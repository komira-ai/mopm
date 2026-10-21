//! Golden files for the channels library: the .deb, the control file, Packages, Release and the formula, built from
//! the fixtures in tests/channels/fixtures and compared with tests/channels/golden. The tests run from the repository
//! root. A mismatch prints what was produced, so a deliberate change is a copy of that text into the golden file in
//! the same commit as the change; the golden files are the reviewed record of what the channels publish.
//!
//! The gzip bytes (and so Packages.gz and its line in Release) are the pinned Zig toolchain's deflate output: a
//! toolchain bump that changes them shows up here as a Release golden change and nowhere else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const deb = @import("deb.zig");
const apt = @import("apt.zig");
const formula = @import("formula.zig");

const mtime: u64 = 1700000000;

fn fixture(a: Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "tests/channels/fixtures/{s}", .{name});
    return std.fs.cwd().readFileAlloc(a, path, 1 << 24);
}

fn expectGolden(a: Allocator, name: []const u8, got: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "tests/channels/golden/{s}", .{name});
    const want = std.fs.cwd().readFileAlloc(a, path, 1 << 24) catch |err| {
        std.debug.print("golden {s} is unreadable ({s}); this is what was produced:\n{s}<<<end\n", .{ path, @errorName(err), got });
        return err;
    };
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("golden {s} differs; this is what was produced:\n{s}<<<end\n", .{ path, got });
        return error.GoldenDiffers;
    }
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "{s}\n", .{std.fmt.bytesToHex(d, .lower)});
}

fn package(a: Allocator, version: []const u8, arch: []const u8) !deb.Package {
    const files = try a.alloc(deb.File, 2);
    files[0] = .{ .path = "usr/bin/mopm", .data = try fixture(a, "mopm.bin"), .mode = 0o755 };
    files[1] = .{ .path = "usr/share/doc/mopm/copyright", .data = try fixture(a, "copyright"), .mode = 0o644 };
    return .{
        .name = "mopm",
        .version = version,
        .architecture = arch,
        .maintainer = "mopm authors <apt@mopm.dev>",
        .homepage = "https://mopm.dev",
        .synopsis = "package manager for Mojo",
        .long_description = std.mem.trimRight(u8, try fixture(a, "description.txt"), "\n"),
        .files = files,
        .mtime = mtime,
    };
}

test "golden: the control file and the sha256 of the .deb, both architectures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectGolden(a, "control_amd64.txt", try deb.controlText(a, try package(a, "1.2.3", "amd64")));
    for ([_][]const u8{ "amd64", "arm64" }) |arch| {
        const bytes = try deb.build(a, try package(a, "1.2.3", arch));
        try expectGolden(a, try std.fmt.allocPrint(a, "mopm_1.2.3_{s}.deb.sha256", .{arch}), try sha256Hex(a, bytes));
        // The control file read back out of the bytes is the one that was written.
        const read = try deb.readControl(a, bytes);
        try expectGolden(a, try std.fmt.allocPrint(a, "control_{s}.txt", .{arch}), read);
    }
}

test "golden: Packages of both architectures and the Release, after two additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try apt.stanzaOf(a, try deb.build(a, try package(a, "1.2.2", "amd64")));
    const index1 = try apt.merge(a, &.{}, &.{first}, 25);
    const amd = try apt.stanzaOf(a, try deb.build(a, try package(a, "1.2.3", "amd64")));
    const arm = try apt.stanzaOf(a, try deb.build(a, try package(a, "1.2.3", "arm64")));
    const index2 = try apt.merge(a, index1.stanzas, &.{ amd, arm }, 25);
    try std.testing.expectEqual(@as(usize, 2), index2.added);
    const info = apt.ReleaseInfo{ .origin = "mopm", .label = "mopm", .description = "mopm packages", .date = mtime };
    const files = try apt.tree(a, info, index2.stanzas, &.{ "amd64", "arm64" });
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try expectGolden(a, "Packages_amd64", files[0].data);
    try expectGolden(a, "Packages_arm64", files[2].data);
    try expectGolden(a, "Release", files[4].data);
}

test "golden: the formula for the fixture SHA256SUMS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try formula.render(a, .{
        .name = "mopm",
        .version = "1.2.3",
        .desc = "Package manager for Mojo",
        .homepage = "https://mopm.dev",
        .license = "Apache-2.0",
        .repo = "komira-ai/mopm",
    }, try fixture(a, "SHA256SUMS"));
    try expectGolden(a, "mopm.rb", text);
}
