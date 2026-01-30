//! TOON Encoder
//!
//! Encoding primitives and normalization for TOON format.
//! Per SPEC.md Section 2.1, numbers must be in canonical form.
//!
//! Canonical Form Requirements:
//! - No exponent notation: 1e6 -> 1000000
//! - No leading zeros (invalid as number, treated as string)
//! - No trailing fractional zeros: 1.5000 -> 1.5
//! - Integer form when fractional part is zero: 1.0 -> 1
//! - Negative zero normalizes: -0 -> 0
//! - NaN and Infinity encode as null

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const constants = @import("constants.zig");
const string_utils = @import("shared/string_utils.zig");
const validation = @import("shared/validation.zig");

// ============================================================================
// Number Normalization
// ============================================================================

/// Maximum safe integer that can be represented exactly in f64.
/// Beyond this, precision loss occurs.
const max_safe_integer: f64 = 9007199254740992.0; // 2^53

/// Format a number in canonical TOON form.
/// Per SPEC.md Section 2.1:
/// - NaN/Infinity -> returns null (caller should handle)
/// - -0 -> "0"
/// - Integer values -> no decimal point
/// - Fractional values -> minimal representation, no trailing zeros
///
/// Returns null if the number should be encoded as null (NaN/Inf).
pub fn formatNumber(allocator: Allocator, n: f64) Allocator.Error!?[]u8 {
    // NaN and Infinity encode as null per spec
    if (std.math.isNan(n) or std.math.isInf(n)) {
        return null;
    }

    // Normalize negative zero to positive zero
    const num = if (n == 0.0 and std.math.signbit(n)) 0.0 else n;

    // Check if it's an integer value (no fractional part)
    if (@floor(num) == num and @abs(num) < max_safe_integer) {
        // Format as integer (no decimal point)
        const int_val: i64 = @intFromFloat(num);
        return try std.fmt.allocPrint(allocator, "{d}", .{int_val});
    }

    // Format as decimal - use Zig's default formatting which handles
    // precision well, then clean up any trailing zeros
    const formatted = try std.fmt.allocPrint(allocator, "{d}", .{num});

    // Find and remove trailing zeros after decimal point
    const cleaned = try removeTrailingZeros(allocator, formatted);
    allocator.free(formatted);

    return cleaned;
}

/// Remove trailing zeros after the decimal point.
/// "1.5000" -> "1.5"
/// "1.0" -> "1" (remove decimal point too if only zeros follow)
/// "1.5" -> "1.5" (no change)
/// "100" -> "100" (no decimal, no change)
fn removeTrailingZeros(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    // Check for exponent - if present, expand it first (per spec, no exponent notation)
    if (std.mem.indexOfAny(u8, s, "eE") != null) {
        return expandExponent(allocator, s);
    }

    return stripTrailingDecimalZeros(allocator, s);
}

/// Strip trailing zeros from a decimal string (no exponent handling).
fn stripTrailingDecimalZeros(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const dot_pos = std.mem.indexOfScalar(u8, s, '.') orelse {
        return allocator.dupe(u8, s);
    };

    var end = s.len;
    while (end > dot_pos + 1 and s[end - 1] == '0') {
        end -= 1;
    }

    // Remove decimal point too if only zeros followed it
    if (end == dot_pos + 1) {
        end = dot_pos;
    }

    return allocator.dupe(u8, s[0..end]);
}

/// Expand exponent notation to decimal form.
/// "1e6" -> "1000000"
/// "1.5e3" -> "1500"
/// "1e-3" -> "0.001"
fn expandExponent(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    // Parse the number and reformat without exponent
    const num = std.fmt.parseFloat(f64, s) catch {
        return allocator.dupe(u8, s);
    };

    // Check if it's an integer
    if (@floor(num) == num and @abs(num) < max_safe_integer) {
        const int_val: i64 = @intFromFloat(num);
        return try std.fmt.allocPrint(allocator, "{d}", .{int_val});
    }

    // For fractional results, format with full precision
    // then remove trailing zeros
    return try formatDecimalExpanded(allocator, num);
}

/// Format a decimal number without exponent notation.
fn formatDecimalExpanded(allocator: Allocator, n: f64) Allocator.Error![]u8 {
    var buf: [350]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:.17}", .{n}) catch {
        return std.fmt.allocPrint(allocator, "{d}", .{n});
    };
    return stripTrailingDecimalZeros(allocator, formatted);
}

// ============================================================================
// Value Normalization
// ============================================================================

/// Normalize a Value for encoding.
/// Returns a new Value with normalized numbers.
/// Caller owns the returned value.
///
/// Per SPEC.md Section 2.1:
/// - NaN/Infinity become null
/// - -0 becomes 0
pub fn normalizeValue(allocator: Allocator, val: value.Value) Allocator.Error!value.Value {
    return switch (val) {
        .null, .bool, .string => val.clone(allocator),
        .number => |n| normalizeNumber(n),
        .array => |arr| {
            var builder = value.ArrayBuilder.init(allocator);
            errdefer builder.deinit();
            for (arr.items) |item| {
                try builder.append(try normalizeValue(allocator, item));
            }
            return .{ .array = builder.toOwnedArray() };
        },
        .object => |obj| {
            var builder = value.ObjectBuilder.init(allocator);
            errdefer builder.deinit();
            for (obj.entries) |entry| {
                var normalized = try normalizeValue(allocator, entry.value);
                errdefer normalized.deinit(allocator);
                try builder.put(entry.key, normalized);
            }
            return .{ .object = builder.toOwnedObject() };
        },
    };
}

/// Normalize a number value.
/// NaN/Infinity -> null, -0 -> 0
fn normalizeNumber(n: f64) value.Value {
    if (std.math.isNan(n) or std.math.isInf(n)) {
        return .null;
    }
    if (n == 0.0 and std.math.signbit(n)) {
        return .{ .number = 0.0 };
    }
    return .{ .number = n };
}

/// Check if a number is in canonical form when represented as a string.
/// Used to determine if a string should be quoted to avoid number interpretation.
pub fn isCanonicalNumber(s: []const u8) bool {
    // Empty string is not a number
    if (s.len == 0) return false;

    // Try to parse as f64
    const n = std.fmt.parseFloat(f64, s) catch return false;

    // NaN/Infinity strings are not canonical numbers
    if (std.math.isNan(n) or std.math.isInf(n)) return false;

    // Check for leading zeros (except "0" and "0.xxx")
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i < s.len and s[i] == '0' and i + 1 < s.len and s[i + 1] != '.') {
        return false; // Leading zero like "007"
    }

    return true;
}

// ============================================================================
// Primitive Encoding
// ============================================================================

/// Encode options for primitive values.
pub const EncodeOptions = struct {
    /// Active delimiter (affects quoting decisions for string values)
    delimiter: constants.Delimiter = constants.default_delimiter,
};

/// Encodes a primitive Value to its TOON string representation.
/// Returns a newly allocated string that the caller must free.
///
/// Per SPEC.md:
/// - null -> "null"
/// - bool -> "true" or "false"
/// - number -> canonical form (via formatNumber), NaN/Infinity -> "null"
/// - string -> quoted if needed, otherwise unquoted
///
/// Returns error if value is not a primitive (array/object).
pub fn encodePrimitive(allocator: Allocator, val: value.Value, options: EncodeOptions) ![]u8 {
    return switch (val) {
        .null => allocator.dupe(u8, constants.null_literal),
        .bool => |b| allocator.dupe(u8, if (b) constants.true_literal else constants.false_literal),
        .number => |n| encodeNumber(allocator, n),
        .string => |s| encodeString(allocator, s, options.delimiter),
        .array, .object => error.InvalidJson,
    };
}

/// Encodes a number to its canonical TOON representation.
/// NaN/Infinity becomes "null".
fn encodeNumber(allocator: Allocator, n: f64) Allocator.Error![]u8 {
    if (formatNumber(allocator, n)) |maybe_str| {
        return maybe_str orelse allocator.dupe(u8, constants.null_literal);
    } else |err| {
        return err;
    }
}

/// Encodes a string value, quoting if necessary.
/// Per SPEC.md Section 3.5, strings need quoting when they:
/// - Contain the active delimiter
/// - Contain double quotes or backslashes
/// - Have leading/trailing whitespace
/// - Look like a number, boolean, or null
/// - Are empty
/// - Start with '-' (list item marker)
fn encodeString(allocator: Allocator, s: []const u8, delimiter: constants.Delimiter) Allocator.Error![]u8 {
    if (validation.valueNeedsQuoting(s, delimiter)) {
        return string_utils.quoteString(allocator, s);
    }
    return allocator.dupe(u8, s);
}

/// Encodes a key for TOON output.
/// Per SPEC.md Section 3.2, keys matching ^[A-Za-z_][A-Za-z0-9_.]*$ are unquoted.
/// All other keys must be quoted.
pub fn encodeKey(allocator: Allocator, key: []const u8) Allocator.Error![]u8 {
    if (validation.keyNeedsQuoting(key)) {
        return string_utils.quoteString(allocator, key);
    }
    return allocator.dupe(u8, key);
}

/// Writes a primitive value directly to a writer.
/// More efficient than allocating a string first.
pub fn writePrimitive(writer: anytype, val: value.Value, options: EncodeOptions) !void {
    switch (val) {
        .null => try writer.writeAll(constants.null_literal),
        .bool => |b| try writer.writeAll(if (b) constants.true_literal else constants.false_literal),
        .number => |n| try writeNumber(writer, n),
        .string => |s| try writeString(writer, s, options.delimiter),
        .array, .object => return error.InvalidJson,
    }
}

/// Writes a number directly to a writer in canonical form.
fn writeNumber(writer: anytype, n: f64) !void {
    if (std.math.isNan(n) or std.math.isInf(n)) {
        try writer.writeAll(constants.null_literal);
        return;
    }

    const num = if (n == 0.0 and std.math.signbit(n)) 0.0 else n;

    if (@floor(num) == num and @abs(num) < max_safe_integer) {
        const int_val: i64 = @intFromFloat(num);
        try writer.print("{d}", .{int_val});
    } else {
        try writer.print("{d}", .{num});
    }
}

/// Writes a string value directly to a writer, quoting if necessary.
fn writeString(writer: anytype, s: []const u8, delimiter: constants.Delimiter) !void {
    if (validation.valueNeedsQuoting(s, delimiter)) {
        try writer.writeByte(constants.double_quote);
        for (s) |c| {
            if (constants.escapeChar(c)) |escaped| {
                try writer.writeByte(constants.backslash);
                try writer.writeByte(escaped);
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte(constants.double_quote);
    } else {
        try writer.writeAll(s);
    }
}

/// Writes a key directly to a writer, quoting if necessary.
pub fn writeKey(writer: anytype, key: []const u8) !void {
    if (validation.keyNeedsQuoting(key)) {
        try writer.writeByte(constants.double_quote);
        for (key) |c| {
            if (constants.escapeChar(c)) |escaped| {
                try writer.writeByte(constants.backslash);
                try writer.writeByte(escaped);
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte(constants.double_quote);
    } else {
        try writer.writeAll(key);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "formatNumber integer values" {
    const allocator = std.testing.allocator;

    // Basic integers
    const zero = (try formatNumber(allocator, 0.0)).?;
    defer allocator.free(zero);
    try std.testing.expectEqualStrings("0", zero);

    const one = (try formatNumber(allocator, 1.0)).?;
    defer allocator.free(one);
    try std.testing.expectEqualStrings("1", one);

    const large = (try formatNumber(allocator, 1000000.0)).?;
    defer allocator.free(large);
    try std.testing.expectEqualStrings("1000000", large);

    const negative = (try formatNumber(allocator, -42.0)).?;
    defer allocator.free(negative);
    try std.testing.expectEqualStrings("-42", negative);
}

test "formatNumber negative zero becomes zero" {
    const allocator = std.testing.allocator;

    const neg_zero = (try formatNumber(allocator, -0.0)).?;
    defer allocator.free(neg_zero);
    try std.testing.expectEqualStrings("0", neg_zero);
}

test "formatNumber NaN returns null" {
    const allocator = std.testing.allocator;
    const result = try formatNumber(allocator, std.math.nan(f64));
    try std.testing.expect(result == null);
}

test "formatNumber Infinity returns null" {
    const allocator = std.testing.allocator;

    const pos_inf = try formatNumber(allocator, std.math.inf(f64));
    try std.testing.expect(pos_inf == null);

    const neg_inf = try formatNumber(allocator, -std.math.inf(f64));
    try std.testing.expect(neg_inf == null);
}

test "formatNumber decimal values no trailing zeros" {
    const allocator = std.testing.allocator;

    const half = (try formatNumber(allocator, 0.5)).?;
    defer allocator.free(half);
    try std.testing.expectEqualStrings("0.5", half);

    const pi = (try formatNumber(allocator, 3.14)).?;
    defer allocator.free(pi);
    try std.testing.expectEqualStrings("3.14", pi);
}

test "formatNumber integer-valued float becomes integer" {
    const allocator = std.testing.allocator;

    const five = (try formatNumber(allocator, 5.0)).?;
    defer allocator.free(five);
    try std.testing.expectEqualStrings("5", five);

    const hundred = (try formatNumber(allocator, 100.0)).?;
    defer allocator.free(hundred);
    try std.testing.expectEqualStrings("100", hundred);
}

test "normalizeNumber NaN becomes null" {
    const result = normalizeNumber(std.math.nan(f64));
    try std.testing.expect(result.eql(.null));
}

test "normalizeNumber Infinity becomes null" {
    const pos = normalizeNumber(std.math.inf(f64));
    try std.testing.expect(pos.eql(.null));

    const neg = normalizeNumber(-std.math.inf(f64));
    try std.testing.expect(neg.eql(.null));
}

test "normalizeNumber negative zero becomes zero" {
    const result = normalizeNumber(-0.0);
    try std.testing.expect(result.number == 0.0);
    try std.testing.expect(!std.math.signbit(result.number));
}

test "normalizeNumber regular values unchanged" {
    const result = normalizeNumber(42.5);
    try std.testing.expect(result.number == 42.5);
}

test "normalizeValue primitives" {
    const allocator = std.testing.allocator;

    var null_val = try normalizeValue(allocator, .null);
    defer null_val.deinit(allocator);
    try std.testing.expect(null_val.eql(.null));

    var bool_val = try normalizeValue(allocator, .{ .bool = true });
    defer bool_val.deinit(allocator);
    try std.testing.expect(bool_val.eql(.{ .bool = true }));
}

test "normalizeValue number normalization" {
    const allocator = std.testing.allocator;

    // NaN becomes null
    var nan_val = try normalizeValue(allocator, .{ .number = std.math.nan(f64) });
    defer nan_val.deinit(allocator);
    try std.testing.expect(nan_val.eql(.null));

    // -0 becomes 0
    var neg_zero = try normalizeValue(allocator, .{ .number = -0.0 });
    defer neg_zero.deinit(allocator);
    try std.testing.expect(neg_zero.number == 0.0);
    try std.testing.expect(!std.math.signbit(neg_zero.number));
}

test "normalizeValue array with NaN" {
    const allocator = std.testing.allocator;

    const items = [_]value.Value{ .{ .number = 1.0 }, .{ .number = std.math.nan(f64) }, .{ .number = 3.0 } };
    var arr = try value.Array.fromSlice(allocator, &items);
    defer arr.deinit(allocator);

    var normalized = try normalizeValue(allocator, .{ .array = arr });
    defer normalized.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), normalized.array.len());
    try std.testing.expect(normalized.array.get(0).?.eql(.{ .number = 1.0 }));
    try std.testing.expect(normalized.array.get(1).?.eql(.null)); // NaN -> null
    try std.testing.expect(normalized.array.get(2).?.eql(.{ .number = 3.0 }));
}

test "normalizeValue nested object" {
    const allocator = std.testing.allocator;

    const entries = [_]value.Object.Entry{
        .{ .key = "inf", .value = .{ .number = std.math.inf(f64) } },
        .{ .key = "normal", .value = .{ .number = 42.0 } },
    };
    var obj = try value.Object.fromSlice(allocator, &entries);
    defer obj.deinit(allocator);

    var normalized = try normalizeValue(allocator, .{ .object = obj });
    defer normalized.deinit(allocator);

    try std.testing.expect(normalized.object.get("inf").?.eql(.null)); // Inf -> null
    try std.testing.expect(normalized.object.get("normal").?.eql(.{ .number = 42.0 }));
}

test "isCanonicalNumber valid numbers" {
    try std.testing.expect(isCanonicalNumber("0"));
    try std.testing.expect(isCanonicalNumber("1"));
    try std.testing.expect(isCanonicalNumber("42"));
    try std.testing.expect(isCanonicalNumber("-1"));
    try std.testing.expect(isCanonicalNumber("3.14"));
    try std.testing.expect(isCanonicalNumber("-0.5"));
    try std.testing.expect(isCanonicalNumber("0.001"));
}

test "isCanonicalNumber invalid - leading zeros" {
    try std.testing.expect(!isCanonicalNumber("007"));
    try std.testing.expect(!isCanonicalNumber("00"));
    try std.testing.expect(!isCanonicalNumber("-007"));
}

test "isCanonicalNumber invalid - not numbers" {
    try std.testing.expect(!isCanonicalNumber(""));
    try std.testing.expect(!isCanonicalNumber("abc"));
    try std.testing.expect(!isCanonicalNumber("12abc"));
}

test "removeTrailingZeros" {
    const allocator = std.testing.allocator;

    const r1 = try removeTrailingZeros(allocator, "1.5000");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("1.5", r1);

    const r2 = try removeTrailingZeros(allocator, "1.0");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("1", r2);

    const r3 = try removeTrailingZeros(allocator, "100");
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("100", r3);

    const r4 = try removeTrailingZeros(allocator, "3.14");
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("3.14", r4);
}

// ============================================================================
// Encoder Primitive Tests
// ============================================================================

test "encodePrimitive null" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .null, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encodePrimitive bool true" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .bool = true }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("true", result);
}

test "encodePrimitive bool false" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .bool = false }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("false", result);
}

test "encodePrimitive number integer" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .number = 42.0 }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "encodePrimitive number decimal" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .number = 3.14 }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("3.14", result);
}

test "encodePrimitive number NaN becomes null" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .number = std.math.nan(f64) }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encodePrimitive number Infinity becomes null" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .number = std.math.inf(f64) }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encodePrimitive number negative zero becomes zero" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .number = -0.0 }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "encodePrimitive string unquoted" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "hello" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "encodePrimitive string quoted - empty" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"\"", result);
}

test "encodePrimitive string quoted - looks like null" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "null" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"null\"", result);
}

test "encodePrimitive string quoted - looks like number" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "123" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"123\"", result);
}

test "encodePrimitive string quoted - contains delimiter" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "a,b" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"a,b\"", result);
}

test "encodePrimitive string quoted - contains escape chars" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "line1\nline2" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"line1\\nline2\"", result);
}

test "encodePrimitive string quoted - leading whitespace" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = " leading" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\" leading\"", result);
}

test "encodePrimitive string quoted - starts with hyphen" {
    const allocator = std.testing.allocator;
    const result = try encodePrimitive(allocator, .{ .string = "-item" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"-item\"", result);
}

test "encodePrimitive string with pipe delimiter" {
    const allocator = std.testing.allocator;
    const opts = EncodeOptions{ .delimiter = .pipe };

    // Comma is allowed with pipe delimiter
    const with_comma = try encodePrimitive(allocator, .{ .string = "a,b" }, opts);
    defer allocator.free(with_comma);
    try std.testing.expectEqualStrings("a,b", with_comma);

    // Pipe requires quoting
    const with_pipe = try encodePrimitive(allocator, .{ .string = "a|b" }, opts);
    defer allocator.free(with_pipe);
    try std.testing.expectEqualStrings("\"a|b\"", with_pipe);
}

test "encodeKey unquoted" {
    const allocator = std.testing.allocator;

    const simple = try encodeKey(allocator, "name");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("name", simple);

    const underscore = try encodeKey(allocator, "_private");
    defer allocator.free(underscore);
    try std.testing.expectEqualStrings("_private", underscore);

    const dotted = try encodeKey(allocator, "config.host");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("config.host", dotted);
}

test "encodeKey quoted" {
    const allocator = std.testing.allocator;

    const numeric = try encodeKey(allocator, "123");
    defer allocator.free(numeric);
    try std.testing.expectEqualStrings("\"123\"", numeric);

    const hyphen = try encodeKey(allocator, "special-key");
    defer allocator.free(hyphen);
    try std.testing.expectEqualStrings("\"special-key\"", hyphen);

    const space = try encodeKey(allocator, "has space");
    defer allocator.free(space);
    try std.testing.expectEqualStrings("\"has space\"", space);

    const empty = try encodeKey(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("\"\"", empty);
}

test "encodeKey with special characters" {
    const allocator = std.testing.allocator;

    const with_newline = try encodeKey(allocator, "key\nvalue");
    defer allocator.free(with_newline);
    try std.testing.expectEqualStrings("\"key\\nvalue\"", with_newline);

    const with_quote = try encodeKey(allocator, "say\"hello\"");
    defer allocator.free(with_quote);
    try std.testing.expectEqualStrings("\"say\\\"hello\\\"\"", with_quote);
}

test "writePrimitive null" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writePrimitive(stream.writer(), .null, .{});
    try std.testing.expectEqualStrings("null", stream.getWritten());
}

test "writePrimitive bool" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writePrimitive(stream.writer(), .{ .bool = true }, .{});
    try std.testing.expectEqualStrings("true", stream.getWritten());

    stream.reset();
    try writePrimitive(stream.writer(), .{ .bool = false }, .{});
    try std.testing.expectEqualStrings("false", stream.getWritten());
}

test "writePrimitive number" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writePrimitive(stream.writer(), .{ .number = 42.0 }, .{});
    try std.testing.expectEqualStrings("42", stream.getWritten());

    stream.reset();
    try writePrimitive(stream.writer(), .{ .number = 3.14 }, .{});
    try std.testing.expectEqualStrings("3.14", stream.getWritten());

    stream.reset();
    try writePrimitive(stream.writer(), .{ .number = std.math.nan(f64) }, .{});
    try std.testing.expectEqualStrings("null", stream.getWritten());
}

test "writePrimitive string" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writePrimitive(stream.writer(), .{ .string = "hello" }, .{});
    try std.testing.expectEqualStrings("hello", stream.getWritten());

    stream.reset();
    try writePrimitive(stream.writer(), .{ .string = "" }, .{});
    try std.testing.expectEqualStrings("\"\"", stream.getWritten());

    stream.reset();
    try writePrimitive(stream.writer(), .{ .string = "true" }, .{});
    try std.testing.expectEqualStrings("\"true\"", stream.getWritten());
}

test "writeKey unquoted" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeKey(stream.writer(), "name");
    try std.testing.expectEqualStrings("name", stream.getWritten());
}

test "writeKey quoted" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeKey(stream.writer(), "123key");
    try std.testing.expectEqualStrings("\"123key\"", stream.getWritten());

    stream.reset();
    try writeKey(stream.writer(), "key\twith\ttabs");
    try std.testing.expectEqualStrings("\"key\\twith\\ttabs\"", stream.getWritten());
}
