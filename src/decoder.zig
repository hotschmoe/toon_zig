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

        return try self.decodeArrayContent(header, 0, &line);
    }

    // ========================================================================
    // Object Decoding
    // ========================================================================

    fn decodeObjectEntries(self: *Self, builder: *value.ObjectBuilder, base_depth: usize) errors.Error!void {
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            if (peeked.depth != base_depth) {
                if (peeked.depth < base_depth) break;
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
                else => break,
            }
        }
    }

    /// Decode a key-value line and add to builder. Takes ownership of the line.
    fn decodeKeyValue(self: *Self, builder: *value.ObjectBuilder, line: *scanner.ScannedLine, base_depth: usize) errors.Error!void {
        defer line.deinit(self.allocator);

        const key = line.key orelse return errors.Error.MissingColon;

        if (line.value) |val| {
            var parsed = try parser.parseValue(self.allocator, val);
            errdefer parsed.deinit(self.allocator);
            try builder.put(key, parsed);
            return;
        }

        const next = try self.peekNonBlank();
        if (next == null or next.?.depth <= base_depth) {
            try builder.put(key, .{ .object = value.Object.init() });
            return;
        }

        var nested = try self.decodeNestedValue(base_depth + 1);
        errdefer nested.deinit(self.allocator);
        try builder.put(key, nested);
    }

    /// Decode an array header at object level. Takes ownership of the line.
    fn decodeKeyArrayHeader(self: *Self, builder: *value.ObjectBuilder, line: *scanner.ScannedLine, base_depth: usize) errors.Error!void {
        const header = line.array_header orelse {
            line.deinit(self.allocator);
            return errors.Error.MalformedArrayHeader;
        };
        const key_ref = header.key orelse {
            line.deinit(self.allocator);
            return errors.Error.MissingColon;
        };

        const key = self.allocator.dupe(u8, key_ref) catch return errors.Error.OutOfMemory;
        defer self.allocator.free(key);

        var arr = try self.decodeArrayContent(header, base_depth, line);
        errdefer arr.deinit(self.allocator);
        try builder.put(key, arr);
    }

    // ========================================================================
    // Array Decoding
    // ========================================================================

    /// Decode array content based on header format.
    /// Takes ownership of the line.
    fn decodeArrayContent(self: *Self, header: scanner.ArrayHeader, base_depth: usize, line: *scanner.ScannedLine) errors.Error!value.Value {
        defer line.deinit(self.allocator);

        if (header.inline_values) |inline_vals| {
            return try self.decodeInlineArray(inline_vals, header.delimiter, header.count);
        }

        if (header.fields) |fields| {
            return try self.decodeTabularArray(fields, header.delimiter, header.count, base_depth);
        }

        return try self.decodeExpandedArray(header.delimiter, header.count, base_depth);
    }

    fn decodeInlineArray(self: *Self, content: []const u8, delimiter: constants.Delimiter, expected_count: usize) errors.Error!value.Value {
        const values = try parser.parseDelimitedPrimitives(self.allocator, content, delimiter);

        if (self.options.strict and values.len != expected_count) {
            for (values) |*v| @constCast(v).deinit(self.allocator);
            self.allocator.free(values);
            return errors.Error.CountMismatch;
        }

        return .{ .array = value.Array.fromOwnedSlice(values) };
    }

    fn decodeTabularArray(self: *Self, fields: []const []const u8, delimiter: constants.Delimiter, expected_count: usize, base_depth: usize) errors.Error!value.Value {
        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        var row_count: usize = 0;
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;
            if (peeked.depth != base_depth + 1 or peeked.line_type != .tabular_row) break;

            var line = self.consumePeeked().?;
            defer line.deinit(self.allocator);

            const row_content = line.value orelse "";
            const row_values = try parser.parseDelimitedPrimitives(self.allocator, row_content, delimiter);
            defer {
                for (row_values) |*v| @constCast(v).deinit(self.allocator);
                self.allocator.free(row_values);
            }

            if (self.options.strict and row_values.len != fields.len) {
                return errors.Error.CountMismatch;
            }

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

        if (self.options.strict and row_count != expected_count) {
            return errors.Error.CountMismatch;
        }

        return .{ .array = arr_builder.toOwnedArray() };
    }

    fn decodeExpandedArray(self: *Self, delimiter: constants.Delimiter, expected_count: usize, base_depth: usize) errors.Error!value.Value {
        _ = delimiter;

        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        var item_count: usize = 0;
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            if (peeked.depth != base_depth + 1) {
                if (peeked.depth <= base_depth) break;
                self.discardPeeked();
                continue;
            }

            if (peeked.line_type != .list_item) break;

            var item = try self.decodeListItem(base_depth + 1);
            errdefer item.deinit(self.allocator);
            try arr_builder.append(item);
            item_count += 1;
        }

        if (self.options.strict and item_count != expected_count) {
            return errors.Error.CountMismatch;
        }

        return .{ .array = arr_builder.toOwnedArray() };
    }

    /// Decode a single list item at item_depth.
    /// Content within the list item is at item_depth + 1.
    fn decodeListItem(self: *Self, item_depth: usize) errors.Error!value.Value {
        var line = self.consumePeeked() orelse {
            const empty = self.allocator.dupe(u8, "") catch return errors.Error.OutOfMemory;
            return .{ .string = empty };
        };
        defer line.deinit(self.allocator);

        const key = line.key orelse {
            const val = line.value orelse "";
            return parser.parseValue(self.allocator, val);
        };

        var obj_builder = value.ObjectBuilder.init(self.allocator);
        errdefer obj_builder.deinit();

        if (line.value) |val| {
            var parsed = try parser.parseValue(self.allocator, val);
            errdefer parsed.deinit(self.allocator);
            try obj_builder.put(key, parsed);
        } else {
            var nested = try self.decodeNestedValue(item_depth + 1);
            errdefer nested.deinit(self.allocator);
            try obj_builder.put(key, nested);
        }

        // Collect additional entries for multi-key list items
        try self.decodeObjectEntriesAtDepth(&obj_builder, item_depth + 1);

        return .{ .object = obj_builder.toOwnedObject() };
    }

    /// Decode additional object entries at a specific depth (for multi-key list items).
    fn decodeObjectEntriesAtDepth(self: *Self, builder: *value.ObjectBuilder, target_depth: usize) errors.Error!void {
        while (true) {
            const peeked = try self.peekNonBlank() orelse break;
            if (peeked.depth != target_depth) break;

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

    fn decodeNestedValue(self: *Self, nested_depth: usize) errors.Error!value.Value {
        const peeked = try self.peekNonBlank() orelse {
            return .{ .object = value.Object.init() };
        };

        if (peeked.depth < nested_depth) {
            return .{ .object = value.Object.init() };
        }

        switch (peeked.line_type) {
            .array_header => {
                const header = peeked.array_header orelse {
                    self.discardPeeked();
                    return errors.Error.MalformedArrayHeader;
                };

                if (header.key != null) {
                    var builder = value.ObjectBuilder.init(self.allocator);
                    errdefer builder.deinit();
                    try self.decodeObjectEntries(&builder, nested_depth);
                    return .{ .object = builder.toOwnedObject() };
                }

                var line = self.consumePeeked().?;
                return try self.decodeArrayContent(header, nested_depth, &line);
            },
            .list_item => return try self.decodeInferredArray(nested_depth),
            .key_value => {
                var builder = value.ObjectBuilder.init(self.allocator);
                errdefer builder.deinit();
                try self.decodeObjectEntries(&builder, nested_depth);
                return .{ .object = builder.toOwnedObject() };
            },
            .tabular_row => {
                var line = self.consumePeeked().?;
                defer line.deinit(self.allocator);
                return parser.parseValue(self.allocator, line.value orelse "");
            },
            .blank, .comment => return .{ .object = value.Object.init() },
        }
    }

    /// Decode an array inferred from list items (no explicit header).
    fn decodeInferredArray(self: *Self, base_depth: usize) errors.Error!value.Value {
        var arr_builder = value.ArrayBuilder.init(self.allocator);
        errdefer arr_builder.deinit();

        while (true) {
            const peeked = try self.peekNonBlank() orelse break;

            if (peeked.depth != base_depth) {
                if (peeked.depth < base_depth) break;
                self.discardPeeked();
                continue;
            }
            if (peeked.line_type != .list_item) break;

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

test "decode empty array" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "items[0]:\n");
    defer result.deinit(allocator);

    const arr = result.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 0), arr.len());
}

test "decode root empty array" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "[0]:\n");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.array.len());
}

test "decode array with mixed primitives" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "mixed[5]: 42,true,false,null,text\n");
    defer result.deinit(allocator);

    const arr = result.object.get("mixed").?.array;
    try std.testing.expectEqual(@as(usize, 5), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .number = 42.0 }));
    try std.testing.expect(arr.get(1).?.eql(.{ .bool = true }));
    try std.testing.expect(arr.get(2).?.eql(.{ .bool = false }));
    try std.testing.expect(arr.get(3).?.eql(.null));
    try std.testing.expect(arr.get(4).?.eql(.{ .string = "text" }));
}

test "decode tabular array with pipe delimiter" {
    const allocator = std.testing.allocator;
    const input =
        \\users[2|]{id|name}:
        \\  1|Alice
        \\  2|Bob
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const arr = result.object.get("users").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());

    const row0 = arr.get(0).?.object;
    try std.testing.expect(row0.get("id").?.eql(.{ .number = 1.0 }));
    try std.testing.expect(row0.get("name").?.eql(.{ .string = "Alice" }));
}

test "decode nested arrays in objects" {
    const allocator = std.testing.allocator;
    const input =
        \\data:
        \\  numbers[3]: 1,2,3
        \\  names[2]: foo,bar
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const data = result.object.get("data").?.object;
    const numbers = data.get("numbers").?.array;
    try std.testing.expectEqual(@as(usize, 3), numbers.len());
    try std.testing.expect(numbers.get(0).?.eql(.{ .number = 1.0 }));

    const names = data.get("names").?.array;
    try std.testing.expectEqual(@as(usize, 2), names.len());
    try std.testing.expect(names.get(0).?.eql(.{ .string = "foo" }));
}

test "decode list items with nested arrays" {
    const allocator = std.testing.allocator;
    const input =
        \\items[2]:
        \\  - id: 1
        \\    values[2]: a,b
        \\  - id: 2
        \\    values[2]: c,d
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    const arr = result.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());

    const item0 = arr.get(0).?.object;
    try std.testing.expect(item0.get("id").?.eql(.{ .number = 1.0 }));
    const values0 = item0.get("values").?.array;
    try std.testing.expectEqual(@as(usize, 2), values0.len());
    try std.testing.expect(values0.get(0).?.eql(.{ .string = "a" }));

    const item1 = arr.get(1).?.object;
    const values1 = item1.get("values").?.array;
    try std.testing.expect(values1.get(0).?.eql(.{ .string = "c" }));
}

test "decode tabular array count mismatch strict" {
    const allocator = std.testing.allocator;
    const input =
        \\users[3]{id,name}:
        \\  1,Alice
        \\  2,Bob
        \\
    ;
    const result = decodeWithOptions(allocator, input, .{ .strict = true });
    try std.testing.expectError(errors.Error.CountMismatch, result);
}

test "decode expanded array count mismatch strict" {
    const allocator = std.testing.allocator;
    const input =
        \\items[3]:
        \\  - first
        \\  - second
        \\
    ;
    const result = decodeWithOptions(allocator, input, .{ .strict = true });
    try std.testing.expectError(errors.Error.CountMismatch, result);
}

test "decode root tabular array" {
    const allocator = std.testing.allocator;
    const input =
        \\[2]{x,y}:
        \\  1,2
        \\  3,4
        \\
    ;
    var result = try decode(allocator, input);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.array.len());

    const row0 = result.array.get(0).?.object;
    try std.testing.expect(row0.get("x").?.eql(.{ .number = 1.0 }));
    try std.testing.expect(row0.get("y").?.eql(.{ .number = 2.0 }));

    const row1 = result.array.get(1).?.object;
    try std.testing.expect(row1.get("x").?.eql(.{ .number = 3.0 }));
    try std.testing.expect(row1.get("y").?.eql(.{ .number = 4.0 }));
}

test "decode array with quoted values containing delimiter" {
    const allocator = std.testing.allocator;
    var result = try decode(allocator, "data[2]: \"a,b\",c\n");
    defer result.deinit(allocator);

    const arr = result.object.get("data").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .string = "a,b" }));
    try std.testing.expect(arr.get(1).?.eql(.{ .string = "c" }));
}
