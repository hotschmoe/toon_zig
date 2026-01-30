//! tzu - TOON Zig Implementation
//!
//! A spec-first Zig implementation of TOON (Token-Oriented Object Notation).
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// Re-export public modules
pub const constants = @import("constants.zig");
pub const errors = @import("errors.zig");
pub const value = @import("value.zig");
pub const literal_utils = @import("shared/literal_utils.zig");
pub const string_utils = @import("shared/string_utils.zig");
pub const validation = @import("shared/validation.zig");

// Re-export commonly used types from constants
pub const Delimiter = constants.Delimiter;
pub const KeyFoldingMode = constants.KeyFoldingMode;
pub const ExpandPathsMode = constants.ExpandPathsMode;

// Re-export commonly used types from errors
pub const Error = errors.Error;
pub const ErrorContext = errors.ErrorContext;
pub const Result = errors.Result;

// Re-export commonly used types from value
pub const Value = value.Value;
pub const Array = value.Array;
pub const Object = value.Object;
pub const ArrayBuilder = value.ArrayBuilder;
pub const ObjectBuilder = value.ObjectBuilder;

test {
    // Run tests from all imported modules
    std.testing.refAllDecls(@This());
}
