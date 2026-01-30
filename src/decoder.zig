//! TOON Decoder
//!
//! Core dispatch for decoding TOON input to Value trees.
//! Uses Scanner for line-by-line tokenization and Parser for semantic parsing.
//!
//! The decoder handles:
//! - Root form detection (object, array, primitive, empty)
//! - Nested structure building via indentation tracking
//! - Array forms: inline primitives, tabular rows, expanded list items
//! - Strict mode validation per SPEC.md Section 7
//!
//! Reference: SPEC.md Sections 3-7

const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const value = @import("value.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const stream = @import("stream.zig");

// ============================================================================
// Decoder
// ============================================================================

/// TOON decoder that converts TOON input to Value trees.
///
/// Usage:
/// ```
/// var decoder = Decoder.init(allocator, input, .{});
/// var result = try decoder.decode();
/// defer result.deinit(allocator);
/// ```
pub const Decoder = struct {
    allocator: Allocator,
    scan: scanner.Scanner,
    options: stream.DecodeOptions,
    current_line: ?scanner.ScannedLine,
    peeked: bool,

    const Self = @This();

    /// Initialize a new decoder.
    pub fn init(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) Self {
        return .{
            .allocator = allocator,
            .scan = scanner.Scanner.init(allocator, input, .{
                .indent_size = options.indent,
                .strict = options.strict,
            }),
            .options = options,
            .current_line = null,
            .peeked = false,
        };
    }

    /// Decode the entire input and return a Value.
    /// Caller owns the returned value and must call deinit on it.
    pub fn decode(self: *Self) errors.Error!value.Value {
        // Get the first non-blank line to detect root form
        const first_line = try self.peekNonBlank();
        const root_form = parser.detectRootForm(first_line);

        return switch (root_form) {
            .empty => .{ .object = value.Object.init() },
            .primitive => try self.decodePrimitive(),
            .array => try self.decodeRootArray(),
            .object => try self.decodeRootObject(),
        };
    }

    // ========================================================================
    // Line Management
    // ========================================================================

    /// Get the next line from the scanner (not peeked line).
    fn nextLineFromScanner(self: *Self) errors.Error!?scanner.ScannedLine {
        return try self.scan.next();
    }

    /// Peek at the next line without consuming it.
    /// Returns the peeked line or fetches a new one.
    fn peekLine(self: *Self) errors.Error!?scanner.ScannedLine {
        if (self.peeked) {
            return self.current_line;
        }
        // Clear any previous line
        if (self.current_line) |*line| {
            line.deinit(self.allocator);
            self.current_line = null;
        }
        self.current_line = try self.scan.next();
        self.peeked = true;
        return self.current_line;
    }

    /// Peek at the next non-blank line without consuming it.
    fn peekNonBlank(self: *Self) errors.Error!?scanner.ScannedLine {
        while (true) {
            const line = try self.peekLine() orelse return null;
            if (line.line_type != .blank) return line;
            // Consume and discard the blank line
            self.discardPeeked();
        }
    }

    /// Consume the peeked line and return it (ownership transferred to caller).
    /// Caller is responsible for calling deinit on the returned line.
    fn consumePeeked(self: *Self) ?scanner.ScannedLine {
        if (self.peeked) {
            self.peeked = false;
            const line = self.current_line;
            self.current_line = null;
            return line;
        }
        return null;
    }

    /// Discard the peeked line (freeing its memory).
    fn discardPeeked(self: *Self) void {
        if (self.peeked) {
            if (self.current_line) |*line| {
                line.deinit(self.allocator);
            }
            self.current_line = null;
            self.peeked = false;
        }
    }

    /// Free any remaining resources.
    pub fn deinit(self: *Self) void {
        if (self.current_line) |*line| {
            line.deinit(self.allocator);
            self.current_line = null;
        }
    }

    // ========================================================================
    // Root Decoders
    // ========================================================================

    /// Decode a single primitive at root level.
    fn decodePrimitive(self: *Self) errors.Error!value.Value {
        var line = self.consumePeeked() orelse {
            const empty = self.allocator.dupe(u8, "") catch return errors.Error.OutOfMemory;
            return .{ .string = empty };
        };
        defer line.deinit(self.allocator);

        const val = line.value orelse "";
        return parser.parseValue(self.allocator, val);
    }

    /// Decode a root-level object.
    fn decodeRootObject(self: *Self) errors.Error!value.Value {
        var builder = value.ObjectBuilder.init(self.allocator);
        errdefer builder.deinit();

        try self.decodeObjectEntries(&builder, 0);

        return .{ .object = builder.toOwnedObject() };
    }

    /// Decode a root-level array.
    fn decodeRootArray(self: *Self) errors.Error!value.Value {
        var line = self.consumePeeked() orelse {
            return .{ .array = value.Array.init() };
        };

        const header = line.array_header orelse {
            line.deinit(self.allocator);
            return errors.Error.MalformedArrayHeader;
        };

        const result = try self.decodeArrayContent(header, 0, &line);
        return result;
    }

    // ========================================================================
    // Object Decoding
    // ========================================================================

    /// Decode object entries at a given depth into the builder.
    fn decodeObjectEntries(self: *Self, builder: *value.ObjectBuilder, base_depth: usize) errors.Error!void {
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            // Stop if we've outdented past our level
            if (peeked.depth < base_depth) break;

            // Skip lines at deeper indentation (shouldn't happen in well-formed input)
            if (peeked.depth > base_depth) {
                self.discardPeeked();
                continue;
            }

            switch (peeked.line_type) {
                .key_value => {
                    var line = self.consumePeeked().?;
                    try self.decodeKeyValue(builder, &line, base_depth);
                },
                .array_header => {
                    var line = self.consumePeeked().?;
                    try self.decodeKeyArrayHeader(builder, &line, base_depth);
                },
                .list_item => {
                    // List items at object level indicate a root array, not object
                    // This shouldn't happen if root form detection is correct
                    break;
                },
                else => break,
            }
        }
    }

    /// Decode a key-value line and add to builder.
    /// Takes ownership of the line - caller should not use line after this call.
    fn decodeKeyValue(self: *Self, builder: *value.ObjectBuilder, line: *scanner.ScannedLine, base_depth: usize) errors.Error!void {
        defer line.deinit(self.allocator);

        const key = line.key orelse return errors.Error.MissingColon;

        if (line.value) |val| {
            // Inline value
            var parsed = try parser.parseValue(self.allocator, val);
            errdefer parsed.deinit(self.allocator);
            try builder.put(key, parsed);
        } else {
            // Nested content - peek at next line to determine type
            const next = try self.peekNonBlank() orelse {
                // Empty nested content -> empty object
                const empty_obj: value.Value = .{ .object = value.Object.init() };
                try builder.put(key, empty_obj);
                return;
            };

            if (next.depth <= base_depth) {
                // No nested content at deeper level -> empty object
                const empty_obj: value.Value = .{ .object = value.Object.init() };
                try builder.put(key, empty_obj);
                return;
            }

            // Decode nested content
            var nested = try self.decodeNestedValue(base_depth + 1);
            errdefer nested.deinit(self.allocator);
            try builder.put(key, nested);
        }
    }

    /// Decode an array header at object level and add to builder.
    /// Takes ownership of the line - caller should not use line after this call.
    fn decodeKeyArrayHeader(self: *Self, builder: *value.ObjectBuilder, line: *scanner.ScannedLine, base_depth: usize) errors.Error!void {
        const header = line.array_header orelse {
            line.deinit(self.allocator);
            return errors.Error.MalformedArrayHeader;
        };
        const key_ref = header.key orelse {
            line.deinit(self.allocator);
            return errors.Error.MissingColon;
        };

        // Copy the key before decodeArrayContent frees the line
        const key = self.allocator.dupe(u8, key_ref) catch return errors.Error.OutOfMemory;
        errdefer self.allocator.free(key);

        var arr = try self.decodeArrayContent(header, base_depth, line);
        errdefer arr.deinit(self.allocator);

        // put takes ownership of key by duplicating it, so we need to free our copy
        try builder.put(key, arr);
        self.allocator.free(key);
    }

    // ========================================================================
    // Array Decoding
    // ========================================================================

    /// Decode array content based on header format.
    /// Takes ownership of the line - caller should not use line after this call.
    fn decodeArrayContent(self: *Self, header: scanner.ArrayHeader, base_depth: usize, line: *scanner.ScannedLine) errors.Error!value.Value {
        defer line.deinit(self.allocator);

        // Check for inline values
        if (header.inline_values) |inline_vals| {
            return try self.decodeInlineArray(inline_vals, header.delimiter, header.count);
        }

        // Check for tabular format
        if (header.fields) |fields| {
            return try self.decodeTabularArray(fields, header.delimiter, header.count, base_depth);
        }

        // Expanded list form
        return try self.decodeExpandedArray(header.delimiter, header.count, base_depth);
    }

    /// Decode an inline primitive array.
    fn decodeInlineArray(self: *Self, content: []const u8, delimiter: constants.Delimiter, expected_count: usize) errors.Error!value.Value {
        const values = try parser.parseDelimitedPrimitives(self.allocator, content, delimiter);

        // Validate count in strict mode
        if (self.options.strict and values.len != expected_count) {
            // Free the values we just allocated before returning error
            for (values) |*v| @constCast(v).deinit(self.allocator);
            self.allocator.free(values);
            return errors.Error.CountMismatch;
        }

        return .{ .array = value.Array.fromOwnedSlice(values) };
    }

    /// Decode a tabular array with field names.
    fn decodeTabularArray(self: *Self, fields: []const []const u8, delimiter: constants.Delimiter, expected_count: usize, base_depth: usize) errors.Error!value.Value {
        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        var row_count: usize = 0;
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            // Stop if we've outdented
            if (peeked.depth <= base_depth) break;

            // Must be a tabular row at depth base_depth + 1
            if (peeked.depth != base_depth + 1) break;

            if (peeked.line_type != .tabular_row) break;

            var line = self.consumePeeked().?;
            defer line.deinit(self.allocator);

            // Parse the row values
            const row_content = line.value orelse "";
            const row_values = try parser.parseDelimitedPrimitives(self.allocator, row_content, delimiter);
            defer {
                for (row_values) |*v| @constCast(v).deinit(self.allocator);
                self.allocator.free(row_values);
            }

            // Validate field count in strict mode
            if (self.options.strict and row_values.len != fields.len) {
                return errors.Error.CountMismatch;
            }

            // Build object from fields and values
            var obj_builder = value.ObjectBuilder.init(self.allocator);
            errdefer obj_builder.deinit();

            const count = @min(fields.len, row_values.len);
            for (0..count) |i| {
                var cloned = try row_values[i].clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                try obj_builder.put(fields[i], cloned);
            }

            try arr_builder.append(.{ .object = obj_builder.toOwnedObject() });
            row_count += 1;
        }

        // Validate count in strict mode
        if (self.options.strict and row_count != expected_count) {
            return errors.Error.CountMismatch;
        }

        return .{ .array = arr_builder.toOwnedArray() };
    }

    /// Decode an expanded array with list items.
    fn decodeExpandedArray(self: *Self, delimiter: constants.Delimiter, expected_count: usize, base_depth: usize) errors.Error!value.Value {
        _ = delimiter; // May be used for nested arrays

        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        var item_count: usize = 0;
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            // Stop if we've outdented
            if (peeked.depth <= base_depth) break;

            // Must be at depth base_depth + 1
            if (peeked.depth != base_depth + 1) {
                // Skip deeper lines (they belong to previous item)
                self.discardPeeked();
                continue;
            }

            if (peeked.line_type != .list_item) break;

            // consumePeeked returns the line, decodeListItem will consume it
            var item = try self.decodeListItem(base_depth + 1);
            errdefer item.deinit(self.allocator);
            try arr_builder.append(item);
            item_count += 1;
        }

        // Validate count in strict mode
        if (self.options.strict and item_count != expected_count) {
            return errors.Error.CountMismatch;
        }

        return .{ .array = arr_builder.toOwnedArray() };
    }

    /// Decode a single list item.
    /// The item_depth is the depth of the "- " marker line.
    /// Content within the list item is at item_depth + 1 (indented under the hyphen).
    fn decodeListItem(self: *Self, item_depth: usize) errors.Error!value.Value {
        var line = self.consumePeeked() orelse {
            const empty = self.allocator.dupe(u8, "") catch return errors.Error.OutOfMemory;
            return .{ .string = empty };
        };
        defer line.deinit(self.allocator);

        // Check if it's a list item with key (- key: value)
        if (line.key) |key| {
            var obj_builder = value.ObjectBuilder.init(self.allocator);
            errdefer obj_builder.deinit();

            if (line.value) |val| {
                // Inline value: - key: value
                var parsed = try parser.parseValue(self.allocator, val);
                errdefer parsed.deinit(self.allocator);
                try obj_builder.put(key, parsed);
            } else {
                // Nested content: - key:
                var nested = try self.decodeNestedValue(item_depth + 1);
                errdefer nested.deinit(self.allocator);
                try obj_builder.put(key, nested);
            }

            // Continue collecting object entries at content depth (item_depth + 1)
            // This handles multi-key list items like:
            //   - id: 1
            //     name: Alice  <- this is at item_depth + 1
            try self.decodeObjectEntriesAtDepth(&obj_builder, item_depth + 1);

            return .{ .object = obj_builder.toOwnedObject() };
        }

        // Simple list item: - value
        const val = line.value orelse "";
        return parser.parseValue(self.allocator, val);
    }

    /// Decode additional object entries at a specific depth (for list items with multiple keys).
    fn decodeObjectEntriesAtDepth(self: *Self, builder: *value.ObjectBuilder, target_depth: usize) errors.Error!void {
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            // Stop if we've outdented or are at different depth
            if (peeked.depth != target_depth) break;

            // Only process key-value and array headers
            switch (peeked.line_type) {
                .key_value => {
                    var line = self.consumePeeked().?;
                    try self.decodeKeyValue(builder, &line, target_depth);
                },
                .array_header => {
                    var line = self.consumePeeked().?;
                    try self.decodeKeyArrayHeader(builder, &line, target_depth);
                },
                else => break,
            }
        }
    }

    // ========================================================================
    // Nested Value Decoding
    // ========================================================================

    /// Decode a nested value starting at the given depth.
    fn decodeNestedValue(self: *Self, nested_depth: usize) errors.Error!value.Value {
        const peeked = try self.peekNonBlank() orelse {
            return .{ .object = value.Object.init() };
        };

        if (peeked.depth < nested_depth) {
            return .{ .object = value.Object.init() };
        }

        switch (peeked.line_type) {
            .array_header => {
                var line = self.consumePeeked().?;
                const header = line.array_header orelse {
                    line.deinit(self.allocator);
                    return errors.Error.MalformedArrayHeader;
                };
                return try self.decodeArrayContent(header, nested_depth, &line);
            },
            .list_item => {
                // Infer array from list items
                return try self.decodeInferredArray(nested_depth);
            },
            .key_value => {
                var builder = value.ObjectBuilder.init(self.allocator);
                errdefer builder.deinit();
                try self.decodeObjectEntries(&builder, nested_depth);
                return .{ .object = builder.toOwnedObject() };
            },
            .tabular_row => {
                // Tabular row at nested level - parse as value
                var line = self.consumePeeked().?;
                defer line.deinit(self.allocator);
                const val = line.value orelse "";
                return parser.parseValue(self.allocator, val);
            },
            .blank, .comment => {
                return .{ .object = value.Object.init() };
            },
        }
    }

    /// Decode an array inferred from list items (no explicit header).
    fn decodeInferredArray(self: *Self, base_depth: usize) errors.Error!value.Value {
        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            if (peeked.depth < base_depth) break;
            if (peeked.depth != base_depth) {
                self.discardPeeked();
                continue;
            }
            if (peeked.line_type != .list_item) break;

            // decodeListItem will consume the peeked line
            var item = try self.decodeListItem(base_depth);
            errdefer item.deinit(self.allocator);
            try arr_builder.append(item);
        }

        return .{ .array = arr_builder.toOwnedArray() };
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Decode TOON input to a Value.
/// Caller owns the returned value and must call deinit on it.
pub fn decode(allocator: Allocator, input: []const u8) errors.Error!value.Value {
    return decodeWithOptions(allocator, input, .{});
}

/// Decode TOON input to a Value with custom options.
/// Caller owns the returned value and must call deinit on it.
pub fn decodeWithOptions(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) errors.Error!value.Value {
    var decoder = Decoder.init(allocator, input, options);
    defer decoder.deinit();
    return try decoder.decode();
}

// ============================================================================
// Tests
// ============================================================================

test "decode empty input" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.object.count() == 0);
}

test "decode single primitive - string" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "hello");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "hello" }));
}

test "decode single primitive - number" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "42");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .number = 42.0 }));
}

test "decode single primitive - boolean" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "true");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .bool = true }));
}

test "decode single primitive - null" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "null");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.null));
}

test "decode simple object" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "name: Alice\nage: 30\n");
    defer result.deinit(allocator);

    try std.testing.expect(result.object.get("name").?.eql(.{ .string = "Alice" }));
    try std.testing.expect(result.object.get("age").?.eql(.{ .number = 30.0 }));
}

test "decode nested object" {
    const allocator = std.testing.allocator;
    const input =
        \\user:
        \\  name: Bob
        \\  age: 25
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const user = result.object.get("user").?.object;
    try std.testing.expect(user.get("name").?.eql(.{ .string = "Bob" }));
    try std.testing.expect(user.get("age").?.eql(.{ .number = 25.0 }));
}

test "decode inline array" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "nums[3]: 1,2,3\n");
    defer result.deinit(allocator);

    const arr = result.object.get("nums").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .number = 1.0 }));
    try std.testing.expect(arr.get(1).?.eql(.{ .number = 2.0 }));
    try std.testing.expect(arr.get(2).?.eql(.{ .number = 3.0 }));
}

test "decode tabular array" {
    const allocator = std.testing.allocator;
    const input =
        \\users[2]{id,name}:
        \\  1,Alice
        \\  2,Bob
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const arr = result.object.get("users").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());

    const row0 = arr.get(0).?.object;
    try std.testing.expect(row0.get("id").?.eql(.{ .number = 1.0 }));
    try std.testing.expect(row0.get("name").?.eql(.{ .string = "Alice" }));

    const row1 = arr.get(1).?.object;
    try std.testing.expect(row1.get("id").?.eql(.{ .number = 2.0 }));
    try std.testing.expect(row1.get("name").?.eql(.{ .string = "Bob" }));
}

test "decode expanded array" {
    const allocator = std.testing.allocator;
    const input =
        \\items[3]:
        \\  - first
        \\  - second
        \\  - third
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const arr = result.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .string = "first" }));
    try std.testing.expect(arr.get(1).?.eql(.{ .string = "second" }));
    try std.testing.expect(arr.get(2).?.eql(.{ .string = "third" }));
}

test "decode root array" {
    const allocator = std.testing.allocator;
    const input =
        \\[3]:
        \\  - a
        \\  - b
        \\  - c
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.array.len());
    try std.testing.expect(result.array.get(0).?.eql(.{ .string = "a" }));
    try std.testing.expect(result.array.get(1).?.eql(.{ .string = "b" }));
    try std.testing.expect(result.array.get(2).?.eql(.{ .string = "c" }));
}

test "decode root array inline" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "[3]: 1,2,3\n");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.array.len());
    try std.testing.expect(result.array.get(0).?.eql(.{ .number = 1.0 }));
    try std.testing.expect(result.array.get(1).?.eql(.{ .number = 2.0 }));
    try std.testing.expect(result.array.get(2).?.eql(.{ .number = 3.0 }));
}

test "decode list item with object" {
    const allocator = std.testing.allocator;
    const input =
        \\items[2]:
        \\  - id: 1
        \\    name: Alice
        \\  - id: 2
        \\    name: Bob
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const arr = result.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());

    const item0 = arr.get(0).?.object;
    try std.testing.expect(item0.get("id").?.eql(.{ .number = 1.0 }));
    try std.testing.expect(item0.get("name").?.eql(.{ .string = "Alice" }));

    const item1 = arr.get(1).?.object;
    try std.testing.expect(item1.get("id").?.eql(.{ .number = 2.0 }));
    try std.testing.expect(item1.get("name").?.eql(.{ .string = "Bob" }));
}

test "decode quoted values" {
    const allocator = std.testing.allocator;
    const input =
        \\str: "hello world"
        \\num: "123"
        \\bool: "true"
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    try std.testing.expect(result.object.get("str").?.eql(.{ .string = "hello world" }));
    try std.testing.expect(result.object.get("num").?.eql(.{ .string = "123" }));
    try std.testing.expect(result.object.get("bool").?.eql(.{ .string = "true" }));
}

test "decode quoted key" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "\"special-key\": value\n");
    defer result.deinit(allocator);

    try std.testing.expect(result.object.get("special-key").?.eql(.{ .string = "value" }));
}

test "decode with pipe delimiter" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "data[3|]: a|b|c\n");
    defer result.deinit(allocator);

    const arr = result.object.get("data").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .string = "a" }));
    try std.testing.expect(arr.get(1).?.eql(.{ .string = "b" }));
    try std.testing.expect(arr.get(2).?.eql(.{ .string = "c" }));
}

test "decode count mismatch in strict mode" {
    const allocator = std.testing.allocator;

    const result = decodeWithOptions(allocator, "nums[3]: 1,2\n", .{ .strict = true });
    try std.testing.expectError(errors.Error.CountMismatch, result);
}

test "decode count mismatch allowed in lenient mode" {
    const allocator = std.testing.allocator;

    var result = try decodeWithOptions(allocator, "nums[3]: 1,2\n", .{ .strict = false });
    defer result.deinit(allocator);

    const arr = result.object.get("nums").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());
}

test "decode deeply nested" {
    const allocator = std.testing.allocator;
    const input =
        \\a:
        \\  b:
        \\    c:
        \\      d: value
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const a = result.object.get("a").?.object;
    const b = a.get("b").?.object;
    const c = b.get("c").?.object;
    try std.testing.expect(c.get("d").?.eql(.{ .string = "value" }));
}

test "decode mixed content" {
    const allocator = std.testing.allocator;
    const input =
        \\name: Test
        \\count: 5
        \\active: true
        \\tags[2]: a,b
        \\meta:
        \\  version: 1
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    try std.testing.expect(result.object.get("name").?.eql(.{ .string = "Test" }));
    try std.testing.expect(result.object.get("count").?.eql(.{ .number = 5.0 }));
    try std.testing.expect(result.object.get("active").?.eql(.{ .bool = true }));
    try std.testing.expectEqual(@as(usize, 2), result.object.get("tags").?.array.len());
    try std.testing.expect(result.object.get("meta").?.object.get("version").?.eql(.{ .number = 1.0 }));
}
