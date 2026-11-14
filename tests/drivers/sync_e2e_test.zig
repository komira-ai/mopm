//! End-to-end test of `mopm sync` installing an environment by itself: the built CLI against mopm-fake-registry, with
//! no pixi (PATH names an empty directory) and a stand-in toolchain closure (sync_fixture.zig `toolchain`) in place of
//! the pinned Mojo one, which the farm cannot download. Run by Buck2 as //:sync_e2e on every pull request; MOPM and
//! MOPM_FAKE_REGISTRY are the built programs. Each check prints `ok` or `FAIL`.
//!
//! The fake serves a package greet 1.0.0 (a real .conda: lib/mojo/greet.mopm.json and a library), the stand-in
//! toolchain T (`mojo` and `mojo-compiler` 1.0.0), a mirror of T (the same bytes under another url), a second
//! toolchain T2 (other bytes), and a package broken 1.0.0 whose payload ends in the middle of its second file. Downloads
//! are counted by the fake (`/_fake/served`), never by time.
//!
//! The stand-in packages hold a symbolic link and an executable, and the fingerprint the checks compare records every
//! entry's kind, link target, executable bit and bytes. The other `mopm sync` drivers (sync_state_e2e_test.zig,
//! sync_refuse_e2e_test.zig, sync_cache_e2e_test.zig) share sync_fixture.zig.
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
const fx = @import("sync_fixture.zig");
const fs = std.fs;

const mojo = fx.mojo;
const build_tag = fx.build_tag;
const beside = fx.beside;

test "mopm sync installs the lock and the toolchain itself: no pixi, pinned bytes only, a whole environment or the old one" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const work = c.work;
    const fake = rig.fake;
    const fake_dir = c.fake_dir;

    const greet = try fx.packageOf(a, c.subdir, "greet", &.{});
    try c.publish("greet", greet);
    const greet_file = "mojo-greet-1.0.0-" ++ build_tag ++ ".conda";
    const tc = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const mirror = try c.toolchain("channel/mirror", "mirror.json", "T");
    const tc2 = try c.toolchain("channel/toolchain2", "toolchain2.json", "T2");
    const cache = try h.join(a, &.{ work, "cache" });
    const reg = [_][]const u8{ "--registry", fake.base };
    const with_t = [_][]const u8{ "--toolchain", tc.closure, "--cache", cache };
    const with_t2 = [_][]const u8{ "--toolchain", tc2.closure, "--cache", cache };

    // ------------------------------------------------ the first sync
    const app = try c.project("app", "\"example/greet\" = \"1\"");
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
    const shas = [_][]const u8{ tc.files[0].sha256, tc.files[1].sha256 };
    const by_sha = if (std.mem.lessThan(u8, shas[0], shas[1])) shas else [_][]const u8{ shas[1], shas[0] };
    rep.check("the locked file is kept in .mopm/pkgs, the toolchain's in --cache, one directory per sha256", std.mem.eql(u8, c.read(app, ".mopm/pkgs/" ++ greet_file) orelse "", greet) and
        std.mem.eql(u8, try c.names(cache), try c.fmt("{s},{s}", .{ by_sha[0], by_sha[1] })) and
        c.exists(cache, try c.fmt("{s}/{s}", .{ tc.files[0].sha256, tc.files[0].file_name })) and
        c.exists(cache, try c.fmt("{s}/{s}", .{ tc.files[1].sha256, tc.files[1].file_name })), try c.names(cache));
    rep.check(".mopm holds the environment, the kept files and the project lock, and no pixi project or local channel", std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), beside), try c.names(c.path(&.{ app, ".mopm" })));
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
    const app_m = try c.project("app_m", "\"example/greet\" = \"1\"");
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
    // The stamp names the files and the path, not the urls: the same project synced again with the pinned url's closure
    // finds the mirror's environment current (T's files are in the cache already).
    before = try c.served();
    r = try c.run(app_m, &.{ "sync", "--locked", "--toolchain", tc.closure, "--cache", cache_m });
    rep.check("a mirror's environment has the stamp of the same files from the pinned url", r.code == 0 and try c.served() - before == 0 and h.contains(r.stdout, ".mopm/env is current"), c.detail(r));
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
        .{ .what = "a toolchain file with one byte changed", .served = t2_mojo.served, .good = t2_mojo.bytes, .bad = flipped_tc, .kept = c.path(&.{ cache, t2_mojo.sha256, t2_mojo.file_name }), .want = try c.fmt("mopm sync: {s} has sha256 {s}; the pin says {s}; refused\n", .{ t2_url, try cp.sha256Hex(a, flipped_tc), t2_mojo.sha256 }) },
        .{ .what = "a toolchain file one byte longer", .served = t2_mojo.served, .good = t2_mojo.bytes, .bad = longer_tc, .kept = c.path(&.{ cache, t2_mojo.sha256, t2_mojo.file_name }), .want = try c.fmt("mopm sync: {s} is larger than the pinned {d} bytes; refused\n", .{ t2_url, t2_mojo.bytes.len }) },
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
        rep.check(try c.fmt("{s}: nothing is left beside the environment", .{t.what}), std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), beside), try c.names(c.path(&.{ app, ".mopm" })));
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
    try c.publish("broken", try fx.brokenPackage(a, c.subdir));
    _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/broken\" = \"1\"");
    r = try c.run(app, &(.{"sync"} ++ reg ++ with_t2));
    rep.check("an unpack that fails in the middle fails the sync, saying the environment is as it was", r.code == 1 and h.contains(r.stderr, "mopm sync: cannot install into .mopm/env: mojo-broken-1.0.0-" ++ build_tag ++ ".conda: ") and
        h.contains(r.stderr, "; the environment is as it was\n"), c.detail(r));
    rep.check("the interrupted unpack leaves the environment as it was", std.mem.eql(u8, c.read(env_dir, "conda-meta/mopm-stamp") orelse "", stamp2) and
        std.mem.eql(u8, try c.fingerprint(env_dir), print2), "the environment changed");
    rep.check("the interrupted unpack leaves no temporary directory beside the environment", std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), beside), try c.names(c.path(&.{ app, ".mopm" })));

    // A temporary directory a killed sync left behind goes with the next install.
    _ = try c.project("app", "\"example/greet\" = \"1\"");
    try fs.cwd().makePath(c.path(&.{ app, ".mopm/.env.tmp-0123456789ab/lib" }));
    try h.writeFile(c.path(&.{ app, ".mopm/.env.tmp-0123456789ab/lib/half" }), "half");
    r = try c.run(app, &(.{"sync"} ++ reg ++ with_t));
    rep.check("the next install removes what a killed sync left, and installs", r.code == 0 and std.mem.eql(u8, try c.names(c.path(&.{ app, ".mopm" })), beside) and
        std.mem.eql(u8, c.read(env_dir, "conda-meta/mopm-stamp") orelse "", stamp1), try c.fmt("{s}\n{s}", .{ c.detail(r), try c.names(c.path(&.{ app, ".mopm" })) }));

    try rep.finish();
}
