//! `mopm sync`: install exactly what mopm.lock pins, and the Mojo toolchain,
//! into the project's own environment, with no pixi, conda or solver.
//!
//!   .mopm/pkgs/<file>.conda   each locked file of this host's subdir (or
//!                             noarch), kept only if its size and sha256 are
//!                             the lock's (core/pkg_fetch.zig)
//!   <cache>/<sha256>/<file>   each file of the toolchain's closure and each
//!                             system library the lock pins, kept the same
//!                             way; the cache is shared by projects, and a
//!                             directory per sha256 keeps two pins of one file
//!                             name apart
//!   .mopm/env                 the environment: every file unpacked by
//!                             core/conda_env.zig into a temporary directory
//!                             beside it, looked at, and renamed into place,
//!                             so it is the old environment or the whole new
//!                             one; `mopm build`, `run` and `repl` find it
//!                             without `--prefix` (core/env.zig)
//!
//! The toolchain is not solved: core/closure.zig is the pre-resolved list of
//! every package `mojo` needs, per Mojo version and platform, with the sha256
//! and size of each. `planInstall` joins it with the lock's system libraries
//! and packages into the one list that is installed (toolchain, libraries,
//! locked packages). A library the toolchain also holds is not added again
//! when the bytes are the same and replaces the toolchain's when they are not
//! (with a warning); a locked package that would install under the name of a
//! toolchain package or a library, and any file name that is not one plain
//! path component, is refused. `stampOf` is a digest of that list and of the
//! environment's absolute path: the environment records it, and a sync whose
//! list has the same stamp, and whose environment `checkInstalled` and
//! `verifyItems` find intact, downloads nothing. `checkInstalled` checks each
//! locked package's `conda-meta` record names the locked sha256, its
//! `lib/mojo/<name>.mopm.json` is there, every native library the lock gives
//! a sha256 hashes to it, each system library's record names its sha256, and
//! no `lib/mojo/*.mopm.json` is installed that the lock does not name.
//! `verifyItems` checks that every item has its record with the item's sha256
//! and that every path the record lists exists.
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
const lock_libs = @import("lock_libs.zig");

/// Where `mopm sync` keeps the environment, relative to the project: the
/// directory, the environment's name in it and its path, and the directory
/// of the locked files.
pub const dir = ".mopm";
pub const env_name = "env";
pub const prefix = ".mopm/env";
pub const pkgs_dir = ".mopm/pkgs";

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
/// One file to install: a locked package, a system library the lock pins, or one of the toolchain's.
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
    /// The lock's package, for a locked file; null for a toolchain file or a library.
    locked: ?lock.Package = null,
    /// True for a system library of the lock's `system_libs`.
    lib: bool = false,
};

pub const Plan = struct {
    items: []const Item,
    /// What the plan changed from the toolchain as pinned; for the user, not an error.
    warnings: []const []const u8 = &.{},
};

pub const Planned = union(enum) { ok: Plan, bad: []const u8 };

/// The item for the system library `l`: its file name is the last part of its URL and its channel the URL up to
/// `/<subdir>/<file>`. Null with `why` set when the URL does not give a `.conda` file name.
fn libItem(arena: Allocator, l: lock_libs.Lib, why: *[]const u8) Allocator.Error!?Item {
    const last = std.mem.lastIndexOfScalar(u8, l.url, '/');
    const before = if (last) |i| std.mem.lastIndexOfScalar(u8, l.url[0..i], '/') else null;
    const file = if (last) |i| l.url[i + 1 ..] else l.url;
    if (before == null or !closure.safeComponent(file) or !std.mem.endsWith(u8, file, ".conda")) {
        why.* = try std.fmt.allocPrint(arena, "the lock's system library {s} {s} has the url '{}', which does not end in <subdir>/<file>.conda; refused", .{ l.name, l.version, std.zig.fmtEscapes(l.url) });
        return null;
    }
    return .{
        .name = l.name,
        .version = l.version,
        .file_name = file,
        .url = l.url,
        .sha256 = l.sha256,
        .size = l.size,
        .channel = l.url[0..before.?],
        .lib = true,
    };
}

/// The files to install for `pkgs` (the lock's, see `forSubdir`), the system libraries `libs` the lock pins
/// for this subdir, and the toolchain closure `c`: the toolchain's first, then the libraries, then the locked
/// ones. A library that is a toolchain package with the same bytes is not added again; with other bytes it
/// takes the toolchain package's place, and a warning says so. A locked package whose conda name is a
/// toolchain package's or a library's is refused, and so is a file name that is not a plain `.conda` name.
pub fn planInstall(arena: Allocator, pkgs: []const lock.Package, libs: []const lock_libs.Lib, c: closure.Closure) !Planned {
    var items = std.ArrayList(Item).init(arena);
    var warnings = std.ArrayList([]const u8).init(arena);
    var names = std.StringHashMap(usize).init(arena);
    for (c.packages) |p| {
        const file = closure.fileName(p);
        if (!closure.safeComponent(file)) {
            return .{ .bad = try std.fmt.allocPrint(arena, "the Mojo {s} toolchain has the file name '{}', which is not a safe file name; refused", .{ c.mojo, std.zig.fmtEscapes(file) }) };
        }
        try names.put(p.name, items.items.len);
        try items.append(.{
            .name = p.name,
            .version = p.version,
            .file_name = file,
            .url = try closure.urlOf(arena, c, p),
            .sha256 = p.sha256,
            .size = p.size,
            .channel = p.channel,
            .md5 = p.md5,
        });
    }
    var lib_names = std.StringHashMap(void).init(arena);
    for (libs) |l| {
        var why: []const u8 = "";
        const item = (try libItem(arena, l, &why)) orelse return .{ .bad = why };
        try lib_names.put(l.name, {});
        const at = names.get(l.name) orelse {
            try names.put(l.name, items.items.len);
            try items.append(item);
            continue;
        };
        const old = items.items[at];
        if (std.mem.eql(u8, old.sha256, item.sha256)) continue;
        try warnings.append(try std.fmt.allocPrint(arena, "the lock pins {s} {s} ({s}); it replaces the Mojo {s} toolchain's {s}", .{ item.name, item.version, item.file_name, c.mojo, old.file_name }));
        items.items[at] = item;
    }
    for (pkgs) |p| {
        const conda_name = try std.fmt.allocPrint(arena, "mojo-{s}", .{p.name});
        if (names.contains(conda_name)) {
            const holder = if (lib_names.contains(conda_name)) "the lock's system libraries" else try std.fmt.allocPrint(arena, "the Mojo {s} toolchain", .{c.mojo});
            return .{ .bad = try std.fmt.allocPrint(arena, "the locked package {s} would install as {s}, which {s} already hold{s}; refused", .{ p.name, conda_name, holder, if (lib_names.contains(conda_name)) "" else "s" }) };
        }
        const file = try fileName(arena, p);
        if (!closure.safeComponent(file)) {
            return .{ .bad = try std.fmt.allocPrint(arena, "the locked package {s} has the file name '{}', which is not a safe file name; refused", .{ p.name, std.zig.fmtEscapes(file) }) };
        }
        try items.append(.{
            .name = conda_name,
            .version = p.version,
            .file_name = file,
            .url = p.url,
            .sha256 = p.sha256,
            .size = p.size,
            .channel = p.channel,
            .locked = p,
        });
    }
    return .{ .ok = .{ .items = items.items, .warnings = warnings.items } };
}

/// A digest of what `items` are, in order, and of where they are installed (`prefix_abs`, the environment's
/// absolute path, which the files' placeholders are rewritten to): the same list at the same place gives the
/// same stamp, so an environment that records it need not be installed again; a project that moved gives
/// another. The leading "mopm-env 2" names how the files are unpacked (core/conda_env.zig,
/// core/conda_unpack.zig): a change there that makes another environment of the same files must change it, so
/// existing environments are installed again. URLs are not in it: a mirror of the same files is the same stamp.
pub fn stampOf(arena: Allocator, prefix_abs: []const u8, items: []const Item) Allocator.Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("mopm-env 2\n");
    var line = std.ArrayList(u8).init(arena);
    try line.writer().print("prefix {s}\n", .{prefix_abs});
    h.update(line.items);
    for (items) |i| {
        line.clearRetainingCapacity();
        try line.writer().print("{s} {s} {s} {s} {d}\n", .{ i.name, i.version, i.file_name, i.sha256, i.size });
        h.update(line.items);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return arena.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// The `conda-meta` record of a package installed from `file_name` (`<name>-<version>-<build>.conda`).
fn recordPath(arena: Allocator, file_name: []const u8) Allocator.Error![]const u8 {
    const stem = if (std.mem.endsWith(u8, file_name, ".conda")) file_name[0 .. file_name.len - ".conda".len] else if (std.mem.endsWith(u8, file_name, ".tar.bz2")) file_name[0 .. file_name.len - ".tar.bz2".len] else file_name;
    return std.fmt.allocPrint(arena, "conda-meta/{s}.json", .{stem});
}

/// Why `env` is not what `items` say, or null: for each item its `conda-meta` record is there with the item's
/// sha256 and every path the record lists exists (as a file, directory or link; file contents are not hashed
/// here, `checkInstalled` hashes the native libraries the lock pins).
pub fn verifyItems(arena: Allocator, env: std.fs.Dir, items: []const Item) !?[]const u8 {
    for (items) |item| {
        const record = try recordPath(arena, item.file_name);
        const text = env.readFileAlloc(arena, record, 64 << 20) catch |e| switch (e) {
            error.FileNotFound => return try std.fmt.allocPrint(arena, "{s} {s} is not installed: no {s}", .{ item.name, item.version, record }),
            else => return e,
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return try std.fmt.allocPrint(arena, "{s} is not JSON", .{record});
        const obj = if (v == .object) v.object else return try std.fmt.allocPrint(arena, "{s} is not a record", .{record});
        const sha = obj.get("sha256");
        if (sha == null or sha.? != .string or !std.mem.eql(u8, sha.?.string, item.sha256)) {
            const got = if (sha != null and sha.? == .string) sha.?.string else "none";
            return try std.fmt.allocPrint(arena, "installed {s} {s} has sha256 {s}; the install pins {s}", .{ item.name, item.version, got, item.sha256 });
        }
        const files = obj.get("files");
        if (files == null or files.? != .array) return try std.fmt.allocPrint(arena, "{s} lists no files", .{record});
        for (files.?.array.items) |f| {
            if (f != .string) return try std.fmt.allocPrint(arena, "{s} lists a file that is not a name", .{record});
            _ = std.posix.fstatat(env.fd, f.string, std.posix.AT.SYMLINK_NOFOLLOW) catch
                return try std.fmt.allocPrint(arena, "{s} {s} is missing {s}", .{ item.name, item.version, f.string });
        }
    }
    return null;
}

/// Why the environment at `env` is not exactly `pkgs` as locked, or null.
/// See the file comment for what is checked.
pub fn checkInstalled(arena: Allocator, env: std.fs.Dir, pkgs: []const lock.Package, libs: []const lock_libs.Lib) !?[]const u8 {
    for (libs) |l| {
        const record = try std.fmt.allocPrint(arena, "conda-meta/{s}-{s}-{s}.json", .{ l.name, l.version, l.build });
        const text = env.readFileAlloc(arena, record, 64 << 20) catch |e| switch (e) {
            error.FileNotFound => return try std.fmt.allocPrint(arena, "the system library {s} {s} is not installed: no {s}", .{ l.name, l.version, record }),
            else => return e,
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return try std.fmt.allocPrint(arena, "{s} is not JSON", .{record});
        const sha = if (v == .object) v.object.get("sha256") else null;
        if (sha == null or sha.? != .string or !std.mem.eql(u8, sha.?.string, l.sha256)) {
            const got = if (sha != null and sha.? == .string) sha.?.string else "none";
            return try std.fmt.allocPrint(arena, "installed system library {s} {s} has sha256 {s}; mopm.lock pins {s}; refused", .{ l.name, l.version, got, l.sha256 });
        }
    }
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

    try std.testing.expectEqualStrings("mojo-greet 1.0.0 (mojo1.0.0_0) is not installed: no conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", (try checkInstalled(a, env, &pkgs, &.{})).?);
    try env.writeFile("conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", "{\"name\":\"mojo-greet\",\"sha256\":\"" ++ sha_other ++ "\"}");
    try std.testing.expectEqualStrings("installed mojo-greet 1.0.0 has sha256 " ++ sha_other ++ "; mopm.lock pins " ++ sha_abc ++ "; refused", (try checkInstalled(a, env, &pkgs, &.{})).?);
    try env.writeFile("conda-meta/mojo-greet-1.0.0-mojo1.0.0_0.json", "{\"name\":\"mojo-greet\",\"sha256\":\"" ++ sha_abc ++ "\"}");
    try std.testing.expectEqualStrings("mojo-greet 1.0.0 is installed without lib/mojo/greet.mopm.json: a corrupt package", (try checkInstalled(a, env, &pkgs, &.{})).?);
    try env.writeFile("lib/mojo/greet.mopm.json", "{}");
    try std.testing.expectEqualStrings("mojo-greet 1.0.0: its native library lib/libgreet.so is not installed", (try checkInstalled(a, env, &pkgs, &.{})).?);
    try env.writeFile("lib/libgreet.so", "abd");
    try std.testing.expect(std.mem.startsWith(u8, (try checkInstalled(a, env, &pkgs, &.{})).?, "lib/libgreet.so of mojo-greet 1.0.0 has sha256 "));
    try env.writeFile("lib/libgreet.so", "abc");
    try std.testing.expectEqual(@as(?[]const u8, null), try checkInstalled(a, env, &pkgs, &.{}));
    try env.writeFile("lib/mojo/stray.mopm.json", "{}");
    try std.testing.expectEqualStrings("lib/mojo/stray.mopm.json is installed but mopm.lock does not lock stray; refused", (try checkInstalled(a, env, &pkgs, &.{})).?);
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

test "planInstall: the toolchain first, then the locked packages; a name the toolchain holds is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = closure.Closure{
        .mojo = "1.0.0",
        .subdir = "linux-64",
        .channels = &.{.{ .name = "max", .url = "https://conda.example/max/" }},
        .packages = &.{
            .{ .name = "mojo", .version = "1.0.0", .build = "release", .subdir = "linux-64", .channel = "max", .path = "linux-64/mojo-1.0.0-release.conda", .sha256 = "a" ** 64, .md5 = "m", .size = 10 },
            .{ .name = "mojo-python", .version = "1.0.0", .build = "release", .subdir = "noarch", .channel = "max", .path = "noarch/mojo-python-1.0.0-release.conda", .sha256 = "b" ** 64, .size = 20 },
        },
    };
    var greet = pkg("greet", "1.0.0", "linux-64", &.{});
    greet.url = "https://conda.mopm.dev/linux-64/mojo-greet-1.0.0-mojo1.0.0_0.conda";
    const items = (try planInstall(a, &.{greet}, &.{}, c)).ok.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("mojo", items[0].name);
    try std.testing.expectEqualStrings("mojo-1.0.0-release.conda", items[0].file_name);
    try std.testing.expectEqualStrings("https://conda.example/max/linux-64/mojo-1.0.0-release.conda", items[0].url);
    try std.testing.expectEqualStrings("m", items[0].md5);
    try std.testing.expect(items[0].locked == null);
    try std.testing.expectEqualStrings("https://conda.example/max/noarch/mojo-python-1.0.0-release.conda", items[1].url);
    try std.testing.expectEqualStrings("mojo-greet", items[2].name);
    try std.testing.expectEqualStrings("mojo-greet-1.0.0-mojo1.0.0_0.conda", items[2].file_name);
    try std.testing.expectEqualStrings(greet.url, items[2].url);
    try std.testing.expectEqual(@as(u64, 3), items[2].size);
    try std.testing.expectEqualStrings("greet", items[2].locked.?.name);

    // With no locked package, the toolchain alone.
    try std.testing.expectEqual(@as(usize, 2), (try planInstall(a, &.{}, &.{}, c)).ok.items.len);

    // A package called "python" would install as mojo-python, which the toolchain holds.
    try std.testing.expectEqualStrings(
        "the locked package python would install as mojo-python, which the Mojo 1.0.0 toolchain already holds; refused",
        (try planInstall(a, &.{pkg("python", "1.0.0", "linux-64", &.{})}, &.{}, c)).bad,
    );
}

test "stampOf: the same files give the same stamp; another hash, size, file or order gives another" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = Item{ .name = "mojo", .version = "1.0.0", .file_name = "mojo-1.0.0-r.conda", .url = "https://a/mojo", .sha256 = "a" ** 64, .size = 10, .channel = "max" };
    const two = Item{ .name = "mojo-greet", .version = "1.0.0", .file_name = "mojo-greet-1.0.0-b.conda", .url = "https://b/g", .sha256 = "b" ** 64, .size = 3, .channel = "c" };
    const s = try stampOf(a, "/p/.mopm/env", &.{ one, two });
    try std.testing.expectEqual(@as(usize, 64), s.len);
    try std.testing.expectEqualStrings(s, try stampOf(a, "/p/.mopm/env", &.{ one, two }));
    // A mirror: another url, the same bytes, the same stamp.
    var mirrored = one;
    mirrored.url = "https://mirror/mojo";
    try std.testing.expectEqualStrings(s, try stampOf(a, "/p/.mopm/env", &.{ mirrored, two }));

    var other_sha = two;
    other_sha.sha256 = "c" ** 64;
    var other_size = two;
    other_size.size = 4;
    var other_file = two;
    other_file.file_name = "mojo-greet-1.0.0-c.conda";
    var other_version = two;
    other_version.version = "1.0.1";
    for ([_][]const Item{ &.{ one, other_sha }, &.{ one, other_size }, &.{ one, other_file }, &.{ one, other_version }, &.{ two, one }, &.{one} }) |list| {
        try std.testing.expect(!std.mem.eql(u8, s, try stampOf(a, "/p/.mopm/env", list)));
    }
}

test "stampOf: the prefix is part of it, a url is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = Item{ .name = "mojo", .version = "1.0.0", .file_name = "mojo-1.0.0-r.conda", .url = "https://a/mojo", .sha256 = "a" ** 64, .size = 10, .channel = "max" };
    const here = try stampOf(a, "/work/one/.mopm/env", &.{one});
    const there = try stampOf(a, "/work/two/.mopm/env", &.{one});
    try std.testing.expect(!std.mem.eql(u8, here, there));
    var mirrored = one;
    mirrored.url = "https://mirror/mojo";
    try std.testing.expectEqualStrings(here, try stampOf(a, "/work/one/.mopm/env", &.{mirrored}));
}

const libz_url = "https://conda.example/forge/linux-64/libz-1.3.1-h0.conda";

fn lib(name: []const u8, url: []const u8, sha: []const u8) lock_libs.Lib {
    return .{ .name = name, .version = "1.3.1", .build = "h0", .url = url, .sha256 = sha, .size = 7 };
}

const tc_two = closure.Closure{
    .mojo = "1.0.0",
    .subdir = "linux-64",
    .channels = &.{.{ .name = "max", .url = "https://conda.example/max/" }},
    .packages = &.{
        .{ .name = "mojo", .version = "1.0.0", .build = "release", .subdir = "linux-64", .channel = "max", .path = "linux-64/mojo-1.0.0-release.conda", .sha256 = "a" ** 64, .size = 10 },
        .{ .name = "libz", .version = "1.3.0", .build = "h0", .subdir = "linux-64", .channel = "max", .path = "linux-64/libz-1.3.0-h0.conda", .sha256 = "b" ** 64, .size = 20 },
    },
};

test "planInstall with system libraries: toolchain, libraries, locked packages; file name and channel come from the url" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const greet = pkg("greet", "1.0.0", "linux-64", &.{});
    const libs = [_]lock_libs.Lib{lib("libffi", "https://conda.example/forge/noarch/libffi-1.3.1-h0.conda", "c" ** 64)};
    const planned = (try planInstall(a, &.{greet}, &libs, tc_two)).ok;
    try std.testing.expectEqual(@as(usize, 0), planned.warnings.len);
    const items = planned.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("mojo", items[0].name);
    try std.testing.expectEqualStrings("libz", items[1].name);
    try std.testing.expectEqualStrings("libffi", items[2].name);
    try std.testing.expect(items[2].lib and items[2].locked == null);
    try std.testing.expectEqualStrings("libffi-1.3.1-h0.conda", items[2].file_name);
    try std.testing.expectEqualStrings("https://conda.example/forge", items[2].channel);
    try std.testing.expectEqualStrings("https://conda.example/forge/noarch/libffi-1.3.1-h0.conda", items[2].url);
    try std.testing.expectEqual(@as(u64, 7), items[2].size);
    try std.testing.expectEqualStrings("mojo-greet", items[3].name);
    try std.testing.expect(!items[3].lib and !items[0].lib);
}

test "planInstall with system libraries: the toolchain's own bytes are not added twice, other bytes replace them with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const same = (try planInstall(a, &.{}, &.{lib("libz", libz_url, "b" ** 64)}, tc_two)).ok;
    try std.testing.expectEqual(@as(usize, 2), same.items.len);
    try std.testing.expectEqual(@as(usize, 0), same.warnings.len);
    try std.testing.expect(!same.items[1].lib);
    try std.testing.expectEqualStrings("libz-1.3.0-h0.conda", same.items[1].file_name);

    const other = (try planInstall(a, &.{}, &.{lib("libz", libz_url, "d" ** 64)}, tc_two)).ok;
    try std.testing.expectEqual(@as(usize, 2), other.items.len);
    try std.testing.expect(other.items[1].lib);
    try std.testing.expectEqualStrings("libz-1.3.1-h0.conda", other.items[1].file_name);
    try std.testing.expectEqualStrings("d" ** 64, other.items[1].sha256);
    try std.testing.expectEqual(@as(usize, 1), other.warnings.len);
    try std.testing.expectEqualStrings("the lock pins libz 1.3.1 (libz-1.3.1-h0.conda); it replaces the Mojo 1.0.0 toolchain's libz-1.3.0-h0.conda", other.warnings[0]);
}

test "planInstall with system libraries: an unusable url or file name, a locked package under a library's name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        "https://conda.example/forge/linux-64/libz-1.3.1-h0.tar.bz2",
        "https://conda.example/forge/linux-64/..",
        "libz-1.3.1-h0.conda",
        "linux-64/libz-1.3.1-h0.conda",
        "https://conda.example/forge/linux-64/a\\b.conda",
        "",
    }) |url| {
        const got = (try planInstall(a, &.{}, &.{lib("libz", url, "d" ** 64)}, tc_two));
        try std.testing.expect(std.mem.startsWith(u8, got.bad, "the lock's system library libz 1.3.1 has the url '"));
        try std.testing.expect(std.mem.endsWith(u8, got.bad, "', which does not end in <subdir>/<file>.conda; refused"));
    }
    const clash = (try planInstall(a, &.{pkg("libffi", "1.0.0", "linux-64", &.{})}, &.{lib("mojo-libffi", libz_url, "d" ** 64)}, tc_two)).bad;
    try std.testing.expectEqualStrings("the locked package libffi would install as mojo-libffi, which the lock's system libraries already hold; refused", clash);
}

test "planInstall: a locked package whose file name is not one path component is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = (try planInstall(a, &.{pkg("evil/../x", "1.0.0", "linux-64", &.{})}, &.{}, tc_two)).bad;
    try std.testing.expectEqualStrings("the locked package evil/../x has the file name 'mojo-evil/../x-1.0.0-mojo1.0.0_0.conda', which is not a safe file name; refused", bad);
    var tc = tc_two;
    tc.packages = &.{.{ .name = "mojo", .version = "1.0.0", .build = "r", .subdir = "linux-64", .channel = "max", .path = "linux-64/..", .sha256 = "a" ** 64, .size = 10 }};
    try std.testing.expectEqualStrings("the Mojo 1.0.0 toolchain has the file name '..', which is not a safe file name; refused", (try planInstall(a, &.{}, &.{}, tc)).bad);
}

test "checkInstalled checks each system library's record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const env = tmp.dir;
    try env.makePath("conda-meta");
    const libs = [_]lock_libs.Lib{lib("libz", libz_url, sha_abc)};
    try std.testing.expectEqualStrings("the system library libz 1.3.1 is not installed: no conda-meta/libz-1.3.1-h0.json", (try checkInstalled(a, env, &.{}, &libs)).?);
    try env.writeFile("conda-meta/libz-1.3.1-h0.json", "not json");
    try std.testing.expectEqualStrings("conda-meta/libz-1.3.1-h0.json is not JSON", (try checkInstalled(a, env, &.{}, &libs)).?);
    try env.writeFile("conda-meta/libz-1.3.1-h0.json", "{\"sha256\":\"" ++ sha_other ++ "\"}");
    try std.testing.expectEqualStrings("installed system library libz 1.3.1 has sha256 " ++ sha_other ++ "; mopm.lock pins " ++ sha_abc ++ "; refused", (try checkInstalled(a, env, &.{}, &libs)).?);
    try env.writeFile("conda-meta/libz-1.3.1-h0.json", "[]");
    try std.testing.expect(std.mem.indexOf(u8, (try checkInstalled(a, env, &.{}, &libs)).?, "has sha256 none;") != null);
    try env.writeFile("conda-meta/libz-1.3.1-h0.json", "{\"sha256\":\"" ++ sha_abc ++ "\"}");
    try std.testing.expectEqual(@as(?[]const u8, null), try checkInstalled(a, env, &.{}, &libs));
}

test "verifyItems: every item's record names its sha256 and every file it lists is there, links included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const env = tmp.dir;
    try env.makePath("conda-meta");
    const item = Item{ .name = "mojo", .version = "1.0.0", .file_name = "mojo-1.0.0-r.conda", .url = "", .sha256 = sha_abc, .size = 3, .channel = "max" };
    const items = [_]Item{item};
    try std.testing.expectEqualStrings("mojo 1.0.0 is not installed: no conda-meta/mojo-1.0.0-r.json", (try verifyItems(a, env, &items)).?);
    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "nope");
    try std.testing.expectEqualStrings("conda-meta/mojo-1.0.0-r.json is not JSON", (try verifyItems(a, env, &items)).?);
    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "[]");
    try std.testing.expectEqualStrings("conda-meta/mojo-1.0.0-r.json is not a record", (try verifyItems(a, env, &items)).?);
    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "{\"sha256\":\"" ++ sha_other ++ "\",\"files\":[]}");
    try std.testing.expectEqualStrings("installed mojo 1.0.0 has sha256 " ++ sha_other ++ "; the install pins " ++ sha_abc, (try verifyItems(a, env, &items)).?);
    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "{\"sha256\":\"" ++ sha_abc ++ "\"}");
    try std.testing.expectEqualStrings("conda-meta/mojo-1.0.0-r.json lists no files", (try verifyItems(a, env, &items)).?);
    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "{\"sha256\":\"" ++ sha_abc ++ "\",\"files\":[3]}");
    try std.testing.expectEqualStrings("conda-meta/mojo-1.0.0-r.json lists a file that is not a name", (try verifyItems(a, env, &items)).?);

    try env.writeFile("conda-meta/mojo-1.0.0-r.json", "{\"sha256\":\"" ++ sha_abc ++ "\",\"files\":[\"bin/mojo\",\"lib/dangling\"]}");
    try env.makePath("bin");
    try std.testing.expectEqualStrings("mojo 1.0.0 is missing bin/mojo", (try verifyItems(a, env, &items)).?);
    try env.writeFile("bin/mojo", "x");
    try std.testing.expectEqualStrings("mojo 1.0.0 is missing lib/dangling", (try verifyItems(a, env, &items)).?);
    // A symlink counts as present even when what it points at is not.
    try env.makePath("lib");
    try env.symLink("nowhere", "lib/dangling", .{});
    try std.testing.expectEqual(@as(?[]const u8, null), try verifyItems(a, env, &items));
    // A .tar.bz2 file name names its record the same way.
    try env.writeFile("conda-meta/old-1-0.json", "{\"sha256\":\"" ++ sha_abc ++ "\",\"files\":[]}");
    var old = item;
    old.file_name = "old-1-0.tar.bz2";
    try std.testing.expectEqual(@as(?[]const u8, null), try verifyItems(a, env, &.{old}));
}
