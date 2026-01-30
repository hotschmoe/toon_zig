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

    /// Peek at the next non-blank line within an array context.
    /// In strict mode, blank lines within arrays are rejected per SPEC.md Section 7.
    fn peekNonBlankInArray(self: *Self) errors.Error!?scanner.ScannedLine {
        while (true) {
            const line = try self.peekLine() orelse return null;
            if (line.line_type != .blank) return line;
            if (self.options.strict) return errors.Error.BlankLineInArray;
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
            const peeked = try self.peekNonBlankInArray() orelse break;
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
            const peeked = try self.peekNonBlankInArray() orelse break;

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
            const peeked = try self.peekNonBlankInArray() orelse break;

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
// Event Builder
// ============================================================================

/// Streaming event builder that converts TOON input to JsonStreamEvent sequence.
/// This enables streaming pipelines and event-based processing.
///
/// The event sequence follows:
/// - Object: start_object -> (key, value events)* -> end_object
/// - Array: start_array -> (value events)* -> end_array
/// - Primitive: primitive event
///
/// Usage:
/// ```
/// var builder = EventBuilder.init(allocator, input, .{});
/// defer builder.deinit();
/// while (try builder.next()) |event| {
///     defer event.deinit(allocator);
///     // process event...
/// }
/// ```
pub const EventBuilder = struct {
    allocator: Allocator,
    decoder: Decoder,
    root_value: ?value.Value,
    event_stack: std.ArrayListUnmanaged(StackFrame),
    started: bool,
    finished: bool,

    const StackFrame = struct {
        value_ptr: *const value.Value,
        state: FrameState,
        index: usize,
    };

    const FrameState = enum {
        start,
        iterating,
        done,
    };

    const Self = @This();

    /// Initialize a new event builder.
    pub fn init(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) Self {
        return .{
            .allocator = allocator,
            .decoder = Decoder.init(allocator, input, options),
            .root_value = null,
            .event_stack = .{},
            .started = false,
            .finished = false,
        };
    }

    /// Get the next event, or null if no more events.
    /// Caller owns the returned event and must call deinit on it.
    pub fn next(self: *Self) errors.Error!?stream.JsonStreamEvent {
        if (self.finished) return null;

        // First call: decode the entire input and start iteration
        if (!self.started) {
            self.root_value = try self.decoder.decode();
            self.started = true;

            // Push root value onto stack
            const root_ptr = &self.root_value.?;
            self.event_stack.append(self.allocator, .{
                .value_ptr = root_ptr,
                .state = .start,
                .index = 0,
            }) catch return errors.Error.OutOfMemory;
        }

        return self.nextEvent();
    }

    fn nextEvent(self: *Self) errors.Error!?stream.JsonStreamEvent {
        while (self.event_stack.items.len > 0) {
            const frame = &self.event_stack.items[self.event_stack.items.len - 1];
            const val = frame.value_ptr.*;

            switch (frame.state) {
                .start => {
                    frame.state = .iterating;
                    switch (val) {
                        .object => |obj| return .{ .start_object = .{ .count = obj.count() } },
                        .array => |arr| return .{ .start_array = .{ .count = arr.len() } },
                        else => {
                            frame.state = .done;
                            return try self.emitPrimitive(val);
                        },
                    }
                },
                .iterating => {
                    switch (val) {
                        .object => |obj| {
                            if (frame.index < obj.entries.len) {
                                const entry = &obj.entries[frame.index];
                                frame.index += 1;
                                const key = self.allocator.dupe(u8, entry.key) catch return errors.Error.OutOfMemory;
                                self.event_stack.append(self.allocator, .{
                                    .value_ptr = &entry.value,
                                    .state = .start,
                                    .index = 0,
                                }) catch {
                                    self.allocator.free(key);
                                    return errors.Error.OutOfMemory;
                                };
                                return .{ .key = key };
                            } else {
                                frame.state = .done;
                                return .end_object;
                            }
                        },
                        .array => |arr| {
                            if (frame.index < arr.items.len) {
                                const item = &arr.items[frame.index];
                                frame.index += 1;
                                self.event_stack.append(self.allocator, .{
                                    .value_ptr = item,
                                    .state = .start,
                                    .index = 0,
                                }) catch return errors.Error.OutOfMemory;
                                continue;
                            } else {
                                frame.state = .done;
                                return .end_array;
                            }
                        },
                        // Primitives transition directly from .start to .done
                        .null, .bool, .number, .string => unreachable,
                    }
                },
                .done => {
                    _ = self.event_stack.pop();
                    continue;
                },
            }
        }

        self.finished = true;
        return null;
    }

    fn emitPrimitive(self: *Self, val: value.Value) errors.Error!stream.JsonStreamEvent {
        return switch (val) {
            .null => .{ .primitive = .null },
            .bool => |b| .{ .primitive = .{ .bool = b } },
            .number => |n| .{ .primitive = .{ .number = n } },
            .string => |s| .{ .primitive = .{ .string = self.allocator.dupe(u8, s) catch return errors.Error.OutOfMemory } },
            .array, .object => unreachable,
        };
    }

    /// Free resources.
    pub fn deinit(self: *Self) void {
        self.decoder.deinit();
        if (self.root_value) |*v| {
            v.deinit(self.allocator);
        }
        self.event_stack.deinit(self.allocator);
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

/// Convert TOON input to JSON string.
/// This is the primary high-level API for converting TOON to JSON.
/// Caller owns the returned string and must free it.
pub fn toonToJson(allocator: Allocator, input: []const u8) errors.Error![]u8 {
    return toonToJsonWithOptions(allocator, input, .{});
}

/// Convert TOON input to JSON string with custom options.
/// Caller owns the returned string and must free it.
pub fn toonToJsonWithOptions(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) errors.Error![]u8 {
    var val = try decodeWithOptions(allocator, input, options);
    defer val.deinit(allocator);
    return valueToJson(allocator, val);
}

/// Write TOON input as JSON to any writer.
pub fn decodeToWriter(writer: anytype, allocator: Allocator, input: []const u8) errors.Error!void {
    return decodeToWriterWithOptions(writer, allocator, input, .{});
}

/// Write TOON input as JSON to any writer with custom options.
pub fn decodeToWriterWithOptions(writer: anytype, allocator: Allocator, input: []const u8, options: stream.DecodeOptions) errors.Error!void {
    var val = try decodeWithOptions(allocator, input, options);
    defer val.deinit(allocator);
    writeValueAsJson(writer, val) catch return errors.Error.WriteError;
}

/// Decode TOON input to a Value with custom options.
/// Caller owns the returned value and must call deinit on it.
pub fn decodeWithOptions(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) errors.Error!value.Value {
    var decoder = Decoder.init(allocator, input, options);
    defer decoder.deinit();
    return try decoder.decode();
}

/// Decode TOON input to a stream of events.
/// Returns a slice of events that the caller owns and must free.
/// Each event in the slice must have deinit called, then the slice itself freed.
pub fn decodeToEvents(allocator: Allocator, input: []const u8) errors.Error![]stream.JsonStreamEvent {
    return decodeToEventsWithOptions(allocator, input, .{});
}

/// Decode TOON input to a stream of events with custom options.
/// Returns a slice of events that the caller owns and must free.
pub fn decodeToEventsWithOptions(allocator: Allocator, input: []const u8, options: stream.DecodeOptions) errors.Error![]stream.JsonStreamEvent {
    var builder = EventBuilder.init(allocator, input, options);
    defer builder.deinit();

    var events: std.ArrayListUnmanaged(stream.JsonStreamEvent) = .{};
    errdefer {
        for (events.items) |*e| e.deinit(allocator);
        events.deinit(allocator);
    }

    while (try builder.next()) |event| {
        events.append(allocator, event) catch return errors.Error.OutOfMemory;
    }

    return events.toOwnedSlice(allocator) catch errors.Error.OutOfMemory;
}

// ============================================================================
// JSON Conversion Helpers
// ============================================================================

/// Convert a Value to a JSON string.
/// Caller owns the returned string and must free it.
pub fn valueToJson(allocator: Allocator, val: value.Value) errors.Error![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    writeValueAsJson(writer, val) catch return errors.Error.OutOfMemory;

    return buffer.toOwnedSlice(allocator) catch errors.Error.OutOfMemory;
}

/// Write a Value as JSON to any writer.
fn writeValueAsJson(writer: anytype, val: value.Value) @TypeOf(writer).Error!void {
    switch (val) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .number => |n| {
            if (std.math.isNan(n) or std.math.isInf(n)) {
                try writer.writeAll("null");
            } else {
                try writeJsonNumber(writer, n);
            }
        },
        .string => |s| try writeJsonString(writer, s),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValueAsJson(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            for (obj.entries, 0..) |entry, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonString(writer, entry.key);
                try writer.writeByte(':');
                try writeValueAsJson(writer, entry.value);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeJsonString(writer: anytype, s: []const u8) @TypeOf(writer).Error!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                try writer.writeAll("\\u00");
                try writer.writeByte(hexDigit(c >> 4));
                try writer.writeByte(hexDigit(c & 0x0F));
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

fn writeJsonNumber(writer: anytype, n: f64) @TypeOf(writer).Error!void {
    const num = if (n == 0.0 and std.math.signbit(n)) 0.0 else n;

    if (@floor(num) == num and @abs(num) < 9007199254740992.0) {
        try writer.print("{d}", .{@as(i64, @intFromFloat(num))});
    } else {
        try writer.print("{d}", .{num});
    }
}

// ============================================================================
// Path Expansion
// ============================================================================

const validation = @import("shared/validation.zig");

/// Expand dotted keys in a value tree.
/// For example, `{"a.b.c": 1}` becomes `{"a": {"b": {"c": 1}}}`.
/// Only expands keys that are valid foldable paths.
pub fn expandPaths(allocator: Allocator, val: value.Value) errors.Error!value.Value {
    return switch (val) {
        .object => |obj| expandObjectPaths(allocator, obj),
        .array => |arr| expandArrayPaths(allocator, arr),
        else => val.clone(allocator) catch return errors.Error.OutOfMemory,
    };
}

fn expandObjectPaths(allocator: Allocator, obj: value.Object) errors.Error!value.Value {
    var builder = value.ObjectBuilder.init(allocator);
    errdefer builder.deinit();

    for (obj.entries) |entry| {
        // Recursively expand nested values first
        var expanded_value = try expandPaths(allocator, entry.value);
        errdefer expanded_value.deinit(allocator);

        // Check if key is a valid foldable path with dots
        if (std.mem.indexOfScalar(u8, entry.key, constants.path_separator) != null and
            validation.isValidFoldablePath(entry.key))
        {
            // Split and insert nested
            try insertPathEntry(&builder, allocator, entry.key, expanded_value);
        } else {
            // Plain key, just add it
            try builder.put(entry.key, expanded_value);
        }
    }

    return .{ .object = builder.toOwnedObject() };
}

fn expandArrayPaths(allocator: Allocator, arr: value.Array) errors.Error!value.Value {
    var builder = value.ArrayBuilder.init(allocator);
    errdefer builder.deinit();

    for (arr.items) |item| {
        var expanded = try expandPaths(allocator, item);
        errdefer expanded.deinit(allocator);
        try builder.append(expanded);
    }

    return .{ .array = builder.toOwnedArray() };
}

/// Insert a dotted path like "a.b.c" with value into the builder.
/// Creates nested objects as needed, merging with existing objects.
fn insertPathEntry(builder: *value.ObjectBuilder, allocator: Allocator, path: []const u8, val: value.Value) errors.Error!void {
    var iter = std.mem.splitScalar(u8, path, constants.path_separator);
    const first_segment = iter.next() orelse return;

    const rest = iter.rest();
    if (rest.len == 0) {
        try builder.put(first_segment, val);
        return;
    }

    // Find existing entry index (if any)
    const existing_idx = findEntryIndex(builder, first_segment);

    // Build nested object, merging with existing if present
    var nested_builder = value.ObjectBuilder.init(allocator);
    errdefer nested_builder.deinit();

    if (existing_idx) |idx| {
        const existing = builder.entries.items[idx].value;
        if (existing == .object) {
            for (existing.object.entries) |e| {
                var cloned = try e.value.clone(allocator);
                errdefer cloned.deinit(allocator);
                nested_builder.put(e.key, cloned) catch return errors.Error.OutOfMemory;
            }
        }
    }

    try insertPathEntry(&nested_builder, allocator, rest, val);
    const nested_obj = nested_builder.toOwnedObject();

    // Remove old entry if it existed
    if (existing_idx) |idx| {
        const entry = builder.entries.orderedRemove(idx);
        allocator.free(entry.key);
        @constCast(&entry.value).deinit(allocator);
    }

    builder.put(first_segment, .{ .object = nested_obj }) catch return errors.Error.OutOfMemory;
}

fn findEntryIndex(builder: *value.ObjectBuilder, key: []const u8) ?usize {
    for (builder.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, key)) return i;
    }
    return null;
}

/// Decode TOON with path expansion.
pub fn decodeWithPathExpansion(allocator: Allocator, input: []const u8) errors.Error!value.Value {
    var result = try decode(allocator, input);
    errdefer result.deinit(allocator);

    if (result == .object or result == .array) {
        const expanded = try expandPaths(allocator, result);
        result.deinit(allocator);
        return expanded;
    }

    return result;
}

/// Convert TOON to JSON with path expansion.
pub fn toonToJsonWithPathExpansion(allocator: Allocator, input: []const u8) errors.Error![]u8 {
    var val = try decodeWithPathExpansion(allocator, input);
    defer val.deinit(allocator);
    return valueToJson(allocator, val);
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

test "decode blank line in expanded array strict mode" {
    const allocator = std.testing.allocator;
    const input =
        \\items[3]:
        \\  - first
        \\
        \\  - second
        \\  - third
        \\
    ;
    const result = decodeWithOptions(allocator, input, .{ .strict = true });
    try std.testing.expectError(errors.Error.BlankLineInArray, result);
}

test "decode blank line in tabular array strict mode" {
    const allocator = std.testing.allocator;
    const input =
        \\users[3]{id,name}:
        \\  1,Alice
        \\
        \\  2,Bob
        \\  3,Carol
        \\
    ;
    const result = decodeWithOptions(allocator, input, .{ .strict = true });
    try std.testing.expectError(errors.Error.BlankLineInArray, result);
}

test "decode blank line in array allowed in lenient mode" {
    const allocator = std.testing.allocator;
    const input =
        \\items[3]:
        \\  - first
        \\
        \\  - second
        \\  - third
        \\
    ;
    var result = try decodeWithOptions(allocator, input, .{ .strict = false });
    defer result.deinit(allocator);

    const arr = result.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .string = "first" }));
    try std.testing.expect(arr.get(1).?.eql(.{ .string = "second" }));
    try std.testing.expect(arr.get(2).?.eql(.{ .string = "third" }));
}

// ============================================================================
// Event Builder Tests
// ============================================================================

test "EventBuilder - simple object" {
    const allocator = std.testing.allocator;
    const events = try decodeToEvents(allocator, "a: 1\n");
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // Expected: start_object(1), key("a"), primitive(1), end_object
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[1].eql(.{ .key = "a" }));
    try std.testing.expect(events[2].eql(.{ .primitive = .{ .number = 1.0 } }));
    try std.testing.expect(events[3].eql(.end_object));
}

test "EventBuilder - simple array" {
    const allocator = std.testing.allocator;
    const events = try decodeToEvents(allocator, "[3]: 1,2,3\n");
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // Expected: start_array(3), primitive(1), primitive(2), primitive(3), end_array
    try std.testing.expectEqual(@as(usize, 5), events.len);
    try std.testing.expect(events[0].eql(.{ .start_array = .{ .count = 3 } }));
    try std.testing.expect(events[1].eql(.{ .primitive = .{ .number = 1.0 } }));
    try std.testing.expect(events[2].eql(.{ .primitive = .{ .number = 2.0 } }));
    try std.testing.expect(events[3].eql(.{ .primitive = .{ .number = 3.0 } }));
    try std.testing.expect(events[4].eql(.end_array));
}

test "EventBuilder - nested object" {
    const allocator = std.testing.allocator;
    const input =
        \\outer:
        \\  inner: value
        \\
    ;
    const events = try decodeToEvents(allocator, input);
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // Expected: start_object(1), key("outer"), start_object(1), key("inner"), primitive("value"), end_object, end_object
    try std.testing.expectEqual(@as(usize, 7), events.len);
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[1].eql(.{ .key = "outer" }));
    try std.testing.expect(events[2].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[3].eql(.{ .key = "inner" }));
    try std.testing.expect(events[4].eql(.{ .primitive = .{ .string = "value" } }));
    try std.testing.expect(events[5].eql(.end_object));
    try std.testing.expect(events[6].eql(.end_object));
}

test "EventBuilder - array with objects" {
    const allocator = std.testing.allocator;
    const input =
        \\users[2]{id,name}:
        \\  1,Alice
        \\  2,Bob
        \\
    ;
    const events = try decodeToEvents(allocator, input);
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // Expected:
    // start_object(1), key("users"), start_array(2),
    //   start_object(2), key("id"), primitive(1), key("name"), primitive("Alice"), end_object,
    //   start_object(2), key("id"), primitive(2), key("name"), primitive("Bob"), end_object,
    // end_array, end_object
    try std.testing.expectEqual(@as(usize, 17), events.len);

    // Root object
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[1].eql(.{ .key = "users" }));
    try std.testing.expect(events[2].eql(.{ .start_array = .{ .count = 2 } }));

    // First row
    try std.testing.expect(events[3].eql(.{ .start_object = .{ .count = 2 } }));
    try std.testing.expect(events[4].eql(.{ .key = "id" }));
    try std.testing.expect(events[5].eql(.{ .primitive = .{ .number = 1.0 } }));
    try std.testing.expect(events[6].eql(.{ .key = "name" }));
    try std.testing.expect(events[7].eql(.{ .primitive = .{ .string = "Alice" } }));
    try std.testing.expect(events[8].eql(.end_object));

    // Second row
    try std.testing.expect(events[9].eql(.{ .start_object = .{ .count = 2 } }));
    try std.testing.expect(events[10].eql(.{ .key = "id" }));
    try std.testing.expect(events[11].eql(.{ .primitive = .{ .number = 2.0 } }));
    try std.testing.expect(events[12].eql(.{ .key = "name" }));
    try std.testing.expect(events[13].eql(.{ .primitive = .{ .string = "Bob" } }));
    try std.testing.expect(events[14].eql(.end_object));

    try std.testing.expect(events[15].eql(.end_array));
    try std.testing.expect(events[16].eql(.end_object));
}

test "EventBuilder - primitive types" {
    const allocator = std.testing.allocator;
    const input =
        \\str: hello
        \\num: 42
        \\bool: true
        \\nil: null
        \\
    ;
    const events = try decodeToEvents(allocator, input);
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // start_object(4) + 4*(key + primitive) + end_object = 10
    try std.testing.expectEqual(@as(usize, 10), events.len);
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 4 } }));

    try std.testing.expect(events[1].eql(.{ .key = "str" }));
    try std.testing.expect(events[2].eql(.{ .primitive = .{ .string = "hello" } }));

    try std.testing.expect(events[3].eql(.{ .key = "num" }));
    try std.testing.expect(events[4].eql(.{ .primitive = .{ .number = 42.0 } }));

    try std.testing.expect(events[5].eql(.{ .key = "bool" }));
    try std.testing.expect(events[6].eql(.{ .primitive = .{ .bool = true } }));

    try std.testing.expect(events[7].eql(.{ .key = "nil" }));
    try std.testing.expect(events[8].eql(.{ .primitive = .null }));

    try std.testing.expect(events[9].eql(.end_object));
}

test "EventBuilder - empty object" {
    const allocator = std.testing.allocator;
    const events = try decodeToEvents(allocator, "");
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // Empty input -> empty object
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 0 } }));
    try std.testing.expect(events[1].eql(.end_object));
}

test "EventBuilder - empty array" {
    const allocator = std.testing.allocator;
    const events = try decodeToEvents(allocator, "[0]:\n");
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(events[0].eql(.{ .start_array = .{ .count = 0 } }));
    try std.testing.expect(events[1].eql(.end_array));
}

test "EventBuilder - single primitive" {
    const allocator = std.testing.allocator;
    const events = try decodeToEvents(allocator, "42");
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].eql(.{ .primitive = .{ .number = 42.0 } }));
}

test "EventBuilder - deeply nested" {
    const allocator = std.testing.allocator;
    const input =
        \\a:
        \\  b:
        \\    c: value
        \\
    ;
    const events = try decodeToEvents(allocator, input);
    defer {
        for (events) |*e| @constCast(e).deinit(allocator);
        allocator.free(events);
    }

    // start_object(1), key("a"),
    //   start_object(1), key("b"),
    //     start_object(1), key("c"), primitive("value"), end_object,
    //   end_object,
    // end_object
    try std.testing.expectEqual(@as(usize, 10), events.len);
    try std.testing.expect(events[0].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[1].eql(.{ .key = "a" }));
    try std.testing.expect(events[2].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[3].eql(.{ .key = "b" }));
    try std.testing.expect(events[4].eql(.{ .start_object = .{ .count = 1 } }));
    try std.testing.expect(events[5].eql(.{ .key = "c" }));
    try std.testing.expect(events[6].eql(.{ .primitive = .{ .string = "value" } }));
    try std.testing.expect(events[7].eql(.end_object));
    try std.testing.expect(events[8].eql(.end_object));
    try std.testing.expect(events[9].eql(.end_object));
}

test "EventBuilder iterator interface" {
    const allocator = std.testing.allocator;
    var builder = EventBuilder.init(allocator, "a: 1\n", .{});
    defer builder.deinit();

    var event_count: usize = 0;
    while (try builder.next()) |event| {
        defer @constCast(&event).deinit(allocator);
        event_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), event_count);

    // Calling next again should return null
    try std.testing.expectEqual(@as(?stream.JsonStreamEvent, null), try builder.next());
}

// ============================================================================
// toonToJson Tests
// ============================================================================

test "toonToJson empty input" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{}", result);
}

test "toonToJson single primitive - null" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "null");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("null", result);
}

test "toonToJson single primitive - boolean" {
    const allocator = std.testing.allocator;

    const result_true = try toonToJson(allocator, "true");
    defer allocator.free(result_true);
    try std.testing.expectEqualStrings("true", result_true);

    const result_false = try toonToJson(allocator, "false");
    defer allocator.free(result_false);
    try std.testing.expectEqualStrings("false", result_false);
}

test "toonToJson single primitive - number" {
    const allocator = std.testing.allocator;

    const result_int = try toonToJson(allocator, "42");
    defer allocator.free(result_int);
    try std.testing.expectEqualStrings("42", result_int);

    const result_float = try toonToJson(allocator, "3.14");
    defer allocator.free(result_float);
    try std.testing.expectEqualStrings("3.14", result_float);
}

test "toonToJson single primitive - string" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "hello");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "toonToJson simple object" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "name: Alice\nage: 30\n");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", result);
}

test "toonToJson nested object" {
    const allocator = std.testing.allocator;
    const input =
        \\user:
        \\  name: Bob
        \\  age: 25
        \\
    ;
    const result = try toonToJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"user\":{\"name\":\"Bob\",\"age\":25}}", result);
}

test "toonToJson inline array" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "[3]: 1,2,3\n");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[1,2,3]", result);
}

test "toonToJson mixed array" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "[4]: 42,true,null,text\n");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[42,true,null,\"text\"]", result);
}

test "toonToJson tabular array" {
    const allocator = std.testing.allocator;
    const input =
        \\[2]{id,name}:
        \\  1,Alice
        \\  2,Bob
        \\
    ;
    const result = try toonToJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]", result);
}

test "toonToJson string with escapes" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "text: \"hello\\nworld\"\n");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"text\":\"hello\\nworld\"}", result);
}

test "toonToJson string with quotes" {
    const allocator = std.testing.allocator;
    const result = try toonToJson(allocator, "text: \"say \\\"hi\\\"\"\n");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"text\":\"say \\\"hi\\\"\"}", result);
}

test "toonToJson complex nested structure" {
    const allocator = std.testing.allocator;
    const input =
        \\config:
        \\  name: app
        \\  settings:
        \\    debug: true
        \\    port: 8080
        \\  tags[2]: dev,test
        \\
    ;
    const result = try toonToJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\"config\":{\"name\":\"app\",\"settings\":{\"debug\":true,\"port\":8080},\"tags\":[\"dev\",\"test\"]}}",
        result,
    );
}

test "toonToJson list items with objects" {
    const allocator = std.testing.allocator;
    const input =
        \\items[2]:
        \\  - id: 1
        \\    name: first
        \\  - id: 2
        \\    name: second
        \\
    ;
    const result = try toonToJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\"items\":[{\"id\":1,\"name\":\"first\"},{\"id\":2,\"name\":\"second\"}]}",
        result,
    );
}

// ============================================================================
// decodeToWriter Tests
// ============================================================================

test "decodeToWriter simple object" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    try decodeToWriter(buffer.writer(allocator), allocator, "a: 1\n");

    try std.testing.expectEqualStrings("{\"a\":1}", buffer.items);
}

test "decodeToWriter nested structure" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    const input =
        \\outer:
        \\  inner: value
        \\
    ;
    try decodeToWriter(buffer.writer(allocator), allocator, input);

    try std.testing.expectEqualStrings("{\"outer\":{\"inner\":\"value\"}}", buffer.items);
}

test "decodeToWriter with options" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    // Test that strict mode validation works with writer API
    try decodeToWriterWithOptions(buffer.writer(allocator), allocator, "x: 1\n", .{ .strict = true });

    try std.testing.expectEqualStrings("{\"x\":1}", buffer.items);
}

// ============================================================================
// valueToJson Tests
// ============================================================================

test "valueToJson null" {
    const allocator = std.testing.allocator;
    const result = try valueToJson(allocator, .null);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("null", result);
}

test "valueToJson bool" {
    const allocator = std.testing.allocator;

    const true_result = try valueToJson(allocator, .{ .bool = true });
    defer allocator.free(true_result);
    try std.testing.expectEqualStrings("true", true_result);

    const false_result = try valueToJson(allocator, .{ .bool = false });
    defer allocator.free(false_result);
    try std.testing.expectEqualStrings("false", false_result);
}

test "valueToJson number integer" {
    const allocator = std.testing.allocator;

    const result = try valueToJson(allocator, .{ .number = 42 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);

    const neg_result = try valueToJson(allocator, .{ .number = -100 });
    defer allocator.free(neg_result);
    try std.testing.expectEqualStrings("-100", neg_result);
}

test "valueToJson number float" {
    const allocator = std.testing.allocator;

    const result = try valueToJson(allocator, .{ .number = 3.14 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("3.14", result);
}

test "valueToJson number special values become null" {
    const allocator = std.testing.allocator;

    const nan_result = try valueToJson(allocator, .{ .number = std.math.nan(f64) });
    defer allocator.free(nan_result);
    try std.testing.expectEqualStrings("null", nan_result);

    const inf_result = try valueToJson(allocator, .{ .number = std.math.inf(f64) });
    defer allocator.free(inf_result);
    try std.testing.expectEqualStrings("null", inf_result);
}

test "valueToJson string with special chars" {
    const allocator = std.testing.allocator;
    const str = try allocator.dupe(u8, "hello\nworld\t\"test\"");
    var val: value.Value = .{ .string = str };
    defer val.deinit(allocator);

    const result = try valueToJson(allocator, val);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\\nworld\\t\\\"test\\\"\"", result);
}

test "valueToJson empty array" {
    const allocator = std.testing.allocator;

    const result = try valueToJson(allocator, .{ .array = value.Array.init() });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "valueToJson empty object" {
    const allocator = std.testing.allocator;

    const result = try valueToJson(allocator, .{ .object = value.Object.init() });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{}", result);
}

// ============================================================================
// Path Expansion Tests
// ============================================================================

test "expandPaths simple dotted key" {
    const allocator = std.testing.allocator;

    // Build {"a.b.c": 1}
    var builder = value.ObjectBuilder.init(allocator);
    builder.put("a.b.c", .{ .number = 1.0 }) catch unreachable;
    const obj = builder.toOwnedObject();
    defer @constCast(&obj).deinit(allocator);

    var expanded = try expandPaths(allocator, .{ .object = obj });
    defer expanded.deinit(allocator);

    // Should be {"a": {"b": {"c": 1}}}
    const a = expanded.object.get("a").?.object;
    const b = a.get("b").?.object;
    const c = b.get("c");
    try std.testing.expect(c.?.eql(.{ .number = 1.0 }));
}

test "expandPaths preserves plain keys" {
    const allocator = std.testing.allocator;

    var builder = value.ObjectBuilder.init(allocator);
    builder.put("simple", .{ .number = 42.0 }) catch unreachable;
    const obj = builder.toOwnedObject();
    defer @constCast(&obj).deinit(allocator);

    var expanded = try expandPaths(allocator, .{ .object = obj });
    defer expanded.deinit(allocator);

    try std.testing.expect(expanded.object.get("simple").?.eql(.{ .number = 42.0 }));
}

test "expandPaths with array" {
    const allocator = std.testing.allocator;

    // Build [{"a.b": 1}]
    var inner_builder = value.ObjectBuilder.init(allocator);
    inner_builder.put("x.y", .{ .number = 1.0 }) catch unreachable;

    var arr_builder = value.ArrayBuilder.init(allocator);
    arr_builder.append(.{ .object = inner_builder.toOwnedObject() }) catch unreachable;
    const arr = arr_builder.toOwnedArray();
    defer @constCast(&arr).deinit(allocator);

    var expanded = try expandPaths(allocator, .{ .array = arr });
    defer expanded.deinit(allocator);

    const first = expanded.array.get(0).?.object;
    const x = first.get("x").?.object;
    try std.testing.expect(x.get("y").?.eql(.{ .number = 1.0 }));
}

test "decodeWithPathExpansion" {
    const allocator = std.testing.allocator;
    var result = try decodeWithPathExpansion(allocator, "a.b.c: 1\n");
    defer result.deinit(allocator);

    const a = result.object.get("a").?.object;
    const b = a.get("b").?.object;
    try std.testing.expect(b.get("c").?.eql(.{ .number = 1.0 }));
}

test "toonToJsonWithPathExpansion" {
    const allocator = std.testing.allocator;
    const result = try toonToJsonWithPathExpansion(allocator, "a.b: 1\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":1}}", result);
}
