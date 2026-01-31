//! tzu - TOON Zig Implementation CLI
//!
//! Command-line interface for converting between JSON and TOON formats.
//!
//! Usage:
//!   tzu encode [options] [input] [-o output]   # JSON -> TOON
//!   tzu decode [options] [input] [-o output]   # TOON -> JSON
//!   tzu -e [options] [input] [-o output]       # Shorthand for encode
//!   tzu -d [options] [input] [-o output]       # Shorthand for decode
//!   tzu --help                                 # Show help
//!   tzu --version                              # Show version

const std = @import("std");
const toon_zig = @import("toon_zig");

const version = "0.1.0";

// ============================================================================
// CLI Arguments
// ============================================================================

const Mode = enum {
    encode,
    decode,
    help,
    version,
};

const Args = struct {
    mode: Mode,
    input_path: ?[]const u8,
    output_path: ?[]const u8,
    show_stats: bool,
    delimiter: toon_zig.Delimiter,
    key_folding: toon_zig.KeyFoldingMode,
    expand_paths: bool,
    indent: u8,
    strict: bool,
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    _ = allocator;

    var args = Args{
        .mode = .help,
        .input_path = null,
        .output_path = null,
        .show_stats = false,
        .delimiter = .comma,
        .key_folding = .off,
        .expand_paths = false,
        .indent = 2,
        .strict = true,
    };

    var i: usize = 1; // Skip program name
    var positional_count: usize = 0;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.mode = .help;
            return args;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args.mode = .version;
            return args;
        } else if (std.mem.eql(u8, arg, "encode") or std.mem.eql(u8, arg, "-e")) {
            args.mode = .encode;
        } else if (std.mem.eql(u8, arg, "decode") or std.mem.eql(u8, arg, "-d")) {
            args.mode = .decode;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingOutputPath;
            args.output_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--stats")) {
            args.show_stats = true;
        } else if (std.mem.eql(u8, arg, "--delimiter=pipe") or std.mem.eql(u8, arg, "-D|")) {
            args.delimiter = .pipe;
        } else if (std.mem.eql(u8, arg, "--delimiter=tab") or std.mem.eql(u8, arg, "-Dt")) {
            args.delimiter = .tab;
        } else if (std.mem.eql(u8, arg, "--key-folding") or std.mem.eql(u8, arg, "-k")) {
            args.key_folding = .safe;
        } else if (std.mem.eql(u8, arg, "--expand-paths") or std.mem.eql(u8, arg, "-x")) {
            args.expand_paths = true;
        } else if (std.mem.eql(u8, arg, "--lenient") or std.mem.eql(u8, arg, "-l")) {
            args.strict = false;
        } else if (std.mem.startsWith(u8, arg, "--indent=")) {
            const val = arg["--indent=".len..];
            args.indent = std.fmt.parseInt(u8, val, 10) catch 2;
        } else if (arg[0] != '-') {
            // Positional argument (input file)
            if (positional_count == 0) {
                args.input_path = arg;
                positional_count += 1;
            }
        }
    }

    return args;
}

// ============================================================================
// I/O Helpers
// ============================================================================

fn readInput(allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    if (path) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    } else {
        // Read from stdin
        const stdin = std.fs.File.stdin();
        return try stdin.readToEndAlloc(allocator, 100 * 1024 * 1024);
    }
}

fn writeOutput(path: ?[]const u8, data: []const u8) !void {
    if (path) |p| {
        const file = try std.fs.cwd().createFile(p, .{});
        defer file.close();
        try file.writeAll(data);
    } else {
        try std.fs.File.stdout().writeAll(data);
    }
}

// ============================================================================
// Statistics
// ============================================================================

fn printStats(stderr: anytype, input_size: usize, output_size: usize) void {
    const input_tokens = (input_size + 3) / 4;
    const output_tokens = (output_size + 3) / 4;
    const reduction = if (input_size > 0)
        @as(i64, @intCast(input_size)) - @as(i64, @intCast(output_size))
    else
        0;
    const pct = if (input_size > 0)
        @as(f64, @floatFromInt(reduction)) / @as(f64, @floatFromInt(input_size)) * 100.0
    else
        0.0;

    stderr.print("\n--- Statistics ---\n", .{}) catch {};
    stderr.print("Input:  {d} bytes (~{d} tokens)\n", .{ input_size, input_tokens }) catch {};
    stderr.print("Output: {d} bytes (~{d} tokens)\n", .{ output_size, output_tokens }) catch {};
    if (reduction > 0) {
        stderr.print("Saved:  {d} bytes ({d:.1}%)\n", .{ reduction, pct }) catch {};
    } else if (reduction < 0) {
        stderr.print("Added:  {d} bytes ({d:.1}%)\n", .{ -reduction, -pct }) catch {};
    }
    stderr.flush() catch {};
}

// ============================================================================
// Commands
// ============================================================================

fn runEncode(allocator: std.mem.Allocator, args: Args) !void {
    const input = try readInput(allocator, args.input_path);
    defer allocator.free(input);

    const options = toon_zig.FullEncodeOptions{
        .indent = args.indent,
        .delimiter = args.delimiter,
        .key_folding = args.key_folding,
    };

    const output = try toon_zig.jsonToToonWithOptions(allocator, input, options);
    defer allocator.free(output);

    try writeOutput(args.output_path, output);

    if (args.show_stats) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        printStats(&stderr_writer.interface, input.len, output.len);
    }
}

fn runDecode(allocator: std.mem.Allocator, args: Args) !void {
    const input = try readInput(allocator, args.input_path);
    defer allocator.free(input);

    const output = if (args.expand_paths)
        try toon_zig.toonToJsonWithPathExpansion(allocator, input)
    else
        try toon_zig.toonToJson(allocator, input);
    defer allocator.free(output);

    try writeOutput(args.output_path, output);

    if (args.show_stats) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        printStats(&stderr_writer.interface, input.len, output.len);
    }
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\tzu - TOON Zig Implementation (spec v
    );
    try writer.writeAll(toon_zig.constants.spec_version);
    try writer.writeAll(
        \\)
        \\
        \\USAGE:
        \\  tzu encode [options] [input] [-o output]   JSON -> TOON
        \\  tzu decode [options] [input] [-o output]   TOON -> JSON
        \\  tzu -e [options] [input] [-o output]       Shorthand for encode
        \\  tzu -d [options] [input] [-o output]       Shorthand for decode
        \\
        \\OPTIONS:
        \\  -h, --help              Show this help
        \\  -v, --version           Show version
        \\  -o, --output <file>     Output file (default: stdout)
        \\  --stats                 Show input/output statistics
        \\
        \\ENCODE OPTIONS:
        \\  --delimiter=pipe        Use | as array delimiter
        \\  --delimiter=tab         Use tab as array delimiter
        \\  -k, --key-folding       Enable key folding (a.b.c: 1)
        \\  --indent=<n>            Spaces per indent level (default: 2)
        \\
        \\DECODE OPTIONS:
        \\  -x, --expand-paths      Expand dotted keys (a.b: 1 -> {a:{b:1}})
        \\  -l, --lenient           Disable strict validation
        \\
        \\EXAMPLES:
        \\  # Convert JSON to TOON
        \\  tzu encode data.json -o data.toon
        \\  cat data.json | tzu -e > data.toon
        \\
        \\  # Convert TOON to JSON
        \\  tzu decode data.toon -o data.json
        \\  cat data.toon | tzu -d > data.json
        \\
        \\  # Roundtrip test
        \\  cat data.json | tzu -e | tzu -d
        \\
        \\  # With statistics
        \\  tzu encode data.json --stats
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.print("tzu {s} (TOON spec v{s})\n", .{ version, toon_zig.constants.spec_version });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = parseArgs(allocator, argv) catch |err| {
        try stderr.print("Error parsing arguments: {}\n", .{err});
        try printHelp(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    switch (args.mode) {
        .help => {
            try printHelp(stdout);
            try stdout.flush();
        },
        .version => {
            try printVersion(stdout);
            try stdout.flush();
        },
        .encode => {
            runEncode(allocator, args) catch |err| {
                try stderr.print("Encode error: {}\n", .{err});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .decode => {
            runDecode(allocator, args) catch |err| {
                try stderr.print("Decode error: {}\n", .{err});
                try stderr.flush();
                std.process.exit(1);
            };
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "library exports constants" {
    try std.testing.expectEqualStrings("3.0", toon_zig.constants.spec_version);
    try std.testing.expectEqual(@as(u8, ','), toon_zig.Delimiter.comma.char());
}

test "parseArgs encode mode" {
    const argv = [_][:0]const u8{ "tzu", "encode", "input.json" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.encode, args.mode);
    try std.testing.expectEqualStrings("input.json", args.input_path.?);
}

test "parseArgs decode mode short" {
    const argv = [_][:0]const u8{ "tzu", "-d", "input.toon" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.decode, args.mode);
    try std.testing.expectEqualStrings("input.toon", args.input_path.?);
}

test "parseArgs with output" {
    const argv = [_][:0]const u8{ "tzu", "-e", "in.json", "-o", "out.toon" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.encode, args.mode);
    try std.testing.expectEqualStrings("in.json", args.input_path.?);
    try std.testing.expectEqualStrings("out.toon", args.output_path.?);
}

test "parseArgs with options" {
    const argv = [_][:0]const u8{ "tzu", "-e", "--key-folding", "--stats", "--indent=4" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.encode, args.mode);
    try std.testing.expectEqual(toon_zig.KeyFoldingMode.safe, args.key_folding);
    try std.testing.expect(args.show_stats);
    try std.testing.expectEqual(@as(u8, 4), args.indent);
}

test "parseArgs help" {
    const argv = [_][:0]const u8{ "tzu", "--help" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.help, args.mode);
}

test "parseArgs version" {
    const argv = [_][:0]const u8{ "tzu", "-v" };
    const args = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Mode.version, args.mode);
}
