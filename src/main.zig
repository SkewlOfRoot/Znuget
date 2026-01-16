const std = @import("std");
const Znuget = @import("Znuget");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var paths = try getProjectFilePaths("c:\\GitRepositories\\Services.Pax.OfferValidity\\Services.Pax.OfferValidity.slnx", allocator);
    defer {
        for (paths.items) |s| allocator.free(s);
        paths.deinit(allocator);
    }

    for (paths.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
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
