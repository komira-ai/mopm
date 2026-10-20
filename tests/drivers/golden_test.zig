//! The golden tests of tests/run_golden.sh, in Zig: the same checks over the
//! same files under tests/golden, for the build farm, which has neither a
//! shell nor `diff`. tests/run_golden.sh stays for ci.yml until farm.yml has
//! matched it, and is superseded by this file.
//!
//! Run by Buck2 (//:golden_test): the working directory is the repository
//! root with the test data present, MOPM is the built CLI, MOPM_FAKE_MOJO a
//! stand-in for `mojo` (tests/drivers/fake_mojo.zig). The repository root is
//! written @ROOT@ in the golden files.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    root: []const u8,
    mopm: []const u8,
    /// A prefix with the fixture exec environment's libraries and the stand-in
    /// `mojo` as bin/mojo, standing for tests/fixtures/env/exec.
    stand_in: []const u8,
    /// The environment every case starts from: this process's, without the two
    /// variables mopm reads to find an environment.
    base: std.process.EnvMap,

    const Set = struct { []const u8, []const u8 };
    const Opts = struct { set: []const Set = &.{}, stdin: ?[]const u8 = null };

    fn envWith(c: *Ctx, set: []const Set) !std.process.EnvMap {
        var env = try h.cloneEnv(c.a, &c.base);
        for (set) |s| try env.put(s[0], s[1]);
        return env;
    }

    /// The program's output with the stand-in prefix and the root rewritten.
    fn normalise(c: *Ctx, text: []const u8) ![]u8 {
        const real = try std.fmt.allocPrint(c.a, "{s}/tests/fixtures/env/exec", .{c.root});
        const first = try std.mem.replaceOwned(u8, c.a, text, c.stand_in, real);
        return std.mem.replaceOwned(u8, c.a, first, c.root, "@ROOT@");
    }

    fn mopmArgv(c: *Ctx, args: []const []const u8) ![]const []const u8 {
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        return argv;
    }

    /// `mopm <args>` with stdout and stderr together: its exit status must be
    /// `want` and the output (the root as @ROOT@) the file `gold`.
    fn cmd(c: *Ctx, label: []const u8, gold: []const u8, want: u8, args: []const []const u8, o: Opts) !void {
        var env = try c.envWith(o.set);
        const r = try h.run(c.a, try c.mopmArgv(args), &env, .{ .stdin_path = o.stdin });
        if (r.signaled or r.code != want) {
            c.rep.check(try std.fmt.allocPrint(c.a, "{s}: exit status", .{label}), false, try std.fmt.allocPrint(c.a, "exit {d}, want {d}", .{ r.code, want }));
        }
        const want_text = try h.readFile(c.a, gold);
        c.rep.same(label, want_text, try c.normalise(r.text));
    }
};

fn exitIs(rep: *h.Report, name: []const u8, r: h.Ran, want: u8) void {
    rep.check(name, !r.signaled and r.code == want, "wrong exit status");
}

/// The files under `dir` (relative paths, sorted), for comparing two trees.
fn listFiles(a: Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    var out = std.ArrayList([]const u8).init(a);
    while (try walker.next()) |e| {
        if (e.kind == .file) try out.append(try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out.items;
}

/// Whether the two trees hold the same files with the same bytes.
fn sameTree(a: Allocator, want: []const u8, got: []const u8) !bool {
    const wl = try listFiles(a, want);
    const gl = try listFiles(a, got);
    if (wl.len != gl.len) return false;
    for (wl, gl) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
        const xb = try h.readFile(a, try h.join(a, &.{ want, x }));
        const yb = try h.readFile(a, try h.join(a, &.{ got, y }));
        if (!std.mem.eql(u8, xb, yb)) return false;
    }
    return true;
}

fn copyInto(src: []const u8, dst: []const u8) !void {
    if (std.fs.path.dirname(dst)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});
}

test "golden files: link-plan, metadata, new and init, build, run, repl, test --list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(90);

    const root = try std.fs.cwd().realpathAlloc(a, ".");
    const mopm = try h.toolPath(a, "MOPM");
    const fake_mojo = try h.toolPath(a, "MOPM_FAKE_MOJO");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    // The exec environment: the fixture's libraries, the stand-in as bin/mojo.
    const stand_in = try h.join(a, &.{ work, "exec" });
    try copyInto("tests/fixtures/env/exec/lib/libecho.so", try h.join(a, &.{ stand_in, "lib/libecho.so" }));
    try copyInto("tests/fixtures/env/exec/lib/mojo/echo.mopm.json", try h.join(a, &.{ stand_in, "lib/mojo/echo.mopm.json" }));
    try copyInto(fake_mojo, try h.join(a, &.{ stand_in, "bin/mojo" }));
    const stand_in_real = try std.fs.cwd().realpathAlloc(a, stand_in);

    var base = try h.environ(a);
    base.remove("CONDA_PREFIX");
    base.remove("MODULAR_HOME");
    var c = Ctx{ .a = a, .rep = &rep, .root = root, .mopm = mopm, .stand_in = stand_in_real, .base = base };

    // ---- link-plan: tests/fixtures/<case>, stdout only
    const plans = [_]struct { name: []const u8, want: u8, pkgs: []const []const u8 }{
        .{ .name = "chain", .want = 0, .pkgs = &.{ "http_client", "crypto" } },
        .{ .name = "missing", .want = 1, .pkgs = &.{"http_client"} },
        .{ .name = "dup", .want = 1, .pkgs = &.{ "pkg_a", "pkg_b" } },
        .{ .name = "static", .want = 1, .pkgs = &.{"staticpkg"} },
    };
    for (plans) |p| {
        var args = std.ArrayList([]const u8).init(a);
        try args.append("link-plan");
        for (p.pkgs) |pkg| try args.append(try std.fmt.allocPrint(a, "tests/fixtures/{s}/{s}.mopm.json", .{ p.name, pkg }));
        const r = try h.run(a, try c.mopmArgv(args.items), &base, .{ .capture = .stdout });
        rep.check(try std.fmt.allocPrint(a, "{s}: exit status", .{p.name}), !r.signaled and r.code == p.want, "wrong exit status");
        rep.same(p.name, try h.readFile(a, try std.fmt.allocPrint(a, "tests/golden/{s}.txt", .{p.name})), r.text);
    }

    // ---- metadata: an accepted manifest prints its JSON; a refused one exits
    // non-zero with path:line:column and the message (stderr).
    {
        const r = try h.run(a, try c.mopmArgv(&.{ "metadata", "tests/manifest/valid/full.toml" }), &base, .{ .capture = .stdout });
        if (!r.signaled and r.code == 0) {
            rep.same("metadata output", try h.readFile(a, "tests/manifest/valid/full.json"), r.text);
        } else rep.check("metadata accepts tests/manifest/valid/full.toml", false, "refused");
        const bad = "tests/manifest/invalid/duplicate_key";
        const toml = bad ++ ".toml";
        const e = try h.run(a, try c.mopmArgv(&.{ "metadata", toml }), &base, .{ .capture = .stderr });
        rep.check("metadata refuses a duplicate key", !e.signaled and e.code != 0, "accepted");
        const want = try std.fmt.allocPrint(a, "mopm: {s}:{s}", .{ toml, h.chomp(try h.readFile(a, bad ++ ".err")) });
        rep.check("metadata error text", std.mem.eql(u8, want, h.chomp(e.text)), e.text);
    }

    // ---- mopm new / init: the trees they make equal tests/new/{lib,bin}
    {
        const sub = try h.join(a, &.{ work, "new" });
        try std.fs.cwd().makePath(sub);
        const r1 = try h.run(a, try c.mopmArgv(&.{ "new", "demo" }), &base, .{ .cwd = sub });
        exitIs(&rep, "new demo", r1, 0);
        rep.check("new demo: tree equals tests/new/lib", try sameTree(a, "tests/new/lib", try h.join(a, &.{ sub, "demo" })), "trees differ");
        const r2 = try h.run(a, try c.mopmArgv(&.{ "new", "demo" }), &base, .{ .cwd = sub });
        rep.check("new over an existing directory is refused", r2.signaled or r2.code != 0, "accepted");
        const bindir = try h.join(a, &.{ sub, "bin/demo" });
        try std.fs.cwd().makePath(bindir);
        const r3 = try h.run(a, try c.mopmArgv(&.{ "init", "--bin" }), &base, .{ .cwd = bindir });
        exitIs(&rep, "init --bin", r3, 0);
        rep.check("init --bin: tree equals tests/new/bin", try sameTree(a, "tests/new/bin", bindir), "trees differ");
        const r4 = try h.run(a, try c.mopmArgv(&.{ "init", "--bin" }), &base, .{ .cwd = bindir });
        rep.check("init over an existing package is refused", r4.signaled or r4.code != 0, "accepted");
        const r5 = try h.run(a, try c.mopmArgv(&.{ "new", "async" }), &base, .{ .cwd = sub });
        rep.check("new accepts a Mojo keyword as a name", r5.signaled or r5.code != 0, "accepted");
        const made = if (std.fs.cwd().access(try h.join(a, &.{ sub, "async" }), .{})) true else |_| false;
        rep.check("new made a directory for a refused name", !made, "made");
    }

    // ---- build, run, repl --print-cmd on each environment, both spellings
    const oses = [_][]const u8{ "linux", "macos" };
    const cases = [_][]const u8{ "chain", "missing", "dup", "static" };
    for (oses) |os| {
        for (cases) |name| {
            const env = try std.fmt.allocPrint(a, "tests/fixtures/env/{s}/{s}", .{ os, name });
            const g = try std.fmt.allocPrint(a, "tests/golden/cmd/{s}/{s}", .{ os, name });
            const ok_all = std.mem.eql(u8, name, "chain");
            const build_ok = ok_all or std.mem.eql(u8, name, "static");
            try c.cmd(try std.fmt.allocPrint(a, "{s}/{s} build", .{ os, name }), try std.fmt.allocPrint(a, "{s}.build.txt", .{g}), if (build_ok) 0 else 1, &.{ "build", "hello.mojo", "-o", "hello", "--prefix", env, "--os", os, "--print-cmd" }, .{});
            try c.cmd(try std.fmt.allocPrint(a, "{s}/{s} run", .{ os, name }), try std.fmt.allocPrint(a, "{s}.run.txt", .{g}), if (ok_all) 0 else 1, &.{ "run", "hello.mojo", "--prefix", env, "--os", os, "--print-cmd" }, .{});
            try c.cmd(try std.fmt.allocPrint(a, "{s}/{s} repl", .{ os, name }), try std.fmt.allocPrint(a, "{s}.repl.txt", .{g}), if (ok_all) 0 else 1, &.{ "repl", try std.fmt.allocPrint(a, "--prefix={s}", .{env}), try std.fmt.allocPrint(a, "--os={s}", .{os}), "--print-cmd" }, .{});
        }
    }

    // A library the metadata names but the environment lacks.
    try c.cmd("linux/nofile build", "tests/golden/cmd/linux/nofile.build.txt", 1, &.{ "build", "hello.mojo", "-o", "hello", "--prefix", "tests/fixtures/env/linux/nofile", "--os", "linux", "--print-cmd" }, .{});

    // Where the environment comes from: --prefix, then CONDA_PREFIX, then
    // MODULAR_HOME. Each source points at the chain environment while every
    // lower-ranked one points at the dup environment, which is refused, so a
    // wrong order changes the output.
    const chain = try std.fmt.allocPrint(a, "{s}/tests/fixtures/env/linux/chain", .{root});
    const dup = try std.fmt.allocPrint(a, "{s}/tests/fixtures/env/linux/dup", .{root});
    const dup_home = try std.fmt.allocPrint(a, "{s}/share/max", .{dup});
    const chain_home = try std.fmt.allocPrint(a, "{s}/share/max", .{chain});
    const g_repl = "tests/golden/cmd/linux/chain.repl.txt";
    try c.cmd("prefix: --prefix beats both variables", g_repl, 0, &.{ "repl", "--prefix", chain, "--os", "linux", "--print-cmd" }, .{ .set = &.{ .{ "CONDA_PREFIX", dup }, .{ "MODULAR_HOME", dup_home } } });
    try c.cmd("prefix: CONDA_PREFIX beats MODULAR_HOME", g_repl, 0, &.{ "repl", "--os", "linux", "--print-cmd" }, .{ .set = &.{ .{ "CONDA_PREFIX", chain }, .{ "MODULAR_HOME", dup_home } } });
    try c.cmd("prefix: MODULAR_HOME minus /share/max", g_repl, 0, &.{ "repl", "--os", "linux", "--print-cmd" }, .{ .set = &.{.{ "MODULAR_HOME", chain_home }} });
    try c.cmd("prefix: an empty CONDA_PREFIX counts as unset", g_repl, 0, &.{ "repl", "--os", "linux", "--print-cmd" }, .{ .set = &.{ .{ "CONDA_PREFIX", "" }, .{ "MODULAR_HOME", chain_home } } });
    try c.cmd("prefix: none", "tests/golden/cmd/no_prefix.txt", 1, &.{ "repl", "--os", "linux", "--print-cmd" }, .{});
    try c.cmd("prefix: MODULAR_HOME of another shape", "tests/golden/cmd/bad_modular_home.txt", 1, &.{ "repl", "--os", "linux", "--print-cmd" }, .{ .set = &.{.{ "MODULAR_HOME", chain }} });
    try c.cmd("prefix: not a Mojo environment", "tests/golden/cmd/not_mojo_env.txt", 1, &.{ "repl", "--prefix", "tests/fixtures/env", "--os", "linux", "--print-cmd" }, .{});

    // Without --print-cmd mopm execs <prefix>/bin/mojo. The stand-in exits 7,
    // so exit 7 means mopm handed over mojo's status. Its MODULAR_HOME must
    // be the prefix's even when the caller's points elsewhere; other
    // variables pass.
    const host = switch (@import("builtin").os.tag) {
        .macos => "macos",
        else => "linux",
    };
    try c.cmd("exec: run", "tests/golden/exec/run.txt", 7, &.{ "run", "hello.mojo", "--prefix", stand_in_real }, .{ .set = &.{ .{ "MODULAR_HOME", dup_home }, .{ "MOPM_GOLDEN_MARK", "kept" } } });
    try c.cmd("exec: build", try std.fmt.allocPrint(a, "tests/golden/exec/build.{s}.txt", .{host}), 7, &.{ "build", "hello.mojo", "-o", "hello", "--prefix", stand_in_real }, .{});
    try c.cmd("exec: repl reads stdin", try std.fmt.allocPrint(a, "tests/golden/exec/repl.{s}.txt", .{host}), 7, &.{ "repl", "--prefix", stand_in_real }, .{ .stdin = "tests/golden/exec/repl.stdin" });
    try c.cmd("exec: no bin/mojo in the environment", "tests/golden/exec/no_mojo.txt", 127, &.{ "run", "hello.mojo", "--prefix", chain }, .{});
    {
        const r = try h.run(a, try c.mopmArgv(&.{ "run", "hello.mojo", "--prefix", stand_in_real, "--os", "linux" }), &base, .{});
        const first = std.mem.sliceTo(r.text, '\n');
        rep.check("exec: --os without --print-cmd is a usage error", !r.signaled and r.code == 2 and h.contains(first, "--os applies only with --print-cmd"), r.text);
    }

    // ---- mopm test --list, and the refusals of `mopm test` that need no Mojo
    const g = "tests/golden/test";
    try c.cmd("test --list: a package root", g ++ "/tree.txt", 0, &.{ "test", "--list", "tests/discovery/tree" }, .{});
    try c.cmd("test --list: a file under the root named again is listed once", g ++ "/tree.txt", 0, &.{ "test", "--list", "tests/discovery/tree", "tests/discovery/tree/tests/test_bare.mojo" }, .{});
    {
        const tree = try h.join(a, &.{ root, "tests/discovery/tree" });
        const r = try h.run(a, try c.mopmArgv(&.{ "test", "--list" }), &base, .{ .cwd = tree });
        const want = try h.readFile(a, g ++ "/tree_dot.txt");
        rep.check("test --list: the current directory", !r.signaled and r.code == 0 and std.mem.eql(u8, want, r.text), r.text);
    }
    try c.cmd("test --list: explicit files", g ++ "/files.txt", 0, &.{ "test", "--list", "tests/discovery/self_hosted_explicit.mojo", "tests/discovery/bare_basic.mojo" }, .{});
    try c.cmd("test --list: nonconforming tests are refused", g ++ "/nonconforming.txt", 2, &.{ "test", "--list", "tests/discovery/nonconforming.mojo", "tests/discovery/bare_basic.mojo" }, .{});
    try c.cmd("test --list: a self-hosted file without readable registrations", g ++ "/self_hosted_none.txt", 0, &.{ "test", "--list", "tests/discovery/self_hosted_none.mojo" }, .{});
    try c.cmd("test --list: --prefix without --check", g ++ "/check_only.txt", 2, &.{ "test", "--list", "--prefix", "/nowhere" }, .{});
    try c.cmd("test --list: a flag that applies only to running tests", g ++ "/list_run_flag.txt", 2, &.{ "test", "--list", "--timeout", "5" }, .{});
    try c.cmd("test: running with no environment", g ++ "/no_env.txt", 5, &.{ "test", "--prefix", "/nowhere", "tests/discovery/tree" }, .{});
    try c.cmd("test: no tests at all", g ++ "/no_tests.txt", 2, &.{ "test", "tests/discovery/none.mojo" }, .{});
    try c.cmd("test: no tests at all, --allow-empty", g ++ "/empty.txt", 0, &.{ "test", "--allow-empty", "tests/discovery/none.mojo" }, .{});
    try c.cmd("test --list: a path that does not exist", g ++ "/missing.txt", 2, &.{ "test", "--list", "tests/discovery/no_such_dir" }, .{});

    // Selection over the fixture package of tests/drivers/test_flaky_test.zig.
    const fx = "tests/e2e/flaky";
    const fxt = fx ++ "/tests";
    try c.cmd("test --list: no filter (the ignored test is not listed)", g ++ "/filter_none.txt", 0, &.{ "test", "--list", fx }, .{});
    try c.cmd("test --list: a substring of <file>::<test>", g ++ "/filter_substring.txt", 0, &.{ "test", "--list", fx, "--", "alpha" }, .{});
    try c.cmd("test --list: globs, on the name or the whole id", g ++ "/filter_glob.txt", 0, &.{ "test", "--list", fx, "--", "test_?eta", fxt ++ "/sub/*::test_g*" }, .{});
    try c.cmd("test --list: --exact takes the whole id", g ++ "/filter_exact.txt", 0, &.{ "test", "--list", "--exact", fx, "--", fxt ++ "/test_names.mojo::test_alpha_one" }, .{});
    try c.cmd("test --list: --exact with a bare name selects nothing", g ++ "/filter_exact_name.txt", 0, &.{ "test", "--list", "--exact", fx, "--", "test_alpha_one" }, .{});
    try c.cmd("test --list: --skip, twice", g ++ "/filter_skip.txt", 0, &.{ "test", "--list", fx, "--skip", "alpha", "--skip=fails" }, .{});
    try c.cmd("test --list: --ignored lists only the ignored test", g ++ "/filter_ignored.txt", 0, &.{ "test", "--list", "--ignored", fx }, .{});
    try c.cmd("test --list: --include-ignored with patterns", g ++ "/filter_include_ignored.txt", 0, &.{ "test", "--list", "--include-ignored", fx, "--", "ignored", "steady" }, .{});
    try c.cmd("test: patterns that leave nothing to run", g ++ "/filter_none_selected.txt", 2, &.{ "test", "--ignored", fx, "--", "alpha" }, .{});
    try c.cmd("test: only an ignored test selected (SKIP, nothing to run)", g ++ "/filter_only_ignored.txt", 2, &.{ "test", fx, "--", "ignored" }, .{});
    try c.cmd("test: only an ignored test selected, --allow-empty", g ++ "/filter_only_ignored_allow.txt", 0, &.{ "test", "--allow-empty", fx, "--", "ignored" }, .{});

    {
        const v = try h.run(a, try c.mopmArgv(&.{"--version"}), &base, .{ .capture = .stdout });
        rep.check("--version", std.mem.eql(u8, h.chomp(v.text), "mopm 0.0.1"), v.text);
        // A planned command exits non-zero and says it is not implemented.
        const p = try h.run(a, try c.mopmArgv(&.{"cov"}), &base, .{});
        rep.check("planned command should exit non-zero", p.signaled or p.code != 0, "exit 0");
        rep.check("planned command message", h.contains(p.text, "not implemented yet"), p.text);
    }

    try rep.finish();
}
