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
        try cmdUpgrade(allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try cmdHelp();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return;
    }
}

///
/// Handler for the Upgrade command.
///
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

    for (paths.items) |path| {
        var packages = try extractNugetPackagesFromProjectFile(allocator, path);
        defer {
            for (packages.items) |*p| {
                p.deinit(allocator);
            }
            packages.deinit(allocator);
        }

        for (packages.items) |package| {
            std.debug.print("Package: '{s}' - '{s}'\n", .{ package.name, package.version });
        }
    }
}

///
/// Handler for the Help command.
///
fn cmdHelp() !void {
    try printHelp();
}

///
/// Extract the project file paths from the dotnet solution file.
///
fn getProjectFilePaths(solution_path: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var project_paths = std.ArrayList([]const u8){};

    const content = try readFileContent(allocator, solution_path);
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

///
/// Extract any Nuget package references from the dotnet project file.
///
fn extractNugetPackagesFromProjectFile(allocator: std.mem.Allocator, project_file_path: []const u8) !std.ArrayList(Package) {
    const content = try readFileContent(allocator, project_file_path);
    defer allocator.free(content);

    var content_iter = std.mem.splitScalar(u8, content, '\n');

    var list = std.ArrayList(Package){};

    while (content_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "PackageReference") != null) {
            var line_iter = std.mem.splitSequence(u8, line, "Version");

            const s1 = line_iter.next();
            const s2 = line_iter.next();
            if (s1 == null or s1.?.len == line.len) {
                continue; // "Version" not found.
            }

            const package_name = try allocator.dupe(u8, extractBetweenQuotes(s1.?).?);
            const version = try allocator.dupe(u8, extractBetweenQuotes(s2.?).?);
            const package = Package{ .name = package_name, .version = version };

            try list.append(allocator, package);
        }
    }

    return list;
}

///
/// Read the contents from a file.
///
fn readFileContent(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
}

///
/// Extract the string value between two quotes '"'.
///
fn extractBetweenQuotes(s: []const u8) ?[]const u8 {
    const s_index = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const rest = s[s_index + 1 ..];

    const e_index = std.mem.indexOfScalar(u8, rest, '"') orelse return null;

    return rest[0..e_index];
}

///
/// Print the help instructions to stdout.
///
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

const Package = struct {
    name: []const u8,
    version: []const u8,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
    }
};
