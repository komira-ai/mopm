//! pixi installs mopm packages from one conda channel per namespace (docs/design/namespaces.md, sections 5 and 13,
//! ns-H2; spec/channel.md). The pixi of this repository (0.79.0, tools/install_pixi.sh) is driven with the commands the
//! channel spec gives a pixi user, against channels this test builds and serves on loopback:
//!
//!   <base>/toolchain/   a stand-in `mojo-compiler 1.0.0` (every mopm package depends on its exact compiler), so no
//!                       conda channel on the network is needed
//!   <base>/komira-ai/   `mojo-komira-ai.json` 0.1.0, and 0.1.1 yanked (listed under `removed`, its file still there)
//!   <base>/alice/       `mojo-alice.report` 0.2.0, which depends on `komira-ai/json` "0.1": a closure over two namespaces
//!   <base>/bob/         `mojo-bob.json` 0.1.0: another namespace's package with the import name `json`
//!
//! Each package is a `.conda` written by `mopm pack` (the built CLI, given a stand-in `.mojoc`), so what pixi unpacks is
//! what a publisher uploads. Each channel's `repodata.json` is written here as spec/channel.md says the registry writes
//! it: four subdirs, `packages` empty, an entry per published file with the `depends` of the archive's
//! `info/index.json`, yanked files under `removed`.
//!
//! What it asserts, one pixi workspace per case:
//!   1. `pixi workspace channel add <base>/komira-ai/` then `pixi add mojo-komira-ai.json` installs
//!      `lib/mojo/json.mojoc` of 0.1.0 (the yanked 0.1.1 is not chosen) and the lock names the namespace's channel.
//!   2. With the channels of both namespaces, `pixi add mojo-alice.report` installs the closure, each package from its
//!      own namespace's channel.
//!   3. With only alice's channel, the solve fails naming `mojo-komira-ai.json`: a closure needs every namespace's
//!      channel, and nothing is installed.
//!   4. With alice's and bob's channels, the solve fails the same way: `mojo-bob.json` has the import name `json` but
//!      is another package, so the namespace in the conda name keeps a dependency to the one package it names.
//!   5. `mojo-komira-ai.json` and `mojo-bob.json` together install: pixi does not refuse two packages that write the
//!      same `lib/mojo/json.mojoc`, and one file is left. mopm refuses that set (section 4); this case shows why a
//!      pixi user cannot count on pixi for it.
//!
//! pixi gets its own home, configuration and cache directories under the test's temporary directory, and only loopback
//! channels: it reads no global configuration and no channel on the network. The farm has no pixi, so no Buck2 target
//! runs this file: `zig build test-pixi -Dpixi=<pixi binary>` runs it, and so does the `pixi-channels` job of ci.yml.

const std = @import("std");
const Allocator = std.mem.Allocator;
const h = @import("harness.zig");
const conda_pkg = @import("conda_pkg.zig");

/// The exact Mojo the packages are packed for: their build string is `mojo1.0.0_0`, their `depends` names
/// `mojo-compiler ==1.0.0`.
const compiler = "1.0.0";
const build = "mojo" ++ compiler ++ "_0";
const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };

/// One version of one package of the channels.
const Pkg = struct {
    namespace: []const u8,
    name: []const u8,
    version: []const u8,
    /// The `[dependencies]` lines of its mopm.toml.
    deps: []const u8 = "",
    yanked: bool = false,
};

const pkgs = [_]Pkg{
    .{ .namespace = "komira-ai", .name = "json", .version = "0.1.0" },
    .{ .namespace = "komira-ai", .name = "json", .version = "0.1.1", .yanked = true },
    .{ .namespace = "alice", .name = "report", .version = "0.2.0", .deps = "\"komira-ai/json\" = \"0.1\"\n" },
    .{ .namespace = "bob", .name = "json", .version = "0.1.0" },
};

/// A file of a channel: what `repodata.json` lists for it.
const Entry = struct {
    channel: []const u8,
    conda_name: []const u8,
    version: []const u8,
    build: []const u8,
    file_name: []const u8,
    bytes: []const u8,
    depends: []const []const u8,
    yanked: bool,
};

/// The `.mojoc` bytes of a package: its full name and version, so an installed file says which package it came from.
fn mojocText(a: Allocator, p: Pkg) ![]u8 {
    return h.fmt(a, "{s}/{s} {s}\n", .{ p.namespace, p.name, p.version });
}

/// `mopm pack` of `p`, with a stand-in `.mojoc`: the `.conda` file and the `depends` of its `info/index.json`.
fn pack(a: Allocator, rep: *h.Report, mopm: []const u8, env: *const std.process.EnvMap, work: []const u8, p: Pkg) !Entry {
    const dir = try h.join(a, &.{ work, "pack", try h.fmt(a, "{s}.{s}-{s}", .{ p.namespace, p.name, p.version }) });
    const manifest = try h.join(a, &.{ dir, "mopm.toml" });
    const mojoc = try h.join(a, &.{ dir, try h.fmt(a, "{s}.mojoc", .{p.name}) });
    try h.writeFile(manifest, try h.fmt(a, "[package]\nname = \"{s}/{s}\"\nversion = \"{s}\"\n\n[toolchain]\nmojo = \"{s}\"\n\n[dependencies]\n{s}", .{ p.namespace, p.name, p.version, compiler, p.deps }));
    try h.writeFile(mojoc, try mojocText(a, p));
    const out = try h.join(a, &.{ dir, "dist" });
    const r = try h.run(a, &.{ mopm, "pack", "--compiler", compiler, "--mojoc", mojoc, "--manifest", manifest, "-o", out }, env, .{ .cwd = dir });
    rep.check(try h.fmt(a, "mopm pack {s}/{s} {s}", .{ p.namespace, p.name, p.version }), r.code == 0 and !r.signaled, r.text);
    if (r.code != 0 or r.signaled) return error.PackFailed;
    const conda_name = try h.fmt(a, "mojo-{s}.{s}", .{ p.namespace, p.name });
    const file_name = try h.fmt(a, "{s}-{s}-{s}.conda", .{ conda_name, p.version, build });
    const bytes = try h.readFile(a, try h.join(a, &.{ out, "noarch", file_name }));
    return .{
        .channel = p.namespace,
        .conda_name = conda_name,
        .version = p.version,
        .build = build,
        .file_name = file_name,
        .bytes = bytes,
        .depends = try indexDepends(a, bytes),
        .yanked = p.yanked,
    };
}

/// `depends` of the `info/index.json` in a `.conda` that `mopm pack` wrote. Its zip entries are stored and its zstd
/// frames are raw blocks (src/core/conda.zig), so the index's bytes are in the file as written: one JSON object with
/// no nested object, starting `{"build":"mojo`.
fn indexDepends(a: Allocator, conda: []const u8) ![]const []const u8 {
    const start = std.mem.indexOf(u8, conda, "{\"build\":\"mojo") orelse return error.NoIndexJson;
    const end = std.mem.indexOfScalarPos(u8, conda, start, '}') orelse return error.NoIndexJson;
    const index = try h.parseJson(a, conda[start .. end + 1]);
    if (index != .object) return error.NoIndexJson;
    const depends = index.object.get("depends") orelse return error.NoIndexJson;
    if (depends != .array) return error.NoIndexJson;
    const out = try a.alloc([]const u8, depends.array.items.len);
    for (depends.array.items, out) |d, *o| {
        if (d != .string) return error.NoIndexJson;
        o.* = d.string;
    }
    return out;
}

/// `repodata.json` of `subdir` of one channel, as spec/channel.md has the registry write it: keys sorted, `packages`
/// empty, every published `.conda` of the subdir under `packages.conda`, a yanked one's file name under `removed`.
fn repodata(a: Allocator, entries: []const Entry, channel: []const u8, subdir: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var ws = std.json.writeStream(out.writer(), .{});
    try ws.beginObject();
    try ws.objectField("info");
    try ws.write(.{ .subdir = subdir });
    try ws.objectField("packages");
    try ws.beginObject();
    try ws.endObject();
    try ws.objectField("packages.conda");
    try ws.beginObject();
    for (entries) |e| {
        if (e.yanked or !std.mem.eql(u8, e.channel, channel) or !std.mem.eql(u8, subdir, "noarch")) continue;
        try ws.objectField(e.file_name);
        try ws.write(.{
            .build = e.build,
            .build_number = 0,
            .depends = e.depends,
            .name = e.conda_name,
            .sha256 = try conda_pkg.sha256Hex(a, e.bytes),
            .size = e.bytes.len,
            .subdir = subdir,
            .version = e.version,
        });
    }
    try ws.endObject();
    try ws.objectField("removed");
    try ws.beginArray();
    for (entries) |e| {
        if (e.yanked and std.mem.eql(u8, e.channel, channel) and std.mem.eql(u8, subdir, "noarch")) try ws.write(e.file_name);
    }
    try ws.endArray();
    try ws.endObject();
    try out.append('\n');
    return out.items;
}

/// Writes every channel under `root`: `<root>/<channel>/<subdir>/` with its repodata and its files (a yanked file
/// stays, as on the registry). `current_repodata.json` is the same document: in these channels every name's newest
/// published version is its only published one.
fn writeChannels(a: Allocator, root: []const u8, entries: []const Entry) !void {
    var seen = std.StringHashMap(void).init(a);
    for (entries) |e| {
        try h.writeFile(try h.join(a, &.{ root, e.channel, "noarch", e.file_name }), e.bytes);
        if ((try seen.getOrPut(e.channel)).found_existing) continue;
        for (subdirs) |s| {
            const doc = try repodata(a, entries, e.channel, s);
            try h.writeFile(try h.join(a, &.{ root, e.channel, s, "repodata.json" }), doc);
            try h.writeFile(try h.join(a, &.{ root, e.channel, s, "current_repodata.json" }), doc);
        }
    }
}

/// A static file server on 127.0.0.1 with a port the system picks, for the channels under `root`: one request per
/// connection, each on its own thread, so pixi's parallel downloads never wait on one another. It runs until the
/// process ends.
const Channels = struct {
    server: std.net.Server,
    root: []const u8,

    fn base(self: *const Channels, a: Allocator) ![]u8 {
        return h.fmt(a, "http://127.0.0.1:{d}", .{self.server.listen_address.getPort()});
    }

    fn serve(self: *Channels) void {
        while (true) {
            const conn = self.server.accept() catch return;
            const t = std.Thread.spawn(.{}, Channels.connection, .{ self, conn }) catch {
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    fn connection(self: *Channels, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [16 * 1024]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        var req = http.receiveHead() catch return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.answer(arena.allocator(), &req) catch return;
    }

    fn answer(self: *Channels, a: Allocator, req: *std.http.Server.Request) !void {
        const target = req.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (path.len < 2 or path[0] != '/' or std.mem.indexOf(u8, path, "..") != null) return req.respond("", .{ .status = .not_found, .keep_alive = false });
        const body = std.fs.cwd().readFileAlloc(a, try h.join(a, &.{ self.root, path[1..] }), 64 << 20) catch return req.respond("", .{ .status = .not_found, .keep_alive = false });
        const content_type = if (std.mem.endsWith(u8, path, ".json")) "application/json" else "application/octet-stream";
        return req.respond(body, .{ .status = .ok, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = content_type }} });
    }
};

/// Runs pixi in `ws` with `args`.
fn pixi(a: Allocator, exe: []const u8, env: *const std.process.EnvMap, ws: []const u8, args: []const []const u8) !h.Ran {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{exe}, args });
    return h.run(a, argv, env, .{ .cwd = ws });
}

/// A new pixi workspace in `<work>/<name>` whose channels are the stand-in toolchain's and those of `namespaces`,
/// added the way spec/channel.md tells a pixi user to (`pixi workspace channel add <channel>/<namespace>/`).
fn workspace(a: Allocator, rep: *h.Report, exe: []const u8, env: *const std.process.EnvMap, work: []const u8, base: []const u8, name: []const u8, namespaces: []const []const u8) ![]u8 {
    const ws = try h.join(a, &.{ work, "ws", name });
    try std.fs.cwd().makePath(ws);
    var r = try pixi(a, exe, env, ws, &.{ "init", "--channel", try h.fmt(a, "{s}/toolchain/", .{base}), ws });
    rep.check(try h.fmt(a, "{s}: pixi init with the stand-in toolchain's channel", .{name}), r.code == 0 and !r.signaled, r.text);
    for (namespaces) |ns| {
        r = try pixi(a, exe, env, ws, &.{ "workspace", "channel", "add", try h.fmt(a, "{s}/{s}/", .{ base, ns }) });
        rep.check(try h.fmt(a, "{s}: pixi workspace channel add {s}'s channel", .{ name, ns }), r.code == 0 and !r.signaled, r.text);
    }
    return ws;
}

/// The bytes of `lib/mojo/<file>` in the default environment of `ws`, or null when there is no such file.
fn installed(a: Allocator, ws: []const u8, file: []const u8) !?[]u8 {
    return std.fs.cwd().readFileAlloc(a, try h.join(a, &.{ ws, ".pixi", "envs", "default", "lib", "mojo", file }), 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// Whether the default environment of `ws` holds the conda record `<file stem>.json` of `entry`.
fn recorded(a: Allocator, ws: []const u8, entry: Entry) !bool {
    const stem = entry.file_name[0 .. entry.file_name.len - ".conda".len];
    const path = try h.join(a, &.{ ws, ".pixi", "envs", "default", "conda-meta", try h.fmt(a, "{s}.json", .{stem}) });
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn same(x: ?[]const u8, y: []const u8) bool {
    return x != null and std.mem.eql(u8, x.?, y);
}

test "pixi 0.79 installs mopm packages from one channel per namespace, and a closure over two namespaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const mopm = try h.toolPath(a, "MOPM");
    const pixi_exe = try h.toolPath(a, "PIXI");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);

    // pixi reads no configuration but this test's: its home, configuration and cache directories are new and empty.
    const parent = try h.environ(a);
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", parent.get("PATH") orelse "/usr/bin:/bin");
    try env.put("HOME", try h.join(a, &.{ work, "home" }));
    try env.put("XDG_CONFIG_HOME", try h.join(a, &.{ work, "home", ".config" }));
    try env.put("XDG_CACHE_HOME", try h.join(a, &.{ work, "home", ".cache" }));
    try env.put("PIXI_HOME", try h.join(a, &.{ work, "home", ".pixi" }));
    try env.put("PIXI_CACHE_DIR", try h.join(a, &.{ work, "cache" }));
    try env.put("RATTLER_CACHE_DIR", try h.join(a, &.{ work, "cache" }));
    try env.put("NO_COLOR", "1");
    try std.fs.cwd().makePath(try h.join(a, &.{ work, "home", ".config" }));

    // The channels: the four packages packed by mopm, and the stand-in compiler.
    var entries = std.ArrayList(Entry).init(a);
    for (pkgs) |p| try entries.append(try pack(a, &rep, mopm, &env, work, p));
    const json = entries.items[0];
    const json_yanked = entries.items[1];
    const report = entries.items[2];
    const bob_json = entries.items[3];
    rep.check("the archive of alice/report depends on its exact compiler and on komira-ai/json by its namespaced conda name", report.depends.len == 2 and
        std.mem.eql(u8, report.depends[0], "mojo-compiler ==" ++ compiler) and std.mem.startsWith(u8, report.depends[1], "mojo-komira-ai.json "), try std.mem.join(a, ", ", report.depends));
    const stand_in = try conda_pkg.package(a, "mojo-compiler", compiler, "stand_0", "noarch", &.{}, &.{
        .{ .path = "share/mopm-pixi-test/mojo-compiler.txt", .data = "a stand-in of mojo-compiler for the pixi channel test\n" },
    });
    try entries.append(.{ .channel = "toolchain", .conda_name = "mojo-compiler", .version = compiler, .build = "stand_0", .file_name = "mojo-compiler-" ++ compiler ++ "-stand_0.conda", .bytes = stand_in, .depends = &.{}, .yanked = false });
    const root = try h.join(a, &.{ work, "channels" });
    try writeChannels(a, root, entries.items);

    // The server outlives the test's arena (its thread runs until the process ends), so it is never freed.
    const server = try std.heap.page_allocator.create(Channels);
    server.* = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true }), .root = try std.heap.page_allocator.dupe(u8, root) };
    (try std.Thread.spawn(.{}, Channels.serve, .{server})).detach();
    const base = try server.base(a);
    const json_url = try h.fmt(a, "{s}/komira-ai/noarch/{s}", .{ base, json.file_name });
    const report_url = try h.fmt(a, "{s}/alice/noarch/{s}", .{ base, report.file_name });

    // 1. The two commands of spec/channel.md, for komira-ai/json.
    {
        const ws = try workspace(a, &rep, pixi_exe, &env, work, base, "one-namespace", &.{"komira-ai"});
        const r = try pixi(a, pixi_exe, &env, ws, &.{ "add", "mojo-komira-ai.json" });
        rep.check("one namespace: pixi add mojo-komira-ai.json succeeds", r.code == 0 and !r.signaled, r.text);
        rep.check("one namespace: lib/mojo/json.mojoc is that of komira-ai/json 0.1.0, not of the yanked 0.1.1", same(try installed(a, ws, "json.mojoc"), try mojocText(a, pkgs[0])), "another json.mojoc, or none");
        const meta = try installed(a, ws, "json.mopm.json") orelse "";
        rep.check("one namespace: lib/mojo/json.mopm.json names the full name komira-ai/json", h.contains(meta, "\"name\":\"komira-ai/json\""), meta);
        const lock = h.readFile(a, try h.join(a, &.{ ws, "pixi.lock" })) catch "";
        rep.check("one namespace: pixi.lock takes the file from the komira-ai channel", h.contains(lock, json_url), lock);
        rep.check("one namespace: pixi.lock does not name the yanked 0.1.1", !h.contains(lock, json_yanked.file_name), lock);
    }

    // 2. A closure over two namespaces: alice/report needs komira-ai/json.
    {
        const ws = try workspace(a, &rep, pixi_exe, &env, work, base, "two-namespaces", &.{ "alice", "komira-ai" });
        const r = try pixi(a, pixi_exe, &env, ws, &.{ "add", "mojo-alice.report" });
        rep.check("two namespaces: pixi add mojo-alice.report succeeds", r.code == 0 and !r.signaled, r.text);
        rep.check("two namespaces: lib/mojo/report.mojoc is that of alice/report 0.2.0", same(try installed(a, ws, "report.mojoc"), try mojocText(a, pkgs[2])), "another report.mojoc, or none");
        rep.check("two namespaces: its dependency's lib/mojo/json.mojoc is that of komira-ai/json 0.1.0", same(try installed(a, ws, "json.mojoc"), try mojocText(a, pkgs[0])), "another json.mojoc, or none");
        const lock = h.readFile(a, try h.join(a, &.{ ws, "pixi.lock" })) catch "";
        rep.check("two namespaces: pixi.lock takes each file from its own namespace's channel", h.contains(lock, report_url) and h.contains(lock, json_url), lock);
    }

    // 3. and 4. The dependency's channel missing, alone or beside another namespace with a package imported as `json`.
    const failing = [_]struct { name: []const u8, namespaces: []const []const u8 }{
        .{ .name = "channel-missing", .namespaces = &.{"alice"} },
        .{ .name = "other-namespace", .namespaces = &.{ "alice", "bob" } },
    };
    for (failing) |f| {
        const ws = try workspace(a, &rep, pixi_exe, &env, work, base, f.name, f.namespaces);
        const r = try pixi(a, pixi_exe, &env, ws, &.{ "add", "mojo-alice.report" });
        rep.check(try h.fmt(a, "{s}: pixi add mojo-alice.report fails, naming mojo-komira-ai.json", .{f.name}), r.code != 0 and !r.signaled and h.contains(r.text, "mojo-komira-ai.json"), r.text);
        rep.check(try h.fmt(a, "{s}: nothing is installed", .{f.name}), (try installed(a, ws, "report.mojoc")) == null and (try installed(a, ws, "json.mojoc")) == null, "a file of the closure is installed");
    }

    // 5. Two packages with one import name, from two namespaces.
    {
        const ws = try workspace(a, &rep, pixi_exe, &env, work, base, "one-import-name", &.{ "komira-ai", "bob" });
        const r = try pixi(a, pixi_exe, &env, ws, &.{ "add", "mojo-komira-ai.json", "mojo-bob.json" });
        rep.check("one import name: pixi add of both packages succeeds", r.code == 0 and !r.signaled, r.text);
        rep.check("one import name: both are installed", try recorded(a, ws, json) and try recorded(a, ws, bob_json), "a conda-meta record is missing");
        const file = try installed(a, ws, "json.mojoc");
        rep.check("one import name: one lib/mojo/json.mojoc is left, that of one of the two", same(file, try mojocText(a, pkgs[0])) or same(file, try mojocText(a, pkgs[3])), file orelse "none");
    }

    try rep.finish();
}
