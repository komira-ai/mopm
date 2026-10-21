// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/zig_cover_exe_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! The shipped zig_cover executable as a process, over small packages whose coverage is known: `zig test` of this file, run as a build action by
//! `:zig_cover_exe_test`, a validation of `:zig_cover`. The cases in zig_cover_test.zig call the pure parts; these run the executable the public
//! target hands out with the pinned zig, kcov and cov_normalize (the zig_test's `env_tools`: ZIG_COVER, PINNED_ZIG and PINNED_ZIG_012 the pinned
//! zigs' directories, KCOV the distribution's directory, NORMALIZE; without them every case fails) over fixtures written into a directory of their own, and check what only a
//! run shows: which lines and blocks a test reaches and which it does not, that the code no test calls is absent, that a failing test, a leak and a
//! logged error fail the run and leave no report, and that the report names repository paths.
//!
//! Each case builds and runs one test executable, so a case costs a compile. The zig cache of the standard library is shared by the cases.

const std = @import("std");

const mini = @embedFile("fixtures/zig_cover/mini.zig");
const mini_test = @embedFile("fixtures/zig_cover/mini_test.zig");
const fail_test = @embedFile("fixtures/zig_cover/fail_test.zig");
const leak_test = @embedFile("fixtures/zig_cover/leak_test.zig");
const log_test = @embedFile("fixtures/zig_cover/log_test.zig");
const runner = @embedFile("zig_cov_runner.zig");

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the tool cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// The line (1-based) of the first line of `text` holding `needle`.
fn lineOf(text: []const u8, needle: []const u8) !usize {
    var n: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| : (n += 1) {
        if (std.mem.indexOf(u8, l, needle) != null) return n;
    }
    return error.TestUnexpectedResult;
}

const Run = struct { code: u8, stderr: []const u8, lines: ?[]const u8, blocks: ?[]const u8 };

/// The standard library's cache of the cases, one per zig (a cache is not shared between versions).
var shared_cache = [2]?[]const u8{ null, null };

/// A fresh directory with the fixtures (`fx/mini.zig`, the test file as `fx/t_test.zig` and the runner), zig_cover run in it over
/// `fx/t_test.zig` including `fx/mini.zig` and `extra_include`, and what it wrote.
fn cover(a: std.mem.Allocator, zig: []const u8, test_source: []const u8, extra: []const []const u8) !Run {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("fx");
    try tmp.dir.writeFile(.{ .sub_path = "fx/mini.zig", .data = mini });
    try tmp.dir.writeFile(.{ .sub_path = "fx/t_test.zig", .data = test_source });
    try tmp.dir.writeFile(.{ .sub_path = "zig_cov_runner.zig", .data = runner });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const which: usize = if (std.mem.eql(u8, zig, "PINNED_ZIG")) 0 else 1;
    if (shared_cache[which] == null) {
        const here = try std.fs.cwd().realpathAlloc(std.heap.page_allocator, ".");
        shared_cache[which] = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.zig-cache-shared-{d}", .{ here, which });
    }
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{
        try tool(a, "ZIG_COVER"),
        "--zig",
        try tool(a, zig),
        "--target",
        "x86_64-linux-musl",
        "--root",
        "fx/t_test.zig",
        "--kcov",
        try tool(a, "KCOV"),
        "--normalize",
        try tool(a, "NORMALIZE"),
        "--out-lines",
        "out/lines.xml",
        "--must-contain",
        "fx/mini.zig",
        "--include",
        "fx/mini.zig",
    });
    try argv.appendSlice(a, extra);
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("ZIG_GLOBAL_CACHE_DIR", shared_cache[which].?);
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ root, ".zig-cache" }));
    try tmp.dir.makePath("out");
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd_dir = tmp.dir, .env_map = &env, .max_output_bytes = 1 << 22 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("zig_cover did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    return .{
        .code = code,
        .stderr = r.stderr,
        .lines = tmp.dir.readFileAlloc(a, "out/lines.xml", 1 << 20) catch null,
        .blocks = tmp.dir.readFileAlloc(a, "out/blocks", 1 << 20) catch null,
    };
}

const BLOCKS = [_][]const u8{ "--runner", "zig_cov_runner.zig", "--out-blocks", "out/blocks" };

/// The `<class>` of `file` in a normalized report.
fn classOf(xml: []const u8, file: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "filename=\"{s}\">", .{file});
    const at = std.mem.indexOf(u8, xml, needle) orelse return error.TestUnexpectedResult;
    const rest = xml[at..];
    return rest[0 .. std.mem.indexOf(u8, rest, "</class>") orelse return error.TestUnexpectedResult];
}

fn lineHits(xml: []const u8, line: usize) ?[]const u8 {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "<line number=\"{d}\" hits=\"", .{line}) catch unreachable;
    const at = std.mem.indexOf(u8, xml, needle) orelse return null;
    const rest = xml[at + needle.len ..];
    return rest[0..std.mem.indexOfScalar(u8, rest, '"').?];
}

/// The blocks that ran and the blocks there are, over the rows of the blocks file (the second and last columns after the position).
fn blockTotals(blocks: []const u8) !struct { hit: usize, total: usize } {
    var hit: usize = 0;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, blocks, '\n');
    _ = it.next();
    while (it.next()) |row| {
        if (row.len == 0) continue;
        var f = std.mem.splitScalar(u8, row, '\t');
        _ = f.next();
        _ = f.next();
        _ = f.next();
        hit += try std.fmt.parseInt(usize, f.next() orelse return error.TestUnexpectedResult, 10);
        total += try std.fmt.parseInt(usize, f.next() orelse return error.TestUnexpectedResult, 10);
    }
    return .{ .hit = hit, .total = total };
}

/// The number of rows of the blocks file on `line`.
fn rowsOn(blocks: []const u8, line: usize) usize {
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, blocks, '\n');
    while (it.next()) |row| {
        var f = std.mem.splitScalar(u8, row, '\t');
        _ = f.next() orelse continue;
        const l = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        if (l == line) rows += 1;
    }
    return rows;
}

test "a passing run: the arms the tests reach are hit, the arm they do not is not, in lines and in blocks, in repository paths" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try cover(a, "PINNED_ZIG", mini_test, &BLOCKS);
    if (r.code != 0) {
        std.debug.print("exit {d}; stderr:\n{s}\n", .{ r.code, r.stderr });
        return error.TestUnexpectedResult;
    }
    const whole = r.lines orelse return error.TestUnexpectedResult;
    const xml = try classOf(whole, "fx/mini.zig");
    const blocks = r.blocks orelse return error.TestUnexpectedResult;

    // Lines: kcov's, mapped to the repository path, clamped to 0 or 1.
    try std.testing.expect(std.mem.indexOf(u8, whole, "<class name=\"fx/mini.zig\" filename=\"fx/mini.zig\">") != null);
    try std.testing.expectEqualStrings("1", lineHits(xml, try lineOf(mini, "return \"negative\"")) orelse "missing");
    try std.testing.expectEqualStrings("1", lineHits(xml, try lineOf(mini, "return \"positive\"")) orelse "missing");
    try std.testing.expectEqualStrings("0", lineHits(xml, try lineOf(mini, "return \"zero\"")) orelse "missing");
    // No absolute path of the run is in the report. (kcov is told the directories of the included files, so the test file beside them is listed too; the summary
    // counts only the package's own sources.)
    try std.testing.expect(std.mem.indexOf(u8, whole, "/tmp") == null and std.mem.indexOf(u8, whole, ".zig-cache") == null and std.mem.indexOf(u8, whole, "filename=\"/") == null);

    // Blocks: the compiler's, counted per position. classify has five: the entry, and the two arms of each of its two conditions; the one the
    // tests do not reach is the arm of `n == 0` that returns "zero".
    try std.testing.expect(std.mem.startsWith(u8, blocks, "# blocks v2\n"));
    var it = std.mem.splitScalar(u8, blocks, '\n');
    _ = it.next();
    while (it.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, row, "fx/mini.zig\t"));
    }
    const totals = try blockTotals(blocks);
    try std.testing.expectEqual(@as(usize, 5), totals.total);
    try std.testing.expectEqual(@as(usize, 4), totals.hit);
    // The function nothing calls was never compiled: neither report has a row for it.
    const never = try lineOf(mini, "return n + 1");
    try std.testing.expect(lineHits(xml, never) == null);
    try std.testing.expectEqual(@as(usize, 0), rowsOn(blocks, never));
}

test "a failing test fails the run with the test's status and leaves no report" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = try cover(arena.allocator(), "PINNED_ZIG", fail_test, &BLOCKS);
    try std.testing.expect(r.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "FAIL (TestExpectedEqual)") != null);
    try std.testing.expect(r.lines == null and r.blocks == null);
}

test "a test that leaks memory fails the run, as zig's own runner fails it" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = try cover(arena.allocator(), "PINNED_ZIG", leak_test, &BLOCKS);
    try std.testing.expect(r.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "1 tests leaked memory") != null);
    try std.testing.expect(r.lines == null and r.blocks == null);
}

test "an error logged by a test that passes fails the run, as zig's own runner fails it" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = try cover(arena.allocator(), "PINNED_ZIG", log_test, &BLOCKS);
    try std.testing.expect(r.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "1 errors were logged") != null);
    try std.testing.expect(r.lines == null and r.blocks == null);
}

test "--no-blocks, for a test built by zig 0.12: lines only, and the block report is not taken" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try cover(a, "PINNED_ZIG_012", mini_test, &.{"--no-blocks"});
    if (r.code != 0) {
        std.debug.print("exit {d}; stderr:\n{s}\n", .{ r.code, r.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings("0", lineHits(r.lines orelse return error.TestUnexpectedResult, try lineOf(mini, "return \"zero\"")) orelse "missing");
    try std.testing.expect(r.blocks == null);
}

test "a file asked for that the executable holds no code of is refused, with no report" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // `--must-contain` names mini.zig, which is included; the block report of a run that has no block of an included file is refused.
    const r = try cover(arena.allocator(), "PINNED_ZIG", "const std = @import(\"std\");\ntest \"nothing of mini.zig is reached\" {\n    try std.testing.expect(true);\n}\n", &BLOCKS);
    try std.testing.expect(r.code != 0);
    try std.testing.expect(r.lines == null and r.blocks == null);
}
