//! tzu - TOON Zig Implementation
//!
//! A spec-first Zig implementation of TOON (Token-Oriented Object Notation).
//! Reference: https://github.com/toon-format/spec

const std = @import("std");

// Re-export public modules
pub const constants = @import("constants.zig");
pub const errors = @import("errors.zig");
pub const value = @import("value.zig");
pub const stream = @import("stream.zig");
pub const scanner = @import("scanner.zig");
pub const parser = @import("parser.zig");
pub const decoder = @import("decoder.zig");
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

// Re-export commonly used types from stream
pub const JsonStreamEvent = stream.JsonStreamEvent;
pub const EncodeOptions = stream.EncodeOptions;
pub const DecodeOptions = stream.DecodeOptions;

// Re-export commonly used types from scanner
pub const Scanner = scanner.Scanner;
pub const ScannedLine = scanner.ScannedLine;
pub const LineType = scanner.LineType;
pub const ArrayHeader = scanner.ArrayHeader;

// Re-export commonly used types from parser
pub const ParsedArrayHeader = parser.ParsedArrayHeader;
pub const ParsedKey = parser.ParsedKey;
pub const RootForm = parser.RootForm;

// Re-export commonly used types from decoder
pub const Decoder = decoder.Decoder;
pub const EventBuilder = decoder.EventBuilder;
pub const decode = decoder.decode;
pub const decodeWithOptions = decoder.decodeWithOptions;
pub const decodeToEvents = decoder.decodeToEvents;
pub const decodeToEventsWithOptions = decoder.decodeToEventsWithOptions;
pub const decodeToWriter = decoder.decodeToWriter;
pub const decodeToWriterWithOptions = decoder.decodeToWriterWithOptions;
pub const toonToJson = decoder.toonToJson;
pub const toonToJsonWithOptions = decoder.toonToJsonWithOptions;
pub const valueToJson = decoder.valueToJson;

test {
    // Run tests from all imported modules
    std.testing.refAllDecls(@This());
}
