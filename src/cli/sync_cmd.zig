//! `mopm sync`: lock when needed, then install the lock and the Mojo
//! toolchain into `.mopm/env` (see core/install.zig), with no pixi, conda or
//! solver.
//!
//!   mopm sync [--locked] [--registry <prod|gamma|beta|url>] [--overlay <dir>] [--cache <dir>] [--toolchain <file>]
//!
//! It locks first when there is no lock or it no longer matches mopm.toml (as
//! `mopm lock` does; never with `--locked`). It downloads each locked file of
//! this machine's subdir, each system library the lock pins for it and each
//! file of the pinned toolchain closure of the lock's Mojo
//! (core/closure.zig), refuses one whose size or sha256 is not its pin,
//! unpacks them all into a temporary directory beside `.mopm/env`, checks that
//! directory against the lock, and only then renames it into place (on any
//! failure the old environment stays). Locked files are kept in `.mopm/pkgs`;
//! the toolchain's and the libraries', which are large and the same for every
//! project, in `<cache>/<sha256>/<file>`, the cache being `--cache` (default
//! `$XDG_CACHE_HOME/mopm/pkgs`, else `~/.cache/mopm/pkgs`; one inside
//! `.mopm/env` is refused, see sync_cache.zig). A sync holds an exclusive lock
//! on `.mopm/sync.lock`, so a second one of the project waits; it first puts
//! back a backup an interrupted sync left. The environment records a stamp of
//! what it holds and where: a sync whose files and path have the same stamp,
//! and whose environment still holds every recorded file, downloads nothing;
//! one whose environment does not says why and installs it again. A version 2
//! lock that records the toolchain closure of its Mojo is refused, before any
//! download, when the closure to install hashes differently. `.mopm/.pixi`,
//! `.mopm/channel` and `.mopm/pixi.toml` of an older mopm are never read or
//! changed.
//! `--toolchain <file>` names another closure file than the built-in one (a
//! mirror: the same pins, other channel urls; or a test). With `--locked` it
//! never locks: a missing or out-of-date lock is an error, and the sparse index
//! is not read.
//!
//! `--overlay <dir>` reads a staged set (core/overlay.zig); `sync` installs a
//! locked file from the set when the set holds exactly the bytes the lock pins.
//! A path dependency is used from its directory and never downloaded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const lock = core.lock;
const inst = core.install;
const overlay = core.overlay;
const unit_graph = core.unit_graph;
const closure = core.closure;
const conda_env = core.conda_env;
const pkg_fetch = core.pkg_fetch;
const lock_libs = core.lock_libs;
const sync_cache = @import("sync_cache.zig");
const ic = @import("install_cmd.zig");

const Args = ic.Args;
const Project = ic.Project;
const err = ic.err;
const lock_path = ic.lock_path;
const manifest_path = ic.manifest_path;

/// `mopm sync`: lock when needed (never with `--locked`), then install.
pub fn sync(arena: Allocator, project: Project, old: ?lock.Lock, args: Args, cli_version: []const u8) !u8 {
    var stale: ?[]const u8 = "there is no " ++ lock_path;
    if (old) |o| {
        stale = null;
        if (try inst.staleness(arena, project.m.mojo, project.roots, project.paths, o)) |why| {
            stale = try std.fmt.allocPrint(arena, "{s} is out of date with {s}: {s}", .{ lock_path, manifest_path, why });
        }
    }
    const l = if (stale) |why| blk: {
        if (args.locked) {
            err(.sync, "--locked: {s}; run 'mopm lock' (or 'mopm sync' without --locked)\n", .{why});
            return 1;
        }
        break :blk (try ic.lockProject(arena, .sync, project, old, args, cli_version)) orelse return 1;
    } else old.?;
    const staged: ?overlay.Overlay = if (args.overlay) |dir| ((try ic.loadOverlay(arena, .sync, dir)) orelse return 1) else null;
    return install(arena, l, args, staged);
}

/// The toolchain closure of `mojo` on `subdir`: the `--toolchain` file, else mopm's pinned one. Null when there is none
/// (reported).
fn loadToolchain(arena: Allocator, mojo: []const u8, subdir: []const u8, file: ?[]const u8) !?closure.Closure {
    const closure_file = file orelse {
        var why: []const u8 = "";
        return unit_graph.pinnedClosure(arena, mojo, subdir, &why) catch |e| {
            if (e != error.Refused) return e;
            err(.sync, "{s}\n", .{why});
            return null;
        };
    };
    const text = std.fs.cwd().readFileAlloc(arena, closure_file, 16 << 20) catch |e| {
        err(.sync, "--toolchain {s}: {s}\n", .{ closure_file, @errorName(e) });
        return null;
    };
    const c = closure.parse(arena, text) catch |e| {
        if (e == error.OutOfMemory) return e;
        err(.sync, "--toolchain {s} is not a toolchain closure file: {s}\n", .{ closure_file, @errorName(e) });
        return null;
    };
    if (try closure.problem(arena, c)) |why| {
        err(.sync, "--toolchain {s}: {s}\n", .{ closure_file, why });
        return null;
    }
    if (!std.mem.eql(u8, c.mojo, mojo) or !std.mem.eql(u8, c.subdir, subdir)) {
        err(.sync, "--toolchain {s} is the closure of mojo {s} on {s}; this sync needs mojo {s} on {s}\n", .{ closure_file, c.mojo, c.subdir, mojo, subdir });
        return null;
    }
    return c;
}

/// Makes `dir/<item.file_name>` the item's pinned bytes, downloading it unless it is there already. False when that
/// failed (reported).
fn fetchItem(arena: Allocator, dir: std.fs.Dir, item: inst.Item) !bool {
    const pin = pkg_fetch.Pin{ .sha256 = item.sha256, .size = item.size };
    if (try pkg_fetch.matches(dir, item.file_name, pin)) return true;
    try std.io.getStdOut().writer().print("downloading {s} ({d} bytes)\n", .{ item.file_name, item.size });
    var diag = pkg_fetch.Diag{};
    pkg_fetch.fetch(arena, dir, item.file_name, item.url, pin, &diag) catch |e| switch (e) {
        error.DownloadFailed, error.BadStatus, error.SizeMismatch, error.HashMismatch => {
            const p = item.locked orelse {
                err(.sync, "{s}\n", .{diag.message});
                return false;
            };
            switch (diag.status) {
                403, 404, 410 => err(.sync, "{s}: {s} {s} has been taken down or is unavailable\n", .{ diag.message, p.name, p.version }),
                else => err(.sync, "{s}\n", .{diag.message}),
            }
            return false;
        },
        else => return e,
    };
    return true;
}

/// Holds the project's `.mopm/sync.lock` (an exclusive flock) until `release`. A second sync of the project waits
/// for the first, and says so on stderr first.
const ProjectLock = struct {
    file: std.fs.File,

    fn take(parent: std.fs.Dir) !ProjectLock {
        const file = try parent.createFile(sync_lock, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!try file.tryLock(.exclusive)) {
            err(.sync, "waiting for another mopm sync of this project to finish ({s}/{s})\n", .{ inst.dir, sync_lock });
            try file.lock(.exclusive);
        }
        return .{ .file = file };
    }

    fn release(self: ProjectLock) void {
        self.file.close();
    }
};

const sync_lock = "sync.lock";

/// Why `.mopm/env` does not hold exactly what `items` and the lock say, or null: its records, their files, the lock's
/// packages (their native libraries hashed) and the system libraries.
fn envProblem(arena: Allocator, env: std.fs.Dir, pkgs: []const lock.Package, libs: []const lock_libs.Lib, items: []const inst.Item) !?[]const u8 {
    if (try inst.checkInstalled(arena, env, pkgs, libs)) |why| return why;
    return inst.verifyItems(arena, env, items);
}

/// Refuses (reported) a lock that records the toolchain closure of its Mojo on `subdir` and `tc` is not that one.
fn closureAgrees(arena: Allocator, whole: lock.Lock, subdir: []const u8, tc: closure.Closure) !bool {
    for (whole.closures) |rec| {
        if (!std.mem.eql(u8, rec.mojo, whole.mojo) or !std.mem.eql(u8, rec.subdir, subdir)) continue;
        const have = try unit_graph.closureSha256(arena, tc);
        if (!std.mem.eql(u8, have, rec.sha256)) {
            err(.sync, "mopm.lock records toolchain closure {s} for mojo {s} on {s}; the toolchain to install has closure {s}; run 'mopm lock' (or pass the --toolchain file it was locked with)\n", .{ rec.sha256, rec.mojo, subdir, have });
            return false;
        }
    }
    return true;
}

/// The message of a `conda_env.commit` that failed with `e` and `message`: the environment is as it was, except after
/// `error.BackupKept`, where `message` names the backup of the previous one.
fn commitFailure(arena: Allocator, e: anyerror, message: []const u8) ![]const u8 {
    if (e == error.BackupKept) {
        return std.fmt.allocPrint(arena, "cannot install into {s}: the previous environment is at {s}/{s}; the next mopm sync puts it back", .{ inst.prefix, inst.dir, message });
    }
    return std.fmt.allocPrint(arena, "cannot install into {s}: {s}; the environment is as it was", .{ inst.prefix, if (message.len > 0) message else @errorName(e) });
}

/// Installs `whole` and its Mojo toolchain into `.mopm/env` (see core/install.zig); 0 when the environment is exactly
/// the lock.
fn install(arena: Allocator, whole: lock.Lock, args: Args, staged: ?overlay.Overlay) !u8 {
    // A version 2 lock installs the builds for its first Mojo version.
    const l = try lock.forMojo(arena, whole, whole.mojo);
    const cwd = std.fs.cwd();
    const subdir = inst.hostSubdir() orelse {
        err(.sync, "no Mojo toolchain is published for this machine (linux-64, linux-aarch64 and osx-arm64 are)\n", .{});
        return 1;
    };
    const pkgs = switch (try inst.forSubdir(arena, l, subdir)) {
        .ok => |p| p,
        .bad => |why| {
            err(.sync, "{s}\n", .{why});
            return 1;
        },
    };
    const libs = lock_libs.libsFor(whole.system_libs, subdir) orelse &[_]lock_libs.Lib{};
    const tc = (try loadToolchain(arena, l.mojo, subdir, args.toolchain)) orelse return 1;
    if (!try closureAgrees(arena, whole, subdir, tc)) return 1;
    const planned = switch (try inst.planInstall(arena, pkgs, libs, tc)) {
        .ok => |p| p,
        .bad => |why| {
            err(.sync, "{s}\n", .{why});
            return 1;
        },
    };
    const items = planned.items;

    try cwd.makePath(inst.dir);
    var parent = try cwd.openDir(inst.dir, .{});
    defer parent.close();
    const out = std.io.getStdOut().writer();

    // One sync of this project at a time: what follows deletes and renames beside `.mopm/env`.
    const project_lock = try ProjectLock.take(parent);
    defer project_lock.release();

    const recovered = try conda_env.recover(arena, parent, inst.env_name);
    for (recovered.warnings) |w| err(.sync, "warning: {s}\n", .{w});
    if (recovered.restored) |backup| err(.sync, "restored {s} from {s}/{s}\n", .{ inst.prefix, inst.dir, backup });

    const prefix_abs = try std.fs.path.join(arena, &.{ try parent.realpathAlloc(arena, "."), inst.env_name });
    const stamp = try inst.stampOf(arena, prefix_abs, items);

    var current = false;
    if (conda_env.readStamp(arena, parent, inst.env_name)) |have| {
        if (std.mem.eql(u8, have, stamp)) {
            var env = try parent.openDir(inst.env_name, .{});
            defer env.close();
            if (try envProblem(arena, env, pkgs, libs, items)) |why| {
                err(.sync, "{s} does not match its stamp ({s}); installing it again\n", .{ inst.prefix, why });
            } else {
                current = true;
            }
        }
    }

    var from_set: usize = 0;
    if (!current) {
        // The files of the toolchain and of the system libraries are the same for every project: the cache, a directory
        // per sha256. The locked packages are this project's.
        const cache_path = (try sync_cache.cacheDir(arena, args.cache)) orelse {
            err(.sync, "no HOME, so no cache directory for the toolchain's files: pass --cache <dir>\n", .{});
            return 1;
        };
        if (try sync_cache.placementProblem(arena, cwd, inst.dir, inst.env_name, cache_path)) |why| {
            err(.sync, "{s}\n", .{why});
            return 1;
        }
        var cache = cwd.makeOpenPath(cache_path, .{}) catch |e| {
            err(.sync, "cannot make the cache directory {s}: {s}\n", .{ cache_path, @errorName(e) });
            return 1;
        };
        defer cache.close();
        var locked_dir = try cwd.makeOpenPath(inst.pkgs_dir, .{});
        defer locked_dir.close();
        var opened = std.ArrayList(std.fs.Dir).init(arena);
        defer for (opened.items) |*d| d.close();

        var files = std.ArrayList(conda_env.Pkg).init(arena);
        for (items) |item| {
            const into = if (item.locked != null) locked_dir else blk: {
                const d = cache.makeOpenPath(item.sha256, .{}) catch |e| {
                    err(.sync, "cannot make the cache directory {s}/{s}: {s}\n", .{ cache_path, item.sha256, @errorName(e) });
                    return 1;
                };
                try opened.append(d);
                break :blk d;
            };
            // The staged set (--overlay) supplies exactly the file the lock pins, when it holds it: that file is not
            // downloaded.
            if (item.locked) |p| if (staged) |set| {
                var why: []const u8 = "";
                const bytes = set.bytesFor(arena, p, &why) catch |e| switch (e) {
                    error.Refused => {
                        err(.sync, "--overlay: {s}\n", .{why});
                        return 1;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (bytes) |b| {
                    if (try inst.checkBytes(arena, p, b)) |why_not| {
                        err(.sync, "{s} (read from the staged set)\n", .{why_not});
                        return 1;
                    }
                    if (!try pkg_fetch.matches(into, item.file_name, .{ .sha256 = item.sha256, .size = item.size })) {
                        try into.writeFile(item.file_name, b);
                    }
                    from_set += 1;
                }
            };
            if (!try fetchItem(arena, into, item)) return 1;
            try files.append(.{
                .name = item.name,
                .version = item.version,
                .dir = into,
                .file_name = item.file_name,
                .sha256 = item.sha256,
                .size = item.size,
                .url = item.url,
                .channel = item.channel,
                .md5 = item.md5,
            });
        }

        // The new environment is built and looked at beside the old one; only a good one replaces it.
        var diag = conda_env.Diag{};
        const cand = conda_env.stage(arena, parent, inst.env_name, prefix_abs, files.items, stamp, &diag) catch |e| {
            err(.sync, "cannot install into {s}: {s}; the environment is as it was\n", .{ inst.prefix, if (diag.message.len > 0) diag.message else @errorName(e) });
            return 1;
        };
        var problem: ?[]const u8 = null;
        {
            var candidate = try parent.openDir(cand.tmp_name, .{});
            defer candidate.close();
            problem = try envProblem(arena, candidate, pkgs, libs, items);
        }
        if (problem) |why| {
            conda_env.discard(parent, cand);
            err(.sync, "cannot install into {s}: {s}; the environment is as it was\n", .{ inst.prefix, why });
            return 1;
        }
        const committed = conda_env.commit(arena, parent, inst.env_name, cand, &diag) catch |e| {
            conda_env.discard(parent, cand);
            err(.sync, "{s}\n", .{try commitFailure(arena, e, diag.message)});
            return 1;
        };
        for (committed.warnings) |w| err(.sync, "warning: {s}\n", .{w});
        for (planned.warnings) |w| err(.sync, "warning: {s}\n", .{w});
    }

    for (l.packages) |p| {
        if (p.source == .path) try out.print("using {s} {s} from {s} (a path dependency: built from source, not downloaded)\n", .{ p.name, p.version, p.path });
    }
    if (current) {
        try out.print("{s} is current: {d} packages for {s} (mojo {s}, {d} toolchain files); nothing to download\n", .{ inst.prefix, pkgs.len, subdir, l.mojo, tc.packages.len });
        return 0;
    }
    if (from_set > 0) try out.print("read {d} packages from the staged set {s}\n", .{ from_set, staged.?.dir });
    try out.print("installed {d} packages for {s} (mojo {s}, {d} toolchain files) into {s}\n", .{ pkgs.len, subdir, l.mojo, tc.packages.len, inst.prefix });
    return 0;
}


test {
    _ = sync_cache;
}

test "a commit that failed says the environment is as it was, or where the backup of the previous one is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "cannot install into .mopm/env: cannot move env aside: AccessDenied; the environment is as it was",
        try commitFailure(a, error.AccessDenied, "cannot move env aside: AccessDenied"),
    );
    try std.testing.expectEqualStrings(
        "cannot install into .mopm/env: AccessDenied; the environment is as it was",
        try commitFailure(a, error.AccessDenied, ""),
    );
    try std.testing.expectEqualStrings(
        "cannot install into .mopm/env: the previous environment is at .mopm/.env.old-x1; the next mopm sync puts it back",
        try commitFailure(a, error.BackupKept, ".env.old-x1"),
    );
}
