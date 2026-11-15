// Vendored, unmodified, from komira-ai/buildrules pull request #153 (merged to main), commit eec7f9f4cdb509a161095fcc78f7dcd1dc1ca503, file rules/coverage/tools/cov_normalize_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! The cases of cov_normalize (README.md#tests), `zig test` of this file
//! (which imports cov_normalize.zig) run as a build action by
//! `:cov_normalize_unit`; the executable `:cov_normalize_exe` is not built
//! unless every one passes.
//!
//! Each case runs the program as main does (`entry`: the command line, a
//! working directory, stderr) in a directory of its own, and reads back the
//! exit status, the messages and the output file. fixtures/kcov_full_paths.xml
//! is a kcov report with absolute file names (made up), and
//! fixtures/kcov_full_paths.golden.xml the output it must give byte for byte.

const std = @import("std");
const N = @import("cov_normalize.zig");

const fixture = @embedFile("fixtures/kcov_full_paths.xml");
const golden = @embedFile("fixtures/kcov_full_paths.golden.xml");

const FX = "kcov_full_paths.xml";
const OUT = "out.xml";

const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";
const ART = "buck-out/v2/art/widget/src/widget_retry/__widget_retry__/fedcba9876543210/src/widget_retry/";
const PKG = "src/widget_retry/";

const Args = []const []const u8;

// The maps of a kcov run: the library's sources under the copied source root
// (longest prefix), the rest of that root (the tests), and the library's
// sources under the placeholder, as an unrelocated report would hold them.
const M1 = [_][]const u8{ "--map", D ++ "/srcroot/" ++ ART ++ "=" ++ PKG };
const M2 = [_][]const u8{ "--map", D ++ "/srcroot/=" ++ PKG };
const M3 = [_][]const u8{ "--map", P ++ "/" ++ ART ++ "=" ++ PKG };
const EX = [_][]const u8{ "--exclude", D ++ "/srcroot/buck-out/v2/gen/" };
const MUST = [_][]const u8{ "--must-contain", PKG ++ "tests/test_refusals.mojo", "--must-contain", PKG ++ "policy.mojo" };
const IO = [_][]const u8{ "--in", FX, "--out", OUT };
const BAD = [_][]const u8{ "--in", "bad.xml", "--out", OUT };

const Result = struct {
    status: u8,
    err: []const u8,
    out: ?[]const u8,
};

/// A directory of its own holding the fixture, where the program runs.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,

    fn init() !Case {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try put(tmp.dir, FX, fixture);
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = tmp };
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn alloc(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// The report `<classes>` holds, as bad.xml: the class is on its line 4.
    fn mk(self: *Case, classes: []const u8) !void {
        const text = try std.fmt.allocPrint(self.alloc(), "<?xml version=\"1.0\" ?>\n<coverage>\n<packages><package name=\"\"><classes>\n{s}\n</classes></package></packages>\n</coverage>\n", .{classes});
        try put(self.tmp.dir, "bad.xml", text);
    }

    /// Runs the program with `args` (no output file left from a run before).
    fn run(self: *Case, args: Args) !Result {
        const a = self.alloc();
        self.tmp.dir.deleteFile(OUT) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        var err = std.ArrayList(u8).empty;
        const status = N.entry(a, self.tmp.dir, args, err.writer(a));
        const out = self.tmp.dir.readFileAlloc(a, OUT, 1 << 20) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        return .{ .status = status, .err = err.items, .out = out };
    }

    /// Exit 0, with an output.
    fn ok(self: *Case, name: []const u8, args: Args) !Result {
        const r = try self.run(args);
        if (r.status != 0 or r.out == null) {
            std.debug.print("{s}: exit {d}, want 0 with an output; stderr:\n{s}\n", .{ name, r.status, r.err });
            return error.TestUnexpectedResult;
        }
        return r;
    }

    /// Exit 1, `msg` on stderr, and no output.
    fn refused(self: *Case, name: []const u8, msg: []const u8, args: Args) !Result {
        const r = try self.run(args);
        if (r.status != 1) {
            std.debug.print("{s}: exit {d}, want 1; stderr:\n{s}\n", .{ name, r.status, r.err });
            return error.TestUnexpectedResult;
        }
        try has(name, r.err, msg);
        if (r.out != null) {
            std.debug.print("{s}: an output was written\n", .{name});
            return error.TestUnexpectedResult;
        }
        return r;
    }

    fn cat(self: *Case, parts: []const Args) Args {
        var all = std.ArrayList([]const u8).empty;
        for (parts) |p| all.appendSlice(self.alloc(), p) catch @panic("out of memory");
        return all.items;
    }
};

fn put(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(bytes);
}

fn has(name: []const u8, hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("{s}: does not say '{s}'; it says:\n{s}\n", .{ name, needle, hay });
        return error.TestUnexpectedResult;
    }
}

fn hasNot(name: []const u8, hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) != null) {
        std.debug.print("{s}: holds '{s}':\n{s}\n", .{ name, needle, hay });
        return error.TestUnexpectedResult;
    }
}

/// `text` with the value of every `<attr>="..."` set to `value`.
fn setAttr(a: std.mem.Allocator, text: []const u8, comptime attr: []const u8, value: []const u8) ![]const u8 {
    return setBetween(a, text, attr ++ "=\"", "\"", value);
}

/// `text` with whatever lies between each `open` and the next `close` set to `value`.
fn setBetween(a: std.mem.Allocator, text: []const u8, open: []const u8, close: []const u8, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, open)) |o| {
        const v0 = o + open.len;
        const v1 = std.mem.indexOfPos(u8, text, v0, close) orelse return error.TestUnexpectedResult;
        try out.appendSlice(a, text[i..v0]);
        try out.appendSlice(a, value);
        i = v1;
    }
    try out.appendSlice(a, text[i..]);
    return out.items;
}

// 1. The golden output, byte for byte. It proves: longest-prefix mapping (the
// library's files take M1, not M2, which is given first); the placeholder
// form mapped (M3); the two policy.mojo classes merged into one (hits summed
// then clamped, the larger k of two branch lines with the same n); a line
// number given twice in one class merged; lines and classes sorted; hits
// clamped to 0/1; a <method>'s lines not read; the excluded generated file
// dropped although M2 covers it; a self-closing <class> kept with no lines;
// the XML entities of a file name decoded and written back escaped; the
// sandbox path and the run's own directories absent (--forbid passes).
test "golden: the report gives fixtures/kcov_full_paths.golden.xml byte for byte" {
    var c = try Case.init();
    defer c.deinit();
    const here = try c.tmp.dir.realpathAlloc(c.alloc(), ".");
    const cwd = try std.fs.cwd().realpathAlloc(c.alloc(), ".");
    const args = c.cat(&.{ &IO, &M2, &M1, &M3, &EX, &MUST, &.{ "--forbid", D, "--forbid", here, "--forbid", cwd } });
    const r = try c.ok("golden", args);
    try std.testing.expectEqualStrings(golden, r.out.?);
    try has("golden", r.err, "7 class(es) read, 1 excluded, 5 written");
}

// 2. The output does not depend on the run: other hit counts above 0, another
// timestamp and other rates and <source> give the same bytes.
test "rerun: other hit counts, timestamp, rates and <source> give the same bytes" {
    var c = try Case.init();
    defer c.deinit();
    const a = c.alloc();
    const first = (try c.ok("rerun, first", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST))).out.?;
    var t: []const u8 = try std.mem.replaceOwned(u8, a, fixture, "hits=\"3\"", "hits=\"41\"");
    t = try setAttr(a, t, "timestamp", "1790000999");
    t = try setAttr(a, t, "line-rate", "0.5");
    t = try setBetween(a, t, "<source>", "</source>", P ++ "/");
    if (std.mem.eql(u8, t, fixture)) {
        std.debug.print("rerun: the edited report equals the fixture, so this case checks nothing\n", .{});
        return error.TestUnexpectedResult;
    }
    try put(c.tmp.dir, "rerun.xml", t);
    const again = (try c.ok("rerun", &([_][]const u8{ "--in", "rerun.xml", "--out", OUT } ++ M1 ++ M2 ++ M3 ++ EX ++ MUST))).out.?;
    try std.testing.expectEqualStrings(first, again);
}

// 3. Without the exclusion, the generated file is mapped by M2 and kept:
// case 1's drop is the exclusion's doing, and an exclusion wins over a map.
test "no exclusion: the generated file is mapped and kept" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.ok("no exclusion", &(IO ++ M1 ++ M2 ++ M3 ++ MUST));
    try has("no exclusion", r.out.?, "filename=\"" ++ PKG ++ "buck-out/v2/gen/widget/0123456789abcdef/gen.mojo\"");
}

// 3b. An exclusion wins over a longer map: everything under the source root is
// excluded although a longer map covers the generated file; only the
// placeholder form's file is left.
test "exclusion over a longer map: the exclusion wins" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.ok("exclusion over a longer map", &(IO ++ M3 ++ [_][]const u8{
        "--map",          D ++ "/srcroot/buck-out/v2/gen/=x/",
        "--exclude",      D ++ "/srcroot/",
        "--must-contain", PKG ++ "policy.mojo",
    }));
    try has("exclusion over a longer map", r.err, "7 class(es) read, 6 excluded, 1 written");
    try hasNot("exclusion over a longer map", r.out.?, "gen.mojo");
}

// 3c. Merging branch lines of two classes that map to one path: true wins over
// false (either order), false over none, and two true with the same n keep the
// larger k.
test "branch merge: true over false either way, false over none, the larger k" {
    var c = try Case.init();
    defer c.deinit();
    try c.mk("<class filename=\"" ++ D ++ "/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"0\" branch=\"false\"/><line number=\"6\" hits=\"0\"/><line number=\"7\" hits=\"1\" branch=\"true\" condition-coverage=\"100% (2/2)\"/></lines></class>\n" ++
        "<class filename=\"" ++ D ++ "/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/><line number=\"6\" hits=\"0\" branch=\"false\"/><line number=\"7\" hits=\"0\" branch=\"false\"/></lines></class>");
    const r = try c.ok("branch merge", &(BAD ++ M2 ++ [_][]const u8{ "--must-contain", PKG ++ "tests/m.mojo" }));
    for ([_][]const u8{
        "<line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/>",
        "<line number=\"6\" hits=\"0\" branch=\"false\"/>",
        "<line number=\"7\" hits=\"1\" branch=\"true\" condition-coverage=\"100% (2/2)\"/>",
    }) |want| try has("branch merge", r.out.?, want);
}

// 3d. Two true branch lines with different n are refused.
test "branch count mismatch: two true lines with different n are refused" {
    var c = try Case.init();
    defer c.deinit();
    try c.mk("<class filename=\"" ++ D ++ "/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/></lines></class>\n" ++
        "<class filename=\"" ++ D ++ "/srcroot/tests/m.mojo\"><lines><line number=\"5\" hits=\"1\" branch=\"true\" condition-coverage=\"25% (1/4)\"/></lines></class>");
    _ = try c.refused("branch count mismatch", PKG ++ "tests/m.mojo:5: two reports of the line give 2 and 4 branches", &(BAD ++ M2 ++ [_][]const u8{ "--must-contain", PKG ++ "tests/m.mojo" }));
}

// 4. A file name no map covers is refused, named, and nothing is written:
// without M2 the three test files are unmapped. Only a mapped file is
// required, so the refusal is the unmapped names' alone. Each of the three is
// named and counted (the check is not left to the clean-path backstop, which
// would refuse an absolute path passed through with another message).
test "unmapped: each unmapped name is refused, named and counted" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.refused("unmapped", "unmapped file name '" ++ D ++ "/srcroot/tests/test_refusals.mojo'", &(IO ++ M1 ++ M3 ++ EX ++ [_][]const u8{ "--must-contain", PKG ++ "policy.mojo" }));
    for ([_][]const u8{
        "unmapped file name '" ++ D ++ "/srcroot/tests/test_empty.mojo'",
        "3 unmapped file name(s) in " ++ FX ++ "; nothing written",
    }) |want| try has("unmapped", r.err, want);
}

// 5. A --must-contain path with no class (a test whose own source kcov
// dropped) is refused.
test "must-contain: a path with no class is refused" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("must-contain", "no class for " ++ PKG ++ "tests/test_missing.mojo", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--must-contain", PKG ++ "tests/test_missing.mojo" }));
}

// 5b. A --must-contain path whose class has no line is refused: an empty class
// is no evidence that kcov read the source.
test "must-contain, no line: a path whose class has no line is refused" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("must-contain, no line", "the class for " ++ PKG ++ "tests/test_empty.mojo has no line", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--must-contain", PKG ++ "tests/test_empty.mojo" }));
}

// 6. An output holding a --forbid string is refused, whether the string is
// given as the path holds it (a&b) or as the output bytes hold it (a&amp;b).
test "forbid: refused as the path holds it" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("forbid", "would hold 'a&b'", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--forbid", "a&b" }));
}

test "forbid, escaped: refused as the output bytes hold it" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("forbid, escaped", "would hold 'a&amp;b'", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--forbid", "a&amp;b" }));
}

// 7. A map whose result is not a clean relative path is refused.
test "dot-dot: a mapped path with a '..' segment is refused" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("dot-dot", "which has an empty, '.' or '..' segment", &(IO ++ [_][]const u8{ "--map", D ++ "/srcroot/=../", "--map", P ++ "/=x/", "--must-contain", "x" }));
}

// 7b. A mapped path that is not UTF-8 is refused: covcheck would decode it
// lossily and look for a file of another name.
test "not UTF-8: a mapped path with byte 0xff is refused" {
    var c = try Case.init();
    defer c.deinit();
    try c.mk("<class filename=\"" ++ D ++ "/srcroot/tests/a\xff.mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class>\n" ++
        "<class filename=\"" ++ D ++ "/srcroot/tests/b.mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class>");
    _ = try c.refused("not UTF-8", "which is not UTF-8", &(BAD ++ M2 ++ [_][]const u8{ "--must-contain", PKG ++ "tests/b.mojo" }));
}

// 8. Malformed reports are refused, naming the line.
test "malformed: unknown entity, line 0, mismatched tag, branch without condition" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "unknown entity", "<class filename=\"" ++ D ++ "/srcroot/tests/a&nbsp;.mojo\"><lines></lines></class>", "bad.xml:4: unknown entity '&nbsp;'" },
        .{ "line 0", "<class filename=\"" ++ D ++ "/srcroot/tests/a.mojo\"><lines><line number=\"0\" hits=\"1\"/></lines></class>", "bad.xml:4: <line> number 0" },
        .{ "mismatched tag", "<class filename=\"" ++ D ++ "/srcroot/tests/a.mojo\"><lines></class>", "bad.xml:4: </class> closes <lines>" },
        .{ "branch without condition", "<class filename=\"" ++ D ++ "/srcroot/tests/a.mojo\"><lines><line number=\"3\" hits=\"1\" branch=\"true\"/></lines></class>", "bad.xml:4: a branch line has no condition-coverage" },
    };
    for (cases) |k| {
        var c = try Case.init();
        defer c.deinit();
        try c.mk(k[1]);
        _ = try c.refused(k[0], k[2], &(BAD ++ M2 ++ [_][]const u8{ "--must-contain", "x" }));
    }
}

// 9. Bad usage exits 2 with the usage line: no --must-contain, a map without
// '=' or whose ABS does not end with '/', an unknown flag, a map ABS, --in or
// --out given twice.
test "usage: bad command lines exit 2 with the usage line" {
    const cases = [_]Args{
        &M2,
        &([_][]const u8{ "--map", D ++ "/srcroot" } ++ MUST),
        &([_][]const u8{ "--map", D ++ "/srcroot=" ++ PKG } ++ MUST),
        &(M2 ++ MUST ++ [_][]const u8{ "--frobnicate", "x" }),
        &(M2 ++ M2 ++ MUST),
        &([_][]const u8{ "--in", FX } ++ M2 ++ MUST),
        &([_][]const u8{ "--out", OUT } ++ M2 ++ MUST),
    };
    for (cases, 0..) |rest, i| {
        var c = try Case.init();
        defer c.deinit();
        const r = try c.run(c.cat(&.{ &IO, rest }));
        if (r.status != 2 or !(std.mem.startsWith(u8, r.err, "usage: cov_normalize") or std.mem.indexOf(u8, r.err, "\nusage: cov_normalize") != null)) {
            std.debug.print("usage case {d}: exit {d}, want 2 with a usage line; stderr:\n{s}\n", .{ i, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
}

// 10. A write of the output that fails part way (EFBIG: a file size limit of
// 512 bytes, with SIGXFSZ ignored) leaves no file, partial or temporary:
// exit 1, the output's directory empty. The output is 1.4 KiB; the probe
// checks the limit stops a plain write of it first.
test "failed write: a write cut short leaves the output's directory empty" {
    var c = try Case.init();
    defer c.deinit();
    try c.tmp.dir.makeDir("o");
    const posix = std.posix;
    const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
    var old_act: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.XFSZ, &ign, &old_act);
    defer posix.sigaction(posix.SIG.XFSZ, &old_act, null);
    const old = try posix.getrlimit(.FSIZE);
    try posix.setrlimit(.FSIZE, .{ .cur = 512, .max = old.max });
    var restored = false;
    defer if (!restored) posix.setrlimit(.FSIZE, old) catch {};

    // The probe: a plain write of the output twice over is stopped.
    {
        var f = try c.tmp.dir.createFile("probe", .{});
        defer f.close();
        if (f.writeAll(golden ++ golden)) {
            std.debug.print("probe: the size limit did not stop the write\n", .{});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.FileTooBig) return e;
        try std.testing.expect((try f.getEndPos()) < 2 * golden.len);
    }

    var err = std.ArrayList(u8).empty;
    const status = N.entry(c.alloc(), c.tmp.dir, &([_][]const u8{ "--in", FX, "--out", "o/out.xml" } ++ M1 ++ M2 ++ M3 ++ EX ++ MUST), err.writer(c.alloc()));
    try posix.setrlimit(.FSIZE, old);
    restored = true;
    if (status != 1) {
        std.debug.print("failed write: exit {d}, want 1; stderr:\n{s}\n", .{ status, err.items });
        return error.TestUnexpectedResult;
    }
    var o = try c.tmp.dir.openDir("o", .{ .iterate = true });
    defer o.close();
    var it = o.iterate();
    if (try it.next()) |e| {
        std.debug.print("failed write: the output's directory holds '{s}'\n", .{e.name});
        return error.TestUnexpectedResult;
    }
}

// 6b. --forbid-path refuses an output holding the string as a whole path (the
// bytes before and after it are not in [A-Za-z0-9._-]), not one holding it as
// a part of a longer name: the working directory `/work` is in `/work/x`, not
// in `/workflows/ci.yml`.
test "forbid-path: refused as a whole path, as the path holds it and escaped" {
    var c = try Case.init();
    defer c.deinit();
    _ = try c.refused("forbid-path", "would hold 'src/widget_retry' as a whole path (--forbid-path)", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--forbid-path", "src/widget_retry" }));
    _ = try c.refused("forbid-path, escaped", "would hold 'a&amp;b' as a whole path (--forbid-path)", &(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--forbid-path", "a&amp;b" }));
}

test "forbid-path: a string that is only a part of a longer name passes" {
    var c = try Case.init();
    defer c.deinit();
    const args = c.cat(&.{ &IO, &M1, &M2, &M3, &EX, &MUST, &.{ "--forbid-path", "src/widget", "--forbid-path", "retry/tests", "--forbid-path", "src/widget_retry/te" } });
    _ = try c.ok("forbid-path, part of a name", args);
}

test "forbid-path: an empty string is a usage error" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run(&(IO ++ M1 ++ M2 ++ M3 ++ EX ++ MUST ++ [_][]const u8{ "--forbid-path", "" }));
    try std.testing.expectEqual(@as(u8, 2), r.status);
    try has("forbid-path, empty", r.err, "--forbid-path is empty");
}

test "holdsPath: whole paths, the ends of the text, NUL, and names that merely hold the string" {
    const L = @import("cov_normalize.zig");
    const t = std.testing;
    try t.expect(L.holdsPath("/work", "/work"));
    try t.expect(L.holdsPath("x /work/buck-out/x", "/work"));
    try t.expect(L.holdsPath("x /work\x00y", "/work"));
    try t.expect(L.holdsPath("file:///work/a", "/work"));
    try t.expect(L.holdsPath("/workflows and /work/x", "/work"));
    try t.expect(!L.holdsPath("github.com/tokio-rs/prost/actions/workflows/ci.yml", "/work"));
    try t.expect(!L.holdsPath("/work-x /work.rs /work_a /work9", "/work"));
    try t.expect(!L.holdsPath("/a/work/x a/work ./work", "/work"));
    try t.expect(!L.holdsPath("", "/work"));
    try t.expect(!L.holdsPath("/work", ""));
}
