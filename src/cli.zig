const std = @import("std");
const dotnet = @import("dotnet.zig");
const utils = @import("utils.zig");
const Color = utils.Color;
const Package = @import("types.zig").Package;

// Command-line interface for Znuget.
// Handles argument parsing, command dispatching, and help output.

/// Print the help instructions to stdout.
pub fn printHelp() !void {
    utils.stdoutPrint(
        \\Usage:
        \\  Znuget <command> [options]
        \\
        \\Commands:
        \\  upgrade <solution file> [--dry-run] [--force]
        \\  help
        \\
    , .{});
}

/// Handler for the Help command.
pub fn cmdHelp() !void {
    try printHelp();
}

/// Handler for the Upgrade command.
pub fn cmdUpgrade(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var filename: ?[]const u8 = null;

    var dry_run = false;
    var force = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (filename == null) {
            filename = arg;
        }
    }

    if (filename == null) {
        utils.stdoutPrintInColor("upgrade: missing filename\n", .{}, Color.red);
        return;
    }

    var project_paths = try dotnet.getProjectFilePaths(filename.?, allocator);
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
        utils.stdoutPrint("- Checking for outdated packages in project: {s}\n", .{path});
        var project_packages = try dotnet.checkForOutdatedPackages(allocator, path);
        try packages.appendSlice(allocator, project_packages.items);

        if (project_packages.items.len == 0) {
            utils.stdoutPrintInColor("  Project is up-to-date.\n\n", .{}, Color.green);
        } else {
            for (project_packages.items) |package| {
                utils.stdoutPrintInColor("  Found outdated package: '{s}' - '{s}'\n", .{ package.package_name, package.version.requested }, Color.yellow);

                if (dry_run) {
                    dotnet.upgradeToLatestPackageDry(package);
                } else {
                    try dotnet.upgradeToLatestPackage(allocator, package);
                }
            }
            utils.stdoutPrint("\n", .{});
        }

        project_packages.clearAndFree(allocator);
    }

    utils.stdoutPrintInColor("DONE :)\n", .{}, Color.green);
}
