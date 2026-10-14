//! The other half of `mopm test` discovery: where test files are, the
//! generated harness that runs a bare test file's tests through
//! `std.testing.TestSuite`, and the cross-check of the scan against the
//! listing the compiled harness prints.
//!
//! Test files (the design's convention, relative to the package root):
//!   tests/**/test_*.mojo       tests against the package
//!   src/**/tests/test_*.mojo   tests kept next to the sources
//! A path with a component starting with '.' is never a test file.
//!
//! The harness for a bare file (test_scan.zig) is the file, unchanged, with
//! a `main` appended after its last line, so every line number in a
//! diagnostic or assertion message still names the original line:
//!
//!     <the test file>
//!     # ---- appended by mopm test ...
//!     from std.testing import TestSuite as _mopm_TestSuite
//!
//!     def main() raises:
//!         var suite = _mopm_TestSuite()
//!         suite.test[test_a]()
//!         ...
//!         suite^.run()
//!
//! The TestSuite of Mojo 1.0.0 (std/testing/suite.mojo) reads the process
//! arguments: no argument runs every registered test; `--only <name>...`
//! runs only those (an unknown name is an error); `--skip-all` runs none and
//! prints every registered test as SKIP. `run()` prints its report and
//! raises when a test failed, so the process exits non-zero.
//!
//! The listing that `--skip-all` prints (ANSI colour codes around words):
//!
//!     Running 2 tests for /path/test_x.mojo
//!         SKIP [ 0.001 ] test_a
//!         SKIP [ 0.001 ] test_b
//!     --------
//!     Summary [ 0.001 ] 2 tests run: 0 passed , 0 failed , 2 skipped
//!
//! `parseListing` reads that; any other shape is a protocol mismatch, never
//! a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_scan = @import("test_scan.zig");

/// Whether `rel` (relative to the package root, '/'-separated) is a test file
/// by the convention above.
pub fn isTestPath(rel: []const u8) bool {
    var first: []const u8 = "";
    var parent: []const u8 = "";
    var base: []const u8 = "";
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |p| {
        if (p.len == 0 or p[0] == '.') return false;
        if (n == 0) first = p;
        parent = base;
        base = p;
        n += 1;
    }
    if (n < 2) return false;
    if (!std.mem.startsWith(u8, base, "test_") or !std.mem.endsWith(u8, base, ".mojo")) return false;
    if (std.mem.eql(u8, first, "tests")) return true;
    return std.mem.eql(u8, first, "src") and std.mem.eql(u8, parent, "tests");
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The test files under `root`, relative to it, sorted bytewise.
pub fn findTestFiles(arena: Allocator, root: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for ([_][]const u8{ "tests", "src" }) |top| {
        const path = try std.fs.path.join(arena, &.{ root, top });
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        defer dir.close();
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ top, entry.path });
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
            if (isTestPath(rel)) try out.append(rel);
        }
    }
    std.sort.insertion([]const u8, out.items, {}, lessThanStr);
    return out.toOwnedSlice();
}

pub const appended_marker = "# ---- appended by mopm test: the lines above are the test file, unchanged ----";

/// The harness source for a bare test file: `src`, then a `main` that
/// registers `tests` in order.
pub fn generate(arena: Allocator, src: []const u8, tests: []const test_scan.Item) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).init(arena);
    const w = buf.writer();
    try buf.appendSlice(src);
    if (src.len > 0 and src[src.len - 1] != '\n') try buf.append('\n');
    try w.print("\n{s}\nfrom std.testing import TestSuite as _mopm_TestSuite\n\n\ndef main() raises:\n    var suite = _mopm_TestSuite()\n", .{appended_marker});
    for (tests) |t| try w.print("    suite.test[{s}]()\n", .{t.name});
    try buf.appendSlice("    suite^.run()\n");
    return buf.toOwnedSlice();
}

/// `s` without ANSI escape sequences (ESC '[' parameters final-byte).
pub fn stripAnsi(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == ';' or s[j] == '?')) j += 1;
            i = if (j < s.len) j + 1 else j;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

pub const ListingError = error{ProtocolMismatch} || Allocator.Error;

/// The test names a `--skip-all` run printed, in its order. The output must
/// have the `Running N tests for` header, N SKIP lines and nothing that ran.
pub fn parseListing(arena: Allocator, output: []const u8) ListingError![]const []const u8 {
    const text = try stripAnsi(arena, output);
    var names = std.ArrayList([]const u8).init(arena);
    var want: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "Running ")) {
            if (want != null) return error.ProtocolMismatch;
            var words = std.mem.tokenizeScalar(u8, l, ' ');
            _ = words.next();
            const n = words.next() orelse return error.ProtocolMismatch;
            const tests_word = words.next() orelse return error.ProtocolMismatch;
            if (!std.mem.eql(u8, tests_word, "tests") and !std.mem.eql(u8, tests_word, "test")) return error.ProtocolMismatch;
            want = std.fmt.parseInt(usize, n, 10) catch return error.ProtocolMismatch;
            continue;
        }
        for ([_][]const u8{ "PASS", "FAIL" }) |r| {
            if (std.mem.startsWith(u8, l, r) and std.mem.indexOf(u8, l, " [ ") != null) return error.ProtocolMismatch;
        }
        if (!std.mem.startsWith(u8, l, "SKIP")) continue;
        if (want == null) return error.ProtocolMismatch;
        const close = std.mem.indexOf(u8, l, " ] ") orelse return error.ProtocolMismatch;
        const name = std.mem.trim(u8, l[close + 3 ..], " \t");
        if (name.len == 0) return error.ProtocolMismatch;
        try names.append(name);
    }
    if (want == null or want.? != names.items.len) return error.ProtocolMismatch;
    return names.toOwnedSlice();
}

pub const Diff = struct {
    only_scan: []const []const u8,
    only_listing: []const []const u8,

    pub fn same(self: Diff) bool {
        return self.only_scan.len == 0 and self.only_listing.len == 0;
    }
};

/// The names in one list and not the other, counting repeats (a name listed
/// twice by the binary and once by the scan is a difference).
pub fn compare(arena: Allocator, scan: []const []const u8, listing: []const []const u8) Allocator.Error!Diff {
    const a = try arena.dupe([]const u8, scan);
    const b = try arena.dupe([]const u8, listing);
    std.sort.insertion([]const u8, a, {}, lessThanStr);
    std.sort.insertion([]const u8, b, {}, lessThanStr);
    var only_a = std.ArrayList([]const u8).init(arena);
    var only_b = std.ArrayList([]const u8).init(arena);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (j >= b.len or (i < a.len and std.mem.lessThan(u8, a[i], b[j]))) {
            try only_a.append(a[i]);
            i += 1;
        } else if (i >= a.len or std.mem.lessThan(u8, b[j], a[i])) {
            try only_b.append(b[j]);
            j += 1;
        } else {
            i += 1;
            j += 1;
        }
    }
    return .{ .only_scan = try only_a.toOwnedSlice(), .only_listing = try only_b.toOwnedSlice() };
}

// ---------------------------------------------------------------- tests

test "the test-file convention" {
    const yes = [_][]const u8{
        "tests/test_a.mojo",
        "tests/deep/er/test_b.mojo",
        "src/tests/test_c.mojo",
        "src/pkg/tests/test_d.mojo",
        "src/a/b/tests/test_e.mojo",
    };
    const no = [_][]const u8{
        "test_a.mojo", // not under tests/ or src/
        "tests/a_test.mojo", // name must start with test_
        "tests/test_a.py",
        "tests/test_a.mojo.bak",
        "src/pkg/test_a.mojo", // under src, only directly inside a tests/ dir
        "src/pkg/tests/sub/test_a.mojo",
        "examples/tests/test_a.mojo",
        "tests/.hidden/test_a.mojo",
        "tests/.test_a.mojo",
        "tests/test_",
    };
    for (yes) |p| std.testing.expect(isTestPath(p)) catch |e| {
        std.debug.print("should be a test file: {s}\n", .{p});
        return e;
    };
    for (no) |p| std.testing.expect(!isTestPath(p)) catch |e| {
        std.debug.print("should not be a test file: {s}\n", .{p});
        return e;
    };
}

// Reads tests/discovery/tree relative to the working directory: run from
// the repository root.
test "test files under a package root, sorted" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const files = try findTestFiles(t.allocator(), "tests/discovery/tree");
    const want = [_][]const u8{
        "src/pkg/tests/test_inner.mojo",
        "tests/sub/test_registered.mojo",
        "tests/test_bare.mojo",
        "tests/test_empty.mojo",
    };
    try std.testing.expectEqual(@as(usize, want.len), files.len);
    for (want, files) |w, f| try std.testing.expectEqualStrings(w, f);
}

test "the harness is the file unchanged, then a main registering each test in order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const src = "def test_b() raises:\n    pass\n\ndef test_a() raises:\n    pass";
    const sc = try test_scan.scan(a, src);
    const got = try generate(a, src, sc.tests);
    try std.testing.expectEqualStrings(src ++ "\n" ++
        \\
        \\# ---- appended by mopm test: the lines above are the test file, unchanged ----
        \\from std.testing import TestSuite as _mopm_TestSuite
        \\
        \\
        \\def main() raises:
        \\    var suite = _mopm_TestSuite()
        \\    suite.test[test_b]()
        \\    suite.test[test_a]()
        \\    suite^.run()
        \\
    , got);
}

// tests/discovery/bare_basic.harness is the generated text after the file.
test "golden harness of tests/discovery/bare_basic.mojo" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const src = try std.fs.cwd().readFileAlloc(a, "tests/discovery/bare_basic.mojo", 1 << 20);
    const want = try std.fs.cwd().readFileAlloc(a, "tests/discovery/bare_basic.harness", 1 << 20);
    const got = try generate(a, src, (try test_scan.scan(a, src)).tests);
    try std.testing.expect(std.mem.startsWith(u8, got, src));
    try std.testing.expectEqualStrings(want, got[src.len..]);
}

// What TestSuite.run(skip_all) of Mojo 1.0.0 prints, colour codes included
// (std/testing/suite.mojo: TestSuiteReport.write_to and TestReport.write_to).
const sample_listing =
    "\n\x1b[32mRunning\x1b[0m \x1b[1;37m3\x1b[0m tests for \x1b[36m/w/test_x.mojo\x1b[0m \n" ++
    "    \x1b[33mSKIP\x1b[0m [ 0.001 ] \x1b[36mtest_one\x1b[0m\n" ++
    "    \x1b[33mSKIP\x1b[0m [ 0.001 ] \x1b[36mtest_two\x1b[0m\n" ++
    "    \x1b[33mSKIP\x1b[0m [ 0.001 ] \x1b[36mcheck_three\x1b[0m\n" ++
    "--------\n" ++
    "\x1b[35mSummary\x1b[0m [ 0.001 ] \x1b[1;37m3\x1b[0m tests run: \x1b[1;37m0\x1b[0m \x1b[32mpassed\x1b[0m , " ++
    "\x1b[1;37m0\x1b[0m \x1b[31mfailed\x1b[0m , \x1b[1;37m3\x1b[0m \x1b[33mskipped\x1b[0m \n";

test "a --skip-all listing: the names in order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const names = try parseListing(t.allocator(), sample_listing);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("test_one", names[0]);
    try std.testing.expectEqualStrings("test_two", names[1]);
    try std.testing.expectEqualStrings("check_three", names[2]);
}

test "a listing of another shape is a protocol mismatch" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    // No header.
    try std.testing.expectError(error.ProtocolMismatch, parseListing(a, "    SKIP [ 0.001 ] test_a\n"));
    // The header counts 3, two lines follow.
    try std.testing.expectError(error.ProtocolMismatch, parseListing(a, "Running 3 tests for x\n    SKIP [ 0.001 ] a\n    SKIP [ 0.001 ] b\n"));
    // A test ran: --skip-all was not honoured.
    try std.testing.expectError(error.ProtocolMismatch, parseListing(a, "Running 1 tests for x\n    PASS [ 0.002 ] a\n"));
    // Nothing at all (a binary that ignores its arguments).
    try std.testing.expectError(error.ProtocolMismatch, parseListing(a, ""));
    // An empty suite is a valid listing.
    try std.testing.expectEqual(@as(usize, 0), (try parseListing(a, "Running 0 tests for x\n--------\n")).len);
}

test "compare: missing, extra and repeated names are differences" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try std.testing.expect((try compare(a, &.{ "b", "a" }, &.{ "a", "b" })).same());
    const d = try compare(a, &.{ "a", "b", "c" }, &.{ "a", "d", "a" });
    try std.testing.expectEqual(@as(usize, 2), d.only_scan.len);
    try std.testing.expectEqualStrings("b", d.only_scan[0]);
    try std.testing.expectEqualStrings("c", d.only_scan[1]);
    try std.testing.expectEqual(@as(usize, 2), d.only_listing.len);
    try std.testing.expectEqualStrings("a", d.only_listing[0]);
    try std.testing.expectEqualStrings("d", d.only_listing[1]);
}
