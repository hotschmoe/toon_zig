const std = @import("std");
const toon_zig = @import("toon_zig");

pub fn main() !void {
    var buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("tzu - TOON Zig Implementation (spec v{s})\n", .{toon_zig.constants.spec_version});
    try stdout.flush();
}

test "library exports constants" {
    try std.testing.expectEqualStrings("3.0", toon_zig.constants.spec_version);
    try std.testing.expectEqual(@as(u8, ','), toon_zig.Delimiter.comma.char());
}
