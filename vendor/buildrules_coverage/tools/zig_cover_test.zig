// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/zig_cover_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! Unit tests of zig_cover.zig: its command line, the commands it builds, and the reduction of the runner's block rows to the report.
//! The run itself (zig, kcov, the runner) is held by zig_cover_exe_test.zig.
const std = @import("std");
const Z = @import("zig_cover.zig");
const t = std.testing;

const BASE = [_][]const u8{
    "--zig",       "/z",         "--runner",     "r.zig",       "--target", "x86_64-linux-musl", "--root",         "pkg/a_test.zig",
    "--kcov",      "/k",         "--normalize",  "/n",          "--out-lines", "o.xml",          "--out-blocks",   "o.blocks",
    "--must-contain", "pkg/a.zig", "--include",   "pkg/a.zig",
};

fn parseWith(a: std.mem.Allocator, extra: []const []const u8, diag: *[]const u8) !Z.Args {
    return Z.parse(a, try std.mem.concat(a, []const u8, &.{ &BASE, extra }), diag);
}

test "parse: the whole command line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try parseWith(a, &.{ "--include", "pkg/b.zig" }, &d);
    try t.expectEqualStrings("/z", r.zig);
    try t.expectEqualStrings("r.zig", r.runner);
    try t.expectEqualStrings("x86_64-linux-musl", r.target);
    try t.expectEqualStrings("pkg/a_test.zig", r.root);
    try t.expectEqualStrings("o.blocks", r.out_blocks);
    try t.expectEqualStrings("pkg/a.zig", r.must_contain);
    try t.expectEqual(@as(usize, 2), r.includes.len);
    try t.expectEqualStrings("pkg/b.zig", r.includes[1]);
}

test "parse: every refusal names its option" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    // An include kcov would split, a path outside the tree, an absolute path.
    for ([_][]const u8{ "a,b", "a:b", "a b", "../x", "x/../y", "/abs/x", "" }) |bad| {
        try t.expectError(error.Usage, parseWith(a, &.{ "--include", bad }, &d));
        try t.expect(std.mem.indexOf(u8, d, "must be a clean relative path") != null);
    }
    try t.expectError(error.Usage, parseWith(a, &.{"--bogus"}, &d));
    try t.expectEqualStrings("--bogus needs a value", d);
    try t.expectError(error.Usage, parseWith(a, &.{ "--bogus", "1" }, &d));
    try t.expectEqualStrings("unknown option --bogus", d);
    // Each required option, left out in turn.
    var i: usize = 0;
    while (i < BASE.len) : (i += 2) {
        if (std.mem.eql(u8, BASE[i], "--include")) continue;
        const without = try std.mem.concat(a, []const u8, &.{ BASE[0..i], BASE[i + 2 ..] });
        try t.expectError(error.Usage, Z.parse(a, without, &d));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s} is required", .{BASE[i]}), d);
    }
    // No include: nothing would be measured.
    try t.expectError(error.Usage, Z.parse(a, BASE[0 .. BASE.len - 2], &d));
    try t.expect(std.mem.indexOf(u8, d, "at least one --include") != null);
}

test "parse: --no-blocks takes no value, and neither --runner nor --out-blocks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const plain = [_][]const u8{ "--zig", "/z", "--target", "x86_64-linux-musl", "--root", "a_test.zig", "--kcov", "/k", "--normalize", "/n", "--out-lines", "o.xml", "--must-contain", "a.zig", "--include", "a.zig" };
    const r = try Z.parse(a, &plain ++ [_][]const u8{"--no-blocks"}, &d);
    try t.expect(!r.blocks);
    try t.expectEqualStrings("a.zig", r.includes[0]);
    // In the middle of the line, too.
    const mid = try Z.parse(a, plain[0..4] ++ [_][]const u8{"--no-blocks"} ++ plain[4..], &d);
    try t.expect(!mid.blocks);
    try t.expectEqualStrings("a_test.zig", mid.root);
    // Without the flag the runner and the block report are required; with it they are refused.
    try t.expectError(error.Usage, Z.parse(a, &plain, &d));
    try t.expectEqualStrings("--runner is required", d);
    try t.expectError(error.Usage, Z.parse(a, &plain ++ [_][]const u8{ "--no-blocks", "--runner", "r.zig" }, &d));
    try t.expectEqualStrings("--no-blocks takes neither --runner nor --out-blocks", d);
    try t.expectError(error.Usage, Z.parse(a, &plain ++ [_][]const u8{ "--no-blocks", "--out-blocks", "b" }, &d));
    // A plain build: no LLVM flag, no counters, zig's own test runner.
    const v = try Z.zigArgv(a, r, "/w/test");
    const want = [_][]const u8{ "/z/zig", "test", "--test-no-exec", "-target", "x86_64-linux-musl", "-femit-bin=/w/test", "a_test.zig" };
    try t.expectEqual(want.len, v.len);
    for (want, v) |w, g| try t.expectEqualStrings(w, g);
}

test "zigArgv: LLVM's code generator, block counters, the coverage runner, and no run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try parseWith(a, &.{}, &d);
    const v = try Z.zigArgv(a, r, "/w/test");
    const want = [_][]const u8{ "/z/zig", "test", "-fllvm", "-ffuzz", "--test-runner", "r.zig", "--test-no-exec", "-target", "x86_64-linux-musl", "-femit-bin=/w/test", "pkg/a_test.zig" };
    try t.expectEqual(want.len, v.len);
    for (want, v) |w, g| try t.expectEqualStrings(w, g);
}

test "includeDirs: the directories of the files, once each, in order; a file with no directory is itself" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try Z.includeDirs(a, &.{ "cli/src/a.zig", "cli/src/b.zig", "tools/release/binhdr.zig", "cli/src/c.zig", "top.zig", "cli/version.zig" });
    const want = [_][]const u8{ "cli/src", "tools/release", "top.zig", "cli" };
    try t.expectEqual(want.len, d.len);
    for (want, d) |w, g| try t.expectEqualStrings(w, g);
    try t.expectEqual(@as(usize, 0), (try Z.includeDirs(a, &.{})).len);
    // Forty files under one directory are one option of a few bytes, whatever the working directory is.
    var many: [40][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = try std.fmt.allocPrint(a, "rules/kpin/file_{d}.zig", .{i});
    const one = try Z.includeDirs(a, &many);
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expectEqualStrings("rules/kpin", one[0]);
}

test "normalizeArgv: the tree is mapped to repository paths and its directory forbidden in the output" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try parseWith(a, &.{}, &d);
    const v = try Z.normalizeArgv(a, r, "/w/cov.xml", "/exec/o.xml", "/exec");
    const want = [_][]const u8{ "/n", "--in", "/w/cov.xml", "--out", "/exec/o.xml", "--map", "/exec/=", "--must-contain", "pkg/a.zig", "--forbid", "/exec" };
    try t.expectEqual(want.len, v.len);
    for (want, v) |w, g| try t.expectEqualStrings(w, g);
}

test "isTestFunction: a test block's function, and nothing a test only calls" {
    try t.expect(Z.isTestFunction("pkg/a_test.zig", "a_test.test.the name of it"));
    try t.expect(Z.isTestFunction("pkg/a_test.zig", "a_test.test_0"));
    try t.expect(Z.isTestFunction("pkg/a_test.zig", "a_test.test_12"));
    // A helper of the test file, and a function of the code under test, are not.
    try t.expect(!Z.isTestFunction("pkg/a_test.zig", "mk"));
    try t.expect(!Z.isTestFunction("pkg/a_test.zig", "a_test.helper"));
    try t.expect(!Z.isTestFunction("pkg/a.zig", "a_test.test.x"));
    try t.expect(!Z.isTestFunction("pkg/a.zig", "a.test_data"));
    try t.expect(!Z.isTestFunction("pkg/a.zig", "a.test_"));
    try t.expect(!Z.isTestFunction("pkg/a.zig", "a.testing"));
}

const HEAD = "# sancov v1 9\n";

test "blocks: counted per source position, not merged: an arm that never ran is not hidden by the arm that did; sorted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = HEAD ++
        "/w/pkg/b.zig\t9\t3\t0\tf\n" ++
        "/w/pkg/a.zig\t10\t5\t0\tg\n" ++
        "/w/pkg/a.zig\t10\t5\t7\tg\n" ++ // a second block at the same position: the other arm
        "/w/pkg/a.zig\t3\t1\t0\tf\n" ++
        "/w/pkg/a.zig\t10\t9\t255\tg\n";
    const bs = try Z.blocks(a, raw, "/w", &.{ "pkg/a.zig", "pkg/b.zig" });
    try t.expectEqual(@as(usize, 4), bs.len);
    const out = try Z.render(a, bs);
    try t.expectEqualStrings("# blocks v2\npkg/a.zig\t3\t1\t0\t1\npkg/a.zig\t10\t5\t1\t2\npkg/a.zig\t10\t9\t1\t1\npkg/b.zig\t9\t3\t0\t1\n", out);
}

test "blocks: a position whose first block ran and whose second did not counts one of two, whatever the order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = HEAD ++
        "/w/pkg/a.zig\t20\t2\t3\tf\n" ++ // the first block at this position ran
        "/w/pkg/a.zig\t20\t2\t0\tf\n" ++ // the second did not: it must not be counted as run because the first was
        "/w/pkg/a.zig\t21\t2\t0\tf\n" ++
        "/w/pkg/a.zig\t21\t2\t3\tf\n" ++ // the other order
        "/w/pkg/a.zig\t22\t2\t3\tf\n" ++
        "/w/pkg/a.zig\t22\t2\t3\tf\n" ++ // both ran
        "/w/pkg/a.zig\t23\t2\t0\tf\n" ++
        "/w/pkg/a.zig\t23\t2\t0\tf\n"; // neither
    const bs = try Z.blocks(a, raw, "/w", &.{"pkg/a.zig"});
    const out = try Z.render(a, bs);
    try t.expectEqualStrings("# blocks v2\npkg/a.zig\t20\t2\t1\t2\npkg/a.zig\t21\t2\t1\t2\npkg/a.zig\t22\t2\t2\t2\npkg/a.zig\t23\t2\t0\t2\n", out);
}

test "blocks: what is not the code under test is left out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = HEAD ++
        "/w/pkg/a.zig\t1\t1\t1\tf\n" ++
        "/w/pkg/a.zig\t2\t1\t0\ta.test.inside a test of the same file\n" ++ // a test function
        "/w/pkg/other.zig\t1\t1\t1\tf\n" ++ // not included
        "/w/pkgx/a.zig\t1\t1\t1\tf\n" ++ // a path that only starts like an included one
        "/elsewhere/pkg/a.zig\t1\t1\t1\tf\n" ++ // outside the tree
        "/wx/pkg/a.zig\t1\t1\t1\tf\n" ++ // outside the tree, sharing the tree's name as a prefix
        "?\t0\t0\t1\t?\n"; // no source position
    const bs = try Z.blocks(a, raw, "/w", &.{"pkg/a.zig"});
    try t.expectEqual(@as(usize, 1), bs.len);
    try t.expectEqualStrings("pkg/a.zig", bs[0].file);
    try t.expectEqual(@as(u32, 1), bs[0].line);
}

test "blocks: a run that recorded no block of an included file is refused, not read as 0 of 0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.NoBlocks, Z.blocks(a, HEAD, "/w", &.{"pkg/a.zig"}));
    try t.expectError(error.NoBlocks, Z.blocks(a, HEAD ++ "/w/pkg/zzz.zig\t1\t1\t1\tf\n", "/w", &.{"pkg/a.zig"}));
    try t.expectError(error.NoBlocks, Z.blocks(a, HEAD ++ "?\t0\t0\t1\t?\n", "/w", &.{"pkg/a.zig"}));
    try t.expectError(error.NoBlocks, Z.blocks(a, "", "/w", &.{"pkg/a.zig"}));
}

test "blocks: a malformed report is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = "/w/pkg/a.zig\t1\t1\t1\tf\n";
    // No header, a wrong header, too few or too many fields, a number that is not one, hits above a byte.
    for ([_][]const u8{
        good,
        "# sancov v2 1\n" ++ good,
        HEAD ++ "/w/pkg/a.zig\t1\t1\t1\n",
        HEAD ++ "/w/pkg/a.zig\t1\t1\t1\tf\textra\n",
        HEAD ++ "/w/pkg/a.zig\tx\t1\t1\tf\n",
        HEAD ++ "/w/pkg/a.zig\t1\t-1\t1\tf\n",
        HEAD ++ "/w/pkg/a.zig\t1\t1\t256\tf\n",
    }) |raw| {
        try t.expectError(error.BadRow, Z.blocks(a, raw, "/w", &.{"pkg/a.zig"}));
    }
}
