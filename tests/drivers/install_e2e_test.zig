//! End-to-end test of `mopm sync` against mopm-fake-registry and the real
//! Mojo toolchain: the Zig port of tests/install_e2e/run.py, for the build
//! farm (no pixi, no network, no system C compiler).
//!
//! What it does:
//!   1. builds libgreet (tests/e2e/native/greet.c, with `cc` = komira's zig)
//!      and precompiles the Mojo package greet (tests/e2e/pkgs/greet) with the
//!      pinned Mojo 1.0.0;
//!   2. packs them into a real conda package, mojo-greet-1.0.0-mojo1.0.0_0.conda,
//!      laid out as spec/channel.md says (lib/mojo/greet.mojoc,
//!      lib/mojo/greet.mopm.json, lib/libgreet.so; a zip of two zstd'd tars),
//!      and serves it from the fake registry with its sparse index line and
//!      repodata.json entry;
//!   3. in a project whose mopm.toml needs greet = "1", runs `mopm sync`, which
//!      locks, downloads, verifies and installs the package and the toolchain
//!      closure into .mopm/env by itself;
//!   4. builds tests/install_e2e/prog.mojo with `mopm build --prefix .mopm/env`
//!      and runs the binary in an empty environment, and runs it with `mopm
//!      run` (with no --prefix: mopm finds .mopm/env): both must print "greet
//!      4242", which only libgreet computes.
//!
//! The farm cannot download the pinned toolchain closure, so sync is given
//! `--toolchain` with a stand-in closure the fake serves (conda_pkg.zig
//! `fakeToolchain`), and the driver lays the real Mojo toolchain into
//! .mopm/env after the sync (mojo_env.zig `prefix`). What the real closure
//! installs is exercised where there is a network: the mojo-e2e job of ci.yml
//! makes its Mojo environment with `mopm sync --locked` in tests/mojo_env.
//! tests/drivers/sync_e2e_test.zig holds the install itself to its properties
//! (no pixi, a current environment downloads nothing, a mirror, a whole
//! environment or the old one) on every pull request.
//!
//! Can-fail checks (each is a refusal the test must see):
//!   * a stale lock: mopm.toml changed after locking (a requirement the locked
//!     version does not meet, a new dependency, a removed one, another
//!     toolchain) makes `mopm sync --locked` fail, naming the drift, and leaves
//!     mopm.lock as it was;
//!   * a tampered artifact: the channel's .conda is replaced by bytes of the
//!     same size with one byte changed, then by bytes one longer. `mopm sync
//!     --locked` must refuse each, naming the pinned and the actual value, must
//!     not keep the file, and must make no environment. A file kept from an
//!     earlier download that was then tampered with must not be used either.
//!     With the original bytes back, the same sync succeeds, so the refusals
//!     came from the bytes and nothing else.
//!
//! A path dependency (`local = { path = "local" }`) is locked with
//! `source = path`, its own mopm.toml's version and no sha256; sync must not
//! download it (it has no url, so a download would fail) nor install it, and
//! must see a lock that holds an older version of it as stale.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const cp = @import("conda_pkg.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const mojo_version = "1.0.0";
const build_tag = "mojo" ++ mojo_version ++ "_0";
const env_rel = ".mopm/env";
const filename = "mojo-greet-1.0.0-" ++ build_tag ++ ".conda";

const sha256Hex = cp.sha256Hex;

/// The bytes of mojo-greet-1.0.0-<build>.conda holding `files`.
fn condaPackage(a: Allocator, subdir: []const u8, files: []const cp.Entry) ![]u8 {
    return cp.package(a, "mojo-greet", "1.0.0", build_tag, subdir, &.{"mojo-compiler ==" ++ mojo_version}, files);
}

// ------------------------------------------------------------ the driver

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    /// The stand-in toolchain closure, and the cache sync keeps its files in.
    toolchain: []const u8 = "",
    cache: []const u8 = "",
    work: []const u8,
    here: []const u8,
    subdir: []const u8,
    fake_dir: []const u8,
    base: []const u8,
    calls: usize = 0,

    const Out = struct { code: u8, signaled: bool, stdout: []u8, stderr: []u8 };

    /// `mopm <args>` in `dir`, standard output and standard error apart.
    fn run(c: *Ctx, dir: []const u8, args: []const []const u8) !Out {
        c.calls += 1;
        const errf = try h.fmt(c.a, "{s}/stderr.{d}", .{ c.work, c.calls });
        var env = try c.m.freshEnv();
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        const r = try h.run(c.a, argv, &env, .{ .cwd = dir, .capture = .stdout, .stderr_path = errf });
        return .{ .code = r.code, .signaled = r.signaled, .stdout = r.text, .stderr = try h.readFile(c.a, errf) };
    }

    fn sync(c: *Ctx, dir: []const u8, extra: []const []const u8) !Out {
        var args = std.ArrayList([]const u8).init(c.a);
        try args.appendSlice(&.{ "sync", "--toolchain", c.toolchain, "--cache", c.cache });
        try args.appendSlice(extra);
        return c.run(dir, args.items);
    }

    fn project(c: *Ctx, name: []const u8, deps: []const u8, mojo: []const u8) ![]u8 {
        const d = try h.join(c.a, &.{ c.work, "proj", name });
        try fs.cwd().makePath(d);
        try h.writeFile(try h.join(c.a, &.{ d, "mopm.toml" }), try h.fmt(c.a,
            \\[package]
            \\name = "app"
            \\version = "0.1.0"
            \\
            \\[toolchain]
            \\mojo = "{s}"
            \\
            \\[dependencies]
            \\{s}
            \\
        , .{ mojo, deps }));
        try fs.cwd().copyFile(try h.join(c.a, &.{ c.here, "tests/install_e2e/prog.mojo" }), fs.cwd(), try h.join(c.a, &.{ d, "prog.mojo" }), .{});
        return d;
    }

    fn read(c: *Ctx, dir: []const u8, rel: []const u8) ?[]u8 {
        return h.readFile(c.a, h.join(c.a, &.{ dir, rel }) catch return null) catch null;
    }

    fn exists(c: *Ctx, dir: []const u8, rel: []const u8) bool {
        const p = h.join(c.a, &.{ dir, rel }) catch return false;
        return if (fs.cwd().access(p, .{})) true else |_| false;
    }

    /// The channel's copy of the package, replaced by `data`.
    fn serve(c: *Ctx, data: []const u8) !void {
        try h.writeFile(try h.fmt(c.a, "{s}/channel/{s}/{s}", .{ c.fake_dir, c.subdir, filename }), data);
    }

    fn detail(c: *Ctx, r: Out) []const u8 {
        return h.fmt(c.a, "exit {d}{s}\n{s}\n{s}", .{ r.code, if (r.signaled) " (signal)" else "", r.stdout, r.stderr }) catch "";
    }
};

/// greet 1.0.0 in the fake's sparse index and channel (spec/index.md,
/// spec/channel.md), as its data directory serves them.
fn publish(c: *Ctx, data: []const u8, soname: []const u8) !void {
    const a = c.a;
    const sha = try sha256Hex(a, data);
    const manifest_sha = try sha256Hex(a, "greet manifest");
    const rec = try h.fmt(a,
        \\{{"build":"{s}","deps":[],"files":[{{"filename":"{s}","sha256":"{s}","size":{d},"subdir":"{s}","url":"{s}/channel/{s}/{s}"}}],"manifest_sha256":"{s}","name":"greet","native":[{{"id":"greet","soname":"{s}"}}],"published_at":"2026-10-14T12:00:00Z","requires_mojo":"=={s}","state":"published","v":1,"version":"1.0.0"}}
        \\
    , .{ build_tag, filename, sha, data.len, c.subdir, c.base, c.subdir, filename, manifest_sha, soname, mojo_version });
    const index = try h.join(a, &.{ c.fake_dir, "index/gr/ee" });
    try fs.cwd().makePath(index);
    try h.writeFile(try h.join(a, &.{ index, "greet" }), rec);
    const repodata = try h.fmt(a,
        \\{{"info":{{"subdir":"{s}"}},"packages":{{}},"packages.conda":{{"{s}":{{"build":"{s}","build_number":0,"depends":["mojo-compiler =={s}"],"name":"mojo-greet","sha256":"{s}","size":{d},"subdir":"{s}","version":"1.0.0"}}}},"removed":[]}}
        \\
    , .{ c.subdir, filename, build_tag, mojo_version, sha, data.len, c.subdir });
    try fs.cwd().makePath(try h.fmt(a, "{s}/channel/{s}", .{ c.fake_dir, c.subdir }));
    try h.writeFile(try h.fmt(a, "{s}/channel/{s}/repodata.json", .{ c.fake_dir, c.subdir }), repodata);
    try c.serve(data);
}

test "mopm sync installs from the fake registry; build and run use it; tampering and stale locks are refused (tests/install_e2e/run.py)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    run(a, &rep) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const m = try mojo_env.Mojo.init(a);
    const subdir = switch (builtin.cpu.arch) {
        .x86_64 => "linux-64",
        .aarch64 => "linux-aarch64",
        else => return error.UnsupportedHost,
    };
    const work = try h.join(a, &.{ m.work, "install_e2e" });
    try fs.cwd().makePath(work);
    const fake_dir = try h.join(a, &.{ work, "fake" });
    const fake_exe = try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY");

    // 1. libgreet and greet.mojoc, as tests/drivers/test_autolink_test.zig builds them.
    var c = Ctx{
        .a = a,
        .rep = rep,
        .m = m,
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .work = work,
        .here = m.work,
        .subdir = subdir,
        .fake_dir = fake_dir,
        .base = "",
    };
    const soname = "libgreet.so";
    const lib = try h.join(a, &.{ work, soname });
    const cc = try m.cc(&.{ "-shared", "-fPIC", "-Wl,-soname," ++ soname, "-o", lib, try h.join(a, &.{ c.here, "tests/e2e/native/greet.c" }) });
    if (cc.signaled or cc.code != 0) {
        rep.check("cc libgreet", false, cc.text);
        return error.Fatal;
    }
    const toolenv = try h.join(a, &.{ work, "toolenv" });
    try m.prefix(toolenv, true);
    const mojoc = try h.join(a, &.{ work, "greet.mojoc" });
    const pc = try m.run(toolenv, &.{ "precompile", try h.join(a, &.{ c.here, "tests/e2e/pkgs/greet" }), "-o", mojoc }, null);
    if (pc.signaled or pc.code != 0) {
        rep.check("mojo precompile greet", false, pc.text);
        return error.Fatal;
    }

    // 2. the package
    const lib_bytes = try h.readFile(a, lib);
    const mojoc_bytes = try h.readFile(a, mojoc);
    const meta = try h.fmt(a, "{{\"deps\": [], \"name\": \"greet\", \"native\": [{{\"file\": \"../{s}\", \"id\": \"greet\", \"soname\": \"{s}\"}}], \"schema\": 1, \"version\": \"1.0.0\"}}\n", .{ soname, soname });
    const good = try condaPackage(a, subdir, &.{
        .{ .path = "lib/mojo/greet.mojoc", .data = mojoc_bytes, .mode = 0o644 },
        .{ .path = "lib/mojo/greet.mopm.json", .data = meta, .mode = 0o644 },
        .{ .path = "lib/" ++ soname, .data = lib_bytes, .mode = 0o755 },
    });
    const good_sha = try sha256Hex(a, good);
    std.debug.print("     {s}: {d} bytes, sha256 {s}\n", .{ filename, good.len, good_sha });

    var fake = try h.Fake.start(a, fake_exe, fake_dir);
    defer fake.close();
    c.base = fake.base;
    try publish(&c, good, soname);
    c.toolchain = (try cp.fakeToolchain(a, fake_dir, fake.base, "channel/toolchain", subdir, mojo_version, try h.join(a, &.{ work, "toolchain.json" }), "T")).closure;
    c.cache = try h.join(a, &.{ work, "cache" });
    const reg = [_][]const u8{ "--registry", fake.base };

    const app = try c.project("app", "greet = \"1\"", mojo_version);

    var r = try c.sync(app, &.{"--locked"});
    rep.check("sync --locked without a lock fails and installs nothing", r.code == 1 and h.contains(r.stderr, "--locked: there is no mopm.lock") and !c.exists(app, ".mopm"), c.detail(r));

    // ------------------------------------------------ lock, install, build, run
    r = try c.sync(app, &reg);
    const installed_msg = try h.fmt(a, "installed 1 packages for {s}", .{subdir});
    rep.check("sync locks and installs", r.code == 0 and h.contains(r.stdout, installed_msg), c.detail(r));
    const lock = c.read(app, "mopm.lock") orelse "";
    rep.check("the lock pins the package's bytes", h.contains(lock, try h.fmt(a, "\"sha256\": \"{s}\"", .{good_sha})) and h.contains(lock, try h.fmt(a, "\"size\": {d}", .{good.len})), lock);
    rep.check("sync keeps exactly the locked bytes in .mopm/pkgs", std.mem.eql(u8, c.read(app, ".mopm/pkgs/" ++ filename) orelse "", good), "missing or other bytes");
    {
        const rec = c.read(app, env_rel ++ "/conda-meta/mojo-greet-1.0.0-" ++ build_tag ++ ".json");
        var ok = false;
        if (rec) |text| {
            const v = h.parseJson(a, text) catch .null;
            ok = std.mem.eql(u8, h.jsonString(v, "sha256") orelse "", good_sha);
        }
        rep.check("sync installed exactly the locked file", ok, rec orelse "no conda-meta record");
    }
    for ([_][]const u8{ "lib/mojo/greet.mojoc", "lib/mojo/greet.mopm.json", "lib/" ++ soname }) |p| {
        rep.check(try h.fmt(a, "installed: {s}", .{p}), c.exists(app, try h.join(a, &.{ env_rel, p })), "missing");
    }

    // The real Mojo toolchain goes into the environment (sync installed the
    // stand-in closure there), then mopm build and run use it.
    try m.prefix(try h.join(a, &.{ app, env_rel }), true);
    {
        const out = try h.join(a, &.{ app, "prog" });
        var b = try c.run(app, &.{ "build", "prog.mojo", "-o", out, "--prefix", env_rel });
        rep.check("mopm build links the installed native library", b.code == 0 and !b.signaled, c.detail(b));
        if (b.code == 0 and !b.signaled) {
            var empty = std.process.EnvMap.init(a);
            const run_out = try h.run(a, &.{out}, &empty, .{});
            rep.check("the binary, in an empty environment, prints greet 4242", run_out.code == 0 and !run_out.signaled and h.contains(run_out.text, "greet 4242"), run_out.text);
        }
        // No --prefix, no CONDA_PREFIX, no MODULAR_HOME: mopm run finds the environment sync made.
        b = try c.run(app, &.{ "run", "prog.mojo" });
        rep.check("mopm run with no --prefix uses .mopm/env and prints greet 4242", b.code == 0 and h.contains(b.stdout, "greet 4242"), c.detail(b));
    }

    r = try c.sync(app, &.{"--locked"});
    rep.check("sync --locked with a fresh lock finds the environment current and leaves the lock alone", r.code == 0 and h.contains(r.stdout, ".mopm/env is current: 1 packages for ") and
        std.mem.eql(u8, c.read(app, "mopm.lock") orelse "", lock) and c.exists(app, env_rel ++ "/bin/mojo"), c.detail(r));

    // ------------------------------------------------ stale locks
    const Stale = struct { what: []const u8, deps: []const u8, mojo: []const u8, want: []const u8 };
    const stale = [_]Stale{
        .{ .what = "a requirement the locked version does not meet", .deps = "greet = \"2\"", .mojo = mojo_version, .want = "mopm.lock is out of date with mopm.toml: mopm.toml needs greet \"2\", but mopm.lock has greet 1.0.0" },
        .{ .what = "a new dependency", .deps = "greet = \"1\"\nother = \"1\"", .mojo = mojo_version, .want = "mopm.lock is out of date with mopm.toml: mopm.toml needs other, which mopm.lock does not lock" },
        .{ .what = "a removed dependency", .deps = "", .mojo = mojo_version, .want = "mopm.lock is out of date with mopm.toml: mopm.lock locks greet 1.0.0, which nothing in mopm.toml needs" },
        .{ .what = "another toolchain", .deps = "greet = \"1\"", .mojo = "1.1.0", .want = "mopm.lock is out of date with mopm.toml: mopm.lock is for mojo 1.0.0; mopm.toml's [toolchain] allows 1.1.0" },
    };
    for (stale) |s| {
        _ = try c.project("app", s.deps, s.mojo);
        r = try c.sync(app, &.{"--locked"});
        rep.check(try h.fmt(a, "stale lock ({s}): sync --locked fails, naming it", .{s.what}), r.code == 1 and h.contains(r.stderr, s.want) and std.mem.eql(u8, c.read(app, "mopm.lock") orelse "", lock), c.detail(r));
    }
    _ = try c.project("app", "greet = \"1\"", mojo_version);

    // ------------------------------------------------ tampered artifacts
    const flipped = try a.dupe(u8, good);
    flipped[flipped.len / 2] ^= 0x01;
    const longer = try std.mem.concat(a, u8, &.{ good, "\x00" });
    const fresh = try c.project("fresh", "greet = \"1\"", mojo_version);
    try fs.cwd().copyFile(try h.join(a, &.{ app, "mopm.lock" }), fs.cwd(), try h.join(a, &.{ fresh, "mopm.lock" }), .{});
    const kept_rel = ".mopm/pkgs/" ++ filename;
    const url = try h.fmt(a, "{s}/channel/{s}/{s}", .{ c.base, subdir, filename });
    const Tamper = struct { what: []const u8, data: []const u8, want: []const u8 };
    const tampers = [_]Tamper{
        .{ .what = "one byte changed", .data = flipped, .want = try h.fmt(a, "mopm sync: {s} has sha256 {s}; the pin says {s}; refused\n", .{ url, try sha256Hex(a, flipped), good_sha }) },
        .{ .what = "one byte longer", .data = longer, .want = try h.fmt(a, "mopm sync: {s} is larger than the pinned {d} bytes; refused\n", .{ url, good.len }) },
    };
    for (tampers) |t| {
        try c.serve(t.data);
        r = try c.sync(fresh, &.{"--locked"});
        rep.check(try h.fmt(a, "tampered artifact ({s}): sync --locked refuses it", .{t.what}), r.code == 1 and h.contains(r.stderr, t.want), c.detail(r));
        rep.check(try h.fmt(a, "tampered artifact ({s}): the file is not kept and no environment is made", .{t.what}), !c.exists(fresh, kept_rel) and !c.exists(fresh, env_rel), "the file was kept or .mopm/env exists");
    }

    // A file kept from an earlier download, tampered with afterwards, is not
    // used: it is downloaded again (and the channel's copy is tampered too).
    try c.serve(flipped);
    try fs.cwd().makePath(try h.join(a, &.{ fresh, ".mopm/pkgs" }));
    try h.writeFile(try h.join(a, &.{ fresh, kept_rel }), flipped);
    r = try c.sync(fresh, &.{"--locked"});
    rep.check("tampered kept file: sync --locked does not use it", r.code == 1 and h.contains(r.stderr, try h.fmt(a, "; the pin says {s}; refused", .{good_sha})) and !c.exists(fresh, env_rel), c.detail(r));

    // Control: the same sync with the original bytes back succeeds.
    try c.serve(good);
    r = try c.sync(fresh, &.{"--locked"});
    rep.check("control: with the original bytes the same sync --locked succeeds", r.code == 0 and std.mem.eql(u8, c.read(fresh, kept_rel) orelse "", good), c.detail(r));

    // ------------------------------------------------ a path dependency
    // Locked as source = path with its own version and no file; sync uses it
    // from its directory and never downloads it (it has no url: a download
    // would fail the sync).
    const withpath = try c.project("withpath", "greet = \"1\"\nlocal = { path = \"local\" }", mojo_version);
    try localVersion(&c, withpath, "0.2.0");
    r = try c.sync(withpath, &reg);
    {
        const lock_text = c.read(withpath, "mopm.lock") orelse "{\"packages\": []}";
        const parsed = h.parseJson(a, lock_text) catch .null;
        var local_ok = false;
        if (parsed == .object) if (parsed.object.get("packages")) |pk| if (pk == .array) for (pk.array.items) |p| {
            if (!std.mem.eql(u8, h.jsonString(p, "name") orelse "", "local")) continue;
            // exactly {name, version, source, path}: no sha256, no url
            local_ok = p.object.count() == 4 and std.mem.eql(u8, h.jsonString(p, "version") orelse "", "0.2.0") and
                std.mem.eql(u8, h.jsonString(p, "source") orelse "", "path") and std.mem.eql(u8, h.jsonString(p, "path") orelse "", "local");
        };
        rep.check("sync with a path dependency locks it as source path, with no sha256, and installs the rest", r.code == 0 and local_ok and
            h.contains(r.stdout, "using local 0.2.0 from local (a path dependency: built from source, not downloaded)\n") and h.contains(r.stdout, installed_msg), c.detail(r));
    }
    {
        var names = std.ArrayList([]const u8).init(a);
        if (fs.cwd().openDir(try h.join(a, &.{ withpath, ".mopm/pkgs" }), .{ .iterate = true })) |d0| {
            var d = d0;
            defer d.close();
            var it = d.iterate();
            while (try it.next()) |e| try names.append(try a.dupe(u8, e.name));
        } else |_| {}
        h.sortStrings(names.items);
        rep.check("the path dependency is neither downloaded nor installed", h.eqlStrings(names.items, &.{filename}) and
            c.exists(withpath, env_rel ++ "/lib/mojo/greet.mopm.json") and !c.exists(withpath, env_rel ++ "/lib/mojo/local.mopm.json"), "the kept files or the environment hold the path dependency, or greet is missing");
    }
    const locked = c.read(withpath, "mopm.lock") orelse "";
    try localVersion(&c, withpath, "0.2.1");
    r = try c.sync(withpath, &.{"--locked"});
    rep.check("a path dependency's new version makes the lock stale for sync --locked", r.code == 1 and
        h.contains(r.stderr, "mopm.lock is out of date with mopm.toml: local/mopm.toml says local 0.2.1, but mopm.lock has local 0.2.0") and
        std.mem.eql(u8, c.read(withpath, "mopm.lock") orelse "", locked), c.detail(r));
    r = try c.sync(withpath, &reg);
    rep.check("sync relocks the path dependency's new version and installs", r.code == 0 and h.contains(r.stdout, "updating local 0.2.0 -> 0.2.1\n") and h.contains(r.stdout, "using local 0.2.1 from local"), c.detail(r));
}

fn localVersion(c: *Ctx, withpath: []const u8, v: []const u8) !void {
    const d = try h.join(c.a, &.{ withpath, "local" });
    try fs.cwd().makePath(d);
    try h.writeFile(try h.join(c.a, &.{ d, "mopm.toml" }), try h.fmt(c.a, "[package]\nname = \"local\"\nversion = \"{s}\"\n", .{v}));
}
