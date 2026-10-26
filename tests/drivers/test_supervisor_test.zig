//! The port of the former tests/e2e/test_supervisor.sh and check_supervisor.py in Zig, for the build
//! farm (no shell, no Python, no pgrep or pkill): `mopm test` running tests
//! against the real Mojo toolchain (komira's pinned 1.0.0). They replace
//! tests/e2e/test_supervisor.sh and check_supervisor.py (deleted); the check is //:supervisor.
//!
//! tests/e2e/supervise is a package whose tests each must get one exact
//! verdict (the comment above each test names it): pass, an assertion and a
//! raise (FAIL), libc abort (CRASH SIGABRT), a null read (CRASH SIGSEGV), a
//! test after the crashes (PASS), a sleep (TIMEOUT hung) that also leaves a
//! `sleep 7919` behind in its process group, 4 s of computing under a 6 s
//! deadline (PASS), endless computing (TIMEOUT slow), an early _exit(0)
//! (FAIL), 1 GiB touched under a 512 MiB cap (OOM), a test calling a native
//! library (PASS), and a self-hosted file (PASS).
//!
//!   1. installs the package greet (libgreet, as in the autolink driver) into
//!      the environment, so test_native.mojo links only if mopm test builds
//!      with the link arguments of `mopm build`;
//!   2. runs `mopm test --timeout 6 --memory 512 --format json --junit` on
//!      the package: exit 1, and every verdict, field and count of the JSON
//!      and the JUnit XML is checked;
//!   3. checks that the checker itself fails on a wrong verdict: it is run
//!      on copies of the results with one verdict changed, and must fail;
//!   4. checks that no `sleep 7919` survived (the group kill), and that the
//!      native test's binary names libgreet;
//!   5. human output: the memory file with --memory 0 --timeout 12 (no cap:
//!      the same test is now TIMEOUT hung, so the OOM above was the cap's),
//!      and the self-hosted file alone (exit 0);
//!   6. supervisor self-test: test_verdicts.mojo with the test-only
//!      --test-only-no-group-kill. The `sleep 7919` must now survive, and
//!      mopm must notice and exit 5, so the check in 4 is shown to fail when
//!      the group kill is broken.
//!
//! Leftover processes. The shell script looked for `sleep 7919` by name over
//! the whole machine (pgrep, pkill), which on a shared worker would also see
//! and kill the sleeps of another action. This driver puts a mark of its own
//! (its pid and start time) in the environment of every `mopm` it starts; the
//! fixture's `sleep` inherits it through the test binary, so the driver
//! recognises what its own run left behind by that mark, however the process
//! was reparented, and kills exactly those pids.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const r = @import("results.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

test {
    std.testing.refAllDecls(r);
}

const V = "tests/test_verdicts.mojo";
const M = "tests/test_memory.mojo";

/// The deadline of the uncapped run of test_memory.mojo, in seconds. The verdict `hung` means "under 5% of one
/// CPU over the last second before the deadline" (src/core/test_proc.zig), so it is true only if the fixture
/// has finished touching its 1 GiB, and then sleeps, by deadline - 1 s. Nothing tells the driver when that is.
/// The capped run passes 512 MiB in about 330 ms on the ubuntu leg, but on the macos-14 runner the touch was still going at 3 s twice
/// (main runs on 16 and 20 October: `slow at the 3 s deadline ... still computing`, 3201 and 3413 ms). A
/// deadline this far above the touch time leaves it a margin of an order of magnitude: the check no longer
/// races the memset, and it still fails (as `slow`) if the touch really never ends.
const nocap_deadline_s = "12";
const N = "tests/test_native.mojo";
const S = "tests/test_self_hosted.mojo";

const Expect = struct {
    id: []const u8,
    status: []const u8,
    exit_zero: bool = false,
    exit_null: bool = false,
    signal_null: bool = false,
    signal_name: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    timeout_null: bool = false,
    message_empty: bool = false,
    message_has: ?[]const u8 = null,
    output_has: ?[]const u8 = null,
    ms: ?[2]i64 = null,
};

/// The order the run must report, and the exact verdict of each.
const expected = [_]Expect{
    .{ .id = M ++ "::test_oom", .status = "oom", .signal_name = "SIGKILL", .timeout_null = true },
    .{ .id = N ++ "::test_native", .status = "pass", .exit_zero = true },
    .{ .id = S ++ "::test_registered_pass", .status = "pass", .exit_zero = true },
    .{ .id = V ++ "::test_pass", .status = "pass", .exit_zero = true, .message_empty = true },
    .{ .id = V ++ "::test_assert_fails", .status = "fail", .signal_null = true, .output_has = "planted assertion" },
    .{ .id = V ++ "::test_raises", .status = "fail", .signal_null = true, .output_has = "planted raise" },
    .{ .id = V ++ "::test_abort", .status = "crash", .signal_name = "SIGABRT", .exit_null = true },
    .{ .id = V ++ "::test_segfault", .status = "crash", .signal_name = "SIGSEGV", .exit_null = true },
    .{ .id = V ++ "::test_after_crashes", .status = "pass", .exit_zero = true },
    .{ .id = V ++ "::test_hang", .status = "timeout", .timeout = "hung", .signal_name = "SIGKILL", .ms = .{ 6000, 9000 } },
    .{ .id = V ++ "::test_slow_ok", .status = "pass", .exit_zero = true, .ms = .{ 4000, 6000 } },
    .{ .id = V ++ "::test_spin_forever", .status = "timeout", .timeout = "slow", .signal_name = "SIGKILL", .ms = .{ 6000, 9000 } },
    .{ .id = V ++ "::test_exits_early", .status = "fail", .exit_zero = true, .message_has = "no PASS line" },
};

const test_keys = [_][]const u8{
    "id",              "file",           "name",       "status",                 "ms",            "cpu_ms",
    "peak_rss_bytes",  "exit_code",      "signal",     "signal_name",            "timeout",       "leftover_processes",
    "message",         "stdout",         "stderr",     "ignore",                 "binary_sha256", "attempts",
};

/// JUnit element and type per non-passing status.
fn junitKind(status: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.eql(u8, status, "fail")) return .{ "failure", "FAIL" };
    if (std.mem.eql(u8, status, "crash")) return .{ "error", "CRASH" };
    if (std.mem.eql(u8, status, "timeout")) return .{ "error", "TIMEOUT" };
    return .{ "error", "OOM" };
}

/// check_supervisor.py: the JSON and JUnit text of the run against `expected`;
/// `pkg` is where mopm test ran (output paths in the JSON are relative to it).
fn checkRun(c: *r.Chk, run_json: []const u8, junit_xml: []const u8, pkg: []const u8) !void {
    const a = c.a;
    const doc = try r.parse(a, run_json);
    c.that(r.int(r.field(doc, "schema")) == 1, "json: schema is 1", .{});
    c.that(r.int(r.field(doc, "exit_code")) == 1, "json: exit_code is 1", .{});
    const st = r.field(doc, "settings") orelse .null;
    c.that(r.int(r.field(st, "timeout_ms")) == 6000 and r.int(r.field(st, "memory_cap_bytes")) == 512 << 20 and
        std.mem.eql(u8, r.str(r.field(st, "memory_enforcement")) orelse "", "rss-sampled") and
        r.int(r.field(st, "opt_level")) == 1 and std.mem.eql(u8, r.str(r.field(st, "assert")) orelse "", "all"), "json: settings", .{});
    const sm = r.field(doc, "summary") orelse .null;
    const want_sum = [_]struct { []const u8, i64 }{
        .{ "tests", 13 },  .{ "pass", 5 }, .{ "fail", 3 },  .{ "crash", 2 },         .{ "timeout", 2 }, .{ "oom", 1 },
        .{ "compile_error", 0 }, .{ "flaky", 0 }, .{ "skip", 0 }, .{ "filtered_out", 0 },
    };
    var sum_ok = sm == .object and sm.object.count() == want_sum.len;
    for (want_sum) |kv| sum_ok = sum_ok and r.int(r.field(sm, kv[0])) == kv[1];
    c.that(sum_ok, "json: summary", .{});
    const tests = r.array(r.field(doc, "tests"));
    var order_ok = tests.len == expected.len;
    if (order_ok) for (tests, expected) |t, e| {
        order_ok = order_ok and std.mem.eql(u8, r.str(r.field(t, "id")) orelse "", e.id);
    };
    c.that(order_ok, "json: exactly the expected tests, in order", .{});

    for (expected) |e| {
        const t = r.testById(tests, e.id) orelse {
            c.that(false, "{s}: missing", .{e.id});
            continue;
        };
        c.that(r.hasExactKeys(t, &test_keys), "{s}: the documented fields", .{e.id});
        const status = r.str(r.field(t, "status")) orelse "";
        c.that(std.mem.eql(u8, status, e.status), "{s}: status {s} (got {s}: {s})", .{ e.id, e.status, status, r.str(r.field(t, "message")) orelse "" });
        const file = r.str(r.field(t, "file")) orelse "";
        const name = r.str(r.field(t, "name")) orelse "";
        c.that(std.mem.eql(u8, try std.fmt.allocPrint(a, "{s}::{s}", .{ file, name }), e.id), "{s}: file and name", .{e.id});
        const lo = r.field(t, "leftover_processes");
        c.that(lo != null and lo.? == .bool and !lo.?.bool, "{s}: no leftover processes", .{e.id});
        // No --retries: exactly one attempt, and the test's fields are its fields.
        const att = r.array(r.field(t, "attempts"));
        var att_ok = att.len == 1 and r.int(r.field(att[0], "attempt")) == 1 and std.mem.eql(u8, r.str(r.field(att[0], "status")) orelse "", status);
        if (att.len == 1) for ([_][]const u8{ "exit_code", "signal", "timeout", "message", "stdout", "stderr" }) |k| {
            att_ok = att_ok and jsonEql(r.field(att[0], k), r.field(t, k));
        };
        c.that(att_ok, "{s}: one attempt, the same as the test", .{e.id});
        const sha = r.str(r.field(t, "binary_sha256"));
        c.that(sha != null and sha.?.len == 64, "{s}: binary_sha256 is a sha256", .{e.id});
        c.that(r.int(r.field(t, "ms")) != null and r.int(r.field(t, "cpu_ms")) != null, "{s}: ms and cpu_ms are integers", .{e.id});
        const msg = r.str(r.field(t, "message")) orelse "<not a string>";
        c.that(std.mem.eql(u8, status, "pass") == (msg.len == 0), "{s}: a message exactly when it did not pass", .{e.id});

        if (e.exit_zero) c.that(r.int(r.field(t, "exit_code")) == 0, "{s}: exit_code is 0", .{e.id});
        if (e.exit_null) c.that(r.isNull(r.field(t, "exit_code")), "{s}: exit_code is null", .{e.id});
        if (e.signal_null) c.that(r.isNull(r.field(t, "signal")), "{s}: signal is null", .{e.id});
        if (e.signal_name) |s| c.that(std.mem.eql(u8, r.str(r.field(t, "signal_name")) orelse "", s), "{s}: signal_name is {s}", .{ e.id, s });
        if (e.timeout) |s| c.that(std.mem.eql(u8, r.str(r.field(t, "timeout")) orelse "", s), "{s}: timeout is {s}", .{ e.id, s });
        if (e.timeout_null) c.that(r.isNull(r.field(t, "timeout")), "{s}: timeout is null", .{e.id});
        if (e.message_empty) c.that(msg.len == 0, "{s}: message is empty", .{e.id});
        if (e.message_has) |s| c.that(h.contains(msg, s), "{s}: message mentions {s}", .{ e.id, s });
        if (e.ms) |b| {
            const ms = r.int(r.field(t, "ms")) orelse -1;
            c.that(b[0] <= ms and ms < b[1], "{s}: {d} <= ms < {d} (got {d})", .{ e.id, b[0], b[1], ms });
        }
        if (e.output_has) |s| c.that(h.contains(try r.outputOf(a, pkg, t), s), "{s}: its captured output holds {s}", .{ e.id, s });
        for ([_][]const u8{ "stdout", "stderr" }) |k| {
            c.that(r.fileExists(a, pkg, r.str(r.field(t, k))), "{s}: output file {s} exists", .{ e.id, k });
        }
    }

    const root = try r.parseXml(a, junit_xml);
    c.that(std.mem.eql(u8, root.name, "testsuites"), "junit: root is <testsuites>", .{});
    const rt = root.attr("tests") orelse "";
    const rf = root.attr("failures") orelse "";
    const re = root.attr("errors") orelse "";
    c.that(std.mem.eql(u8, rt, "13") and std.mem.eql(u8, rf, "3") and std.mem.eql(u8, re, "5"), "junit: tests=13 failures=3 errors=5 (got {s} {s} {s})", .{ rt, rf, re });
    var cases = std.StringHashMap(*r.Node).init(a);
    for (try r.children(a, root, "testsuite")) |suite| {
        const sc = try r.children(a, suite, "testcase");
        c.that(std.mem.eql(u8, suite.attr("tests") orelse "", try std.fmt.allocPrint(a, "{d}", .{sc.len})), "junit: suite {s} counts its {d} cases", .{ suite.attr("name") orelse "", sc.len });
        for (sc) |tc| try cases.put(try std.fmt.allocPrint(a, "{s}::{s}", .{ tc.attr("classname") orelse "", tc.attr("name") orelse "" }), tc);
    }
    var cases_ok = cases.count() == expected.len;
    for (expected) |e| cases_ok = cases_ok and cases.contains(e.id);
    c.that(cases_ok, "junit: exactly the expected test cases", .{});
    for (expected) |e| {
        const tc = cases.get(e.id) orelse continue;
        if (std.mem.eql(u8, e.status, "pass")) {
            c.that(tc.kids.len == 0, "junit: {s} has no failure or error", .{e.id});
        } else {
            const k = junitKind(e.status);
            c.that(tc.kids.len == 1 and std.mem.eql(u8, tc.kids[0].name, k[0]) and std.mem.eql(u8, tc.kids[0].attr("type") orelse "", k[1]), "junit: {s} is <{s} type={s}>", .{ e.id, k[0], k[1] });
        }
    }
}

fn jsonEql(x: ?r.J, y: ?r.J) bool {
    if (r.isNull(x) and r.isNull(y)) return true;
    const p = x orelse return false;
    const q = y orelse return false;
    if (p == .string and q == .string) return std.mem.eql(u8, p.string, q.string);
    if (p == .integer and q == .integer) return p.integer == q.integer;
    return false;
}

// ------------------------------------------------------ leftover processes

/// The mark of this run: in the environment of every process the driver starts.
var run_mark: []const u8 = "";

/// The pids of live (not zombie) processes marked as ours whose command line
/// is `sleep 7919`: what a broken group kill leaves behind.
fn survivors(a: Allocator) ![]i32 {
    var out = std.ArrayList(i32).init(a);
    if (builtin.os.tag != .linux) {
        // No /proc: `pgrep -f`, as the shell test did. The mark cannot be
        // read from another process's environment here; a runner runs one job.
        var env = try h.environ(a);
        const r1 = try h.run(a, &.{ "/usr/bin/pgrep", "-f", "sleep 7919" }, &env, .{ .capture = .stdout });
        var lines = std.mem.tokenizeScalar(u8, r1.text, '\n');
        while (lines.next()) |l| {
            const pid = std.fmt.parseInt(i32, std.mem.trim(u8, l, " \t"), 10) catch continue;
            try out.append(pid);
        }
        return out.items;
    }
    const want = try std.fmt.allocPrint(a, "MOPM_E2E_MARK={s}", .{run_mark});
    var proc = try std.fs.cwd().openDir("/proc", .{ .iterate = true });
    defer proc.close();
    var it = proc.iterate();
    while (try it.next()) |e| {
        const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
        const stat = proc.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/stat", .{e.name}), 4096) catch continue;
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var f = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        const state = f.next() orelse continue;
        if (state[0] == 'Z') continue;
        const cmd = proc.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/cmdline", .{e.name}), 4096) catch continue;
        if (!std.mem.startsWith(u8, cmd, "sleep\x007919")) continue;
        const environ = proc.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/environ", .{e.name}), 1 << 20) catch continue;
        var vars = std.mem.splitScalar(u8, environ, 0);
        while (vars.next()) |v| if (std.mem.eql(u8, v, want)) {
            try out.append(pid);
            break;
        };
    }
    return out.items;
}

/// Kills exactly the given pids.
fn killAll(pids: []const i32) void {
    for (pids) |p| std.posix.kill(p, std.posix.SIG.KILL) catch {};
}

// ------------------------------------------------------------------ driver

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    prefix: []const u8,
    work: []const u8,
    pkg: []const u8,

    const Two = struct { code: u8, signaled: bool, out: []u8, err: []u8 };

    fn mopm2(c: *Ctx, args: []const []const u8, tag: []const u8) !Two {
        var env = try c.m.freshEnv();
        try env.put("MOPM_E2E_MARK", run_mark);
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        // Files, not pipes: a process the run leaves behind (step 6 plants
        // one) must not hold a pipe open and block the read.
        const err_path = try h.fmt(c.a, "{s}/{s}.err", .{ c.work, tag });
        const out_path = try h.fmt(c.a, "{s}/{s}.out", .{ c.work, tag });
        const res = try h.run(c.a, argv, &env, .{ .cwd = c.pkg, .capture = .none, .stdout_path = out_path, .stderr_path = err_path });
        return .{ .code = res.code, .signaled = res.signaled, .out = try h.readFile(c.a, out_path), .err = try h.readFile(c.a, err_path) };
    }

    fn plain(c: *Ctx, text: []const u8) []const u8 {
        return h.stripAnsi(c.a, text) catch text;
    }

    /// The checker on doctored results must fail.
    fn mutant(c: *Ctx, label: []const u8, run_json: []const u8, junit: []const u8, doctored_json: ?[]const u8, doctored_xml: ?[]const u8) !void {
        if (doctored_json == null and doctored_xml == null) {
            c.rep.check(try h.fmt(c.a, "checker self-test ({s})", .{label}), false, "the edit changed nothing");
            return;
        }
        var q = r.Chk{ .a = c.a, .quiet = true };
        try checkRun(&q, doctored_json orelse run_json, doctored_xml orelse junit, c.pkg);
        c.rep.check(try h.fmt(c.a, "checker self-test ({s}): rejected ({d} failed checks)", .{ label, q.failures }), q.failures > 0, "the checker accepted a wrong result");
    }
};

test "supervisor: mopm test verdicts against the real mojo (tests/e2e/test_supervisor.sh)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    try run(a, &rep);
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    run_mark = try h.fmt(a, "{d}.{d}", .{ std.crypto.random.int(u32), std.time.milliTimestamp() });
    const prefix = try h.join(a, &.{ m.work, "env" });
    try m.prefix(prefix, true);
    var c = Ctx{
        .a = a,
        .rep = rep,
        .m = m,
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .prefix = prefix,
        .work = try h.join(a, &.{ m.work, "out" }),
        .pkg = try h.join(a, &.{ m.work, "tests/e2e/supervise" }),
    };
    try std.fs.cwd().makePath(c.work);
    const here = try h.join(a, &.{ m.work, "tests/e2e" });
    const v = try m.run(prefix, &.{"--version"}, null);
    std.debug.print("== mojo: {s}", .{v.text});

    // ---------------------------------------------------------------- 1
    const libgreet = try mojo_env.libName(a, "greet");
    const lib = try h.join(a, &.{ prefix, "lib", libgreet });
    {
        var cc_args = std.ArrayList([]const u8).init(a);
        try cc_args.appendSlice(try mojo_env.shlibFlags(a, "greet"));
        try cc_args.appendSlice(&.{ "-o", lib, try h.join(a, &.{ here, "native/greet.c" }) });
        const cc = try m.cc(cc_args.items);
        if (cc.signaled or cc.code != 0) {
            std.debug.print("FAIL cc libgreet: {s}\n", .{cc.text});
            return error.Fatal;
        }
        const pc = try m.run(prefix, &.{ "precompile", try h.join(a, &.{ here, "pkgs/greet" }), "-o", try h.join(a, &.{ prefix, "lib/mojo/greet.mojoc" }) }, null);
        if (pc.signaled or pc.code != 0) {
            std.debug.print("FAIL mojo precompile greet: {s}\n", .{pc.text});
            return error.Fatal;
        }
        try h.writeFile(try h.join(a, &.{ prefix, "lib/mojo/greet.mopm.json" }), try h.fmt(a,
            \\{{"schema": 1, "name": "greet", "version": "1.0.0", "deps": [],
            \\ "native": [{{"id": "greet", "soname": "{s}", "file": "../{s}", "needs": []}}]}}
            \\
        , .{ libgreet, libgreet }));
        std.debug.print("ok   installed greet ({s}) into the environment\n", .{libgreet});
    }

    // ---------------------------------------------------------------- 2
    const junit_path = try h.join(a, &.{ c.work, "junit.xml" });
    var timer = try std.time.Timer.start();
    const res = try c.mopm2(&.{ "test", "--prefix", prefix, "--timeout", "6", "--memory", "512", "--format", "json", "--junit", junit_path }, "run");
    std.debug.print("     mopm test took {d} s (builds included); stderr:\n{s}\n", .{ timer.read() / std.time.ns_per_s, c.plain(res.err) });
    rep.check("mopm test on the fixtures: exit 1 (tests did not pass, everything built)", !res.signaled and res.code == 1, try h.fmt(a, "exit {d}, want 1; stdout:\n{s}", .{ res.code, res.out }));
    const junit = try h.readFile(a, junit_path);
    var chk = r.Chk{ .a = a };
    try checkRun(&chk, res.out, junit, c.pkg);
    rep.check(try h.fmt(a, "every verdict, JSON field and JUnit count is the expected one ({d} checks)", .{chk.checks}), chk.failures == 0, try h.fmt(a, "{d} check(s) failed (above); the JSON:\n{s}", .{ chk.failures, res.out }));

    // ---------------------------------------------------------------- 3
    const Mut = struct { label: []const u8, marker: []const u8, from: []const u8, to: []const u8 };
    for ([_]Mut{
        .{ .label = "a crash reported as a failure", .marker = "\"name\": \"test_segfault\"", .from = "\"status\": \"crash\"", .to = "\"status\": \"fail\"" },
        .{ .label = "a hung test reported as slow", .marker = "\"name\": \"test_hang\"", .from = "\"timeout\": \"hung\"", .to = "\"timeout\": \"slow\"" },
        .{ .label = "a slow test that passed reported as a timeout", .marker = "\"name\": \"test_slow_ok\"", .from = "\"status\": \"pass\"", .to = "\"status\": \"timeout\"" },
        .{ .label = "the wrong signal", .marker = "\"name\": \"test_abort\"", .from = "\"signal_name\": \"SIGABRT\"", .to = "\"signal_name\": \"SIGILL\"" },
        .{ .label = "an early exit reported as a pass", .marker = "\"name\": \"test_exits_early\"", .from = "\"status\": \"fail\"", .to = "\"status\": \"pass\"" },
    }) |mu| {
        try c.mutant(mu.label, res.out, junit, try r.editLines(a, res.out, mu.marker, mu.from, mu.to), null);
    }
    try c.mutant("a wrong JUnit count", res.out, junit, null, try r.editAll(a, junit, "failures=\"3\"", "failures=\"2\""));

    // ---------------------------------------------------------------- 4
    {
        std.time.sleep(1 * std.time.ns_per_s);
        const left = try survivors(a);
        rep.check("no 'sleep 7919' left behind: the deadline kill took the hung test's whole process group", left.len == 0, try h.fmt(a, "{d} 'sleep 7919' process(es) survived the run", .{left.len}));
        killAll(left);
        const bins = try h.findFiles(a, try h.join(a, &.{ c.pkg, "target/mopm/bin" }), "test_native");
        var named = false;
        if (bins.len == 1) {
            const d = try mojo_env.dynamic(a, try h.fmt(a, "{s}/target/mopm/bin/{s}", .{ c.pkg, bins[0] }));
            named = d.needs(libgreet);
        }
        rep.check("the native test's binary names libgreet", named, "no single test_native binary, or it does not name libgreet");
    }

    // ---------------------------------------------------------------- 5
    {
        const nocap = try c.mopm2(&.{ "test", "--prefix", prefix, "--memory", "0", "--timeout", nocap_deadline_s, "tests/test_memory.mojo" }, "nocap");
        const ok = !nocap.signaled and nocap.code == 1 and
            h.hasLineMatching(nocap.out, "TIMEOUT", "tests/test_memory.mojo::test_oom (", "ms): hung at the " ++ nocap_deadline_s ++ " s deadline") and
            h.hasLinePrefix(nocap.out, "---- tests/test_memory.mojo::test_oom: TIMEOUT") and
            h.hasLine(nocap.out, "mopm test: 1 tests: 0 passed, 0 failed, 0 crashed, 1 timed out, 0 out of memory, 0 not built, 0 flaky, 0 ignored");
        rep.check("human output: with --memory 0 the same test is TIMEOUT hung (so the OOM came from the cap)", ok, try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ nocap.code, c.plain(nocap.out), c.plain(nocap.err) }));
        const self = try c.mopm2(&.{ "test", "--prefix", prefix, "tests/test_self_hosted.mojo" }, "self");
        const ok2 = !self.signaled and self.code == 0 and
            h.hasLineMatching(self.out, "PASS", "tests/test_self_hosted.mojo::test_registered_pass (", "ms)") and
            h.hasLineBetween(self.out, "PASS ", "ms)") and
            h.hasLinePrefix(self.out, "mopm test: 1 tests: 1 passed, 0 failed");
        rep.check("human output: a self-hosted file that passes, exit 0", ok2, try h.fmt(a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ self.code, c.plain(self.out), c.plain(self.err) }));
    }

    // ---------------------------------------------------------------- 6
    {
        const nk = try c.mopm2(&.{ "test", "--prefix", prefix, "--timeout", "6", "--memory", "512", "--test-only-no-group-kill", "tests/test_verdicts.mojo" }, "nokill");
        std.time.sleep(500 * std.time.ns_per_ms);
        const left = try survivors(a);
        const ok = !nk.signaled and nk.code == 5 and left.len > 0 and
            h.hasLineBetween(nk.err, "mopm test: tests/test_verdicts.mojo::test_hang: process group ", " still has processes after the test ended");
        rep.check("self-test: without the group kill the 'sleep 7919' survives, and mopm reports it and exits 5", ok, try h.fmt(a, "exit {d} (want 5); {d} survivor(s); stdout:\n{s}stderr:\n{s}", .{ nk.code, left.len, c.plain(nk.out), c.plain(nk.err) }));
        killAll(left);
        const ok2 = h.hasLineMatching(nk.out, "TIMEOUT", "tests/test_verdicts.mojo::test_hang (", "") and
            h.hasLineMatching(nk.out, "CRASH", "tests/test_verdicts.mojo::test_segfault (", "");
        rep.check("self-test run: the verdicts are unchanged", ok2, c.plain(nk.out));
    }
}
