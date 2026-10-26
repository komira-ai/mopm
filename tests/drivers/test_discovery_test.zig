//! The port of the former tests/e2e/test_discovery.sh in Zig, for the build farm: `mopm test --list`
//! against the real Mojo toolchain (komira's pinned 1.0.0), no shell, no pixi.
//! It replaces tests/e2e/test_discovery.sh (deleted); the check is //:discovery.
//!
//! tests/e2e/testpkg is a package with three test files, one of each kind:
//! a bare file (mopm generates its main), a self-hosted file registering its
//! tests explicitly, and a self-hosted file using TestSuite.discover_tests;
//! plus files outside the convention. testpkg/expected.txt is the list.
//!
//!   1. `mopm test --list` (sources only) prints exactly expected.txt;
//!   2. `mopm test --list --check --strict-discovery` builds every file (the
//!      bare one through its generated harness), runs each binary with
//!      --skip-all, finds no difference and prints the same list;
//!   3. independently of mopm's comparison, this driver runs each built
//!      binary with --skip-all itself and compares the names with
//!      expected.txt; and checks the harness starts with the test file
//!      unchanged;
//!   4. the harness runs one test per `--only <name>`: `--only test_one`
//!      passes and runs nothing else; `--only test_raises` fails; no argument
//!      runs all four (one fails);
//!   5. tests/e2e/testpkg_mismatch registers a test only at run time, so the
//!      scan lists a test the binary does not: --check warns (exit 0) and
//!      --check --strict-discovery refuses (exit 2, nothing on stdout).

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    prefix: []const u8,

    const Two = struct { code: u8, signaled: bool, out: []u8, err: []u8 };

    /// `mopm <args>` in `dir`, standard output and standard error apart.
    fn mopm2(c: *Ctx, dir: []const u8, args: []const []const u8, tag: []const u8) !Two {
        var env = try c.m.freshEnv();
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        const err_path = try h.fmt(c.a, "{s}/scratch/{s}.err", .{ c.m.work, tag });
        const r = try h.run(c.a, argv, &env, .{ .cwd = dir, .capture = .stdout, .stderr_path = err_path });
        return .{ .code = r.code, .signaled = r.signaled, .out = r.text, .err = try h.readFile(c.a, err_path) };
    }

    fn exitIs(r: Two, want: u8) bool {
        return !r.signaled and r.code == want;
    }

    /// A built binary, run with an empty environment.
    fn runBin(c: *Ctx, exe: []const u8, args: []const []const u8, dir: []const u8) !h.Ran {
        var env = std.process.EnvMap.init(c.a);
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        return h.run(c.a, argv, &env, .{ .cwd = dir });
    }

    /// The one binary mopm built for the test file `stem`.mojo, or null.
    fn binFor(c: *Ctx, dir: []const u8, stem: []const u8) !?[]const u8 {
        const root = try h.fmt(c.a, "{s}/target/mopm/bin", .{dir});
        const found = try h.findFiles(c.a, root, stem);
        if (found.len != 1) return null;
        return try h.fmt(c.a, "{s}/{s}", .{ root, found[0] });
    }

    /// The names the file's lines of `expected` give, sorted.
    fn wantNames(c: *Ctx, expected: []const u8, file: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).init(c.a);
        var lines = std.mem.splitScalar(u8, expected, '\n');
        const prefix = try h.fmt(c.a, "{s}::", .{file});
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, prefix)) try out.append(l[prefix.len..]);
        }
        h.sortStrings(out.items);
        return out.items;
    }
};

test "discovery: mopm test --list against the real mojo (tests/e2e/test_discovery.sh)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    try run(a, &rep);
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    const prefix = try h.join(a, &.{ m.work, "env" });
    try m.prefix(prefix, true);
    var c = Ctx{ .a = a, .rep = rep, .m = m, .mopm = try h.toolPathAbs(a, "MOPM"), .prefix = prefix };
    const v = try m.run(prefix, &.{"--version"}, null);
    std.debug.print("== mojo: {s}", .{v.text});

    const pkg = try h.join(a, &.{ m.work, "tests/e2e/testpkg" });
    const mismatch = try h.join(a, &.{ m.work, "tests/e2e/testpkg_mismatch" });
    const expected = try h.readFile(a, try h.join(a, &.{ pkg, "expected.txt" }));

    // ------------------------------------------------------------ 1
    {
        const r = try c.mopm2(pkg, &.{ "test", "--list" }, "list");
        rep.check("mopm test --list prints expected.txt", Ctx.exitIs(r, 0) and std.mem.eql(u8, r.out, expected) and r.err.len == 0, try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ r.code, r.out, r.err }));
    }

    // ------------------------------------------------------------ 2
    {
        const r = try c.mopm2(pkg, &.{ "test", "--list", "--check", "--strict-discovery", "--prefix", prefix }, "check");
        rep.check("mopm test --list --check --strict-discovery: built, listed, no difference", Ctx.exitIs(r, 0) and std.mem.eql(u8, r.out, expected), try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ r.code, r.out, r.err }));
    }

    // ------------------------------------------------------------ 3
    for ([_][]const u8{ "tests/test_bare.mojo", "tests/sub/test_registered.mojo", "src/testpkg/tests/test_discovered.mojo" }) |f| {
        const stem = std.fs.path.stem(f);
        const label = try h.fmt(a, "{s}: the binary's own --skip-all lists exactly the expected tests", .{f});
        const b = try c.binFor(pkg, stem) orelse {
            rep.check(label, false, try h.fmt(a, "no single built binary named {s} under target/mopm/bin", .{stem}));
            continue;
        };
        const r = try c.runBin(b, &.{"--skip-all"}, pkg);
        const text = try h.stripAnsi(a, r.text);
        const got = try h.resultNames(a, text, "SKIP");
        h.sortStrings(got);
        const want = try c.wantNames(expected, f);
        rep.check(label, !r.signaled and r.code == 0 and want.len > 0 and h.eqlStrings(want, got), try h.fmt(a, "exit {d}; got {d} names, want {d}; output:\n{s}", .{ r.code, got.len, want.len, text }));
    }

    {
        const gens = try h.findFiles(a, try h.join(a, &.{ pkg, "target/mopm/gen" }), "test_bare.mojo");
        const src = try h.readFile(a, try h.join(a, &.{ pkg, "tests/test_bare.mojo" }));
        var ok = gens.len >= 1;
        var detail: []const u8 = "no generated harness for tests/test_bare.mojo";
        if (ok) {
            const harness = try h.readFile(a, try h.fmt(a, "{s}/target/mopm/gen/{s}", .{ pkg, gens[0] }));
            const starts = std.mem.startsWith(u8, harness, src);
            ok = starts and h.hasLine(harness, "    suite.test[test_raises]()") and !h.contains(harness, "suite.test[test_helper]");
            detail = "the harness does not start with tests/test_bare.mojo, or registers the wrong functions";
        }
        rep.check("the harness is the bare file unchanged, then a main registering its tests", ok, detail);
        const reg = try h.findFiles(a, try h.join(a, &.{ pkg, "target/mopm/gen" }), "test_registered.mojo");
        rep.check("no harness is generated for a self-hosted file", reg.len == 0, "a harness was generated for tests/sub/test_registered.mojo");
    }

    // ------------------------------------------------------------ 4
    if (try c.binFor(pkg, "test_bare")) |bare| {
        const one = try c.runBin(bare, &.{ "--only", "test_one" }, pkg);
        const one_t = try h.stripAnsi(a, one.text);
        const passes = try h.resultNames(a, one_t, "PASS");
        const fails = try h.resultNames(a, one_t, "FAIL");
        rep.check("harness --only test_one runs that one test and passes", !one.signaled and one.code == 0 and passes.len == 1 and fails.len == 0 and std.mem.eql(u8, passes[0], "test_one"), one_t);

        const raises = try c.runBin(bare, &.{ "--only", "test_raises" }, pkg);
        const raises_t = try h.stripAnsi(a, raises.text);
        const r_pass = try h.resultNames(a, raises_t, "PASS");
        const r_fail = try h.resultNames(a, raises_t, "FAIL");
        rep.check("harness --only test_raises runs that one test and fails", raises.code != 0 and r_pass.len == 0 and r_fail.len == 1 and std.mem.eql(u8, r_fail[0], "test_raises") and h.contains(raises_t, "planted"), raises_t);

        const all = try c.runBin(bare, &.{}, pkg);
        const all_t = try h.stripAnsi(a, all.text);
        const a_pass = try h.resultNames(a, all_t, "PASS");
        const a_fail = try h.resultNames(a, all_t, "FAIL");
        rep.check("the harness with no argument runs all four tests (three pass, one fails)", all.code != 0 and a_pass.len == 3 and a_fail.len == 1, all_t);
    } else {
        rep.check("harness runs", false, "no binary for tests/test_bare.mojo");
    }

    // ------------------------------------------------------------ 5
    {
        const f = "tests/test_hidden_registration.mojo";
        const warn = try c.mopm2(mismatch, &.{ "test", "--list", "--check", "--prefix", prefix }, "warn");
        const want_out = try h.fmt(a, "{s}::test_listed\n{s}::test_never_registered\n", .{ f, f });
        const head = try h.fmt(a, "mopm test: warning: {s}: the scan and the `--skip-all` listing of the built file differ", .{f});
        rep.check("a self-hosted file whose listing differs: a warning, the scanned list, exit 0", Ctx.exitIs(warn, 0) and std.mem.eql(u8, warn.out, want_out) and
            h.hasLinePrefix(warn.err, head) and h.hasLineSuffix(warn.err, "only in the scan:", "test_never_registered"), try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ warn.code, warn.out, warn.err }));

        const strict = try c.mopm2(mismatch, &.{ "test", "--list", "--check", "--strict-discovery", "--prefix", prefix }, "strict");
        const head2 = try h.fmt(a, "mopm test: {s}: the scan and the `--skip-all` listing of the built file differ", .{f});
        rep.check("the same file with --strict-discovery: refused, exit 2, nothing listed", Ctx.exitIs(strict, 2) and strict.out.len == 0 and
            h.hasLinePrefix(strict.err, head2) and h.hasLineSuffix(strict.err, "only in the scan:", "test_never_registered"), try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ strict.code, strict.out, strict.err }));
    }
}
