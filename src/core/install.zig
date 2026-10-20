//! `mopm sync`: install exactly what mopm.lock pins into the project's own
//! environment under `.mopm/`, an internal pixi project mopm generates.
//!
//!   .mopm/channel/<subdir>/<file>.conda   each locked file of this host's
//!                                         subdir (or noarch), downloaded by
//!                                         mopm and checked against the lock's
//!                                         size and sha256 before it is kept
//!   .mopm/channel/<subdir>/repodata.json  those files and nothing else
//!   .mopm/pixi.toml                       the toolchain (`mojo` and
//!                                         `mojo-compiler` ==<lock toolchain>)
//!                                         and every locked package pinned to
//!                                         its version, build and sha256
//!   .mopm/.pixi/envs/default              the environment `pixi install`
//!                                         makes; `mopm build --prefix` names it
//!
//! The local channel is listed first, so under pixi's strict channel priority
//! a `mojo-<name>` package can come only from bytes mopm verified. After pixi
//! has installed, `checkInstalled` checks the result: each locked package's
//! `conda-meta` record names the locked sha256, its `lib/mojo/<name>.mopm.json`
//! is there, every native library the lock gives a sha256 hashes to it, and
//! no `lib/mojo/*.mopm.json` is installed that the lock does not name.
//!
//! `staleness` says why a lock no longer matches mopm.toml (`mopm sync
//! --locked` refuses it); it reads only the manifests and the lock.
//!
//! A path dependency is locked with `source = path` and no file: `forSubdir`
//! leaves it out, so sync neither downloads it nor puts it in the pixi
//! project or the local channel. It is used from its directory. `staleness`
//! checks that each one is still locked at its path and at the version its
//! own mopm.toml gives.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const lock = @import("lock.zig");
const resolve = @import("resolve.zig");
const semver = @import("semver.zig");
const plan = @import("install_plan.zig");

/// Where `mopm sync` keeps the environment, relative to the project.
pub const dir = ".mopm";
pub const channel_dir = ".mopm/channel";
pub const pixi_manifest = ".mopm/pixi.toml";
pub const prefix = ".mopm/.pixi/envs/default";

/// The channels the toolchain comes from, after the local channel.
pub const toolchain_channels = [_][]const u8{ "https://conda.modular.com/max", "conda-forge" };

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
    if (l.mojos.len > 0) {
        var same = l.mojos.len == toolchains.len;
        for (toolchains) |t| same = same and contains(l.mojos, t);
        if (!same) {
            return try std.fmt.allocPrint(arena, "mopm.lock is for mojo {s}; mopm.toml's mojo is {s}", .{ try std.mem.join(arena, ", ", l.mojos), try std.mem.join(arena, ", ", toolchains) });
        }
    } else if (!contains(toolchains, l.mojo)) {
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
        // A version 2 lock may hold one version per Mojo version: each must fit.
        for (l.packages) |q| {
            if (!std.mem.eql(u8, q.name, r.name)) continue;
            const v = resolve.semverOf(q.version);
            if (v == null or !req.matches(v.?)) {
                return try std.fmt.allocPrint(arena, "mopm.toml needs {s} \"{s}\", but mopm.lock has {s} {s}", .{ r.name, r.requirement, r.name, q.version });
            }
        }
        _ = have;
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

/// Why `bytes` are not the file `p` pins (size, then sha256), or null.
pub fn checkBytes(arena: Allocator, p: lock.Package, bytes: []const u8) Allocator.Error!?[]const u8 {
    const name = try fileName(arena, p);
    if (bytes.len != p.size) {
        return try std.fmt.allocPrint(arena, "{s}: mopm.lock pins {d} bytes, the file has {d}; refused", .{ name, p.size, bytes.len });
    }
    const got = try sha256Hex(arena, bytes);
    if (!std.mem.eql(u8, got, p.sha256)) {
        return try std.fmt.allocPrint(arena, "{s}: sha256 mismatch: mopm.lock pins {s}, the file is {s}; refused", .{ name, p.sha256, got });
    }
    return null;
}

pub const Looked = union(enum) {
    /// The channel's `depends` of the file; null when the channel lists the
    /// file as removed (a yanked version: the lock still installs it).
    ok: ?[]const []const u8,
    bad: []const u8,
};

/// The entry of `p`'s file in its channel's `<subdir>/repodata.json`. Its
/// sha256 and size must be the lock's; a difference names both.
pub fn lookUp(arena: Allocator, repodata: []const u8, p: lock.Package) Allocator.Error!Looked {
    const name = try fileName(arena, p);
    const where = try std.fmt.allocPrint(arena, "{s}{s}/repodata.json", .{ p.channel, p.subdir });
    const bad = struct {
        fn f(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Looked {
            return .{ .bad = try std.fmt.allocPrint(a, fmt, args) };
        }
    }.f;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, repodata, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return bad(arena, "{s} is not JSON", .{where});
    };
    if (v != .object) return bad(arena, "{s} is not a JSON object", .{where});
    const conda = v.object.get("packages.conda") orelse return bad(arena, "{s} has no packages.conda", .{where});
    if (conda != .object) return bad(arena, "{s}: packages.conda is not an object", .{where});
    const entry = conda.object.get(name) orelse {
        if (v.object.get("removed")) |removed| {
            if (removed == .array) {
                for (removed.array.items) |r| {
                    if (r == .string and std.mem.eql(u8, r.string, name)) return .{ .ok = null };
                }
            }
        }
        return bad(arena, "{s} does not offer {s}, which mopm.lock pins", .{ where, name });
    };
    if (entry != .object) return bad(arena, "{s}: the entry of {s} is not an object", .{ where, name });
    const sha = entry.object.get("sha256");
    const size = entry.object.get("size");
    const sha_ok = sha != null and sha.? == .string and std.mem.eql(u8, sha.?.string, p.sha256);
    const size_ok = size != null and size.? == .integer and size.?.integer == @as(i64, @intCast(p.size));
    if (!sha_ok or !size_ok) {
        var said = std.ArrayList(u8).init(arena);
        try std.json.stringify(.{ .sha256 = sha, .size = size }, .{}, said.writer());
        return bad(arena, "{s}: mopm.lock pins sha256 {s}, size {d}; {s} says {s}", .{ name, p.sha256, p.size, where, said.items });
    }
    var depends = std.ArrayList([]const u8).init(arena);
    if (entry.object.get("depends")) |d| {
        if (d != .array) return bad(arena, "{s}: the depends of {s} is not an array", .{ where, name });
        for (d.array.items) |item| {
            if (item != .string) return bad(arena, "{s}: a depends of {s} is not a string", .{ where, name });
            try depends.append(item.string);
        }
    }
    return .{ .ok = depends.items };
}

/// The `depends` of a file the channel no longer offers (yanked), from the
/// lock alone: the exact compiler and the locked Mojo dependencies.
pub fn dependsFromLock(arena: Allocator, p: lock.Package) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    try out.append(try std.fmt.allocPrint(arena, "mojo-compiler =={s}", .{p.mojo}));
    for (p.deps) |d| try out.append(try std.fmt.allocPrint(arena, "mojo-{s}", .{d}));
    return out.items;
}

pub const LocalFile = struct { pkg: lock.Package, depends: []const []const u8 };

/// `repodata.json` of the local channel's `subdir`: exactly `files` (those
/// of that subdir), with the lock's sha256 and size.
pub fn localRepodata(arena: Allocator, subdir: []const u8, files: []const LocalFile) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var ws = std.json.writeStream(out.writer(), .{});
    try ws.beginObject();
    try ws.objectField("info");
    try ws.write(.{ .subdir = subdir });
    try ws.objectField("packages");
    try ws.beginObject();
    try ws.endObject();
    try ws.objectField("packages.conda");
    try ws.beginObject();
    for (files) |f| {
        if (!std.mem.eql(u8, f.pkg.subdir, subdir)) continue;
        try ws.objectField(try fileName(arena, f.pkg));
        try ws.write(.{
            .build = f.pkg.build,
            .build_number = 0,
            .depends = f.depends,
            .name = try std.fmt.allocPrint(arena, "mojo-{s}", .{f.pkg.name}),
            .sha256 = f.pkg.sha256,
            .size = f.pkg.size,
            .subdir = subdir,
            .version = f.pkg.version,
        });
    }
    try ws.endObject();
    try ws.objectField("removed");
    try ws.beginArray();
    try ws.endArray();
    try ws.endObject();
    try out.append('\n');
    return out.items;
}

/// `file://` URL of an absolute path, each byte outside [A-Za-z0-9/._~-]
/// percent-encoded.
pub fn fileUrl(arena: Allocator, abs_path: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try out.appendSlice("file://");
    for (abs_path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/._~-", c) != null) {
            try out.append(c);
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
    return out.items;
}

fn tomlString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => if (c < 0x20 or c == 0x7f) try w.print("\\u{X:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// `.mopm/pixi.toml`: the local channel first, then the toolchain's; the
/// toolchain pinned to the lock's Mojo; each of `pkgs` pinned to its
/// version, build and sha256.
pub fn pixiToml(arena: Allocator, local_channel: []const u8, platform: []const u8, mojo: []const u8, pkgs: []const lock.Package) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.writeAll("# Written by mopm sync from mopm.lock. Do not edit: every sync rewrites it.\n[workspace]\nname = \"mopm-env\"\nchannels = [");
    try tomlString(w, local_channel);
    for (toolchain_channels) |c| {
        try w.writeAll(", ");
        try tomlString(w, c);
    }
    try w.writeAll("]\nplatforms = [");
    try tomlString(w, platform);
    try w.writeAll("]\n\n[dependencies]\nmojo = ");
    try tomlString(w, try std.fmt.allocPrint(arena, "=={s}", .{mojo}));
    try w.writeAll("\nmojo-compiler = ");
    try tomlString(w, try std.fmt.allocPrint(arena, "=={s}", .{mojo}));
    try w.writeByte('\n');
    for (pkgs) |p| {
        try w.print("mojo-{s} = {{ version = ", .{p.name});
        try tomlString(w, try std.fmt.allocPrint(arena, "=={s}", .{p.version}));
        try w.writeAll(", build = ");
        try tomlString(w, p.build);
        try w.writeAll(", sha256 = ");
        try tomlString(w, p.sha256);
        try w.writeAll(" }\n");
    }
    return out.items;
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

test "downloaded bytes: the pinned ones pass; a changed byte or length is refused, naming both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = pkg("greet", "1.0.0", "linux-64", &.{});
    try std.testing.expectEqual(@as(?[]const u8, null), try checkBytes(a, p, "abc"));
    const flipped = (try checkBytes(a, p, "abd")).?;
    try std.testing.expect(std.mem.startsWith(u8, flipped, "mojo-greet-1.0.0-mojo1.0.0_0.conda: sha256 mismatch: mopm.lock pins " ++ sha_abc ++ ", the file is "));
    try std.testing.expect(std.mem.endsWith(u8, flipped, "; refused"));
    try std.testing.expectEqualStrings("mojo-greet-1.0.0-mojo1.0.0_0.conda: mopm.lock pins 3 bytes, the file has 4; refused", (try checkBytes(a, p, "abcd")).?);
}

test "the channel's entry: depends when it agrees, both values when it does not, null when removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = pkg("greet", "1.0.0", "linux-64", &.{});
    const entry = "\"mojo-greet-1.0.0-mojo1.0.0_0.conda\":{\"build\":\"mojo1.0.0_0\",\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-greet\",\"size\":3,\"sha256\":\"";
    const good = "{\"packages.conda\":{" ++ entry ++ sha_abc ++ "\"}},\"removed\":[]}";
    const deps = (try lookUp(a, good, p)).ok.?;
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("mojo-compiler ==1.0.0", deps[0]);

    const differs = "{\"packages.conda\":{" ++ entry ++ sha_other ++ "\"}},\"removed\":[]}";
    try std.testing.expectEqualStrings(
        "mojo-greet-1.0.0-mojo1.0.0_0.conda: mopm.lock pins sha256 " ++ sha_abc ++ ", size 3; https://conda.mopm.dev/linux-64/repodata.json says {\"sha256\":\"" ++ sha_other ++ "\",\"size\":3}",
        (try lookUp(a, differs, p)).bad,
    );
    const removed = "{\"packages.conda\":{},\"removed\":[\"mojo-greet-1.0.0-mojo1.0.0_0.conda\"]}";
    try std.testing.expect((try lookUp(a, removed, p)).ok == null);
    try std.testing.expectEqualStrings(
        "https://conda.mopm.dev/linux-64/repodata.json does not offer mojo-greet-1.0.0-mojo1.0.0_0.conda, which mopm.lock pins",
        (try lookUp(a, "{\"packages.conda\":{}}", p)).bad,
    );
    try std.testing.expect((try lookUp(a, "nope", p)) == .bad);

    const yanked = try dependsFromLock(a, pkg("http_client", "0.4.0", "linux-64", &.{ "crypto", "http_core" }));
    try std.testing.expectEqual(@as(usize, 3), yanked.len);
    try std.testing.expectEqualStrings("mojo-compiler ==1.0.0", yanked[0]);
    try std.testing.expectEqualStrings("mojo-http_core", yanked[2]);
}

test "the generated pixi project and local repodata, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pkgs = (try forSubdir(a, app_lock, "linux-64")).ok;
    const local = try fileUrl(a, "/work/my app/.mopm/channel");
    try std.testing.expectEqualStrings("file:///work/my%20app/.mopm/channel", local);
    try std.testing.expectEqualStrings(
        \\# Written by mopm sync from mopm.lock. Do not edit: every sync rewrites it.
        \\[workspace]
        \\name = "mopm-env"
        \\channels = ["file:///work/my%20app/.mopm/channel", "https://conda.modular.com/max", "conda-forge"]
        \\platforms = ["linux-64"]
        \\
        \\[dependencies]
        \\mojo = "==1.0.0"
        \\mojo-compiler = "==1.0.0"
        \\mojo-crypto = { version = "==2.0.1", build = "mojo1.0.0_0", sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }
        \\mojo-http_client = { version = "==0.4.0", build = "mojo1.0.0_0", sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }
        \\mojo-http_core = { version = "==1.2.5", build = "mojo1.0.0_0", sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }
        \\
    , try pixiToml(a, local, "linux-64", "1.0.0", pkgs));

    var buf = std.ArrayList(u8).init(a);
    try tomlString(buf.writer(), "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u000A\"", buf.items);

    const files = [_]LocalFile{
        .{ .pkg = pkgs[0], .depends = &.{"mojo-compiler ==1.0.0"} },
        .{ .pkg = pkgs[2], .depends = &.{} },
    };
    try std.testing.expectEqualStrings(
        "{\"info\":{\"subdir\":\"linux-64\"},\"packages\":{},\"packages.conda\":{\"mojo-crypto-2.0.1-mojo1.0.0_0.conda\":" ++
            "{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-crypto\"," ++
            "\"sha256\":\"" ++ sha_abc ++ "\",\"size\":3,\"subdir\":\"linux-64\",\"version\":\"2.0.1\"}},\"removed\":[]}\n",
        try localRepodata(a, "linux-64", &files),
    );
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
