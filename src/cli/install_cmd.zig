//! `mopm lock`, `mopm update`, `mopm tree` and `mopm sync`: resolve the
//! project's dependencies against a registry's sparse index and write
//! mopm.lock, draw the locked graph, or install the lock.
//!
//!   mopm lock   [--registry <prod|gamma|beta|url>]
//!   mopm update [<package>...] [--registry <prod|gamma|beta|url>]
//!   mopm tree
//!   mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--cache <dir>] [--toolchain <file>]
//!
//! All four work in the current directory (mopm.toml and mopm.lock). `lock`
//! keeps every version the existing lock pins while it still fits; `update`
//! drops the pins of the named packages (of all, with no names) and picks the
//! newest versions that fit. Reading the index needs no account. `tree`
//! reads only mopm.toml and mopm.lock. Each index version that is not
//! MAJOR.MINOR.PATCH is ignored with a warning on stderr.
//!
//! `sync` locks first when there is no lock or it no longer matches
//! mopm.toml (as `lock` does), then installs the lock and the Mojo toolchain
//! into `.mopm/env` (see core/install.zig), with no pixi, conda or solver:
//! it downloads each locked file of this machine's subdir and each file of the
//! toolchain's pinned closure for the lock's Mojo (core/closure.zig),
//! refuses one whose size or sha256 differs from its pin, unpacks them all into
//! a temporary directory and renames that into place, and checks what it
//! installed against the lock. With `--locked` it never locks: a missing or
//! out-of-date lock is an error, and the sparse index is not read. Locked
//! files are kept in `.mopm/pkgs`; the toolchain's, which are large and the
//! same for every project, in `--cache` (default `$XDG_CACHE_HOME/mopm/pkgs`,
//! else `~/.cache/mopm/pkgs`). `--toolchain <file>` names another closure file
//! than the built-in one (a mirror, or a test).
//!
//! A path dependency (`name = { path = "..." }`, in [dependencies] or
//! [dev-dependencies], and in a path dependency's own [dependencies]) is
//! read from `<path>/mopm.toml`: it is locked with `source = path` and that
//! file's version, and its own requirements are resolved with the project's.
//! `sync` uses it from its directory and never downloads it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const registry = core.registry;
const manifest = core.manifest;
const resolve = core.resolve;
const lock = core.lock;
const plan = core.install_plan;
const inst = core.install;
const closure = core.closure;
const closure_data = core.closure_data;
const conda_env = core.conda_env;
const pkg_fetch = core.pkg_fetch;

pub const Command = enum { lock, update, tree, sync };

const usage =
    \\usage: mopm lock   [--registry <prod|gamma|beta|url>]
    \\       mopm update [<package>...] [--registry <prod|gamma|beta|url>]
    \\       mopm tree
    \\       mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--cache <dir>] [--toolchain <file>]
    \\
;

const manifest_path = "mopm.toml";
const lock_path = "mopm.lock";

pub const Args = struct {
    registry: []const u8 = "prod",
    packages: []const []const u8 = &.{},
    /// `sync --locked`: install the existing lock or fail; never lock.
    locked: bool = false,
    /// `sync --cache <dir>`: where the toolchain's files are kept.
    cache: ?[]const u8 = null,
    /// `sync --toolchain <file>`: a closure file in place of the built-in one.
    toolchain: ?[]const u8 = null,
};

/// The arguments of `cmd`; null on a usage error.
pub fn parseArgs(arena: Allocator, cmd: Command, args: []const []const u8) Allocator.Error!?Args {
    var out = Args{};
    var names = std.ArrayList([]const u8).init(arena);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (cmd != .tree and std.mem.eql(u8, a, "--registry")) {
            if (i + 1 >= args.len) return null;
            i += 1;
            out.registry = args[i];
        } else if (cmd == .sync and std.mem.eql(u8, a, "--locked")) {
            out.locked = true;
        } else if (cmd == .sync and std.mem.eql(u8, a, "--cache")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return null;
            i += 1;
            out.cache = args[i];
        } else if (cmd == .sync and std.mem.eql(u8, a, "--toolchain")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return null;
            i += 1;
            out.toolchain = args[i];
        } else if (cmd == .update and a.len > 0 and a[0] != '-') {
            try names.append(a);
        } else return null;
    }
    out.packages = names.items;
    return out;
}

fn err(cmd: Command, comptime fmt: []const u8, args: anytype) void {
    const w = std.io.getStdErr().writer();
    w.print("mopm {s}: ", .{@tagName(cmd)}) catch {};
    w.print(fmt, args) catch {};
}

pub fn main(arena: Allocator, cmd: Command, args: []const []const u8, cli_version: []const u8) u8 {
    const parsed = (parseArgs(arena, cmd, args) catch return 1) orelse {
        std.io.getStdErr().writeAll(usage) catch {};
        return 2;
    };
    return run(arena, cmd, parsed, cli_version) catch |e| {
        err(cmd, "{s}\n", .{@errorName(e)});
        return 1;
    };
}

const Project = struct {
    m: manifest.Manifest,
    /// Registry requirements: the project's, and its path dependencies'.
    roots: []const resolve.Root,
    paths: []const plan.PathDep,
    deps: []const []const u8,
    dev_deps: []const []const u8,
};

fn readManifest(arena: Allocator, cmd: Command, path: []const u8) !?manifest.Manifest {
    const src = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s}\n", .{path});
        } else {
            err(cmd, "{s}: {s}\n", .{ path, @errorName(e) });
        }
        return null;
    };
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(arena, src, &diag) catch |e| {
        if (e == error.Invalid) {
            err(cmd, "{s}:{d}:{d}: {s}\n", .{ path, diag.pos.line, diag.pos.col, diag.message });
        } else {
            err(cmd, "{s}: {s}\n", .{ path, @errorName(e) });
        }
        return null;
    };
}

/// `dir` joined with `rel`, `/`-separated, with `.` and `..` resolved
/// (relative stays relative).
fn joinPath(arena: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    const r = try std.mem.replaceOwned(u8, arena, rel, "\\", "/");
    if (std.fs.path.isAbsolutePosix(r) or dir.len == 0) return std.fs.path.resolvePosix(arena, &.{r});
    return std.fs.path.resolvePosix(arena, &.{ dir, r });
}

/// Reads the path dependency `name` at `path` (relative to the project) and,
/// through it, its own dependencies. False when it failed (reported).
fn addPathDep(arena: Allocator, cmd: Command, name: []const u8, path: []const u8, needed_by: []const u8, roots: *std.ArrayList(resolve.Root), paths: *std.ArrayList(plan.PathDep)) anyerror!bool {
    for (paths.items) |q| {
        if (!std.mem.eql(u8, q.name, name)) continue;
        if (std.mem.eql(u8, q.path, path)) return true;
        err(cmd, "{s} is the path dependency {s} and also {s} ({s}); one name, one path\n", .{ name, q.path, path, needed_by });
        return false;
    }
    const file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, manifest_path });
    const m = (try readManifest(arena, cmd, file)) orelse return false;
    if (!std.mem.eql(u8, m.package.name, name)) {
        err(cmd, "{s} names the package {s}, but {s} calls it {s}\n", .{ file, m.package.name, needed_by, name });
        return false;
    }
    const at = paths.items.len;
    try paths.append(.{ .name = name, .version = m.package.version, .path = path });
    var names = std.ArrayList([]const u8).init(arena);
    for (m.dependencies) |d| {
        try names.append(d.name);
        switch (d.source) {
            .version => |req| try roots.append(.{ .name = d.name, .requirement = req, .from = file }),
            .path => |p| if (!try addPathDep(arena, cmd, d.name, try joinPath(arena, path, p), file, roots, paths)) return false,
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    paths.items[at].deps = names.items;
    return true;
}

fn readProject(arena: Allocator, cmd: Command) !?Project {
    std.fs.cwd().access(manifest_path, .{}) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s} in this directory\n", .{manifest_path});
            return null;
        }
    };
    const m = (try readManifest(arena, cmd, manifest_path)) orelse return null;
    var roots = std.ArrayList(resolve.Root).init(arena);
    var paths = std.ArrayList(plan.PathDep).init(arena);
    var lists = [2]std.ArrayList([]const u8){ std.ArrayList([]const u8).init(arena), std.ArrayList([]const u8).init(arena) };
    for ([_][]const manifest.Dep{ m.dependencies, m.dev_dependencies }, 0..) |group, g| {
        for (group) |d| {
            switch (d.source) {
                .version => |req| {
                    try roots.append(.{ .name = d.name, .requirement = req });
                    try lists[g].append(d.name);
                },
                .path => |p| {
                    if (!try addPathDep(arena, cmd, d.name, try joinPath(arena, "", p), manifest_path, &roots, &paths)) return null;
                    try lists[g].append(d.name);
                },
            }
        }
    }
    return .{ .m = m, .roots = roots.items, .paths = paths.items, .deps = lists[0].items, .dev_deps = lists[1].items };
}

/// The existing lock, null when there is none, or error.Invalid (reported).
fn readLock(arena: Allocator, cmd: Command) !?lock.Lock {
    const text = std.fs.cwd().readFileAlloc(arena, lock_path, 64 << 20) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    var why: []const u8 = "";
    return lock.parse(arena, text, &why) catch |e| {
        if (e == error.Invalid) err(cmd, "{s}: {s}\n", .{ lock_path, why });
        return e;
    };
}

/// Reads the sparse index of a registry, anonymously.
const IndexSource = struct {
    config: registry.Config,

    pub fn fetch(self: IndexSource, arena: Allocator, name: []const u8, diag: *resolve.Diagnostic) resolve.Error!?[]const u8 {
        const url = try registry.indexUrl(arena, self.config, name);
        const answer = http.request(arena, .GET, url, .{}) catch |e| {
            return resolve.fail(arena, diag, .unreachable_index, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (answer.status == 404) return null;
        if (!answer.ok()) {
            const why = try http.describe(arena, answer);
            return resolve.fail(arena, diag, .unreachable_index, "{s} answered HTTP {d}: {s}", .{ url, answer.status, std.mem.trimRight(u8, why, "\n") });
        }
        return answer.body;
    }
};

/// Reads `<channel><subdir>/repodata.json`.
const ChannelSource = struct {
    channel_url: []const u8,

    pub fn fetch(self: ChannelSource, arena: Allocator, subdir: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}/repodata.json", .{ self.channel_url, subdir });
        const answer = http.request(arena, .GET, url, .{}) catch |e| {
            return resolve.fail(arena, diag, .bad_channel, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (!answer.ok()) return resolve.fail(arena, diag, .bad_channel, "{s} answered HTTP {d}", .{ url, answer.status });
        return answer.body;
    }
};

fn run(arena: Allocator, cmd: Command, args: Args, cli_version: []const u8) !u8 {
    const project = (try readProject(arena, cmd)) orelse return 1;
    const old = readLock(arena, cmd) catch |e| {
        if (e == error.Invalid) return 1;
        return e;
    };
    if (cmd == .tree) return tree(arena, project, old);

    if (project.m.mojo.len == 0) {
        err(cmd, "{s} has no [toolchain] mojo; a lock pins the one compiler every package is built with\n", .{manifest_path});
        return 1;
    }
    if (cmd == .sync) return sync(arena, project, old, args, cli_version);
    for (args.packages) |name| {
        const known = (old != null and old.?.versionOf(name) != null);
        if (!known) {
            err(cmd, "{s} is not in {s}\n", .{ name, lock_path });
            return 1;
        }
    }
    return if ((try lockProject(arena, cmd, project, old, args, cli_version)) == null) 1 else 0;
}

/// Resolves the project, writes mopm.lock and prints what changed. Null when
/// it failed (already reported).
fn lockProject(arena: Allocator, cmd: Command, project: Project, old: ?lock.Lock, args: Args, cli_version: []const u8) !?lock.Lock {
    const toolchains = project.m.mojo;
    const base = switch (registry.resolve(args.registry)) {
        .ok => |b| b,
        .bad => |why| {
            err(cmd, "--registry {s}: {s}\n", .{ args.registry, why });
            return null;
        },
    };
    const config = switch (try registry.load(arena, base, cli_version)) {
        .ok => |c| c,
        .bad => |why| {
            err(cmd, "{s}: {s}\n", .{ base, why });
            return null;
        },
    };

    var failures = std.ArrayList(u8).init(arena);
    var warnings = std.ArrayList([]const u8).init(arena);
    defer printWarnings(cmd, warnings.items);
    for (toolchains) |mojo| {
        var pins = std.ArrayList(resolve.Pin).init(arena);
        if (old) |o| {
            const update_all = cmd == .update and args.packages.len == 0;
            if (std.mem.eql(u8, o.mojo, mojo) and !update_all) {
                for (o.packages) |p| {
                    if (p.source == .path) continue;
                    var named = false;
                    for (args.packages) |n| named = named or std.mem.eql(u8, n, p.name);
                    if (!named) try pins.append(.{ .name = p.name, .version = p.version });
                }
            }
        }
        var diag: resolve.Diagnostic = .{};
        const res = resolve.resolve(arena, IndexSource{ .config = config }, .{ .mojo = mojo, .roots = project.roots, .pins = pins.items, .warnings = &warnings }, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            try failures.writer().print("  with mojo {s}: {s}\n", .{ mojo, diag.message });
            continue;
        };
        const from_registry = plan.buildLock(arena, res, config.channel_url, ChannelSource{ .channel_url = config.channel_url }, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        const new = plan.addPaths(arena, from_registry, project.paths, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        const text = try lock.render(arena, new);
        try std.fs.cwd().writeFile(lock_path, text);
        const out = std.io.getStdOut().writer();
        try plan.writeChanges(old, new, out);
        try out.print("locked {d} packages for mojo {s}\n", .{ res.packages.len + project.paths.len, mojo });
        return new;
    }
    err(cmd, "cannot resolve the dependencies of {s}:\n{s}", .{ project.m.package.name, failures.items });
    return null;
}

/// `mopm sync`: lock when needed (never with `--locked`), then install.
fn sync(arena: Allocator, project: Project, old: ?lock.Lock, args: Args, cli_version: []const u8) !u8 {
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
        break :blk (try lockProject(arena, .sync, project, old, args, cli_version)) orelse return 1;
    } else old.?;
    return install(arena, l, args);
}

/// `--cache`, else `$XDG_CACHE_HOME/mopm/pkgs`, else `$HOME/.cache/mopm/pkgs`.
fn cacheDir(arena: Allocator, flag: ?[]const u8) ![]const u8 {
    if (flag) |f| return f;
    if (std.process.getEnvVarOwned(arena, "XDG_CACHE_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(arena, &.{ x, "mopm", "pkgs" });
    } else |_| {}
    const home = std.process.getEnvVarOwned(arena, "HOME") catch return error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".cache", "mopm", "pkgs" });
}

/// The toolchain closure of `mojo` on `subdir`: the `--toolchain` file, else
/// the built-in one. Null when there is none (reported).
fn loadToolchain(arena: Allocator, mojo: []const u8, subdir: []const u8, override: ?[]const u8) !?closure.Closure {
    if (override) |path| {
        const text = std.fs.cwd().readFileAlloc(arena, path, 16 << 20) catch |e| {
            err(.sync, "--toolchain {s}: {s}\n", .{ path, @errorName(e) });
            return null;
        };
        const c = closure.parse(arena, text) catch |e| {
            if (e == error.OutOfMemory) return e;
            err(.sync, "--toolchain {s}: not a closure file: {s}\n", .{ path, @errorName(e) });
            return null;
        };
        if (try closure.problem(arena, c)) |why| {
            err(.sync, "--toolchain {s}: {s}\n", .{ path, why });
            return null;
        }
        if (!std.mem.eql(u8, c.mojo, mojo) or !std.mem.eql(u8, c.subdir, subdir)) {
            err(.sync, "--toolchain {s} is for mojo {s} on {s}, but this project needs mojo {s} on {s}\n", .{ path, c.mojo, c.subdir, mojo, subdir });
            return null;
        }
        return c;
    }
    if (try closure_data.find(arena, mojo, subdir)) |c| return c;
    err(.sync, "this mopm has no pinned toolchain for mojo {s} on {s} (it has: {s}); change [toolchain] mojo in {s} and run 'mopm lock'\n", .{ mojo, subdir, try closure_data.versions(arena), manifest_path });
    return null;
}

/// Makes `cache/<item.file_name>` the item's pinned bytes, downloading it if
/// need be. False when it failed (reported).
fn fetchItem(arena: Allocator, cache: std.fs.Dir, item: inst.Item) !bool {
    const pin = pkg_fetch.Pin{ .sha256 = item.sha256, .size = item.size };
    if (!(try pkg_fetch.matches(cache, item.file_name, pin))) {
        try std.io.getStdOut().writer().print("downloading {s} ({d} bytes)\n", .{ item.file_name, item.size });
    }
    var diag = pkg_fetch.Diag{};
    pkg_fetch.fetch(arena, cache, item.file_name, item.url, pin, &diag) catch |e| switch (e) {
        error.DownloadFailed, error.BadStatus, error.SizeMismatch, error.HashMismatch => {
            err(.sync, "{s}\n", .{diag.message});
            return false;
        },
        else => return e,
    };
    return true;
}

/// Installs `l` and its Mojo toolchain into `.mopm/env` (see
/// core/install.zig); 0 when the environment is exactly the lock.
fn install(arena: Allocator, l: lock.Lock, args: Args) !u8 {
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
    const tc = (try loadToolchain(arena, l.mojo, subdir, args.toolchain)) orelse return 1;
    const items = switch (try inst.planInstall(arena, pkgs, tc)) {
        .ok => |i| i,
        .bad => |why| {
            err(.sync, "{s}\n", .{why});
            return 1;
        },
    };
    const stamp = try inst.stampOf(arena, items);

    try cwd.makePath(inst.dir);
    var parent = try cwd.openDir(inst.dir, .{});
    defer parent.close();
    const out = std.io.getStdOut().writer();

    const have = conda_env.readStamp(arena, parent, inst.env_name);
    if (have != null and std.mem.eql(u8, have.?, stamp)) {
        try out.print("the environment {s} is current (mojo {s})\n", .{ inst.prefix, l.mojo });
    } else {
        // The toolchain's files are shared by every project: the user's cache.
        // The locked packages are this project's: .mopm/pkgs.
        const cache_path = try cacheDir(arena, args.cache);
        var cache = try cwd.makeOpenPath(cache_path, .{});
        defer cache.close();
        try parent.makePath("pkgs");
        var project_pkgs = try parent.openDir("pkgs", .{});
        defer project_pkgs.close();

        var files = std.ArrayList(conda_env.Pkg).init(arena);
        for (items) |item| {
            const into = if (item.locked) project_pkgs else cache;
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
        const prefix_abs = try std.fs.path.join(arena, &.{ try parent.realpathAlloc(arena, "."), inst.env_name });
        var diag = conda_env.Diag{};
        _ = conda_env.installEnv(arena, parent, inst.env_name, prefix_abs, files.items, stamp, &diag) catch |e| {
            err(.sync, "installing into {s}: {s}\n", .{ inst.prefix, if (diag.message.len > 0) diag.message else @errorName(e) });
            return 1;
        };
    }

    var env = cwd.openDir(inst.prefix, .{}) catch |e| {
        err(.sync, "no environment at {s}: {s}\n", .{ inst.prefix, @errorName(e) });
        return 1;
    };
    defer env.close();
    if (try inst.checkInstalled(arena, env, pkgs)) |why| {
        err(.sync, "{s}\n", .{why});
        return 1;
    }
    for (l.packages) |p| {
        if (p.source == .path) try out.print("using {s} {s} from {s} (a path dependency: built from source, not downloaded)\n", .{ p.name, p.version, p.path });
    }
    try out.print("installed {d} packages for {s} (mojo {s}, {d} toolchain files) into {s}\n", .{ pkgs.len, subdir, l.mojo, tc.packages.len, inst.prefix });
    return 0;
}

/// Each warning once, in the order first given (a second toolchain reads
/// the same index again).
fn printWarnings(cmd: Command, warnings: []const []const u8) void {
    for (warnings, 0..) |w, i| {
        var seen = false;
        for (warnings[0..i]) |x| seen = seen or std.mem.eql(u8, x, w);
        if (!seen) err(cmd, "warning: {s}\n", .{w});
    }
}

fn tree(arena: Allocator, project: Project, l: ?lock.Lock) !u8 {
    const locked = l orelse {
        err(.tree, "no {s}; run 'mopm lock'\n", .{lock_path});
        return 1;
    };
    for ([_][]const []const u8{ project.deps, project.dev_deps }) |names| {
        if (plan.missing(locked, names)) |name| {
            err(.tree, "{s} does not lock {s}; run 'mopm lock'\n", .{ lock_path, name });
            return 1;
        }
    }
    var buf = std.ArrayList(u8).init(arena);
    try plan.writeTree(arena, project.m.package.name, project.m.package.version, project.deps, project.dev_deps, locked, buf.writer());
    try std.io.getStdOut().writeAll(buf.items);
    return 0;
}

test "lock, update and tree arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("prod", (try parseArgs(a, .lock, &.{})).?.registry);
    try std.testing.expectEqualStrings("beta", (try parseArgs(a, .lock, &.{ "--registry", "beta" })).?.registry);
    try std.testing.expect((try parseArgs(a, .lock, &.{"tls"})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{"--registry"})) == null);
    const u = (try parseArgs(a, .update, &.{ "tls", "--registry", "beta", "http_core" })).?;
    try std.testing.expectEqual(@as(usize, 2), u.packages.len);
    try std.testing.expectEqualStrings("http_core", u.packages[1]);
    try std.testing.expect((try parseArgs(a, .tree, &.{ "--registry", "beta" })) == null);
    try std.testing.expect((try parseArgs(a, .update, &.{"--frobnicate"})) == null);

    const s = (try parseArgs(a, .sync, &.{ "--locked", "--cache", "/opt/cache", "--toolchain", "tc.json", "--registry", "beta" })).?;
    try std.testing.expect(s.locked);
    try std.testing.expectEqualStrings("/opt/cache", s.cache.?);
    try std.testing.expectEqualStrings("tc.json", s.toolchain.?);
    try std.testing.expectEqualStrings("beta", s.registry);
    const d = (try parseArgs(a, .sync, &.{})).?;
    try std.testing.expect(!d.locked);
    try std.testing.expect(d.cache == null and d.toolchain == null);
    try std.testing.expect((try parseArgs(a, .sync, &.{"--cache"})) == null);
    // pixi is not used, so there is no flag for one.
    try std.testing.expect((try parseArgs(a, .sync, &.{ "--pixi", "/opt/pixi" })) == null);
    try std.testing.expect((try parseArgs(a, .sync, &.{"tls"})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{"--locked"})) == null);
}

test "path dependency directories are joined relative to the project" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("local", try joinPath(a, "", "./local/"));
    try std.testing.expectEqualStrings("../shared", try joinPath(a, "", "../shared"));
    try std.testing.expectEqualStrings("util", try joinPath(a, "local", "../util"));
    try std.testing.expectEqualStrings("local/sub", try joinPath(a, "local", "sub"));
    try std.testing.expectEqualStrings("../util", try joinPath(a, "local", "../../util"));
    try std.testing.expectEqualStrings("/opt/pkg", try joinPath(a, "local", "/opt/pkg"));
}
