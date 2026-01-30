//! TOON Value Types
//!
//! Value representation matching the JSON data model as specified in SPEC.md Section 2.
//! Reference: https://github.com/toon-format/spec

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Value Type
// ============================================================================

/// Represents any JSON value that can be encoded to or decoded from TOON.
/// Matches the JSON data model per SPEC.md Section 2:
/// - Primitives: null, bool, number, string
/// - Containers: array, object
pub const Value = union(enum) {
    null,
    bool: bool,
    number: f64,
    string: []const u8,
    array: Array,
    object: Object,

    const Self = @This();

    /// Frees all memory owned by this value.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .number => {},
            .string => |s| allocator.free(s),
            .array => |*arr| arr.deinit(allocator),
            .object => |*obj| obj.deinit(allocator),
        }
    }

    /// Returns true if this value is a primitive (null, bool, number, string).
    pub fn isPrimitive(self: Self) bool {
        return switch (self) {
            .null, .bool, .number, .string => true,
            .array, .object => false,
        };
    }

    /// Returns true if this value is a container (array or object).
    pub fn isContainer(self: Self) bool {
        return !self.isPrimitive();
    }

    /// Deep clone of the value.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        return switch (self) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| .{ .array = try arr.clone(allocator) },
            .object => |obj| .{ .object = try obj.clone(allocator) },
        };
    }

    /// Check equality with another value.
    pub fn eql(self: Self, other: Self) bool {
        const tag_self: std.meta.Tag(Self) = self;
        const tag_other: std.meta.Tag(Self) = other;
        if (tag_self != tag_other) return false;

        return switch (self) {
            .null => true,
            .bool => |b| b == other.bool,
            .number => |n| numberEql(n, other.number),
            .string => |s| std.mem.eql(u8, s, other.string),
            .array => |arr| arr.eql(other.array),
            .object => |obj| obj.eql(other.object),
        };
    }
};

/// Compare two f64 values for equality, handling special cases.
/// Per SPEC.md Section 2.1: NaN and Infinity encode as null.
fn numberEql(a: f64, b: f64) bool {
    // Both NaN are considered equal (both would encode as null)
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    // One NaN, other not -> not equal
    if (std.math.isNan(a) or std.math.isNan(b)) return false;
    // Standard comparison (handles infinity correctly)
    return a == b;
}

// ============================================================================
// Array Type
// ============================================================================

/// Ordered collection of values.
/// Per SPEC.md Section 2: Arrays are ordered and length-declared.
pub const Array = struct {
    items: []Value,

    const Self = @This();

    /// Create an empty array.
    pub fn init() Self {
        return .{ .items = &.{} };
    }

    /// Create an array from a slice, taking ownership.
    pub fn fromOwnedSlice(items: []Value) Self {
        return .{ .items = items };
    }

    /// Create an array by cloning a slice.
    pub fn fromSlice(allocator: Allocator, items: []const Value) Allocator.Error!Self {
        const cloned = try allocator.alloc(Value, items.len);
        errdefer allocator.free(cloned);

        var i: usize = 0;
        errdefer {
            for (cloned[0..i]) |*item| {
                item.deinit(allocator);
            }
        }

        for (items) |item| {
            cloned[i] = try item.clone(allocator);
            i += 1;
        }

        return .{ .items = cloned };
    }

    /// Free all memory owned by this array.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        if (self.items.len > 0) {
            allocator.free(self.items);
        }
        self.items = &.{};
    }

    /// Deep clone of the array.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        return fromSlice(allocator, self.items);
    }

    /// Number of elements.
    pub fn len(self: Self) usize {
        return self.items.len;
    }

    /// Get element at index.
    pub fn get(self: Self, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    /// Check equality with another array.
    pub fn eql(self: Self, other: Self) bool {
        if (self.items.len != other.items.len) return false;
        for (self.items, other.items) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

// ============================================================================
// Object Type
// ============================================================================

/// Key-value pairs with insertion order preserved.
/// Per SPEC.md Section 2: Objects preserve insertion order.
/// Uses an array-based map to maintain order while allowing key lookup.
pub const Object = struct {
    entries: []Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    const Self = @This();

    /// Create an empty object.
    pub fn init() Self {
        return .{ .entries = &.{} };
    }

    /// Create an object from a slice of entries, taking ownership.
    pub fn fromOwnedSlice(entries: []Entry) Self {
        return .{ .entries = entries };
    }

    /// Create an object by cloning a slice of entries.
    pub fn fromSlice(allocator: Allocator, entries: []const Entry) Allocator.Error!Self {
        const cloned = try allocator.alloc(Entry, entries.len);
        errdefer allocator.free(cloned);

        var i: usize = 0;
        errdefer {
            for (cloned[0..i]) |*entry| {
                allocator.free(entry.key);
                entry.value.deinit(allocator);
            }
        }

        for (entries) |entry| {
            cloned[i] = .{
                .key = try allocator.dupe(u8, entry.key),
                .value = try entry.value.clone(allocator),
            };
            i += 1;
        }

        return .{ .entries = cloned };
    }

    /// Free all memory owned by this object.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.entries) |*entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);
        }
        if (self.entries.len > 0) {
            allocator.free(self.entries);
        }
        self.entries = &.{};
    }

    /// Deep clone of the object.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        return fromSlice(allocator, self.entries);
    }

    /// Number of key-value pairs.
    pub fn count(self: Self) usize {
        return self.entries.len;
    }

    /// Get value for a key, or null if not found.
    pub fn get(self: Self, key: []const u8) ?Value {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Check if a key exists.
    pub fn contains(self: Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Get all keys in insertion order.
    pub fn keys(self: Self, allocator: Allocator) Allocator.Error![][]const u8 {
        const result = try allocator.alloc([]const u8, self.entries.len);
        for (self.entries, 0..) |entry, i| {
            result[i] = entry.key;
        }
        return result;
    }

    /// Check equality with another object.
    /// Order matters per SPEC.md (insertion order preserved).
    pub fn eql(self: Self, other: Self) bool {
        if (self.entries.len != other.entries.len) return false;
        for (self.entries, other.entries) |a, b| {
            if (!std.mem.eql(u8, a.key, b.key)) return false;
            if (!a.value.eql(b.value)) return false;
        }
        return true;
    }
};

// ============================================================================
// Builder Types
// ============================================================================

/// Builder for constructing arrays incrementally.
pub const ArrayBuilder = struct {
    items: std.ArrayListUnmanaged(Value),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .items = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    /// Append a value (takes ownership).
    pub fn append(self: *Self, value: Value) Allocator.Error!void {
        try self.items.append(self.allocator, value);
    }

    /// Append a cloned value.
    pub fn appendClone(self: *Self, value: Value) Allocator.Error!void {
        try self.items.append(self.allocator, try value.clone(self.allocator));
    }

    /// Build the final array, transferring ownership.
    pub fn toOwnedArray(self: *Self) Array {
        const slice = self.items.toOwnedSlice(self.allocator) catch unreachable;
        return Array.fromOwnedSlice(slice);
    }
};

/// Builder for constructing objects incrementally.
pub const ObjectBuilder = struct {
    entries: std.ArrayListUnmanaged(Object.Entry),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Put a key-value pair (takes ownership of value, clones key).
    pub fn put(self: *Self, key: []const u8, value: Value) Allocator.Error!void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.entries.append(self.allocator, .{ .key = key_copy, .value = value });
    }

    /// Put a key-value pair (clones both).
    pub fn putClone(self: *Self, key: []const u8, value: Value) Allocator.Error!void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try value.clone(self.allocator);
        errdefer {
            var v = value_copy;
            v.deinit(self.allocator);
        }
        try self.entries.append(self.allocator, .{ .key = key_copy, .value = value_copy });
    }

    /// Build the final object, transferring ownership.
    pub fn toOwnedObject(self: *Self) Object {
        const slice = self.entries.toOwnedSlice(self.allocator) catch unreachable;
        return Object.fromOwnedSlice(slice);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Value null" {
    var v: Value = .null;
    try std.testing.expect(v.isPrimitive());
    try std.testing.expect(!v.isContainer());
    try std.testing.expect(v.eql(.null));
    v.deinit(std.testing.allocator);
}

test "Value bool" {
    const v_true: Value = .{ .bool = true };
    const v_false: Value = .{ .bool = false };

    try std.testing.expect(v_true.isPrimitive());
    try std.testing.expect(v_true.eql(.{ .bool = true }));
    try std.testing.expect(!v_true.eql(.{ .bool = false }));
    try std.testing.expect(v_false.eql(.{ .bool = false }));
}

test "Value number" {
    const v: Value = .{ .number = 42.5 };
    try std.testing.expect(v.isPrimitive());
    try std.testing.expect(v.eql(.{ .number = 42.5 }));
    try std.testing.expect(!v.eql(.{ .number = 42.0 }));
}

test "Value number NaN equality" {
    const nan1: Value = .{ .number = std.math.nan(f64) };
    const nan2: Value = .{ .number = std.math.nan(f64) };
    try std.testing.expect(nan1.eql(nan2));
}

test "Value number infinity" {
    const pos_inf: Value = .{ .number = std.math.inf(f64) };
    const neg_inf: Value = .{ .number = -std.math.inf(f64) };
    try std.testing.expect(pos_inf.eql(.{ .number = std.math.inf(f64) }));
    try std.testing.expect(!pos_inf.eql(neg_inf));
}

test "Value string" {
    const allocator = std.testing.allocator;
    const str = try allocator.dupe(u8, "hello");
    var v: Value = .{ .string = str };
    defer v.deinit(allocator);

    try std.testing.expect(v.isPrimitive());
    try std.testing.expect(v.eql(.{ .string = "hello" }));
    try std.testing.expect(!v.eql(.{ .string = "world" }));
}

test "Value clone string" {
    const allocator = std.testing.allocator;
    const str = try allocator.dupe(u8, "test");
    var original: Value = .{ .string = str };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.string.ptr != cloned.string.ptr);
}

test "Array empty" {
    var arr = Array.init();
    try std.testing.expectEqual(@as(usize, 0), arr.len());
    try std.testing.expectEqual(@as(?Value, null), arr.get(0));
    arr.deinit(std.testing.allocator);
}

test "Array from slice" {
    const allocator = std.testing.allocator;
    const items = [_]Value{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } };
    var arr = try Array.fromSlice(allocator, &items);
    defer arr.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .number = 1 }));
    try std.testing.expect(arr.get(1).?.eql(.{ .number = 2 }));
    try std.testing.expect(arr.get(2).?.eql(.{ .number = 3 }));
    try std.testing.expectEqual(@as(?Value, null), arr.get(3));
}

test "Array equality" {
    const allocator = std.testing.allocator;
    const items1 = [_]Value{ .{ .number = 1 }, .{ .number = 2 } };
    const items2 = [_]Value{ .{ .number = 1 }, .{ .number = 2 } };
    const items3 = [_]Value{ .{ .number = 1 }, .{ .number = 3 } };

    var arr1 = try Array.fromSlice(allocator, &items1);
    defer arr1.deinit(allocator);
    var arr2 = try Array.fromSlice(allocator, &items2);
    defer arr2.deinit(allocator);
    var arr3 = try Array.fromSlice(allocator, &items3);
    defer arr3.deinit(allocator);

    try std.testing.expect(arr1.eql(arr2));
    try std.testing.expect(!arr1.eql(arr3));
}

test "Object empty" {
    var obj = Object.init();
    try std.testing.expectEqual(@as(usize, 0), obj.count());
    try std.testing.expectEqual(@as(?Value, null), obj.get("key"));
    try std.testing.expect(!obj.contains("key"));
    obj.deinit(std.testing.allocator);
}

test "Object from slice" {
    const allocator = std.testing.allocator;
    const entries = [_]Object.Entry{
        .{ .key = "name", .value = .{ .string = "Alice" } },
        .{ .key = "age", .value = .{ .number = 30 } },
    };
    var obj = try Object.fromSlice(allocator, &entries);
    defer obj.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), obj.count());
    try std.testing.expect(obj.contains("name"));
    try std.testing.expect(obj.contains("age"));
    try std.testing.expect(!obj.contains("missing"));
    try std.testing.expect(obj.get("name").?.eql(.{ .string = "Alice" }));
    try std.testing.expect(obj.get("age").?.eql(.{ .number = 30 }));
}

test "Object keys" {
    const allocator = std.testing.allocator;
    const entries = [_]Object.Entry{
        .{ .key = "first", .value = .{ .number = 1 } },
        .{ .key = "second", .value = .{ .number = 2 } },
    };
    var obj = try Object.fromSlice(allocator, &entries);
    defer obj.deinit(allocator);

    const key_list = try obj.keys(allocator);
    defer allocator.free(key_list);

    try std.testing.expectEqual(@as(usize, 2), key_list.len);
    try std.testing.expectEqualStrings("first", key_list[0]);
    try std.testing.expectEqualStrings("second", key_list[1]);
}

test "Object equality preserves order" {
    const allocator = std.testing.allocator;
    const entries1 = [_]Object.Entry{
        .{ .key = "a", .value = .{ .number = 1 } },
        .{ .key = "b", .value = .{ .number = 2 } },
    };
    const entries2 = [_]Object.Entry{
        .{ .key = "b", .value = .{ .number = 2 } },
        .{ .key = "a", .value = .{ .number = 1 } },
    };

    var obj1 = try Object.fromSlice(allocator, &entries1);
    defer obj1.deinit(allocator);
    var obj2 = try Object.fromSlice(allocator, &entries2);
    defer obj2.deinit(allocator);

    try std.testing.expect(!obj1.eql(obj2));
}

test "ArrayBuilder" {
    const allocator = std.testing.allocator;
    var builder = ArrayBuilder.init(allocator);
    defer builder.deinit();

    try builder.append(.{ .number = 1 });
    try builder.append(.{ .number = 2 });
    try builder.append(.{ .number = 3 });

    var arr = builder.toOwnedArray();
    defer arr.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expect(arr.get(0).?.eql(.{ .number = 1 }));
    try std.testing.expect(arr.get(2).?.eql(.{ .number = 3 }));
}

test "ObjectBuilder" {
    const allocator = std.testing.allocator;
    var builder = ObjectBuilder.init(allocator);

    const name_str = try allocator.dupe(u8, "Bob");
    try builder.put("name", .{ .string = name_str });
    try builder.put("active", .{ .bool = true });

    var obj = builder.toOwnedObject();
    defer obj.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), obj.count());
    try std.testing.expect(obj.get("name").?.eql(.{ .string = "Bob" }));
    try std.testing.expect(obj.get("active").?.eql(.{ .bool = true }));
}

test "Value array container" {
    const allocator = std.testing.allocator;
    const items = [_]Value{ .{ .number = 1 }, .null };
    const arr = try Array.fromSlice(allocator, &items);

    var v: Value = .{ .array = arr };
    defer v.deinit(allocator);

    try std.testing.expect(!v.isPrimitive());
    try std.testing.expect(v.isContainer());
}

test "Value object container" {
    const allocator = std.testing.allocator;
    const entries = [_]Object.Entry{
        .{ .key = "x", .value = .{ .number = 10 } },
    };
    const obj = try Object.fromSlice(allocator, &entries);

    var v: Value = .{ .object = obj };
    defer v.deinit(allocator);

    try std.testing.expect(!v.isPrimitive());
    try std.testing.expect(v.isContainer());
}

test "nested value clone" {
    const allocator = std.testing.allocator;

    var inner_builder = ObjectBuilder.init(allocator);
    try inner_builder.put("nested", .{ .bool = true });
    const inner_obj = inner_builder.toOwnedObject();
    inner_builder.deinit();

    var arr_builder = ArrayBuilder.init(allocator);
    try arr_builder.append(.{ .object = inner_obj });
    try arr_builder.append(.{ .number = 42 });
    const arr = arr_builder.toOwnedArray();
    arr_builder.deinit();

    var original: Value = .{ .array = arr };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(original.eql(cloned));
}

test "cross-type inequality" {
    const v_null: Value = .null;
    const v_false: Value = .{ .bool = false };
    const v_zero: Value = .{ .number = 0 };
    const v_str: Value = .{ .string = "0" };

    try std.testing.expect(!v_null.eql(v_false));
    try std.testing.expect(!v_null.eql(v_zero));
    try std.testing.expect(!v_false.eql(v_zero));
    try std.testing.expect(!v_zero.eql(v_str));
}
