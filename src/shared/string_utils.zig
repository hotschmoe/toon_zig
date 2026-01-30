//! String Utilities
//!
//! Functions for escaping, unescaping, and parsing quoted strings in TOON.
//! Used by both encoder (string output) and decoder (string parsing).
//!
//! Reference: SPEC.md Section 2.2 (String Representation)

const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("../constants.zig");
const errors = @import("../errors.zig");

// ============================================================================
// String Escaping (for encoding)
// ============================================================================

/// Escapes a string for TOON output by converting special characters to
/// their escape sequences. Per SPEC.md Section 2.2:
/// - Backslash -> \\
/// - Double quote -> \"
/// - Newline (U+000A) -> \n
/// - Carriage return (U+000D) -> \r
/// - Tab (U+0009) -> \t
///
/// Returns a newly allocated string that the caller must free.
pub fn escapeString(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    // First pass: count the output size
    var output_len: usize = 0;
    for (input) |c| {
        output_len += if (constants.escapeChar(c) != null) 2 else 1;
    }

    // Allocate result buffer
    const result = try allocator.alloc(u8, output_len);

    // Second pass: write escaped content
    var i: usize = 0;
    for (input) |c| {
        if (constants.escapeChar(c)) |escaped| {
            result[i] = constants.backslash;
            result[i + 1] = escaped;
            i += 2;
        } else {
            result[i] = c;
            i += 1;
        }
    }

    return result;
}

/// Returns true if the input string contains any characters that need escaping.
/// Used to determine if a string needs quoting.
pub fn needsEscaping(input: []const u8) bool {
    for (input) |c| {
        if (constants.escapeChar(c) != null) return true;
    }
    return false;
}

// ============================================================================
// String Unescaping (for decoding)
// ============================================================================

/// Unescapes a TOON string by converting escape sequences back to their
/// original characters. Per SPEC.md Section 2.2, valid escapes are:
/// \\ -> Backslash
/// \" -> Double quote
/// \n -> Newline (U+000A)
/// \r -> Carriage return (U+000D)
/// \t -> Tab (U+0009)
///
/// Returns error.InvalidEscapeSequence if an unknown escape is encountered.
/// Returns a newly allocated string that the caller must free.
pub fn unescapeString(allocator: Allocator, input: []const u8) errors.Error![]u8 {
    // First pass: count output size and validate escapes
    var output_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == constants.backslash) {
            if (i + 1 >= input.len) {
                return errors.Error.InvalidEscapeSequence;
            }
            if (constants.unescapeChar(input[i + 1]) == null) {
                return errors.Error.InvalidEscapeSequence;
            }
            output_len += 1;
            i += 2;
        } else {
            output_len += 1;
            i += 1;
        }
    }

    // Allocate result buffer
    const result = allocator.alloc(u8, output_len) catch return errors.Error.OutOfMemory;

    // Second pass: write unescaped content
    var out_idx: usize = 0;
    i = 0;
    while (i < input.len) {
        if (input[i] == constants.backslash) {
            result[out_idx] = constants.unescapeChar(input[i + 1]).?;
            out_idx += 1;
            i += 2;
        } else {
            result[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    return result;
}

/// Result of finding a closing quote
pub const QuoteFindResult = union(enum) {
    /// Successfully found the closing quote; value is the index of the quote
    found: usize,
    /// String is unterminated (no closing quote found)
    unterminated,
    /// Invalid escape sequence at the given index
    invalid_escape: usize,
};

/// Finds the closing quote in a quoted string, handling escape sequences.
/// The input should start AFTER the opening quote.
///
/// Returns:
/// - .found with index of the closing quote (relative to input start)
/// - .unterminated if no closing quote is found
/// - .invalid_escape with index of the bad escape sequence
///
/// This does not allocate memory.
pub fn findClosingQuote(input: []const u8) QuoteFindResult {
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == constants.double_quote) {
            return .{ .found = i };
        }
        if (c == constants.backslash) {
            if (i + 1 >= input.len) {
                return .{ .invalid_escape = i };
            }
            if (constants.unescapeChar(input[i + 1]) == null) {
                return .{ .invalid_escape = i };
            }
            i += 2; // Skip the escape sequence
        } else {
            i += 1;
        }
    }
    return .unterminated;
}

/// Extracts the content of a quoted string, unescaping it.
/// Input should include the opening and closing quotes.
/// Returns error if quotes are malformed or contain invalid escapes.
pub fn parseQuotedString(allocator: Allocator, input: []const u8) errors.Error![]u8 {
    if (input.len < 2) return errors.Error.UnterminatedString;
    if (input[0] != constants.double_quote) return errors.Error.UnterminatedString;
    if (input[input.len - 1] != constants.double_quote) return errors.Error.UnterminatedString;

    // Extract content between quotes and unescape
    return unescapeString(allocator, input[1 .. input.len - 1]);
}

/// Wraps a string in quotes and escapes its content.
/// Returns a newly allocated string including the surrounding quotes.
pub fn quoteString(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    // Calculate escaped content size
    var escaped_len: usize = 0;
    for (input) |c| {
        escaped_len += if (constants.escapeChar(c) != null) 2 else 1;
    }

    // Allocate for quotes + escaped content
    const result = try allocator.alloc(u8, escaped_len + 2);
    result[0] = constants.double_quote;

    // Write escaped content
    var i: usize = 1;
    for (input) |c| {
        if (constants.escapeChar(c)) |escaped| {
            result[i] = constants.backslash;
            result[i + 1] = escaped;
            i += 2;
        } else {
            result[i] = c;
            i += 1;
        }
    }

    result[escaped_len + 1] = constants.double_quote;
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "escapeString handles empty string" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "escapeString handles plain string" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "escapeString handles backslashes" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "path\\to\\file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "escapeString handles double quotes" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "say \"hello\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", result);
}

test "escapeString handles newlines" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "line1\nline2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2", result);
}

test "escapeString handles carriage returns" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "line1\rline2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\\rline2", result);
}

test "escapeString handles tabs" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "col1\tcol2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("col1\\tcol2", result);
}

test "escapeString handles mixed escapes" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "a\\b\"c\nd\re\tf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\\\\b\\\"c\\nd\\re\\tf", result);
}

test "needsEscaping detects escapable characters" {
    try std.testing.expect(!needsEscaping(""));
    try std.testing.expect(!needsEscaping("hello"));
    try std.testing.expect(!needsEscaping("hello world 123"));
    try std.testing.expect(needsEscaping("hello\\world"));
    try std.testing.expect(needsEscaping("say\"hello\""));
    try std.testing.expect(needsEscaping("line\n"));
    try std.testing.expect(needsEscaping("col\t"));
    try std.testing.expect(needsEscaping("cr\r"));
}

test "unescapeString handles empty string" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "unescapeString handles plain string" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "unescapeString handles backslashes" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "path\\\\to\\\\file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\to\\file", result);
}

test "unescapeString handles double quotes" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "say \\\"hello\\\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("say \"hello\"", result);
}

test "unescapeString handles newlines" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "line1\\nline2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2", result);
}

test "unescapeString handles carriage returns" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "line1\\rline2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\rline2", result);
}

test "unescapeString handles tabs" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "col1\\tcol2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("col1\tcol2", result);
}

test "unescapeString handles mixed escapes" {
    const allocator = std.testing.allocator;
    const result = try unescapeString(allocator, "a\\\\b\\\"c\\nd\\re\\tf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\\b\"c\nd\re\tf", result);
}

test "unescapeString rejects invalid escape sequence" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "\\x"));
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "\\"));
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "abc\\"));
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "\\u0041"));
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "\\0"));
    try std.testing.expectError(errors.Error.InvalidEscapeSequence, unescapeString(allocator, "\\a"));
}

test "unescapeString/escapeString roundtrip" {
    const allocator = std.testing.allocator;

    const test_cases = [_][]const u8{
        "",
        "hello",
        "hello world",
        "path\\to\\file",
        "say \"hello\"",
        "line1\nline2\nline3",
        "col1\tcol2\tcol3",
        "mixed\n\r\t\\\"all",
        "unicode: \xc3\xa9\xc3\xa0\xc3\xb9", // UTF-8 directly (no escaping)
    };

    for (test_cases) |original| {
        const escaped = try escapeString(allocator, original);
        defer allocator.free(escaped);

        const unescaped = try unescapeString(allocator, escaped);
        defer allocator.free(unescaped);

        try std.testing.expectEqualStrings(original, unescaped);
    }
}

test "findClosingQuote finds quote in simple string" {
    const result = findClosingQuote("hello\"");
    try std.testing.expectEqual(QuoteFindResult{ .found = 5 }, result);
}

test "findClosingQuote finds quote at start" {
    const result = findClosingQuote("\"");
    try std.testing.expectEqual(QuoteFindResult{ .found = 0 }, result);
}

test "findClosingQuote skips escaped quotes" {
    // Input: hello \"world\" end"rest
    // Indices: h(0) e(1) l(2) l(3) o(4) ' '(5) \(6) "(7) w(8) o(9) r(10)
    //          l(11) d(12) \(13) "(14) ' '(15) e(16) n(17) d(18) "(19) ...
    // The first unescaped quote is at index 19
    const result = findClosingQuote("hello \\\"world\\\" end\"rest");
    try std.testing.expectEqual(QuoteFindResult{ .found = 19 }, result);
}

test "findClosingQuote skips escaped backslashes" {
    const result = findClosingQuote("path\\\\file\"");
    try std.testing.expectEqual(QuoteFindResult{ .found = 10 }, result);
}

test "findClosingQuote detects unterminated string" {
    try std.testing.expectEqual(QuoteFindResult.unterminated, findClosingQuote("hello"));
    try std.testing.expectEqual(QuoteFindResult.unterminated, findClosingQuote(""));
    try std.testing.expectEqual(QuoteFindResult.unterminated, findClosingQuote("hello\\\""));
}

test "findClosingQuote detects invalid escape at end" {
    const result = findClosingQuote("hello\\");
    try std.testing.expectEqual(QuoteFindResult{ .invalid_escape = 5 }, result);
}

test "findClosingQuote detects invalid escape sequence" {
    const result = findClosingQuote("hello\\xworld\"");
    try std.testing.expectEqual(QuoteFindResult{ .invalid_escape = 5 }, result);
}

test "parseQuotedString handles simple quoted string" {
    const allocator = std.testing.allocator;
    const result = try parseQuotedString(allocator, "\"hello\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "parseQuotedString handles empty quoted string" {
    const allocator = std.testing.allocator;
    const result = try parseQuotedString(allocator, "\"\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "parseQuotedString handles escaped content" {
    const allocator = std.testing.allocator;
    const result = try parseQuotedString(allocator, "\"line1\\nline2\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2", result);
}

test "parseQuotedString rejects malformed strings" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(errors.Error.UnterminatedString, parseQuotedString(allocator, ""));
    try std.testing.expectError(errors.Error.UnterminatedString, parseQuotedString(allocator, "\""));
    try std.testing.expectError(errors.Error.UnterminatedString, parseQuotedString(allocator, "hello\""));
    try std.testing.expectError(errors.Error.UnterminatedString, parseQuotedString(allocator, "\"hello"));
}

test "quoteString wraps and escapes" {
    const allocator = std.testing.allocator;
    const result = try quoteString(allocator, "hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "quoteString handles empty string" {
    const allocator = std.testing.allocator;
    const result = try quoteString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"\"", result);
}

test "quoteString escapes special characters" {
    const allocator = std.testing.allocator;
    const result = try quoteString(allocator, "say \"hi\"\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\n\"", result);
}

test "quoteString/parseQuotedString roundtrip" {
    const allocator = std.testing.allocator;

    const test_cases = [_][]const u8{
        "",
        "hello",
        "hello world",
        "path\\to\\file",
        "say \"hello\"",
        "line1\nline2",
        "tab\there",
    };

    for (test_cases) |original| {
        const quoted = try quoteString(allocator, original);
        defer allocator.free(quoted);

        const parsed = try parseQuotedString(allocator, quoted);
        defer allocator.free(parsed);

        try std.testing.expectEqualStrings(original, parsed);
    }
}
