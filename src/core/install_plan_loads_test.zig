//! Tests of the `loads` of a lock entry (lock_libs.zig): `buildLock` takes them from the `depends` of the repodata
//! entry, and `mergeMojos` keeps those of every build. They are in a file of their own so install_plan.zig stays
//! small; mopm_core.zig runs them with the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");
const plan = @import("install_plan.zig");

const index = resolve.MemoryIndex{ .files = &.{
    .{ "tls", plan.recJson("tls", "1.1.0", "", "", plan.fileJson("linux-64", "mojo-tls-1.1.0-mojo1.0.0_0.conda", plan.digests[1])) },
} };

const roots = [_]resolve.Root{.{ .name = "tls", .requirement = "1" }};

/// A repodata.json holding tls, whose entry says `depends`.
fn repodata(comptime depends: []const u8) []const u8 {
    return "{\"info\":{\"subdir\":\"linux-64\"},\"packages\":{},\"packages.conda\":{\"mojo-tls-1.1.0-mojo1.0.0_0.conda\":{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":" ++ depends ++
        ",\"name\":\"mojo-tls\",\"sha256\":\"" ++ plan.digests[1] ++ "\",\"size\":1000,\"subdir\":\"linux-64\",\"version\":\"1.1.0\"}},\"removed\":[]}\n";
}

fn lockWith(a: Allocator, comptime depends: []const u8, diag: *resolve.Diagnostic) resolve.Error!lock.Lock {
    const channel = comptime plan.MemoryChannel{ .files = &.{.{ "linux-64", repodata(depends) }} };
    const res = try resolve.resolve(a, index, .{ .mojo = "1.0.0", .roots = &roots }, diag);
    return plan.buildLock(a, res, "https://conda.mopm.dev/", channel, null, diag);
}

fn expectLoads(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "a lock entry loads the libraries its repodata entry depends on: the names, without Mojo packages, sorted, once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: resolve.Diagnostic = .{};
    const l = lockWith(a, "[\"mojo-compiler ==1.0.0\",\"mojo-http_core >=1\",\"libsqlite >=3.40\",\"libzlib\",\"libsqlite\"]", &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    try std.testing.expectEqual(@as(usize, 1), l.packages.len);
    try expectLoads(&.{ "libsqlite", "libzlib" }, l.packages[0].loads);
}

test "a package that depends on Mojo packages only loads nothing, and its lock text has no loads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: resolve.Diagnostic = .{};
    const l = try lockWith(a, "[\"mojo-compiler ==1.0.0\",\"mojo-http_core >=1\"]", &diag);
    try std.testing.expectEqual(@as(usize, 0), l.packages[0].loads.len);
    try std.testing.expect(std.mem.indexOf(u8, try lock.render(a, l), "loads") == null);
    // An entry with no depends at all is the same.
    const none = try lockWith(a, "[]", &diag);
    try std.testing.expectEqual(@as(usize, 0), none.packages[0].loads.len);
}

test "a depends that is not a list of strings is refused, naming the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: resolve.Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, lockWith(a, "[7]", &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "linux-64/repodata.json: the depends of mojo-tls-1.1.0-mojo1.0.0_0.conda is not a list of strings") != null);
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, lockWith(a, "\"libsqlite\"", &diag));
}

test "the lock of a package that loads a library is not readable until that library is pinned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: resolve.Diagnostic = .{};
    const l = try lockWith(a, "[\"mojo-compiler ==1.0.0\",\"libsqlite\"]", &diag);
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, lock.parse(a, try lock.render(a, l), &why));
    try std.testing.expectEqualStrings("tls: loads libsqlite, which system_libs does not pin for linux-64", why);
}

test "mergeMojos: a version built for two Mojo versions loads the libraries of both builds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var p = lock.Package{ .name = "tls", .version = "1.1.0", .build = "mojo1.0.0_0", .subdir = "linux-64", .channel = "https://conda.mopm.dev/", .url = "https://conda.mopm.dev/linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda", .sha256 = "a" ** 64, .size = 10, .mojo = "1.0.0", .loads = &.{"libzlib"} };
    const first = lock.Lock{ .mojo = "1.0.0", .channels = &.{"https://conda.mopm.dev/"}, .packages = &.{p} };
    p.build = "mojo1.1.0_0";
    p.url = "https://conda.mopm.dev/linux-64/mojo-tls-1.1.0-mojo1.1.0_0.conda";
    p.mojo = "1.1.0";
    p.loads = &.{ "libsqlite", "libzlib" };
    const second = lock.Lock{ .mojo = "1.1.0", .channels = &.{"https://conda.mopm.dev/"}, .packages = &.{p} };
    const merged = try plan.mergeMojos(a, &.{ first, second }, &.{});
    try std.testing.expectEqual(@as(usize, 1), merged.packages.len);
    try expectLoads(&.{ "libsqlite", "libzlib" }, merged.packages[0].loads);
}
