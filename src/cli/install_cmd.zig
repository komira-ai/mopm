//! `mopm lock`, `mopm update`, `mopm tree` and `mopm sync`: resolve the
//! project's dependencies against a registry's sparse index and write
//! mopm.lock, draw the locked graph, or install the lock.
//!
//!   mopm lock   [--registry <prod|gamma|beta|url>]
//!   mopm update [<package>...] [--registry <prod|gamma|beta|url>]
//!   mopm tree
//!   mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--pixi <path>]
//!
//! All four work in the current directory (mopm.toml and mopm.lock). `lock`
//! keeps every version the existing lock pins while it still fits; `update`
//! drops the pins of the named packages (of all, with no names) and picks the
//! newest versions that fit. Reading the index needs no account. `tree`
//! reads only mopm.toml and mopm.lock. Each index version that is not
//! MAJOR.MINOR.PATCH is ignored with a warning on stderr.
//!
//! `sync` locks first when there is no lock or it no longer matches
//! mopm.toml (as `lock` does), then installs the lock into `.mopm/` (see
//! core/install.zig): it downloads each locked file of this machine's
//! subdir, refuses one whose size or sha256 differs from the lock, writes the
//! internal pixi project, runs `pixi install` (the `pixi` on PATH, or
//! `--pixi`), and checks what pixi installed against the lock. With
//! `--locked` it never locks: a missing or out-of-date lock is an error, and
//! the sparse index is not read.

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

pub const Command = enum { lock, update, tree, sync };

const usage =
    \\usage: mopm lock   [--registry <prod|gamma|beta|url>]
    \\       mopm update [<package>...] [--registry <prod|gamma|beta|url>]
    \\       mopm tree
    \\       mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--pixi <path>]
    \\
;

const manifest_path = "mopm.toml";
const lock_path = "mopm.lock";

pub const Args = struct {
    registry: []const u8 = "prod",
    packages: []const []const u8 = &.{},
    /// `sync --locked`: install the existing lock or fail; never lock.
    locked: bool = false,
    /// `sync --pixi <path>`: the pixi to run.
    pixi: []const u8 = "pixi",
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
        } else if (cmd == .sync and std.mem.eql(u8, a, "--pixi")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return null;
            i += 1;
            out.pixi = args[i];
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
    roots: []const resolve.Root,
    deps: []const []const u8,
    dev_deps: []const []const u8,
};

fn readProject(arena: Allocator, cmd: Command) !?Project {
    const src = std.fs.cwd().readFileAlloc(arena, manifest_path, 1 << 20) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s} in this directory\n", .{manifest_path});
        } else {
            err(cmd, "{s}: {s}\n", .{ manifest_path, @errorName(e) });
        }
        return null;
    };
    var diag: manifest.Diagnostic = .{};
    const m = manifest.parse(arena, src, &diag) catch |e| {
        if (e == error.Invalid) {
            err(cmd, "{s}:{d}:{d}: {s}\n", .{ manifest_path, diag.pos.line, diag.pos.col, diag.message });
        } else {
            err(cmd, "{s}: {s}\n", .{ manifest_path, @errorName(e) });
        }
        return null;
    };
    var roots = std.ArrayList(resolve.Root).init(arena);
    var lists = [2]std.ArrayList([]const u8){ std.ArrayList([]const u8).init(arena), std.ArrayList([]const u8).init(arena) };
    for ([_][]const manifest.Dep{ m.dependencies, m.dev_dependencies }, 0..) |group, g| {
        for (group) |d| {
            switch (d.source) {
                .version => |req| {
                    try roots.append(.{ .name = d.name, .requirement = req });
                    try lists[g].append(d.name);
                },
                .path => |p| err(cmd, "note: {s} is a path dependency ({s}); it is not locked\n", .{ d.name, p }),
            }
        }
    }
    return .{ .m = m, .roots = roots.items, .deps = lists[0].items, .dev_deps = lists[1].items };
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
        const new = plan.buildLock(arena, res, config.channel_url, ChannelSource{ .channel_url = config.channel_url }, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        const text = try lock.render(arena, new);
        try std.fs.cwd().writeFile(lock_path, text);
        const out = std.io.getStdOut().writer();
        try plan.writeChanges(old, new, out);
        try out.print("locked {d} packages for mojo {s}\n", .{ res.packages.len, mojo });
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
        if (try inst.staleness(arena, project.m.mojo, project.roots, o)) |why| {
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
    return install(arena, l, args.pixi);
}

/// The largest package file mopm downloads (the HTTP client's limit).
const max_file = 64 << 20;

/// An anonymous GET; null when the request failed (reported).
fn httpGet(arena: Allocator, url: []const u8) ?http.Answer {
    return http.request(arena, .GET, url, .{}) catch |e| {
        err(.sync, "cannot read {s}: {s}\n", .{ url, @errorName(e) });
        return null;
    };
}

/// Installs `l` into `.mopm/` (see core/install.zig); 0 when the environment
/// is exactly the lock.
fn install(arena: Allocator, l: lock.Lock, pixi: []const u8) !u8 {
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

    var repodata = std.StringHashMap([]const u8).init(arena);
    var files = std.ArrayList(inst.LocalFile).init(arena);
    for (pkgs) |p| {
        const where = try std.fmt.allocPrint(arena, "{s}{s}/repodata.json", .{ p.channel, p.subdir });
        const text = repodata.get(where) orelse blk: {
            const answer = httpGet(arena, where) orelse return 1;
            if (!answer.ok()) {
                err(.sync, "{s} answered HTTP {d}\n", .{ where, answer.status });
                return 1;
            }
            try repodata.put(where, answer.body);
            break :blk answer.body;
        };
        const depends = switch (try inst.lookUp(arena, text, p)) {
            .ok => |d| d orelse blk: {
                err(.sync, "warning: {s} {s} is yanked (the channel lists it as removed); it installs because {s} pins it\n", .{ p.name, p.version, lock_path });
                break :blk try inst.dependsFromLock(arena, p);
            },
            .bad => |why| {
                err(.sync, "{s}\n", .{why});
                return 1;
            },
        };

        // A file kept from an earlier sync is used only if it is still the
        // pinned bytes; otherwise it is downloaded again.
        const local = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ inst.channel_dir, p.subdir, try inst.fileName(arena, p) });
        const kept: ?[]const u8 = cwd.readFileAlloc(arena, local, max_file) catch null;
        const reuse = if (kept) |b| (try inst.checkBytes(arena, p, b)) == null else false;
        if (!reuse) {
            const answer = httpGet(arena, p.url) orelse return 1;
            switch (answer.status) {
                403, 404, 410 => {
                    err(.sync, "{s} answered HTTP {d}: {s} {s} has been taken down or is unavailable\n", .{ p.url, answer.status, p.name, p.version });
                    return 1;
                },
                else => {},
            }
            if (!answer.ok()) {
                err(.sync, "{s} answered HTTP {d}\n", .{ p.url, answer.status });
                return 1;
            }
            if (try inst.checkBytes(arena, p, answer.body)) |why| {
                err(.sync, "{s} (downloaded from {s})\n", .{ why, p.url });
                return 1;
            }
            try cwd.makePath(std.fs.path.dirname(local).?);
            try cwd.writeFile(local, answer.body);
        }
        try files.append(.{ .pkg = p, .depends = depends });
    }

    for ([_][]const u8{ subdir, "noarch" }) |s| {
        const d = try std.fmt.allocPrint(arena, "{s}/{s}", .{ inst.channel_dir, s });
        try cwd.makePath(d);
        try cwd.writeFile(try std.fmt.allocPrint(arena, "{s}/repodata.json", .{d}), try inst.localRepodata(arena, s, files.items));
    }
    const channel = try inst.fileUrl(arena, try cwd.realpathAlloc(arena, inst.channel_dir));
    try cwd.writeFile(inst.pixi_manifest, try inst.pixiToml(arena, channel, subdir, l.mojo, pkgs));

    var child = std.ChildProcess.init(&.{ pixi, "install", "--manifest-path", inst.pixi_manifest }, arena);
    const term = child.spawnAndWait() catch |e| {
        err(.sync, "cannot run {s}: {s}; pass --pixi <path to pixi>\n", .{ pixi, @errorName(e) });
        return 1;
    };
    const exited_ok = switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!exited_ok) {
        err(.sync, "{s} install --manifest-path {s} failed\n", .{ pixi, inst.pixi_manifest });
        return 1;
    }

    var env = cwd.openDir(inst.prefix, .{}) catch |e| {
        err(.sync, "pixi made no environment at {s}: {s}\n", .{ inst.prefix, @errorName(e) });
        return 1;
    };
    defer env.close();
    if (try inst.checkInstalled(arena, env, pkgs)) |why| {
        err(.sync, "{s}\n", .{why});
        return 1;
    }
    try std.io.getStdOut().writer().print("installed {d} packages for {s} (mojo {s}) into {s}\n", .{ pkgs.len, subdir, l.mojo, inst.prefix });
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

    const s = (try parseArgs(a, .sync, &.{ "--locked", "--pixi", "/opt/pixi", "--registry", "beta" })).?;
    try std.testing.expect(s.locked);
    try std.testing.expectEqualStrings("/opt/pixi", s.pixi);
    try std.testing.expectEqualStrings("beta", s.registry);
    const d = (try parseArgs(a, .sync, &.{})).?;
    try std.testing.expect(!d.locked);
    try std.testing.expectEqualStrings("pixi", d.pixi);
    try std.testing.expect((try parseArgs(a, .sync, &.{"--pixi"})) == null);
    try std.testing.expect((try parseArgs(a, .sync, &.{"tls"})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{"--locked"})) == null);
}
