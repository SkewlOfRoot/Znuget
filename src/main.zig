const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");
const Color = utils.Color;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip executable name
    _ = args_iter.next();

    const cmd = args_iter.next() orelse {
        try cli.printHelp();
        return;
    };

    if (std.mem.eql(u8, cmd, "upgrade")) {
        try cli.cmdUpgrade(allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try cli.cmdHelp();
    } else {
        utils.stdoutPrintInColor("Unknown command: {s}\n\n", .{cmd}, Color.red);
        try cli.printHelp();
        return;
    }
}
