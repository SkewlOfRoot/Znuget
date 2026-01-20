const std = @import("std");

/// Represents a package with version information.
pub const Package = struct {
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

/// Represents package version details.
pub const PackageVersion = struct {
    requested: []const u8,
    resolved: []const u8,
    latest: []const u8,

    pub fn deinit(self: *PackageVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.requested);
        allocator.free(self.resolved);
        allocator.free(self.latest);
    }
};
