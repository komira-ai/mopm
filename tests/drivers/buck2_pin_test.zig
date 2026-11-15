//! //:buck2_pin: the buck2 release pinned in tools/buck2 is one that reports a real TTL for what the farm holds.
//!
//! Buck2's remote-execution client before release 2026-11-01 wrote `ttl: 0` into every GetActionResult answer, every
//! Execute result and every output file (remote_execution/oss/re_grpc/src/client.rs). A materialization that failed for
//! any reason, such as a reset connection, then said "retrieved N seconds ago with ttl = 0 seconds", as if the farm had
//! dropped the blob. From 2026-11-01 the client reports its `cas_ttl_secs` (3 hours by default). The pin must name that
//! release or a later one, for both platforms, with the size and the sha256 the download is checked against.
//! Shown able to fail: the pin of release 2026-09-15 is refused with the exact message.

const std = @import("std");
const t = std.testing;

/// The first buck2 release whose RE client reports `cas_ttl_secs` instead of 0. Release tags are dates, so they compare as text.
const first_with_ttl = "2026-11-01";
const marker = "releases/download/";

/// The reason `pin` (the text of tools/buck2) is not acceptable, or null. The reason is allocated from `a`.
fn problem(a: std.mem.Allocator, pin: []const u8) !?[]const u8 {
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pin, at, marker)) |i| {
        const start = i + marker.len;
        const end = std.mem.indexOfScalarPos(u8, pin, start, '/') orelse return try a.dupe(u8, "a release URL has no asset name");
        const tag = pin[start..end];
        if (std.mem.order(u8, tag, first_with_ttl) == .lt) {
            return try std.fmt.allocPrint(a, "release {s} writes ttl 0 into every action result and output file; pin {s} or later", .{ tag, first_with_ttl });
        }
        seen += 1;
        at = end;
    }
    if (seen != 2) return try std.fmt.allocPrint(a, "expected 2 release URLs (linux-x86_64, macos-aarch64), found {d}", .{seen});
    inline for (.{ "\"linux-x86_64\"", "\"macos-aarch64\"" }) |platform| {
        if (std.mem.indexOf(u8, pin, platform) == null) return try std.fmt.allocPrint(a, "no {s} entry", .{platform});
    }
    return null;
}

/// The text of tools/buck2: under BUILDRULES_TEST_WORK in the Buck2 build, else the current directory, the repository root.
fn real(a: std.mem.Allocator) ![]u8 {
    const root = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try a.dupe(u8, "."),
        else => return err,
    };
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();
    return dir.readFileAlloc(a, "tools/buck2", 1 << 20);
}

test "the buck2 pinned in tools/buck2 is a release that reports cas_ttl_secs, for both platforms" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try problem(a, try real(a));
    if (found) |why| std.debug.print("tools/buck2: {s}\n", .{why});
    try t.expect(found == null);
}

const old_pin =
    \\"url": "https://github.com/facebook/buck2/releases/download/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst"
    \\"url": "https://github.com/facebook/buck2/releases/download/2026-09-15/buck2-aarch64-apple-darwin.zst"
    \\"linux-x86_64" "macos-aarch64"
;

test "the pin of release 2026-09-15 is refused: that client writes ttl 0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const found = try problem(arena.allocator(), old_pin);
    try t.expectEqualStrings("release 2026-09-15 writes ttl 0 into every action result and output file; pin 2026-11-01 or later", found.?);
}

test "a pin of the first release with the fix, or a later one, is accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "2026-11-01", "2026-11-15", "2027-01-01" }) |tag| {
        const text = try std.mem.replaceOwned(u8, a, old_pin, "2026-09-15", tag);
        try t.expect((try problem(a, text)) == null);
    }
}

test "a pin with one platform, or an unterminated URL, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = "\"url\": \"https://github.com/facebook/buck2/releases/download/2026-11-15/buck2.zst\" \"linux-x86_64\" \"macos-aarch64\"";
    try t.expectEqualStrings("expected 2 release URLs (linux-x86_64, macos-aarch64), found 1", (try problem(a, one)).?);
    try t.expectEqualStrings("a release URL has no asset name", (try problem(a, "releases/download/2026-11-15")).?);
    const named = "releases/download/2026-11-15/a releases/download/2026-11-15/b \"linux-x86_64\"";
    try t.expectEqualStrings("no \"macos-aarch64\" entry", (try problem(a, named)).?);
}
