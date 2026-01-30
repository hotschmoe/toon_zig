//! tzu - TOON Zig Implementation
//!
//! A spec-first Zig implementation of TOON (Token-Oriented Object Notation).
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// Re-export public modules
pub const constants = @import("constants.zig");

// Re-export commonly used types from constants
pub const Delimiter = constants.Delimiter;
pub const KeyFoldingMode = constants.KeyFoldingMode;
pub const ExpandPathsMode = constants.ExpandPathsMode;

test {
    // Run tests from all imported modules
    std.testing.refAllDecls(@This());
}
