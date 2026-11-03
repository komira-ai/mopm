//! `mopm sync` against an environment that already exists, in the states a project gets into: it moved, a file of it is
//! gone or changed, a killed sync left a backup, the legacy pixi layout is beside it, another sync is running. The
//! built CLI against mopm-fake-registry with the stand-in toolchain (sync_fixture.zig). Run by Buck2 as
//! //:sync_state_e2e on every pull request. Each check prints `ok` or `FAIL`; no check looks at a clock.
//!
//! What can go red, and why:
//! - a project moved to another absolute path is not current: it installs again from the kept files with no download,
//!   and a text file with a prefix placeholder names the new path, not the old;
//! - an environment with the right stamp but a missing toolchain file, or a changed library of a locked package, says
//!   on stderr that it does not match its stamp and is installed again; a missing stamp and a garbled stamp are a plain
//!   install;
//! - a backup `.mopm/.env.old-*` with no environment is put back by the next sync (stderr says so), and stays put when
//!   that sync fails; a backup beside a live environment is deleted;
//! - `.mopm/.pixi`, `.mopm/channel` and `.mopm/pixi.toml` are never read, moved or deleted, on success and on failure;
//! - a sync that finds `.mopm/sync.lock` held says so on stderr (the progress event the test waits for),
//!   leaves the environment alone while it waits, and installs when the lock is released.
//! The failures of the swap itself (a rename that fails between the two moves, a failed rollback, a failed delete) need
//! a seam a driver cannot reach: core/conda_env_test.zig covers them ("commit: ..." and "recover: ..." tests).

const std = @import("std");
const h = @import("harness.zig");
const cp = @import("conda_pkg.zig");
const fx = @import("sync_fixture.zig");
const fs = std.fs;

const mojo = fx.mojo;
const build_tag = fx.build_tag;

test "a project moved to another path installs again for the new path, from the kept files, and names it in rewritten files" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;

    const placeholder = "/opt/placeholder-prefix-0123456789abcdef";
    const ph_pkg = try fx.packageOf(a, c.subdir, "phfile", &.{.{ .path = "share/ph/prefix.txt", .data = "prefix=" ++ placeholder ++ "\n", .placeholder = placeholder }});
    try c.publish("phfile", ph_pkg);
    const t = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const cache = try h.join(a, &.{ c.work, "cache" });
    const flags = [_][]const u8{ "--registry", c.fake.base, "--toolchain", t.closure, "--cache", cache };
    const app = try c.project("app", "phfile = \"1\"");

    var r = try c.run(app, &(.{"sync"} ++ flags));
    const before_prefix = c.read(app, ".mopm/env/share/ph/prefix.txt") orelse "";
    rep.check("the first sync writes the environment's own path into the placeholder file", r.code == 0 and
        std.mem.eql(u8, before_prefix, try c.fmt("prefix={s}/.mopm/env\n", .{app})), try c.fmt("{s}\n{s}", .{ c.detail(r), before_prefix }));

    const moved_parent = c.path(&.{ c.work, "elsewhere" });
    try fs.cwd().makePath(moved_parent);
    const moved = c.path(&.{ moved_parent, "app" });
    try fs.cwd().rename(app, moved);
    const before = try c.served();
    r = try c.run(moved, try c.cat(&.{ &.{ "sync", "--locked" }, flags[2..] }));
    rep.check("a moved project is not current: it installs again", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and !h.contains(r.stdout, "is current"), c.detail(r));
    rep.check("the install after a move downloads nothing and prints nothing on stderr", try c.served() - before == 0 and r.stderr.len == 0, try c.fmt("{d} downloads; {s}", .{ try c.served() - before, r.stderr }));
    const after_prefix = c.read(moved, ".mopm/env/share/ph/prefix.txt") orelse "";
    rep.check("the placeholder file names the new path, not the old", std.mem.eql(u8, after_prefix, try c.fmt("prefix={s}/.mopm/env\n", .{moved})), after_prefix);
    r = try c.run(moved, try c.cat(&.{ &.{ "sync", "--locked" }, flags[2..] }));
    rep.check("the project at its new path is then current", r.code == 0 and h.contains(r.stdout, ".mopm/env is current: 1 packages for"), c.detail(r));
    try rep.finish();
}

test "a stamped environment that no longer matches its stamp is repaired; no stamp or a garbled one is a plain install" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);
    const lib_bytes = "the library of greet\n";

    // The lock pins the sha256 of greet's library, as a lock of a package with a native library does.
    {
        var v = try c.lockValue(b.app);
        const pkg = &v.object.getPtr("packages").?.array.items[0].object;
        const native = try std.fmt.allocPrint(a, "[{{\"id\": \"greet\", \"soname\": \"libgreet.so\", \"sha256\": \"{s}\"}}]", .{try cp.sha256Hex(a, lib_bytes)});
        try pkg.put("native", try h.parseJson(a, native));
        try c.writeLockValue(b.app, v);
    }
    var r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("the lock with the native library's hash finds the environment current", r.code == 0 and h.contains(r.stdout, ".mopm/env is current") and r.stderr.len == 0, c.detail(r));

    // A toolchain file gone.
    try fs.cwd().deleteFile(c.path(&.{ b.env_dir, "bin/mojo" }));
    var before = try c.served();
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.same("a missing bin/mojo: stderr names it and says the install is repeated", "mopm sync: .mopm/env does not match its stamp (mojo 1.0.0 is missing bin/mojo); installing it again\n", r.stderr);
    rep.check("a missing bin/mojo is back, the environment is the one of the first sync, nothing was downloaded", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and try c.served() - before == 0, c.detail(r));

    // A symbolic link of the toolchain gone: a dangling link is still a file of the record.
    try fs.cwd().deleteFile(c.path(&.{ b.env_dir, "bin/mojo-link" }));
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.same("a missing link: stderr names it", "mopm sync: .mopm/env does not match its stamp (mojo 1.0.0 is missing bin/mojo-link); installing it again\n", r.stderr);
    rep.check("a missing link is back as a link", std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print), try c.fingerprint(b.env_dir));

    // A changed native library of a locked package.
    try h.writeFile(c.path(&.{ b.env_dir, "lib/libgreet.so" }), "tampered\n");
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.same("a changed native library: stderr names both hashes", try c.fmt("mopm sync: .mopm/env does not match its stamp (lib/libgreet.so of mojo-greet 1.0.0 has sha256 {s}; mopm.lock pins {s}; refused); installing it again\n", .{ try cp.sha256Hex(a, "tampered\n"), try cp.sha256Hex(a, lib_bytes) }), r.stderr);
    rep.check("a changed native library is the pinned one again", r.code == 0 and std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print), c.detail(r));

    // No stamp, then a garbled one: a plain install with nothing on stderr.
    try fs.cwd().deleteFile(c.path(&.{ b.env_dir, "conda-meta/mopm-stamp" }));
    before = try c.served();
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("a missing stamp is a full install, quietly", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and r.stderr.len == 0 and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and try c.served() - before == 0, c.detail(r));
    try h.writeFile(c.path(&.{ b.env_dir, "conda-meta/mopm-stamp" }), "not a stamp \x00\xff garbage");
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("a garbled stamp is a full install, quietly", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and r.stderr.len == 0 and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print), c.detail(r));
    try rep.finish();
}

test "a backup with no environment is put back by the next sync, and stays when that sync fails; a backup beside an environment goes" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);
    const dot_mopm = c.path(&.{ b.app, ".mopm" });
    const backup = ".env.old-0123456789ab";
    const restored_line = "mopm sync: restored .mopm/env from .mopm/" ++ backup ++ "\n";

    try fs.cwd().rename(b.env_dir, c.path(&.{ dot_mopm, backup }));
    var r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.same("the restore is announced on stderr", restored_line, r.stderr);
    rep.check("the restored environment is the one that was moved, and is current", r.code == 0 and h.contains(r.stdout, ".mopm/env is current") and
        std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and std.mem.eql(u8, try c.names(dot_mopm), fx.beside), c.detail(r));

    // The restore happens first: a sync that then fails leaves the restored environment, not nothing.
    try fs.cwd().rename(b.env_dir, c.path(&.{ dot_mopm, backup }));
    const t2_mojo = b.t2.files[0];
    const flipped = try a.dupe(u8, t2_mojo.bytes);
    flipped[flipped.len / 2] ^= 0x01;
    try h.writeFile(c.path(&.{ c.fake_dir, t2_mojo.served }), flipped);
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t2 }));
    const want = try c.fmt("{s}mopm sync: {s}/{s} has sha256 {s}; the pin says {s}; refused\n", .{ restored_line, c.fake.base, t2_mojo.served, try cp.sha256Hex(a, flipped), t2_mojo.sha256 });
    rep.same("a failing sync after the restore reports the restore and the failure", want, r.stderr);
    rep.check("the failing sync leaves the restored environment and no backup", r.code == 1 and std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and
        std.mem.eql(u8, try c.names(dot_mopm), fx.beside), try c.names(dot_mopm));

    // A backup beside a live environment is stale: removed, nothing restored.
    try fs.cwd().makePath(c.path(&.{ dot_mopm, backup, "lib" }));
    try h.writeFile(c.path(&.{ dot_mopm, backup, "lib/old" }), "old");
    r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t }));
    rep.check("a backup beside an environment is deleted without a word", r.code == 0 and r.stderr.len == 0 and h.contains(r.stdout, ".mopm/env is current") and
        std.mem.eql(u8, try c.names(dot_mopm), fx.beside) and std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print), c.detail(r));
    try rep.finish();
}

fn legacySnapshot(c: *fx.Cx, app: []const u8) ![]const u8 {
    const pix = try c.fingerprint(c.path(&.{ app, ".mopm/.pixi" }));
    const chan = try c.fingerprint(c.path(&.{ app, ".mopm/channel" }));
    const toml = c.read(app, ".mopm/pixi.toml") orelse "<missing>";
    const mode = (try fs.cwd().statFile(c.path(&.{ app, ".mopm/pixi.toml" }))).mode;
    return c.fmt("{s}\n--\n{s}\n--\n{s}\n{o}", .{ pix, chan, toml, mode & 0o777 });
}

test "the legacy pixi layout beside .mopm/env is never read, moved or deleted, whether sync succeeds or fails" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;

    const greet = try fx.packageOf(a, c.subdir, "greet", &.{});
    try c.publish("greet", greet);
    const t = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const t2 = try c.toolchain("channel/toolchain2", "toolchain2.json", "T2");
    const cache = try h.join(a, &.{ c.work, "cache" });
    const app = try c.project("app", "greet = \"1\"");
    const dot = c.path(&.{ app, ".mopm" });
    try fs.cwd().makePath(c.path(&.{ dot, ".pixi/envs/default/bin" }));
    try fs.cwd().makePath(c.path(&.{ dot, "channel/noarch" }));
    {
        const f = try fs.cwd().createFile(c.path(&.{ dot, ".pixi/envs/default/bin/x" }), .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll("#!/bin/sh\nlegacy\n");
        const p = try fs.cwd().createFile(c.path(&.{ dot, "pixi.toml" }), .{ .mode = 0o640 });
        defer p.close();
        try p.writeAll("[project]\nname = \"legacy\"\n");
    }
    try h.writeFile(c.path(&.{ dot, "channel/noarch/repodata.json" }), "{\"packages\": {}}\n");
    const legacy = try legacySnapshot(c, app);

    var r = try c.run(app, &.{ "sync", "--registry", c.fake.base, "--toolchain", t.closure, "--cache", cache });
    rep.check("sync installs the environment next to the legacy layout", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and c.exists(dot, "env/conda-meta/mopm-stamp"), c.detail(r));
    rep.check("after a successful sync the legacy files are byte for byte and mode for mode what they were", std.mem.eql(u8, legacy, try legacySnapshot(c, app)), try legacySnapshot(c, app));
    rep.check(".mopm holds the legacy entries beside the new ones", std.mem.eql(u8, try c.names(dot), ".pixi,channel,env,pixi.toml,pkgs,sync.lock"), try c.names(dot));

    // A failing sync (a toolchain file that is not the pinned bytes).
    const bad = try a.dupe(u8, t2.files[0].bytes);
    bad[bad.len / 2] ^= 0x01;
    try h.writeFile(c.path(&.{ c.fake_dir, t2.files[0].served }), bad);
    const env_print = try c.fingerprint(c.path(&.{ dot, "env" }));
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", t2.closure, "--cache", cache });
    rep.check("a failing sync fails", r.code == 1 and h.contains(r.stderr, "; refused\n"), c.detail(r));
    rep.check("after a failing sync the legacy files are what they were, and so is the environment", std.mem.eql(u8, legacy, try legacySnapshot(c, app)) and
        std.mem.eql(u8, env_print, try c.fingerprint(c.path(&.{ dot, "env" }))), try legacySnapshot(c, app));
    try rep.finish();
}

test "a second sync waits for the first sync of the project, says so on stderr, and installs once the lock is free" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);
    const dot_mopm = c.path(&.{ b.app, ".mopm" });

    // This test is "the other sync": it holds the project lock.
    const held = try fs.cwd().openFile(c.path(&.{ dot_mopm, "sync.lock" }), .{ .mode = .read_write });
    defer held.close();
    try held.lock(.exclusive);

    const argv = try c.cat(&.{ &.{c.mopm}, &.{"sync"}, b.reg, b.with_t2 });
    var child = std.process.Child.init(argv, a);
    child.cwd = b.app;
    child.env_map = &c.env;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    // The line is the progress event: the child has the lock file open and is blocked on it.
    const line = try h.readLine(a, child.stderr.?);
    rep.same("the waiting sync says what it waits for", "mopm sync: waiting for another mopm sync of this project to finish (.mopm/sync.lock)", line);
    rep.check("while it waits the environment is untouched and no temporary directory exists", std.mem.eql(u8, try c.fingerprint(b.env_dir), b.print) and
        std.mem.eql(u8, try c.names(dot_mopm), fx.beside), try c.names(dot_mopm));

    held.unlock();
    const out = try child.stdout.?.readToEndAlloc(a, 1 << 20);
    const rest = try child.stderr.?.readToEndAlloc(a, 1 << 20);
    const term = try child.wait();
    rep.check("after the lock is released the waiting sync installs", term == .Exited and term.Exited == 0 and h.contains(out, "installed 1 packages for") and rest.len == 0, try c.fmt("{any}\n{s}\n{s}", .{ term, out, rest }));
    rep.check("the environment is the second toolchain's", h.contains(c.read(b.env_dir, "share/mopm-fake-toolchain/mojo.txt") orelse "", "T2") and std.mem.eql(u8, try c.names(dot_mopm), fx.beside), try c.names(dot_mopm));
    try rep.finish();
}
