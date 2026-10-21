// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/zig/zig_launch_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! Unit tests of zig_launch.zig: the pure parts of the zig_test runner. Its
//! process behaviour (the applets as PATH, the exit status of a failing test,
//! the driver's data and tools) is held by tests//functional/zig_rules and
//! tests//negative/zig_rules, which run through it.
const std = @import("std");
const L = @import("zig_launch.zig");
const t = std.testing;

fn ok(args: []const []const u8) !L.Plan {
    var diag: []const u8 = "";
    return L.parse(args, &diag);
}

fn bad(args: []const []const u8, want: []const u8) !void {
    var diag: []const u8 = "";
    try t.expectError(error.Usage, L.parse(args, &diag));
    try t.expectEqualStrings(want, diag);
}

test "parse: the whole command line of a zig_test" {
    const p = try ok(&.{ "test", "--busybox", "bb", "--zig", "z", "--out", "o", "--stamp", "passed\n", "--", "test", "-target", "x", "a.zig" });
    try t.expectEqualStrings("bb", p.busybox);
    try t.expectEqualStrings("z", p.zig_dir.?);
    try t.expect(p.exec == null);
    try t.expectEqualStrings("o", p.out);
    try t.expectEqualStrings("passed\n", p.stamp);
    try t.expect(!p.isDriver());
    try t.expectEqual(@as(usize, 4), p.zig_args.len);
    try t.expectEqualStrings("a.zig", p.zig_args[3]);
}

test "parse: a manifest, even of an empty list, makes a driver test" {
    const p = try ok(&.{ "test", "--busybox", "b", "--zig", "z", "--out", "o", "--stamp", "s", "--tools", "m", "--", "test", "a.zig" });
    try t.expect(p.isDriver());
    try t.expect(p.data == null);
    try t.expectEqualStrings("m", p.tools.?);
    const q = try ok(&.{ "test", "--data", "d", "--busybox", "b", "--zig", "z", "--out", "o", "--stamp", "s", "--", "test", "a.zig" });
    try t.expect(q.isDriver());
}

test "parse: arguments after the double dash are zig's, whatever they look like" {
    const p = try ok(&.{ "test", "--busybox", "b", "--zig", "z", "--out", "o", "--stamp", "s", "--", "--out", "--stamp", "--" });
    try t.expectEqual(@as(usize, 3), p.zig_args.len);
    try t.expectEqualStrings("--out", p.zig_args[0]);
}

test "parse: refusals" {
    try bad(&.{}, "the subcommand is `test` or `run`");
    try bad(&.{"build"}, "the subcommand is `test` or `run`");
    try bad(&.{ "test", "--bogus", "x" }, "unknown argument");
    try bad(&.{ "test", "--out" }, "an option has no value");
    try bad(&.{ "test", "--out", "a", "--out", "b" }, "an option is given twice");
    try bad(&.{ "test", "--busybox", "b", "--zig", "z", "--out", "o", "--", "test" }, "--busybox, --zig, --out and --stamp are required");
    try bad(&.{ "test", "--busybox", "b", "--zig", "z", "--out", "o", "--stamp", "s" }, "the zig arguments follow `--`");
    try bad(&.{ "test", "--busybox", "b", "--zig", "z", "--out", "o", "--stamp", "s", "--" }, "no zig arguments after `--`");
}

test "parse: `run` takes a program of the action's own, not zig, and may give it no arguments" {
    const p = try ok(&.{ "run", "--busybox", "bb", "--exec", "tools/cover", "--out", "o", "--stamp", "s", "--data", "d", "--", "--zig", "z" });
    try t.expectEqualStrings("tools/cover", p.exec.?);
    try t.expect(p.zig_dir == null);
    try t.expect(p.isDriver());
    try t.expectEqual(@as(usize, 2), p.zig_args.len);
    const q = try ok(&.{ "run", "--busybox", "bb", "--exec", "x", "--out", "o", "--stamp", "s", "--" });
    try t.expectEqual(@as(usize, 0), q.zig_args.len);
}

test "parse: `run` and `test` each refuse the other's option and name their own required ones" {
    try bad(&.{ "run", "--busybox", "b", "--zig", "z", "--exec", "x", "--out", "o", "--stamp", "s", "--", "a" }, "unknown argument");
    try bad(&.{ "test", "--busybox", "b", "--zig", "z", "--exec", "x", "--out", "o", "--stamp", "s", "--", "a" }, "unknown argument");
    try bad(&.{ "run", "--busybox", "b", "--out", "o", "--stamp", "s", "--", "a" }, "--busybox, --exec, --out and --stamp are required");
    try bad(&.{ "run", "--busybox", "b", "--exec", "x", "--out", "o", "--stamp", "s" }, "the program's arguments follow `--`");
}

test "scratchRoot: where buck2 names, else beside the inputs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/w/.buildrules_action", try L.scratchRoot(a, "/w", null));
    try t.expectEqualStrings("/w/.buildrules_action", try L.scratchRoot(a, "/w", ""));
    try t.expectEqualStrings("/s/x/buildrules", try L.scratchRoot(a, "/w", "/s/x"));
    try t.expectEqualStrings("/w/buck-out/s/buildrules", try L.scratchRoot(a, "/w", "buck-out/s"));
}

test "manifest: lines of two tab-separated fields; the last needs no newline" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = try L.manifest(a, "fixtures/a\tsrc/a\n\nb/c\tsrc dir/c\td\nlast\tl");
    try t.expectEqual(@as(usize, 3), es.len);
    try t.expectEqualStrings("fixtures/a", es[0].left);
    try t.expectEqualStrings("src/a", es[0].right);
    try t.expectEqualStrings("src dir/c\td", es[1].right);
    try t.expectEqualStrings("last", es[2].left);
    try t.expectEqualStrings("l", es[2].right);
    try t.expectEqual(@as(usize, 0), (try L.manifest(a, "")).len);
}

test "manifest: a line without two fields is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "novalue", "\tnoname", "noval\t" }) |text| {
        try t.expectError(error.BadLine, L.manifest(a, text));
    }
}

test "exitCodeOf: a child's status, 128 + N for a signal" {
    try t.expectEqual(@as(u8, 0), L.exitCodeOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 1), L.exitCodeOf(.{ .Exited = 1 }));
    try t.expectEqual(@as(u8, 124), L.exitCodeOf(.{ .Exited = 124 }));
    try t.expectEqual(@as(u8, 137), L.exitCodeOf(.{ .Signal = 9 }));
    try t.expectEqual(@as(u8, 1), L.exitCodeOf(.{ .Unknown = 5 }));
}

fn put(dir: std.fs.Dir, name: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    const f = try dir.createFile(name, .{ .mode = mode });
    defer f.close();
    try f.writeAll(data);
}

test "copyTree merges, keeps modes and links; makeWritable opens a read-only tree" {
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try src.dir.makePath("sub/deeper");
    try put(src.dir, "plain.txt", "plain\n", 0o444);
    try put(src.dir, "tool", "#!x\n", 0o555);
    try put(src.dir, "sub/deeper/inner.txt", "inner\n", 0o444);
    try src.dir.symLink("plain.txt", "link", .{});
    // The destination has a directory of the same name and a file to replace.
    try dst.dir.makePath("sub/kept");
    try put(dst.dir, "plain.txt", "old\n", 0o644);

    try L.copyTree(src.dir, dst.dir);

    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("plain\n", try dst.dir.readFile("plain.txt", &buf));
    try t.expectEqualStrings("inner\n", try dst.dir.readFile("sub/deeper/inner.txt", &buf));
    try t.expectEqualStrings("plain.txt", try dst.dir.readLink("link", &buf));
    _ = try dst.dir.statFile("sub/kept");
    const tool = try dst.dir.statFile("tool");
    try t.expect(tool.mode & 0o100 != 0);
    try t.expect(tool.mode & 0o200 == 0);

    // A directory without the write bit, as a copied read-only fixture tree has.
    {
        var deeper = try dst.dir.openDir("sub/deeper", .{ .iterate = true });
        defer deeper.close();
        try (std.fs.File{ .handle = deeper.fd }).chmod(0o555);
    }
    try L.makeWritable(dst.dir);
    {
        var deeper = try dst.dir.openDir("sub/deeper", .{ .iterate = true });
        defer deeper.close();
        const st = try (std.fs.File{ .handle = deeper.fd }).stat();
        try t.expect(st.mode & 0o200 != 0);
        try put(deeper, "created.txt", "x", 0o644);
    }
    const plain = try dst.dir.statFile("plain.txt");
    try t.expect(plain.mode & 0o200 != 0);
    const tool2 = try dst.dir.statFile("tool");
    try t.expect(tool2.mode & 0o200 != 0);
    try t.expect(tool2.mode & 0o100 != 0);
    const inner = try dst.dir.statFile("sub/deeper/inner.txt");
    try t.expect(inner.mode & 0o200 != 0);
}
