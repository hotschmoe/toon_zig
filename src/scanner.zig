//! TOON Scanner
//!
//! Line-by-line scanner for TOON input. Handles indentation tracking,
//! line classification, and tokenization of TOON syntax elements.
//!
//! The scanner is the first stage of TOON decoding - it produces structured
//! line information that the parser can use to build the value tree.
//!
//! Reference: SPEC.md Sections 3, 4, 6

const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const string_utils = @import("shared/string_utils.zig");
const validation = @import("shared/validation.zig");
const literal_utils = @import("shared/literal_utils.zig");

// ============================================================================
// Line Types
// ============================================================================

/// Classification of a TOON line.
pub const LineType = enum {
    /// Empty line or whitespace-only line.
    blank,

    /// Key-value pair: `key: value` or `key:` (for nested content).
    key_value,

    /// Array header: `[N]:`, `key[N]:`, or `key[N]{fields}:`.
    array_header,

    /// List item: `- value` or `- key: value`.
    list_item,

    /// Tabular row: comma/pipe/tab-separated values in a tabular array.
    tabular_row,

    /// Comment line (not part of spec, but useful for future extension).
    comment,
};

// ============================================================================
// Array Header Info
// ============================================================================

/// Parsed array header information.
/// Corresponds to the pattern: `[key][count<delim?>][{fields}]:`
pub const ArrayHeader = struct {
    /// Optional key name (for `key[N]:` form).
    key: ?[]const u8,

    /// Declared element count.
    count: usize,

    /// Delimiter for this array scope.
    delimiter: constants.Delimiter,

    /// Field names for tabular arrays (for `key[N]{f1,f2}:` form).
    /// Null if not a tabular array.
    fields: ?[]const []const u8,

    /// Inline values after the colon (for primitive arrays).
    /// Null if values are on subsequent lines.
    inline_values: ?[]const u8,

    /// Free allocated memory.
    pub fn deinit(self: *ArrayHeader, allocator: Allocator) void {
        if (self.fields) |fields| {
            for (fields) |field| {
                allocator.free(field);
            }
            allocator.free(fields);
        }
        if (self.key) |k| {
            allocator.free(k);
        }
        if (self.inline_values) |v| {
            allocator.free(v);
        }
    }
};

// ============================================================================
// Scanned Line
// ============================================================================

/// Result of scanning a single TOON line.
pub const ScannedLine = struct {
    /// The type of this line.
    line_type: LineType,

    /// Indentation depth (number of indent levels, not spaces).
    depth: usize,

    /// The raw line content (without leading indentation).
    content: []const u8,

    /// For key_value lines: the key (unescaped if quoted).
    key: ?[]const u8,

    /// For key_value lines: the value portion (may be empty for nested content).
    /// For list_item lines: the value after the hyphen.
    value: ?[]const u8,

    /// For array_header lines: parsed header information.
    array_header: ?ArrayHeader,

    /// 1-based line number for error reporting.
    line_number: usize,

    /// Original line including indentation.
    raw_line: []const u8,

    /// Free allocated memory.
    pub fn deinit(self: *ScannedLine, allocator: Allocator) void {
        if (self.key) |k| {
            allocator.free(k);
        }
        if (self.array_header) |*ah| {
            ah.deinit(allocator);
        }
    }
};

// ============================================================================
// Scanner
// ============================================================================

/// TOON line scanner.
///
/// The scanner processes TOON input line by line, producing ScannedLine
/// structures that contain parsed information about each line's type,
/// indentation, and content.
///
/// Usage:
/// ```
/// var scanner = Scanner.init(allocator, input, .{});
/// while (try scanner.next()) |line| {
///     defer line.deinit(allocator);
///     // process line...
/// }
/// ```
pub const Scanner = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize,
    line_number: usize,
    indent_size: u8,
    strict: bool,

    /// Scanner configuration options.
    pub const Options = struct {
        indent_size: u8 = constants.default_indent_size,
        strict: bool = constants.default_strict,
    };

    /// Initialize a new scanner.
    pub fn init(allocator: Allocator, input: []const u8, options: Options) Scanner {
        return .{
            .allocator = allocator,
            .input = input,
            .position = 0,
            .line_number = 0,
            .indent_size = options.indent_size,
            .strict = options.strict,
        };
    }

    /// Get the next scanned line, or null if at end of input.
    pub fn next(self: *Scanner) errors.Error!?ScannedLine {
        if (self.position >= self.input.len) return null;

        const line_start = self.position;
        self.line_number += 1;

        // Find end of line
        var line_end = self.position;
        while (line_end < self.input.len and self.input[line_end] != constants.line_terminator) {
            line_end += 1;
        }

        const raw_line = self.input[line_start..line_end];

        // Advance past the newline
        self.position = if (line_end < self.input.len) line_end + 1 else line_end;

        return try self.scanLine(raw_line, self.line_number);
    }

    /// Scan a single line and produce a ScannedLine.
    fn scanLine(self: *Scanner, raw_line: []const u8, line_number: usize) errors.Error!ScannedLine {
        // Validate and compute indentation
        const indent_result = validation.validateIndentation(raw_line, self.indent_size);
        const depth: usize = switch (indent_result) {
            .ok => |d| d,
            .tabs_found => return errors.Error.TabsInIndentation,
            .invalid_multiple => |spaces| blk: {
                if (self.strict) {
                    return errors.Error.InvalidIndentation;
                }
                // In lenient mode, compute approximate depth
                break :blk spaces / self.indent_size;
            },
        };

        // Get content after indentation
        const indent_chars = depth * self.indent_size;
        const content = if (indent_chars < raw_line.len) raw_line[indent_chars..] else "";

        // Check for blank line
        if (isBlankContent(content)) {
            return ScannedLine{
                .line_type = .blank,
                .depth = depth,
                .content = content,
                .key = null,
                .value = null,
                .array_header = null,
                .line_number = line_number,
                .raw_line = raw_line,
            };
        }

        // Check for list item
        if (content.len >= 2 and content[0] == constants.list_marker and content[1] == constants.space) {
            return self.scanListItem(raw_line, content, depth, line_number);
        }

        // Check for array header or key-value
        return self.scanKeyValueOrArrayHeader(raw_line, content, depth, line_number);
    }

    /// Scan a list item line.
    fn scanListItem(self: *Scanner, raw_line: []const u8, content: []const u8, depth: usize, line_number: usize) errors.Error!ScannedLine {
        // Content after "- "
        const item_content = content[2..];

        // Check if it's a list item with key-value (- key: value)
        if (findUnquotedColon(item_content)) |colon_pos| {
            const key_part = item_content[0..colon_pos];
            const key = try self.parseKey(key_part);
            errdefer if (key) |k| self.allocator.free(k);

            const value_start = colon_pos + 1;
            const value = if (value_start < item_content.len) blk: {
                const v = std.mem.trimLeft(u8, item_content[value_start..], " ");
                break :blk if (v.len > 0) v else null;
            } else null;

            return ScannedLine{
                .line_type = .list_item,
                .depth = depth,
                .content = content,
                .key = key,
                .value = value,
                .array_header = null,
                .line_number = line_number,
                .raw_line = raw_line,
            };
        }

        // Simple list item (- value)
        return ScannedLine{
            .line_type = .list_item,
            .depth = depth,
            .content = content,
            .key = null,
            .value = if (item_content.len > 0) item_content else null,
            .array_header = null,
            .line_number = line_number,
            .raw_line = raw_line,
        };
    }

    /// Scan a key-value or array header line.
    fn scanKeyValueOrArrayHeader(self: *Scanner, raw_line: []const u8, content: []const u8, depth: usize, line_number: usize) errors.Error!ScannedLine {
        // Look for array header pattern: key[N] or [N]
        if (findArrayBracket(content)) |bracket_pos| {
            return self.scanArrayHeader(raw_line, content, depth, line_number, bracket_pos);
        }

        // Regular key-value line
        if (findUnquotedColon(content)) |colon_pos| {
            const key_part = content[0..colon_pos];
            const key = try self.parseKey(key_part);
            errdefer if (key) |k| self.allocator.free(k);

            const value_start = colon_pos + 1;
            const value = if (value_start < content.len) blk: {
                const v = std.mem.trimLeft(u8, content[value_start..], " ");
                break :blk if (v.len > 0) v else null;
            } else null;

            return ScannedLine{
                .line_type = .key_value,
                .depth = depth,
                .content = content,
                .key = key,
                .value = value,
                .array_header = null,
                .line_number = line_number,
                .raw_line = raw_line,
            };
        }

        // Content without colon - could be a tabular row or invalid syntax
        // For now, treat as tabular row (the parser will validate context)
        return ScannedLine{
            .line_type = .tabular_row,
            .depth = depth,
            .content = content,
            .key = null,
            .value = content,
            .array_header = null,
            .line_number = line_number,
            .raw_line = raw_line,
        };
    }

    /// Scan an array header line.
    fn scanArrayHeader(self: *Scanner, raw_line: []const u8, content: []const u8, depth: usize, line_number: usize, bracket_pos: usize) errors.Error!ScannedLine {
        // Parse optional key before bracket
        var key: ?[]const u8 = null;
        if (bracket_pos > 0) {
            key = try self.parseKey(content[0..bracket_pos]);
        }
        errdefer if (key) |k| self.allocator.free(k);

        // Find the closing bracket
        const rest = content[bracket_pos + 1 ..];
        const close_bracket = std.mem.indexOfScalar(u8, rest, constants.bracket_close) orelse {
            return errors.Error.MalformedArrayHeader;
        };

        // Parse count and optional delimiter from inside brackets
        const bracket_content = rest[0..close_bracket];
        const count_delimiter = try parseCountAndDelimiter(bracket_content);

        // Check for field list after bracket
        const after_bracket = rest[close_bracket + 1 ..];
        var fields: ?[]const []const u8 = null;
        var fields_end: usize = 0;

        if (after_bracket.len > 0 and after_bracket[0] == constants.brace_open) {
            const brace_result = try self.parseFieldList(after_bracket[1..], count_delimiter.delimiter);
            fields = brace_result.fields;
            fields_end = brace_result.end_pos + 1; // +1 for opening brace
        }
        errdefer if (fields) |f| {
            for (f) |field| self.allocator.free(field);
            self.allocator.free(f);
        };

        // Find the colon after bracket/fields
        const colon_search = after_bracket[fields_end..];
        const colon_pos = std.mem.indexOfScalar(u8, colon_search, constants.colon) orelse {
            return errors.Error.MalformedArrayHeader;
        };

        // Get inline values after colon (if any)
        var inline_values: ?[]const u8 = null;
        const after_colon = colon_search[colon_pos + 1 ..];
        if (after_colon.len > 0) {
            const trimmed = std.mem.trimLeft(u8, after_colon, " ");
            if (trimmed.len > 0) {
                inline_values = try self.allocator.dupe(u8, trimmed);
            }
        }
        errdefer if (inline_values) |v| self.allocator.free(v);

        const header = ArrayHeader{
            .key = key,
            .count = count_delimiter.count,
            .delimiter = count_delimiter.delimiter,
            .fields = fields,
            .inline_values = inline_values,
        };

        return ScannedLine{
            .line_type = .array_header,
            .depth = depth,
            .content = content,
            .key = null,
            .value = null,
            .array_header = header,
            .line_number = line_number,
            .raw_line = raw_line,
        };
    }

    /// Parse a key (quoted or unquoted) and return the unescaped key string.
    fn parseKey(self: *Scanner, raw_key: []const u8) errors.Error!?[]const u8 {
        const key = std.mem.trim(u8, raw_key, " ");
        if (key.len == 0) return null;

        if (key[0] == constants.double_quote) {
            // Quoted key - parse and unescape
            const parsed = try string_utils.parseQuotedString(self.allocator, key);
            return parsed;
        }

        // Unquoted key - duplicate it
        const duped = self.allocator.dupe(u8, key) catch return errors.Error.OutOfMemory;
        return duped;
    }

    /// Parse field list from inside braces.
    /// Returns the parsed fields and the position of the closing brace.
    fn parseFieldList(self: *Scanner, content: []const u8, delimiter: constants.Delimiter) errors.Error!struct { fields: []const []const u8, end_pos: usize } {
        const close_brace = std.mem.indexOfScalar(u8, content, constants.brace_close) orelse {
            return errors.Error.MalformedArrayHeader;
        };

        const field_content = content[0..close_brace];
        const fields = try parseDelimitedValues(self.allocator, field_content, delimiter);

        return .{ .fields = fields, .end_pos = close_brace + 1 };
    }

    /// Reset the scanner to the beginning.
    pub fn reset(self: *Scanner) void {
        self.position = 0;
        self.line_number = 0;
    }

    /// Check if there is more input to scan.
    pub fn hasMore(self: *const Scanner) bool {
        return self.position < self.input.len;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if content is blank (empty or whitespace only).
fn isBlankContent(content: []const u8) bool {
    for (content) |c| {
        if (c != constants.space and c != constants.tab_char) return false;
    }
    return true;
}

/// Find the position of an unquoted colon in content.
/// Skips colons inside quoted strings.
fn findUnquotedColon(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == constants.double_quote) {
            // Skip quoted string
            const quote_result = string_utils.findClosingQuote(content[i + 1 ..]);
            switch (quote_result) {
                .found => |pos| {
                    i += pos + 2; // Skip past closing quote
                },
                else => return null, // Malformed quote - let parser handle
            }
        } else if (c == constants.colon) {
            return i;
        } else if (c == constants.bracket_open) {
            // Stop at array bracket - this is likely an array header
            return null;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Find the position of an array bracket that starts an array header.
/// Returns position of '[' if this looks like an array header pattern.
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

/// Result of parsing count and delimiter from bracket content.
const CountDelimiter = struct {
    count: usize,
    delimiter: constants.Delimiter,
};

/// Parse count and optional delimiter from array bracket content.
/// Format: N or N| or N\t
fn parseCountAndDelimiter(content: []const u8) errors.Error!CountDelimiter {
    if (content.len == 0) return errors.Error.MalformedArrayHeader;

    // Find where the count ends
    var count_end: usize = 0;
    while (count_end < content.len and constants.isDigit(content[count_end])) {
        count_end += 1;
    }

    if (count_end == 0) return errors.Error.MalformedArrayHeader;

    // Validate and parse count
    const count_str = content[0..count_end];
    if (!validation.isValidArrayCount(count_str)) {
        return errors.Error.MalformedArrayHeader;
    }

    const count = std.fmt.parseInt(usize, count_str, 10) catch {
        return errors.Error.MalformedArrayHeader;
    };

    // Parse optional delimiter
    var delimiter = constants.default_delimiter;
    if (count_end < content.len) {
        const delim_char = content[count_end];
        if (delim_char == '|') {
            delimiter = .pipe;
        } else if (delim_char == '\t') {
            delimiter = .tab;
        } else {
            return errors.Error.MalformedArrayHeader;
        }
    }

    return .{ .count = count, .delimiter = delimiter };
}

/// Parse delimiter-separated values into a slice of strings.
pub fn parseDelimitedValues(allocator: Allocator, content: []const u8, delimiter: constants.Delimiter) errors.Error![]const []const u8 {
    if (content.len == 0) {
        const result = allocator.alloc([]const u8, 0) catch return errors.Error.OutOfMemory;
        return result;
    }

    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (values.items) |v| allocator.free(v);
        values.deinit(allocator);
    }

    const delim_char = delimiter.char();
    var start: usize = 0;
    var i: usize = 0;

    while (i <= content.len) {
        const at_end = i >= content.len;
        const at_delimiter = !at_end and content[i] == delim_char;

        if (at_end or at_delimiter) {
            const raw_value = content[start..i];
            const value = try parseFieldValue(allocator, raw_value);
            values.append(allocator, value) catch return errors.Error.OutOfMemory;
            start = i + 1;
            i += 1;
        } else if (!at_end and content[i] == constants.double_quote) {
            // Skip quoted value
            const quote_result = string_utils.findClosingQuote(content[i + 1 ..]);
            switch (quote_result) {
                .found => |pos| {
                    i += pos + 2;
                },
                .unterminated => return errors.Error.UnterminatedString,
                .invalid_escape => return errors.Error.InvalidEscapeSequence,
            }
        } else {
            i += 1;
        }
    }

    return values.toOwnedSlice(allocator) catch errors.Error.OutOfMemory;
}

/// Parse a single field value (handles quoting and trimming).
fn parseFieldValue(allocator: Allocator, raw: []const u8) errors.Error![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0) {
        return allocator.dupe(u8, "") catch errors.Error.OutOfMemory;
    }

    if (trimmed[0] == constants.double_quote) {
        return string_utils.parseQuotedString(allocator, trimmed);
    }

    return allocator.dupe(u8, trimmed) catch errors.Error.OutOfMemory;
}

// ============================================================================
// Tests
// ============================================================================

test "Scanner - blank lines" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "\n  \n", .{});

    const line1 = (try scanner.next()).?;
    try std.testing.expectEqual(LineType.blank, line1.line_type);
    try std.testing.expectEqual(@as(usize, 0), line1.depth);

    const line2 = (try scanner.next()).?;
    try std.testing.expectEqual(LineType.blank, line2.line_type);
    try std.testing.expectEqual(@as(usize, 1), line2.depth);

    try std.testing.expectEqual(@as(?ScannedLine, null), try scanner.next());
}

test "Scanner - simple key-value" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "name: Alice\nage: 30\n", .{});

    var line1 = (try scanner.next()).?;
    defer line1.deinit(allocator);
    try std.testing.expectEqual(LineType.key_value, line1.line_type);
    try std.testing.expectEqualStrings("name", line1.key.?);
    try std.testing.expectEqualStrings("Alice", line1.value.?);

    var line2 = (try scanner.next()).?;
    defer line2.deinit(allocator);
    try std.testing.expectEqual(LineType.key_value, line2.line_type);
    try std.testing.expectEqualStrings("age", line2.key.?);
    try std.testing.expectEqualStrings("30", line2.value.?);
}

test "Scanner - nested key-value" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "user:\n  name: Alice\n  age: 30\n", .{});

    var line1 = (try scanner.next()).?;
    defer line1.deinit(allocator);
    try std.testing.expectEqual(LineType.key_value, line1.line_type);
    try std.testing.expectEqualStrings("user", line1.key.?);
    try std.testing.expectEqual(@as(?[]const u8, null), line1.value);
    try std.testing.expectEqual(@as(usize, 0), line1.depth);

    var line2 = (try scanner.next()).?;
    defer line2.deinit(allocator);
    try std.testing.expectEqual(LineType.key_value, line2.line_type);
    try std.testing.expectEqualStrings("name", line2.key.?);
    try std.testing.expectEqual(@as(usize, 1), line2.depth);
}

test "Scanner - quoted key" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "\"special-key\": value\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);
    try std.testing.expectEqual(LineType.key_value, line.line_type);
    try std.testing.expectEqualStrings("special-key", line.key.?);
    try std.testing.expectEqualStrings("value", line.value.?);
}

test "Scanner - simple array header" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "items[3]: a,b,c\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);
    try std.testing.expectEqual(LineType.array_header, line.line_type);

    const header = line.array_header.?;
    try std.testing.expectEqualStrings("items", header.key.?);
    try std.testing.expectEqual(@as(usize, 3), header.count);
    try std.testing.expectEqual(constants.Delimiter.comma, header.delimiter);
    try std.testing.expectEqual(@as(?[]const []const u8, null), header.fields);
    try std.testing.expectEqualStrings("a,b,c", header.inline_values.?);
}

test "Scanner - array header with fields" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "users[2]{id,name}:\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);
    try std.testing.expectEqual(LineType.array_header, line.line_type);

    const header = line.array_header.?;
    try std.testing.expectEqualStrings("users", header.key.?);
    try std.testing.expectEqual(@as(usize, 2), header.count);
    try std.testing.expectEqual(@as(usize, 2), header.fields.?.len);
    try std.testing.expectEqualStrings("id", header.fields.?[0]);
    try std.testing.expectEqualStrings("name", header.fields.?[1]);
}

test "Scanner - array header with pipe delimiter" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "data[3|]:\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);

    const header = line.array_header.?;
    try std.testing.expectEqual(@as(usize, 3), header.count);
    try std.testing.expectEqual(constants.Delimiter.pipe, header.delimiter);
}

test "Scanner - root array header" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "[5]:\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);
    try std.testing.expectEqual(LineType.array_header, line.line_type);

    const header = line.array_header.?;
    try std.testing.expectEqual(@as(?[]const u8, null), header.key);
    try std.testing.expectEqual(@as(usize, 5), header.count);
}

test "Scanner - list item simple" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "- first\n- second\n", .{});

    var line1 = (try scanner.next()).?;
    defer line1.deinit(allocator);
    try std.testing.expectEqual(LineType.list_item, line1.line_type);
    try std.testing.expectEqual(@as(?[]const u8, null), line1.key);
    try std.testing.expectEqualStrings("first", line1.value.?);

    var line2 = (try scanner.next()).?;
    defer line2.deinit(allocator);
    try std.testing.expectEqualStrings("second", line2.value.?);
}

test "Scanner - list item with key-value" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "- id: 1\n- id: 2\n", .{});

    var line1 = (try scanner.next()).?;
    defer line1.deinit(allocator);
    try std.testing.expectEqual(LineType.list_item, line1.line_type);
    try std.testing.expectEqualStrings("id", line1.key.?);
    try std.testing.expectEqualStrings("1", line1.value.?);
}

test "Scanner - tabular row" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "  1,Alice,true\n", .{});

    var line = (try scanner.next()).?;
    defer line.deinit(allocator);
    try std.testing.expectEqual(LineType.tabular_row, line.line_type);
    try std.testing.expectEqual(@as(usize, 1), line.depth);
    try std.testing.expectEqualStrings("1,Alice,true", line.value.?);
}

test "Scanner - tabs in indentation rejected" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "\tkey: value\n", .{});

    try std.testing.expectError(errors.Error.TabsInIndentation, scanner.next());
}

test "Scanner - invalid indentation in strict mode" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "   key: value\n", .{ .strict = true });

    try std.testing.expectError(errors.Error.InvalidIndentation, scanner.next());
}

test "parseDelimitedValues - comma separated" {
    const allocator = std.testing.allocator;

    const values = try parseDelimitedValues(allocator, "a,b,c", .comma);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("a", values[0]);
    try std.testing.expectEqualStrings("b", values[1]);
    try std.testing.expectEqualStrings("c", values[2]);
}

test "parseDelimitedValues - pipe separated" {
    const allocator = std.testing.allocator;

    const values = try parseDelimitedValues(allocator, "x|y|z", .pipe);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("x", values[0]);
    try std.testing.expectEqualStrings("y", values[1]);
    try std.testing.expectEqualStrings("z", values[2]);
}

test "parseDelimitedValues - with quoted values" {
    const allocator = std.testing.allocator;

    const values = try parseDelimitedValues(allocator, "\"hello, world\",plain,\"quoted\"", .comma);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("hello, world", values[0]);
    try std.testing.expectEqualStrings("plain", values[1]);
    try std.testing.expectEqualStrings("quoted", values[2]);
}

test "parseDelimitedValues - empty" {
    const allocator = std.testing.allocator;

    const values = try parseDelimitedValues(allocator, "", .comma);
    defer allocator.free(values);

    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "parseCountAndDelimiter - count only" {
    const result = try parseCountAndDelimiter("5");
    try std.testing.expectEqual(@as(usize, 5), result.count);
    try std.testing.expectEqual(constants.Delimiter.comma, result.delimiter);
}

test "parseCountAndDelimiter - with pipe" {
    const result = try parseCountAndDelimiter("3|");
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(constants.Delimiter.pipe, result.delimiter);
}

test "parseCountAndDelimiter - with tab" {
    const result = try parseCountAndDelimiter("10\t");
    try std.testing.expectEqual(@as(usize, 10), result.count);
    try std.testing.expectEqual(constants.Delimiter.tab, result.delimiter);
}

test "parseCountAndDelimiter - invalid leading zero" {
    try std.testing.expectError(errors.Error.MalformedArrayHeader, parseCountAndDelimiter("007"));
}

test "parseCountAndDelimiter - empty" {
    try std.testing.expectError(errors.Error.MalformedArrayHeader, parseCountAndDelimiter(""));
}

test "Scanner - hasMore and reset" {
    const allocator = std.testing.allocator;

    var scanner = Scanner.init(allocator, "a: 1\nb: 2\n", .{});

    try std.testing.expect(scanner.hasMore());

    var line1 = (try scanner.next()).?;
    defer line1.deinit(allocator);

    try std.testing.expect(scanner.hasMore());

    var line2 = (try scanner.next()).?;
    defer line2.deinit(allocator);

    try std.testing.expect(!scanner.hasMore());

    scanner.reset();
    try std.testing.expect(scanner.hasMore());
    try std.testing.expectEqual(@as(usize, 0), scanner.line_number);
}

test "findUnquotedColon - simple" {
    try std.testing.expectEqual(@as(?usize, 4), findUnquotedColon("name: value"));
    try std.testing.expectEqual(@as(?usize, 0), findUnquotedColon(": value"));
    try std.testing.expectEqual(@as(?usize, null), findUnquotedColon("no colon"));
}

test "findUnquotedColon - skips quoted" {
    // "key:in:quote": value
    // 0            13|14
    // Opening quote at 0, closing quote at 13, colon at 14
    try std.testing.expectEqual(@as(?usize, 14), findUnquotedColon("\"key:in:quote\": value"));
}

test "findArrayBracket - finds bracket" {
    // items[3]:
    // 01234|5
    // Bracket '[' is at position 5
    try std.testing.expectEqual(@as(?usize, 5), findArrayBracket("items[3]:"));
    try std.testing.expectEqual(@as(?usize, 0), findArrayBracket("[5]:"));
    try std.testing.expectEqual(@as(?usize, null), findArrayBracket("key: value"));
}

test "findArrayBracket - stops at colon" {
    try std.testing.expectEqual(@as(?usize, null), findArrayBracket("key: [3]"));
}
