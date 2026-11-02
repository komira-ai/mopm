// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/cov_run_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! Unit tests of cov_run.zig: its command line, and the two lines it builds for kcov and cov_normalize. The run itself (kcov tracing a test
//! binary) is held by the examples' coverage targets.
const std = @import("std");
const C = @import("cov_run.zig");
const t = std.testing;

fn args(a: std.mem.Allocator, extra: []const []const u8) ![]const []const u8 {
    const base = [_][]const u8{ "--kcov", "/k", "--normalize", "/n", "--compiler", "/c", "--binary", "/b/t", "--share", "/s", "--out", "o.xml", "--must-contain", "pkg/tests/test_x.mojo", "--include", "base" };
    return std.mem.concat(a, []const u8, &.{ &base, extra });
}

test "parse: the whole command line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--include", "tests/test_x.mojo", "--map", "base/=pkg/src/base/", "--map", "tests/=pkg/tests/", "--refuse-in-binary", ".stage/src/" }), &d);
    try t.expectEqualStrings("/k", r.kcov);
    try t.expectEqual(@as(usize, 2), r.includes.len);
    try t.expectEqualStrings("tests/test_x.mojo", r.includes[1]);
    try t.expectEqual(@as(usize, 2), r.maps.len);
    try t.expectEqualStrings("pkg/tests/", r.maps[1].repo);
    try t.expectEqualStrings(".stage/src/", r.refuse[0]);
}

test "parse: refusals name the option" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--include", "a,b" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "--include a,b") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--map", "base=pkg/" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "both sides are relative directories ending in /") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--map", "/abs/=pkg/" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{"--bogus"}), &d));
    try t.expectError(error.Usage, C.parse(a, &.{ "--kcov", "/k" }, &d));
    try t.expect(std.mem.indexOf(u8, d, "is required") != null);
    // No include path: kcov would measure nothing, and say nothing.
    try t.expectError(error.Usage, C.parse(a, &.{ "--kcov", "/k", "--normalize", "/n", "--compiler", "/c", "--binary", "/b", "--share", "/s", "--out", "o", "--must-contain", "x" }, &d));
    try t.expect(std.mem.indexOf(u8, d, "at least one --include") != null);
}

test "kcov's command line measures exactly the included paths under the tree, with full paths in the report" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--include", "tests/test_x.mojo" }), &d);
    const k = try C.kcovArgv(a, r, "/real/share", "/work");
    try t.expectEqualStrings("/k/bin/kcov", k[0]);
    try t.expectEqualStrings("--cobertura-only", k[1]);
    try t.expectEqualStrings("--configure=cobertura-full-paths=1", k[3]);
    try t.expectEqualStrings("--include-path=/real/share/base,/real/share/tests/test_x.mojo", k[4]);
    try t.expectEqualStrings("/work", k[5]);
    try t.expectEqualStrings("/b/t", k[6]);
}

test "kcov's command line passes the test binary its arguments, after the binary" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    var r = try C.parse(a, try args(a, &.{}), &d);
    r.binary_args = &.{ "--cov-out=/w/blocks", "--x" };
    const k = try C.kcovArgv(a, r, "/real/share", "/work");
    try t.expectEqual(@as(usize, 9), k.len);
    try t.expectEqualStrings("/b/t", k[6]);
    try t.expectEqualStrings("--cov-out=/w/blocks", k[7]);
    try t.expectEqualStrings("--x", k[8]);
    // cov_run's own command line gives the binary none.
    const plain = try C.kcovArgv(a, try C.parse(a, try args(a, &.{}), &d), "/real/share", "/work");
    try t.expectEqual(@as(usize, 7), plain.len);
}

test "cov_normalize's command line maps the tree's absolute names to repository paths and forbids the action's directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--map", "base/=pkg/src/base/" }), &d);
    const n = try C.normalizeArgv(a, r, "/real/share", "/work/cov.xml", "/exec/root");
    try t.expectEqualStrings("/n", n[0]);
    try t.expectEqualStrings("/work/cov.xml", n[2]);
    try t.expectEqualStrings("--map", n[5]);
    try t.expectEqualStrings("/real/share/base/=pkg/src/base/", n[6]);
    try t.expectEqualStrings("--must-contain", n[7]);
    try t.expectEqualStrings("pkg/tests/test_x.mojo", n[8]);
    try t.expectEqualStrings("--forbid", n[9]);
    try t.expectEqualStrings("/exec/root", n[10]);
}

test "heldText: the staged-path leak is found in a binary, and a clean binary passes" {
    try t.expectEqualStrings(".stage/src/", C.heldText("..\x00/exec/root/x/out.stage/src/base\x00..", &.{".stage/src/"}).?);
    try t.expect(C.heldText("base/__init__.mojo", &.{".stage/src/"}) == null);
    try t.expect(C.heldText("anything", &.{}) == null);
}
