//! End-to-end tests of `--overlay <staged set>` for `mopm add`, `mopm lock` and `mopm sync`, against
//! mopm-fake-registry and a small stand-in that records the requests it gets. Run by Buck2 (//:overlay_e2e); MOPM,
//! MOPM_FAKE_REGISTRY and FAKE_PIXI are the built programs. Each check prints `ok` or `FAIL`.
//!
//! The packages are real: `mopm pack` makes them. libbase 0.1.0 ships a static archive; applib 0.2.0 depends on libbase
//! and on regdep 1.0.0, which only the registry has. The staged set (spec/staged-set.md) holds libbase and applib, with
//! a plan.json written here; the registry holds regdep, and later, as the published registry, all three (its index files
//! and repodata.json are written below the way spec/index.md and spec/channel.md say; the fake does not open archives).
//!
//! What can go red, and why:
//! - the lock `add --overlay` and `lock --overlay` make before the versions are published must be byte for byte the lock
//!   (and the mopm.toml) that `add` makes against the registry after they are: a lock that named the set, a channel or
//!   URL of the set, a sha256 or native hash that is not the published file's, or a missing dependency, differs;
//! - the project holds the two files mopm writes and nothing else, and neither names the set's path;
//! - the set is never written: every file and directory of it (names, sizes, modification times, sha256) is the same
//!   after all of it, and the same check sees a file added to it;
//! - a package the set lacks is resolved from the registry (regdep), and a package neither has is refused as before;
//! - a staged version the registry already holds with other bytes is refused, with both files unchanged, and the same
//!   command succeeds where the registry holds the same bytes;
//! - a closure the set holds entirely asks the registry for its configuration (the lock names the registry's channel)
//!   and for nothing else, and the same request without the set asks for the index file (so the recording can see one);
//!   against the production registry it asks for nothing at all;
//! - `sync --locked --overlay` installs the staged files from the set while the registry holds none of them, and the
//!   same sync without the set fails, the registry's repodata.json not offering them;
//! - a missing set, and a staged file changed after the plan was made, are refused and write nothing.
//!
//! The production registry is not reachable from a test: the check that `--overlay` with the default registry makes a
//! lock with its channel cannot see a request made to it when the machine has a network, and sees it fail when it has
//! none (the farm has none). The property is proven in core/overlay.zig, where the registry's source fails the test if
//! asked for anything.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const head =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
    \\[dependencies]
    \\
;

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    work: []const u8,

    fn ok(cx: *Cx, name: []const u8, good: bool, detail: []const u8) void {
        cx.rep.check(name, good, detail);
    }

    fn fmt(cx: *Cx, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(cx.a, f, args);
    }

    /// `mopm <args>` in `dir`.
    fn run(cx: *Cx, dir: []const u8, args: []const []const u8) !Out {
        const argv = try cx.a.alloc([]const u8, args.len + 1);
        argv[0] = cx.mopm;
        @memcpy(argv[1..], args);
        const r = try std.process.Child.run(.{ .allocator = cx.a, .argv = argv, .cwd = dir, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |code| code,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// A project directory with a mopm.toml holding `deps` under [dependencies].
    fn project(cx: *Cx, name: []const u8, deps: []const u8) ![]u8 {
        const d = try h.join(cx.a, &.{ cx.work, name });
        try h.writeFile(try h.join(cx.a, &.{ d, "mopm.toml" }), try cx.fmt("{s}{s}", .{ head, deps }));
        return d;
    }

    fn read(cx: *Cx, dir: []const u8, name: []const u8) ?[]u8 {
        return h.readFile(cx.a, h.join(cx.a, &.{ dir, name }) catch return null) catch null;
    }

    /// The names of the files below `dir`, sorted and joined by commas.
    fn files(cx: *Cx, dir: []const u8) ![]u8 {
        const names = try h.findFilesAll(cx.a, dir);
        std.mem.sort([]const u8, names, {}, lessStr);
        return std.mem.join(cx.a, ",", names);
    }
};

// ---------------------------------------------------------------- the packages

const Pkg = struct { name: []const u8, version: []const u8, extra: []const u8 = "", archive: ?[]const u8 = null };

/// `mopm pack` of `p` (linux-64) into `out`; the bytes of its file.
fn pack(cx: *Cx, p: Pkg, out: []const u8) ![]u8 {
    const dir = try h.join(cx.a, &.{ cx.work, "src", p.name });
    const manifest = try h.join(cx.a, &.{ dir, "mopm.toml" });
    try h.writeFile(manifest, try cx.fmt("[package]\nname = \"{s}\"\nversion = \"{s}\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n{s}", .{ p.name, p.version, p.extra }));
    const mojoc = try h.join(cx.a, &.{ dir, "lib.mojoc" });
    try h.writeFile(mojoc, "not a real mojoc, only bytes\n");
    var argv = std.ArrayList([]const u8).init(cx.a);
    try argv.appendSlice(&.{ cx.mopm, "pack", "--compiler", "1.0.0", "--manifest", manifest, "-o", out, "--mojoc", try cx.fmt("linux-64={s}", .{mojoc}) });
    if (p.archive) |bytes| {
        const ar = try h.join(cx.a, &.{ dir, "libbase_sys.a" });
        try h.writeFile(ar, bytes);
        try argv.appendSlice(&.{ "--native", try cx.fmt("base_sys=linux-64:{s}", .{ar}) });
    }
    const r = try std.process.Child.run(.{ .allocator = cx.a, .argv = argv.items });
    if (r.term != .Exited or r.term.Exited != 0) {
        std.debug.print("mopm pack of {s} failed: {s}{s}\n", .{ p.name, r.stdout, r.stderr });
        return error.PackFailed;
    }
    return h.readFile(cx.a, try h.join(cx.a, &.{ out, "linux-64", try cx.fmt("mojo-{s}-{s}-mojo1.0.0_0.conda", .{ p.name, p.version }) }));
}

fn fileName(cx: *Cx, name: []const u8, version: []const u8) ![]u8 {
    return cx.fmt("mojo-{s}-{s}-mojo1.0.0_0.conda", .{ name, version });
}

// ---------------------------------------------------------------- the staged set

const Planned = struct { name: []const u8, version: []const u8, skip: bool = false };

/// plan.json for the files of `set`, the members in the order given.
fn writePlan(cx: *Cx, set: []const u8, members: []const Planned) !void {
    var plan = std.ArrayList(u8).init(cx.a);
    try plan.appendSlice("{\"version\":1,\"members\":[");
    for (members, 0..) |m, i| {
        if (i > 0) try plan.append(',');
        if (m.skip) {
            try plan.writer().print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"skip\",\"reason\":\"already published with these bytes\"}}", .{ m.name, m.version });
            continue;
        }
        const name = try fileName(cx, m.name, m.version);
        const bytes = try h.readFile(cx.a, try h.join(cx.a, &.{ set, "linux-64", name }));
        try plan.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"linux-64\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ m.name, m.version, try sha256Hex(cx.a, m.name), name, try sha256Hex(cx.a, bytes), bytes.len },
        );
    }
    try plan.appendSlice("]}\n");
    try h.writeFile(try h.join(cx.a, &.{ set, "plan.json" }), plan.items);
}

/// Every file and directory below `dir`: kind, path, size, modification time and the sha256 of a file's bytes, one
/// line each, sorted. Two snapshots are equal when nothing was added, removed, rewritten or touched.
fn snapshot(a: Allocator, dir_path: []const u8) ![]u8 {
    var lines = std.ArrayList([]const u8).init(a);
    const root = try std.fs.cwd().statFile(dir_path);
    try lines.append(try std.fmt.allocPrint(a, "dir . {d} {d}", .{ root.size, root.mtime }));
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| {
        const st = try dir.statFile(e.path);
        if (e.kind == .file) {
            const bytes = try dir.readFileAlloc(a, e.path, 1 << 28);
            try lines.append(try std.fmt.allocPrint(a, "file {s} {d} {d} {s}", .{ e.path, st.size, st.mtime, try sha256Hex(a, bytes) }));
        } else {
            try lines.append(try std.fmt.allocPrint(a, "dir {s} {d} {d}", .{ e.path, st.size, st.mtime }));
        }
    }
    std.mem.sort([]const u8, lines.items, {}, lessStr);
    return std.mem.join(a, "\n", lines.items);
}

// ---------------------------------------------------------------- the registry

const Dep = struct { name: []const u8, range: []const u8 };
const Native = struct { id: []const u8, soname: []const u8 };
const Entry = struct {
    name: []const u8,
    version: []const u8,
    deps: []const Dep = &.{},
    native: []const Native = &.{},
    bytes: []const u8,
};
const IFile = struct { filename: []const u8, sha256: []const u8, size: usize, subdir: []const u8, url: []const u8 };
const Record = struct {
    v: u8 = 1,
    name: []const u8,
    version: []const u8,
    build: []const u8 = "mojo1.0.0_0",
    state: []const u8 = "published",
    published_at: []const u8 = "2026-10-13T12:00:00Z",
    requires_mojo: []const u8 = "==1.0.0",
    deps: []const Dep,
    native: []const Native,
    files: []const IFile,
    manifest_sha256: []const u8,
};
const RepoEntry = struct {
    build: []const u8 = "mojo1.0.0_0",
    build_number: u8 = 0,
    depends: []const []const u8 = &.{"mojo-compiler ==1.0.0"},
    name: []const u8,
    sha256: []const u8,
    size: usize,
    subdir: []const u8 = "linux-64",
    version: []const u8,
};

fn toJson(a: Allocator, value: anytype) ![]u8 {
    return std.json.stringifyAlloc(a, value, .{ .emit_null_optional_fields = false });
}

/// The index files, the repodata.json and the package files of `entries` under the fake's data directory `root`, as a
/// registry that holds exactly these versions serves them.
fn writeRegistry(cx: *Cx, root: []const u8, base: []const u8, entries: []const Entry) !void {
    const a = cx.a;
    var repo = std.ArrayList(u8).init(a);
    for (entries, 0..) |e, i| {
        const filename = try fileName(cx, e.name, e.version);
        const sha = try sha256Hex(a, e.bytes);
        try h.writeFile(try cx.fmt("{s}/channel/linux-64/{s}", .{ root, filename }), e.bytes);
        const rec = Record{
            .name = e.name,
            .version = e.version,
            .deps = e.deps,
            .native = e.native,
            .files = &.{.{ .filename = filename, .sha256 = sha, .size = e.bytes.len, .subdir = "linux-64", .url = try cx.fmt("{s}/channel/linux-64/{s}", .{ base, filename }) }},
            .manifest_sha256 = try sha256Hex(a, e.name),
        };
        var padded: [4]u8 = "____".*;
        for (e.name[0..@min(e.name.len, 4)], 0..) |b, k| padded[k] = b;
        try h.writeFile(try cx.fmt("{s}/index/{s}/{s}/{s}", .{ root, padded[0..2], padded[2..4], e.name }), try cx.fmt("{s}\n", .{try toJson(a, rec)}));
        if (i > 0) try repo.append(',');
        try repo.writer().print("\"{s}\":{s}", .{ filename, try toJson(a, RepoEntry{ .name = try cx.fmt("mojo-{s}", .{e.name}), .sha256 = sha, .size = e.bytes.len, .version = e.version }) });
    }
    const doc = try cx.fmt("{{\"info\":{{\"subdir\":\"linux-64\"}},\"packages\":{{}},\"packages.conda\":{{{s}}},\"removed\":[]}}\n", .{repo.items});
    try h.writeFile(try cx.fmt("{s}/channel/linux-64/repodata.json", .{root}), doc);
}

// ---------------------------------------------------------------- the stand-in

/// A registry that serves its configuration and answers 404 to everything else, and records what it was asked.
const Stub = struct {
    server: std.net.Server,
    mutex: std.Thread.Mutex = .{},
    paths: std.ArrayListUnmanaged([]const u8) = .{},

    fn base(self: *Stub, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.server.listen_address.getPort()});
    }

    fn serve(self: *Stub) void {
        while (true) {
            const conn = self.server.accept() catch return;
            self.connection(conn);
        }
    }

    fn connection(self: *Stub, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        var buf: [16 * 1024]u8 = undefined;
        var http = std.http.Server.init(conn, &buf);
        while (http.state == .ready) {
            var req = http.receiveHead() catch return;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            self.answer(arena.allocator(), &req) catch return;
        }
    }

    fn answer(self: *Stub, a: Allocator, req: *std.http.Server.Request) !void {
        const target = try std.heap.page_allocator.dupe(u8, req.head.target);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.paths.append(std.heap.page_allocator, target);
        if (std.mem.eql(u8, target, "/index/config.json")) {
            const b = try self.base(a);
            return req.respond(try std.fmt.allocPrint(a,
                \\{{"index_version":1,"stage":"stub","api_url":"{s}/api/v1","channel_url":"{s}/channel/","min_cli_version":"0.0.1"}}
            , .{ b, b }), .{ .status = .ok, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }}, .keep_alive = false });
        }
        return req.respond("{}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }}, .keep_alive = false });
    }

    /// What was asked so far, one path per line.
    fn asked(self: *Stub, a: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.join(a, "\n", self.paths.items);
    }
};

// ---------------------------------------------------------------- the test

test "mopm add, lock and sync with --overlay: a staged set is a read-only channel ahead of the registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    try h.watchdog(280);
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    const pixi_exe = try h.toolPath(a, "FAKE_PIXI");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);
    var cx = Cx{ .a = a, .rep = &rep, .mopm = mopm_exe, .work = work };

    // --- the packages, and the staged set
    h.stage = "packing";
    const archive = "!<arch>\nlibbase native, linux-64\n";
    const set = try h.join(a, &.{ work, "set" });
    const regpack = try h.join(a, &.{ work, "regpack" });
    const base_bytes = try pack(&cx, .{ .name = "libbase", .version = "0.1.0", .extra = "[native.base_sys]\nkind = \"static\"\n", .archive = archive }, set);
    const app_bytes = try pack(&cx, .{ .name = "applib", .version = "0.2.0", .extra = "[dependencies]\nlibbase = \"0.1\"\nregdep = \"1\"\n" }, set);
    const reg_bytes = try pack(&cx, .{ .name = "regdep", .version = "1.0.0" }, regpack);
    try writePlan(&cx, set, &.{ .{ .name = "libbase", .version = "0.1.0" }, .{ .name = "applib", .version = "0.2.0" }, .{ .name = "regdep", .version = "1.0.0", .skip = true } });
    const before = try snapshot(a, set);
    cx.ok("the staged set holds plan.json and the two files, and the snapshot lists them", has(before, "file plan.json") and
        has(before, "mojo-libbase-0.1.0-mojo1.0.0_0.conda") and has(before, "mojo-applib-0.2.0-mojo1.0.0_0.conda"), before);

    const libbase_entry = Entry{ .name = "libbase", .version = "0.1.0", .native = &.{.{ .id = "base_sys", .soname = "libbase_sys.a" }}, .bytes = base_bytes };
    const applib_entry = Entry{ .name = "applib", .version = "0.2.0", .deps = &.{ .{ .name = "libbase", .range = "0.1" }, .{ .name = "regdep", .range = "1" } }, .bytes = app_bytes };
    const regdep_entry = Entry{ .name = "regdep", .version = "1.0.0", .bytes = reg_bytes };

    h.stage = "starting the fake registry";
    const fake_dir = try h.join(a, &.{ work, "fake" });
    var fake = try h.Fake.start(a, fake_exe, fake_dir);
    defer fake.close();
    const channel = try cx.fmt("{s}/channel/", .{fake.base});
    // Before the publish the registry holds regdep only.
    try writeRegistry(&cx, fake_dir, fake.base, &.{regdep_entry});

    // --- before the publish: the set supplies libbase and applib, the registry regdep
    h.stage = "add --overlay before the publish";
    const app1 = try cx.project("app1", "");
    var r = try cx.run(app1, &.{ "add", "applib@=0.2.0", "--overlay", set, "--registry", fake.base });
    const lock1 = cx.read(app1, "mopm.lock") orelse "";
    const toml1 = cx.read(app1, "mopm.toml") orelse "";
    cx.ok("add --overlay locks the staged closure and what the registry adds (exit 0, three packages)", r.code == 0 and
        has(r.stdout, "adding applib 0.2.0\n") and has(r.stdout, "adding libbase 0.1.0\n") and has(r.stdout, "adding regdep 1.0.0\n") and has(r.stdout, "locked 3 packages for mojo 1.0.0\n"), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    cx.ok("the lock names the registry's channel and file URLs, and the hashes of the staged files and of libbase's archive", has(lock1, channel) and
        has(lock1, try cx.fmt("{s}linux-64/mojo-applib-0.2.0-mojo1.0.0_0.conda", .{channel})) and
        has(lock1, try sha256Hex(a, base_bytes)) and has(lock1, try sha256Hex(a, app_bytes)) and has(lock1, try sha256Hex(a, archive)) and has(lock1, try sha256Hex(a, reg_bytes)), lock1);
    cx.ok("add writes the requirement into mopm.toml, and nothing about the set", has(toml1, "applib = \"=0.2.0\"\n") and !has(toml1, set) and !has(toml1, "overlay") and !has(toml1, "staged"), toml1);
    cx.ok("nothing of the set is in the lock, and the project holds mopm.lock and mopm.toml only", !has(lock1, set) and !has(lock1, "overlay") and !has(lock1, "staged") and !has(lock1, "plan.json") and
        std.mem.eql(u8, try cx.files(app1), "mopm.lock,mopm.toml"), try cx.files(app1));

    // lock --overlay of a manifest that already names the dependency.
    const app0 = try cx.project("app0", "applib = \"=0.2.0\"\n");
    r = try cx.run(app0, &.{ "lock", "--overlay", set, "--registry", fake.base });
    cx.ok("lock --overlay makes the lock add --overlay made", r.code == 0 and std.mem.eql(u8, cx.read(app0, "mopm.lock") orelse "", lock1), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    r = try cx.run(app0, &.{ "lock", "--overlay", set, "--registry", fake.base });
    cx.ok("lock --overlay again changes nothing", r.code == 0 and has(r.stdout, "locked 3 packages for mojo 1.0.0\n") and !has(r.stdout, "adding") and !has(r.stdout, "updating") and
        std.mem.eql(u8, cx.read(app0, "mopm.lock") orelse "", lock1), r.stdout);

    // A package the set lacks comes from the registry; one that neither has is refused.
    h.stage = "falling through";
    const app5 = try cx.project("app5", "");
    r = try cx.run(app5, &.{ "add", "regdep", "--overlay", set, "--registry", fake.base });
    const lock5 = cx.read(app5, "mopm.lock") orelse "";
    cx.ok("a package the set lacks is resolved from the registry: its version, URL and hash are the registry's", r.code == 0 and has(r.stdout, "locked 1 packages for mojo 1.0.0\n") and
        has(lock5, try cx.fmt("{s}linux-64/mojo-regdep-1.0.0-mojo1.0.0_0.conda", .{channel})) and has(lock5, try sha256Hex(a, reg_bytes)) and
        has(cx.read(app5, "mopm.toml") orelse "", "regdep = \"^1.0.0\""), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    const app6 = try cx.project("app6", "");
    r = try cx.run(app6, &.{ "add", "nosuch", "--overlay", set, "--registry", fake.base });
    cx.ok("a package neither the set nor the registry has is refused, and nothing is written", r.code == 1 and has(r.stderr, "nosuch (required by mopm.toml) is not in the registry's index") and
        std.mem.eql(u8, cx.read(app6, "mopm.toml") orelse "", head) and cx.read(app6, "mopm.lock") == null, try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));

    // --- sync installs the staged files from the set, while the registry holds none of them
    h.stage = "sync";
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        r = try cx.run(app1, &.{ "sync", "--locked", "--overlay", set, "--pixi", pixi_exe });
        const kept = cx.read(app1, ".mopm/channel/linux-64/mojo-applib-0.2.0-mojo1.0.0_0.conda") orelse "";
        cx.ok("sync --locked --overlay installs libbase and applib from the set and regdep from the registry", r.code == 0 and has(r.stdout, "read 2 packages from the staged set") and
            has(r.stdout, "installed 3 packages for linux-64") and std.mem.eql(u8, kept, app_bytes) and
            std.mem.eql(u8, cx.read(app1, ".mopm/channel/linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda") orelse "", base_bytes) and
            std.mem.eql(u8, cx.read(app1, ".mopm/channel/linux-64/mojo-regdep-1.0.0-mojo1.0.0_0.conda") orelse "", reg_bytes) and
            std.mem.eql(u8, cx.read(app1, "mopm.lock") orelse "", lock1), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
        cx.ok("the installed environment holds the staged packages and the archive of libbase", cx.read(app1, ".mopm/.pixi/envs/default/lib/libbase_sys.a") != null and
            cx.read(app1, ".mopm/.pixi/envs/default/lib/mojo/applib.mopm.json") != null, try cx.files(app1));
        const app1c = try cx.project("app1c", "applib = \"=0.2.0\"\n");
        try h.writeFile(try h.join(a, &.{ app1c, "mopm.lock" }), lock1);
        r = try cx.run(app1c, &.{ "sync", "--locked", "--pixi", pixi_exe });
        cx.ok("the same sync without the set fails on the registry, whose repodata.json offers none of the staged files", r.code == 1 and has(r.stderr, "does not offer mojo-applib-0.2.0-mojo1.0.0_0.conda"), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
        const app1d = try cx.project("app1d", "applib = \"=0.2.0\"\n");
        try h.writeFile(try h.join(a, &.{ app1d, "mopm.lock" }), lock1);
        const other = try h.join(a, &.{ work, "set_other" });
        _ = try pack(&cx, .{ .name = "applib", .version = "0.2.0", .extra = "[dependencies]\nlibbase = \"0.1\"\n" }, other);
        try writePlan(&cx, other, &.{.{ .name = "applib", .version = "0.2.0" }});
        r = try cx.run(app1d, &.{ "sync", "--locked", "--overlay", other, "--pixi", pixi_exe });
        cx.ok("a set holding another file under the locked name is not used: the lock pins the bytes", !has(r.stdout, "read 1 packages from the staged set") and r.code == 1 and has(r.stderr, "does not offer mojo-applib-0.2.0-mojo1.0.0_0.conda"), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    }

    // --- the publish: the registry holds all three
    h.stage = "after the publish";
    try writeRegistry(&cx, fake_dir, fake.base, &.{ libbase_entry, applib_entry, regdep_entry });
    const app2 = try cx.project("app2", "");
    r = try cx.run(app2, &.{ "add", "applib@=0.2.0", "--registry", fake.base });
    cx.ok("add against the registry after the publish resolves the same closure", r.code == 0 and has(r.stdout, "locked 3 packages for mojo 1.0.0\n"), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    cx.rep.same("the lock made with the set is the lock the registry gives once the versions are published", cx.read(app2, "mopm.lock") orelse "", lock1);
    cx.rep.same("the mopm.toml made with the set is the one made without it", cx.read(app2, "mopm.toml") orelse "", toml1);
    const app3 = try cx.project("app3", "");
    r = try cx.run(app3, &.{ "add", "applib@=0.2.0", "--overlay", set, "--registry", fake.base });
    cx.ok("with the registry holding the same bytes the set is accepted, and the lock is the same", r.code == 0 and std.mem.eql(u8, cx.read(app3, "mopm.lock") orelse "", lock1) and
        std.mem.eql(u8, cx.read(app3, "mopm.toml") orelse "", toml1), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    // --- a staged version the registry holds with other bytes
    h.stage = "a conflict";
    const fake_dir_c = try h.join(a, &.{ work, "fake_c" });
    var fake_c = try h.Fake.start(a, fake_exe, fake_dir_c);
    defer fake_c.close();
    const changed = try std.mem.concat(a, u8, &.{ base_bytes, "x" });
    try writeRegistry(&cx, fake_dir_c, fake_c.base, &.{ regdep_entry, .{ .name = "libbase", .version = "0.1.0", .native = libbase_entry.native, .bytes = changed } });
    const app7 = try cx.project("app7", "");
    r = try cx.run(app7, &.{ "add", "applib@=0.2.0", "--overlay", set, "--registry", fake_c.base });
    cx.ok("a staged version the registry holds with other bytes is refused, naming the version and the way out", r.code == 1 and has(r.stderr, "libbase 0.1.0 is staged in") and
        has(r.stderr, try sha256Hex(a, base_bytes)) and has(r.stderr, try sha256Hex(a, changed)) and has(r.stderr, "needs a new version"), try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));
    cx.ok("the refusal leaves mopm.toml as it was and writes no lock", std.mem.eql(u8, cx.read(app7, "mopm.toml") orelse "", head) and cx.read(app7, "mopm.lock") == null, cx.read(app7, "mopm.toml") orelse "");

    // --- no network for the staged closure
    h.stage = "no network";
    const stub = try a.create(Stub);
    stub.* = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true }) };
    const thread = try std.Thread.spawn(.{}, Stub.serve, .{stub});
    thread.detach();
    const stub_base = try stub.base(a);
    const app8 = try cx.project("app8", "");
    r = try cx.run(app8, &.{ "add", "libbase@=0.1.0", "--overlay", set, "--registry", stub_base });
    const asked = try stub.asked(a);
    const lock8 = cx.read(app8, "mopm.lock") orelse "";
    cx.ok("a closure the set holds is locked, asking the registry for its configuration only", r.code == 0 and std.mem.eql(u8, asked, "/index/config.json") and
        has(lock8, try cx.fmt("{s}/channel/linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda", .{stub_base})) and has(lock8, try sha256Hex(a, archive)), try cx.fmt("exit {d}, asked [{s}]: {s}{s}", .{ r.code, asked, r.stdout, r.stderr }));
    const app9 = try cx.project("app9", "");
    r = try cx.run(app9, &.{ "add", "libbase@=0.1.0", "--registry", stub_base });
    const asked_after = try stub.asked(a);
    cx.ok("without the set the same add asks for libbase's index file (so the recording can see a request), and fails", r.code == 1 and has(asked_after, "/index/li/bb/libbase"), try cx.fmt("exit {d}, asked [{s}]", .{ r.code, asked_after }));
    const app10 = try cx.project("app10", "");
    r = try cx.run(app10, &.{ "add", "libbase@=0.1.0", "--overlay", set, "--registry", "http://127.0.0.1:1" });
    cx.ok("a registry that cannot be reached cannot name the lock's channel: refused, nothing written", r.code == 1 and has(r.stderr, "cannot reach") and cx.read(app10, "mopm.lock") == null and
        std.mem.eql(u8, cx.read(app10, "mopm.toml") orelse "", head), try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));
    const app11 = try cx.project("app11", "");
    r = try cx.run(app11, &.{ "add", "libbase@=0.1.0", "--overlay", set });
    cx.ok("against the production registry a closure the set holds is locked with the production channel", r.code == 0 and
        has(cx.read(app11, "mopm.lock") orelse "", "https://conda.mopm.dev/linux-64/mojo-libbase-0.1.0-mojo1.0.0_0.conda"), try cx.fmt("exit {d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    // --- sets that are refused
    h.stage = "refused sets";
    const app12 = try cx.project("app12", "");
    r = try cx.run(app12, &.{ "add", "libbase@=0.1.0", "--overlay", try h.join(a, &.{ work, "nosuchset" }), "--registry", fake.base });
    cx.ok("a directory that is not a staged set is refused", r.code == 1 and has(r.stderr, "--overlay: cannot open the staged set") and cx.read(app12, "mopm.lock") == null, try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));
    try h.writeFile(try h.join(a, &.{ work, "notaset", "readme.txt" }), "not a staged set\n");
    r = try cx.run(app12, &.{ "lock", "--overlay", try h.join(a, &.{ work, "notaset" }), "--registry", fake.base });
    cx.ok("a directory with no plan.json is refused, naming the file", r.code == 1 and has(r.stderr, "notaset/plan.json: FileNotFound"), try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));
    const set2 = try h.join(a, &.{ work, "set2" });
    try h.copyTree(a, set, set2);
    try h.writeFile(try h.join(a, &.{ set2, "linux-64", "mojo-applib-0.2.0-mojo1.0.0_0.conda" }), try std.mem.concat(a, u8, &.{ app_bytes, "x" }));
    const app13 = try cx.project("app13", "");
    r = try cx.run(app13, &.{ "add", "applib@=0.2.0", "--overlay", set2, "--registry", fake.base });
    cx.ok("a staged file changed after the plan was made is refused, and nothing is written", r.code == 1 and has(r.stderr, "is not the file plan.json describes") and
        cx.read(app13, "mopm.lock") == null and std.mem.eql(u8, cx.read(app13, "mopm.toml") orelse "", head), try cx.fmt("exit {d}: {s}", .{ r.code, r.stderr }));

    // --- the set was never written
    h.stage = "the set after all of it";
    const after = try snapshot(a, set);
    cx.rep.same("the staged set is exactly as it was: no file added, removed, rewritten or touched", before, after);
    try h.writeFile(try h.join(a, &.{ set, "stray" }), "x");
    cx.ok("the snapshot sees a file added to the set", !std.mem.eql(u8, before, try snapshot(a, set)), "the snapshot did not change");

    try rep.finish();
}
