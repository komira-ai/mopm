//! What the `mopm sync` drivers share (sync_e2e_test.zig, sync_state_e2e_test.zig, sync_refuse_e2e_test.zig,
//! sync_cache_e2e_test.zig): the built CLI run against mopm-fake-registry with no pixi (PATH names an empty directory),
//! packages published into the fake's sparse index and channel, a stand-in toolchain closure, and a fingerprint of a
//! directory tree that records every entry's kind, symlink target and executable bit, so "the environment is as it
//! was" is asserted on links and modes as well as on bytes. Standard library, harness.zig and conda_pkg.zig only.

const std = @import("std");
const h = @import("harness.zig");
const cp = @import("conda_pkg.zig");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const mojo = "1.0.0";
pub const build_tag = "mojo" ++ mojo ++ "_0";
/// What `.mopm` holds after a sync: the environment, the locked files and the project lock.
pub const beside = "env,pkgs,sync.lock";

/// A test's world: a scratch directory, the fake registry, and the context the checks run in. `init` fills it in place
/// (the context points into it, so it must not move).
pub const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    rep: h.Report,
    fake: h.Fake,
    c: Cx,

    pub fn init(self: *Rig) !void {
        self.arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = self.arena_state.allocator();
        self.tmp = std.testing.tmpDir(.{});
        self.rep = .{};
        const work = try h.tmpPath(a, &self.tmp);
        // PATH names an empty directory: no pixi, nor anything else, can be run by sync.
        const empty_bin = try h.join(a, &.{ work, "empty-bin" });
        try fs.cwd().makePath(empty_bin);
        const home = try h.join(a, &.{ work, "home" });
        try fs.cwd().makePath(home);
        var env = std.process.EnvMap.init(a);
        try env.put("PATH", empty_bin);
        try env.put("HOME", home);
        const fake_dir = try h.join(a, &.{ work, "fake" });
        self.fake = try h.Fake.start(a, try h.toolPath(a, "MOPM_FAKE_REGISTRY"), fake_dir);
        self.c = .{ .a = a, .rep = &self.rep, .mopm = try h.toolPath(a, "MOPM"), .work = work, .home = home, .env = env, .fake = &self.fake, .fake_dir = fake_dir, .subdir = cp.hostSubdir(), .entries = std.ArrayList([]const u8).init(a) };
    }

    pub fn deinit(self: *Rig) void {
        self.fake.close();
        self.tmp.cleanup();
        self.arena_state.deinit();
    }
};

pub const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    work: []const u8,
    home: []const u8,
    env: std.process.EnvMap,
    fake: *h.Fake,
    fake_dir: []const u8,
    subdir: []const u8,
    /// The `packages.conda` entries of the channel's repodata.json, one per published package.
    entries: std.ArrayList([]const u8),

    pub const Out = struct { code: u8, stdout: []const u8, stderr: []const u8 };

    pub fn fmt(c: *Cx, comptime f: []const u8, args: anytype) ![]u8 {
        return h.fmt(c.a, f, args);
    }

    pub fn path(c: *Cx, parts: []const []const u8) []const u8 {
        return h.join(c.a, parts) catch "";
    }

    /// The argument lists joined in order.
    pub fn cat(c: *Cx, parts: []const []const []const u8) ![]const []const u8 {
        return std.mem.concat(c.a, []const u8, parts);
    }

    /// `mopm <args>` in `dir`, standard output and standard error apart.
    pub fn run(c: *Cx, dir: []const u8, args: []const []const u8) !Out {
        return c.runIn(dir, args, &c.env);
    }

    /// `run` with exactly the environment `env`.
    pub fn runIn(c: *Cx, dir: []const u8, args: []const []const u8, env: *const std.process.EnvMap) !Out {
        const errf = c.path(&.{ c.work, "stderr.txt" });
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        const r = try h.run(c.a, argv, env, .{ .cwd = dir, .capture = .stdout, .stderr_path = errf });
        return .{ .code = if (r.signaled) 255 else r.code, .stdout = r.text, .stderr = try h.readFile(c.a, errf) };
    }

    pub fn detail(c: *Cx, r: Out) []const u8 {
        return c.fmt("exit {d}\n{s}\n{s}", .{ r.code, r.stdout, r.stderr }) catch "";
    }

    pub fn read(c: *Cx, dir: []const u8, rel: []const u8) ?[]u8 {
        return h.readFile(c.a, c.path(&.{ dir, rel })) catch null;
    }

    /// Whether `rel` below `dir` is there.
    pub fn exists(c: *Cx, dir: []const u8, rel: []const u8) bool {
        return if (fs.cwd().access(c.path(&.{ dir, rel }), .{})) true else |_| false;
    }

    /// The names in `dir`, sorted and joined by commas; "" when it is not there.
    pub fn names(c: *Cx, dir: []const u8) ![]const u8 {
        var d = fs.cwd().openDir(dir, .{ .iterate = true }) catch return "";
        defer d.close();
        var list = std.ArrayList([]const u8).init(c.a);
        var it = d.iterate();
        while (try it.next()) |e| try list.append(try c.a.dupe(u8, e.name));
        h.sortStrings(list.items);
        return std.mem.join(c.a, ",", list.items);
    }

    /// Every entry under `dir`, one line each: its path and kind, then for a file its executable bit and its bytes'
    /// sha256, for a symbolic link its target. A fingerprint of an environment (or of a project tree); "" when `dir` is
    /// not there.
    pub fn fingerprint(c: *Cx, dir: []const u8) ![]const u8 {
        var d = fs.cwd().openDir(dir, .{ .iterate = true }) catch return "";
        defer d.close();
        var walker = try d.walk(c.a);
        defer walker.deinit();
        var lines = std.ArrayList([]const u8).init(c.a);
        while (try walker.next()) |e| {
            switch (e.kind) {
                .file => {
                    const st = try d.statFile(e.path);
                    const bytes = try d.readFileAlloc(c.a, e.path, 64 << 20);
                    try lines.append(try c.fmt("file {s} exec={} {s}", .{ e.path, st.mode & 0o111 != 0, try cp.sha256Hex(c.a, bytes) }));
                },
                .sym_link => {
                    var buf: [fs.max_path_bytes]u8 = undefined;
                    try lines.append(try c.fmt("link {s} -> {s}", .{ e.path, try d.readLink(e.path, &buf) }));
                },
                .directory => try lines.append(try c.fmt("dir {s}", .{e.path})),
                else => try lines.append(try c.fmt("other {s}", .{e.path})),
            }
        }
        h.sortStrings(lines.items);
        return std.mem.join(c.a, "\n", lines.items);
    }

    /// Whether anything below `dir` is a half-written download (`*.part-*`) or a half-built environment.
    pub fn leftovers(c: *Cx, dir: []const u8) !bool {
        var d = fs.cwd().openDir(dir, .{ .iterate = true }) catch return false;
        defer d.close();
        var walker = try d.walk(c.a);
        defer walker.deinit();
        while (try walker.next()) |e| {
            if (std.mem.indexOf(u8, e.basename, ".part-") != null or std.mem.indexOf(u8, e.basename, ".env.tmp-") != null) return true;
        }
        return false;
    }

    /// How many .conda files the fake has served so far.
    pub fn served(c: *Cx) !i64 {
        const v = try c.fake.control(c.a, "/served", "{}");
        return v.object.get("conda").?.integer;
    }

    pub fn project(c: *Cx, name: []const u8, deps: []const u8) ![]const u8 {
        const d = c.path(&.{ c.work, "proj", name });
        try fs.cwd().makePath(d);
        try h.writeFile(c.path(&.{ d, "mopm.toml" }), try c.fmt(
            \\[package]
            \\name = "example/app"
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
    pub fn publish(c: *Cx, name: []const u8, data: []const u8) !void {
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
    pub fn serve(c: *Cx, name: []const u8, data: []const u8) !void {
        const p = c.path(&.{ c.fake_dir, "channel", c.subdir, try c.fmt("mojo-{s}-1.0.0-{s}.conda", .{ name, build_tag }) });
        try fs.cwd().makePath(std.fs.path.dirname(p).?);
        try h.writeFile(p, data);
    }

    /// The stand-in toolchain `variant` served below `channel_dir`, with an executable `bin/mojo` and a symbolic link
    /// `bin/mojo-link` to it besides the marker files, so a check that the environment is as it was sees both kinds.
    pub fn toolchain(c: *Cx, channel_dir: []const u8, closure_name: []const u8, variant: []const u8) !cp.Toolchain {
        return cp.fakeToolchainWith(c.a, c.fake_dir, c.fake.base, channel_dir, c.subdir, mojo, c.path(&.{ c.work, closure_name }), variant, &stand_in_files);
    }

    /// The text of the project's mopm.lock as JSON.
    pub fn lockValue(c: *Cx, app: []const u8) !std.json.Value {
        return h.parseJson(c.a, c.read(app, "mopm.lock") orelse return error.NoLock);
    }

    pub fn writeLockValue(c: *Cx, app: []const u8, v: std.json.Value) !void {
        var out = std.ArrayList(u8).init(c.a);
        try std.json.stringify(v, .{ .whitespace = .indent_2 }, out.writer());
        try out.append('\n');
        try h.writeFile(c.path(&.{ app, "mopm.lock" }), out.items);
    }
};

/// What the stand-in toolchain's `mojo` package ships besides its marker.
pub const stand_in_files = [_]cp.Entry{
    .{ .path = "bin/mojo", .data = "#!/bin/sh\necho stand-in mojo\n", .mode = 0o755 },
    .{ .path = "bin/mojo-link", .link = "mojo", .mode = 0o777 },
};

/// The package `name` 1.0.0 as `mopm pack` lays one out: its metadata, one library, a link to it, and `extra`.
pub fn packageOf(a: Allocator, subdir: []const u8, name: []const u8, extra: []const cp.Entry) ![]u8 {
    const meta = try h.fmt(a, "{{\"deps\": [], \"name\": \"{s}\", \"schema\": 1, \"version\": \"1.0.0\"}}\n", .{name});
    const base = [_]cp.Entry{
        .{ .path = try h.fmt(a, "lib/mojo/{s}.mopm.json", .{name}), .data = meta },
        .{ .path = try h.fmt(a, "lib/lib{s}.so", .{name}), .data = try h.fmt(a, "the library of {s}\n", .{name}), .mode = 0o755 },
        .{ .path = try h.fmt(a, "lib/lib{s}-current.so", .{name}), .link = try h.fmt(a, "lib{s}.so", .{name}), .mode = 0o777 },
    };
    return cp.package(a, try h.fmt(a, "mojo-{s}", .{name}), "1.0.0", build_tag, subdir, &.{"mojo-compiler ==" ++ mojo}, try std.mem.concat(a, cp.Entry, &.{ &base, extra }));
}

/// A package whose payload holds one whole file and then the start of a second one: the unpack fails in the middle.
pub fn brokenPackage(a: Allocator, subdir: []const u8) ![]u8 {
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

/// A project `app` that has been synced once with the stand-in toolchain T (and a second toolchain T2 with other bytes
/// that has not been used), the state the failure and repair drivers start from.
pub const Base = struct {
    app: []const u8,
    env_dir: []const u8,
    cache: []const u8,
    greet: []const u8,
    greet_file: []const u8,
    t: cp.Toolchain,
    t2: cp.Toolchain,
    /// `--registry <fake>`.
    reg: []const []const u8,
    /// `--toolchain <T> --cache <cache>`, and the same for T2.
    with_t: []const []const u8,
    with_t2: []const []const u8,
    /// The fingerprint of the environment after the first sync.
    print: []const u8,
    stamp: []const u8,
};

/// Publishes greet, writes T and T2, and syncs the project `app` (depending on greet) with T, checking that it worked.
pub fn baseline(c: *Cx) !Base {
    const a = c.a;
    const greet = try packageOf(a, c.subdir, "greet", &.{});
    try c.publish("greet", greet);
    const t = try c.toolchain("channel/toolchain", "toolchain.json", "T");
    const t2 = try c.toolchain("channel/toolchain2", "toolchain2.json", "T2");
    const cache = try h.join(a, &.{ c.work, "cache" });
    const reg = try a.dupe([]const u8, &.{ "--registry", c.fake.base });
    const with_t = try a.dupe([]const u8, &.{ "--toolchain", t.closure, "--cache", cache });
    const with_t2 = try a.dupe([]const u8, &.{ "--toolchain", t2.closure, "--cache", cache });
    const app = try c.project("app", "\"example/greet\" = \"1\"");
    const env_dir = c.path(&.{ app, ".mopm/env" });
    const r = try c.run(app, try c.cat(&.{ &.{"sync"}, reg, with_t }));
    c.rep.check("baseline: the first sync installs greet and T", r.code == 0 and h.contains(r.stdout, "installed 1 packages for"), c.detail(r));
    return .{
        .app = app,
        .env_dir = env_dir,
        .cache = cache,
        .greet = greet,
        .greet_file = "mojo-greet-1.0.0-" ++ build_tag ++ ".conda",
        .t = t,
        .t2 = t2,
        .reg = reg,
        .with_t = with_t,
        .with_t2 = with_t2,
        .print = try c.fingerprint(env_dir),
        .stamp = c.read(env_dir, "conda-meta/mopm-stamp") orelse "",
    };
}

/// A project manifest that lists its Mojo versions under `[package] mojo`, so `mopm lock` writes a version 2 lock.
pub fn projectV2(c: *Cx, name: []const u8, deps: []const u8) ![]const u8 {
    const d = c.path(&.{ c.work, "proj", name });
    try fs.cwd().makePath(d);
    try h.writeFile(c.path(&.{ d, "mopm.toml" }), try c.fmt(
        \\[package]
        \\name = "example/app"
        \\version = "0.1.0"
        \\mojo = ["{s}"]
        \\
        \\[dependencies]
        \\{s}
        \\
    , .{ mojo, deps }));
    return d;
}
