//! Verdicts and reports of `mopm test`: what a finished test process means,
//! and the three ways the results are written (a human summary, one JSON
//! document, JUnit XML). The JSON schema and the verdict rules are
//! documented in docs/mopm-test.md; a change to either is a schema change.
//!
//! Verdict of one test process (`classify`), first rule that applies:
//!   OOM      mopm killed it: its resident size passed the memory cap;
//!   TIMEOUT  mopm killed it at the deadline (hung: no CPU over the last
//!            window; slow: still computing; unknown: CPU not readable);
//!   CRASH    it died by a signal (the signal is reported);
//!   FAIL     it exited non-zero, or exited 0 without printing the
//!            TestSuite's `PASS [ <time> ] <name>` line for its test (a
//!            test that ends the process early has not passed);
//!   PASS     it exited 0 and printed that line.
//! A test of a file that did not build is COMPILE-ERROR; a test marked
//! `# mopm: ignore` that was not asked for is SKIP.
//!
//! With `--retries N` a test that did not pass runs again, up to N more
//! times, the same binary with the same argv. Its verdict (`finalStatus`)
//! is that of its last attempt, except that a test that did not pass and
//! then passed is FLAKY, never PASS: flaky means the same inputs both
//! passed and failed. Every attempt is reported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_proc = @import("test_proc.zig");
const test_harness = @import("test_harness.zig");
const test_scan = @import("test_scan.zig");

pub const Status = enum {
    pass,
    fail,
    crash,
    timeout,
    oom,
    compile_error,
    flaky,
    skip,

    /// The JSON spelling.
    pub fn json(s: Status) []const u8 {
        return switch (s) {
            .compile_error => "compile-error",
            else => @tagName(s),
        };
    }

    /// The human and JUnit spelling.
    pub fn label(s: Status) []const u8 {
        return switch (s) {
            .pass => "PASS",
            .fail => "FAIL",
            .crash => "CRASH",
            .timeout => "TIMEOUT",
            .oom => "OOM",
            .compile_error => "COMPILE-ERROR",
            .flaky => "FLAKY",
            .skip => "SKIP",
        };
    }

    /// A verdict that makes the run fail on its own: everything but PASS,
    /// FLAKY (that one fails the run only with --deny-flaky) and SKIP.
    pub fn failsRun(s: Status) bool {
        return switch (s) {
            .pass, .flaky, .skip => false,
            else => true,
        };
    }
};

/// One run of a test process.
pub const Attempt = struct {
    status: Status,
    message: []const u8 = "",
    wall_ns: u64 = 0,
    cpu_ns: ?u64 = null,
    peak_rss: ?u64 = null,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    timeout: ?test_proc.Liveness = null,
    leftover: bool = false,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
};

/// Whether a test that got `status` on attempt number `attempt` (1-based)
/// runs again under `--retries retries`.
pub fn retryAfter(status: Status, attempt: u32, retries: u32) bool {
    return status != .pass and attempt <= retries;
}

/// The verdict of a test from its attempts, in order (at least one): the
/// last attempt's, except FLAKY when an attempt did not pass and the last
/// one passed.
pub fn finalStatus(attempts: []const Attempt) Status {
    const last = attempts[attempts.len - 1].status;
    if (last == .pass and attempts.len > 1) return .flaky;
    return last;
}

/// The one-line reason of a test with several attempts:
/// `attempt 1 FAIL (exit status 1), attempt 2 PASS`.
pub fn attemptsMessage(arena: Allocator, attempts: []const Attempt) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (attempts, 1..) |at, k| {
        if (k > 1) try out.appendSlice(", ");
        try out.writer().print("attempt {d} {s}", .{ k, at.status.label() });
        if (at.message.len > 0) try out.writer().print(" ({s})", .{at.message});
    }
    return out.items;
}

pub const Outcome = struct {
    /// `<file>::<name>`.
    id: []const u8,
    file: []const u8,
    name: []const u8,
    status: Status,
    /// One line saying why, empty for PASS.
    message: []const u8 = "",
    wall_ns: u64 = 0,
    cpu_ns: ?u64 = null,
    peak_rss: ?u64 = null,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    timeout: ?test_proc.Liveness = null,
    /// The process group outlived the test (a supervisor failure).
    leftover: bool = false,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
    /// Every attempt, in order; empty when the test did not run (SKIP,
    /// COMPILE-ERROR). The fields above are those of the last attempt.
    attempts: []const Attempt = &.{},
    /// `# mopm: ignore`.
    ignore: ?test_scan.Ignore = null,
    /// sha256 of the binary every attempt ran, or null when none ran.
    binary_sha256: ?[]const u8 = null,
};

/// Whether TestSuite output says test `name` passed: a line `PASS [ t ]
/// <name>` once ANSI colour codes are removed.
pub fn sawPass(arena: Allocator, output: []const u8, name: []const u8) Allocator.Error!bool {
    const text = try test_harness.stripAnsi(arena, output);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, l, "PASS [")) continue;
        const close = std.mem.indexOfScalar(u8, l, ']') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, l[close + 1 ..], " \t"), name)) return true;
    }
    return false;
}

pub const Verdict = struct { status: Status, message: []const u8 };

pub fn classify(arena: Allocator, r: test_proc.Result, deadline_ns: u64, memory_cap: ?u64, saw_pass: bool) Allocator.Error!Verdict {
    if (r.oom) return .{ .status = .oom, .message = try std.fmt.allocPrint(arena, "resident size passed the memory cap of {d} MiB (--memory)", .{(memory_cap orelse 0) >> 20}) };
    if (r.timeout) |l| return .{ .status = .timeout, .message = try std.fmt.allocPrint(arena, "{s} at the {d} s deadline (--timeout): {s}", .{
        @tagName(l),
        deadline_ns / std.time.ns_per_s,
        switch (l) {
            .hung => "no CPU used over the last window",
            .slow => "still computing",
            .unknown => "CPU use could not be read",
        },
    }) };
    switch (r.term) {
        .signaled => |sig| return .{ .status = .crash, .message = try std.fmt.allocPrint(arena, "killed by {s} (signal {d})", .{ test_proc.signalName(sig) orelse "a signal", sig }) },
        .exited => |code| {
            if (code != 0) return .{ .status = .fail, .message = try std.fmt.allocPrint(arena, "exit status {d}", .{code}) };
            if (!saw_pass) return .{ .status = .fail, .message = "exit status 0 but no PASS line for the test: the process ended before the test finished" };
            return .{ .status = .pass, .message = "" };
        },
    }
}

pub const Counts = struct {
    total: usize = 0,
    pass: usize = 0,
    fail: usize = 0,
    crash: usize = 0,
    timeout: usize = 0,
    oom: usize = 0,
    compile_error: usize = 0,
    flaky: usize = 0,
    skip: usize = 0,

    pub fn of(outcomes: []const Outcome) Counts {
        var c = Counts{};
        for (outcomes) |o| {
            c.total += 1;
            switch (o.status) {
                inline else => |s| @field(c, @tagName(s)) += 1,
            }
        }
        return c;
    }
};

pub const Settings = struct {
    deadline_ns: u64,
    memory_cap: ?u64,
    /// "rss-sampled" or "none".
    memory_enforcement: []const u8,
    opt_level: u8,
    exit_code: u8,
    retries: u32 = 0,
    deny_flaky: bool = false,
    /// Tests the name filters (or --ignored) left out; not in `tests`.
    filtered_out: usize = 0,
};

// ---------------------------------------------------------------- JSON

pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn optStr(w: anytype, s: ?[]const u8) !void {
    if (s) |v| try writeJsonString(w, v) else try w.writeAll("null");
}

fn optInt(w: anytype, v: anytype) !void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

/// The fields a test and each of its attempts share, from "ms" to "stderr".
fn writeRunFields(w: anytype, a: Attempt) !void {
    try w.print("\"ms\": {d}, \"cpu_ms\": ", .{a.wall_ns / std.time.ns_per_ms});
    try optInt(w, if (a.cpu_ns) |n| n / std.time.ns_per_ms else null);
    try w.writeAll(", \"peak_rss_bytes\": ");
    try optInt(w, a.peak_rss);
    try w.writeAll(", \"exit_code\": ");
    try optInt(w, a.exit_code);
    try w.writeAll(", \"signal\": ");
    try optInt(w, a.signal);
    try w.writeAll(", \"signal_name\": ");
    try optStr(w, if (a.signal) |s| test_proc.signalName(s) else null);
    try w.writeAll(", \"timeout\": ");
    try optStr(w, if (a.timeout) |l| @tagName(l) else null);
    try w.print(", \"leftover_processes\": {}", .{a.leftover});
    try w.writeAll(", \"message\": ");
    try writeJsonString(w, a.message);
    try w.writeAll(", \"stdout\": ");
    try optStr(w, a.stdout_path);
    try w.writeAll(", \"stderr\": ");
    try optStr(w, a.stderr_path);
}

/// The `--format json` document (schema 1, docs/mopm-test.md).
pub fn writeJson(w: anytype, settings: Settings, outcomes: []const Outcome) !void {
    const c = Counts.of(outcomes);
    try w.writeAll("{\n  \"schema\": 1,\n");
    try w.print("  \"exit_code\": {d},\n", .{settings.exit_code});
    try w.print("  \"settings\": {{\"timeout_ms\": {d}, \"memory_cap_bytes\": ", .{settings.deadline_ns / std.time.ns_per_ms});
    try optInt(w, settings.memory_cap);
    try w.writeAll(", \"memory_enforcement\": ");
    try writeJsonString(w, settings.memory_enforcement);
    try w.print(", \"opt_level\": {d}, \"assert\": \"all\", \"retries\": {d}, \"deny_flaky\": {}}},\n", .{ settings.opt_level, settings.retries, settings.deny_flaky });
    try w.print("  \"summary\": {{\"tests\": {d}, \"pass\": {d}, \"fail\": {d}, \"crash\": {d}, \"timeout\": {d}, \"oom\": {d}, \"compile_error\": {d}, \"flaky\": {d}, \"skip\": {d}, \"filtered_out\": {d}}},\n", .{ c.total, c.pass, c.fail, c.crash, c.timeout, c.oom, c.compile_error, c.flaky, c.skip, settings.filtered_out });
    try w.writeAll("  \"tests\": [");
    for (outcomes, 0..) |o, i| {
        try w.writeAll(if (i == 0) "\n    {" else ",\n    {");
        try w.writeAll("\"id\": ");
        try writeJsonString(w, o.id);
        try w.writeAll(", \"file\": ");
        try writeJsonString(w, o.file);
        try w.writeAll(", \"name\": ");
        try writeJsonString(w, o.name);
        try w.print(", \"status\": \"{s}\", ", .{o.status.json()});
        try writeRunFields(w, .{
            .status = o.status,
            .message = o.message,
            .wall_ns = o.wall_ns,
            .cpu_ns = o.cpu_ns,
            .peak_rss = o.peak_rss,
            .exit_code = o.exit_code,
            .signal = o.signal,
            .timeout = o.timeout,
            .leftover = o.leftover,
            .stdout_path = o.stdout_path,
            .stderr_path = o.stderr_path,
        });
        try w.writeAll(", \"ignore\": ");
        if (o.ignore) |ig| {
            try w.writeAll("{\"reason\": ");
            try writeJsonString(w, ig.reason);
            try w.writeAll(", \"issue\": ");
            try writeJsonString(w, ig.issue);
            try w.writeByte('}');
        } else try w.writeAll("null");
        try w.writeAll(", \"binary_sha256\": ");
        try optStr(w, o.binary_sha256);
        try w.writeAll(", \"attempts\": [");
        for (o.attempts, 1..) |at, k| {
            if (k > 1) try w.writeAll(", ");
            try w.print("{{\"attempt\": {d}, \"status\": \"{s}\", ", .{ k, at.status.json() });
            try writeRunFields(w, at);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll(if (outcomes.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

// ---------------------------------------------------------------- JUnit

/// XML character data: escaped, and without the characters XML 1.0 cannot
/// hold at all (control characters other than tab, newline, return).
pub fn writeXmlText(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        '\t', '\n', '\r' => try w.writeByte(c),
        0...8, 11, 12, 14...0x1f => {},
        else => try w.writeByte(c),
    };
}

fn seconds(w: anytype, ns: u64) !void {
    try w.print("{d}.{d:0>3}", .{ ns / std.time.ns_per_s, (ns % std.time.ns_per_s) / std.time.ns_per_ms });
}

/// The last attempt of a test as an Attempt (also for a test that never
/// ran: its status and message).
pub fn lastRun(o: Outcome) Attempt {
    return .{
        .status = o.status,
        .message = o.message,
        .wall_ns = o.wall_ns,
        .cpu_ns = o.cpu_ns,
        .peak_rss = o.peak_rss,
        .exit_code = o.exit_code,
        .signal = o.signal,
        .timeout = o.timeout,
        .leftover = o.leftover,
        .stdout_path = o.stdout_path,
        .stderr_path = o.stderr_path,
    };
}

fn junitCounts(c: Counts) struct { failures: usize, errors: usize } {
    return .{ .failures = c.fail, .errors = c.crash + c.timeout + c.oom + c.compile_error };
}

/// One JUnit element for one attempt that did not pass.
fn junitElement(arena: Allocator, w: anytype, elem: []const u8, at: Attempt, label: []const u8, details: *const fn (Allocator, Attempt) []const u8) !void {
    try w.print("      <{s} type=\"{s}\" message=\"", .{ elem, at.status.label() });
    try writeXmlText(w, label);
    try writeXmlText(w, at.message);
    try w.writeAll("\">");
    try writeXmlText(w, details(arena, at));
    try w.print("</{s}>\n", .{elem});
}

/// JUnit XML: one <testsuite> per test file, in the order of `outcomes`
/// (which is grouped by file). FAIL is a <failure>; CRASH, TIMEOUT, OOM and
/// COMPILE-ERROR are an <error> whose type is the verdict; SKIP is
/// <skipped>. With retries, the attempts other than the last are recorded
/// as Maven Surefire records reruns: in a test that did not pass, each
/// earlier attempt is a <rerunFailure> (FAIL) or <rerunError> (the rest);
/// a FLAKY test counts as passed and holds a <flakyFailure> or
/// <flakyError> per attempt that did not pass. `details(a)` gives an
/// element's text (the attempt's output tail).
pub fn writeJunit(arena: Allocator, w: anytype, outcomes: []const Outcome, details: *const fn (Allocator, Attempt) []const u8) !void {
    const c = Counts.of(outcomes);
    const jc = junitCounts(c);
    var total_ns: u64 = 0;
    for (outcomes) |o| total_ns += o.wall_ns;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print("<testsuites name=\"mopm test\" tests=\"{d}\" failures=\"{d}\" errors=\"{d}\" skipped=\"{d}\" time=\"", .{ c.total, jc.failures, jc.errors, c.skip });
    try seconds(w, total_ns);
    try w.writeAll("\">\n");
    var i: usize = 0;
    while (i < outcomes.len) {
        var j = i;
        while (j < outcomes.len and std.mem.eql(u8, outcomes[j].file, outcomes[i].file)) j += 1;
        const group = outcomes[i..j];
        const gc = Counts.of(group);
        const gjc = junitCounts(gc);
        var ns: u64 = 0;
        for (group) |o| ns += o.wall_ns;
        try w.writeAll("  <testsuite name=\"");
        try writeXmlText(w, group[0].file);
        try w.print("\" tests=\"{d}\" failures=\"{d}\" errors=\"{d}\" skipped=\"{d}\" time=\"", .{ gc.total, gjc.failures, gjc.errors, gc.skip });
        try seconds(w, ns);
        try w.writeAll("\">\n");
        for (group) |o| {
            try w.writeAll("    <testcase classname=\"");
            try writeXmlText(w, o.file);
            try w.writeAll("\" name=\"");
            try writeXmlText(w, o.name);
            try w.writeAll("\" time=\"");
            try seconds(w, o.wall_ns);
            if (o.status == .pass) {
                try w.writeAll("\"/>\n");
                continue;
            }
            try w.writeAll("\">\n");
            switch (o.status) {
                .skip => {
                    try w.writeAll("      <skipped message=\"");
                    try writeXmlText(w, o.message);
                    try w.writeAll("\"/>\n");
                },
                .flaky => {
                    for (o.attempts, 1..) |at, k| {
                        if (at.status == .pass) continue;
                        const label = try std.fmt.allocPrint(arena, "attempt {d}: ", .{k});
                        try junitElement(arena, w, if (at.status == .fail) "flakyFailure" else "flakyError", at, label, details);
                    }
                },
                else => {
                    try junitElement(arena, w, if (o.status == .fail) "failure" else "error", lastRun(o), "", details);
                    if (o.attempts.len > 1) {
                        for (o.attempts[0 .. o.attempts.len - 1], 1..) |at, k| {
                            const label = try std.fmt.allocPrint(arena, "attempt {d}: ", .{k});
                            try junitElement(arena, w, if (at.status == .fail) "rerunFailure" else "rerunError", at, label, details);
                        }
                    }
                },
            }
            try w.writeAll("    </testcase>\n");
        }
        try w.writeAll("  </testsuite>\n");
        i = j;
    }
    try w.writeAll("</testsuites>\n");
}

// ---------------------------------------------------------------- human

/// One line per test: `<VERDICT> <id> (<ms> ms)[: <message>]`.
pub fn writeLine(w: anytype, o: Outcome) !void {
    try w.print("{s: <13} {s} ({d} ms)", .{ o.status.label(), o.id, o.wall_ns / std.time.ns_per_ms });
    if (o.message.len > 0) try w.print(": {s}", .{o.message});
    try w.writeByte('\n');
}

pub fn writeSummary(w: anytype, outcomes: []const Outcome, filtered_out: usize) !void {
    const c = Counts.of(outcomes);
    try w.print("mopm test: {d} tests: {d} passed, {d} failed, {d} crashed, {d} timed out, {d} out of memory, {d} not built, {d} flaky, {d} ignored", .{ c.total, c.pass, c.fail, c.crash, c.timeout, c.oom, c.compile_error, c.flaky, c.skip });
    if (filtered_out > 0) try w.print("; {d} filtered out", .{filtered_out});
    try w.writeByte('\n');
}

// ---------------------------------------------------------------- tests

fn res(term: test_proc.Term) test_proc.Result {
    return .{ .term = term, .wall_ns = 0, .cpu_ns = 0, .peak_rss = null, .pgid = 1 };
}

test "classify: each rule, in order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const d = 6 * std.time.ns_per_s;
    try std.testing.expectEqual(Status.pass, (try classify(a, res(.{ .exited = 0 }), d, null, true)).status);
    // Exit 0 without the PASS line: the test did not finish.
    try std.testing.expectEqual(Status.fail, (try classify(a, res(.{ .exited = 0 }), d, null, false)).status);
    try std.testing.expectEqual(Status.fail, (try classify(a, res(.{ .exited = 1 }), d, null, true)).status);
    const crash = try classify(a, res(.{ .signaled = std.posix.SIG.SEGV }), d, null, false);
    try std.testing.expectEqual(Status.crash, crash.status);
    try std.testing.expectEqualStrings("killed by SIGSEGV (signal 11)", crash.message);
    // mopm's own kill is not a crash: the deadline and the cap win.
    var to = res(.{ .signaled = std.posix.SIG.KILL });
    to.timeout = .hung;
    const tv = try classify(a, to, d, null, false);
    try std.testing.expectEqual(Status.timeout, tv.status);
    try std.testing.expectEqualStrings("hung at the 6 s deadline (--timeout): no CPU used over the last window", tv.message);
    var oom = res(.{ .signaled = std.posix.SIG.KILL });
    oom.oom = true;
    try std.testing.expectEqual(Status.oom, (try classify(a, oom, d, 256 << 20, false)).status);
}

test "sawPass: the PASS line of that test only, colour codes removed" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const out = "Running 1 tests for /x/t.mojo\n    \x1b[92mPASS\x1b[0m [ 0.002 ] test_one\n--------\n";
    try std.testing.expect(try sawPass(a, out, "test_one"));
    try std.testing.expect(!try sawPass(a, out, "test_on"));
    try std.testing.expect(!try sawPass(a, "    FAIL [ 0.002 ] test_one\n", "test_one"));
    try std.testing.expect(!try sawPass(a, "", "test_one"));
}

fn noDetails(_: Allocator, a: Attempt) []const u8 {
    return a.message;
}

test "JSON and JUnit: counts, escaping, one suite per file" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const outcomes = [_]Outcome{
        .{ .id = "a.mojo::test_p", .file = "a.mojo", .name = "test_p", .status = .pass, .wall_ns = 1_500_000, .exit_code = 0 },
        .{ .id = "a.mojo::test_f", .file = "a.mojo", .name = "test_f", .status = .fail, .message = "exit status 1 <\"&\">", .exit_code = 1 },
        .{ .id = "b.mojo::test_c", .file = "b.mojo", .name = "test_c", .status = .crash, .message = "killed by SIGSEGV", .signal = std.posix.SIG.SEGV },
    };
    var json = std.ArrayList(u8).init(a);
    try writeJson(json.writer(), .{ .deadline_ns = 6 * std.time.ns_per_s, .memory_cap = null, .memory_enforcement = "none", .opt_level = 1, .exit_code = 1 }, &outcomes);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{});
    const root = parsed.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema").?.integer);
    try std.testing.expectEqual(@as(i64, 3), root.get("summary").?.object.get("tests").?.integer);
    const tests = root.get("tests").?.array.items;
    try std.testing.expectEqualStrings("crash", tests[2].object.get("status").?.string);
    try std.testing.expectEqualStrings("SIGSEGV", tests[2].object.get("signal_name").?.string);
    try std.testing.expectEqualStrings("exit status 1 <\"&\">", tests[1].object.get("message").?.string);
    try std.testing.expect(tests[0].object.get("signal").? == .null);

    var xml = std.ArrayList(u8).init(a);
    try writeJunit(a, xml.writer(), &outcomes, &noDetails);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<testsuites name=\"mopm test\" tests=\"3\" failures=\"1\" errors=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<testsuite name=\"a.mojo\" tests=\"2\" failures=\"1\" errors=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<testsuite name=\"b.mojo\" tests=\"1\" failures=\"0\" errors=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "message=\"exit status 1 &lt;&quot;&amp;&quot;&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<error type=\"CRASH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "time=\"0.001\"/>") != null);
}

test "retries: FLAKY when an attempt failed and a later one passed, never PASS" {
    const P = Attempt{ .status = .pass };
    const F = Attempt{ .status = .fail };
    const C = Attempt{ .status = .crash };
    try std.testing.expectEqual(Status.pass, finalStatus(&.{P}));
    try std.testing.expectEqual(Status.fail, finalStatus(&.{F}));
    try std.testing.expectEqual(Status.flaky, finalStatus(&.{ F, P }));
    try std.testing.expectEqual(Status.flaky, finalStatus(&.{ C, F, P }));
    try std.testing.expectEqual(Status.fail, finalStatus(&.{ C, F }));
    try std.testing.expectEqual(Status.crash, finalStatus(&.{ F, C }));
    // --retries 0: never again; --retries 2: attempts 1 and 2 may retry, 3 not.
    try std.testing.expect(!retryAfter(.fail, 1, 0));
    try std.testing.expect(retryAfter(.fail, 1, 2));
    try std.testing.expect(retryAfter(.timeout, 2, 2));
    try std.testing.expect(!retryAfter(.fail, 3, 2));
    try std.testing.expect(!retryAfter(.pass, 1, 2));
    try std.testing.expect(!Status.flaky.failsRun());
    try std.testing.expect(!Status.skip.failsRun());
    try std.testing.expect(Status.compile_error.failsRun());
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectEqualStrings("attempt 1 FAIL (exit status 1), attempt 2 PASS", try attemptsMessage(t.allocator(), &.{ .{ .status = .fail, .message = "exit status 1" }, P }));
}

test "JSON and JUnit: every attempt of a FLAKY and a retried FAIL, and a SKIP" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const flaky_attempts = [_]Attempt{
        .{ .status = .crash, .message = "killed by SIGABRT (signal 6)", .signal = std.posix.SIG.ABRT },
        .{ .status = .pass, .exit_code = 0 },
    };
    const fail_attempts = [_]Attempt{
        .{ .status = .fail, .message = "exit status 1", .exit_code = 1 },
        .{ .status = .fail, .message = "exit status 2", .exit_code = 2 },
    };
    const outcomes = [_]Outcome{
        .{ .id = "a.mojo::test_f", .file = "a.mojo", .name = "test_f", .status = .flaky, .message = "m", .exit_code = 0, .attempts = &flaky_attempts, .binary_sha256 = "ab" },
        .{ .id = "a.mojo::test_x", .file = "a.mojo", .name = "test_x", .status = .fail, .message = "exit status 2", .exit_code = 2, .attempts = &fail_attempts },
        .{ .id = "a.mojo::test_i", .file = "a.mojo", .name = "test_i", .status = .skip, .message = "ignored: slow (#4)", .ignore = .{ .reason = "slow", .issue = "#4" } },
    };
    var json = std.ArrayList(u8).init(a);
    try writeJson(json.writer(), .{ .deadline_ns = std.time.ns_per_s, .memory_cap = null, .memory_enforcement = "none", .opt_level = 1, .exit_code = 1, .retries = 1, .deny_flaky = true, .filtered_out = 5 }, &outcomes);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{})).object;
    const sum = root.get("summary").?.object;
    try std.testing.expectEqual(@as(i64, 1), sum.get("flaky").?.integer);
    try std.testing.expectEqual(@as(i64, 1), sum.get("skip").?.integer);
    try std.testing.expectEqual(@as(i64, 5), sum.get("filtered_out").?.integer);
    try std.testing.expectEqual(true, root.get("settings").?.object.get("deny_flaky").?.bool);
    const tests = root.get("tests").?.array.items;
    try std.testing.expectEqualStrings("flaky", tests[0].object.get("status").?.string);
    const fa = tests[0].object.get("attempts").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), fa.len);
    try std.testing.expectEqualStrings("crash", fa[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("SIGABRT", fa[0].object.get("signal_name").?.string);
    try std.testing.expectEqual(@as(i64, 2), fa[1].object.get("attempt").?.integer);
    try std.testing.expectEqualStrings("pass", fa[1].object.get("status").?.string);
    try std.testing.expectEqualStrings("ab", tests[0].object.get("binary_sha256").?.string);
    try std.testing.expectEqual(@as(usize, 0), tests[2].object.get("attempts").?.array.items.len);
    try std.testing.expectEqualStrings("#4", tests[2].object.get("ignore").?.object.get("issue").?.string);
    try std.testing.expect(tests[1].object.get("ignore").? == .null);

    var xml = std.ArrayList(u8).init(a);
    try writeJunit(a, xml.writer(), &outcomes, &noDetails);
    // FLAKY counts as passed; the SKIP is skipped.
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "tests=\"3\" failures=\"1\" errors=\"0\" skipped=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<flakyError type=\"CRASH\" message=\"attempt 1: killed by SIGABRT (signal 6)\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<failure type=\"FAIL\" message=\"exit status 2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<rerunFailure type=\"FAIL\" message=\"attempt 1: exit status 1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<skipped message=\"ignored: slow (#4)\"/>") != null);
}
