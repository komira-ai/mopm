//! `mopm lock`, `mopm update` and `mopm tree`: resolve the project's
//! dependencies against a registry's sparse index and write mopm.lock, or
//! draw the locked graph.
//!
//!   mopm lock   [--registry <prod|gamma|beta|url>]
//!   mopm update [<package>...] [--registry <prod|gamma|beta|url>]
//!   mopm tree
//!
//! All three work in the current directory (mopm.toml and mopm.lock). `lock`
//! keeps every version the existing lock pins while it still fits; `update`
//! drops the pins of the named packages (of all, with no names) and picks the
//! newest versions that fit. Reading the index needs no account. `tree`
//! reads only mopm.toml and mopm.lock. Each index version that is not
//! MAJOR.MINOR.PATCH is ignored with a warning on stderr.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const registry = core.registry;
const manifest = core.manifest;
const resolve = core.resolve;
const lock = core.lock;
const plan = core.install_plan;

pub const Command = enum { lock, update, tree };

const usage =
    \\usage: mopm lock   [--registry <prod|gamma|beta|url>]
    \\       mopm update [<package>...] [--registry <prod|gamma|beta|url>]
    \\       mopm tree
    \\
;

const manifest_path = "mopm.toml";
const lock_path = "mopm.lock";

pub const Args = struct {
    registry: []const u8 = "prod",
    packages: []const []const u8 = &.{},
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

    const toolchains = project.m.mojo;
    if (toolchains.len == 0) {
        err(cmd, "{s} has no [toolchain] mojo; a lock pins the one compiler every package is built with\n", .{manifest_path});
        return 1;
    }
    for (args.packages) |name| {
        const known = (old != null and old.?.versionOf(name) != null);
        if (!known) {
            err(cmd, "{s} is not in {s}\n", .{ name, lock_path });
            return 1;
        }
    }

    const base = switch (registry.resolve(args.registry)) {
        .ok => |b| b,
        .bad => |why| {
            err(cmd, "--registry {s}: {s}\n", .{ args.registry, why });
            return 1;
        },
    };
    const config = switch (try registry.load(arena, base, cli_version)) {
        .ok => |c| c,
        .bad => |why| {
            err(cmd, "{s}: {s}\n", .{ base, why });
            return 1;
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
            return 1;
        };
        const text = try lock.render(arena, new);
        try std.fs.cwd().writeFile(lock_path, text);
        const out = std.io.getStdOut().writer();
        try plan.writeChanges(old, new, out);
        try out.print("locked {d} packages for mojo {s}\n", .{ res.packages.len, mojo });
        return 0;
    }
    err(cmd, "cannot resolve the dependencies of {s}:\n{s}", .{ project.m.package.name, failures.items });
    return 1;
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
}
