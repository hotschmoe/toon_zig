//! TOON Parser
//!
//! Higher-level parsing for TOON syntax elements including array headers,
//! keys, and primitive tokens. Builds on the scanner to provide structured
//! parsing of TOON documents.
//!
//! The parser is responsible for:
//! - Parsing array headers with count, delimiter, and field list
//! - Parsing and validating keys (quoted and unquoted)
//! - Converting primitive tokens to Value types
//!
//! Reference: SPEC.md Sections 3 (Syntax), 4 (Root Form Detection)

const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const string_utils = @import("shared/string_utils.zig");
const literal_utils = @import("shared/literal_utils.zig");
const validation = @import("shared/validation.zig");
const value = @import("value.zig");
const scanner = @import("scanner.zig");

// ============================================================================
// Parsed Array Header
// ============================================================================

/// Fully parsed array header with all components.
/// Represents the complete structure: `[key][count<delim?>][{fields}]: [inline_values]`
pub const ParsedArrayHeader = struct {
    /// Optional key name (for `key[N]:` form).
    /// Owned by caller - must be freed.
    key: ?[]const u8,

    /// Declared element count.
    count: usize,

    /// Delimiter for this array scope.
    delimiter: constants.Delimiter,

    /// Field names for tabular arrays (for `key[N]{f1,f2}:` form).
    /// Each field is owned by caller - must be freed.
    /// Null if not a tabular array.
    fields: ?[]const []const u8,

    /// Whether this is a tabular array (has fields).
    pub fn isTabular(self: ParsedArrayHeader) bool {
        return self.fields != null;
    }

    /// Free all allocated memory.
    pub fn deinit(self: *ParsedArrayHeader, allocator: Allocator) void {
        if (self.key) |k| {
            allocator.free(k);
        }
        if (self.fields) |fields| {
            for (fields) |field| {
                allocator.free(field);
            }
            allocator.free(fields);
        }
    }
};

// ============================================================================
// Parsed Key
// ============================================================================

/// Result of parsing a key.
pub const ParsedKey = struct {
    /// The key string (unescaped if quoted).
    /// Owned by caller - must be freed.
    value: []const u8,

    /// Whether the original key was quoted.
    was_quoted: bool,

    /// Free allocated memory.
    pub fn deinit(self: *ParsedKey, allocator: Allocator) void {
        allocator.free(self.value);
    }
};

// ============================================================================
// Key Parsing
// ============================================================================

/// Parse a key from raw input.
/// Handles both quoted and unquoted keys.
///
/// Per SPEC.md Section 3.2:
/// - Unquoted keys match: ^[A-Za-z_][A-Za-z0-9_.]*$
/// - Keys not matching this pattern must be quoted
///
/// Returns error if:
/// - Key is empty
/// - Quoted key has invalid syntax
/// - Quoted key has invalid escape sequences
pub fn parseKey(allocator: Allocator, raw: []const u8) errors.Error!ParsedKey {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0) {
        return errors.Error.MissingColon;
    }

    // Check if quoted
    if (trimmed[0] == constants.double_quote) {
        const unquoted = try string_utils.parseQuotedString(allocator, trimmed);
        return .{
            .value = unquoted,
            .was_quoted = true,
        };
    }

    const duped = allocator.dupe(u8, trimmed) catch return errors.Error.OutOfMemory;
    return .{
        .value = duped,
        .was_quoted = false,
    };
}

/// Check if a key should be quoted for output.
/// Uses strict validation per SPEC.md Section 3.2.
pub fn keyRequiresQuoting(key: []const u8) bool {
    return validation.keyNeedsQuoting(key);
}

// ============================================================================
// Primitive Token Parsing
// ============================================================================

/// Parse a primitive token into a Value.
/// Handles null, boolean, number, and string tokens.
///
/// Per SPEC.md Section 2:
/// - null, true, false are keywords
/// - Numbers follow JSON number grammar
/// - Everything else is a string
///
/// If the token is quoted, it's always treated as a string.
/// The `is_quoted` parameter indicates if the token was originally quoted.
pub fn parsePrimitiveToken(allocator: Allocator, token: []const u8, is_quoted: bool) errors.Error!value.Value {
    // Quoted tokens are always strings
    if (is_quoted) {
        const str = allocator.dupe(u8, token) catch return errors.Error.OutOfMemory;
        return .{ .string = str };
    }

    // Empty token is empty string
    if (token.len == 0) {
        const str = allocator.dupe(u8, "") catch return errors.Error.OutOfMemory;
        return .{ .string = str };
    }

    // Check for null
    if (literal_utils.isNullLiteral(token)) {
        return .null;
    }

    // Check for boolean
    if (std.mem.eql(u8, token, constants.true_literal)) {
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, token, constants.false_literal)) {
        return .{ .bool = false };
    }

    // Check for number
    if (literal_utils.isNumericLiteral(token)) {
        const num = std.fmt.parseFloat(f64, token) catch {
            // Valid syntax but can't parse - treat as string
            const str = allocator.dupe(u8, token) catch return errors.Error.OutOfMemory;
            return .{ .string = str };
        };
        // Normalize special values
        if (std.math.isNan(num) or std.math.isInf(num)) {
            return .null;
        }
        // Normalize negative zero
        if (num == 0.0 and std.math.signbit(num)) {
            return .{ .number = 0.0 };
        }
        return .{ .number = num };
    }

    // Everything else is a string
    const str = allocator.dupe(u8, token) catch return errors.Error.OutOfMemory;
    return .{ .string = str };
}

/// Parse a raw value that may be quoted.
/// If quoted, unescapes the content. If not, parses as primitive.
pub fn parseValue(allocator: Allocator, raw: []const u8) errors.Error!value.Value {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0) {
        const str = allocator.dupe(u8, "") catch return errors.Error.OutOfMemory;
        return .{ .string = str };
    }

    // Check if quoted
    if (trimmed[0] == constants.double_quote) {
        const unquoted = try string_utils.parseQuotedString(allocator, trimmed);
        return .{ .string = unquoted };
    }

    // Parse as unquoted primitive
    return parsePrimitiveToken(allocator, trimmed, false);
}

// ============================================================================
// Delimited Values Parsing
// ============================================================================

/// Parse a delimiter-separated list of values.
/// Each value is parsed according to parseValue rules.
/// Quoted values are preserved as strings (not interpreted as primitives).
///
/// Returns owned slice of Values. Caller must free each value and the slice.
pub fn parseDelimitedPrimitives(
    allocator: Allocator,
    content: []const u8,
    delimiter: constants.Delimiter,
) errors.Error![]value.Value {
    if (content.len == 0) {
        return &.{};
    }

    const tokens = try scanner.parseDelimitedTokens(allocator, content, delimiter);
    defer {
        for (tokens) |*t| @constCast(t).deinit(allocator);
        allocator.free(tokens);
    }

    var values: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (values.items) |*v| v.deinit(allocator);
        values.deinit(allocator);
    }

    for (tokens) |token| {
        const parsed = try parsePrimitiveToken(allocator, token.value, token.was_quoted);
        values.append(allocator, parsed) catch return errors.Error.OutOfMemory;
    }

    return values.toOwnedSlice(allocator) catch errors.Error.OutOfMemory;
}

// ============================================================================
// Array Header Line Parsing
// ============================================================================

/// Parse a complete array header line.
/// This is a higher-level function that parses the entire header pattern.
///
/// Pattern: `[key][count<delim?>][{fields}]:`
///
/// Examples:
/// - `[3]:` - root array with 3 elements
/// - `items[5]:` - named array with 5 elements
/// - `users[2]{id,name}:` - tabular array with 2 rows and 2 fields
/// - `data[3|]:` - array with 3 elements using pipe delimiter
pub fn parseArrayHeaderLine(
    allocator: Allocator,
    line: []const u8,
) errors.Error!ParsedArrayHeader {
    // Find the opening bracket
    const bracket_pos = findArrayBracket(line) orelse {
        return errors.Error.MalformedArrayHeader;
    };

    // Parse optional key before bracket
    var key: ?[]const u8 = null;
    if (bracket_pos > 0) {
        const key_part = line[0..bracket_pos];
        const parsed_key = try parseKey(allocator, key_part);
        key = parsed_key.value;
    }
    errdefer if (key) |k| allocator.free(k);

    // Find closing bracket
    const rest = line[bracket_pos + 1 ..];
    const close_bracket = std.mem.indexOfScalar(u8, rest, constants.bracket_close) orelse {
        return errors.Error.MalformedArrayHeader;
    };

    // Parse count and optional delimiter from bracket content
    const bracket_content = rest[0..close_bracket];
    const count_delim = try parseCountAndDelimiter(bracket_content);

    // Check for field list after bracket
    const after_bracket = rest[close_bracket + 1 ..];
    var fields: ?[]const []const u8 = null;
    var fields_end: usize = 0;

    if (after_bracket.len > 0 and after_bracket[0] == constants.brace_open) {
        const field_result = try parseFieldList(allocator, after_bracket[1..], count_delim.delimiter);
        fields = field_result.fields;
        fields_end = field_result.end_pos + 1;
    }
    errdefer if (fields) |f| {
        for (f) |field| allocator.free(field);
        allocator.free(f);
    };

    // Verify colon follows
    const colon_search = after_bracket[fields_end..];
    _ = std.mem.indexOfScalar(u8, colon_search, constants.colon) orelse {
        return errors.Error.MalformedArrayHeader;
    };

    return .{
        .key = key,
        .count = count_delim.count,
        .delimiter = count_delim.delimiter,
        .fields = fields,
    };
}

/// Find the opening bracket of an array header.
/// Handles quoted keys that may contain brackets.
fn findArrayBracket(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == constants.double_quote) {
            // Skip quoted string
            const quote_result = string_utils.findClosingQuote(content[i + 1 ..]);
            switch (quote_result) {
                .found => |pos| {
                    i += pos + 2;
                },
                else => return null,
            }
        } else if (c == constants.bracket_open) {
            return i;
        } else if (c == constants.colon) {
            // Found colon before bracket - not an array header
            return null;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Result of parsing count and delimiter.
const CountDelimiter = struct {
    count: usize,
    delimiter: constants.Delimiter,
};

/// Parse count and optional delimiter from bracket content.
/// Format: N or N| or N\t
fn parseCountAndDelimiter(content: []const u8) errors.Error!CountDelimiter {
    if (content.len == 0) return errors.Error.MalformedArrayHeader;

    // Find where the count ends
    var count_end: usize = 0;
    while (count_end < content.len and constants.isDigit(content[count_end])) {
        count_end += 1;
    }

    if (count_end == 0) return errors.Error.MalformedArrayHeader;

    // Validate count (no leading zeros except for "0")
    const count_str = content[0..count_end];
    if (!validation.isValidArrayCount(count_str)) {
        return errors.Error.MalformedArrayHeader;
    }

    const count = std.fmt.parseInt(usize, count_str, 10) catch {
        return errors.Error.MalformedArrayHeader;
    };

    // Parse optional delimiter
    const delimiter: constants.Delimiter = if (count_end >= content.len)
        constants.default_delimiter
    else switch (content[count_end]) {
        '|' => .pipe,
        '\t' => .tab,
        else => return errors.Error.MalformedArrayHeader,
    };

    return .{ .count = count, .delimiter = delimiter };
}

/// Result of parsing a field list.
const FieldListResult = struct {
    fields: []const []const u8,
    end_pos: usize,
};

/// Parse field list from inside braces.
fn parseFieldList(
    allocator: Allocator,
    content: []const u8,
    delimiter: constants.Delimiter,
) errors.Error!FieldListResult {
    const close_brace = std.mem.indexOfScalar(u8, content, constants.brace_close) orelse {
        return errors.Error.MalformedArrayHeader;
    };

    const field_content = content[0..close_brace];
    const fields = try scanner.parseDelimitedValues(allocator, field_content, delimiter);

    return .{ .fields = fields, .end_pos = close_brace + 1 };
}

// ============================================================================
// Root Form Detection
// ============================================================================

/// Detected root form of a TOON document.
pub const RootForm = enum {
    /// Root is an array (starts with array header).
    array,
    /// Root is an object (key-value pairs).
    object,
    /// Root is a single primitive value.
    primitive,
    /// Document is empty.
    empty,
};

/// Detect the root form of a TOON document.
/// Per SPEC.md Section 4.
pub fn detectRootForm(first_line: ?scanner.ScannedLine) RootForm {
    const line = first_line orelse return .empty;
    if (line.depth != 0) return .object;

    return switch (line.line_type) {
        .blank => .empty,
        .array_header => blk: {
            // Root array only if no key: `[N]:` not `key[N]:`
            if (line.array_header) |header| {
                if (header.key != null) break :blk .object;
            }
            break :blk .array;
        },
        .key_value, .list_item => .object,
        .tabular_row => .primitive,
        .comment => .object,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseKey - unquoted valid key" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "name");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("name", result.value);
    try std.testing.expect(!result.was_quoted);
}

test "parseKey - unquoted key with underscores" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "user_name_123");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("user_name_123", result.value);
    try std.testing.expect(!result.was_quoted);
}

test "parseKey - unquoted key with dots" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "config.database.host");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("config.database.host", result.value);
    try std.testing.expect(!result.was_quoted);
}

test "parseKey - quoted simple key" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "\"special-key\"");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("special-key", result.value);
    try std.testing.expect(result.was_quoted);
}

test "parseKey - quoted key with escapes" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "\"key\\nwith\\nnewlines\"");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("key\nwith\nnewlines", result.value);
    try std.testing.expect(result.was_quoted);
}

test "parseKey - quoted key with colon" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "\"key:with:colons\"");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("key:with:colons", result.value);
    try std.testing.expect(result.was_quoted);
}

test "parseKey - trimmed whitespace" {
    const allocator = std.testing.allocator;
    var result = try parseKey(allocator, "  name  ");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("name", result.value);
}

test "parseKey - empty key error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.MissingColon, parseKey(allocator, ""));
    try std.testing.expectError(errors.Error.MissingColon, parseKey(allocator, "   "));
}

test "keyRequiresQuoting - valid unquoted keys" {
    try std.testing.expect(!keyRequiresQuoting("name"));
    try std.testing.expect(!keyRequiresQuoting("user_id"));
    try std.testing.expect(!keyRequiresQuoting("Config.Host"));
    try std.testing.expect(!keyRequiresQuoting("_private"));
}

test "keyRequiresQuoting - needs quoting" {
    try std.testing.expect(keyRequiresQuoting("special-key"));
    try std.testing.expect(keyRequiresQuoting("123numeric"));
    try std.testing.expect(keyRequiresQuoting("has space"));
    try std.testing.expect(keyRequiresQuoting(""));
    try std.testing.expect(keyRequiresQuoting("key:colon"));
}

test "parsePrimitiveToken - null" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "null", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.null));
}

test "parsePrimitiveToken - true" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "true", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .bool = true }));
}

test "parsePrimitiveToken - false" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "false", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .bool = false }));
}

test "parsePrimitiveToken - integer" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "42", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .number = 42.0 }));
}

test "parsePrimitiveToken - negative number" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "-123", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .number = -123.0 }));
}

test "parsePrimitiveToken - decimal" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "3.14159", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(f64, 3.14159), result.number);
}

test "parsePrimitiveToken - exponent" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "1e6", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .number = 1000000.0 }));
}

test "parsePrimitiveToken - string" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "hello", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "hello" }));
}

test "parsePrimitiveToken - quoted string treated as string" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "true", true);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "true" }));
}

test "parsePrimitiveToken - leading zeros treated as string" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "007", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "007" }));
}

test "parsePrimitiveToken - empty" {
    const allocator = std.testing.allocator;
    var result = try parsePrimitiveToken(allocator, "", false);
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "" }));
}

test "parseValue - unquoted primitive" {
    const allocator = std.testing.allocator;
    var result = try parseValue(allocator, "42");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .number = 42.0 }));
}

test "parseValue - quoted string" {
    const allocator = std.testing.allocator;
    var result = try parseValue(allocator, "\"hello world\"");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "hello world" }));
}

test "parseValue - quoted with escapes" {
    const allocator = std.testing.allocator;
    var result = try parseValue(allocator, "\"line1\\nline2\"");
    defer result.deinit(allocator);

    try std.testing.expect(result.eql(.{ .string = "line1\nline2" }));
}

test "parseDelimitedPrimitives - comma separated numbers" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "1,2,3", .comma);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expect(values[0].eql(.{ .number = 1.0 }));
    try std.testing.expect(values[1].eql(.{ .number = 2.0 }));
    try std.testing.expect(values[2].eql(.{ .number = 3.0 }));
}

test "parseDelimitedPrimitives - mixed types" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "42,true,hello", .comma);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expect(values[0].eql(.{ .number = 42.0 }));
    try std.testing.expect(values[1].eql(.{ .bool = true }));
    try std.testing.expect(values[2].eql(.{ .string = "hello" }));
}

test "parseDelimitedPrimitives - pipe separator" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "a|b|c", .pipe);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expect(values[0].eql(.{ .string = "a" }));
    try std.testing.expect(values[1].eql(.{ .string = "b" }));
    try std.testing.expect(values[2].eql(.{ .string = "c" }));
}

test "parseDelimitedPrimitives - empty" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "", .comma);
    defer allocator.free(values);

    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "parseDelimitedPrimitives - quoted number stays string" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "\"123\",456", .comma);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 2), values.len);
    // "123" should remain a string because it was quoted
    try std.testing.expect(values[0].eql(.{ .string = "123" }));
    // 456 should be parsed as a number
    try std.testing.expect(values[1].eql(.{ .number = 456.0 }));
}

test "parseDelimitedPrimitives - quoted boolean stays string" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "\"true\",false", .comma);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 2), values.len);
    // "true" should remain a string because it was quoted
    try std.testing.expect(values[0].eql(.{ .string = "true" }));
    // false should be parsed as boolean
    try std.testing.expect(values[1].eql(.{ .bool = false }));
}

test "parseDelimitedPrimitives - quoted null stays string" {
    const allocator = std.testing.allocator;
    const values = try parseDelimitedPrimitives(allocator, "\"null\",null", .comma);
    defer {
        for (values) |*v| v.deinit(allocator);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 2), values.len);
    // "null" should remain a string because it was quoted
    try std.testing.expect(values[0].eql(.{ .string = "null" }));
    // null should be parsed as null
    try std.testing.expect(values[1].eql(.null));
}

test "parseArrayHeaderLine - simple" {
    const allocator = std.testing.allocator;
    var result = try parseArrayHeaderLine(allocator, "[3]:");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), result.key);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(constants.Delimiter.comma, result.delimiter);
    try std.testing.expectEqual(@as(?[]const []const u8, null), result.fields);
}

test "parseArrayHeaderLine - with key" {
    const allocator = std.testing.allocator;
    var result = try parseArrayHeaderLine(allocator, "items[5]:");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("items", result.key.?);
    try std.testing.expectEqual(@as(usize, 5), result.count);
    try std.testing.expect(!result.isTabular());
}

test "parseArrayHeaderLine - with pipe delimiter" {
    const allocator = std.testing.allocator;
    var result = try parseArrayHeaderLine(allocator, "data[3|]:");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(constants.Delimiter.pipe, result.delimiter);
}

test "parseArrayHeaderLine - with fields (tabular)" {
    const allocator = std.testing.allocator;
    var result = try parseArrayHeaderLine(allocator, "users[2]{id,name}:");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("users", result.key.?);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expect(result.isTabular());
    try std.testing.expectEqual(@as(usize, 2), result.fields.?.len);
    try std.testing.expectEqualStrings("id", result.fields.?[0]);
    try std.testing.expectEqualStrings("name", result.fields.?[1]);
}

test "parseArrayHeaderLine - complex tabular" {
    const allocator = std.testing.allocator;
    var result = try parseArrayHeaderLine(allocator, "records[100]{a,b,c,d}:");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("records", result.key.?);
    try std.testing.expectEqual(@as(usize, 100), result.count);
    try std.testing.expectEqual(@as(usize, 4), result.fields.?.len);
}

test "parseArrayHeaderLine - invalid missing bracket" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.MalformedArrayHeader, parseArrayHeaderLine(allocator, "items:"));
}

test "parseArrayHeaderLine - invalid missing colon" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.MalformedArrayHeader, parseArrayHeaderLine(allocator, "[3]"));
}

test "parseArrayHeaderLine - invalid leading zero" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.MalformedArrayHeader, parseArrayHeaderLine(allocator, "[007]:"));
}

test "detectRootForm - empty" {
    try std.testing.expectEqual(RootForm.empty, detectRootForm(null));
}

test "detectRootForm - array" {
    const line = scanner.ScannedLine{
        .line_type = .array_header,
        .depth = 0,
        .content = "[3]:",
        .key = null,
        .value = null,
        .array_header = null,
        .line_number = 1,
        .raw_line = "[3]:",
    };
    try std.testing.expectEqual(RootForm.array, detectRootForm(line));
}

test "detectRootForm - object" {
    const line = scanner.ScannedLine{
        .line_type = .key_value,
        .depth = 0,
        .content = "name: value",
        .key = null,
        .value = null,
        .array_header = null,
        .line_number = 1,
        .raw_line = "name: value",
    };
    try std.testing.expectEqual(RootForm.object, detectRootForm(line));
}

test "detectRootForm - primitive" {
    const line = scanner.ScannedLine{
        .line_type = .tabular_row,
        .depth = 0,
        .content = "42",
        .key = null,
        .value = null,
        .array_header = null,
        .line_number = 1,
        .raw_line = "42",
    };
    try std.testing.expectEqual(RootForm.primitive, detectRootForm(line));
}

test "detectRootForm - blank line is empty" {
    const line = scanner.ScannedLine{
        .line_type = .blank,
        .depth = 0,
        .content = "",
        .key = null,
        .value = null,
        .array_header = null,
        .line_number = 1,
        .raw_line = "",
    };
    try std.testing.expectEqual(RootForm.empty, detectRootForm(line));
}
