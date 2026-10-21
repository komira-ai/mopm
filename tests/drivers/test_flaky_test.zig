//! The port of the former tests/e2e/test_flaky.sh and check_flaky.py in Zig, for the build farm (no
//! shell, no Python): `mopm test --retries`, `--deny-flaky` and the name
//! filters against the real Mojo toolchain (komira's pinned 1.0.0). They replace
//! tests/e2e/test_flaky.sh and check_flaky.py (deleted); the check is //:flaky.
//!
//! tests/e2e/flaky is a package. Its tests/test_flaky.mojo tests count their
//! own attempts in target/flaky-state/ under the directory mopm test runs in
//! (see the file), so each fails on its first attempt(s) and passes after:
//! deterministic in a fresh state directory, which `fresh` makes before every
//! run. tests/test_names.mojo and tests/sub/test_more.mojo hold passing tests
//! with names the filters select (test_alpha_one is in both).
//!
//!   1. --retries 2 on test_flaky.mojo, JSON and JUnit: exit 1 (one test
//!      fails every attempt); every verdict, every attempt and the JUnit
//!      flaky/rerun elements are checked. Then the checker itself must reject
//!      copies of the results with one verdict or attempt changed.
//!   2. The same two flaky tests (`-- once`) with no --retries: FAIL and
//!      CRASH, exit 1. So the fixtures do fail first, and with --retries 0
//!      (the default) nothing is retried.
//!   3. --retries 2 -- once: both FLAKY, exit 0 and a warning on stderr.
//!   4. The same plus --deny-flaky: exit 1. Same inputs as 3; only the flag
//!      differs, so the flag is what fails the run.
//!   5. --retries 1 -- test_fails_twice: FAIL after two attempts.
//!   6. --ignored on the package: only the ignored test runs (and fails).
//!   7. --exact with two ids, in a fresh copy: exactly those two tests run,
//!      and only their two files are built.

const std = @import("std");
const h = @import("harness.zig");
const r = @import("results.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

test {
    std.testing.refAllDecls(r);
}

const F = "tests/test_flaky.mojo";
const N = "tests/test_names.mojo";
const M = "tests/sub/test_more.mojo";
const ISSUE = "https://github.com/komira-ai/mopm/blob/main/docs/mopm-test.md";

const Retry = struct { id: []const u8, status: []const u8, attempts: []const []const u8 };
const retries = [_]Retry{
    .{ .id = F ++ "::test_steady", .status = "pass", .attempts = &.{"pass"} },
    .{ .id = F ++ "::test_fails_once", .status = "flaky", .attempts = &.{ "fail", "pass" } },
    .{ .id = F ++ "::test_crashes_once", .status = "flaky", .attempts = &.{ "crash", "pass" } },
    .{ .id = F ++ "::test_fails_twice", .status = "flaky", .attempts = &.{ "fail", "fail", "pass" } },
    .{ .id = F ++ "::test_always_fails", .status = "fail", .attempts = &.{ "fail", "fail", "fail" } },
    .{ .id = F ++ "::test_ignored_fails", .status = "skip", .attempts = &.{} },
};

const Junit = struct { id: []const u8, kids: []const [2]?[]const u8 };
const junit_want = [_]Junit{
    .{ .id = F ++ "::test_steady", .kids = &.{} },
    .{ .id = F ++ "::test_fails_once", .kids = &.{.{ "flakyFailure", "FAIL" }} },
    .{ .id = F ++ "::test_crashes_once", .kids = &.{.{ "flakyError", "CRASH" }} },
    .{ .id = F ++ "::test_fails_twice", .kids = &.{ .{ "flakyFailure", "FAIL" }, .{ "flakyFailure", "FAIL" } } },
    .{ .id = F ++ "::test_always_fails", .kids = &.{ .{ "failure", "FAIL" }, .{ "rerunFailure", "FAIL" }, .{ "rerunFailure", "FAIL" } } },
    .{ .id = F ++ "::test_ignored_fails", .kids = &.{.{ "skipped", null }} },
};

const test_keys = [_][]const u8{
    "id",             "file",   "name",        "status",             "ms",            "cpu_ms",
    "peak_rss_bytes", "exit_code", "signal",   "signal_name",        "timeout",       "leftover_processes",
    "message",        "stdout", "stderr",      "ignore",             "binary_sha256", "attempts",
};
const attempt_keys = [_][]const u8{
    "status",    "ms",     "cpu_ms",  "peak_rss_bytes", "exit_code", "signal",  "signal_name",
    "timeout",   "leftover_processes", "message", "stdout", "stderr", "attempt",
};

fn upper(a: Allocator, s: []const u8) ![]u8 {
    return std.ascii.allocUpperString(a, s);
}

/// check_flaky.py `retries`.
fn checkRetries(c: *r.Chk, run_json: []const u8, junit_xml: []const u8, pkg: []const u8) !void {
    const a = c.a;
    const doc = try r.parse(a, run_json);
    c.that(r.int(r.field(doc, "exit_code")) == 1, "json: exit_code 1 (test_always_fails; FLAKY alone does not fail without --deny-flaky)", .{});
    const st = r.field(doc, "settings") orelse .null;
    const dn = r.field(st, "deny_flaky");
    c.that(r.int(r.field(st, "retries")) == 2 and dn != null and dn.? == .bool and !dn.?.bool, "json: settings retries 2, deny_flaky false", .{});
    const want_sum = [_]struct { []const u8, i64 }{
        .{ "tests", 6 },  .{ "pass", 1 }, .{ "fail", 1 }, .{ "crash", 0 }, .{ "timeout", 0 }, .{ "oom", 0 },
        .{ "compile_error", 0 }, .{ "flaky", 3 }, .{ "skip", 1 }, .{ "filtered_out", 0 },
    };
    const sm = r.field(doc, "summary") orelse .null;
    var sum_ok = sm == .object and sm.object.count() == want_sum.len;
    for (want_sum) |kv| sum_ok = sum_ok and r.int(r.field(sm, kv[0])) == kv[1];
    c.that(sum_ok, "json: summary", .{});
    const tests = r.array(r.field(doc, "tests"));
    var order_ok = tests.len == retries.len;
    if (order_ok) for (tests, retries) |t, e| {
        order_ok = order_ok and std.mem.eql(u8, r.str(r.field(t, "id")) orelse "", e.id);
    };
    c.that(order_ok, "json: exactly the tests of test_flaky.mojo, in order", .{});

    var shas = std.StringHashMap(void).init(a);
    for (retries) |e| {
        const t = r.testById(tests, e.id) orelse {
            c.that(false, "{s}: missing", .{e.id});
            continue;
        };
        c.that(r.hasExactKeys(t, &test_keys), "{s}: the documented fields", .{e.id});
        const status = r.str(r.field(t, "status")) orelse "";
        c.that(std.mem.eql(u8, status, e.status), "{s}: status {s} (got {s}: {s})", .{ e.id, e.status, status, r.str(r.field(t, "message")) orelse "" });
        const att = r.array(r.field(t, "attempts"));
        var got_ok = att.len == e.attempts.len;
        var num_ok = att.len == e.attempts.len;
        if (got_ok) for (att, e.attempts, 0..) |x, want, k| {
            got_ok = got_ok and std.mem.eql(u8, r.str(r.field(x, "status")) orelse "", want);
            num_ok = num_ok and r.int(r.field(x, "attempt")) == @as(i64, @intCast(k + 1));
        };
        c.that(got_ok, "{s}: the attempts have the expected verdicts", .{e.id});
        c.that(num_ok, "{s}: attempts numbered from 1", .{e.id});
        const msg = r.str(r.field(t, "message")) orelse "";
        if (std.mem.eql(u8, e.status, "skip")) {
            const ig = r.field(t, "ignore") orelse .null;
            c.that(ig == .object and ig.object.count() == 2 and std.mem.eql(u8, r.str(r.field(ig, "reason")) orelse "", "planted: fails when run") and
                std.mem.eql(u8, r.str(r.field(ig, "issue")) orelse "", ISSUE), "{s}: ignore reason and issue", .{e.id});
            c.that(r.isNull(r.field(t, "stdout")) and r.isNull(r.field(t, "binary_sha256")), "{s}: never ran", .{e.id});
            c.that(h.contains(msg, "ignored: planted: fails when run"), "{s}: message says ignored and why", .{e.id});
            continue;
        }
        c.that(r.isNull(r.field(t, "ignore")), "{s}: not ignored", .{e.id});
        if (r.str(r.field(t, "binary_sha256"))) |s| try shas.put(s, {}) else try shas.put("<none>", {});
        var paths = std.StringHashMap(void).init(a);
        for (att, 1..) |x, k| {
            c.that(r.hasExactKeys(x, &attempt_keys), "{s} attempt {d}: the documented fields", .{ e.id, k });
            for ([_][]const u8{ "stdout", "stderr" }) |key| {
                const p = r.str(r.field(x, key));
                c.that(r.fileExists(a, pkg, p), "{s} attempt {d}: output file {s} exists", .{ e.id, k, key });
                if (p) |pp| try paths.put(pp, {});
            }
            if (k > 1) {
                const want = try std.fmt.allocPrint(a, ".attempt{d}.", .{k});
                c.that(h.contains(r.str(r.field(x, "stdout")) orelse "", want), "{s} attempt {d}: its own output file", .{ e.id, k });
            }
            const text = try r.outputOf(a, pkg, x);
            const xs = r.str(r.field(x, "status")) orelse "";
            if (std.mem.eql(u8, xs, "fail")) c.that(h.contains(text, "planted failure"), "{s} attempt {d}: its output holds the planted failure", .{ e.id, k });
            if (std.mem.eql(u8, xs, "crash")) c.that(std.mem.eql(u8, r.str(r.field(x, "signal_name")) orelse "", "SIGABRT") and r.isNull(r.field(x, "exit_code")), "{s} attempt {d}: SIGABRT", .{ e.id, k });
            if (std.mem.eql(u8, xs, "pass")) c.that(r.int(r.field(x, "exit_code")) == 0 and (r.str(r.field(x, "message")) orelse "x").len == 0, "{s} attempt {d}: exit 0, no message", .{ e.id, k });
        }
        c.that(paths.count() == 2 * e.attempts.len, "{s}: every attempt has output files of its own", .{e.id});
        if (att.len > 0) {
            const last = att[att.len - 1];
            var same = true;
            for ([_][]const u8{ "exit_code", "signal", "stdout", "stderr" }) |k| same = same and jsonEql(r.field(t, k), r.field(last, k));
            c.that(same, "{s}: the test's fields are its last attempt's", .{e.id});
        }
        if (e.attempts.len > 1) {
            for (e.attempts, 1..) |s, k| {
                const want = try std.fmt.allocPrint(a, "attempt {d} {s}", .{ k, try upper(a, s) });
                c.that(h.contains(msg, want), "{s}: message names {s} (got {s})", .{ e.id, want, msg });
            }
        }
    }
    var one_sha = shas.count() == 1;
    var it = shas.keyIterator();
    while (it.next()) |k| one_sha = one_sha and k.len == 64;
    c.that(one_sha, "json: one binary, one sha256, for every attempt of every test", .{});

    const root = try r.parseXml(a, junit_xml);
    const at = [_][]const u8{ root.attr("tests") orelse "", root.attr("failures") orelse "", root.attr("errors") orelse "", root.attr("skipped") orelse "" };
    c.that(std.mem.eql(u8, at[0], "6") and std.mem.eql(u8, at[1], "1") and std.mem.eql(u8, at[2], "0") and std.mem.eql(u8, at[3], "1"), "junit: tests=6 failures=1 errors=0 skipped=1 (got {s} {s} {s} {s})", .{ at[0], at[1], at[2], at[3] });
    var cases = std.StringHashMap(*r.Node).init(a);
    for (try r.children(a, root, "testsuite")) |suite| {
        for (try r.children(a, suite, "testcase")) |tc| try cases.put(try std.fmt.allocPrint(a, "{s}::{s}", .{ tc.attr("classname") orelse "", tc.attr("name") orelse "" }), tc);
    }
    var cases_ok = cases.count() == junit_want.len;
    for (junit_want) |w| cases_ok = cases_ok and cases.contains(w.id);
    c.that(cases_ok, "junit: exactly the expected test cases", .{});
    for (junit_want) |w| {
        const tc = cases.get(w.id) orelse continue;
        var kids_ok = tc.kids.len == w.kids.len;
        if (kids_ok) for (tc.kids, w.kids) |k, want| {
            kids_ok = kids_ok and std.mem.eql(u8, k.name, want[0].?);
            if (want[1]) |ty| kids_ok = kids_ok and std.mem.eql(u8, k.attr("type") orelse "", ty) else kids_ok = kids_ok and k.attr("type") == null;
        };
        c.that(kids_ok, "junit: {s} holds the expected elements", .{w.id});
        for (tc.kids) |k| {
            if (std.mem.startsWith(u8, k.name, "flaky") or std.mem.startsWith(u8, k.name, "rerun")) {
                c.that(std.mem.startsWith(u8, k.attr("message") orelse "", "attempt "), "junit: {s} <{s}> names its attempt", .{ w.id, k.name });
            }
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

fn pairs(a: Allocator, tests: []const r.J) ![][2][]const u8 {
    const out = try a.alloc([2][]const u8, tests.len);
    for (tests, 0..) |t, i| out[i] = .{ r.str(r.field(t, "id")) orelse "", r.str(r.field(t, "status")) orelse "" };
    return out;
}

/// check_flaky.py `ignored`.
fn checkIgnored(c: *r.Chk, run_json: []const u8) !void {
    const doc = try r.parse(c.a, run_json);
    const got = try pairs(c.a, r.array(r.field(doc, "tests")));
    c.that(got.len == 1 and std.mem.eql(u8, got[0][0], F ++ "::test_ignored_fails") and std.mem.eql(u8, got[0][1], "fail"), "--ignored: only the ignored test ran, and failed", .{});
    c.that(r.int(r.field(r.field(doc, "summary") orelse .null, "filtered_out")) == 10, "--ignored: the 10 others filtered out", .{});
    c.that(r.int(r.field(doc, "exit_code")) == 1, "--ignored: exit_code 1", .{});
}

/// check_flaky.py `exact`.
fn checkExact(c: *r.Chk, run_json: []const u8) !void {
    const doc = try r.parse(c.a, run_json);
    const got = try pairs(c.a, r.array(r.field(doc, "tests")));
    c.that(got.len == 2 and std.mem.eql(u8, got[0][0], M ++ "::test_gamma") and std.mem.eql(u8, got[0][1], "pass") and
        std.mem.eql(u8, got[1][0], N ++ "::test_alpha_one") and std.mem.eql(u8, got[1][1], "pass"), "--exact: exactly the two named tests ran, and passed", .{});
    c.that(r.int(r.field(r.field(doc, "summary") orelse .null, "filtered_out")) == 9, "--exact: the 9 others filtered out", .{});
    c.that(r.int(r.field(doc, "exit_code")) == 0, "--exact: exit_code 0", .{});
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

    fn mopm2(c: *Ctx, dir: []const u8, args: []const []const u8, tag: []const u8) !Two {
        var env = try c.m.freshEnv();
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        const err_path = try h.fmt(c.a, "{s}/{s}.err", .{ c.work, tag });
        const out_path = try h.fmt(c.a, "{s}/{s}.out", .{ c.work, tag });
        const res = try h.run(c.a, argv, &env, .{ .cwd = dir, .capture = .none, .stdout_path = out_path, .stderr_path = err_path });
        return .{ .code = res.code, .signaled = res.signaled, .out = try h.readFile(c.a, out_path), .err = try h.readFile(c.a, err_path) };
    }

    fn mopmTest(c: *Ctx, tag: []const u8, extra: []const []const u8) !Two {
        var args = std.ArrayList([]const u8).init(c.a);
        try args.appendSlice(&.{ "test", "--prefix", c.prefix });
        try args.appendSlice(extra);
        return c.mopm2(c.pkg, args.items, tag);
    }

    /// A fresh state directory: every fixture test starts again at attempt 1.
    fn fresh(c: *Ctx) !void {
        try std.fs.cwd().deleteTree(try h.join(c.a, &.{ c.pkg, "target/flaky-state" }));
    }

    fn shown(c: *Ctx, t: Two) ![]u8 {
        return h.fmt(c.a, "exit {d}; stdout:\n{s}stderr:\n{s}", .{ t.code, try h.stripAnsi(c.a, t.out), try h.stripAnsi(c.a, t.err) });
    }

    /// `expect` of test_flaky.sh: the exit status and a glob per line.
    fn expect(c: *Ctx, label: []const u8, want: u8, t: Two, globs: []const []const u8) !void {
        var ok = !t.signaled and t.code == want;
        var missing = std.ArrayList(u8).init(c.a);
        for (globs) |g| if (!h.hasLineGlob(t.out, g)) {
            ok = false;
            try missing.writer().print("missing: {s}\n", .{g});
        };
        c.rep.check(label, ok, try h.fmt(c.a, "(want exit {d}) {s}{s}", .{ want, missing.items, try c.shown(t) }));
    }

    fn mutantJson(c: *Ctx, label: []const u8, junit: []const u8, doctored: ?[]const u8) !void {
        if (doctored == null) {
            c.rep.check(try h.fmt(c.a, "checker self-test ({s})", .{label}), false, "the edit changed nothing");
            return;
        }
        var q = r.Chk{ .a = c.a, .quiet = true };
        try checkRetries(&q, doctored.?, junit, c.pkg);
        c.rep.check(try h.fmt(c.a, "checker self-test ({s}): rejected ({d} failed checks)", .{ label, q.failures }), q.failures > 0, "the checker accepted it");
    }

    fn mutantXml(c: *Ctx, label: []const u8, run_json: []const u8, doctored: ?[]const u8) !void {
        if (doctored == null) {
            c.rep.check(try h.fmt(c.a, "checker self-test ({s})", .{label}), false, "the edit changed nothing");
            return;
        }
        var q = r.Chk{ .a = c.a, .quiet = true };
        try checkRetries(&q, run_json, doctored.?, c.pkg);
        c.rep.check(try h.fmt(c.a, "checker self-test ({s}): rejected", .{label}), q.failures > 0, "the checker accepted it");
    }
};

test "flaky: mopm test --retries, --deny-flaky and filters against the real mojo (tests/e2e/test_flaky.sh)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    try h.watchdog(1500);
    var rep = h.Report{};
    try run(a, &rep);
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    const prefix = try h.join(a, &.{ m.work, "env" });
    try m.prefix(prefix, true);
    var c = Ctx{
        .a = a,
        .rep = rep,
        .m = m,
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .prefix = prefix,
        .work = try h.join(a, &.{ m.work, "out" }),
        .pkg = try h.join(a, &.{ m.work, "tests/e2e/flaky" }),
    };
    try std.fs.cwd().makePath(c.work);
    const v = try m.run(prefix, &.{"--version"}, null);
    std.debug.print("== mojo: {s}", .{v.text});

    // ---------------------------------------------------------------- 1
    try c.fresh();
    const junit_path = try h.join(a, &.{ c.work, "r1.xml" });
    const r1 = try c.mopmTest("r1", &.{ "--retries", "2", "--format", "json", "--junit", junit_path, F });
    std.debug.print("     stderr:\n{s}\n", .{try h.stripAnsi(a, r1.err)});
    rep.check("--retries 2: exit 1 (test_always_fails)", !r1.signaled and r1.code == 1, try c.shown(r1));
    const junit = try h.readFile(a, junit_path);
    var chk = r.Chk{ .a = a };
    try checkRetries(&chk, r1.out, junit, c.pkg);
    rep.check(try h.fmt(a, "--retries 2: every verdict, attempt and JUnit element is the expected one ({d} checks)", .{chk.checks}), chk.failures == 0, try h.fmt(a, "{d} check(s) failed (above); the JSON:\n{s}", .{ chk.failures, r1.out }));
    rep.check("--retries 2: the FLAKY warning on stderr", h.hasLinePrefix(r1.err, "mopm test: warning: 3 FLAKY test(s)"), r1.err);

    try c.mutantJson("a flaky test reported as PASS", junit, try r.editLines(a, r1.out, "\"name\": \"test_fails_once\"", "\"status\": \"flaky\"", "\"status\": \"pass\""));
    try c.mutantJson("a test failing every attempt reported as FLAKY", junit, try r.editLines(a, r1.out, "\"name\": \"test_always_fails\"", "\"status\": \"fail\"", "\"status\": \"flaky\""));
    try c.mutantJson("a failed attempt recorded as passed", junit, try r.editLines(a, r1.out, "\"name\": \"test_fails_twice\"", "\"attempt\": 2, \"status\": \"fail\"", "\"attempt\": 2, \"status\": \"pass\""));
    try c.mutantJson("the first attempt's crash recorded as a failure", junit, try r.editLines(a, r1.out, "\"name\": \"test_crashes_once\"", "\"attempt\": 1, \"status\": \"crash\"", "\"attempt\": 1, \"status\": \"fail\""));
    try c.mutantJson("the ignored test reported as run", junit, try r.editLines(a, r1.out, "\"name\": \"test_ignored_fails\"", "\"status\": \"skip\"", "\"status\": \"pass\""));
    try c.mutantJson("a retry dropped from the attempts", junit, try r.editSpan(a, r1.out, "\"name\": \"test_always_fails\"", ", {\"attempt\": 3, ", "}]", "]"));
    {
        const step1 = try r.editEvery(a, junit, "<flakyError type=\"CRASH\"", "<flakyFailure type=\"CRASH\"");
        const both = if (step1) |s| try r.editEvery(a, s, "</flakyError>", "</flakyFailure>") else null;
        try c.mutantXml("JUnit: a flaky crash recorded as a flaky failure", r1.out, both);
        try c.mutantXml("JUnit: the skipped count", r1.out, try r.editAll(a, junit, "skipped=\"1\"", "skipped=\"0\""));
    }

    // ---------------------------------------------------------------- 2
    try c.fresh();
    const r2 = try c.mopmTest("r2", &.{ F, "--", "once" });
    try c.expect("no --retries: the same two tests are FAIL and CRASH, never retried", 1, r2, &.{
        "FAIL~" ++ F ++ "::test_fails_once (# ms): exit status #",
        "CRASH~" ++ F ++ "::test_crashes_once (# ms): killed by SIGABRT*",
        "mopm test: 2 tests: 0 passed, 1 failed, 1 crashed, 0 timed out, 0 out of memory, 0 not built, 0 flaky, 0 ignored; 4 filtered out",
    });
    {
        const x1 = try h.readFile(a, try h.join(a, &.{ c.pkg, "target/flaky-state/test_fails_once" }));
        const x2 = try h.readFile(a, try h.join(a, &.{ c.pkg, "target/flaky-state/test_crashes_once" }));
        rep.check("no --retries: each test ran exactly once", std.mem.eql(u8, x1, "x") and std.mem.eql(u8, x2, "x"), try h.fmt(a, "attempts recorded: {s} {s}", .{ x1, x2 }));
    }

    // ---------------------------------------------------------------- 3
    try c.fresh();
    const r3 = try c.mopmTest("r3", &.{ "--retries", "2", F, "--", "once" });
    try c.expect("--retries 2 -- once: both FLAKY, exit 0", 0, r3, &.{
        "FLAKY~" ++ F ++ "::test_fails_once (# ms): attempt 1 FAIL (exit status #), attempt 2 PASS",
        "FLAKY~" ++ F ++ "::test_crashes_once (# ms): attempt 1 CRASH (killed by SIGABRT (signal 6)), attempt 2 PASS",
        "---- " ++ F ++ "::test_fails_once: FLAKY: *",
        "  attempt 1: FAIL: exit status #",
        "mopm test: 2 tests: 0 passed, 0 failed, 0 crashed, 0 timed out, 0 out of memory, 0 not built, 2 flaky, 0 ignored; 4 filtered out",
    });
    rep.check("--retries 2 -- once: the FLAKY warning", h.hasLine(r3.err, "mopm test: warning: 2 FLAKY test(s): each failed and then passed, same binary and argv; the run still passes (--deny-flaky fails it)"), r3.err);

    // ---------------------------------------------------------------- 4
    try c.fresh();
    const r4 = try c.mopmTest("r4", &.{ "--retries", "2", "--deny-flaky", F, "--", "once" });
    try c.expect("--deny-flaky: the same run is red, exit 1", 1, r4, &.{
        "FLAKY~" ++ F ++ "::test_fails_once (*",
        "FLAKY~" ++ F ++ "::test_crashes_once (*",
    });
    rep.check("--deny-flaky: says why the run failed", h.hasLine(r4.err, "mopm test: 2 FLAKY test(s): each failed and then passed, same binary and argv; --deny-flaky fails the run"), r4.err);

    // ---------------------------------------------------------------- 5
    try c.fresh();
    const r5 = try c.mopmTest("r5", &.{ "--retries", "1", F, "--", "test_fails_twice" });
    try c.expect("--retries 1: two attempts, both FAIL", 1, r5, &.{
        "FAIL~" ++ F ++ "::test_fails_twice (# ms): attempt 1 FAIL (exit status #), attempt 2 FAIL (exit status #)",
    });

    // ---------------------------------------------------------------- 6
    try c.fresh();
    {
        const r6 = try c.mopmTest("r6", &.{ "--ignored", "--format", "json" });
        var q = r.Chk{ .a = a };
        try checkIgnored(&q, r6.out);
        rep.check("--ignored: only the ignored test ran", !r6.signaled and r6.code == 1 and q.failures == 0, try c.shown(r6));
    }

    // ---------------------------------------------------------------- 7
    {
        const exact = try h.join(a, &.{ m.work, "exact" });
        try h.copyTree(a, c.pkg, exact);
        // The copy is made from the package as staged, which has run before:
        // start from a clean target directory, as the shell test's fresh copy.
        try std.fs.cwd().deleteTree(try h.join(a, &.{ exact, "target" }));
        const r7 = try c.mopm2(exact, &.{ "test", "--prefix", prefix, "--format", "json", "--exact", "--", N ++ "::test_alpha_one", M ++ "::test_gamma" }, "r7");
        var q = r.Chk{ .a = a };
        try checkExact(&q, r7.out);
        rep.check("--exact: exactly the two named tests ran", !r7.signaled and r7.code == 0 and q.failures == 0, try c.shown(r7));
        const bins = try h.findFilesAll(a, try h.join(a, &.{ exact, "target/mopm/bin" }));
        h.sortStrings(bins);
        rep.check("--exact: only the two files with a selected test were built", bins.len == 2 and std.mem.eql(u8, bins[0], "test_more") and std.mem.eql(u8, bins[1], "test_names"), try std.mem.join(a, " ", bins));
    }
}
