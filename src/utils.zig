const std = @import("std");

/// Color enum for terminal output.
pub const Color = enum { black, red, green, yellow, blue, margenta, cyan, white, default };

/// Converts a color to the corresponding xterm color code.
fn colorCode(color: Color) []const u8 {
    return switch (color) {
        Color.black => "30",
        Color.red => "31",
        Color.green => "32",
        Color.yellow => "33",
        Color.blue => "34",
        Color.margenta => "35",
        Color.cyan => "36",
        Color.white => "37",
        Color.default => "37",
    };
}

/// Prints to stdout.
pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    stdoutPrintInColor(fmt, args, Color.default);
}

/// Prints to stdout in a specified color.
pub fn stdoutPrintInColor(comptime fmt: []const u8, args: anytype, color: Color) void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);

    const stdout = &stdout_writer.interface;

    const color_code = colorCode(color);

    // Set color
    stdout.print("\x1b[{s}m", .{color_code}) catch {
        return;
    };

    // Print text
    stdout.print(fmt, args) catch |err| {
        stderrPrint("Failed to print to stdout: {}\n", .{err});
        return;
    };
    // Reset color
    stdout.print("\x1b[0m", .{}) catch {
        return;
    };

    stdout.flush() catch |err| {
        stderrPrint("Failed to flush stdout writer: {}", .{err});
        return;
    };
}

/// Prints to stderr.
pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);

    const stderr = &stderr_writer.interface;

    stderr.print(fmt, args) catch |err| {
        std.debug.print("Failed to print to stderr: {}\n", .{err});
        return;
    };

    stderr.flush() catch |err| {
        std.debug.print("Failed to flush stderr writer: {}", .{err});
        return;
    };
}

/// Read the contents from a file.
pub fn readFileContent(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
}

/// Extract the string value between two quotes '"'.
pub fn extractBetweenQuotes(s: []const u8) ?[]const u8 {
    const s_index = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const rest = s[s_index + 1 ..];
    const e_index = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..e_index];
}
