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
        // var project_packages = try extractNugetPackagesFromProjectFile(allocator, path);
        // try packages.appendSlice(allocator, project_packages.items);
        // project_packages.clearAndFree(allocator);

        std.debug.print("Checking for outdated packages in project: {s}\n", .{path});
        var project_packages = try checkForOutdatedPackages(allocator, path);
        try packages.appendSlice(allocator, project_packages.items);
        project_packages.clearAndFree(allocator);
    }

    for (packages.items) |package| {
        std.debug.print("{s}: '{s}' - '{s}'\n", .{ package.project_name, package.package_name, package.version.requested });
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
/// Extract any Nuget package references from the .NET project file.
///
// fn extractNugetPackagesFromProjectFile(allocator: std.mem.Allocator, project_file_path: []const u8) !std.ArrayList(Package) {
//     const content = try readFileContent(allocator, project_file_path);
//     defer allocator.free(content);

//     var content_iter = std.mem.splitScalar(u8, content, '\n');

//     var list = std.ArrayList(Package){};

//     while (content_iter.next()) |line| {
//         if (std.mem.indexOf(u8, line, "PackageReference") != null) {
//             var line_iter = std.mem.splitSequence(u8, line, "Version");

//             const s1 = line_iter.next();
//             const s2 = line_iter.next();
//             if (s1 == null or s1.?.len == line.len) {
//                 continue; // "Version" not found.
//             }

//             const project_name = try allocator.dupe(u8, std.fs.path.stem(project_file_path));
//             const project_path = try allocator.dupe(u8, project_file_path);
//             const package_name = try allocator.dupe(u8, extractBetweenQuotes(s1.?).?);
//             const version = try allocator.dupe(u8, extractBetweenQuotes(s2.?).?);
//             const package = Package{ .project_name = project_name, .project_path = project_path, .package_name = package_name, .version = version };

//             try list.append(allocator, package);
//         }
//     }

//     return list;
// }

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

    var list = std.ArrayList(Package){};

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "   >")) {
            var line_iter = std.mem.splitScalar(u8, line, '\n');

            while (line_iter.next()) |val| {
                std.debug.print("val: {s}\n", .{val});
                var val_iter = std.mem.splitSequence(u8, val, " ");

                var arr = std.ArrayList([]const u8){};
                defer arr.deinit(allocator);

                while (val_iter.next()) |v| {
                    if (std.mem.eql(u8, v, "") or std.mem.eql(u8, v, ">")) {
                        continue;
                    }

                    try arr.append(allocator, v);
                    std.debug.print("v: {s}\n", .{v});
                }

                if (arr.items.len > 0) {
                    const package = Package{
                        .project_path = try allocator.dupe(u8, project_path),
                        .project_name = try allocator.dupe(u8, std.fs.path.stem(project_path)),
                        .package_name = try allocator.dupe(u8, arr.items[0]),
                        .version = PackageVersion{
                            .requested = try allocator.dupe(u8, arr.items[1]),
                            .resolved = try allocator.dupe(u8, arr.items[2]),
                            .latest = try allocator.dupe(u8, arr.items[3]),
                        },
                    };
                    try list.append(allocator, package);
                }
            }
        }
    }

    return list;
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
