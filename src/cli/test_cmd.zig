//! `mopm test`: discover the tests of a package, build each test file once,
//! and run every test in a process of its own under a supervisor. The
//! reference (flags, verdicts, the JSON schema, exit codes, what the memory
//! cap does on each OS) is docs/mopm-test.md.
//!
//!   mopm test [<path>...]
//!       Discover (core/test_scan.zig; a <path> that is a directory is a
//!       package root searched by the convention in core/test_harness.zig,
//!       a file is a test file as given; default "."), then build every file
//!       that has tests with the `mojo build` command line `mopm build` uses
//!       (core/autolink.zig: same environment, same native link arguments),
//!       plus `-D ASSERT=all --optimization-level 1` and `-I <root>/src` (the package's own sources,
//!       which its tests import by name). A bare file is built
//!       through its generated harness, target/mopm/gen/<hash>/<name>.mojo;
//!       the binary is target/mopm/bin/<hash>/<stem>. Each binary's
//!       `--skip-all` listing is compared with the scan as in --check. Then
//!       each test runs as `<binary> --only <name>` through
//!       core/test_proc.zig (own process group, deadline, memory cap), its
//!       output in target/mopm/test/<hash>/<name>.{stdout,stderr}.
//!       With --retries N a test that did not pass runs again, up to N
//!       more times (attempt k > 1 writes <name>.attempt<k>.{stdout,stderr});
//!       one that failed and then passed is FLAKY (core/test_report.zig).
//!   mopm test --list [--check] [<path>...]
//!       Only list: `<file>::<test>` per line, the tests a run would run.
//!       --check also builds and compares the `--skip-all` listing.
//!
//! Selection (core/test_filter.zig): the patterns after `--`, --skip,
//! --exact; tests marked `# mopm: ignore` are SKIP unless --ignored (only
//! them) or --include-ignored (all). Only files with a test to run build.
//!
//! Exit status: 0 every test that ran passed (FLAKY included, unless
//! --deny-flaky); 1 a test did not pass (FAIL, CRASH, TIMEOUT, OOM, or
//! FLAKY with --deny-flaky); 2 a usage error, a discovery error, a listing that differs
//! from the scan, a file that did not build, or no test to run (unless
//! --allow-empty); 5 a mopm or toolchain problem: no usable environment, a
//! `--skip-all` listing mopm cannot read, or a test whose process group
//! outlived it. The highest applicable status wins.

const std = @import("std");
const core = @import("mopm_core");
const test_scan = core.test_scan;
const test_harness = core.test_harness;
const test_proc = core.test_proc;
const report = core.test_report;
const autolink = core.autolink;
const mojo_cmd = core.mojo_cmd;
const test_filter = core.test_filter;

const usage =
    \\usage: mopm test [<path>...] [--prefix <dir>] [--timeout <seconds>]
    \\                 [--memory <MiB>] [--opt-level <0-3>] [--format human|json]
    \\                 [--junit <file>] [--allow-empty] [--strict-discovery]
    \\                 [--retries <n>] [--deny-flaky] [<selection>] [-- <pattern>...]
    \\       mopm test --list [--check [--strict-discovery] [--prefix <dir>]]
    \\                 [<selection>] [<path>...] [-- <pattern>...]
    \\  <selection>: [--skip <pattern>]... [--exact] [--ignored | --include-ignored]
    \\
;

const Format = enum { human, json };

const Opts = struct {
    list: bool = false,
    check: bool = false,
    strict: bool = false,
    prefix: ?[]const u8 = null,
    paths: std.ArrayList([]const u8),
    timeout_s: ?u64 = null,
    memory_mib: ?u64 = null,
    opt_level: ?u8 = null,
    format: ?Format = null,
    junit: ?[]const u8 = null,
    allow_empty: bool = false,
    retries: ?u32 = null,
    deny_flaky: bool = false,
    /// After `--`: a test runs when one of them selects it (core/test_filter.zig).
    patterns: std.ArrayList([]const u8),
    skips: std.ArrayList([]const u8),
    exact: bool = false,
    ignored: test_filter.Ignored = .skip,
    /// Test-only (the supervisor self-test): never kill the process group.
    no_group_kill: bool = false,

    fn runOnly(o: Opts) bool {
        return o.timeout_s != null or o.memory_mib != null or o.format != null or o.junit != null or o.allow_empty or o.no_group_kill or o.retries != null or o.deny_flaky;
    }
};

const File = struct {
    /// As printed and as opened: relative to the root it was found under,
    /// joined to it unless the root is ".", or as given on the command line.
    display: []const u8,
};

fn lessFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.display, b.display);
}

pub fn main(arena: std.mem.Allocator, args: []const []const u8) u8 {
    return run(arena, args) catch |e| {
        std.io.getStdErr().writer().print("mopm test: {s}\n", .{@errorName(e)}) catch {};
        return 5;
    };
}

/// `--name value` or `--name=value`: the value (advancing `i`), "" when the
/// value is missing, null when `args[i]` is another option.
fn optValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, name)) {
        if (i.* + 1 >= args.len) return "";
        i.* += 1;
        return args[i.*];
    }
    if (a.len > name.len and std.mem.startsWith(u8, a, name) and a[name.len] == '=') return a[name.len + 1 ..];
    return null;
}

const Parsed = union(enum) { ok: Opts, usage: []const u8 };

fn parse(arena: std.mem.Allocator, args: []const []const u8) !Parsed {
    var o = Opts{
        .paths = std.ArrayList([]const u8).init(arena),
        .patterns = std.ArrayList([]const u8).init(arena),
        .skips = std.ArrayList([]const u8).init(arena),
    };
    var ignored_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            for (args[i + 1 ..]) |p| {
                if (p.len == 0) return .{ .usage = "an empty pattern after --" };
                try o.patterns.append(p);
            }
            break;
        } else if (std.mem.eql(u8, a, "--exact")) {
            o.exact = true;
        } else if (std.mem.eql(u8, a, "--ignored") or std.mem.eql(u8, a, "--include-ignored")) {
            if (ignored_flag) |prev| {
                if (!std.mem.eql(u8, prev, a)) return .{ .usage = "--ignored (only the ignored tests) and --include-ignored (all tests) exclude each other" };
            }
            ignored_flag = a;
            o.ignored = if (std.mem.eql(u8, a, "--ignored")) .only else .include;
        } else if (std.mem.eql(u8, a, "--deny-flaky")) {
            o.deny_flaky = true;
        } else if (optValue(args, &i, "--skip")) |v| {
            if (v.len == 0) return .{ .usage = "--skip needs a pattern" };
            try o.skips.append(v);
        } else if (optValue(args, &i, "--retries")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 1000;
            if (n > 100) return .{ .usage = try std.fmt.allocPrint(arena, "--retries takes 0 to 100, not '{s}'", .{v}) };
            o.retries = n;
        } else if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, a, "--strict-discovery")) {
            o.strict = true;
        } else if (std.mem.eql(u8, a, "--allow-empty")) {
            o.allow_empty = true;
        } else if (std.mem.eql(u8, a, "--test-only-no-group-kill")) {
            o.no_group_kill = true;
        } else if (optValue(args, &i, "--prefix")) |v| {
            if (v.len == 0) return .{ .usage = "--prefix needs a directory" };
            o.prefix = v;
        } else if (optValue(args, &i, "--timeout")) |v| {
            const n = std.fmt.parseInt(u64, v, 10) catch 0;
            if (n == 0 or n > 86400) return .{ .usage = try std.fmt.allocPrint(arena, "--timeout takes whole seconds from 1 to 86400, not '{s}'", .{v}) };
            o.timeout_s = n;
        } else if (optValue(args, &i, "--memory")) |v| {
            o.memory_mib = std.fmt.parseInt(u64, v, 10) catch
                return .{ .usage = try std.fmt.allocPrint(arena, "--memory takes MiB (0: no cap), not '{s}'", .{v}) };
        } else if (optValue(args, &i, "--opt-level")) |v| {
            const n = std.fmt.parseInt(u8, v, 10) catch 9;
            if (n > 3) return .{ .usage = try std.fmt.allocPrint(arena, "--opt-level takes 0 to 3, not '{s}'", .{v}) };
            o.opt_level = n;
        } else if (optValue(args, &i, "--format")) |v| {
            o.format = std.meta.stringToEnum(Format, v) orelse
                return .{ .usage = try std.fmt.allocPrint(arena, "--format takes human or json, not '{s}'", .{v}) };
        } else if (optValue(args, &i, "--junit")) |v| {
            if (v.len == 0) return .{ .usage = "--junit needs a file name" };
            o.junit = v;
        } else if (a.len > 1 and a[0] == '-') {
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{a}) };
        } else {
            try o.paths.append(a);
        }
    }
    if (o.list) {
        if (o.runOnly()) return .{ .usage = "--timeout, --memory, --format, --junit, --allow-empty, --retries and --deny-flaky apply only when running tests, not with --list" };
        if (o.opt_level != null) return .{ .usage = "--opt-level applies only when running tests" };
        if (!o.check and (o.strict or o.prefix != null)) return .{ .usage = "with --list, --strict-discovery and --prefix apply only with --check" };
    } else if (o.check) {
        return .{ .usage = "--check applies only with --list (running tests always checks the listing)" };
    }
    if (o.exact and o.patterns.items.len == 0 and o.skips.items.len == 0) return .{ .usage = "--exact needs a pattern: `-- <file>::<test>` or --skip <file>::<test>" };
    if (o.paths.items.len == 0) try o.paths.append(".");
    return .{ .ok = o };
}

/// Where one test file's products go: target/mopm/<kind>/<hash>.
const Paths = struct {
    hash: []const u8,
    base: []const u8,
    stem: []const u8,

    fn of(arena: std.mem.Allocator, display: []const u8) !Paths {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(display, &digest, .{});
        const base = std.fs.path.basename(display);
        return .{
            .hash = try std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(digest[0..8])}),
            .base = base,
            .stem = base[0 .. base.len - std.fs.path.extension(base).len],
        };
    }

    fn dir(p: Paths, arena: std.mem.Allocator, kind: []const u8) ![]const u8 {
        const d = try std.fs.path.join(arena, &.{ "target", "mopm", kind, p.hash });
        try std.fs.cwd().makePath(d);
        return d;
    }
};

fn run(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    const err = std.io.getStdErr().writer();
    const o = switch (try parse(arena, args)) {
        .ok => |v| v,
        .usage => |m| return usageError(m),
    };

    // The files, deduplicated by their display path.
    var files = std.ArrayList(File).init(arena);
    for (o.paths.items) |p| {
        const st = std.fs.cwd().statFile(p) catch |e| {
            try err.print("mopm test: {s}: {s}\n", .{ p, @errorName(e) });
            return 2;
        };
        if (st.kind == .directory) {
            for (try test_harness.findTestFiles(arena, p)) |rel| {
                const shown = if (std.mem.eql(u8, p, ".")) rel else try std.fs.path.join(arena, &.{ p, rel });
                try files.append(.{ .display = shown });
            }
        } else {
            try files.append(.{ .display = p });
        }
    }
    std.sort.insertion(File, files.items, {}, lessFile);

    const Scanned = struct { f: File, src: []const u8, sc: test_scan.Scan };
    var scanned = std.ArrayList(Scanned).init(arena);
    var failed = false;
    var prev: ?[]const u8 = null;
    for (files.items) |f| {
        if (prev) |q| if (std.mem.eql(u8, q, f.display)) continue;
        prev = f.display;
        const src = std.fs.cwd().readFileAlloc(arena, f.display, 16 << 20) catch |e| {
            try err.print("mopm test: {s}: {s}\n", .{ f.display, @errorName(e) });
            failed = true;
            continue;
        };
        const sc = try test_scan.scan(arena, src);
        for (sc.warnings) |d| try err.print("mopm test: warning: {s}:{d}: {s}\n", .{ f.display, d.line, d.message });
        for (sc.errors) |d| try err.print("mopm test: {s}:{d}: {s}\n", .{ f.display, d.line, d.message });
        if (!sc.ok()) {
            failed = true;
            continue;
        }
        try scanned.append(.{ .f = f, .src = src, .sc = sc });
    }

    // Which tests run (core/test_filter.zig): per file, one choice per test.
    const filter = test_filter.Filter{
        .patterns = o.patterns.items,
        .skips = o.skips.items,
        .exact = o.exact,
        .ignored = o.ignored,
    };
    const State = enum { idle, compile_error, check_failed, ok };
    const Plan = struct {
        s: Scanned,
        choices: []test_filter.Choice,
        runs: usize = 0,
        state: State = .idle,
        bin: ?[]const u8 = null,
        sha: ?[]const u8 = null,
    };
    var plans = std.ArrayList(Plan).init(arena);
    var discovered: usize = 0;
    var filtered_out: usize = 0;
    var to_run: usize = 0;
    for (scanned.items) |s| {
        var plan = Plan{ .s = s, .choices = try arena.alloc(test_filter.Choice, s.sc.tests.len) };
        for (s.sc.tests, plan.choices) |t, *c| {
            const id = try std.fmt.allocPrint(arena, "{s}::{s}", .{ s.f.display, t.name });
            c.* = test_filter.choose(filter, id, t.name, t.ignore != null);
            switch (c.*) {
                .run => plan.runs += 1,
                .skip => {},
                .out => filtered_out += 1,
            }
        }
        discovered += s.sc.tests.len;
        to_run += plan.runs;
        try plans.append(plan);
    }

    if (o.list and !o.check) {
        if (failed) return 2;
        return listSelected(arena, plans.items);
    }

    var tc: ?autolink.Toolchain = null;
    if (to_run > 0) {
        switch (try autolink.prepare(arena, .build, o.prefix, getEnv(arena, "CONDA_PREFIX"), getEnv(arena, "MODULAR_HOME"))) {
            .ok => |v| tc = v,
            .refused => |msgs| {
                for (msgs) |m| try err.print("mopm test: {s}\n", .{m});
                return 5;
            },
        }
    }

    const opt_level = o.opt_level orelse 1;
    var flag_list = std.ArrayList([]const u8).init(arena);
    try flag_list.appendSlice(&.{ "-D", "ASSERT=all", "--optimization-level", try std.fmt.allocPrint(arena, "{d}", .{opt_level}) });
    // A package's tests import the package by name (`from my_pkg import f`, as `mopm new` writes them): its
    // sources are on the import path. The package root is each directory given, or the current one for a file.
    for (o.paths.items) |p| {
        const st = std.fs.cwd().statFile(p) catch continue;
        const src_dir = try std.fs.path.join(arena, &.{ if (st.kind == .directory) p else ".", "src" });
        const src_st = std.fs.cwd().statFile(src_dir) catch continue;
        if (src_st.kind != .directory) continue;
        var seen = false;
        for (flag_list.items) |f| seen = seen or std.mem.eql(u8, f, src_dir);
        if (!seen) try flag_list.appendSlice(&.{ "-I", src_dir });
    }
    const flags = flag_list.items;
    for (plans.items) |*plan| {
        if (plan.runs == 0) continue;
        const bin = (try buildFile(arena, tc.?, plan.s.f, plan.s.src, plan.s.sc, flags)) orelse {
            failed = true;
            plan.state = .compile_error;
            continue;
        };
        switch (try check(arena, o, plan.s.f, plan.s.sc, bin)) {
            .same, .warned => {
                plan.state = .ok;
                plan.bin = bin;
                plan.sha = try sha256File(arena, bin);
            },
            .failed => {
                failed = true;
                plan.state = .check_failed;
            },
            .protocol => return 5,
        }
    }

    if (o.list) {
        if (failed) return 2;
        return listSelected(arena, plans.items);
    }

    // ------------------------------------------------------------ run
    const format = o.format orelse .human;
    const retries = o.retries orelse 0;
    const deadline_ns = (o.timeout_s orelse 60) * std.time.ns_per_s;
    const memory_cap: ?u64 = if (o.memory_mib) |m|
        (if (m == 0) null else m << 20)
    else
        @min(@as(u64, 4096) << 20, test_proc.totalMemory() orelse (@as(u64, 4096) << 20));
    const stdout = std.io.getStdOut().writer();
    var outcomes = std.ArrayList(report.Outcome).init(arena);
    var leftover = false;
    for (plans.items) |plan| {
        // A file whose listing differs from the scan reports no tests (the
        // error above says why, and the run exits 2).
        if (plan.state == .check_failed) continue;
        const p = try Paths.of(arena, plan.s.f.display);
        for (plan.s.sc.tests, plan.choices) |t, choice| {
            if (choice == .out) continue;
            const id = try std.fmt.allocPrint(arena, "{s}::{s}", .{ plan.s.f.display, t.name });
            var oc = report.Outcome{ .id = id, .file = plan.s.f.display, .name = t.name, .status = .compile_error, .ignore = t.ignore };
            if (choice == .skip) {
                oc.status = .skip;
                oc.message = try std.fmt.allocPrint(arena, "ignored: {s} ({s}); --ignored or --include-ignored runs it", .{ t.ignore.?.reason, t.ignore.?.issue });
            } else if (plan.bin) |bin| {
                const dir = try p.dir(arena, "test");
                var attempts = std.ArrayList(report.Attempt).init(arena);
                var k: u32 = 1;
                while (true) : (k += 1) {
                    // Attempt 1 writes <test>.stdout; attempt k > 1 <test>.attempt<k>.stdout.
                    const stem = if (k == 1) t.name else try std.fmt.allocPrint(arena, "{s}.attempt{d}", .{ t.name, k });
                    const at = try runOnce(arena, id, k, bin, t.name, dir, stem, deadline_ns, memory_cap, !o.no_group_kill);
                    leftover = leftover or at.leftover;
                    try attempts.append(at);
                    if (!report.retryAfter(at.status, k, retries)) break;
                }
                const last = attempts.items[attempts.items.len - 1];
                oc.attempts = attempts.items;
                oc.binary_sha256 = plan.sha;
                oc.status = report.finalStatus(attempts.items);
                oc.message = if (attempts.items.len == 1) last.message else try report.attemptsMessage(arena, attempts.items);
                oc.wall_ns = last.wall_ns;
                oc.cpu_ns = last.cpu_ns;
                oc.peak_rss = last.peak_rss;
                oc.exit_code = last.exit_code;
                oc.signal = last.signal;
                oc.timeout = last.timeout;
                oc.leftover = last.leftover;
                oc.stdout_path = last.stdout_path;
                oc.stderr_path = last.stderr_path;
            } else {
                oc.message = "the test file did not build";
            }
            try outcomes.append(oc);
            if (format == .human) try report.writeLine(stdout, oc);
        }
    }

    const counts = report.Counts.of(outcomes.items);
    var code: u8 = 0;
    for (outcomes.items) |oc| {
        if (oc.status.failsRun()) code = 1;
    }
    if (counts.flaky > 0 and o.deny_flaky) code = 1;
    if (failed) code = 2;
    if (counts.total == counts.skip and !failed and !o.allow_empty) {
        if (discovered == 0) {
            try err.print("mopm test: no tests found (--allow-empty accepts that)\n", .{});
        } else {
            try err.print("mopm test: no test selected to run: {d} filtered out, {d} ignored (--allow-empty accepts that)\n", .{ filtered_out, counts.skip });
        }
        code = 2;
    }
    if (leftover) code = 5;

    switch (format) {
        .human => {
            for (outcomes.items) |oc| {
                if (oc.status == .pass or oc.status == .compile_error or oc.status == .skip) continue;
                try stdout.print("\n---- {s}: {s}: {s}\n", .{ oc.id, oc.status.label(), oc.message });
                for (oc.attempts, 1..) |at, k| {
                    if (at.status == .pass) continue;
                    if (oc.attempts.len > 1) try stdout.print("  attempt {d}: {s}: {s}\n", .{ k, at.status.label(), at.message });
                    try stdout.writeAll(tail(arena, at, 30));
                }
            }
            if (counts.total > 0) {
                try stdout.writeByte('\n');
                try report.writeSummary(stdout, outcomes.items, filtered_out);
            }
        },
        .json => {
            var buf = std.ArrayList(u8).init(arena);
            try report.writeJson(buf.writer(), .{
                .deadline_ns = deadline_ns,
                .memory_cap = memory_cap,
                .memory_enforcement = if (memory_cap == null) "none" else "rss-sampled",
                .opt_level = opt_level,
                .exit_code = code,
                .retries = retries,
                .deny_flaky = o.deny_flaky,
                .filtered_out = filtered_out,
            }, outcomes.items);
            try std.io.getStdOut().writeAll(buf.items);
        },
    }
    if (counts.flaky > 0) {
        if (o.deny_flaky) {
            try err.print("mopm test: {d} FLAKY test(s): each failed and then passed, same binary and argv; --deny-flaky fails the run\n", .{counts.flaky});
        } else {
            try err.print("mopm test: warning: {d} FLAKY test(s): each failed and then passed, same binary and argv; the run still passes (--deny-flaky fails it)\n", .{counts.flaky});
        }
    }
    if (o.junit) |path| {
        var buf = std.ArrayList(u8).init(arena);
        try report.writeJunit(arena, buf.writer(), outcomes.items, &junitDetails);
        std.fs.cwd().writeFile(path, buf.items) catch |e| {
            try err.print("mopm test: writing {s}: {s}\n", .{ path, @errorName(e) });
            return 5;
        };
    }
    return code;
}

/// `--list`: the tests that would run, `<file>::<test>` per line.
fn listSelected(arena: std.mem.Allocator, plans: anytype) !u8 {
    var out = std.ArrayList(u8).init(arena);
    for (plans) |plan| {
        for (plan.s.sc.tests, plan.choices) |t, c| {
            if (c == .run) try out.writer().print("{s}::{s}\n", .{ plan.s.f.display, t.name });
        }
    }
    try std.io.getStdOut().writeAll(out.items);
    return 0;
}

/// One attempt of one test: `<bin> --only <name>` under the supervisor,
/// output to `<dir>/<stem>.stdout` and `.stderr`, and its verdict.
/// A process group that outlived the test is reported on stderr here.
fn runOnce(arena: std.mem.Allocator, id: []const u8, attempt: u32, bin: []const u8, name: []const u8, dir: []const u8, stem: []const u8, deadline_ns: u64, memory_cap: ?u64, kill_group: bool) !report.Attempt {
    const out_path = try std.fmt.allocPrint(arena, "{s}/{s}.stdout", .{ dir, stem });
    const err_path = try std.fmt.allocPrint(arena, "{s}/{s}.stderr", .{ dir, stem });
    const r = try test_proc.run(arena, .{
        .argv = &.{ bin, "--only", name },
        .stdout_path = out_path,
        .stderr_path = err_path,
    }, .{ .deadline_ns = deadline_ns, .memory_bytes = memory_cap, .kill_group = kill_group });
    const out_text = std.fs.cwd().readFileAlloc(arena, out_path, 64 << 20) catch "";
    const err_text = std.fs.cwd().readFileAlloc(arena, err_path, 64 << 20) catch "";
    const saw = (try report.sawPass(arena, out_text, name)) or (try report.sawPass(arena, err_text, name));
    const v = try report.classify(arena, r, deadline_ns, memory_cap, saw);
    if (r.leftover) {
        const which = if (attempt == 1) "" else try std.fmt.allocPrint(arena, " (attempt {d})", .{attempt});
        try std.io.getStdErr().writer().print("mopm test: {s}: process group {d} still has processes after the test ended{s}\n", .{ id, r.pgid, which });
    }
    var at = report.Attempt{
        .status = v.status,
        .message = v.message,
        .wall_ns = r.wall_ns,
        .cpu_ns = r.cpu_ns,
        .peak_rss = r.peak_rss,
        .timeout = r.timeout,
        .leftover = r.leftover,
        .stdout_path = out_path,
        .stderr_path = err_path,
    };
    switch (r.term) {
        .exited => |c| at.exit_code = c,
        .signaled => |sig| at.signal = sig,
    }
    return at;
}

/// Lower-case hex sha256 of a file's bytes.
fn sha256File(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 << 10]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    const digest = h.finalResult();
    return std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

fn getEnv(arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(arena, key) catch null;
}

/// The last `n` lines of an attempt's stdout and of its stderr, colour codes
/// removed, indented.
fn tail(arena: std.mem.Allocator, at: report.Attempt, n: usize) []const u8 {
    var out = std.ArrayList(u8).init(arena);
    for ([_]?[]const u8{ at.stdout_path, at.stderr_path }, [_][]const u8{ "stdout", "stderr" }) |path, label| {
        const p = path orelse continue;
        const raw = std.fs.cwd().readFileAlloc(arena, p, 64 << 20) catch continue;
        const text = test_harness.stripAnsi(arena, raw) catch continue;
        const trimmed = std.mem.trimRight(u8, text, "\n");
        if (trimmed.len == 0) continue;
        var start = trimmed.len;
        var lines: usize = 0;
        while (start > 0 and lines < n) {
            start -= 1;
            if (trimmed[start] == '\n') lines += 1;
        }
        if (trimmed[start] == '\n') start += 1;
        out.writer().print("  [{s}, {s}]\n", .{ label, p }) catch return "";
        var it = std.mem.splitScalar(u8, trimmed[start..], '\n');
        while (it.next()) |l| out.writer().print("  | {s}\n", .{l}) catch return "";
    }
    return out.items;
}

fn junitDetails(arena: std.mem.Allocator, at: report.Attempt) []const u8 {
    return tail(arena, at, 40);
}

fn usageError(msg: []const u8) u8 {
    std.io.getStdErr().writer().print("mopm test: {s}\n\n{s}", .{ msg, usage }) catch {};
    return 2;
}

/// Build one test file (through its harness when bare) with the `mojo
/// build` line of `mopm build` plus `flags`. Returns the binary, or null
/// after printing why it did not build.
fn buildFile(arena: std.mem.Allocator, tc: autolink.Toolchain, f: File, src: []const u8, sc: test_scan.Scan, flags: []const []const u8) !?[]const u8 {
    const err = std.io.getStdErr().writer();
    const p = try Paths.of(arena, f.display);
    var program = f.display;
    if (sc.kind == .bare) {
        program = try std.fs.path.join(arena, &.{ try p.dir(arena, "gen"), p.base });
        try std.fs.cwd().writeFile(program, try test_harness.generate(arena, src, sc.tests));
    }
    const bin = try std.fs.path.join(arena, &.{ try p.dir(arena, "bin"), p.stem });
    const cmd = try mojo_cmd.construct(arena, .{
        .tool = .build,
        .prefix = tc.prefix,
        .os = mojo_cmd.Os.host(),
        .file = program,
        .out = bin,
        .flags = flags,
    }, tc.plan);
    var env_map = try core.child_env.forChild(arena);
    try mojo_cmd.applyEnv(&env_map, cmd.env);
    const r = std.ChildProcess.run(.{ .allocator = arena, .argv = cmd.argv, .env_map = &env_map, .max_output_bytes = 16 << 20 }) catch |e| {
        try err.print("mopm test: {s}: cannot run {s}: {s}\n", .{ f.display, cmd.argv[0], @errorName(e) });
        return null;
    };
    if (!exitedZero(r.term)) {
        var line = std.ArrayList(u8).init(arena);
        try mojo_cmd.render(cmd, line.writer());
        try err.print("mopm test: {s}: the build failed ({s}):\n  {s}{s}{s}", .{ f.display, program, line.items, r.stdout, r.stderr });
        return null;
    }
    return bin;
}

const Checked = enum { same, warned, failed, protocol };

/// List the built binary with `--skip-all` and compare with the scan.
fn check(arena: std.mem.Allocator, o: Opts, f: File, sc: test_scan.Scan, bin: []const u8) !Checked {
    const err = std.io.getStdErr().writer();
    var listed_env = try core.child_env.forChild(arena);
    const listed = try std.ChildProcess.run(.{ .allocator = arena, .argv = &.{ bin, "--skip-all" }, .env_map = &listed_env, .max_output_bytes = 16 << 20 });
    if (!exitedZero(listed.term)) {
        try err.print("mopm test: {s}: `{s} --skip-all` failed:\n{s}{s}", .{ f.display, bin, listed.stdout, listed.stderr });
        return .failed;
    }
    const names = test_harness.parseListing(arena, listed.stdout) catch |e| switch (e) {
        error.ProtocolMismatch => {
            try err.print("mopm test: {s}: `{s} --skip-all` printed a listing mopm cannot read; the installed Mojo's std.testing.TestSuite is not the one mopm knows (Mojo 1.0.0). Its output:\n{s}{s}", .{ f.display, bin, listed.stdout, listed.stderr });
            return .protocol;
        },
        else => |x| return x,
    };
    var scanned = std.ArrayList([]const u8).init(arena);
    for (sc.tests) |t| try scanned.append(t.name);
    const d = try test_harness.compare(arena, scanned.items, names);
    if (d.same()) return .same;

    const fatal = sc.kind == .bare or o.strict;
    try err.print("mopm test: {s}{s}: the scan and the `--skip-all` listing of the built {s} differ\n", .{
        @as([]const u8, if (fatal) "" else "warning: "),
        f.display,
        @as([]const u8, if (sc.kind == .bare) "harness" else "file"),
    });
    try printNames(err, "only in the scan:   ", d.only_scan);
    try printNames(err, "only in the listing:", d.only_listing);
    try printNames(err, "scan:               ", scanned.items);
    try printNames(err, "listing:            ", names);
    return if (fatal) .failed else .warned;
}

fn printNames(w: anytype, label: []const u8, names: []const []const u8) !void {
    try w.print("  {s}", .{label});
    for (names) |n| try w.print(" {s}", .{n});
    try w.writeByte('\n');
}

fn exitedZero(term: std.ChildProcess.Term) bool {
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}

// ---------------------------------------------------------------- tests

fn parsed(a: std.mem.Allocator, args: []const []const u8) !Opts {
    return switch (try parse(a, args)) {
        .ok => |o| o,
        .usage => |m| {
            std.debug.print("unexpected usage error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn refused(a: std.mem.Allocator, args: []const []const u8) !void {
    switch (try parse(a, args)) {
        .ok => return error.TestUnexpectedResult,
        .usage => {},
    }
}

test "test options" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const o = try parsed(a, &.{ "pkg", "--timeout", "6", "--memory=256", "--format", "json", "--junit", "j.xml", "--opt-level=0", "--prefix", "/e" });
    try std.testing.expectEqual(@as(?u64, 6), o.timeout_s);
    try std.testing.expectEqual(@as(?u64, 256), o.memory_mib);
    try std.testing.expectEqual(@as(?Format, .json), o.format);
    try std.testing.expectEqualStrings("j.xml", o.junit.?);
    try std.testing.expectEqual(@as(?u8, 0), o.opt_level);
    try std.testing.expectEqualStrings("pkg", o.paths.items[0]);
    const d = try parsed(a, &.{});
    try std.testing.expectEqualStrings(".", d.paths.items[0]);
    try std.testing.expect(!d.no_group_kill);
    try refused(a, &.{ "--timeout", "0" });
    try refused(a, &.{ "--timeout", "x" });
    try refused(a, &.{"--timeout"});
    try refused(a, &.{ "--memory", "-1" });
    try refused(a, &.{ "--opt-level", "4" });
    try refused(a, &.{ "--format", "xml" });
    try refused(a, &.{ "--list", "--timeout", "5" });
    try refused(a, &.{ "--list", "--junit", "x" });
    try refused(a, &.{ "--list", "--prefix", "/e" });
    try refused(a, &.{"--check"});
    try refused(a, &.{"--frobnicate"});
    _ = try parsed(a, &.{ "--list", "--check", "--strict-discovery", "--prefix", "/e" });
}

test "selection and retry options" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const o = try parsed(a, &.{ "pkg", "--retries", "2", "--deny-flaky", "--skip", "slow", "--skip=net", "--include-ignored", "--", "alpha", "--exact", "pkg2" });
    try std.testing.expectEqual(@as(?u32, 2), o.retries);
    try std.testing.expect(o.deny_flaky);
    try std.testing.expectEqual(test_filter.Ignored.include, o.ignored);
    try std.testing.expectEqual(@as(usize, 2), o.skips.items.len);
    try std.testing.expectEqualStrings("net", o.skips.items[1]);
    // Everything after `--` is a pattern, even what looks like an option or a path.
    try std.testing.expectEqual(@as(usize, 3), o.patterns.items.len);
    try std.testing.expectEqualStrings("--exact", o.patterns.items[1]);
    try std.testing.expect(!o.exact);
    try std.testing.expectEqual(@as(usize, 1), o.paths.items.len);
    const d = try parsed(a, &.{});
    try std.testing.expectEqual(@as(?u32, null), d.retries);
    try std.testing.expect(!d.deny_flaky);
    try std.testing.expectEqual(test_filter.Ignored.skip, d.ignored);
    try std.testing.expectEqual(test_filter.Ignored.only, (try parsed(a, &.{ "--ignored", "--ignored" })).ignored);
    _ = try parsed(a, &.{ "--list", "--ignored", "--skip", "x", "--exact", "--", "f::t" });
    try refused(a, &.{ "--ignored", "--include-ignored" });
    try refused(a, &.{ "--retries", "101" });
    try refused(a, &.{ "--retries", "-1" });
    try refused(a, &.{"--retries"});
    try refused(a, &.{"--skip"});
    try refused(a, &.{"--exact"});
    try refused(a, &.{ "--", "" });
    try refused(a, &.{ "--list", "--retries", "1" });
    try refused(a, &.{ "--list", "--deny-flaky" });
}
