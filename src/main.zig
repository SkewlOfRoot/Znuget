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
        stdout_print("Unknown command: {s}\n\n", .{cmd});
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
        stdout_print("upgrade: missing filename\n", .{});
        return;
    }

    var project_paths = try getProjectFilePaths(filename.?, allocator);
    defer {
        for (project_paths.items) |s| allocator.free(s);
        project_paths.deinit(allocator);
    }

    var packages = std.ArrayList(Package){};
    defer {
        for (packages.items) |*p| p.deinit(allocator);
        packages.deinit(allocator);
    }

    for (project_paths.items) |path| {
        stdout_print("- Checking for outdated packages in project: {s}\n", .{path});
        var project_packages = try checkForOutdatedPackages(allocator, path);
        try packages.appendSlice(allocator, project_packages.items);

        if (project_packages.items.len == 0) {
            stdout_print("  Project is up-to-date.\n\n", .{});
        } else {
            for (project_packages.items) |package| {
                stdout_print("  Found outdated package: '{s}' - '{s}'\n", .{ package.package_name, package.version.requested });
            }
            stdout_print("\n", .{});
        }

        project_packages.clearAndFree(allocator);
    }
}

///
/// Handler for the Help command.
///
fn cmdHelp() !void {
    try printHelp();
}

///
/// Extract the project file paths from the .NET solution file.
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
/// Check a .NET project file for potential outdated Nuget packages using the dotnet CLI.
///
fn checkForOutdatedPackages(allocator: std.mem.Allocator, project_path: []const u8) !std.ArrayList(Package) {
    var child = std.process.Child.init(&[_][]const u8{
        "dotnet",
        "list",
        "package",
        "--outdated",
    }, allocator);

    child.cwd = std.fs.path.dirname(project_path);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    if (term.Exited != 0) {
        std.debug.print("dotnet failed:\n{s}\n", .{stderr});
        return error.DotnetFailed;
    }

    const packages = try parseOutdatedPackagesRawOutput(allocator, stdout, project_path);
    return packages;
}

///
/// Parses the raw string output from the dotnet list command and returns an ArrayList of outdated packages.
///
fn parseOutdatedPackagesRawOutput(allocator: std.mem.Allocator, content: []const u8, project_path: []const u8) !std.ArrayList(Package) {
    var lines_iter = std.mem.splitScalar(u8, content, '\n');

    var packages = std.ArrayList(Package){};

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "   >")) {
            var line_iter = std.mem.splitScalar(u8, line, '\n');

            while (line_iter.next()) |val| {
                var val_iter = std.mem.splitSequence(u8, val, " ");

                var value_list = std.ArrayList([]const u8){};
                defer value_list.deinit(allocator);

                while (val_iter.next()) |v| {
                    if (std.mem.eql(u8, v, "") or std.mem.eql(u8, v, ">")) {
                        continue;
                    }

                    try value_list.append(allocator, v);
                }

                if (value_list.items.len > 0) {
                    const package = Package{
                        .project_path = try allocator.dupe(u8, project_path),
                        .project_name = try allocator.dupe(u8, std.fs.path.stem(project_path)),
                        .package_name = try allocator.dupe(u8, value_list.items[0]),
                        .version = PackageVersion{
                            .requested = try allocator.dupe(u8, value_list.items[1]),
                            .resolved = try allocator.dupe(u8, value_list.items[2]),
                            .latest = try allocator.dupe(u8, value_list.items[3]),
                        },
                    };
                    try packages.append(allocator, package);
                }
            }
        }
    }

    return packages;
}

///
/// Print the help instructions to stdout.
///
fn printHelp() !void {
    stdout_print(
        \\Usage:
        \\  Znuget <command> [options]
        \\
        \\Commands:
        \\  upgrade <solution file> [--dry-run] [--force]
        \\  help
        \\
    , .{});
}

fn stdout_print(comptime text: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);

    const stdout = &stdout_writer.interface;

    stdout.print(text, args) catch |err| {
        stderr_print("Failed to print to stdout: {}\n", .{err});
        return;
    };

    stdout.flush() catch |err| {
        stderr_print("Failed to flush stdout writer: {}", .{err});
        return;
    };
}

fn stderr_print(comptime text: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);

    const stderr = &stderr_writer.interface;

    stderr.print(text, args) catch |err| {
        std.debug.print("Failed to print to stderr: {}\n", .{err});
        return;
    };

    stderr.flush() catch |err| {
        std.debug.print("Failed to flush stderr writer: {}", .{err});
        return;
    };
}

const Package = struct {
    project_name: []const u8,
    project_path: []const u8,
    package_name: []const u8,
    version: PackageVersion,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        allocator.free(self.project_name);
        allocator.free(self.project_path);
        allocator.free(self.package_name);
        self.version.deinit(allocator);
    }
};

const PackageVersion = struct {
    requested: []const u8,
    resolved: []const u8,
    latest: []const u8,

    pub fn deinit(self: *PackageVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.requested);
        allocator.free(self.resolved);
        allocator.free(self.latest);
    }
};
