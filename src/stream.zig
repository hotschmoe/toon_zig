//! TOON Streaming Types
//!
//! Stream events and options for TOON encoding/decoding.
//! Reference: SPEC.md Sections 5 and 9.2

const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const value = @import("value.zig");

// ============================================================================
// Stream Events
// ============================================================================

/// Events emitted during streaming decode (or consumed during streaming encode).
/// Per SPEC.md Section 9.2: decodeStream returns iterator of JsonStreamEvent.
///
/// Event sequence for structures:
/// - Object: start_object -> (key, value events)* -> end_object
/// - Array: start_array -> (value events)* -> end_array
/// - Primitive: primitive event
pub const JsonStreamEvent = union(enum) {
    /// Start of an object. Count is the number of key-value pairs.
    start_object: ObjectInfo,

    /// End of an object.
    end_object,

    /// Object key. Followed by value event(s).
    key: []const u8,

    /// Start of an array. Count is the number of elements.
    start_array: ArrayInfo,

    /// End of an array.
    end_array,

    /// A primitive value (null, bool, number, or string).
    primitive: value.Value,

    pub const ObjectInfo = struct {
        /// Number of key-value pairs in the object.
        count: usize,
    };

    pub const ArrayInfo = struct {
        /// Number of elements in the array.
        count: usize,
    };

    const Self = @This();

    /// Free any owned memory in this event.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.*) {
            .key => |k| allocator.free(k),
            .primitive => |*p| p.deinit(allocator),
            else => {},
        }
    }

    /// Clone this event, duplicating any owned memory.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        return switch (self) {
            .start_object => |info| .{ .start_object = info },
            .end_object => .end_object,
            .key => |k| .{ .key = try allocator.dupe(u8, k) },
            .start_array => |info| .{ .start_array = info },
            .end_array => .end_array,
            .primitive => |p| .{ .primitive = try p.clone(allocator) },
        };
    }

    /// Check equality with another event.
    pub fn eql(self: Self, other: Self) bool {
        const tag_self: std.meta.Tag(Self) = self;
        const tag_other: std.meta.Tag(Self) = other;
        if (tag_self != tag_other) return false;

        return switch (self) {
            .start_object => |info| info.count == other.start_object.count,
            .end_object => true,
            .key => |k| std.mem.eql(u8, k, other.key),
            .start_array => |info| info.count == other.start_array.count,
            .end_array => true,
            .primitive => |p| p.eql(other.primitive),
        };
    }

    /// Format for debug output.
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .start_object => |info| try writer.print("start_object({d})", .{info.count}),
            .end_object => try writer.writeAll("end_object"),
            .key => |k| try writer.print("key(\"{s}\")", .{k}),
            .start_array => |info| try writer.print("start_array({d})", .{info.count}),
            .end_array => try writer.writeAll("end_array"),
            .primitive => |p| switch (p) {
                .null => try writer.writeAll("primitive(null)"),
                .bool => |b| try writer.print("primitive({s})", .{if (b) "true" else "false"}),
                .number => |n| try writer.print("primitive({d})", .{n}),
                .string => |s| try writer.print("primitive(\"{s}\")", .{s}),
                else => try writer.writeAll("primitive(<container>)"),
            },
        }
    }
};

// ============================================================================
// Encode Options
// ============================================================================

/// Options for TOON encoding.
/// Per SPEC.md Section 5.1.
pub const EncodeOptions = struct {
    /// Spaces per indent level. Default: 2.
    indent: u8 = constants.default_indent_size,

    /// Active delimiter for arrays. Default: comma.
    delimiter: constants.Delimiter = constants.default_delimiter,

    /// Key folding mode. Default: off.
    key_folding: constants.KeyFoldingMode = constants.default_key_folding,

    /// Maximum depth for key folding. Default: unlimited.
    flatten_depth: usize = constants.max_flatten_depth,

    /// Default options.
    pub const default: EncodeOptions = .{};

    /// Create options with key folding enabled.
    pub fn withKeyFolding(key_folding: constants.KeyFoldingMode) EncodeOptions {
        return .{ .key_folding = key_folding };
    }

    /// Create options with custom delimiter.
    pub fn withDelimiter(delimiter: constants.Delimiter) EncodeOptions {
        return .{ .delimiter = delimiter };
    }

    /// Create options with custom indent size.
    pub fn withIndent(indent: u8) EncodeOptions {
        return .{ .indent = indent };
    }
};

// ============================================================================
// Decode Options
// ============================================================================

/// Options for TOON decoding.
/// Per SPEC.md Section 5.2.
pub const DecodeOptions = struct {
    /// Expected indent size. Default: 2.
    indent: u8 = constants.default_indent_size,

    /// Enable strict validation. Default: true.
    /// When true, enforces all SPEC.md Section 7 checks.
    strict: bool = constants.default_strict,

    /// Path expansion mode. Default: off.
    expand_paths: constants.ExpandPathsMode = constants.default_expand_paths,

    /// Default options.
    pub const default: DecodeOptions = .{};

    /// Create options with strict mode disabled (lenient parsing).
    pub fn lenient() DecodeOptions {
        return .{ .strict = false };
    }

    /// Create options with path expansion enabled.
    pub fn withPathExpansion(expand_paths: constants.ExpandPathsMode) DecodeOptions {
        return .{ .expand_paths = expand_paths };
    }

    /// Create options with custom indent size.
    pub fn withIndent(indent: u8) DecodeOptions {
        return .{ .indent = indent };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "JsonStreamEvent start_object" {
    var event: JsonStreamEvent = .{ .start_object = .{ .count = 3 } };
    try std.testing.expect(event.eql(.{ .start_object = .{ .count = 3 } }));
    try std.testing.expect(!event.eql(.{ .start_object = .{ .count = 2 } }));
    try std.testing.expect(!event.eql(.end_object));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent end_object" {
    var event: JsonStreamEvent = .end_object;
    try std.testing.expect(event.eql(.end_object));
    try std.testing.expect(!event.eql(.end_array));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent key" {
    const allocator = std.testing.allocator;
    const key_str = try allocator.dupe(u8, "mykey");
    var event: JsonStreamEvent = .{ .key = key_str };
    defer event.deinit(allocator);

    try std.testing.expect(event.eql(.{ .key = "mykey" }));
    try std.testing.expect(!event.eql(.{ .key = "other" }));
}

test "JsonStreamEvent key clone" {
    const allocator = std.testing.allocator;
    const key_str = try allocator.dupe(u8, "original");
    var original: JsonStreamEvent = .{ .key = key_str };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.key.ptr != cloned.key.ptr);
}

test "JsonStreamEvent start_array" {
    var event: JsonStreamEvent = .{ .start_array = .{ .count = 5 } };
    try std.testing.expect(event.eql(.{ .start_array = .{ .count = 5 } }));
    try std.testing.expect(!event.eql(.{ .start_array = .{ .count = 4 } }));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent primitive null" {
    var event: JsonStreamEvent = .{ .primitive = .null };
    try std.testing.expect(event.eql(.{ .primitive = .null }));
    try std.testing.expect(!event.eql(.{ .primitive = .{ .bool = false } }));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent primitive bool" {
    var event: JsonStreamEvent = .{ .primitive = .{ .bool = true } };
    try std.testing.expect(event.eql(.{ .primitive = .{ .bool = true } }));
    try std.testing.expect(!event.eql(.{ .primitive = .{ .bool = false } }));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent primitive number" {
    var event: JsonStreamEvent = .{ .primitive = .{ .number = 42.5 } };
    try std.testing.expect(event.eql(.{ .primitive = .{ .number = 42.5 } }));
    try std.testing.expect(!event.eql(.{ .primitive = .{ .number = 0 } }));
    event.deinit(std.testing.allocator);
}

test "JsonStreamEvent primitive string" {
    const allocator = std.testing.allocator;
    const str = try allocator.dupe(u8, "hello");
    var event: JsonStreamEvent = .{ .primitive = .{ .string = str } };
    defer event.deinit(allocator);

    try std.testing.expect(event.eql(.{ .primitive = .{ .string = "hello" } }));
    try std.testing.expect(!event.eql(.{ .primitive = .{ .string = "world" } }));
}

test "JsonStreamEvent primitive clone" {
    const allocator = std.testing.allocator;
    const str = try allocator.dupe(u8, "test");
    var original: JsonStreamEvent = .{ .primitive = .{ .string = str } };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.primitive.string.ptr != cloned.primitive.string.ptr);
}

test "JsonStreamEvent format" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const event1: JsonStreamEvent = .{ .start_object = .{ .count = 2 } };
    try event1.format("", .{}, writer);
    try std.testing.expectEqualStrings("start_object(2)", stream.getWritten());

    stream.reset();
    const event2: JsonStreamEvent = .{ .key = "name" };
    try event2.format("", .{}, writer);
    try std.testing.expectEqualStrings("key(\"name\")", stream.getWritten());

    stream.reset();
    const event3: JsonStreamEvent = .{ .primitive = .{ .number = 42 } };
    try event3.format("", .{}, writer);
    try std.testing.expectEqualStrings("primitive(42)", stream.getWritten());
}

test "EncodeOptions default" {
    const opts = EncodeOptions.default;
    try std.testing.expectEqual(@as(u8, 2), opts.indent);
    try std.testing.expectEqual(constants.Delimiter.comma, opts.delimiter);
    try std.testing.expectEqual(constants.KeyFoldingMode.off, opts.key_folding);
    try std.testing.expectEqual(constants.max_flatten_depth, opts.flatten_depth);
}

test "EncodeOptions withKeyFolding" {
    const opts = EncodeOptions.withKeyFolding(.safe);
    try std.testing.expectEqual(constants.KeyFoldingMode.safe, opts.key_folding);
    try std.testing.expectEqual(@as(u8, 2), opts.indent);
}

test "EncodeOptions withDelimiter" {
    const opts = EncodeOptions.withDelimiter(.pipe);
    try std.testing.expectEqual(constants.Delimiter.pipe, opts.delimiter);
}

test "EncodeOptions withIndent" {
    const opts = EncodeOptions.withIndent(4);
    try std.testing.expectEqual(@as(u8, 4), opts.indent);
}

test "DecodeOptions default" {
    const opts = DecodeOptions.default;
    try std.testing.expectEqual(@as(u8, 2), opts.indent);
    try std.testing.expect(opts.strict);
    try std.testing.expectEqual(constants.ExpandPathsMode.off, opts.expand_paths);
}

test "DecodeOptions lenient" {
    const opts = DecodeOptions.lenient();
    try std.testing.expect(!opts.strict);
    try std.testing.expectEqual(@as(u8, 2), opts.indent);
}

test "DecodeOptions withPathExpansion" {
    const opts = DecodeOptions.withPathExpansion(.safe);
    try std.testing.expectEqual(constants.ExpandPathsMode.safe, opts.expand_paths);
    try std.testing.expect(opts.strict);
}

test "DecodeOptions withIndent" {
    const opts = DecodeOptions.withIndent(4);
    try std.testing.expectEqual(@as(u8, 4), opts.indent);
}
