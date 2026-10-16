//! `mopm sync`: install exactly what mopm.lock pins, and the Mojo toolchain,
//! into the project's own environment, with no pixi, conda or solver.
//!
//!   <cache>/<file>.conda   each file downloaded by mopm (the locked packages
//!                          of this host's subdir or noarch, and the toolchain
//!                          closure's), kept only if its size and sha256 are
//!                          the pinned ones (core/pkg_fetch.zig)
//!   .mopm/env              the environment: every file unpacked by
//!                          core/conda_env.zig into a temporary directory and
//!                          renamed into place, so it is the old environment
//!                          or the whole new one; `mopm build` finds it
//!                          without `--prefix` (core/env.zig)
//!
//! The toolchain is not solved: core/closure.zig is the pre-resolved list of
//! every package `mojo` needs, per Mojo version and platform, with the sha256
//! of each. `plan` joins it with the lock's packages into the one list that
//! is installed, and refuses a locked package that has the name of a
//! toolchain one. After the install, `checkInstalled` checks the result: each
//! locked package's `conda-meta` record names the locked sha256, its
//! `lib/mojo/<name>.mopm.json` is there, every native library the lock gives a
//! sha256 hashes to it, and no `lib/mojo/*.mopm.json` is installed that the
//! lock does not name.
//!
//! `staleness` says why a lock no longer matches mopm.toml (`mopm sync
//! --locked` refuses it); it reads only the manifests and the lock.
//!
//! A path dependency is locked with `source = path` and no file: `forSubdir`
//! leaves it out, so sync neither downloads nor installs it. It is used from
//! its directory. `staleness` checks that each one is still locked at its
//! path and at the version its own mopm.toml gives.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const lock = @import("lock.zig");
const resolve = @import("resolve.zig");
const semver = @import("semver.zig");
const plan = @import("install_plan.zig");
const closure = @import("closure.zig");

/// Where `mopm sync` keeps the environment, relative to the project: the
/// directory, the environment's name in it, and its path.
pub const dir = ".mopm";
pub const env_name = "env";
pub const prefix = ".mopm/env";

/// The conda subdir of the machine mopm runs on, or null when no Mojo
/// toolchain is published for it.
pub fn hostSubdir() ?[]const u8 {
    return subdirOf(builtin.os.tag, builtin.cpu.arch);
}

fn subdirOf(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "linux-64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        .macos => switch (arch) {
            .aarch64 => "osx-arm64",
            else => null,
        },
        else => null,
    };
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn lockedEntry(l: lock.Lock, name: []const u8) ?lock.Package {
    for (l.packages) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Why `l` no longer matches mopm.toml (its `[toolchain] mojo` versions, its
/// version requirements `roots` and its path dependencies `paths`, each at
/// any depth), or null when it does: the lock's toolchain is one the manifest
/// allows, every requirement is locked from the registry at a version that
/// satisfies it, every path dependency is locked as one at the same path and
/// version, and every locked package is needed by a requirement or a path
/// dependency directly or through the locked dependencies.
pub fn staleness(arena: Allocator, toolchains: []const []const u8, roots: []const resolve.Root, paths: []const plan.PathDep, l: lock.Lock) Allocator.Error!?[]const u8 {
    if (!contains(toolchains, l.mojo)) {
        const allowed = try std.mem.join(arena, ", ", toolchains);
        return try std.fmt.allocPrint(arena, "mopm.lock is for mojo {s}; mopm.toml's [toolchain] allows {s}", .{ l.mojo, allowed });
    }
    for (roots) |r| {
        const have = l.versionOf(r.name) orelse
            return try std.fmt.allocPrint(arena, "mopm.toml needs {s}, which mopm.lock does not lock", .{r.name});
        if (lockedEntry(l, r.name).?.source == .path) {
            return try std.fmt.allocPrint(arena, "{s} needs {s} \"{s}\" from the registry, but mopm.lock has it as a path dependency", .{ r.from, r.name, r.requirement });
        }
        var why: []const u8 = "";
        const req = semver.parseReq(arena, r.requirement, &why) catch |e| switch (e) {
            error.Invalid => return try std.fmt.allocPrint(arena, "mopm.toml: {s} = \"{s}\": {s}", .{ r.name, r.requirement, why }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const v = resolve.semverOf(have);
        if (v == null or !req.matches(v.?)) {
            return try std.fmt.allocPrint(arena, "mopm.toml needs {s} \"{s}\", but mopm.lock has {s} {s}", .{ r.name, r.requirement, r.name, have });
        }
    }
    for (paths) |d| {
        const e = lockedEntry(l, d.name) orelse
            return try std.fmt.allocPrint(arena, "mopm.toml needs {s} (path {s}), which mopm.lock does not lock", .{ d.name, d.path });
        if (e.source != .path or !std.mem.eql(u8, e.path, d.path)) {
            return try std.fmt.allocPrint(arena, "{s} is the path dependency {s}, but mopm.lock has {s} {s}{s}{s}", .{ d.name, d.path, e.name, e.version, if (e.source == .path) " at " else " from ", if (e.source == .path) e.path else e.channel });
        }
        if (!std.mem.eql(u8, e.version, d.version)) {
            return try std.fmt.allocPrint(arena, "{s}/mopm.toml says {s} {s}, but mopm.lock has {s} {s}", .{ d.path, d.name, d.version, d.name, e.version });
        }
    }
    var needed = std.StringHashMap(void).init(arena);
    var todo = std.ArrayList([]const u8).init(arena);
    for (roots) |r| try todo.append(r.name);
    for (paths) |d| try todo.append(d.name);
    while (todo.popOrNull()) |name| {
        if (needed.contains(name)) continue;
        try needed.put(name, {});
        for (l.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) try todo.appendSlice(p.deps);
        }
    }
    for (l.packages) |p| {
        if (!needed.contains(p.name)) {
            return try std.fmt.allocPrint(arena, "mopm.lock locks {s} {s}, which nothing in mopm.toml needs", .{ p.name, p.version });
        }
    }
    return null;
}

pub const Selected = union(enum) { ok: []const lock.Package, bad: []const u8 };

/// One entry per locked name from the registry: its file for `subdir`, else
/// its `noarch` file. Path dependencies have no file and are left out.
pub fn forSubdir(arena: Allocator, l: lock.Lock, subdir: []const u8) Allocator.Error!Selected {
    var out = std.ArrayList(lock.Package).init(arena);
    var i: usize = 0;
    while (i < l.packages.len) {
        if (l.packages[i].source == .path) {
            i += 1;
            continue;
        }
        const name = l.packages[i].name;
        var pick: ?lock.Package = null;
        var noarch: ?lock.Package = null;
        while (i < l.packages.len and std.mem.eql(u8, l.packages[i].name, name)) : (i += 1) {
            const p = l.packages[i];
            if (std.mem.eql(u8, p.subdir, subdir)) pick = p;
            if (std.mem.eql(u8, p.subdir, "noarch")) noarch = p;
        }
        try out.append(pick orelse noarch orelse
            return .{ .bad = try std.fmt.allocPrint(arena, "mopm.lock has no file of {s} for {s} (nor a noarch one)", .{ name, subdir }) });
    }
    return .{ .ok = out.items };
}

/// The conda file name of a lock entry.
pub fn fileName(arena: Allocator, p: lock.Package) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "mojo-{s}-{s}-{s}.conda", .{ p.name, p.version, p.build });
}

pub fn sha256Hex(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

/// One file to install: a locked package or one of the toolchain's.
pub const Item = struct {
    /// The conda package name (`mojo-<name>` for a locked package).
    name: []const u8,
    version: []const u8,
    file_name: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    channel: []const u8,
    md5: []const u8 = "",
    /// True for a package of the lock, false for the toolchain's.
    locked: bool,
};

pub const Planned = union(enum) { ok: []const Item, bad: []const u8 };

/// The files to install for `pkgs` (the lock's, see `forSubdir`) and the
/// toolchain closure `c`: the toolchain's first, then the locked ones. A
/// locked package whose conda name is a toolchain package's is refused.
pub fn planInstall(arena: Allocator, pkgs: []const lock.Package, c: closure.Closure) !Planned {
    var items = std.ArrayList(Item).init(arena);
    var names = std.StringHashMap(void).init(arena);
    for (c.packages) |p| {
        try names.put(p.name, {});
        try items.append(.{
            .name = p.name,
            .version = p.version,
            .file_name = closure.fileName(p),
            .url = try closure.urlOf(arena, c, p),
            .sha256 = p.sha256,
            .size = p.size,
            .channel = p.channel,
            .md5 = p.md5,
            .locked = false,
        });
    }
    for (pkgs) |p| {
        const conda_name = try std.fmt.allocPrint(arena, "mojo-{s}", .{p.name});
        if (names.contains(conda_name)) {
            return .{ .bad = try std.fmt.allocPrint(arena, "the locked package {s} would install as {s}, which the Mojo {s} toolchain already provides; rename the package", .{ p.name, conda_name, c.mojo }) };
        }
        try items.append(.{
            .name = conda_name,
            .version = p.version,
            .file_name = try fileName(arena, p),
            .url = p.url,
            .sha256 = p.sha256,
            .size = p.size,
            .channel = p.channel,
            .locked = true,
        });
    }
    return .{ .ok = items.items };
}

/// A digest of what `items` are: the same list gives the same stamp, so an
/// environment whose stamp is it need not be installed again.
pub fn stampOf(arena: Allocator, items: []const Item) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("mopm-env 1\n");
    for (items) |i| {
        h.update(i.name);
        h.update(" ");
        h.update(i.version);
        h.update(" ");
        h.update(i.file_name);
        h.update(" ");
        h.update(i.sha256);
        h.update("\n");
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return arena.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// Why the environment at `env` is not exactly `pkgs` as locked, or null.
/// See the file comment for what is checked.
pub fn checkInstalled(arena: Allocator, env: std.fs.Dir, pkgs: []const lock.Package) !?[]const u8 {
    for (pkgs) |p| {
        const record = try std.fmt.allocPrint(arena, "conda-meta/mojo-{s}-{s}-{s}.json", .{ p.name, p.version, p.build });
        const text = env.readFileAlloc(arena, record, 64 << 20) catch |e| switch (e) {
            error.FileNotFound => return try std.fmt.allocPrint(arena, "mojo-{s} {s} ({s}) is not installed: no {s}", .{ p.name, p.version, p.build, record }),
            else => return e,
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return try std.fmt.allocPrint(arena, "{s} is not JSON", .{record});
        const sha = if (v == .object) v.object.get("sha256") else null;
        if (sha == null or sha.? != .string or !std.mem.eql(u8, sha.?.string, p.sha256)) {
            const got = if (sha != null and sha.? == .string) sha.?.string else "none";
            return try std.fmt.allocPrint(arena, "installed mojo-{s} {s} has sha256 {s}; mopm.lock pins {s}; refused", .{ p.name, p.version, got, p.sha256 });
        }
        const meta = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mopm.json", .{p.name});
        env.access(meta, .{}) catch return try std.fmt.allocPrint(arena, "mojo-{s} {s} is installed without {s}: a corrupt package", .{ p.name, p.version, meta });
        for (p.native) |n| {
            const want = n.sha256 orelse continue;
            const path = try std.fmt.allocPrint(arena, "lib/{s}", .{n.soname});
            const bytes = env.readFileAlloc(arena, path, 1 << 30) catch
                return try std.fmt.allocPrint(arena, "mojo-{s} {s}: its native library {s} is not installed", .{ p.name, p.version, path });
            const got = try sha256Hex(arena, bytes);
            if (!std.mem.eql(u8, got, want)) {
                return try std.fmt.allocPrint(arena, "{s} of mojo-{s} {s} has sha256 {s}; mopm.lock pins {s}; refused", .{ path, p.name, p.version, got, want });
            }
        }
    }
    var mojo_dir = env.openDir("lib/mojo", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            if (pkgs.len == 0) return null;
            return "the environment has no lib/mojo";
        },
        else => return e,
    };
    defer mojo_dir.close();
    var it = mojo_dir.iterate();
    while (try it.next()) |entry| {
        const suffix = ".mopm.json";
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const name = entry.name[0 .. entry.name.len - suffix.len];
        var locked = false;
        for (pkgs) |p| locked = locked or std.mem.eql(u8, p.name, name);
        if (!locked) return try std.fmt.allocPrint(arena, "lib/mojo/{s} is installed but mopm.lock does not lock {s}; refused", .{ entry.name, name });
    }
    return null;
}

// ---------------------------------------------------------------- tests

const sha_abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const sha_other = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

fn pkg(name: []const u8, version: []const u8, subdir: []const u8, deps: []const []const u8) lock.Package {
    return .{
        .name = name,
        .version = version,
        .build = "mojo1.0.0_0",
        .subdir = subdir,
        .channel = "https://conda.mopm.dev/",
        .url = "",
        .sha256 = sha_abc,
        .size = 3,
        .mojo = "1.0.0",
        .deps = deps,
    };
}

const app_lock = lock.Lock{ .mojo = "1.0.0", .channels = &.{"https://conda.mopm.dev/"}, .packages = &.{
    pkg("crypto", "2.0.1", "linux-64", &.{}),
    pkg("crypto", "2.0.1", "osx-arm64", &.{}),
    pkg("http_client", "0.4.0", "linux-64", &.{ "crypto", "http_core" }),
    pkg("http_core", "1.2.5", "noarch", &.{}),
} };

const app_roots = [_]resolve.Root{ .{ .name = "http_client", .requirement = "0.4" }, .{ .name = "http_core", .requirement = "~1.2" } };

test "a lock that matches mopm.toml is fresh; each kind of drift is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(?[]const u8, null), try staleness(a, &.{ "0.9.0", "1.0.0" }, &app_roots, &.{}, app_lock));

    const Case = struct { []const []const u8, []const resolve.Root, []const u8 };
    const cases = [_]Case{
        .{ &.{"1.1.0"}, &app_roots, "mopm.lock is for mojo 1.0.0; mopm.toml's [toolchain] allows 1.1.0" },
        .{ &.{"1.0.0"}, &.{ app_roots[0], app_roots[1], .{ .name = "tls", .requirement = "1" } }, "mopm.toml needs tls, which mopm.lock does not lock" },
        .{ &.{"1.0.0"}, &.{ .{ .name = "http_client", .requirement = "0.5" }, app_roots[1] }, "mopm.toml needs http_client \"0.5\", but mopm.lock has http_client 0.4.0" },
        .{ &.{"1.0.0"}, &.{ app_roots[0], .{ .name = "http_core", .requirement = ">=1.3" } }, "mopm.toml needs http_core \">=1.3\", but mopm.lock has http_core 1.2.5" },
        .{ &.{"1.0.0"}, &.{.{ .name = "http_core", .requirement = "1" }}, "mopm.lock locks crypto 2.0.1, which nothing in mopm.toml needs" },
        .{ &.{"1.0.0"}, &.{ app_roots[0], .{ .name = "http_core", .requirement = "1.x.2" } }, "mopm.toml: http_core = \"1.x.2\": " },
    };
    for (cases) |case| {
        const got = (try staleness(a, case[0], case[1], &.{}, app_lock)) orelse {
            std.debug.print("fresh, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.startsWith(u8, got, case[2])) {
            std.debug.print("got: {s}\nwant: {s}\n", .{ got, case[2] });
            return error.TestUnexpectedResult;
        }
    }
}

test "one file per name: the host's subdir, else noarch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const linux = (try forSubdir(a, app_lock, "linux-64")).ok;
    try std.testing.expectEqual(@as(usize, 3), linux.len);
    try std.testing.expectEqualStrings("linux-64", linux[0].subdir);
    try std.testing.expectEqualStrings("noarch", linux[2].subdir);
    const arm = try forSubdir(a, app_lock, "linux-aarch64");
    try std.testing.expectEqualStrings("mopm.lock has no file of crypto for linux-aarch64 (nor a noarch one)", arm.bad);
    try std.testing.expectEqualStrings("linux-64", subdirOf(.linux, .x86_64).?);
    try std.testing.expectEqualStrings("linux-aarch64", subdirOf(.linux, .aarch64).?);
    try std.testing.expectEqualStrings("osx-arm64", subdirOf(.macos, .aarch64).?);
    try std.testing.expect(subdirOf(.macos, .x86_64) == null);
    try std.testing.expect(subdirOf(.windows, .x86_64) == null);
}

test "the installed environment: exactly the lock, or a refusal that says what differs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const env = tmp.dir;
    try env.makePath("conda-meta");
    try env.makePath("lib/mojo");
    var greet = pkg("greet", "1.0.0", "linux-64", &.{});
    greet.native = &.{.{ .id = "greet", .soname = "libgreet.so", .sha256 = sha_abc }};
    const pkgs = [_]lock.Package{greet};

    try std.testing.expectEqualStrings("mojo-greet 1.0.0 (mojo1.0.0_0) is not installed: no conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", (try checkInstalled(a, env, &pkgs)).?);
    try env.writeFile("conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", "{\"name\":\"mojo-greet\",\"sha256\":\"" ++ sha_other ++ "\"}");
    try std.testing.expectEqualStrings("installed mojo-greet 1.0.0 has sha256 " ++ sha_other ++ "; mopm.lock pins " ++ sha_abc ++ "; refused", (try checkInstalled(a, env, &pkgs)).?);
    try env.writeFile("conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", "{\"name\":\"mojo-greet\",\"sha256\":\"" ++ sha_abc ++ "\"}");
    try std.testing.expectEqualStrings("mojo-greet 1.0.0 is installed without lib/mojo/greet.mopm.json: a corrupt package", (try checkInstalled(a, env, &pkgs)).?);
    try env.writeFile("lib/mojo/greet.mopm.json", "{}");
    try std.testing.expectEqualStrings("mojo-greet 1.0.0: its native library lib/libgreet.so is not installed", (try checkInstalled(a, env, &pkgs)).?);
    try env.writeFile("lib/libgreet.so", "abd");
    try std.testing.expect(std.mem.startsWith(u8, (try checkInstalled(a, env, &pkgs)).?, "lib/libgreet.so of mojo-greet 1.0.0 has sha256 "));
    try env.writeFile("lib/libgreet.so", "abc");
    try std.testing.expectEqual(@as(?[]const u8, null), try checkInstalled(a, env, &pkgs));
    try env.writeFile("lib/mojo/stray.mopm.json", "{}");
    try std.testing.expectEqualStrings("lib/mojo/stray.mopm.json is installed but mopm.lock does not lock stray; refused", (try checkInstalled(a, env, &pkgs)).?);
}

test "path dependencies: locked at their path and version, never selected for download" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const with_path = lock.Lock{ .mojo = "1.0.0", .channels = &.{"https://conda.mopm.dev/"}, .packages = &.{
        pkg("crypto", "2.0.1", "linux-64", &.{}),
        pkg("http_client", "0.4.0", "linux-64", &.{ "crypto", "http_core" }),
        pkg("http_core", "1.2.5", "noarch", &.{}),
        .{ .name = "local", .version = "0.3.0", .source = .path, .path = "local", .deps = &.{"http_client"} },
    } };
    // local's own mopm.toml requires http_client; the project requires only local.
    const roots = [_]resolve.Root{.{ .name = "http_client", .requirement = "0.4", .from = "local/mopm.toml" }};
    const paths = [_]plan.PathDep{.{ .name = "local", .version = "0.3.0", .path = "local", .deps = &.{"http_client"} }};
    try std.testing.expectEqual(@as(?[]const u8, null), try staleness(a, &.{"1.0.0"}, &roots, &paths, with_path));

    const Case = struct { []const resolve.Root, []const plan.PathDep, []const u8 };
    const cases = [_]Case{
        .{ &roots, &.{.{ .name = "local", .version = "0.3.1", .path = "local" }}, "local/mopm.toml says local 0.3.1, but mopm.lock has local 0.3.0" },
        .{ &roots, &.{.{ .name = "local", .version = "0.3.0", .path = "../moved" }}, "local is the path dependency ../moved, but mopm.lock has local 0.3.0 at local" },
        .{ &roots, &.{ paths[0], .{ .name = "crypto", .version = "2.0.1", .path = "vendor/crypto" } }, "crypto is the path dependency vendor/crypto, but mopm.lock has crypto 2.0.1 from https://conda.mopm.dev/" },
        .{ &roots, &.{ paths[0], .{ .name = "other", .version = "1.0.0", .path = "other" } }, "mopm.toml needs other (path other), which mopm.lock does not lock" },
        .{ &.{ roots[0], .{ .name = "local", .requirement = "0.3" } }, &paths, "mopm.toml needs local \"0.3\" from the registry, but mopm.lock has it as a path dependency" },
        .{ &roots, &.{}, "mopm.lock locks local 0.3.0, which nothing in mopm.toml needs" },
    };
    for (cases) |case| {
        const got = (try staleness(a, &.{"1.0.0"}, case[0], case[1], with_path)) orelse {
            std.debug.print("fresh, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got, case[2])) {
            std.debug.print("got: {s}\nwant: {s}\n", .{ got, case[2] });
            return error.TestUnexpectedResult;
        }
    }

    const selected = (try forSubdir(a, with_path, "linux-64")).ok;
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    for (selected) |p| try std.testing.expect(p.source == .registry and !std.mem.eql(u8, p.name, "local"));
}

test "planInstall: the toolchain first, then the locked packages; a name the toolchain has is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = closure.Closure{
        .mojo = "1.0.0",
        .subdir = "linux-64",
        .channels = &.{.{ .name = "max", .url = "https://conda.example/max/" }},
        .packages = &.{
            .{ .name = "mojo", .version = "1.0.0", .build = "release", .subdir = "linux-64", .channel = "max", .path = "linux-64/mojo-1.0.0-release.conda", .sha256 = "a" ** 64, .size = 10 },
            .{ .name = "mojo-python", .version = "1.0.0", .build = "release", .subdir = "noarch", .channel = "max", .path = "noarch/mojo-python-1.0.0-release.conda", .sha256 = "b" ** 64, .size = 20 },
        },
    };
    var greet = pkg("greet", "1.0.0", "linux-64", &.{});
    greet.url = "https://conda.mopm.dev/linux-64/mojo-greet-1.0.0-mojo1.0.0_0.conda";
    const items = (try planInstall(a, &.{greet}, c)).ok;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("mojo", items[0].name);
    try std.testing.expectEqualStrings("https://conda.example/max/linux-64/mojo-1.0.0-release.conda", items[0].url);
    try std.testing.expect(!items[0].locked);
    try std.testing.expectEqualStrings("mojo-greet", items[2].name);
    try std.testing.expectEqualStrings("mojo-greet-1.0.0-mojo1.0.0_0.conda", items[2].file_name);
    try std.testing.expectEqualStrings(greet.url, items[2].url);
    try std.testing.expect(items[2].locked);

    // A package called "python" would install as mojo-python, which the toolchain has.
    const clash = pkg("python", "1.0.0", "linux-64", &.{});
    const bad = (try planInstall(a, &.{clash}, c)).bad;
    try std.testing.expect(std.mem.indexOf(u8, bad, "would install as mojo-python") != null);

    // The stamp is the same for the same files and differs when a hash does.
    const s1 = try stampOf(a, items);
    try std.testing.expectEqualStrings(s1, try stampOf(a, items));
    var other = try a.dupe(Item, items);
    other[1].sha256 = "c" ** 64;
    try std.testing.expect(!std.mem.eql(u8, s1, try stampOf(a, other)));
}
