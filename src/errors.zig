//! TOON Error Types
//!
//! Error types and context as specified in SPEC.md Section 6.
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// ============================================================================
// Error Set
// ============================================================================

/// All possible errors during TOON encoding/decoding operations.
/// Categorized per SPEC.md Section 6.1.
pub const Error = error{
    // Syntax Errors
    UnterminatedString,
    InvalidEscapeSequence,
    MissingColon,
    UnexpectedEndOfInput,

    // Indentation Errors
    InvalidIndentation,
    TabsInIndentation,

    // Array Errors
    CountMismatch,
    BlankLineInArray,
    MalformedArrayHeader,

    // Structural Errors
    PathExpansionConflict,
    InvalidJson,
    InvalidToon,

    // Memory errors (from allocator operations)
    OutOfMemory,
};

// ============================================================================
// Error Context
// ============================================================================

/// Detailed error information including position.
/// Per SPEC.md Section 6.2, errors include line, column, and a message.
pub const ErrorContext = struct {
    /// The error code
    code: Error,

    /// Human-readable error message
    message: []const u8,

    /// 1-based line number where error occurred (0 = not applicable)
    line: usize,

    /// 1-based column/position where error occurred (0 = not applicable)
    column: usize,

    /// Create an error context without position information
    pub fn init(code: Error, message: []const u8) ErrorContext {
        return .{
            .code = code,
            .message = message,
            .line = 0,
            .column = 0,
        };
    }

    /// Create an error context with position information
    pub fn initWithPosition(code: Error, message: []const u8, line: usize, column: usize) ErrorContext {
        return .{
            .code = code,
            .message = message,
            .line = line,
            .column = column,
        };
    }

    /// Format the error for display
    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.line > 0) {
            if (self.column > 0) {
                try writer.print("{s} at line {d}, column {d}: {s}", .{
                    @errorName(self.code),
                    self.line,
                    self.column,
                    self.message,
                });
            } else {
                try writer.print("{s} at line {d}: {s}", .{
                    @errorName(self.code),
                    self.line,
                    self.message,
                });
            }
        } else {
            try writer.print("{s}: {s}", .{
                @errorName(self.code),
                self.message,
            });
        }
    }
};

// ============================================================================
// Error Messages (Static)
// ============================================================================

/// Standard error messages for each error type
pub const messages = struct {
    // Syntax Errors
    pub const unterminated_string = "String literal missing closing quote";
    pub const invalid_escape_sequence = "Invalid escape sequence";
    pub const missing_colon = "Key missing colon separator";
    pub const unexpected_end_of_input = "Unexpected end of input";

    // Indentation Errors
    pub const invalid_indentation = "Indentation is not a multiple of indent size";
    pub const tabs_in_indentation = "Tabs are not allowed in indentation";

    // Array Errors
    pub const count_mismatch = "Array element count does not match declared count";
    pub const blank_line_in_array = "Blank line not allowed within array";
    pub const malformed_array_header = "Invalid array header syntax";

    // Structural Errors
    pub const path_expansion_conflict = "Path expansion conflicts with existing structure";
    pub const invalid_json = "Invalid JSON input";
    pub const invalid_toon = "Invalid TOON input";
};

// ============================================================================
// Result Type
// ============================================================================

/// Result type that can hold either a value or an error context.
/// Useful for functions that need to return detailed error information.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,

        const Self = @This();

        pub fn unwrap(self: Self) Error!T {
            return switch (self) {
                .ok => |value| value,
                .err => |ctx| ctx.code,
            };
        }

        pub fn getError(self: Self) ?ErrorContext {
            return switch (self) {
                .ok => null,
                .err => |ctx| ctx,
            };
        }

        pub fn isOk(self: Self) bool {
            return self == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self == .err;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorContext init without position" {
    const ctx = ErrorContext.init(Error.UnterminatedString, messages.unterminated_string);
    try std.testing.expectEqual(Error.UnterminatedString, ctx.code);
    try std.testing.expectEqualStrings(messages.unterminated_string, ctx.message);
    try std.testing.expectEqual(@as(usize, 0), ctx.line);
    try std.testing.expectEqual(@as(usize, 0), ctx.column);
}

test "ErrorContext init with position" {
    const ctx = ErrorContext.initWithPosition(
        Error.MissingColon,
        messages.missing_colon,
        10,
        5,
    );
    try std.testing.expectEqual(Error.MissingColon, ctx.code);
    try std.testing.expectEqualStrings(messages.missing_colon, ctx.message);
    try std.testing.expectEqual(@as(usize, 10), ctx.line);
    try std.testing.expectEqual(@as(usize, 5), ctx.column);
}

test "ErrorContext format with line and column" {
    const ctx = ErrorContext.initWithPosition(
        Error.InvalidIndentation,
        messages.invalid_indentation,
        3,
        4,
    );
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try ctx.format("", .{}, stream.writer());
    const result = stream.getWritten();
    try std.testing.expectEqualStrings(
        "InvalidIndentation at line 3, column 4: Indentation is not a multiple of indent size",
        result,
    );
}

test "ErrorContext format with line only" {
    const ctx = ErrorContext.initWithPosition(
        Error.BlankLineInArray,
        messages.blank_line_in_array,
        7,
        0,
    );
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try ctx.format("", .{}, stream.writer());
    const result = stream.getWritten();
    try std.testing.expectEqualStrings(
        "BlankLineInArray at line 7: Blank line not allowed within array",
        result,
    );
}

test "ErrorContext format without position" {
    const ctx = ErrorContext.init(Error.InvalidJson, messages.invalid_json);
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try ctx.format("", .{}, stream.writer());
    const result = stream.getWritten();
    try std.testing.expectEqualStrings(
        "InvalidJson: Invalid JSON input",
        result,
    );
}

test "Result type ok case" {
    const result: Result(i32) = .{ .ok = 42 };
    try std.testing.expect(result.isOk());
    try std.testing.expect(!result.isErr());
    try std.testing.expectEqual(@as(i32, 42), try result.unwrap());
    try std.testing.expectEqual(@as(?ErrorContext, null), result.getError());
}

test "Result type err case" {
    const result: Result(i32) = .{
        .err = ErrorContext.init(Error.InvalidToon, messages.invalid_toon),
    };
    try std.testing.expect(!result.isOk());
    try std.testing.expect(result.isErr());
    try std.testing.expectError(Error.InvalidToon, result.unwrap());
    const err_ctx = result.getError().?;
    try std.testing.expectEqual(Error.InvalidToon, err_ctx.code);
}

test "error set has expected count" {
    const error_list = [_]Error{
        Error.UnterminatedString,
        Error.InvalidEscapeSequence,
        Error.MissingColon,
        Error.UnexpectedEndOfInput,
        Error.InvalidIndentation,
        Error.TabsInIndentation,
        Error.CountMismatch,
        Error.BlankLineInArray,
        Error.MalformedArrayHeader,
        Error.PathExpansionConflict,
        Error.InvalidJson,
        Error.InvalidToon,
        Error.OutOfMemory,
    };

    try std.testing.expectEqual(@as(usize, 13), error_list.len);
}
