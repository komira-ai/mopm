//! Installing a set of verified `.conda` files as one conda environment, with
//! no conda and no pixi.
//!
//! The environment is replaced in steps, so the caller can look at the new one
//! before it replaces anything:
//!
//! - `recover` (first, under the caller's lock) finishes what an interrupted
//!   run left beside the target: when the target is missing, the latest backup
//!   `.<env>.old-<n>` (the highest `n`; `commit` numbers each backup one past
//!   the highest there) is put back; temporary `.<env>.tmp-*` directories and,
//!   once the target exists, the older backups are deleted. When it cannot
//!   tell which backup is the latest (two or more, one not numbered) it keeps
//!   them all and says so.
//! - `stage` builds the new environment in `.<env>.tmp-<rand>` beside the
//!   target. The files are unpacked by core/conda_unpack.zig with the prefix
//!   placeholders pointing at the target's own path; each package gets the
//!   `conda-meta/<name>-<version>-<build>.json` record conda writes, so the
//!   result is a valid conda prefix (`conda list` and pixi read it). Before a
//!   file is unpacked its size and sha256 are checked against the pin, the
//!   names the archive declares must be safe file name parts, and a path two
//!   packages both install must hold the same file bytes in both (the
//!   packages' own `info/` files, licences and notes, are the one exception:
//!   the last package wins).
//! - `commit` swaps the candidate in with renames: the target is moved to a
//!   backup `.<env>.old-<n>`, the candidate becomes the target, the backup is
//!   deleted. If the
//!   second rename fails the backup is renamed back; if that fails too the
//!   backup stays and the message names it, for the next `recover`.
//! - `discard` deletes a candidate that was not committed.
//!
//! The target is therefore always the environment as it was or the whole new
//! one, never half of either.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unpack = @import("conda_unpack.zig");
const fetch = @import("pkg_fetch.zig");
const closure = @import("closure.zig");

pub const Pkg = struct {
    name: []const u8,
    version: []const u8,
    /// The directory holding the file, and its name there.
    dir: std.fs.Dir,
    file_name: []const u8,
    /// The pinned bytes of the file.
    sha256: []const u8,
    size: u64,
    /// For the conda-meta record.
    url: []const u8,
    channel: []const u8 = "",
    md5: []const u8 = "",
};

pub const Diag = unpack.Diag;

const PathRec = struct {
    _path: []const u8,
    path_type: []const u8,
    size_in_bytes: u64,
    sha256: ?[]const u8 = null,
    sha256_in_prefix: ?[]const u8 = null,
    prefix_placeholder: ?[]const u8 = null,
    file_mode: ?[]const u8 = null,
};

const Record = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    build_number: u64,
    subdir: []const u8,
    channel: []const u8,
    @"fn": []const u8,
    url: []const u8,
    sha256: []const u8,
    md5: ?[]const u8 = null,
    size: u64,
    depends: []const []const u8,
    constrains: ?std.json.Value = null,
    license: ?std.json.Value = null,
    timestamp: ?std.json.Value = null,
    files: []const []const u8,
    paths_data: struct { paths_version: u8 = 1, paths: []const PathRec },
    link: struct { source: []const u8, type: u8 = 1 },
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn recordOf(arena: Allocator, pkg: Pkg, inst: unpack.Installed) !Record {
    var files = std.ArrayList([]const u8).init(arena);
    var paths = std.ArrayList(PathRec).init(arena);
    for (inst.paths) |p| {
        try files.append(p.path);
        try paths.append(.{
            ._path = p.path,
            .path_type = if (p.kind == .softlink) "softlink" else "hardlink",
            .size_in_bytes = p.size,
            .sha256 = nonEmpty(p.sha256),
            .sha256_in_prefix = nonEmpty(p.sha256_in_prefix),
            .prefix_placeholder = nonEmpty(p.placeholder),
            .file_mode = nonEmpty(p.file_mode),
        });
    }
    return .{
        .name = inst.name,
        .version = inst.version,
        .build = inst.build,
        .build_number = inst.build_number,
        .subdir = inst.subdir,
        .channel = pkg.channel,
        .@"fn" = pkg.file_name,
        .url = pkg.url,
        .sha256 = pkg.sha256,
        .md5 = nonEmpty(pkg.md5),
        .size = pkg.size,
        .depends = inst.depends,
        .constrains = inst.index.object.get("constrains"),
        .license = inst.index.object.get("license"),
        .timestamp = inst.index.object.get("timestamp"),
        .files = files.items,
        .paths_data = .{ .paths = paths.items },
        .link = .{ .source = pkg.file_name },
    };
}

/// "3.15" for the python `version` "3.15.0" (or "3.15.0rc1"), else null.
fn pythonMinor(version: []const u8) ?[]const u8 {
    const dot1 = std.mem.indexOfScalar(u8, version, '.') orelse return null;
    const dot2 = std.mem.indexOfScalarPos(u8, version, dot1 + 1, '.') orelse return null;
    return version[0..dot2];
}

fn exists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

fn tempName(arena: Allocator, env_name: []const u8, kind: []const u8) ![]u8 {
    var r: [6]u8 = undefined;
    std.crypto.random.bytes(&r);
    return std.fmt.allocPrint(arena, ".{s}.{s}-{s}", .{ env_name, kind, std.fmt.bytesToHex(r, .lower) });
}

/// The number of the backup `name` (`.<env_name>.old-<n>`), or null when it is not numbered.
fn backupNumber(env_name: []const u8, name: []const u8) ?u64 {
    const digits = name[env_name.len + ".".len + ".old-".len ..];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// A name for the next backup of `env_name`: numbered one past the highest backup in `parent`, so that a later backup
/// always has a higher number than one an earlier run failed to delete.
fn backupName(arena: Allocator, parent: std.fs.Dir, env_name: []const u8) ![]u8 {
    const prefix = try std.fmt.allocPrint(arena, ".{s}.old-", .{env_name});
    var next: u64 = 1;
    var listing = try parent.openDir(".", .{ .iterate = true });
    defer listing.close();
    var it = listing.iterate();
    while (try it.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        if (backupNumber(env_name, e.name)) |n| next = @max(next, n +| 1);
    }
    return std.fmt.allocPrint(arena, "{s}{d:0>12}", .{ prefix, next });
}

/// The file of an environment that holds its stamp: the caller's digest of
/// what was installed (core/install.zig `stampOf`).
pub const stamp_file = "conda-meta/mopm-stamp";

/// The stamp of the environment `env_name` in `parent`; null when there is no
/// environment or it has no stamp.
pub fn readStamp(arena: Allocator, parent: std.fs.Dir, env_name: []const u8) ?[]const u8 {
    var env = parent.openDir(env_name, .{}) catch return null;
    defer env.close();
    return env.readFileAlloc(arena, stamp_file, 4096) catch null;
}

/// The renames and deletes of `recover` and `commit`. Production uses `RealOps`;
/// a test passes a type with the same two functions that fails on demand.
pub const RealOps = struct {
    pub fn rename(_: *RealOps, parent: std.fs.Dir, old: []const u8, new: []const u8) !void {
        try parent.rename(old, new);
    }
    pub fn deleteTree(_: *RealOps, parent: std.fs.Dir, name: []const u8) !void {
        try parent.deleteTree(name);
    }
};

pub const Recovered = struct {
    /// The name of the backup that was renamed back to the target, if one was.
    restored: ?[]const u8 = null,
    /// What could not be deleted; not an error.
    warnings: []const []const u8 = &.{},
};

/// Finishes what an interrupted run left beside the target `env_name` in
/// `parent`. Run it first, while no other run can be working there.
pub fn recover(arena: Allocator, parent: std.fs.Dir, env_name: []const u8) !Recovered {
    var ops = RealOps{};
    return recoverWith(&ops, arena, parent, env_name);
}

pub fn recoverWith(ops: anytype, arena: Allocator, parent: std.fs.Dir, env_name: []const u8) !Recovered {
    var tmps = std.ArrayList([]const u8).init(arena);
    var olds = std.ArrayList([]const u8).init(arena);
    {
        // `parent` may not have been opened for iteration: open it again, so.
        var listing = try parent.openDir(".", .{ .iterate = true });
        defer listing.close();
        const tmp_prefix = try std.fmt.allocPrint(arena, ".{s}.tmp-", .{env_name});
        const old_prefix = try std.fmt.allocPrint(arena, ".{s}.old-", .{env_name});
        var it = listing.iterate();
        while (try it.next()) |e| {
            if (std.mem.startsWith(u8, e.name, tmp_prefix)) try tmps.append(try arena.dupe(u8, e.name));
            if (std.mem.startsWith(u8, e.name, old_prefix)) try olds.append(try arena.dupe(u8, e.name));
        }
    }
    // Sorted only so that messages list them the same way every time; the order of the backups is their numbers.
    std.mem.sort([]const u8, olds.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var warnings = std.ArrayList([]const u8).init(arena);
    var out = Recovered{};
    var have_env = exists(parent, env_name);
    // The backup to put back: the only one, or the highest numbered when every one is numbered.
    var latest: ?usize = if (olds.items.len == 1) 0 else null;
    if (olds.items.len > 1) {
        var best: u64 = 0;
        for (olds.items, 0..) |n, i| {
            const num = backupNumber(env_name, n) orelse {
                latest = null;
                break;
            };
            if (latest == null or num > best) {
                latest = i;
                best = num;
            }
        }
    }
    var restored: ?usize = null;
    if (!have_env and olds.items.len > 0) {
        if (latest) |i| {
            if (ops.rename(parent, olds.items[i], env_name)) {
                out.restored = olds.items[i];
                restored = i;
                have_env = true;
            } else |e| {
                try warnings.append(try std.fmt.allocPrint(arena, "cannot put {s} back as {s}: {s}", .{ olds.items[i], env_name, @errorName(e) }));
            }
        } else {
            try warnings.append(try std.fmt.allocPrint(arena, "cannot tell which of {s} is the latest {s}, so all are kept; rename that one to {s}", .{ try std.mem.join(arena, ", ", olds.items), env_name, env_name }));
        }
    }
    for (tmps.items) |n| try deleteQuietly(ops, arena, parent, n, &warnings);
    if (have_env) {
        for (olds.items, 0..) |n, i| {
            if (restored != i) try deleteQuietly(ops, arena, parent, n, &warnings);
        }
    }
    out.warnings = warnings.items;
    return out;
}

fn deleteQuietly(ops: anytype, arena: Allocator, parent: std.fs.Dir, name: []const u8, warnings: *std.ArrayList([]const u8)) !void {
    ops.deleteTree(parent, name) catch |e| {
        try warnings.append(try std.fmt.allocPrint(arena, "cannot remove {s}: {s}", .{ name, @errorName(e) }));
    };
}

/// A fully built environment that has not replaced the target yet.
pub const Candidate = struct {
    /// Its directory name in `parent`.
    tmp_name: []const u8,
    installed: []const unpack.Installed,
};

/// One installed path: who put it there, and what it is.
const Owner = struct {
    pkg: usize,
    kind: @TypeOf(@as(unpack.PathEntry, undefined).kind),
    sha256: []const u8,
    /// Whether the file was executable as that package left it.
    exec: bool,
};

/// Whether the regular file `rel` in `dir` has an execute bit; false for anything else or what cannot be read.
fn executable(dir: std.fs.Dir, rel: []const u8) bool {
    const st = dir.statFile(rel) catch return false;
    return st.kind == .file and st.mode & 0o111 != 0;
}

fn contentSha(p: unpack.PathEntry) []const u8 {
    return if (p.sha256_in_prefix.len > 0) p.sha256_in_prefix else p.sha256;
}

/// Why the identifier `value` of `what` cannot name a file, else null.
fn unsafeName(arena: Allocator, file_name: []const u8, what: []const u8, value: []const u8) !?[]const u8 {
    if (closure.safeComponent(value)) return null;
    return try std.fmt.allocPrint(arena, "{s}: its {s} '{}' is not a safe file name part; refused", .{ file_name, what, std.zig.fmtEscapes(value) });
}

/// Builds the environment for `pkgs` in a temporary directory beside
/// `env_name` in `parent` (whose absolute path is `prefix`: placeholders are
/// rewritten to it) and records `stamp` in it (`stamp_file`). Nothing but that
/// directory is touched; on an error it is deleted too.
pub fn stage(arena: Allocator, parent: std.fs.Dir, env_name: []const u8, prefix: []const u8, pkgs: []const Pkg, stamp: []const u8, diag: *Diag) !Candidate {
    var python: ?[]const u8 = null;
    for (pkgs) |p| {
        if (std.mem.eql(u8, p.name, "python")) python = pythonMinor(p.version);
    }

    const window = try std.heap.page_allocator.alloc(u8, unpack.window_size);
    defer std.heap.page_allocator.free(window);

    const tmp_name = try tempName(arena, env_name, "tmp");
    try parent.makeDir(tmp_name);
    errdefer parent.deleteTree(tmp_name) catch {};
    var tmp = try parent.openDir(tmp_name, .{});
    defer tmp.close();
    try tmp.makePath("conda-meta");

    var links = std.StringHashMap(void).init(arena);
    var owners = std.StringHashMap(Owner).init(arena);
    var done = std.ArrayList(unpack.Installed).init(arena);
    var records = std.ArrayList(Record).init(arena);
    for (pkgs, 0..) |pkg, index| {
        if (!closure.safeComponent(pkg.file_name)) {
            diag.message = try std.fmt.allocPrint(arena, "'{}' is not a safe file name; refused", .{std.zig.fmtEscapes(pkg.file_name)});
            return error.UnsafeName;
        }
        if (!(try fetch.matches(pkg.dir, pkg.file_name, .{ .sha256 = pkg.sha256, .size = pkg.size }))) {
            diag.message = try std.fmt.allocPrint(arena, "{s} is not the pinned file (size {d}, sha256 {s}); refused", .{ pkg.file_name, pkg.size, pkg.sha256 });
            return error.HashMismatch;
        }
        const file = try pkg.dir.openFile(pkg.file_name, .{});
        defer file.close();
        const inst = unpack.install(arena, file, .{
            .prefix = prefix,
            .dest = tmp,
            .window = window,
            .python = python,
            .links = &links,
        }, diag) catch |e| {
            if (diag.message.len == 0) diag.message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ pkg.file_name, @errorName(e) });
            return e;
        };
        if (!std.mem.eql(u8, inst.name, pkg.name) or !std.mem.eql(u8, inst.version, pkg.version)) {
            diag.message = try std.fmt.allocPrint(arena, "{s} holds {s} {s}, not the {s} {s} that was asked for; refused", .{ pkg.file_name, inst.name, inst.version, pkg.name, pkg.version });
            return error.PackageMismatch;
        }
        // The record is named after these; nothing has been written under them yet.
        const bad = (try unsafeName(arena, pkg.file_name, "name", inst.name)) orelse
            (try unsafeName(arena, pkg.file_name, "version", inst.version)) orelse
            (try unsafeName(arena, pkg.file_name, "build", inst.build));
        if (bad) |m| {
            diag.message = m;
            return error.UnsafeName;
        }
        for (inst.paths) |p| {
            // `info/` holds a package's own licences and notes, which many conda-forge packages ship under the same
            // names with different texts, and conda lets the last one win; no program reads them.
            if (std.mem.startsWith(u8, p.path, "info/")) continue;
            // The mode is read now, before a later package can replace the file: it is part of what the package installs.
            const mine = Owner{ .pkg = index, .kind = p.kind, .sha256 = contentSha(p), .exec = p.kind == .file and executable(tmp, p.path) };
            const prev = (try owners.fetchPut(p.path, mine)) orelse continue;
            const other = prev.value;
            const same = other.kind == .file and mine.kind == .file and mine.sha256.len > 0 and std.mem.eql(u8, other.sha256, mine.sha256);
            if (!same or other.exec != mine.exec) {
                const a = pkgs[other.pkg];
                diag.message = try std.fmt.allocPrint(arena, "{s} is installed by both {s} {s} and {s} {s} with different {s}; refused", .{ p.path, a.name, a.version, pkg.name, pkg.version, if (same) "permissions" else "contents" });
                return error.PathConflict;
            }
        }
        try done.append(inst);
        try records.append(try recordOf(arena, pkg, inst));
    }

    for (records.items) |r| {
        const name = try std.fmt.allocPrint(arena, "conda-meta/{s}-{s}-{s}.json", .{ r.name, r.version, r.build });
        var out = std.ArrayList(u8).init(arena);
        try std.json.stringify(r, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 }, out.writer());
        try out.append('\n');
        try tmp.writeFile(name, out.items);
    }
    try tmp.writeFile("conda-meta/history", "");
    try tmp.writeFile(stamp_file, stamp);
    return .{ .tmp_name = tmp_name, .installed = done.items };
}

pub const Committed = struct {
    /// What could not be cleaned up after the swap; not an error.
    warnings: []const []const u8 = &.{},
};

/// Makes the candidate the environment `env_name`. On an error the candidate
/// still exists (the caller `discard`s it) and the target is the environment
/// it was, except with `error.BackupKept`: the previous environment could not
/// be put back and `diag.message` is the name of its backup beside the target,
/// which `recover` restores.
pub fn commit(arena: Allocator, parent: std.fs.Dir, env_name: []const u8, cand: Candidate, diag: *Diag) !Committed {
    var ops = RealOps{};
    return commitWith(&ops, arena, parent, env_name, cand, diag);
}

pub fn commitWith(ops: anytype, arena: Allocator, parent: std.fs.Dir, env_name: []const u8, cand: Candidate, diag: *Diag) !Committed {
    if (!exists(parent, env_name)) {
        ops.rename(parent, cand.tmp_name, env_name) catch |e| {
            diag.message = try std.fmt.allocPrint(arena, "cannot move the new environment to {s}: {s}", .{ env_name, @errorName(e) });
            return e;
        };
        return .{};
    }
    const old_name = try backupName(arena, parent, env_name);
    ops.rename(parent, env_name, old_name) catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "cannot move {s} aside: {s}", .{ env_name, @errorName(e) });
        return e;
    };
    ops.rename(parent, cand.tmp_name, env_name) catch |e| {
        ops.rename(parent, old_name, env_name) catch {
            diag.message = old_name;
            return error.BackupKept;
        };
        diag.message = try std.fmt.allocPrint(arena, "cannot move the new environment to {s}: {s}", .{ env_name, @errorName(e) });
        return e;
    };
    var warnings = std.ArrayList([]const u8).init(arena);
    try deleteQuietly(ops, arena, parent, old_name, &warnings);
    return .{ .warnings = warnings.items };
}

/// Deletes a candidate that was not committed.
pub fn discard(parent: std.fs.Dir, cand: Candidate) void {
    parent.deleteTree(cand.tmp_name) catch {};
}

test {
    _ = @import("conda_env_test.zig");
}
