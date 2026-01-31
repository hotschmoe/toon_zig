//! TOON Specification Conformance Tests
//!
//! Validates tzu against the official TOON specification test fixtures.
//! Fixtures are embedded at compile time from tests/fixtures/tests/fixtures/.
//!
//! Reference: https://github.com/toon-format/spec

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const toon = @import("toon_zig");
const Value = toon.Value;
const FullEncodeOptions = toon.FullEncodeOptions;
const DecodeOptions = toon.DecodeOptions;
const Delimiter = toon.Delimiter;
const KeyFoldingMode = toon.KeyFoldingMode;
const ExpandPathsMode = toon.ExpandPathsMode;

// ============================================================================
// Embedded Fixture Files
// ============================================================================

const EncodeFixtures = struct {
    const arrays_nested = @embedFile("fixtures/tests/fixtures/encode/arrays-nested.json");
    const arrays_objects = @embedFile("fixtures/tests/fixtures/encode/arrays-objects.json");
    const arrays_primitive = @embedFile("fixtures/tests/fixtures/encode/arrays-primitive.json");
    const arrays_tabular = @embedFile("fixtures/tests/fixtures/encode/arrays-tabular.json");
    const delimiters = @embedFile("fixtures/tests/fixtures/encode/delimiters.json");
    const key_folding = @embedFile("fixtures/tests/fixtures/encode/key-folding.json");
    const objects = @embedFile("fixtures/tests/fixtures/encode/objects.json");
    const primitives = @embedFile("fixtures/tests/fixtures/encode/primitives.json");
    const whitespace = @embedFile("fixtures/tests/fixtures/encode/whitespace.json");
};

const DecodeFixtures = struct {
    const arrays_nested = @embedFile("fixtures/tests/fixtures/decode/arrays-nested.json");
    const arrays_primitive = @embedFile("fixtures/tests/fixtures/decode/arrays-primitive.json");
    const arrays_tabular = @embedFile("fixtures/tests/fixtures/decode/arrays-tabular.json");
    const blank_lines = @embedFile("fixtures/tests/fixtures/decode/blank-lines.json");
    const delimiters = @embedFile("fixtures/tests/fixtures/decode/delimiters.json");
    const indentation_errors = @embedFile("fixtures/tests/fixtures/decode/indentation-errors.json");
    const numbers = @embedFile("fixtures/tests/fixtures/decode/numbers.json");
    const objects = @embedFile("fixtures/tests/fixtures/decode/objects.json");
    const path_expansion = @embedFile("fixtures/tests/fixtures/decode/path-expansion.json");
    const primitives = @embedFile("fixtures/tests/fixtures/decode/primitives.json");
    const root_form = @embedFile("fixtures/tests/fixtures/decode/root-form.json");
    const validation_errors = @embedFile("fixtures/tests/fixtures/decode/validation-errors.json");
    const whitespace = @embedFile("fixtures/tests/fixtures/decode/whitespace.json");
};

// ============================================================================
// Test Result Tracking
// ============================================================================

const TestResult = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn add(self: *TestResult, other: TestResult) void {
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

// ============================================================================
// Fixture Parsing
// ============================================================================

const FixtureOptions = struct {
    delimiter: ?Delimiter = null,
    indent: ?u8 = null,
    key_folding: ?KeyFoldingMode = null,
    flatten_depth: ?usize = null,
    strict: ?bool = null,
    expand_paths: ?ExpandPathsMode = null,
};

fn parseFixtureOptions(allocator: Allocator, options_val: ?std.json.Value) !FixtureOptions {
    _ = allocator;
    var result = FixtureOptions{};

    const obj = if (options_val) |o| switch (o) {
        .object => |m| m,
        else => return result,
    } else return result;

    if (obj.get("delimiter")) |d| {
        if (d == .string) {
            const delim_str = d.string;
            if (delim_str.len == 1) {
                result.delimiter = switch (delim_str[0]) {
                    ',' => .comma,
                    '|' => .pipe,
                    '\t' => .tab,
                    else => null,
                };
            }
        }
    }

    if (obj.get("indent")) |i| {
        if (i == .integer) {
            result.indent = @intCast(i.integer);
        }
    }

    if (obj.get("keyFolding")) |kf| {
        if (kf == .string) {
            if (std.mem.eql(u8, kf.string, "safe")) {
                result.key_folding = .safe;
            } else if (std.mem.eql(u8, kf.string, "off")) {
                result.key_folding = .off;
            }
        }
    }

    if (obj.get("flattenDepth")) |fd| {
        if (fd == .integer) {
            result.flatten_depth = @intCast(fd.integer);
        }
    }

    if (obj.get("strict")) |s| {
        if (s == .bool) {
            result.strict = s.bool;
        }
    }

    if (obj.get("expandPaths")) |ep| {
        if (ep == .string) {
            if (std.mem.eql(u8, ep.string, "safe")) {
                result.expand_paths = .safe;
            } else if (std.mem.eql(u8, ep.string, "off")) {
                result.expand_paths = .off;
            }
        }
    }

    return result;
}

fn buildEncodeOptions(fixture_opts: FixtureOptions) FullEncodeOptions {
    return .{
        .indent = fixture_opts.indent orelse 2,
        .delimiter = fixture_opts.delimiter orelse .comma,
        .key_folding = fixture_opts.key_folding orelse .off,
        .flatten_depth = fixture_opts.flatten_depth orelse std.math.maxInt(usize),
    };
}

fn buildDecodeOptions(fixture_opts: FixtureOptions) DecodeOptions {
    return .{
        .indent = fixture_opts.indent orelse 2,
        .strict = fixture_opts.strict orelse true,
        .expand_paths = fixture_opts.expand_paths orelse .off,
    };
}

// ============================================================================
// Value Comparison
// ============================================================================

fn valuesEqual(a: Value, b: Value) bool {
    return a.eql(b);
}

fn stdJsonToValue(allocator: Allocator, json_val: std.json.Value) !Value {
    return toon.fromStdJson(allocator, json_val);
}

fn compareJsonValues(allocator: Allocator, actual: std.json.Value, expected: std.json.Value) !bool {
    var actual_val = try stdJsonToValue(allocator, actual);
    defer actual_val.deinit(allocator);

    var expected_val = try stdJsonToValue(allocator, expected);
    defer expected_val.deinit(allocator);

    return valuesEqual(actual_val, expected_val);
}

// ============================================================================
// Test Runners
// ============================================================================

fn runEncodeTest(
    allocator: Allocator,
    test_obj: std.json.ObjectMap,
    fixture_name: []const u8,
) !bool {
    const name = if (test_obj.get("name")) |n| n.string else "unnamed";

    const input_val = test_obj.get("input") orelse {
        std.debug.print("  [SKIP] {s}: missing input\n", .{name});
        return false;
    };

    const expected_val = test_obj.get("expected") orelse {
        std.debug.print("  [SKIP] {s}: missing expected\n", .{name});
        return false;
    };

    const expected_str = switch (expected_val) {
        .string => |s| s,
        else => {
            std.debug.print("  [SKIP] {s}: expected is not a string\n", .{name});
            return false;
        },
    };

    const should_error = if (test_obj.get("shouldError")) |se| se.bool else false;

    const fixture_opts = try parseFixtureOptions(allocator, test_obj.get("options"));
    const encode_opts = buildEncodeOptions(fixture_opts);

    // Convert input to our Value type
    var input_value = try stdJsonToValue(allocator, input_val);
    defer input_value.deinit(allocator);

    // Encode to TOON
    const encoded = toon.encode(allocator, input_value, encode_opts) catch |err| {
        if (should_error) {
            return true;
        }
        std.debug.print("  [FAIL] {s}/{s}: encode error: {any}\n", .{ fixture_name, name, err });
        return false;
    };
    defer allocator.free(encoded);

    if (should_error) {
        std.debug.print("  [FAIL] {s}/{s}: expected error but got success\n", .{ fixture_name, name });
        return false;
    }

    // Normalize: strip trailing newline for comparison
    const actual_trimmed = std.mem.trimRight(u8, encoded, "\n");

    if (std.mem.eql(u8, actual_trimmed, expected_str)) {
        return true;
    }

    std.debug.print("  [FAIL] {s}/{s}:\n", .{ fixture_name, name });
    std.debug.print("    Expected: \"{s}\"\n", .{expected_str});
    std.debug.print("    Actual:   \"{s}\"\n", .{actual_trimmed});
    return false;
}

fn runDecodeTest(
    allocator: Allocator,
    test_obj: std.json.ObjectMap,
    fixture_name: []const u8,
) !bool {
    const name = if (test_obj.get("name")) |n| n.string else "unnamed";

    const input_val = test_obj.get("input") orelse {
        std.debug.print("  [SKIP] {s}: missing input\n", .{name});
        return false;
    };

    const input_str = switch (input_val) {
        .string => |s| s,
        else => {
            std.debug.print("  [SKIP] {s}: input is not a string\n", .{name});
            return false;
        },
    };

    const should_error = if (test_obj.get("shouldError")) |se| se.bool else false;

    const fixture_opts = try parseFixtureOptions(allocator, test_obj.get("options"));
    const decode_opts = buildDecodeOptions(fixture_opts);

    // Decode TOON
    var decoded = toon.decodeWithOptions(allocator, input_str, decode_opts) catch |err| {
        if (should_error) {
            return true;
        }
        std.debug.print("  [FAIL] {s}/{s}: decode error: {any}\n", .{ fixture_name, name, err });
        return false;
    };
    defer decoded.deinit(allocator);

    if (should_error) {
        std.debug.print("  [FAIL] {s}/{s}: expected error but got success\n", .{ fixture_name, name });
        return false;
    }

    const expected_val = test_obj.get("expected") orelse {
        std.debug.print("  [SKIP] {s}: missing expected\n", .{name});
        return false;
    };

    // Convert expected to our Value type
    var expected_value = try stdJsonToValue(allocator, expected_val);
    defer expected_value.deinit(allocator);

    if (valuesEqual(decoded, expected_value)) {
        return true;
    }

    std.debug.print("  [FAIL] {s}/{s}: values do not match\n", .{ fixture_name, name });
    return false;
}

fn runFixture(
    allocator: Allocator,
    fixture_json: []const u8,
    fixture_name: []const u8,
    comptime is_encode: bool,
) !TestResult {
    var result = TestResult{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, fixture_json, .{}) catch |err| {
        std.debug.print("[ERROR] Failed to parse fixture {s}: {any}\n", .{ fixture_name, err });
        return result;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("[ERROR] Fixture {s} root is not an object\n", .{fixture_name});
            return result;
        },
    };

    const tests_val = root.get("tests") orelse {
        std.debug.print("[ERROR] Fixture {s} has no tests array\n", .{fixture_name});
        return result;
    };

    const tests_arr = switch (tests_val) {
        .array => |a| a,
        else => {
            std.debug.print("[ERROR] Fixture {s} tests is not an array\n", .{fixture_name});
            return result;
        },
    };

    for (tests_arr.items) |test_val| {
        const test_obj = switch (test_val) {
            .object => |o| o,
            else => {
                result.skipped += 1;
                continue;
            },
        };

        const passed = if (is_encode)
            try runEncodeTest(allocator, test_obj, fixture_name)
        else
            try runDecodeTest(allocator, test_obj, fixture_name);

        if (passed) {
            result.passed += 1;
        } else {
            result.failed += 1;
        }
    }

    return result;
}

// ============================================================================
// Encode Fixture Tests
// ============================================================================

test "conformance: encode/primitives" {
    const result = try runFixture(testing.allocator, EncodeFixtures.primitives, "encode/primitives", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/objects" {
    const result = try runFixture(testing.allocator, EncodeFixtures.objects, "encode/objects", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/arrays-primitive" {
    const result = try runFixture(testing.allocator, EncodeFixtures.arrays_primitive, "encode/arrays-primitive", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/arrays-nested" {
    const result = try runFixture(testing.allocator, EncodeFixtures.arrays_nested, "encode/arrays-nested", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/arrays-objects" {
    const result = try runFixture(testing.allocator, EncodeFixtures.arrays_objects, "encode/arrays-objects", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/arrays-tabular" {
    const result = try runFixture(testing.allocator, EncodeFixtures.arrays_tabular, "encode/arrays-tabular", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/delimiters" {
    const result = try runFixture(testing.allocator, EncodeFixtures.delimiters, "encode/delimiters", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/key-folding" {
    const result = try runFixture(testing.allocator, EncodeFixtures.key_folding, "encode/key-folding", true);
    try testing.expect(result.failed == 0);
}

test "conformance: encode/whitespace" {
    const result = try runFixture(testing.allocator, EncodeFixtures.whitespace, "encode/whitespace", true);
    try testing.expect(result.failed == 0);
}

// ============================================================================
// Decode Fixture Tests
// ============================================================================

test "conformance: decode/primitives" {
    const result = try runFixture(testing.allocator, DecodeFixtures.primitives, "decode/primitives", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/numbers" {
    const result = try runFixture(testing.allocator, DecodeFixtures.numbers, "decode/numbers", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/objects" {
    const result = try runFixture(testing.allocator, DecodeFixtures.objects, "decode/objects", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/arrays-primitive" {
    const result = try runFixture(testing.allocator, DecodeFixtures.arrays_primitive, "decode/arrays-primitive", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/arrays-nested" {
    const result = try runFixture(testing.allocator, DecodeFixtures.arrays_nested, "decode/arrays-nested", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/arrays-tabular" {
    const result = try runFixture(testing.allocator, DecodeFixtures.arrays_tabular, "decode/arrays-tabular", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/delimiters" {
    const result = try runFixture(testing.allocator, DecodeFixtures.delimiters, "decode/delimiters", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/path-expansion" {
    const result = try runFixture(testing.allocator, DecodeFixtures.path_expansion, "decode/path-expansion", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/blank-lines" {
    const result = try runFixture(testing.allocator, DecodeFixtures.blank_lines, "decode/blank-lines", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/whitespace" {
    const result = try runFixture(testing.allocator, DecodeFixtures.whitespace, "decode/whitespace", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/root-form" {
    const result = try runFixture(testing.allocator, DecodeFixtures.root_form, "decode/root-form", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/validation-errors" {
    const result = try runFixture(testing.allocator, DecodeFixtures.validation_errors, "decode/validation-errors", false);
    try testing.expect(result.failed == 0);
}

test "conformance: decode/indentation-errors" {
    const result = try runFixture(testing.allocator, DecodeFixtures.indentation_errors, "decode/indentation-errors", false);
    try testing.expect(result.failed == 0);
}
