//! End-to-end test of `mopm sync` installing an environment by itself: the built CLI against mopm-fake-registry, with
//! no pixi (PATH names an empty directory) and a stand-in toolchain closure (conda_pkg.zig `fakeToolchain`) in place of
//! the pinned Mojo one, which the farm cannot download. Run by Buck2 as //:sync_e2e on every pull request; MOPM and
//! MOPM_FAKE_REGISTRY are the built programs. Each check prints `ok` or `FAIL`.
//!
//! The fake serves a package greet 1.0.0 (a real .conda: lib/mojo/greet.mopm.json and a library), the stand-in
//! toolchain T (`mojo` and `mojo-compiler` 1.0.0), a mirror of T (the same bytes under another url), a second
//! toolchain T2 (other bytes), and a package broken 1.0.0 whose payload ends in the middle of its second file. Downloads
//! are counted by the fake (`/_fake/served`), never by time.
//!
//! What can go red, and why:
//! - the first sync locks and installs greet and T into .mopm/env: every file, a conda-meta record per package with the
//!   pinned sha256, the locked file in .mopm/pkgs and T's in --cache, three downloads; and no pixi project, no local
//!   channel (a sync that ran pixi fails here: there is none on PATH);
//! - a second sync with the same lock and toolchain finds the environment current and downloads nothing, even with the
//!   kept files gone;
//! - `--pixi` is an unknown flag (usage, exit 2), and `--toolchain` that is missing, not a closure, or the closure of
//!   another Mojo is refused, naming it;
//! - with T's files gone from its url, `--toolchain <mirror>` installs from the mirror (the records name the mirror's
//!   urls) with the same stamp;
//! - a toolchain file or a locked file whose bytes are not the pinned ones (one byte changed, one byte more) is refused,
//!   naming both values, is not kept, and the environment is exactly the one before (its stamp and its files); a kept
//!   locked file that was changed is not used but downloaded again;
//! - an unpack that fails in the middle (broken) leaves the environment as it was and no temporary directory beside it,
//!   and a temporary directory a killed sync left is removed by the next install.

const std = @import("std");
const h = @import("harness.zig");
const cp = @import("conda_pkg.zig");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const mojo = "1.0.0";
const build_tag = "mojo" ++ mojo ++ "_0";

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    work: []const u8,
    env: std.process.EnvMap,
    fake: *h.Fake,
    fake_dir: []const u8,
    subdir: []const u8,
    /// The `packages.conda` entries of the channel's repodata.json, one per published package.
    entries: std.ArrayList([]const u8),

    const Out = struct { code: u8, stdout: []const u8, stderr: []const u8 };

    fn fmt(c: *Cx, comptime f: []const u8, args: anytype) ![]u8 {
        return h.fmt(c.a, f, args);
    }

    fn path(c: *Cx, parts: []const []const u8) []const u8 {
        return h.join(c.a, parts) catch "";
    }

    /// `mopm <args>` in `dir`, standard output and standard error apart.
    fn run(c: *Cx, dir: []const u8, args: []const []const u8) !Out {
        const errf = c.path(&.{ c.work, "stderr.txt" });
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        const r = try h.run(c.a, argv, &c.env, .{ .cwd = dir, .capture = .stdout, .stderr_path = errf });
        return .{ .code = if (r.signaled) 255 else r.code, .stdout = r.text, .stderr = try h.readFile(c.a, errf) };
    }

    fn detail(c: *Cx, r: Out) []const u8 {
        return c.fmt("exit {d}\n{s}\n{s}", .{ r.code, r.stdout, r.stderr }) catch "";
    }

    fn read(c: *Cx, dir: []const u8, rel: []const u8) ?[]u8 {
        return h.readFile(c.a, c.path(&.{ dir, rel })) catch null;
    }

    fn exists(c: *Cx, dir: []const u8, rel: []const u8) bool {
        return if (fs.cwd().access(c.path(&.{ dir, rel }), .{})) true else |_| false;
    }

    /// The names in `dir`, sorted and joined by commas; "" when it is not there.
    fn names(c: *Cx, dir: []const u8) ![]const u8 {
        var d = fs.cwd().openDir(dir, .{ .iterate = true }) catch return "";
        defer d.close();
        var list = std.ArrayList([]const u8).init(c.a);
        var it = d.iterate();
        while (try it.next()) |e| try list.append(try c.a.dupe(u8, e.name));
        h.sortStrings(list.items);
        return std.mem.join(c.a, ",", list.items);
    }

    /// Every file under `dir` with its bytes' sha256, one per line: a fingerprint of an environment.
    fn fingerprint(c: *Cx, dir: []const u8) ![]const u8 {
        var d = fs.cwd().openDir(dir, .{ .iterate = true }) catch return "";
        defer d.close();
        var walker = try d.walk(c.a);
        defer walker.deinit();
        var lines = std.ArrayList([]const u8).init(c.a);
        while (try walker.next()) |e| {
            if (e.kind != .file) continue;
            const bytes = try d.readFileAlloc(c.a, e.path, 64 << 20);
            try lines.append(try c.fmt("{s} {s}", .{ e.path, try cp.sha256Hex(c.a, bytes) }));
        }
        h.sortStrings(lines.items);
        return std.mem.join(c.a, "\n", lines.items);
    }

    /// How many .conda files the fake has served so far.
    fn served(c: *Cx) !i64 {
        const v = try c.fake.control(c.a, "/served", "{}");
        return v.object.get("conda").?.integer;
    }

    fn project(c: *Cx, name: []const u8, deps: []const u8) ![]const u8 {
        const d = c.path(&.{ c.work, "proj", name });
        try fs.cwd().makePath(d);
        try h.writeFile(c.path(&.{ d, "mopm.toml" }), try c.fmt(
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
        return d;
    }

    /// `<name>` 1.0.0 in the fake's sparse index and channel (spec/index.md, spec/channel.md), with `data` as its file.
    fn publish(c: *Cx, name: []const u8, data: []const u8) !void {
        const file = try c.fmt("mojo-{s}-1.0.0-{s}.conda", .{ name, build_tag });
        const sha = try cp.sha256Hex(c.a, data);
        const rec = try c.fmt(
            \\{{"build":"{s}","deps":[],"files":[{{"filename":"{s}","sha256":"{s}","size":{d},"subdir":"{s}","url":"{s}/channel/{s}/{s}"}}],"manifest_sha256":"{s}","name":"{s}","native":[],"published_at":"2026-10-14T12:00:00Z","requires_mojo":"=={s}","state":"published","v":1,"version":"1.0.0"}}
            \\
        , .{ build_tag, file, sha, data.len, c.subdir, c.fake.base, c.subdir, file, sha, name, mojo });
        const index = c.path(&.{ c.fake_dir, "index", name[0..2], name[2..4], name });
        try fs.cwd().makePath(std.fs.path.dirname(index).?);
        try h.writeFile(index, rec);
        try c.entries.append(try c.fmt(
            \\"{s}":{{"build":"{s}","build_number":0,"depends":["mojo-compiler =={s}"],"name":"mojo-{s}","sha256":"{s}","size":{d},"subdir":"{s}","version":"1.0.0"}}
        , .{ file, build_tag, mojo, name, sha, data.len, c.subdir }));
        const repodata = try c.fmt(
            \\{{"info":{{"subdir":"{s}"}},"packages":{{}},"packages.conda":{{{s}}},"removed":[]}}
            \\
        , .{ c.subdir, try std.mem.join(c.a, ",", c.entries.items) });
        try c.serve(name, data);
        try h.writeFile(c.path(&.{ c.fake_dir, "channel", c.subdir, "repodata.json" }), repodata);
    }

    /// The channel's copy of `<name>` 1.0.0, replaced by `data`.
    fn serve(c: *Cx, name: []const u8, data: []const u8) !void {
        const p = c.path(&.{ c.fake_dir, "channel", c.subdir, try c.fmt("mojo-{s}-1.0.0-{s}.conda", .{ name, build_tag }) });
        try fs.cwd().makePath(std.fs.path.dirname(p).?);
        try h.writeFile(p, data);
    }
};

/// The package `name` 1.0.0 as `mopm pack` lays one out: its metadata, and one library.
fn packageOf(a: Allocator, subdir: []const u8, name: []const u8) ![]u8 {
    const meta = try h.fmt(a, "{{\"deps\": [], \"name\": \"{s}\", \"schema\": 1, \"version\": \"1.0.0\"}}\n", .{name});
    return cp.package(a, try h.fmt(a, "mojo-{s}", .{name}), "1.0.0", build_tag, subdir, &.{"mojo-compiler ==" ++ mojo}, &.{
        .{ .path = try h.fmt(a, "lib/mojo/{s}.mopm.json", .{name}), .data = meta },
        .{ .path = try h.fmt(a, "lib/lib{s}.so", .{name}), .data = try h.fmt(a, "the library of {s}\n", .{name}), .mode = 0o755 },
    });
}

/// A package whose payload holds one whole file and then the start of a second one: the unpack fails in the middle.
fn brokenPackage(a: Allocator, subdir: []const u8) ![]u8 {
    const stem = "mojo-broken-1.0.0-" ++ build_tag;
    const meta = "{\"deps\": [], \"name\": \"broken\", \"schema\": 1, \"version\": \"1.0.0\"}\n";
    const second = "x" ** 2048;
    const whole = try cp.tar(a, &.{
        .{ .path = "lib/mojo/broken.mopm.json", .data = meta },
        .{ .path = "lib/libbroken.so", .data = second },
    });
    // The first entry (one header, one block of data), the second header, and half of the second file.
    const cut = whole[0 .. 512 + 512 + 512 + 1024];
    const index = try h.fmt(a, "{{\"build\": \"{s}\", \"build_number\": 0, \"depends\": [], \"name\": \"mojo-broken\", \"subdir\": \"{s}\", \"version\": \"1.0.0\"}}", .{ build_tag, subdir });
    const paths = try h.fmt(a, "{{\"paths\": [{{\"_path\": \"lib/mojo/broken.mopm.json\", \"path_type\": \"hardlink\", \"sha256\": \"{s}\", \"size_in_bytes\": {d}}}, {{\"_path\": \"lib/libbroken.so\", \"path_type\": \"hardlink\", \"sha256\": \"{s}\", \"size_in_bytes\": {d}}}], \"paths_version\": 1}}", .{ try cp.sha256Hex(a, meta), meta.len, try cp.sha256Hex(a, second), second.len });
    const info = try cp.tar(a, &.{
        .{ .path = "info/index.json", .data = index },
        .{ .path = "info/paths.json", .data = paths },
    });
    return cp.zip(a, &.{
        .{ .path = "metadata.json", .data = "{\"conda_pkg_format_version\": 2}", .mode = 0 },
        .{ .path = "info-" ++ stem ++ ".tar.zst", .data = try cp.zstdRaw(a, info), .mode = 0 },
        .{ .path = "pkg-" ++ stem ++ ".tar.zst", .data = try cp.zstdRaw(a, cut), .mode = 0 },
    });
}

test "mopm sync installs the lock and the toolchain itself: no pixi, pinned bytes only, a whole environment or the old one" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    // PATH names an empty directory: no pixi, nor anything else, can be run by sync.
    const empty_bin = try h.join(a, &.{ work, "empty-bin" });
    try fs.cwd().makePath(empty_bin);
    const home = try h.join(a, &.{ work, "home" });
    try fs.cwd().makePath(home);
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", empty_bin);
    try env.put("HOME", home);

    const fake_dir = try h.join(a, &.{ work, "fake" });
    var fake = try h.Fake.start(a, try h.toolPath(a, "MOPM_FAKE_REGISTRY"), fake_dir);
    defer fake.close();
    var c = Cx{ .a = a, .rep = &rep, .mopm = try h.toolPath(a, "MOPM"), .work = work, .env = env, .fake = &fake, .fake_dir = fake_dir, .subdir = cp.hostSubdir(), .entries = std.ArrayList([]const u8).init(a) };

    const greet = try packageOf(a, c.subdir, "greet");
    try c.publish("greet", greet);
    const greet_file = "mojo-greet-1.0.0-" ++ build_tag ++ ".conda";
    const tc = try cp.fakeToolchain(a, fake_dir, fake.base, "channel/toolchain", c.subdir, mojo, try h.join(a, &.{ work, "toolchain.json" }), "T");
    const mirror = try cp.fakeToolchain(a, fake_dir, fake.base, "channel/mirror", c.subdir, mojo, try h.join(a, &.{ work, "mirror.json" }), "T");
    const tc2 = try cp.fakeToolchain(a, fake_dir, fake.base, "channel/toolchain2", c.subdir, mojo, try h.join(a, &.{ work, "toolchain2.json" }), "T2");
    const cache = try h.join(a, &.{ work, "cache" });
    const reg = [_][]const u8{ "--registry", fake.base };
    const with_t = [_][]const u8{ "--toolchain", tc.closure, "--cache", cache };
    const with_t2 = [_][]const u8{ "--toolchain", tc2.closure, "--cache", cache };

    // ------------------------------------------------ the first sync
    const app = try c.project("app", "greet = \"1\"");
    var before = try c.served();
    var r = try c.run(app, &(.{"sync"} ++ reg ++ with_t));
    const env_dir = c.path(&.{ app, ".mopm/env" });
    rep.check("sync locks, downloads and installs greet and the toolchain, with no pixi on PATH", r.code == 0 and
        h.contains(r.stdout, try c.fmt("installed 1 packages for {s} (mojo {s}, 2 toolchain files) into .mopm/env\n", .{ c.subdir, mojo })), c.detail(r));
    rep.check("the first sync downloads the locked file and the two toolchain files, once each", try c.served() - before == 3, try c.fmt("{d} downloads", .{try c.served() - before}));
    for ([_][]const u8{ "lib/mojo/greet.mopm.json", "lib/libgreet.so", "share/mopm-fake-toolchain/mojo.txt", "share/mopm-fake-toolchain/mojo-compiler.txt" }) |p| {
        rep.check(try c.fmt("installed: {s}", .{p}), c.exists(env_dir, p), try c.names(env_dir));
    }
    {
        const rec = c.read(env_dir, "conda-meta/mojo-greet-1.0.0-" ++ build_tag ++ ".json") orelse "";
        const v = h.parseJson(a, rec) catch std.json.Value{ .null = {} };
        rep.check("the locked package's conda-meta record names its pinned sha256 and its url", std.mem.eql(u8, h.jsonString(v, "sha256") orelse "", try cp.sha256Hex(a, greet)) and
            std.mem.eql(u8, h.jsonString(v, "url") orelse "", try c.fmt("{s}/channel/{s}/{s}", .{ fake.base, c.subdir, greet_file })), rec);
        for (tc.files) |f| {
            const t = c.read(env_dir, try c.fmt("conda-meta/{s}-{s}-{s}.json", .{ f.name, mojo, cp.fake_build })) orelse "";
            const tv = h.parseJson(a, t) catch std.json.Value{ .null = {} };
            rep.check(try c.fmt("the toolchain's {s} has a conda-meta record with its pinned sha256", .{f.name}), std.mem.eql(u8, h.jsonString(tv, "sha256") orelse "", f.sha256), t);
        }
    }
    rep.check("the locked file is kept in .mopm/pkgs, the toolchain's in --cache", std.mem.eql(u8, c.read(app, ".mopm/pkgs/" ++ greet_file) orelse "", greet) and
        std.mem.eql(u8, try c.names(cache), try c.fmt("{s},{s}", .{ tc.files[0].file_name, tc.files[1].file_name })), try c.names(cache));
    rep.check(".mopm holds the environment and the kept files, and no pixi project or local channel", std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), "env,pkgs"), try c.names(c.path(&.{ app, ".mopm" })));
    const stamp1 = c.read(env_dir, "conda-meta/mopm-stamp") orelse "";
    rep.check("the environment records its stamp", stamp1.len == 64, stamp1);
    const print1 = try c.fingerprint(env_dir);

    // ------------------------------------------------ an unchanged lock: nothing to do
    before = try c.served();
    r = try c.run(app, &(.{ "sync", "--locked" } ++ with_t));
    rep.check("a second sync with the same lock finds the environment current", r.code == 0 and h.contains(r.stdout, ".mopm/env is current: 1 packages for") and h.contains(r.stdout, "nothing to download"), c.detail(r));
    try fs.cwd().deleteTree(c.path(&.{ app, ".mopm/pkgs" }));
    try fs.cwd().deleteTree(cache);
    r = try c.run(app, &(.{ "sync", "--locked" } ++ with_t));
    rep.check("a second sync with the same lock downloads nothing, even with the kept files gone", r.code == 0 and try c.served() - before == 0 and !h.contains(r.stdout, "downloading"), try c.fmt("{d} downloads; {s}", .{ try c.served() - before, c.detail(r) }));
    rep.check("the current environment is left as it was", std.mem.eql(u8, try c.fingerprint(env_dir), print1), "the environment changed");

    // ------------------------------------------------ flags
    r = try c.run(app, &.{ "sync", "--pixi", "/usr/bin/pixi" });
    rep.check("--pixi is an unknown flag: usage, exit 2", r.code == 2 and h.contains(r.stderr, "usage: mopm lock") and h.contains(r.stderr, "[--toolchain <file>]"), c.detail(r));
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", "no-such.json" });
    rep.check("a --toolchain file that is not there is refused, naming it", r.code == 1 and h.contains(r.stderr, "mopm sync: --toolchain no-such.json: FileNotFound"), c.detail(r));
    try h.writeFile(c.path(&.{ app, "junk.json" }), "{\"format\": 1}");
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", "junk.json" });
    rep.check("a --toolchain file that is not a closure is refused", r.code == 1 and h.contains(r.stderr, "mopm sync: --toolchain junk.json is not a toolchain closure file"), c.detail(r));
    const other_mojo = try h.join(a, &.{ work, "other-mojo.json" });
    _ = try cp.fakeToolchain(a, fake_dir, fake.base, "channel/othermojo", c.subdir, "9.9.9", other_mojo, "T");
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", other_mojo });
    rep.check("the closure of another Mojo is refused", r.code == 1 and h.contains(r.stderr, try c.fmt("is the closure of mojo 9.9.9 on {s}; this sync needs mojo {s} on {s}", .{ c.subdir, mojo, c.subdir })), c.detail(r));
    rep.check("a refused --toolchain leaves the environment as it was", std.mem.eql(u8, try c.fingerprint(env_dir), print1), "the environment changed");

    // ------------------------------------------------ a mirror
    // T's url serves nothing now: only the mirror can supply its bytes.
    try fs.cwd().rename(c.path(&.{ fake_dir, "channel/toolchain" }), c.path(&.{ fake_dir, "channel/toolchain-away" }));
    const app_m = try c.project("app_m", "greet = \"1\"");
    try fs.cwd().copyFile(c.path(&.{ app, "mopm.lock" }), fs.cwd(), c.path(&.{ app_m, "mopm.lock" }), .{});
    const cache_m = try h.join(a, &.{ work, "cache-m" });
    before = try c.served();
    r = try c.run(app_m, &.{ "sync", "--locked", "--toolchain", mirror.closure, "--cache", cache_m });
    {
        const t = c.read(app_m, try c.fmt(".mopm/env/conda-meta/mojo-{s}-{s}.json", .{ mojo, cp.fake_build })) orelse "";
        const tv = h.parseJson(a, t) catch std.json.Value{ .null = {} };
        rep.check("--toolchain <mirror> installs the toolchain from the mirror", r.code == 0 and try c.served() - before == 3 and
            std.mem.eql(u8, h.jsonString(tv, "url") orelse "", try c.fmt("{s}/channel/mirror/{s}/{s}", .{ fake.base, c.subdir, mirror.files[0].file_name })), try c.fmt("{s}\n{s}", .{ c.detail(r), t }));
    }
    rep.check("a mirror's environment has the stamp of the same files from the pinned url", std.mem.eql(u8, c.read(app_m, ".mopm/env/conda-meta/mopm-stamp") orelse "", stamp1), "another stamp");
    try fs.cwd().rename(c.path(&.{ fake_dir, "channel/toolchain-away" }), c.path(&.{ fake_dir, "channel/toolchain" }));

    // ------------------------------------------------ bytes that are not the pinned ones
    // Each case changes what the fake serves, runs a sync that has to download it, and must leave the environment of
    // the first sync exactly as it was.
    const Tamper = struct { what: []const u8, served: []const u8, good: []const u8, bad: []const u8, want: []const u8, kept: []const u8 };
    const t2_mojo = tc2.files[0];
    const flipped_tc = try a.dupe(u8, t2_mojo.bytes);
    flipped_tc[flipped_tc.len / 2] ^= 0x01;
    const longer_tc = try std.mem.concat(a, u8, &.{ t2_mojo.bytes, "\x00" });
    const flipped_greet = try a.dupe(u8, greet);
    flipped_greet[flipped_greet.len / 2] ^= 0x01;
    const longer_greet = try std.mem.concat(a, u8, &.{ greet, "\x00" });
    const greet_served = try c.fmt("channel/{s}/{s}", .{ c.subdir, greet_file });
    const t2_url = try c.fmt("{s}/{s}", .{ fake.base, t2_mojo.served });
    const greet_url = try c.fmt("{s}/{s}", .{ fake.base, greet_served });
    const tampers = [_]Tamper{
        .{ .what = "a toolchain file with one byte changed", .served = t2_mojo.served, .good = t2_mojo.bytes, .bad = flipped_tc, .kept = c.path(&.{ cache, t2_mojo.file_name }), .want = try c.fmt("mopm sync: {s} has sha256 {s}; the pin says {s}; refused\n", .{ t2_url, try cp.sha256Hex(a, flipped_tc), t2_mojo.sha256 }) },
        .{ .what = "a toolchain file one byte longer", .served = t2_mojo.served, .good = t2_mojo.bytes, .bad = longer_tc, .kept = c.path(&.{ cache, t2_mojo.file_name }), .want = try c.fmt("mopm sync: {s} is larger than the pinned {d} bytes; refused\n", .{ t2_url, t2_mojo.bytes.len }) },
        .{ .what = "a locked file with one byte changed", .served = greet_served, .good = greet, .bad = flipped_greet, .kept = c.path(&.{ app, ".mopm/pkgs", greet_file }), .want = try c.fmt("mopm sync: {s} has sha256 {s}; the pin says {s}; refused\n", .{ greet_url, try cp.sha256Hex(a, flipped_greet), try cp.sha256Hex(a, greet) }) },
        .{ .what = "a locked file one byte longer", .served = greet_served, .good = greet, .bad = longer_greet, .kept = c.path(&.{ app, ".mopm/pkgs", greet_file }), .want = try c.fmt("mopm sync: {s} is larger than the pinned {d} bytes; refused\n", .{ greet_url, greet.len }) },
    };
    for (tampers) |t| {
        try h.writeFile(c.path(&.{ fake_dir, t.served }), t.bad);
        fs.cwd().deleteFile(t.kept) catch {};
        r = try c.run(app, &(.{ "sync", "--locked" } ++ with_t2));
        rep.check(try c.fmt("{s}: sync refuses it, naming the pinned and the actual value", .{t.what}), r.code == 1 and h.contains(r.stderr, t.want), c.detail(r));
        rep.check(try c.fmt("{s}: the file is not kept", .{t.what}), !c.exists(t.kept, ""), t.kept);
        rep.check(try c.fmt("{s}: the environment is the one before, stamp and files", .{t.what}), std.mem.eql(u8, c.read(env_dir, "conda-meta/mopm-stamp") orelse "", stamp1) and
            std.mem.eql(u8, try c.fingerprint(env_dir), print1), "the environment changed");
        rep.check(try c.fmt("{s}: nothing is left beside the environment", .{t.what}), std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), "env,pkgs"), try c.names(c.path(&.{ app, ".mopm" })));
        try h.writeFile(c.path(&.{ fake_dir, t.served }), t.good);
    }

    // A kept locked file that was changed afterwards is not used: it is downloaded again.
    try fs.cwd().makePath(c.path(&.{ app, ".mopm/pkgs" }));
    try h.writeFile(c.path(&.{ app, ".mopm/pkgs", greet_file }), flipped_greet);
    before = try c.served();
    r = try c.run(app, &(.{ "sync", "--locked" } ++ with_t2));
    rep.check("a changed kept file is downloaded again, and the sync installs", r.code == 0 and h.contains(r.stdout, "downloading " ++ greet_file) and
        std.mem.eql(u8, c.read(app, ".mopm/pkgs/" ++ greet_file) orelse "", greet), c.detail(r));
    const stamp2 = c.read(env_dir, "conda-meta/mopm-stamp") orelse "";
    rep.check("another toolchain is another stamp, and its files are installed", stamp2.len == 64 and !std.mem.eql(u8, stamp1, stamp2) and
        h.contains(c.read(env_dir, "share/mopm-fake-toolchain/mojo.txt") orelse "", "T2"), stamp2);
    const print2 = try c.fingerprint(env_dir);

    // ------------------------------------------------ an unpack that fails in the middle
    try c.publish("broken", try brokenPackage(a, c.subdir));
    _ = try c.project("app", "greet = \"1\"\nbroken = \"1\"");
    r = try c.run(app, &(.{"sync"} ++ reg ++ with_t2));
    rep.check("an unpack that fails in the middle fails the sync, saying the environment is as it was", r.code == 1 and h.contains(r.stderr, "mopm sync: cannot install into .mopm/env: mojo-broken-1.0.0-" ++ build_tag ++ ".conda: ") and
        h.contains(r.stderr, "; the environment is as it was\n"), c.detail(r));
    rep.check("the interrupted unpack leaves the environment as it was", std.mem.eql(u8, c.read(env_dir, "conda-meta/mopm-stamp") orelse "", stamp2) and
        std.mem.eql(u8, try c.fingerprint(env_dir), print2), "the environment changed");
    rep.check("the interrupted unpack leaves no temporary directory beside the environment", std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), "env,pkgs"), try c.names(c.path(&.{ app, ".mopm" })));

    // A temporary directory a killed sync left behind goes with the next install.
    _ = try c.project("app", "greet = \"1\"");
    try fs.cwd().makePath(c.path(&.{ app, ".mopm/.env.tmp-0123456789ab/lib" }));
    try h.writeFile(c.path(&.{ app, ".mopm/.env.tmp-0123456789ab/lib/half" }), "half");
    r = try c.run(app, &(.{"sync"} ++ reg ++ with_t));
    rep.check("the next install removes what a killed sync left, and installs", r.code == 0 and std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), "env,pkgs") and
        std.mem.eql(u8, c.read(env_dir, "conda-meta/mopm-stamp") orelse "", stamp1), try c.fmt("{s}\n{s}", .{ c.detail(r), try c.names(c.path(&.{ app, ".mopm" })) }));

    try rep.finish();
}
