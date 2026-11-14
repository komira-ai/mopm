//! Where `mopm sync` keeps the files it downloads, and what else it installs from them. The built CLI against
//! mopm-fake-registry with the stand-in toolchain (sync_fixture.zig). Run by Buck2 as //:sync_cache_e2e on every pull
//! request. The environments of the failure cases are compared by fingerprint (kind, link target, executable bit and
//! bytes of every entry).
//!
//! What can go red, and why:
//! - the lock's `system_libs` for the host's subdir are installed with the toolchain (a conda-meta record and the
//!   library file), from the cache, and the next sync finds the environment current;
//! - a lock library with the name of a toolchain package and other bytes takes that package's place and a warning on
//!   stderr says so; one whose url is not an https `.conda` file is refused, the environment as it was;
//! - `--cache` that is `.mopm/env`, inside it, or reaches it through a symbolic link is refused with nothing created
//!   and the environment unchanged;
//! - without `--cache` the directory is `$XDG_CACHE_HOME/mopm/pkgs` when that is set and not empty, else
//!   `$HOME/.cache/mopm/pkgs`; `--cache` wins over both; with neither the sync says so; a `--cache` that cannot be a
//!   directory is reported by name and error;
//! - the cache is content addressed (`<cache>/<sha256>/<file>`): two projects whose toolchains have a file of the same
//!   name and other bytes share a cache without sharing an entry, and the second install of the first project needs no
//!   download.

const std = @import("std");
const h = @import("harness.zig");
const cp = @import("conda_pkg.zig");
const fx = @import("sync_fixture.zig");
const fs = std.fs;

const mojo = fx.mojo;
const build_tag = fx.build_tag;

/// Whether both files of the toolchain `t` are in `root` as `<sha256>/<file name>`.
fn holds(c: *fx.Cx, root: []const u8, t: cp.Toolchain) bool {
    for (t.files) |f| {
        if (!c.exists(root, c.fmt("{s}/{s}", .{ f.sha256, f.file_name }) catch return false)) return false;
    }
    return true;
}

test "the lock's system libraries are installed with the toolchain, from the cache, and the next sync is current" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    const lib_bytes = "the shared library libfoo 1.2.3\n";
    const lib_pkg = try cp.package(a, "libfoo", "1.2.3", "h0_0", c.subdir, &.{}, &.{.{ .path = "lib/libfoo.so.1", .data = lib_bytes, .mode = 0o755 }});
    const lib_sha = try cp.sha256Hex(a, lib_pkg);
    const lib_file = "libfoo-1.2.3-h0_0.conda";
    // The lock's urls are https; this lock's file is in the cache already, so the url is never fetched.
    const lib_json = try c.fmt("{{\"{s}\": [{{\"name\": \"libfoo\", \"version\": \"1.2.3\", \"build\": \"h0_0\", \"url\": \"https://conda.example/pkgs/{s}/{s}\", \"sha256\": \"{s}\", \"size\": {d}}}]}}", .{ c.subdir, c.subdir, lib_file, lib_sha, lib_pkg.len });
    var v = try c.lockValue(b.app);
    try v.object.put("system_libs", try h.parseJson(a, lib_json));
    try c.writeLockValue(b.app, v);
    try fs.cwd().makePath(c.path(&.{ b.cache, lib_sha }));
    try h.writeFile(c.path(&.{ b.cache, lib_sha, lib_file }), lib_pkg);

    const before = try c.served();
    var r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("sync installs the library the lock pins, with greet and the toolchain", r.code == 0 and r.stderr.len == 0 and
        h.contains(r.stdout, try c.fmt("installed 1 packages for {s} (mojo {s}, 2 toolchain files) into .mopm/env\n", .{ c.subdir, mojo })), c.detail(r));
    const record = c.read(b.env_dir, "conda-meta/libfoo-1.2.3-h0_0.json") orelse "";
    const rv = h.parseJson(a, record) catch std.json.Value{ .null = {} };
    rep.check("the library has a conda-meta record with its pinned sha256 and its url", std.mem.eql(u8, h.jsonString(rv, "sha256") orelse "", lib_sha) and
        std.mem.eql(u8, h.jsonString(rv, "url") orelse "", try c.fmt("https://conda.example/pkgs/{s}/{s}", .{ c.subdir, lib_file })), record);
    rep.check("the library file is in the environment, executable, and nothing was downloaded for it", std.mem.eql(u8, c.read(b.env_dir, "lib/libfoo.so.1") orelse "", lib_bytes) and
        try c.served() == before, try c.names(c.path(&.{ b.env_dir, "lib" })));
    const print = try c.fingerprint(b.env_dir);
    rep.check("the library's file carries its executable bit", h.contains(print, "file lib/libfoo.so.1 exec=true "), print);

    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("a second sync finds the environment with the library current", r.code == 0 and r.stderr.len == 0 and h.contains(r.stdout, ".mopm/env is current: 1 packages for") and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), print), c.detail(r));

    // The library's record gone: the stamp matches, the environment does not, and sync says which.
    try fs.cwd().deleteFile(c.path(&.{ b.env_dir, "conda-meta/libfoo-1.2.3-h0_0.json" }));
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.same("a missing record of the library: stderr names it", "mopm sync: .mopm/env does not match its stamp (the system library libfoo 1.2.3 is not installed: no conda-meta/libfoo-1.2.3-h0_0.json); installing it again\n", r.stderr);
    rep.check("a missing record of the library is written again", r.code == 0 and std.mem.eql(u8, try c.fingerprint(b.env_dir), print), c.detail(r));
    try rep.finish();
}

test "--cache inside .mopm/env, equal to it, or reaching it through a symbolic link is refused with nothing created" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    const link = c.path(&.{ c.work, "into-env" });
    try fs.cwd().symLink(b.env_dir, link, .{ .is_directory = true });
    const inside = c.path(&.{ b.env_dir, "kept-files" });
    // In the project: a component that does not exist, `..` back out of it, then a symbolic link into the environment.
    try fs.cwd().symLink(b.env_dir, c.path(&.{ b.app, "into-env" }), .{ .is_directory = true });
    const cases = [_][]const u8{ inside, b.env_dir, c.path(&.{ link, "deeper", "still" }), link, ".mopm/env/relative", ".mopm/../.mopm/env", "newpart/../into-env/cache" };
    for (cases) |cache| {
        const r = try c.run(b.app, &.{ "sync", "--locked", "--toolchain", b.t2.closure, "--cache", cache });
        const want = try c.fmt("mopm sync: --cache {s} is inside .mopm/env, which mopm sync replaces; use a directory outside it\n", .{cache});
        rep.same(try c.fmt("--cache {s}: the refusal", .{cache}), want, r.stderr);
        rep.check(try c.fmt("--cache {s}: exit 1, nothing downloaded or created, the environment is as it was", .{cache}), r.code == 1 and r.stdout.len == 0 and
            std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and std.mem.eql(u8, try c.names(c.path(&.{ b.app, ".mopm" })), fx.beside), c.detail(r));
    }
    rep.check("no newpart directory was made in the project", !c.exists(b.app, "newpart"), "");

    // A symbolic link whose target does not exist yet: what creating through it makes cannot be judged.
    try fs.cwd().symLink(c.path(&.{ b.env_dir, "not-yet" }), c.path(&.{ b.app, "dangling" }), .{ .is_directory = true });
    const r = try c.run(b.app, &.{ "sync", "--locked", "--toolchain", b.t2.closure, "--cache", "dangling/cache" });
    rep.same("--cache through a dangling link: the refusal", "mopm sync: --cache dangling/cache passes through a symbolic link whose target does not exist; refused\n", r.stderr);
    rep.check("--cache through a dangling link: exit 1, the environment is as it was, nothing made at its target", r.code == 1 and r.stdout.len == 0 and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and !c.exists(b.env_dir, "not-yet"), c.detail(r));
    try rep.finish();
}

test "without --cache the files go to XDG_CACHE_HOME/mopm/pkgs, else HOME/.cache/mopm/pkgs; --cache wins; no HOME is an error; a file in the way is reported" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    try c.publish("greet", try fx.packageOf(a, c.subdir, "greet", &.{}));
    const t = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const t2 = try c.toolchain("channel/toolchain2", "toolchain2.json", "T2");
    const reg = [_][]const u8{ "--registry", c.fake.base };

    const Case = struct { name: []const u8, home: ?[]const u8, xdg: ?[]const u8, flag: ?[]const u8, root: []const u8, absent: []const u8 };
    const cases = [_]Case{
        .{ .name = "HOME only", .home = c.path(&.{ c.work, "h1" }), .xdg = null, .flag = null, .root = c.path(&.{ c.work, "h1/.cache/mopm/pkgs" }), .absent = c.path(&.{ c.work, "x1" }) },
        .{ .name = "XDG_CACHE_HOME and HOME", .home = c.path(&.{ c.work, "h2" }), .xdg = c.path(&.{ c.work, "x2" }), .flag = null, .root = c.path(&.{ c.work, "x2/mopm/pkgs" }), .absent = c.path(&.{ c.work, "h2/.cache" }) },
        .{ .name = "an empty XDG_CACHE_HOME and HOME", .home = c.path(&.{ c.work, "h3" }), .xdg = "", .flag = null, .root = c.path(&.{ c.work, "h3/.cache/mopm/pkgs" }), .absent = c.path(&.{ c.work, "x3" }) },
        .{ .name = "--cache, XDG_CACHE_HOME and HOME", .home = c.path(&.{ c.work, "h4" }), .xdg = c.path(&.{ c.work, "x4" }), .flag = c.path(&.{ c.work, "flag4" }), .root = c.path(&.{ c.work, "flag4" }), .absent = c.path(&.{ c.work, "x4" }) },
    };
    for (cases, 0..) |case, i| {
        var env = try h.cloneEnv(a, &c.env);
        if (case.home) |home| try env.put("HOME", home);
        if (case.xdg) |xdg| try env.put("XDG_CACHE_HOME", xdg);
        const app = try c.project(try c.fmt("case{d}", .{i}), "\"example/greet\" = \"1\"");
        const args = if (case.flag) |f| try c.cat(&.{ &.{"sync"}, &reg, &.{ "--toolchain", t.closure, "--cache", f } }) else try c.cat(&.{ &.{"sync"}, &reg, &.{ "--toolchain", t.closure } });
        const r = try c.runIn(app, args, &env);
        rep.check(try c.fmt("{s}: the toolchain's files are in <cache>/<sha256>/<file>, and in no other cache", .{case.name}), r.code == 0 and holds(c, case.root, t) and !c.exists(case.absent, ""), c.detail(r));
    }

    // No HOME and no XDG_CACHE_HOME, and --cache a file in the way: the old environment stays.
    const app = try c.project("fixed", "\"example/greet\" = \"1\"");
    const own = c.path(&.{ c.work, "own-cache" });
    var r = try c.run(app, &.{ "sync", "--registry", c.fake.base, "--toolchain", t.closure, "--cache", own });
    rep.check("a project synced with --cache", r.code == 0, c.detail(r));
    const env_dir = c.path(&.{ app, ".mopm/env" });
    const print = try c.fingerprint(env_dir);
    const no_home = "mopm sync: no HOME, so no cache directory for the toolchain's files: pass --cache <dir>\n";
    var empty_home = try h.cloneEnv(a, &c.env);
    try empty_home.put("HOME", "");
    r = try c.runIn(app, &.{ "sync", "--locked", "--toolchain", t2.closure }, &empty_home);
    rep.same("an empty HOME and no XDG_CACHE_HOME: the error", no_home, r.stderr);
    rep.check("an empty HOME: exit 1, the environment is as it was", r.code == 1 and std.mem.eql(u8, try c.fingerprint(env_dir), print), c.detail(r));
    var no_env = try h.cloneEnv(a, &c.env);
    no_env.remove("HOME");
    r = try c.runIn(app, &.{ "sync", "--locked", "--toolchain", t2.closure }, &no_env);
    rep.same("no HOME at all and no XDG_CACHE_HOME: the error", no_home, r.stderr);
    rep.check("no HOME at all: exit 1, the environment is as it was", r.code == 1 and std.mem.eql(u8, try c.fingerprint(env_dir), print), c.detail(r));

    const blocker = c.path(&.{ c.work, "a-file" });
    try h.writeFile(blocker, "not a directory\n");
    const blocked = [_][]const u8{ blocker, c.path(&.{ blocker, "below" }) };
    for (blocked) |cache| {
        r = try c.run(app, &.{ "sync", "--locked", "--toolchain", t2.closure, "--cache", cache });
        rep.same(try c.fmt("--cache {s}: the error names the directory and the failure", .{cache}), try c.fmt("mopm sync: cannot make the cache directory {s}: NotDir\n", .{cache}), r.stderr);
        rep.check(try c.fmt("--cache {s}: exit 1, the environment is as it was, the file is untouched", .{cache}), r.code == 1 and std.mem.eql(u8, try c.fingerprint(env_dir), print) and
            std.mem.eql(u8, c.read(c.work, "a-file") orelse "", "not a directory\n"), c.detail(r));
    }
    try rep.finish();
}

test "two projects share one cache: the same file name with other bytes is another entry, and a reinstall needs no download" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const rep = &rig.rep;
    const b = try fx.baseline(c);
    try std.testing.expectEqualStrings(b.t.files[0].file_name, b.t2.files[0].file_name);
    try std.testing.expect(!std.mem.eql(u8, b.t.files[0].sha256, b.t2.files[0].sha256));

    const app_b = try c.project("app_b", "\"example/greet\" = \"1\"");
    const env_b = c.path(&.{ app_b, ".mopm/env" });
    var r = try c.run(app_b, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.check("project B installs its toolchain T2 into the cache A used", r.code == 0, c.detail(r));
    rep.check("the cache holds an entry for each toolchain's files", holds(c, b.cache, b.t) and holds(c, b.cache, b.t2), try c.names(b.cache));
    const print_b = try c.fingerprint(env_b);

    try fs.cwd().deleteTree(b.env_dir);
    const before = try c.served();
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("project A installs again from the cache and its kept files, with no download", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and try c.served() == before, c.detail(r));
    rep.check("A's environment has A's toolchain bytes and B's has B's", std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and std.mem.eql(u8, try c.fingerprint(env_b), print_b) and
        h.contains(c.read(b.env_dir, "share/mopm-fake-toolchain/mojo.txt") orelse "", "(T)") and h.contains(c.read(env_b, "share/mopm-fake-toolchain/mojo.txt") orelse "", "(T2)"), "an environment holds the other's bytes");
    try rep.finish();
}

/// The lock's `system_libs` entry for the host subdir holding `pkg` (named `name` `version`) at `url`.
fn libsJson(c: *fx.Cx, name: []const u8, version: []const u8, url: []const u8, pkg: []const u8) !std.json.Value {
    const sha = try cp.sha256Hex(c.a, pkg);
    return h.parseJson(c.a, try c.fmt("{{\"{s}\": [{{\"name\": \"{s}\", \"version\": \"{s}\", \"build\": \"h0_0\", \"url\": \"{s}\", \"sha256\": \"{s}\", \"size\": {d}}}]}}", .{ c.subdir, name, version, url, sha, pkg.len }));
}

test "a lock library named like a toolchain package, with other bytes, replaces it and sync warns on stderr" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    const lib_bytes = "the replacement mojo package\n";
    const lib_pkg = try cp.package(a, "mojo", "2.0.0", "h0_0", c.subdir, &.{}, &.{.{ .path = "lib/libreplaced.so", .data = lib_bytes, .mode = 0o755 }});
    const lib_sha = try cp.sha256Hex(a, lib_pkg);
    const lib_file = "mojo-2.0.0-h0_0.conda";
    const old_file = b.t.files[0].file_name;
    rep.check("the toolchain file the lock's library replaces is the stand-in's mojo", std.mem.eql(u8, b.t.files[0].name, "mojo"), old_file);
    var v = try c.lockValue(b.app);
    try v.object.put("system_libs", try libsJson(c, "mojo", "2.0.0", try c.fmt("https://conda.example/pkgs/{s}/{s}", .{ c.subdir, lib_file }), lib_pkg));
    try c.writeLockValue(b.app, v);
    try fs.cwd().makePath(c.path(&.{ b.cache, lib_sha }));
    try h.writeFile(c.path(&.{ b.cache, lib_sha, lib_file }), lib_pkg);

    const before = try c.served();
    const r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    const want_err = try c.fmt("mopm sync: warning: the lock pins mojo 2.0.0 ({s}); it replaces the Mojo {s} toolchain's {s}\n", .{ lib_file, mojo, old_file });
    rep.same("the warning names the library, the file it replaces and the Mojo version", want_err, r.stderr);
    rep.check("the sync succeeds without a download", r.code == 0 and try c.served() == before and
        h.contains(r.stdout, try c.fmt("installed 1 packages for {s} (mojo {s}, 2 toolchain files) into .mopm/env\n", .{ c.subdir, mojo })), c.detail(r));
    rep.check("the library's bytes are installed and its record replaces the toolchain package's", std.mem.eql(u8, c.read(b.env_dir, "lib/libreplaced.so") orelse "", lib_bytes) and
        c.exists(b.env_dir, "conda-meta/mojo-2.0.0-h0_0.json") and !c.exists(b.env_dir, c.fmt("conda-meta/mojo-{s}-fake_0.json", .{mojo}) catch ""), try c.names(c.path(&.{ b.env_dir, "conda-meta" })));
    try rep.finish();
}

test "a lock library whose url is not an https .conda file is refused and the environment is as it was" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    const lib_pkg = try cp.package(a, "libfoo", "1.2.3", "h0_0", c.subdir, &.{}, &.{.{ .path = "lib/libfoo.so.1", .data = "x\n", .mode = 0o755 }});
    const urls = [_][]const u8{
        "https://conda.example/pkgs/linux/libfoo-1.2.3-h0_0.tar.bz2",
        "https://conda.example/pkgs/linux/..",
        "https://conda.example/libfoo-1.2.3-h0_0.conda%00",
    };
    for (urls) |url| {
        var v = try c.lockValue(b.app);
        try v.object.put("system_libs", try libsJson(c, "libfoo", "1.2.3", url, lib_pkg));
        try c.writeLockValue(b.app, v);
        const before = try c.served();
        const r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
        const want = try c.fmt("mopm sync: mopm.lock: system_libs of {s}: libfoo's url {s} is not an https .conda file\n", .{ c.subdir, url });
        rep.same(url, want, r.stderr);
        rep.check("exit 1, nothing printed, nothing downloaded, the environment unchanged", r.code == 1 and r.stdout.len == 0 and try c.served() == before and
            std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print), c.detail(r));
    }
    try rep.finish();
}
