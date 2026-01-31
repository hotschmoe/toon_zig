//! tzu - TOON Zig Implementation
//!
//! A spec-first Zig implementation of TOON (Token-Oriented Object Notation).
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// Internal module imports (not re-exported)
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const value_mod = @import("value.zig");
const stream = @import("stream.zig");
const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");

// Public types from constants
pub const Delimiter = constants.Delimiter;
pub const KeyFoldingMode = constants.KeyFoldingMode;
pub const ExpandPathsMode = constants.ExpandPathsMode;

// Public error type
pub const Error = errors.Error;

// Public value types
pub const Value = value_mod.Value;
pub const Array = value_mod.Array;
pub const Object = value_mod.Object;
pub const ArrayBuilder = value_mod.ArrayBuilder;
pub const ObjectBuilder = value_mod.ObjectBuilder;
pub const fromStdJson = value_mod.fromStdJson;

// Public options types
pub const EncodeOptions = stream.EncodeOptions;
pub const DecodeOptions = stream.DecodeOptions;
pub const FullEncodeOptions = encoder.FullEncodeOptions;

// Core decoding functions
pub const decode = decoder.decode;
pub const decodeWithOptions = decoder.decodeWithOptions;
pub const toonToJson = decoder.toonToJson;
pub const toonToJsonWithOptions = decoder.toonToJsonWithOptions;
pub const toonToJsonWithPathExpansion = decoder.toonToJsonWithPathExpansion;
pub const expandPaths = decoder.expandPaths;

// Core encoding functions
pub const encode = encoder.encode;
pub const jsonToToon = encoder.jsonToToon;
pub const jsonToToonWithOptions = encoder.jsonToToonWithOptions;

test {
    // Run tests from all imported modules
    std.testing.refAllDecls(@This());
}
