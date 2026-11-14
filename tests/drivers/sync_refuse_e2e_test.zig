//! What `mopm sync` refuses, and what it leaves behind when it does. The built CLI against mopm-fake-registry with the
//! stand-in toolchain (sync_fixture.zig). Run by Buck2 as //:sync_refuse_e2e on every pull request. Every refusal is
//! checked against the complete stderr line, the exit code, and the environment of an earlier sync: its fingerprint
//! (every entry's kind, link target, executable bit and bytes) is the same, and `.mopm` holds nothing but env, pkgs and
//! sync.lock.
//!
//! What can go red, and why:
//! - a locked archive without its `lib/mojo/<name>.mopm.json`, or whose native library is not the one the lock pins, is
//!   refused after the unpack and before the old environment is replaced;
//! - a toolchain closure whose package name, version or build holds a path separator is refused before anything is
//!   written, in the project or outside it;
//! - a locked package that ships a file a toolchain package ships (other bytes, or a link where a file is) is refused,
//!   naming the path and both packages; the same bytes at the same path are accepted;
//! - a version 2 lock that records another toolchain closure than the one to install is refused before any download or
//!   any directory is made; a mirror (same pins, other urls) has the same closure hash and is accepted;
//! - a locked file or a toolchain file whose body is shorter than its pin, or whose url answers 404, is refused with
//!   the message of the download and no `*.part-*` is left. (A body cut off by a closed connection is the same short
//!   body to the client: pkg_fetch.zig's "fetch: a body shorter than the pin, and one cut off mid-way" covers both.)

const std = @import("std");
const h = @import("harness.zig");
const cp = @import("conda_pkg.zig");
const fx = @import("sync_fixture.zig");
const fs = std.fs;

const mojo = fx.mojo;
const build_tag = fx.build_tag;

fn untouched(c: *fx.Cx, b: fx.Base, what: []const u8) void {
    const dot = c.path(&.{ b.app, ".mopm" });
    const ok = std.mem.eql(u8, c.fingerprint(b.env_dir) catch "?", b.print) and std.mem.eql(u8, c.names(dot) catch "?", fx.beside) and
        !(c.leftovers(dot) catch true) and !(c.leftovers(b.cache) catch true);
    c.rep.check(c.fmt("{s}: the environment is the one before, .mopm holds env,pkgs,sync.lock, nothing is half-written", .{what}) catch what, ok, c.names(dot) catch "?");
}

test "a locked archive without its metadata, or with a native library the lock does not pin, is refused and the old environment stays" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    // The lock pins another sha256 for greet's native library than the library in the archive.
    {
        var v = try c.lockValue(b.app);
        const pkg = &v.object.getPtr("packages").?.array.items[0].object;
        const pinned = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        try pkg.put("native", try h.parseJson(a, "[{\"id\": \"greet\", \"soname\": \"libgreet.so\", \"sha256\": \"" ++ pinned ++ "\"}]"));
        try c.writeLockValue(b.app, v);
        const r = try c.run(b.app, try c.cat(&.{ &.{ "sync", "--locked" }, b.with_t2 }));
        const want = try c.fmt("mopm sync: cannot install into .mopm/env: lib/libgreet.so of mojo-greet 1.0.0 has sha256 {s}; mopm.lock pins {s}; refused; the environment is as it was\n", .{ try cp.sha256Hex(a, "the library of greet\n"), pinned });
        rep.same("a native library that is not the pinned one: the refusal", want, r.stderr);
        rep.check("a native library that is not the pinned one: exit 1", r.code == 1, c.detail(r));
        untouched(c, b, "a native library that is not the pinned one");
    }

    // The archive has the pinned bytes but no lib/mojo/nometa.mopm.json.
    {
        const nometa = try cp.package(a, "mojo-nometa", "1.0.0", build_tag, c.subdir, &.{"mojo-compiler ==" ++ mojo}, &.{.{ .path = "lib/libnometa.so", .data = "the library of nometa\n", .mode = 0o755 }});
        try c.publish("nometa", nometa);
        _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/nometa\" = \"1\"");
        const r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
        rep.same("an archive without lib/mojo/nometa.mopm.json: the refusal", "mopm sync: cannot install into .mopm/env: mojo-nometa 1.0.0 is installed without lib/mojo/nometa.mopm.json: a corrupt package; the environment is as it was\n", r.stderr);
        rep.check("an archive without its metadata: exit 1, the archive was downloaded and checked", r.code == 1 and h.contains(r.stdout, "downloading mojo-nometa-1.0.0-" ++ build_tag ++ ".conda"), c.detail(r));
        untouched(c, b, "an archive without its metadata");
    }
    try rep.finish();
}

test "a toolchain closure naming a package with a path separator is refused before anything is written" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    _ = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const app = try c.project("app", "");
    const cache = try h.join(a, &.{ c.work, "cache" });
    const locked = try c.run(app, &.{ "lock", "--registry", c.fake.base });
    rep.check("a project with no dependencies is locked offline", locked.code == 0, c.detail(locked));
    const proj_before = try c.fingerprint(c.path(&.{ c.work, "proj" }));

    const Case = struct { field: []const u8, value: []const u8, shown: []const u8 };
    const cases = [_]Case{
        .{ .field = "name", .value = "../../escape", .shown = "../../escape" },
        .{ .field = "build", .value = "fake/0", .shown = "fake/0" },
        .{ .field = "version", .value = "1.0.0/..", .shown = "1.0.0/.." },
    };
    for (cases, 0..) |case, i| {
        var v = try h.parseJson(a, c.read(c.work, "toolchain.json").?);
        try v.object.getPtr("packages").?.array.items[0].object.put(case.field, .{ .string = case.value });
        var out = std.ArrayList(u8).init(a);
        try std.json.stringify(v, .{}, out.writer());
        const closure = try c.fmt("{s}/evil-{d}.json", .{ c.work, i });
        try h.writeFile(closure, out.items);
        const r = try c.run(app, &.{ "sync", "--locked", "--toolchain", closure, "--cache", cache });
        const want = try c.fmt("mopm sync: --toolchain {s}: a package's {s} '{s}' is not a safe file name part (no '/', '\\', control characters, '.' or '..')\n", .{ closure, case.field, case.shown });
        rep.same(try c.fmt("a closure with a package {s} '{s}': the refusal", .{ case.field, case.value }), want, r.stderr);
        rep.check(try c.fmt("a closure with a package {s} '{s}': exit 1, no download, nothing written in or outside the project", .{ case.field, case.value }), r.code == 1 and r.stdout.len == 0 and
            std.mem.eql(u8, proj_before, try c.fingerprint(c.path(&.{ c.work, "proj" }))) and !c.exists(c.work, "cache") and !c.exists(c.work, "escape") and
            !c.exists(c.work, "proj/escape") and try c.served() == 0, c.detail(r));
    }
    try rep.finish();
}

test "a locked package that ships a toolchain file with other contents is refused; the same bytes at the same path are accepted" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);
    const mojo_bin = fx.stand_in_files[0];

    const clash = try fx.packageOf(a, c.subdir, "clash", &.{.{ .path = mojo_bin.path, .data = "#!/bin/sh\necho not the compiler\n", .mode = 0o755 }});
    try c.publish("clash", clash);
    const linked = try fx.packageOf(a, c.subdir, "linked", &.{.{ .path = mojo_bin.path, .link = "../lib/liblinked.so", .mode = 0o777 }});
    try c.publish("linked", linked);
    const twin = try fx.packageOf(a, c.subdir, "twin", &.{.{ .path = mojo_bin.path, .data = mojo_bin.data, .mode = mojo_bin.mode }});
    try c.publish("twin", twin);
    // The same file under another spelling, which a check comparing path strings would not see.
    const dotted_path = try c.fmt("bin/./{s}", .{mojo_bin.path["bin/".len..]});
    const dotted = try fx.packageOf(a, c.subdir, "dotted", &.{.{ .path = dotted_path, .data = "#!/bin/sh\necho not the compiler\n", .mode = 0o755 }});
    try c.publish("dotted", dotted);
    // The toolchain's bytes, but not executable: it would leave a compiler that cannot run.
    const plain = try fx.packageOf(a, c.subdir, "plain", &.{.{ .path = mojo_bin.path, .data = mojo_bin.data, .mode = 0o644 }});
    try c.publish("plain", plain);

    for ([_][]const u8{ "clash", "linked" }) |name| {
        _ = try c.project("app", try c.fmt("\"example/greet\" = \"1\"\n\"example/{s}\" = \"1\"", .{name}));
        const r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
        const want = try c.fmt("mopm sync: cannot install into .mopm/env: bin/mojo is installed by both mojo 1.0.0 and mojo-{s} 1.0.0 with different contents; refused; the environment is as it was\n", .{name});
        rep.same(try c.fmt("{s} ships bin/mojo with other contents: the refusal", .{name}), want, r.stderr);
        rep.check(try c.fmt("{s} ships bin/mojo with other contents: exit 1", .{name}), r.code == 1, c.detail(r));
        untouched(c, b, name);
    }

    _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/dotted\" = \"1\"");
    var r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.same("dotted ships bin/./mojo: the refusal", try c.fmt("mopm sync: cannot install into .mopm/env: the package holds the path '{s}', which has a '.' component; a path is written one way only; the environment is as it was\n", .{dotted_path}), r.stderr);
    rep.check("dotted ships bin/./mojo: exit 1", r.code == 1, c.detail(r));
    untouched(c, b, "dotted");

    _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/plain\" = \"1\"");
    r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.same("plain ships bin/mojo with the same bytes but not executable: the refusal", "mopm sync: cannot install into .mopm/env: bin/mojo is installed by both mojo 1.0.0 and mojo-plain 1.0.0 with different permissions; refused; the environment is as it was\n", r.stderr);
    rep.check("plain ships bin/mojo not executable: exit 1", r.code == 1, c.detail(r));
    untouched(c, b, "plain");

    _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/twin\" = \"1\"");
    r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.check("twin ships bin/mojo with the toolchain's bytes: accepted, the file is the toolchain's", r.code == 0 and r.stderr.len == 0 and
        std.mem.eql(u8, c.read(b.env_dir, "bin/mojo") orelse "", mojo_bin.data) and c.exists(b.env_dir, "lib/libtwin.so"), c.detail(r));
    try rep.finish();
}

fn closureOf(stderr: []const u8, key: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, stderr, key) orelse return "";
    const rest = stderr[at + key.len ..];
    return rest[0..@min(64, rest.len)];
}

test "a version 2 lock that records another toolchain closure is refused before any download; a mirror of the recorded one is accepted" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;

    try c.publish("greet", try fx.packageOf(a, c.subdir, "greet", &.{}));
    const t = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const mirror = try c.toolchain("channel/mirror", "mirror.json", "T");
    const cache = try h.join(a, &.{ c.work, "cache" });
    const app = try fx.projectV2(c, "app", "\"example/greet\" = \"1\"");
    const reg = [_][]const u8{ "--registry", c.fake.base };

    var r = try c.run(app, &(.{"lock"} ++ reg));
    rep.check("mopm lock writes a version 2 lock with the closure of the built-in toolchain", r.code == 0 and h.contains(c.read(app, "mopm.lock") orelse "", "\"lock_version\": 2"), c.detail(r));
    const recorded_value = (try c.lockValue(app)).object.get("toolchain").?.object.get(mojo).?.object.get(c.subdir).?.string;

    const before = try c.served();
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", t.closure, "--cache", cache });
    const have = closureOf(r.stderr, "the toolchain to install has closure ");
    const want = try c.fmt("mopm sync: mopm.lock records toolchain closure {s} for mojo {s} on {s}; the toolchain to install has closure {s}; run 'mopm lock' (or pass the --toolchain file it was locked with)\n", .{ recorded_value, mojo, c.subdir, have });
    rep.same("a recorded closure that is not the one to install: the refusal", want, r.stderr);
    rep.check("the refusal names a hash of the toolchain to install, which is not the recorded one", r.code == 1 and have.len == 64 and !std.mem.eql(u8, have, recorded_value), c.detail(r));
    rep.check("nothing was downloaded, no cache directory and no environment were made", try c.served() == before and !c.exists(c.work, "cache") and !c.exists(app, ".mopm"), try c.names(c.path(&.{ app, ".mopm" })));

    // The lock records the closure of the stand-in toolchain: T and its mirror (same pins, other urls) are accepted.
    var v = try c.lockValue(app);
    try v.object.getPtr("toolchain").?.object.getPtr(mojo).?.object.put(c.subdir, .{ .string = have });
    try c.writeLockValue(app, v);
    r = try c.run(app, &.{ "sync", "--locked", "--toolchain", t.closure, "--cache", cache });
    rep.check("the closure the lock records is accepted", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and r.stderr.len == 0, c.detail(r));

    const app_m = try fx.projectV2(c, "app_m", "\"example/greet\" = \"1\"");
    try fs.cwd().copyFile(c.path(&.{ app, "mopm.lock" }), fs.cwd(), c.path(&.{ app_m, "mopm.lock" }), .{});
    r = try c.run(app_m, &.{ "sync", "--locked", "--toolchain", mirror.closure, "--cache", cache });
    rep.check("a mirror of the recorded closure has the same hash and is accepted", r.code == 0 and h.contains(r.stdout, "installed 1 packages for") and r.stderr.len == 0, c.detail(r));
    const rec = c.read(app_m, try c.fmt(".mopm/env/conda-meta/mojo-{s}-{s}.json", .{ mojo, cp.fake_build })) orelse "";
    rep.check("the mirror's environment records the mirror's urls", h.contains(rec, "/channel/mirror/"), rec);
    try rep.finish();
}

test "a short body and an HTTP 404 of a locked file or a toolchain file are refused with the download's message, and leave the old environment" {
    var rig: fx.Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.c;
    const a = c.a;
    const rep = &rig.rep;
    const b = try fx.baseline(c);

    // A locked file the project has not got yet: first with a body cut in two, then not served at all.
    const late = try fx.packageOf(a, c.subdir, "late", &.{});
    try c.publish("late", late);
    const late_file = "mojo-late-1.0.0-" ++ build_tag ++ ".conda";
    const late_url = try c.fmt("{s}/channel/{s}/{s}", .{ c.fake.base, c.subdir, late_file });
    _ = try c.project("app", "\"example/greet\" = \"1\"\n\"example/late\" = \"1\"");
    try c.serve("late", late[0 .. late.len / 2]);
    var r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t }));
    rep.same("a locked file with a short body: the refusal", try c.fmt("mopm sync: {s} is {d} bytes; the pin says {d}; the download is short or broke off; refused\n", .{ late_url, late.len / 2, late.len }), r.stderr);
    rep.check("a locked file with a short body: exit 1 and the file is not kept", r.code == 1 and !c.exists(b.app, ".mopm/pkgs/" ++ late_file), c.detail(r));
    untouched(c, b, "a locked file with a short body");

    try fs.cwd().deleteFile(c.path(&.{ c.fake_dir, "channel", c.subdir, late_file }));
    r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t }));
    rep.same("a locked file the registry does not have: the refusal", try c.fmt("mopm sync: {s} answered HTTP 404: late 1.0.0 has been taken down or is unavailable\n", .{late_url}), r.stderr);
    rep.check("a locked file the registry does not have: exit 1", r.code == 1, c.detail(r));
    untouched(c, b, "a locked file the registry does not have");

    // A toolchain file of T2, which the cache has not got: a short body, then no file.
    _ = try c.project("app", "\"example/greet\" = \"1\"");
    const t2_mojo = b.t2.files[0];
    const t2_url = try c.fmt("{s}/{s}", .{ c.fake.base, t2_mojo.served });
    const served_path = c.path(&.{ c.fake_dir, t2_mojo.served });
    try h.writeFile(served_path, t2_mojo.bytes[0 .. t2_mojo.bytes.len / 3]);
    r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.same("a toolchain file with a short body: the refusal", try c.fmt("mopm sync: {s} is {d} bytes; the pin says {d}; the download is short or broke off; refused\n", .{ t2_url, t2_mojo.bytes.len / 3, t2_mojo.bytes.len }), r.stderr);
    rep.check("a toolchain file with a short body: exit 1", r.code == 1, c.detail(r));
    untouched(c, b, "a toolchain file with a short body");

    try fs.cwd().deleteFile(served_path);
    r = try c.run(b.app, try c.cat(&.{ &.{"sync"}, b.reg, b.with_t2 }));
    rep.same("a toolchain file the registry does not have: the refusal", try c.fmt("mopm sync: {s} answered HTTP 404\n", .{t2_url}), r.stderr);
    rep.check("a toolchain file the registry does not have: exit 1", r.code == 1, c.detail(r));
    untouched(c, b, "a toolchain file the registry does not have");
    try rep.finish();
}
