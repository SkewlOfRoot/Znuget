const std = @import("std");
const Znuget = @import("Znuget");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip executable name
    _ = args_iter.next();

    const cmd = args_iter.next() orelse {
        try printHelp();
        return;
    };

    if (std.mem.eql(u8, cmd, "upgrade")) {

        // "c:\\GitRepositories\\Services.Pax.OfferValidity\\Services.Pax.OfferValidity.slnx"

        try cmdUpgrade(allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try cmdHelp();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return;
    }
}

fn cmdUpgrade(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var filename: ?[]const u8 = null;

    var dry = false;
    var force = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (filename == null) {
            filename = arg;
        }
    }

    if (filename == null) {
        std.debug.print("upgrade: missing filename\n", .{});
        return;
    }

    var paths = try getProjectFilePaths(filename.?, allocator);
    defer {
        for (paths.items) |s| allocator.free(s);
        paths.deinit(allocator);
    }

    for (paths.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}

fn cmdHelp() !void {
    try printHelp();
}

fn getProjectFilePaths(solution_path: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var project_paths = std.ArrayList([]const u8){};

    const content = try std.fs.cwd().readFileAlloc(allocator, solution_path, 10 * 1024 * 1024);
    defer allocator.free(content);

    var content_iter = std.mem.splitScalar(u8, content, '\n');

    const base_path = std.fs.path.dirname(solution_path).?;

    while (content_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "Project Path=") != null) {
            if (extractBetweenQuotes(line)) |path| {
                const normalized_path = try std.mem.replaceOwned(u8, allocator, path, "/", "\\");
                defer allocator.free(normalized_path);

                const project_path = try std.fs.path.join(allocator, &.{ base_path, normalized_path });
                try project_paths.append(allocator, project_path);
            }
        }
    }

    return project_paths;
}

fn extractBetweenQuotes(s: []const u8) ?[]const u8 {
    const s_index = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const rest = s[s_index + 1 ..];

    const e_index = std.mem.indexOfScalar(u8, rest, '"') orelse return null;

    return rest[0..e_index];
}

fn printHelp() !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);

    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\Usage:
        \\  Znuget <command> [options]
        \\
        \\Commands:
        \\  upgrade <solution file> [--dry-run] [--force]
        \\  help
        \\
    , .{});

    try stdout.flush();
}
