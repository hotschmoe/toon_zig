//! Validation Utilities
//!
//! Functions for validating keys, values, and determining quoting requirements.
//! Used by encoder (quoting decisions) and decoder (key/value validation).
//!
//! Reference: SPEC.md Section 3.2 (Keys), 3.5 (Quoting Rules), 3.6 (Key Folding)

const std = @import("std");
const constants = @import("../constants.zig");
const literal_utils = @import("literal_utils.zig");

// ============================================================================
// Key Validation
// ============================================================================

/// Returns true if the string is a valid unquoted key.
/// Per SPEC.md Section 3.2, unquoted keys must match: ^[A-Za-z_][A-Za-z0-9_.]*$
///
/// Examples:
///   - Valid: "name", "user_id", "Config.Database.Host", "_private"
///   - Invalid: "123numeric", "special-key", "", " spaces"
pub fn isValidUnquotedKey(s: []const u8) bool {
    if (s.len == 0) return false;

    // First character must match [A-Za-z_]
    if (!constants.isKeyStartChar(s[0])) return false;

    // Remaining characters must match [A-Za-z0-9_.]
    for (s[1..]) |c| {
        if (!constants.isKeyChar(c)) return false;
    }

    return true;
}

/// Returns true if the string is a valid identifier segment for key folding.
/// Per SPEC.md Section 3.6, identifier segments must match: ^[A-Za-z_][A-Za-z0-9_]*$
///
/// Note: This is stricter than unquoted keys - no dots allowed.
///
/// Examples:
///   - Valid: "config", "database_host", "_private", "User123"
///   - Invalid: "config.database", "special-key", "", "123start"
pub fn isValidIdentifierSegment(s: []const u8) bool {
    if (s.len == 0) return false;

    // First character must match [A-Za-z_]
    if (!constants.isIdentifierStartChar(s[0])) return false;

    // Remaining characters must match [A-Za-z0-9_] (no dots)
    for (s[1..]) |c| {
        if (!constants.isIdentifierChar(c)) return false;
    }

    return true;
}

/// Returns true if a dotted path contains only valid identifier segments.
/// Used to validate paths for key folding/expansion.
///
/// Examples:
///   - Valid: "config.database.host", "user_profile.settings"
///   - Invalid: "config..host" (empty segment), "config.123.host" (invalid start)
pub fn isValidFoldablePath(s: []const u8) bool {
    if (s.len == 0) return false;

    var iter = std.mem.splitScalar(u8, s, constants.path_separator);
    while (iter.next()) |segment| {
        if (!isValidIdentifierSegment(segment)) return false;
    }

    return true;
}

// ============================================================================
// Value Quoting Requirements
// ============================================================================

/// Returns true if the string value is safe to use unquoted with a specific delimiter.
/// Per SPEC.md Section 3.5, a string must be quoted when it:
/// - Contains the active delimiter
/// - Contains double quotes or backslashes
/// - Has leading/trailing whitespace
/// - Looks like a number, boolean, or null
/// - Is empty string
/// - Starts with '-' (list item marker)
pub fn isSafeUnquotedWithDelimiter(s: []const u8, delimiter: constants.Delimiter) bool {
    return isSafeUnquotedCore(s, delimiter.char());
}

/// Returns true if the string value is "safe" to use unquoted in TOON
/// regardless of which delimiter is active (checks all three delimiters).
/// Use `isSafeUnquotedWithDelimiter` for delimiter-aware checks.
pub fn isSafeUnquoted(s: []const u8) bool {
    return isSafeUnquotedCore(s, null);
}

/// Core implementation for unquoted value safety checks.
/// If delim_char is null, checks against all three delimiter characters.
fn isSafeUnquotedCore(s: []const u8, delim_char: ?u8) bool {
    if (s.len == 0) return false;
    if (s[0] == constants.list_marker) return false;
    if (s[0] == constants.space or s[s.len - 1] == constants.space) return false;

    for (s) |c| {
        if (delim_char) |dc| {
            if (c == dc) return false;
        } else {
            if (c == ',' or c == '|' or c == '\t') return false;
        }
        if (c == constants.double_quote or c == constants.backslash) return false;
        if (c == constants.line_terminator or c == constants.carriage_return) return false;
    }

    if (literal_utils.isBooleanOrNullLiteral(s)) return false;
    if (literal_utils.isNumericLike(s)) return false;

    return true;
}

/// Determines if a key needs quoting.
/// Keys need quoting when they don't match the unquoted key pattern.
pub fn keyNeedsQuoting(key: []const u8) bool {
    return !isValidUnquotedKey(key);
}

/// Determines if a value needs quoting with a specific delimiter.
/// Returns true if the value should be wrapped in double quotes.
pub fn valueNeedsQuoting(value: []const u8, delimiter: constants.Delimiter) bool {
    return !isSafeUnquotedWithDelimiter(value, delimiter);
}

// ============================================================================
// Indentation Validation
// ============================================================================

/// Validates that indentation consists only of spaces (no tabs) and
/// is a valid multiple of the indent size.
/// Per SPEC.md Section 3.1.
///
/// Returns:
/// - .ok with the depth level if valid
/// - .tabs_found if tabs are present in indentation
/// - .invalid_multiple if not a multiple of indent size
pub const IndentValidationResult = union(enum) {
    ok: usize,
    tabs_found: usize,
    invalid_multiple: usize,
};

pub fn validateIndentation(line: []const u8, indent_size: u8) IndentValidationResult {
    var spaces: usize = 0;

    for (line, 0..) |c, i| {
        if (c == constants.space) {
            spaces += 1;
        } else if (c == constants.tab_char) {
            return .{ .tabs_found = i };
        } else {
            break;
        }
    }

    if (spaces == 0) return .{ .ok = 0 };

    if (spaces % indent_size != 0) {
        return .{ .invalid_multiple = spaces };
    }

    return .{ .ok = spaces / indent_size };
}

/// Returns the number of leading spaces in a line.
/// Does not validate - just counts.
pub fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == constants.space) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

// ============================================================================
// Array Header Validation
// ============================================================================

/// Returns true if the character is a valid array count digit.
pub fn isArrayCountChar(c: u8) bool {
    return constants.isDigit(c);
}

/// Validates an array count string (non-negative integer).
/// Returns true if the string represents a valid count (0 or positive integer, no leading zeros except for "0").
pub fn isValidArrayCount(s: []const u8) bool {
    if (s.len == 0) return false;

    // "0" is valid
    if (s.len == 1 and s[0] == '0') return true;

    // Leading zeros are invalid for multi-digit numbers
    if (s[0] == '0') return false;

    // All characters must be digits
    for (s) |c| {
        if (!constants.isDigit(c)) return false;
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "isValidUnquotedKey - valid keys" {
    try std.testing.expect(isValidUnquotedKey("name"));
    try std.testing.expect(isValidUnquotedKey("user_id"));
    try std.testing.expect(isValidUnquotedKey("Config.Database.Host"));
    try std.testing.expect(isValidUnquotedKey("_private"));
    try std.testing.expect(isValidUnquotedKey("A"));
    try std.testing.expect(isValidUnquotedKey("_"));
    try std.testing.expect(isValidUnquotedKey("a1"));
    try std.testing.expect(isValidUnquotedKey("camelCase"));
    try std.testing.expect(isValidUnquotedKey("PascalCase"));
    try std.testing.expect(isValidUnquotedKey("SCREAMING_CASE"));
    try std.testing.expect(isValidUnquotedKey("with.dots.in.it"));
}

test "isValidUnquotedKey - invalid keys" {
    try std.testing.expect(!isValidUnquotedKey(""));
    try std.testing.expect(!isValidUnquotedKey("123numeric"));
    try std.testing.expect(!isValidUnquotedKey("special-key"));
    try std.testing.expect(!isValidUnquotedKey("has space"));
    try std.testing.expect(!isValidUnquotedKey(" leading"));
    try std.testing.expect(!isValidUnquotedKey("trailing "));
    try std.testing.expect(!isValidUnquotedKey("has:colon"));
    try std.testing.expect(!isValidUnquotedKey("has\"quote"));
    try std.testing.expect(!isValidUnquotedKey("0start"));
    try std.testing.expect(!isValidUnquotedKey(".startsdot"));
}

test "isValidIdentifierSegment - valid segments" {
    try std.testing.expect(isValidIdentifierSegment("config"));
    try std.testing.expect(isValidIdentifierSegment("database_host"));
    try std.testing.expect(isValidIdentifierSegment("_private"));
    try std.testing.expect(isValidIdentifierSegment("User123"));
    try std.testing.expect(isValidIdentifierSegment("A"));
    try std.testing.expect(isValidIdentifierSegment("_"));
}

test "isValidIdentifierSegment - invalid segments" {
    try std.testing.expect(!isValidIdentifierSegment(""));
    try std.testing.expect(!isValidIdentifierSegment("config.database"));
    try std.testing.expect(!isValidIdentifierSegment("special-key"));
    try std.testing.expect(!isValidIdentifierSegment("123start"));
    try std.testing.expect(!isValidIdentifierSegment(".start"));
    try std.testing.expect(!isValidIdentifierSegment("has space"));
}

test "isValidFoldablePath - valid paths" {
    try std.testing.expect(isValidFoldablePath("config"));
    try std.testing.expect(isValidFoldablePath("config.database"));
    try std.testing.expect(isValidFoldablePath("config.database.host"));
    try std.testing.expect(isValidFoldablePath("user_profile.settings"));
    try std.testing.expect(isValidFoldablePath("a.b.c.d.e"));
}

test "isValidFoldablePath - invalid paths" {
    try std.testing.expect(!isValidFoldablePath(""));
    try std.testing.expect(!isValidFoldablePath("."));
    try std.testing.expect(!isValidFoldablePath("config..host"));
    try std.testing.expect(!isValidFoldablePath(".config"));
    try std.testing.expect(!isValidFoldablePath("config."));
    try std.testing.expect(!isValidFoldablePath("config.123.host"));
    try std.testing.expect(!isValidFoldablePath("config.special-key.host"));
}

test "isSafeUnquoted - safe values" {
    try std.testing.expect(isSafeUnquoted("hello"));
    try std.testing.expect(isSafeUnquoted("hello_world"));
    try std.testing.expect(isSafeUnquoted("HelloWorld"));
    try std.testing.expect(isSafeUnquoted("some-value"));
    try std.testing.expect(isSafeUnquoted("value:with:colons"));
    try std.testing.expect(isSafeUnquoted("dot.ted.path"));
}

test "isSafeUnquoted - needs quoting" {
    // Empty string
    try std.testing.expect(!isSafeUnquoted(""));
    // Starts with list marker
    try std.testing.expect(!isSafeUnquoted("-item"));
    // Leading/trailing whitespace
    try std.testing.expect(!isSafeUnquoted(" leading"));
    try std.testing.expect(!isSafeUnquoted("trailing "));
    try std.testing.expect(!isSafeUnquoted(" both "));
    // Contains delimiter
    try std.testing.expect(!isSafeUnquoted("has,comma"));
    try std.testing.expect(!isSafeUnquoted("has|pipe"));
    try std.testing.expect(!isSafeUnquoted("has\ttab"));
    // Contains quote or backslash
    try std.testing.expect(!isSafeUnquoted("has\"quote"));
    try std.testing.expect(!isSafeUnquoted("has\\backslash"));
    // Contains newline
    try std.testing.expect(!isSafeUnquoted("line1\nline2"));
    try std.testing.expect(!isSafeUnquoted("line1\rline2"));
    // Looks like literal
    try std.testing.expect(!isSafeUnquoted("true"));
    try std.testing.expect(!isSafeUnquoted("false"));
    try std.testing.expect(!isSafeUnquoted("null"));
    try std.testing.expect(!isSafeUnquoted("123"));
    try std.testing.expect(!isSafeUnquoted("-45"));
    try std.testing.expect(!isSafeUnquoted("3.14"));
    try std.testing.expect(!isSafeUnquoted("007"));
}

test "isSafeUnquotedWithDelimiter - comma delimiter" {
    const comma = constants.Delimiter.comma;
    try std.testing.expect(isSafeUnquotedWithDelimiter("hello", comma));
    try std.testing.expect(isSafeUnquotedWithDelimiter("with|pipe", comma));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("has,comma", comma));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("", comma));
}

test "isSafeUnquotedWithDelimiter - pipe delimiter" {
    const pipe = constants.Delimiter.pipe;
    try std.testing.expect(isSafeUnquotedWithDelimiter("hello", pipe));
    try std.testing.expect(isSafeUnquotedWithDelimiter("with,comma", pipe));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("has|pipe", pipe));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("", pipe));
}

test "isSafeUnquotedWithDelimiter - tab delimiter" {
    const tab = constants.Delimiter.tab;
    try std.testing.expect(isSafeUnquotedWithDelimiter("hello", tab));
    try std.testing.expect(isSafeUnquotedWithDelimiter("with,comma", tab));
    try std.testing.expect(isSafeUnquotedWithDelimiter("with|pipe", tab));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("has\ttab", tab));
    try std.testing.expect(!isSafeUnquotedWithDelimiter("", tab));
}

test "keyNeedsQuoting" {
    try std.testing.expect(!keyNeedsQuoting("name"));
    try std.testing.expect(!keyNeedsQuoting("user_id"));
    try std.testing.expect(!keyNeedsQuoting("Config.Host"));
    try std.testing.expect(keyNeedsQuoting("123numeric"));
    try std.testing.expect(keyNeedsQuoting("special-key"));
    try std.testing.expect(keyNeedsQuoting("has space"));
    try std.testing.expect(keyNeedsQuoting(""));
}

test "valueNeedsQuoting" {
    const comma = constants.Delimiter.comma;
    try std.testing.expect(!valueNeedsQuoting("hello", comma));
    try std.testing.expect(valueNeedsQuoting("", comma));
    try std.testing.expect(valueNeedsQuoting("true", comma));
    try std.testing.expect(valueNeedsQuoting("123", comma));
    try std.testing.expect(valueNeedsQuoting("has,comma", comma));
    try std.testing.expect(!valueNeedsQuoting("has|pipe", comma));
}

test "validateIndentation - valid indentation" {
    try std.testing.expectEqual(IndentValidationResult{ .ok = 0 }, validateIndentation("no indent", 2));
    try std.testing.expectEqual(IndentValidationResult{ .ok = 1 }, validateIndentation("  one level", 2));
    try std.testing.expectEqual(IndentValidationResult{ .ok = 2 }, validateIndentation("    two levels", 2));
    try std.testing.expectEqual(IndentValidationResult{ .ok = 3 }, validateIndentation("      three levels", 2));
    try std.testing.expectEqual(IndentValidationResult{ .ok = 1 }, validateIndentation("    one level (4-space)", 4));
}

test "validateIndentation - tabs not allowed" {
    const result = validateIndentation("\tindented", 2);
    try std.testing.expectEqual(IndentValidationResult{ .tabs_found = 0 }, result);

    const result2 = validateIndentation("  \tmixed", 2);
    try std.testing.expectEqual(IndentValidationResult{ .tabs_found = 2 }, result2);
}

test "validateIndentation - invalid multiple" {
    try std.testing.expectEqual(IndentValidationResult{ .invalid_multiple = 3 }, validateIndentation("   three spaces", 2));
    try std.testing.expectEqual(IndentValidationResult{ .invalid_multiple = 1 }, validateIndentation(" one space", 2));
    try std.testing.expectEqual(IndentValidationResult{ .invalid_multiple = 5 }, validateIndentation("     five spaces", 2));
}

test "countLeadingSpaces" {
    try std.testing.expectEqual(@as(usize, 0), countLeadingSpaces("no spaces"));
    try std.testing.expectEqual(@as(usize, 2), countLeadingSpaces("  two spaces"));
    try std.testing.expectEqual(@as(usize, 4), countLeadingSpaces("    four spaces"));
    try std.testing.expectEqual(@as(usize, 0), countLeadingSpaces("\ttab not space"));
    try std.testing.expectEqual(@as(usize, 0), countLeadingSpaces(""));
    try std.testing.expectEqual(@as(usize, 3), countLeadingSpaces("   "));
}

test "isArrayCountChar" {
    try std.testing.expect(isArrayCountChar('0'));
    try std.testing.expect(isArrayCountChar('5'));
    try std.testing.expect(isArrayCountChar('9'));
    try std.testing.expect(!isArrayCountChar('a'));
    try std.testing.expect(!isArrayCountChar('-'));
    try std.testing.expect(!isArrayCountChar(' '));
}

test "isValidArrayCount - valid counts" {
    try std.testing.expect(isValidArrayCount("0"));
    try std.testing.expect(isValidArrayCount("1"));
    try std.testing.expect(isValidArrayCount("10"));
    try std.testing.expect(isValidArrayCount("123"));
    try std.testing.expect(isValidArrayCount("999"));
}

test "isValidArrayCount - invalid counts" {
    try std.testing.expect(!isValidArrayCount(""));
    try std.testing.expect(!isValidArrayCount("00"));
    try std.testing.expect(!isValidArrayCount("007"));
    try std.testing.expect(!isValidArrayCount("01"));
    try std.testing.expect(!isValidArrayCount("-1"));
    try std.testing.expect(!isValidArrayCount("abc"));
    try std.testing.expect(!isValidArrayCount("12a"));
}
