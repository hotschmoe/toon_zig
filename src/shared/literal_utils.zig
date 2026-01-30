//! Literal Utilities
//!
//! Functions for recognizing and classifying literal values in TOON.
//! Used by both encoder (quoting decisions) and decoder (value parsing).
//!
//! Reference: SPEC.md Sections 2.1 (numbers), 3.5 (quoting rules)

const std = @import("std");
const constants = @import("../constants.zig");

// ============================================================================
// Boolean and Null Detection
// ============================================================================

/// Returns true if the string is exactly "true", "false", or "null".
/// These are the only valid boolean/null literals in TOON.
pub fn isBooleanOrNullLiteral(s: []const u8) bool {
    return std.mem.eql(u8, s, constants.true_literal) or
        std.mem.eql(u8, s, constants.false_literal) or
        std.mem.eql(u8, s, constants.null_literal);
}

/// Returns true if the string is exactly "true" or "false".
pub fn isBooleanLiteral(s: []const u8) bool {
    return std.mem.eql(u8, s, constants.true_literal) or
        std.mem.eql(u8, s, constants.false_literal);
}

/// Returns true if the string is exactly "null".
pub fn isNullLiteral(s: []const u8) bool {
    return std.mem.eql(u8, s, constants.null_literal);
}

// ============================================================================
// Numeric Literal Detection
// ============================================================================

/// Returns true if the string is a valid numeric literal per TOON spec.
/// This performs strict validation according to JSON number grammar.
///
/// Valid numbers:
///   - Integer: -?[1-9][0-9]* or 0
///   - Decimal: -?[1-9][0-9]*\.[0-9]+ or 0\.[0-9]+
///   - Exponent: <integer or decimal>[eE][+-]?[0-9]+
///
/// Invalid:
///   - Leading zeros: 007 (treated as string)
///   - Standalone minus: -
///   - Trailing decimal: 1.
///   - Leading decimal: .5
pub fn isNumericLiteral(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;

    // Optional leading minus
    if (s[i] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }

    if (s[i] == '0') {
        i += 1;
        // If we have more digits after 0, it's invalid (leading zero)
        if (i < s.len and constants.isDigit(s[i])) {
            return false;
        }
    } else if (constants.isDigit(s[i])) {
        // Non-zero digit followed by more digits
        while (i < s.len and constants.isDigit(s[i])) {
            i += 1;
        }
    } else {
        return false; // Must start with digit
    }

    // Optional fractional part
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or !constants.isDigit(s[i])) {
            return false; // Must have digits after decimal
        }
        while (i < s.len and constants.isDigit(s[i])) {
            i += 1;
        }
    }

    // Optional exponent part
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        // Optional sign
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            i += 1;
        }
        if (i >= s.len or !constants.isDigit(s[i])) {
            return false; // Must have digits after exponent
        }
        while (i < s.len and constants.isDigit(s[i])) {
            i += 1;
        }
    }

    // Must have consumed entire string
    return i == s.len;
}

/// Returns true if the string "looks like" a number and should be quoted
/// to avoid ambiguity. This is less strict than isNumericLiteral - it catches
/// strings that could be misinterpreted as numbers.
///
/// This is used for encoder quoting decisions (SPEC.md Section 3.5):
/// "Quote a string value when it looks like a number..."
///
/// Returns true if the string starts with a digit or minus followed by digit.
pub fn isNumericLike(s: []const u8) bool {
    if (s.len == 0) return false;
    if (constants.isDigit(s[0])) return true;
    return s[0] == '-' and s.len > 1 and constants.isDigit(s[1]);
}

// ============================================================================
// Literal Classification
// ============================================================================

/// Classification of a literal token
pub const LiteralKind = enum {
    null_literal,
    bool_true,
    bool_false,
    number,
    string,
};

/// Classifies a token into its literal kind.
/// Returns .string if the token doesn't match any special literal pattern.
pub fn classifyLiteral(s: []const u8) LiteralKind {
    if (std.mem.eql(u8, s, constants.null_literal)) return .null_literal;
    if (std.mem.eql(u8, s, constants.true_literal)) return .bool_true;
    if (std.mem.eql(u8, s, constants.false_literal)) return .bool_false;
    if (isNumericLiteral(s)) return .number;
    return .string;
}

// ============================================================================
// Tests
// ============================================================================

test "isBooleanOrNullLiteral" {
    try std.testing.expect(isBooleanOrNullLiteral("true"));
    try std.testing.expect(isBooleanOrNullLiteral("false"));
    try std.testing.expect(isBooleanOrNullLiteral("null"));

    try std.testing.expect(!isBooleanOrNullLiteral("True"));
    try std.testing.expect(!isBooleanOrNullLiteral("FALSE"));
    try std.testing.expect(!isBooleanOrNullLiteral("NULL"));
    try std.testing.expect(!isBooleanOrNullLiteral(""));
    try std.testing.expect(!isBooleanOrNullLiteral("truee"));
    try std.testing.expect(!isBooleanOrNullLiteral("tru"));
    try std.testing.expect(!isBooleanOrNullLiteral("nil"));
    try std.testing.expect(!isBooleanOrNullLiteral("0"));
    try std.testing.expect(!isBooleanOrNullLiteral("1"));
}

test "isBooleanLiteral" {
    try std.testing.expect(isBooleanLiteral("true"));
    try std.testing.expect(isBooleanLiteral("false"));
    try std.testing.expect(!isBooleanLiteral("null"));
    try std.testing.expect(!isBooleanLiteral("True"));
}

test "isNullLiteral" {
    try std.testing.expect(isNullLiteral("null"));
    try std.testing.expect(!isNullLiteral("true"));
    try std.testing.expect(!isNullLiteral("false"));
    try std.testing.expect(!isNullLiteral("NULL"));
    try std.testing.expect(!isNullLiteral("nil"));
}

test "isNumericLiteral valid integers" {
    try std.testing.expect(isNumericLiteral("0"));
    try std.testing.expect(isNumericLiteral("1"));
    try std.testing.expect(isNumericLiteral("42"));
    try std.testing.expect(isNumericLiteral("123456789"));
    try std.testing.expect(isNumericLiteral("-1"));
    try std.testing.expect(isNumericLiteral("-42"));
    try std.testing.expect(isNumericLiteral("-123456789"));
}

test "isNumericLiteral valid decimals" {
    try std.testing.expect(isNumericLiteral("0.0"));
    try std.testing.expect(isNumericLiteral("0.5"));
    try std.testing.expect(isNumericLiteral("1.5"));
    try std.testing.expect(isNumericLiteral("3.14159"));
    try std.testing.expect(isNumericLiteral("-0.5"));
    try std.testing.expect(isNumericLiteral("-3.14"));
}

test "isNumericLiteral valid exponents" {
    try std.testing.expect(isNumericLiteral("1e6"));
    try std.testing.expect(isNumericLiteral("1E6"));
    try std.testing.expect(isNumericLiteral("1e+6"));
    try std.testing.expect(isNumericLiteral("1e-6"));
    try std.testing.expect(isNumericLiteral("1.5e10"));
    try std.testing.expect(isNumericLiteral("-1e6"));
    try std.testing.expect(isNumericLiteral("-1.5E-10"));
}

test "isNumericLiteral invalid cases" {
    try std.testing.expect(!isNumericLiteral(""));
    try std.testing.expect(!isNumericLiteral("-"));
    try std.testing.expect(!isNumericLiteral("+1"));
    try std.testing.expect(!isNumericLiteral("007"));
    try std.testing.expect(!isNumericLiteral("00"));
    try std.testing.expect(!isNumericLiteral("-007"));
    try std.testing.expect(!isNumericLiteral("1."));
    try std.testing.expect(!isNumericLiteral(".5"));
    try std.testing.expect(!isNumericLiteral("1e"));
    try std.testing.expect(!isNumericLiteral("1e+"));
    try std.testing.expect(!isNumericLiteral("1e-"));
    try std.testing.expect(!isNumericLiteral("abc"));
    try std.testing.expect(!isNumericLiteral("12abc"));
    try std.testing.expect(!isNumericLiteral("1.2.3"));
    try std.testing.expect(!isNumericLiteral("--1"));
    try std.testing.expect(!isNumericLiteral("1-"));
    try std.testing.expect(!isNumericLiteral("NaN"));
    try std.testing.expect(!isNumericLiteral("Infinity"));
    try std.testing.expect(!isNumericLiteral("-Infinity"));
}

test "isNumericLike" {
    // Things that look like numbers
    try std.testing.expect(isNumericLike("0"));
    try std.testing.expect(isNumericLike("1"));
    try std.testing.expect(isNumericLike("123"));
    try std.testing.expect(isNumericLike("007")); // Looks like a number even though invalid
    try std.testing.expect(isNumericLike("-1"));
    try std.testing.expect(isNumericLike("-0"));
    try std.testing.expect(isNumericLike("1.5"));
    try std.testing.expect(isNumericLike("1e6"));
    try std.testing.expect(isNumericLike("12abc")); // Starts with digit

    // Things that don't look like numbers
    try std.testing.expect(!isNumericLike(""));
    try std.testing.expect(!isNumericLike("-")); // Standalone minus
    try std.testing.expect(!isNumericLike("abc"));
    try std.testing.expect(!isNumericLike("abc123"));
    try std.testing.expect(!isNumericLike(".5")); // Leading decimal
    try std.testing.expect(!isNumericLike("true"));
    try std.testing.expect(!isNumericLike("null"));
}

test "classifyLiteral" {
    try std.testing.expectEqual(LiteralKind.null_literal, classifyLiteral("null"));
    try std.testing.expectEqual(LiteralKind.bool_true, classifyLiteral("true"));
    try std.testing.expectEqual(LiteralKind.bool_false, classifyLiteral("false"));
    try std.testing.expectEqual(LiteralKind.number, classifyLiteral("42"));
    try std.testing.expectEqual(LiteralKind.number, classifyLiteral("-3.14"));
    try std.testing.expectEqual(LiteralKind.number, classifyLiteral("1e6"));
    try std.testing.expectEqual(LiteralKind.string, classifyLiteral("hello"));
    try std.testing.expectEqual(LiteralKind.string, classifyLiteral("007")); // Invalid number -> string
    try std.testing.expectEqual(LiteralKind.string, classifyLiteral(""));
    try std.testing.expectEqual(LiteralKind.string, classifyLiteral("True")); // Case-sensitive
}
