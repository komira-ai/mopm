//! The .debs of a release, as the release tools see them: which targets get one, what it is called, and how to rebuild
//! it from the tarball of its target. Shared by release.zig (which refuses to attest a .deb whose binary is not the one
//! the user beta tested) and cut_release.zig (which refuses to publish one). The package itself is written by
//! channels/deb_package.zig, the same code `channels deb-package` runs in release-build.yml, so a rebuild here and the
//! build there give the same bytes for the same binary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const deb_package = @import("channels/deb_package.zig");
const tar = @import("channels/tar.zig");

pub const package_name = "mopm";

/// Where the package metadata (control, copyright, lintian-overrides) is kept, relative to the repository root.
pub const default_packaging = "packaging/deb";

/// A release target that gets a .deb, and the Debian architecture of it. Both are static musl binaries.
pub const Deb = struct { target: []const u8, arch: []const u8 };

pub const debs = [_]Deb{
    .{ .target = "linux-x86_64", .arch = "amd64" },
    .{ .target = "linux-aarch64", .arch = "arm64" },
};

/// `mopm_1.2.3_amd64.deb` (a pre-release 1.2.3-rc.1 is `mopm_1.2.3~rc.1_amd64.deb`, as dpkg names it).
pub fn debName(a: Allocator, version: []const u8, arch: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}_{s}_{s}.deb", .{ package_name, try deb_package.debVersion(a, version), arch });
}

/// `mopm-1.2.3-linux-x86_64.tar.gz`.
pub fn tarballName(a: Allocator, version: []const u8, target: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}-{s}-{s}.tar.gz", .{ package_name, version, target });
}

pub fn loadPackaging(a: Allocator, path: []const u8) !deb_package.Metadata {
    var dir = try std.fs.cwd().openDir(path, .{});
    defer dir.close();
    return deb_package.Metadata.load(a, dir);
}

/// The bytes of `mopm-<version>-<target>/mopm` inside the tarball (`tar_gz` is the .tar.gz file's bytes).
pub fn binaryOf(a: Allocator, tar_gz: []const u8, version: []const u8, target: []const u8) ![]const u8 {
    const want = try std.fmt.allocPrint(a, "{s}-{s}-{s}/{s}", .{ package_name, version, target, package_name });
    for (try tar.read(a, try tar.gunzip(a, tar_gz))) |m| {
        if (std.mem.eql(u8, m.path, want)) return m.data;
    }
    return error.NoBinaryInTarball;
}

/// The .deb that the tarball's binary makes.
pub fn rebuild(a: Allocator, tar_gz: []const u8, version: []const u8, d: Deb, meta: deb_package.Metadata) ![]u8 {
    return deb_package.build(a, .{
        .binary = try binaryOf(a, tar_gz, version, d.target),
        .name = package_name,
        .version = version,
        .arch = d.arch,
        .control = meta.control,
        .copyright = meta.copyright,
        .lintian_overrides = meta.lintian_overrides,
    });
}
