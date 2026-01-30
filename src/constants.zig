//! TOON Format Constants
//!
//! Constants derived from TOON Specification v3.0.
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// ============================================================================
// Format Metadata
// ============================================================================

/// TOON specification version implemented
pub const spec_version = "3.0";

/// File extension for TOON files
pub const file_extension = ".toon";

/// MIME type (provisional)
pub const media_type = "application/toon";

// ============================================================================
// Delimiters
// ============================================================================

/// Delimiter types for arrays and tabular data
pub const Delimiter = enum(u8) {
    comma = ',',
    pipe = '|',
    tab = '\t',

    pub fn char(self: Delimiter) u8 {
        return @intFromEnum(self);
    }
};

/// Default delimiter for arrays
pub const default_delimiter: Delimiter = .comma;

// ============================================================================
// Indentation
// ============================================================================

/// Default spaces per indentation level
pub const default_indent_size: u8 = 2;

/// Minimum valid indent size
pub const min_indent_size: u8 = 1;

/// Maximum valid indent size
pub const max_indent_size: u8 = 8;

/// Space character (only valid indentation character)
pub const indent_char: u8 = ' ';

/// Tab character (forbidden in indentation)
pub const tab_char: u8 = '\t';

// ============================================================================
// Line Termination
// ============================================================================

/// Line terminator (LF only, not CRLF)
pub const line_terminator: u8 = '\n';

/// Carriage return (invalid as line terminator)
pub const carriage_return: u8 = '\r';

// ============================================================================
// Syntax Characters
// ============================================================================

/// Key-value separator
pub const colon: u8 = ':';

/// String delimiter
pub const double_quote: u8 = '"';

/// Escape character
pub const backslash: u8 = '\\';

/// Array bracket open
pub const bracket_open: u8 = '[';

/// Array bracket close
pub const bracket_close: u8 = ']';

/// Field list open (tabular arrays)
pub const brace_open: u8 = '{';

/// Field list close (tabular arrays)
pub const brace_close: u8 = '}';

/// List item marker
pub const list_marker: u8 = '-';

/// Key folding/path separator
pub const path_separator: u8 = '.';

/// Space character
pub const space: u8 = ' ';

// ============================================================================
// Escape Sequences
// ============================================================================

/// Escape sequence mappings
pub const EscapeMapping = struct {
    escaped: u8,
    unescaped: u8,
};

pub const escape_mappings = [_]EscapeMapping{
    .{ .escaped = '\\', .unescaped = '\\' },
    .{ .escaped = '"', .unescaped = '"' },
    .{ .escaped = 'n', .unescaped = '\n' },
    .{ .escaped = 'r', .unescaped = '\r' },
    .{ .escaped = 't', .unescaped = '\t' },
};

/// Get unescaped character for an escape sequence
pub fn unescapeChar(escaped: u8) ?u8 {
    for (escape_mappings) |mapping| {
        if (mapping.escaped == escaped) {
            return mapping.unescaped;
        }
    }
    return null;
}

/// Get escaped character for a character that needs escaping
pub fn escapeChar(unescaped: u8) ?u8 {
    for (escape_mappings) |mapping| {
        if (mapping.unescaped == unescaped) {
            return mapping.escaped;
        }
    }
    return null;
}

// ============================================================================
// Literals
// ============================================================================

/// Null literal
pub const null_literal = "null";

/// Boolean true literal
pub const true_literal = "true";

/// Boolean false literal
pub const false_literal = "false";

// ============================================================================
// Key Patterns
// ============================================================================

/// Characters valid as the first character of an unquoted key
/// Pattern: [A-Za-z_]
pub fn isKeyStartChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

/// Characters valid in the rest of an unquoted key
/// Pattern: [A-Za-z0-9_.]
pub fn isKeyChar(c: u8) bool {
    return isKeyStartChar(c) or (c >= '0' and c <= '9') or c == '.';
}

/// Characters valid in an identifier segment (for key folding)
/// Pattern: [A-Za-z_][A-Za-z0-9_]*
pub const isIdentifierStartChar = isKeyStartChar;

/// Characters valid in the rest of an identifier segment
pub fn isIdentifierChar(c: u8) bool {
    return isIdentifierStartChar(c) or (c >= '0' and c <= '9');
}

// ============================================================================
// Number Characters
// ============================================================================

/// Valid digit characters
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Valid characters that can start a number
pub fn isNumberStartChar(c: u8) bool {
    return isDigit(c) or c == '-';
}

/// Valid characters within a number
pub fn isNumberChar(c: u8) bool {
    return isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E';
}

// ============================================================================
// Options Defaults
// ============================================================================

/// Key folding modes
pub const KeyFoldingMode = enum {
    off,
    safe,
};

/// Path expansion modes
pub const ExpandPathsMode = enum {
    off,
    safe,
};

/// Default key folding mode
pub const default_key_folding: KeyFoldingMode = .off;

/// Default path expansion mode
pub const default_expand_paths: ExpandPathsMode = .off;

/// Default strict mode for decoder
pub const default_strict: bool = true;

/// Maximum flatten depth (for key folding)
pub const max_flatten_depth: usize = std.math.maxInt(usize);

// ============================================================================
// Tests
// ============================================================================

test "Delimiter char conversion" {
    try std.testing.expectEqual(@as(u8, ','), Delimiter.comma.char());
    try std.testing.expectEqual(@as(u8, '|'), Delimiter.pipe.char());
    try std.testing.expectEqual(@as(u8, '\t'), Delimiter.tab.char());
}

test "escape/unescape mapping" {
    try std.testing.expectEqual(@as(?u8, '\\'), unescapeChar('\\'));
    try std.testing.expectEqual(@as(?u8, '"'), unescapeChar('"'));
    try std.testing.expectEqual(@as(?u8, '\n'), unescapeChar('n'));
    try std.testing.expectEqual(@as(?u8, '\r'), unescapeChar('r'));
    try std.testing.expectEqual(@as(?u8, '\t'), unescapeChar('t'));
    try std.testing.expectEqual(@as(?u8, null), unescapeChar('x'));

    try std.testing.expectEqual(@as(?u8, '\\'), escapeChar('\\'));
    try std.testing.expectEqual(@as(?u8, '"'), escapeChar('"'));
    try std.testing.expectEqual(@as(?u8, 'n'), escapeChar('\n'));
    try std.testing.expectEqual(@as(?u8, 'r'), escapeChar('\r'));
    try std.testing.expectEqual(@as(?u8, 't'), escapeChar('\t'));
    try std.testing.expectEqual(@as(?u8, null), escapeChar('x'));
}

test "key start character validation" {
    try std.testing.expect(isKeyStartChar('a'));
    try std.testing.expect(isKeyStartChar('Z'));
    try std.testing.expect(isKeyStartChar('_'));
    try std.testing.expect(!isKeyStartChar('0'));
    try std.testing.expect(!isKeyStartChar('-'));
    try std.testing.expect(!isKeyStartChar('.'));
}

test "key character validation" {
    try std.testing.expect(isKeyChar('a'));
    try std.testing.expect(isKeyChar('Z'));
    try std.testing.expect(isKeyChar('_'));
    try std.testing.expect(isKeyChar('0'));
    try std.testing.expect(isKeyChar('.'));
    try std.testing.expect(!isKeyChar('-'));
    try std.testing.expect(!isKeyChar(' '));
}

test "identifier segment character validation" {
    try std.testing.expect(isIdentifierStartChar('a'));
    try std.testing.expect(isIdentifierStartChar('_'));
    try std.testing.expect(!isIdentifierStartChar('0'));
    try std.testing.expect(!isIdentifierStartChar('.'));

    try std.testing.expect(isIdentifierChar('a'));
    try std.testing.expect(isIdentifierChar('0'));
    try std.testing.expect(isIdentifierChar('_'));
    try std.testing.expect(!isIdentifierChar('.'));
}

test "number character validation" {
    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('a'));

    try std.testing.expect(isNumberStartChar('0'));
    try std.testing.expect(isNumberStartChar('-'));
    try std.testing.expect(!isNumberStartChar('.'));

    try std.testing.expect(isNumberChar('0'));
    try std.testing.expect(isNumberChar('.'));
    try std.testing.expect(isNumberChar('e'));
    try std.testing.expect(isNumberChar('E'));
    try std.testing.expect(isNumberChar('+'));
    try std.testing.expect(isNumberChar('-'));
}
