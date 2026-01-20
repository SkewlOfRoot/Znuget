const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");
const Color = utils.Color;
const types = @import("types.zig");
const Package = types.Package;
const PackageVersion = types.PackageVersion;

// .NET specific operations for Znuget.
// Handles parsing .NET solution files and interacting with dotnet CLI.

/// Extract the project file paths from the .NET solution file.
pub fn getProjectFilePaths(solution_path: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var project_paths = std.ArrayList([]const u8){};

    const content = try utils.readFileContent(allocator, solution_path);
    defer allocator.free(content);

    var content_iter = std.mem.splitScalar(u8, content, '\n');

    const base_path = std.fs.path.dirname(solution_path).?;

    while (content_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "Project Path=") != null) {
            if (utils.extractBetweenQuotes(line)) |path| {
                const normalized_path = try std.mem.replaceOwned(u8, allocator, path, "/", "\\");
                defer allocator.free(normalized_path);

                const project_path = try std.fs.path.join(allocator, &.{ base_path, normalized_path });
                try project_paths.append(allocator, project_path);
            }
        }
    }

    return project_paths;
}

/// Check a .NET project file for potential outdated Nuget packages using the dotnet CLI.
pub fn checkForOutdatedPackages(allocator: std.mem.Allocator, project_path: []const u8) !std.ArrayList(Package) {
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
        utils.stdoutPrintInColor("dotnet failed:\n{s}\n", .{stderr}, Color.red);
        return error.DotnetFailed;
    }

    const packages = try processOutdatedPackagesRawOutput(allocator, stdout, project_path);
    return packages;
}

/// Processes the raw string output from the dotnet list command and returns an ArrayList of outdated packages.
fn processOutdatedPackagesRawOutput(allocator: std.mem.Allocator, raw: []const u8, project_path: []const u8) !std.ArrayList(Package) {
    var lines_iter = std.mem.splitScalar(u8, raw, '\n');

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

/// Dry-run of upgrading a .NET package to the latest version.
pub fn upgradeToLatestPackageDry(package: Package) void {
    utils.stdoutPrint("  Would upgrade {s} package version from {s} to {s} \n", .{ package.package_name, package.version.requested, package.version.latest });
}

/// Upgrade .NET Nuget package to the latest version using the dotnet CLI.
pub fn upgradeToLatestPackage(allocator: std.mem.Allocator, package: Package) !void {
    var child = std.process.Child.init(&[_][]const u8{ "dotnet", "add", "package", package.package_name }, allocator);

    child.cwd = std.fs.path.dirname(package.project_path);
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
        utils.stdoutPrintInColor("dotnet failed: {s}\n", .{stderr}, Color.red);
        return error.DotnetFailed;
    }

    processUpgradePackageRawOutput(stdout);
}

/// Processes the raw string output from the dotnet add package command.
fn processUpgradePackageRawOutput(raw: []const u8) void {
    var lines_iter = std.mem.splitScalar(u8, raw, '\n');

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "info : Adding") or std.mem.startsWith(u8, line, "info : Installed") or std.mem.startsWith(u8, line, "info : Package ")) {
            utils.stdoutPrint("  {s}\n", .{line});
        } else if (std.mem.startsWith(u8, line, "info : PackageReference")) {
            utils.stdoutPrintInColor("  {s}\n", .{line}, Color.green);
        } else if (std.mem.startsWith(u8, line, "log  : Restored")) {
            utils.stdoutPrintInColor("  {s}\n", .{line}, Color.blue);
        }
    }
}
