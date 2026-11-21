//! Tests of the unit graph for each Mojo version mopm pins a toolchain for (1.0.0, 1.1.0, 1.2.0): the toolchain
//! section names that version's mojo-compiler on every platform, each version's closure hash is its own, a lock for
//! two versions gives each its own toolchain, and a version mopm pins nothing for is refused naming the pinned ones.
//! They are in a file of their own so unit_graph.zig stays under the size limit; mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const ug = @import("unit_graph.zig");
const Graph = ug.Graph;
const toolchainFor = ug.toolchainFor;
const lock_subdirs = ug.lock_subdirs;

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

/// A package with one library and no dependencies, in `dir`.
fn emptyApp(dir: std.fs.Dir) !void {
    try put(dir, "src/app/__init__.mojo", "def run():\n    pass\n");
    try put(dir, "tests/test_app.mojo", "from app import run\n\ndef main():\n    run()\n");
}

/// One Mojo version's recorded closures in a lock: `(subdir, hash)` pairs.
const Recorded = struct { mojo: []const u8, closures: []const [2][]const u8 };

/// A lock with no packages, locked for the versions of `recorded` in that order, recording their closures.
fn lockRecording(a: Allocator, recorded: []const Recorded, why: *[]const u8) !lock.Lock {
    var text = std.ArrayList(u8).init(a);
    try text.appendSlice("{\"lock_version\": 3, \"mojo\": [");
    for (recorded, 0..) |r, i| try text.writer().print("{s}\"{s}\"", .{ if (i == 0) "" else ", ", r.mojo });
    try text.appendSlice("], \"toolchain\": {");
    for (recorded, 0..) |r, i| {
        try text.writer().print("{s}\"{s}\": {{", .{ if (i == 0) "" else ", ", r.mojo });
        for (r.closures, 0..) |c, j| try text.writer().print("{s}\"{s}\": \"{s}\"", .{ if (j == 0) "" else ", ", c[0], c[1] });
        try text.appendSlice("}");
    }
    try text.appendSlice("}, \"channels\": [\"https://conda.mopm.dev/\"], \"packages\": []}\n");
    return lock.parse(a, text.items, why);
}

/// The closures this mopm pins for `mojo` on every platform, as a lock records them.
fn pinnedClosures(a: Allocator, mojo: []const u8, why: *[]const u8) ![]const [2][]const u8 {
    var out = std.ArrayList([2][]const u8).init(a);
    for (lock_subdirs) |subdir| try out.append(.{ subdir, (try toolchainFor(a, mojo, subdir, why)).closure_sha256 });
    return out.items;
}

/// The unit graph of `example/app`, whose manifest lists `listed` (a TOML array), for `mojo` on `subdir`.
fn graphFor(a: Allocator, dir: []const u8, listed: []const u8, l: lock.Lock, mojo: []const u8, subdir: []const u8, why: *[]const u8) !Graph {
    var diag: manifest.Diagnostic = .{};
    const toml = try std.fmt.allocPrint(a, "[package]\nname = \"example/app\"\nversion = \"1.0.0\"\nmojo = {s}\n", .{listed});
    const m = try manifest.parse(a, toml, &diag);
    return ug.build(a, .{ .dir = dir, .m = m, .members = &.{}, .l = l, .subdir = subdir, .mojo = mojo }, why);
}

/// The mojo-compiler package the planning read of conda.modular.com gives for a version and platform: the url, its
/// sha256 and its size, independent of the closure files.
const Compiler = struct { mojo: []const u8, subdir: []const u8, sha256: []const u8, size: u64 };

const compilers = [_]Compiler{
    .{ .mojo = "1.1.0", .subdir = "linux-64", .sha256 = "1ff52b39a0d2a1bedb8c4705aadc460205ca62fc19f63426bc545e4b60a31aa0", .size = 69781261 },
    .{ .mojo = "1.1.0", .subdir = "linux-aarch64", .sha256 = "6d764a80411401b0e04ef4c8e779d7b09564cb0011d382986aefe189378451d1", .size = 67816551 },
    .{ .mojo = "1.1.0", .subdir = "osx-arm64", .sha256 = "6b0bac64c58040eed477c77a998ee685168b52f34256397867e85e1024d7f0a9", .size = 62368467 },
    .{ .mojo = "1.2.0", .subdir = "linux-64", .sha256 = "a746d7db173a9882e7073ae6d905acfe383a754faecb4a53710b7b90db377e6b", .size = 71258238 },
    .{ .mojo = "1.2.0", .subdir = "linux-aarch64", .sha256 = "a10c210e81877d47369f53b918a2b82da635908d44088ef52ffeb7035b297f23", .size = 69162897 },
    .{ .mojo = "1.2.0", .subdir = "osx-arm64", .sha256 = "1f5811bc7ff86dc8a684ddab6d9612a966529935fa184e204990323e573228de", .size = 63449264 },
};

test "plan --unit-graph for a package of mojo 1.1.0 or 1.2.0 names that version's mojo-compiler on every platform, and each closure hash is its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    // The 1.0.0 hashes the other versions must differ from.
    var seen = std.ArrayList([]const u8).init(a);
    for (try pinnedClosures(a, "1.0.0", &why)) |c| try seen.append(c[1]);

    for (compilers) |want| {
        const listed = try std.fmt.allocPrint(a, "[\"{s}\"]", .{want.mojo});
        const l = try lockRecording(a, &.{.{ .mojo = want.mojo, .closures = try pinnedClosures(a, want.mojo, &why) }}, &why);
        const g = graphFor(a, dir, listed, l, want.mojo, want.subdir, &why) catch |e| {
            std.debug.print("mojo {s} on {s} refused: {s}\n", .{ want.mojo, want.subdir, why });
            return e;
        };
        const text = try ug.render(a, .{ .package = g.package, .mojo = g.mojo, .toolchain = g.toolchain, .units = g.units });
        const head = try std.fmt.allocPrint(a, "  \"mojo\": \"{s}\",\n  \"toolchain\": {{\n    \"mojo\": \"{s}\",\n    \"subdir\": \"{s}\",\n", .{ want.mojo, want.mojo, want.subdir });
        const line = try std.fmt.allocPrint(a, "{{\"name\": \"mojo-compiler\", \"version\": \"{s}\", \"url\": \"https://conda.modular.com/max/{s}/mojo-compiler-{s}-release.conda\", \"sha256\": \"{s}\", \"size\": {d}}}", .{ want.mojo, want.subdir, want.mojo, want.sha256, want.size });
        const unit = try std.fmt.allocPrint(a, "\"id\": \"example/app@1.0.0#mojo{s}/lib\"", .{want.mojo});
        for ([_][]const u8{ head, line, unit }) |part| {
            if (std.mem.indexOf(u8, text, part) == null) {
                std.debug.print("---- the graph of mojo {s} on {s} lacks ----\n{s}\n---- graph ----\n{s}---- end ----\n", .{ want.mojo, want.subdir, part, text });
                return error.TestUnexpectedResult;
            }
        }
        // Mojo 1.1.0 and 1.2.0 are linked by the Zig 1.0.0 is linked by, for the same C target.
        const old = try toolchainFor(a, "1.0.0", want.subdir, &why);
        try std.testing.expectEqualStrings(old.zig.sha256, g.toolchain.zig.sha256);
        try std.testing.expectEqualStrings(old.cc_target, g.toolchain.cc_target);
        try std.testing.expectEqual(old.components.len, g.toolchain.components.len);

        const h = g.toolchain.closure_sha256;
        try std.testing.expect(lock.isSha256(h));
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, h)) {
                std.debug.print("mojo {s} on {s} has the closure hash of another toolchain: {s}\n", .{ want.mojo, want.subdir, h });
                return error.TestUnexpectedResult;
            }
        }
        try seen.append(h);
    }
    // Three versions on three platforms: nine toolchains, nine hashes.
    try std.testing.expectEqual(@as(usize, 9), seen.items.len);
}

test "a package of mojo 1.0.0 and 1.1.0 gets one toolchain per version from one lock, and a hash recorded under the other version is stale" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    const c10 = try pinnedClosures(a, "1.0.0", &why);
    const c11 = try pinnedClosures(a, "1.1.0", &why);
    const l = try lockRecording(a, &.{ .{ .mojo = "1.0.0", .closures = c10 }, .{ .mojo = "1.1.0", .closures = c11 } }, &why);
    try std.testing.expectEqual(@as(usize, 6), l.closures.len);
    // Written and read again, the lock is the same text.
    const text = try lock.render(a, l);
    try std.testing.expectEqualStrings(text, try lock.render(a, try lock.parse(a, text, &why)));

    const listed = "[\"1.0.0\", \"1.1.0\"]";
    for (lock_subdirs, 0..) |subdir, i| {
        const g0 = try graphFor(a, dir, listed, l, "1.0.0", subdir, &why);
        const g1 = graphFor(a, dir, listed, l, "1.1.0", subdir, &why) catch |e| {
            std.debug.print("mojo 1.1.0 on {s} refused: {s}\n", .{ subdir, why });
            return e;
        };
        try std.testing.expectEqualStrings("1.0.0", g0.toolchain.mojo);
        try std.testing.expectEqualStrings("1.1.0", g1.toolchain.mojo);
        try std.testing.expectEqualStrings(c10[i][1], g0.toolchain.closure_sha256);
        try std.testing.expectEqualStrings(c11[i][1], g1.toolchain.closure_sha256);
        try std.testing.expect(!std.mem.eql(u8, g0.toolchain.closure_sha256, g1.toolchain.closure_sha256));
        try std.testing.expect(g0.find("example/app@1.0.0#mojo1.0.0/lib") != null);
        try std.testing.expect(g1.find("example/app@1.0.0#mojo1.1.0/lib") != null);
    }

    // A lock that records 1.0.0's closures under 1.1.0 too was not made by this mopm for 1.1.0.
    const stale = try lockRecording(a, &.{ .{ .mojo = "1.0.0", .closures = c10 }, .{ .mojo = "1.1.0", .closures = c10 } }, &why);
    try std.testing.expectError(error.Refused, graphFor(a, dir, listed, stale, "1.1.0", "linux-64", &why));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm.lock records toolchain closure {s} for mojo 1.1.0 on linux-64, but this mopm pins {s}; run 'mopm lock'", .{ c10[0][1], c11[0][1] }), why);
    _ = try graphFor(a, dir, listed, stale, "1.0.0", "linux-64", &why);
}

test "a Mojo version mopm pins no toolchain for is refused on every platform, naming each version it pins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try emptyApp(tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    // The next minor, a patch of a pinned version (1.1.1 and 1.2.1 were never released), one before the first, and
    // a version string that is not one.
    for ([_][]const u8{ "1.3.0", "1.1.1", "1.2.1", "0.26.0", "1.1", "" }) |mojo| {
        for (lock_subdirs) |subdir| {
            const want = try std.fmt.allocPrint(a, "mopm has no pinned toolchain for mojo {s} on {s} (it pins mojo 1.0.0, 1.1.0, 1.2.0 on linux-64, linux-aarch64 and osx-arm64)", .{ mojo, subdir });
            try std.testing.expectError(error.Refused, toolchainFor(a, mojo, subdir, &why));
            try std.testing.expectEqualStrings(want, why);
            try std.testing.expectError(error.Refused, ug.pinnedClosure(a, mojo, subdir, &why));
            try std.testing.expectEqualStrings(want, why);
        }
    }
    // The graph is refused the same way, before any source is read.
    const l = try lockRecording(a, &.{.{ .mojo = "1.3.0", .closures = &.{.{ "linux-64", "a" ** 64 }} }}, &why);
    try std.testing.expectError(error.Refused, graphFor(a, dir, "[\"1.3.0\"]", l, "1.3.0", "linux-64", &why));
    try std.testing.expectEqualStrings("mopm has no pinned toolchain for mojo 1.3.0 on linux-64 (it pins mojo 1.0.0, 1.1.0, 1.2.0 on linux-64, linux-aarch64 and osx-arm64)", why);
}
