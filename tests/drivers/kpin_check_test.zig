//! //:kpin_check: `kpin check` (buildrules' kpin, the tool that writes the locks and the weekly
//! update runs) over every pins.lock.bzl of the repository, run by Buck2 as a test.
//! What it catches: a lock whose header, or whose sri512 integrity, is not what its
//! pins.toml and package-lock.json produce. What it does NOT catch: a changed sha256 or
//! size; those cannot be derived offline, and are caught only where a lock is consumed
//! (npm_modules downloads verify the digest), which service/infra/{access,dns,stacks}
//! and tools/node do. Every lock listed is loaded by a BUCK file (the site and the API use
//! buildrules.lock.bzl, and their old kpin locks are gone). Shown able to fail: the same lock with the header of another tool
//! must be refused.
//!
//! The sets are the lines of KPIN_SETS in .github/workflows/kpin-update.yml; the test
//! fails if the two lists differ, so a new lock cannot go unchecked.

const std = @import("std");
const h = @import("harness.zig");

/// pins.toml, lock, then the package-lock.json files (none for tools/node).
const Set = struct { pins: []const u8, lock: []const u8, npm: ?[]const u8 };

const sets = [_]Set{
    .{ .pins = "tools/node/pins.toml", .lock = "tools/node/pins.lock.bzl", .npm = null },
    .{ .pins = "service/pins.toml", .lock = "service/infra/access/pins.lock.bzl", .npm = "service/infra/access/package-lock.json" },
    .{ .pins = "service/pins.toml", .lock = "service/infra/dns/pins.lock.bzl", .npm = "service/infra/dns/package-lock.json" },
    .{ .pins = "service/pins.toml", .lock = "service/infra/stacks/pins.lock.bzl", .npm = "service/infra/stacks/package-lock.json" },
};

fn kpinCheck(a: std.mem.Allocator, kpin: []const u8, work: []const u8, pins: []const u8, lock: []const u8, npm: ?[]const u8) !h.Ran {
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ kpin, "check", "--pins", pins, "--lock", lock });
    if (npm) |n| try argv.appendSlice(&.{ "--npm", n });
    var env = std.process.EnvMap.init(a);
    return h.run(a, argv.items, &env, .{ .cwd = work });
}

test "kpin check accepts every lock (header and sri512 match pins.toml and package-lock.json)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const kpin = try h.toolPathAbs(a, "KPIN");
    const work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    var rep = h.Report{};
    for (sets) |s| {
        const r = try kpinCheck(a, kpin, work, s.pins, s.lock, s.npm);
        std.debug.print("kpin check {s}: exit {d}\n{s}", .{ s.lock, r.code, r.text });
        rep.check(s.lock, !r.signaled and r.code == 0, "kpin check refused the lock: header or sri512 differs from what its inputs produce");
    }
    try rep.finish();
}

test "kpin check refuses a lock that names another tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const kpin = try h.toolPathAbs(a, "KPIN");
    const work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const s = sets[sets.len - 1]; // an npm set (service/infra/stacks)
    const good = try h.readFile(a, try h.join(a, &.{ work, s.lock }));
    const want = "#   ./buck2 run buildrules//rules/kpin -- lock\n";
    const at = std.mem.indexOf(u8, good, want) orelse return error.TestUnexpectedResult;
    const stale = try std.mem.concat(a, u8, &.{ good[0..at], "#   ./buck2 run komira//tools/build/kpin -- lock\n", good[at + want.len ..] });
    try h.writeFile(try h.join(a, &.{ work, "stale.pins.lock.bzl" }), stale);
    const r = try kpinCheck(a, kpin, work, s.pins, "stale.pins.lock.bzl", s.npm);
    std.debug.print("kpin check of the stale lock: exit {d}\n{s}", .{ r.code, r.text });
    try std.testing.expect(!r.signaled and r.code == 1);
}

test "the sets are the sets kpin-update.yml lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const yml = try h.readFile(a, try h.join(a, &.{ work, ".github/workflows/kpin-update.yml" }));
    for (sets) |s| {
        const line = try h.fmt(a, "{s} {s}", .{ s.pins, s.lock });
        if (!h.contains(yml, line)) {
            std.debug.print("kpin-update.yml KPIN_SETS has no line starting `{s}`\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, yml, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trimLeft(u8, l, " ");
        if (std.mem.endsWith(u8, std.mem.trimRight(u8, t, " "), "pins.lock.bzl") or std.mem.indexOf(u8, t, "pins.lock.bzl ") != null) {
            if (std.mem.startsWith(u8, t, "tools/") or std.mem.startsWith(u8, t, "service/") or std.mem.startsWith(u8, t, "site/")) listed += 1;
        }
    }
    try std.testing.expectEqual(sets.len, listed);
}
