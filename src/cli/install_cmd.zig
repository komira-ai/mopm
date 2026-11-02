//! `mopm lock`, `mopm update`, `mopm tree`, `mopm sync`, `mopm add` and
//! `mopm remove`: resolve the project's dependencies against a registry's
//! sparse index and write mopm.lock, draw the locked graph, install the lock,
//! or change one dependency of mopm.toml and lock again.
//!
//!   mopm lock   [--registry <prod|gamma|beta|url>]
//!   mopm update [<package>...] [--registry <prod|gamma|beta|url>]
//!   mopm tree
//!   mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--cache <dir>] [--toolchain <file>]
//!   mopm add    <package>[@<requirement>] [--dev] [--path <dir>] [--registry ...]
//!   mopm remove <package> [--dev] [--registry ...]
//!
//! All of them work in the current directory (mopm.toml and mopm.lock). `lock`
//! keeps every version the existing lock pins while it still fits; `update`
//! drops the pins of the named packages (of all, with no names) and picks the
//! newest versions that fit. Reading the index needs no account. `tree`
//! reads only mopm.toml and mopm.lock. Each index version that is not
//! MAJOR.MINOR.PATCH is ignored with a warning on stderr.
//!
//! `sync` locks first when there is no lock or it no longer matches
//! mopm.toml (as `lock` does), then installs the lock and the Mojo toolchain
//! into `.mopm/env` (see core/install.zig), with no pixi, conda or solver: it
//! downloads each locked file of this machine's subdir and each file of the
//! pinned toolchain closure of the lock's Mojo (core/closure.zig), refuses one
//! whose size or sha256 is not its pin, unpacks them all into a temporary
//! directory beside `.mopm/env` and renames that into place (on any failure
//! the old environment stays), and checks what it installed against the lock.
//! Locked files are kept in `.mopm/pkgs`; the toolchain's, which are large and
//! the same for every project, in `--cache` (default `$XDG_CACHE_HOME/mopm/pkgs`,
//! else `~/.cache/mopm/pkgs`). The environment records a stamp of what it
//! holds: a sync whose files have the same stamp downloads nothing.
//! `--toolchain <file>` names another closure file than the built-in one (a
//! mirror: the same pins, other channel urls; or a test). With `--locked` it
//! never locks: a missing or out-of-date lock is an error, and the sparse index
//! is not read.
//!
//! `--overlay <dir>` (`add`, `lock`, `sync`) reads a staged set (core/overlay.zig) as a read-only local channel
//! ahead of the registry: a package the set holds is resolved and locked from the set, one it lacks from the
//! registry, and a closure the set holds entirely needs no request for its index files, repodata or packages (the
//! production registry's channel is known; any other registry is asked for its index/config.json, once, for the
//! channel the lock names). The set is never written, and nothing about it reaches mopm.lock or mopm.toml: the lock
//! names the registry's channel and file URLs with the files' sha256, so it is the lock the registry gives once the
//! versions are published. When the registry is asked anyway, a staged version it already holds with other bytes is
//! refused. `sync` installs a locked file from the set when the set holds exactly the bytes the lock pins.
//!
//! A path dependency (`name = { path = "..." }`, in [dependencies] or
//! [dev-dependencies], and in a path dependency's own [dependencies]) is
//! read from `<path>/mopm.toml`: it is locked with `source = path` and that
//! file's version, and its own requirements are resolved with the project's.
//! `sync` uses it from its directory and never downloads it.
//!
//! `add` sets `<package>` in [dependencies] (with `--dev`, in
//! [dev-dependencies]) and `remove` takes it out, through core/toml_edit.zig,
//! so every other byte of mopm.toml (comments, order, spacing) stays as it
//! was. Without a requirement, `add` resolves with `*` and writes a caret
//! requirement on the version picked (`^X.Y.Z`, as cargo does); with `--path`
//! it writes `{ path = "<dir>" }`. Either command resolves the edited
//! manifest first, then writes mopm.toml and mopm.lock; when resolution
//! fails, neither file is written. The package added is resolved afresh (the
//! lock's pin on it, if any, is dropped); the others keep their pins, and a
//! package that only the removed one needed leaves the lock.

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
const overlay = core.overlay;
const semver = core.semver;
const toml_edit = core.toml_edit;
const unit_graph = core.unit_graph;
const system_libs = core.system_libs;
const closure = core.closure;
const conda_env = core.conda_env;
const pkg_fetch = core.pkg_fetch;
const publish_cmd = @import("publish_cmd.zig");

/// The command whose name prefixes a message. `plan` and `build` only read the project (`readProject`).
pub const Command = enum { lock, update, tree, sync, add, remove, plan, build };

const usage =
    \\usage: mopm lock   [--registry <prod|gamma|beta|url>] [--overlay <staged set>]
    \\       mopm update [<package>...] [--registry <prod|gamma|beta|url>]
    \\       mopm tree
    \\       mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--overlay <staged set>] [--cache <dir>] [--toolchain <file>]
    \\       mopm add    <package>[@<requirement>] [--dev] [--path <dir>] [--registry <prod|gamma|beta|url>] [--overlay <staged set>]
    \\       mopm remove <package> [--dev] [--registry <prod|gamma|beta|url>]
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
    /// `sync --toolchain <file>`: a toolchain closure file in place of the built-in one.
    toolchain: ?[]const u8 = null,
    /// `add` and `remove`: the package, `add` with an optional `@<requirement>`.
    spec: []const u8 = "",
    /// `add --dev`, `remove --dev`: [dev-dependencies] instead of [dependencies].
    dev: bool = false,
    /// `add --path <dir>`: a path dependency.
    path: ?[]const u8 = null,
    /// `--overlay <dir>` (`add`, `lock`, `sync`): a staged set, read as a local channel ahead of the registry.
    overlay: ?[]const u8 = null,
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
        } else if ((cmd == .add or cmd == .lock or cmd == .sync) and std.mem.eql(u8, a, "--overlay")) {
            if (i + 1 >= args.len or args[i + 1].len == 0 or out.overlay != null) return null;
            i += 1;
            out.overlay = args[i];
        } else if (cmd == .sync and std.mem.eql(u8, a, "--locked")) {
            out.locked = true;
        } else if (cmd == .sync and std.mem.eql(u8, a, "--cache")) {
            if (i + 1 >= args.len or args[i + 1].len == 0 or out.cache != null) return null;
            i += 1;
            out.cache = args[i];
        } else if (cmd == .sync and std.mem.eql(u8, a, "--toolchain")) {
            if (i + 1 >= args.len or args[i + 1].len == 0 or out.toolchain != null) return null;
            i += 1;
            out.toolchain = args[i];
        } else if (cmd == .update and a.len > 0 and a[0] != '-') {
            try names.append(a);
        } else if ((cmd == .add or cmd == .remove) and std.mem.eql(u8, a, "--dev")) {
            out.dev = true;
        } else if (cmd == .add and std.mem.eql(u8, a, "--path")) {
            if (i + 1 >= args.len or args[i + 1].len == 0 or out.path != null) return null;
            i += 1;
            out.path = args[i];
        } else if ((cmd == .add or cmd == .remove) and a.len > 0 and a[0] != '-' and out.spec.len == 0) {
            out.spec = a;
        } else return null;
    }
    out.packages = names.items;
    if (cmd == .add or cmd == .remove) {
        if (out.spec.len == 0) return null;
        const at = std.mem.indexOfScalar(u8, out.spec, '@');
        // `remove` takes a name only; a path dependency has no requirement.
        if (at != null and (cmd == .remove or out.path != null)) return null;
    }
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

pub const Project = struct {
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
    return parseManifest(arena, cmd, path, src);
}

/// `src`, the text of `path`, checked as a manifest; null when it is not
/// one (reported).
fn parseManifest(arena: Allocator, cmd: Command, path: []const u8, src: []const u8) !?manifest.Manifest {
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
    try paths.append(.{ .name = name, .version = m.package.version, .path = path, .native_deps = m.native_dependencies });
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

pub fn readProject(arena: Allocator, cmd: Command) !?Project {
    std.fs.cwd().access(manifest_path, .{}) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s} in this directory\n", .{manifest_path});
            return null;
        }
    };
    const m = (try readManifest(arena, cmd, manifest_path)) orelse return null;
    return projectOf(arena, cmd, m);
}

/// The project `m` describes, with its path dependencies read; null when
/// one of them cannot be (reported).
fn projectOf(arena: Allocator, cmd: Command, m: manifest.Manifest) !?Project {
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
pub fn readLock(arena: Allocator, cmd: Command) !?lock.Lock {
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
    /// The most a package file may be: what `mopm publish` sends (the registry's 100 MB), no more.
    max_conda: usize = publish_cmd.max_file_bytes,

    pub fn fetch(self: ChannelSource, arena: Allocator, subdir: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}/repodata.json", .{ self.channel_url, subdir });
        const answer = http.request(arena, .GET, url, .{}) catch |e| {
            return resolve.fail(arena, diag, .bad_channel, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (!answer.ok()) return resolve.fail(arena, diag, .bad_channel, "{s} answered HTTP {d}", .{ url, answer.status });
        return answer.body;
    }

    /// Reads `<channel><subdir>/<filename>`: a package file, for the natives `mopm lock` hashes. The body is held
    /// in memory, up to `max_conda` bytes; a longer one is refused as too large.
    pub fn fetchConda(self: ChannelSource, arena: Allocator, subdir: []const u8, filename: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ self.channel_url, subdir, filename });
        const answer = http.request(arena, .GET, url, .{ .max_body = self.max_conda }) catch |e| {
            if (e == error.StreamTooLong) return resolve.fail(arena, diag, .bad_channel, "{s} is larger than {d} bytes, the most a package file may be", .{ url, self.max_conda });
            return resolve.fail(arena, diag, .bad_channel, "cannot read {s}: {s}", .{ url, @errorName(e) });
        };
        if (!answer.ok()) return resolve.fail(arena, diag, .bad_channel, "{s} answered HTTP {d}", .{ url, answer.status });
        return answer.body;
    }
};

/// The registry a command talks to: its base URL and its configuration (`index/config.json`), which is read up front,
/// or, with a staged set, the first time something needs it: a closure the set holds needs no registry request.
const Registry = struct {
    base: []const u8,
    cli_version: []const u8,
    config: ?registry.Config = null,

    fn get(self: *Registry, arena: Allocator, diag: *resolve.Diagnostic) resolve.Error!registry.Config {
        if (self.config) |c| return c;
        const parsed = registry.load(arena, self.base, self.cli_version) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return resolve.fail(arena, diag, .unreachable_index, "cannot read the configuration of {s}: {s}", .{ self.base, @errorName(e) });
        };
        switch (parsed) {
            .ok => |c| {
                self.config = c;
                return c;
            },
            .bad => |why| return resolve.fail(arena, diag, .unreachable_index, "{s}: {s}", .{ self.base, why }),
        }
    }
};

/// `IndexSource` of a `Registry`.
const RegistryIndex = struct {
    reg: *Registry,

    pub fn fetch(self: RegistryIndex, arena: Allocator, name: []const u8, diag: *resolve.Diagnostic) resolve.Error!?[]const u8 {
        const c = try self.reg.get(arena, diag);
        return (IndexSource{ .config = c }).fetch(arena, name, diag);
    }
};

/// `ChannelSource` of a `Registry`.
const RegistryChannel = struct {
    reg: *Registry,

    pub fn fetch(self: RegistryChannel, arena: Allocator, subdir: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
        const c = try self.reg.get(arena, diag);
        return (ChannelSource{ .channel_url = c.channel_url }).fetch(arena, subdir, diag);
    }

    pub fn fetchConda(self: RegistryChannel, arena: Allocator, subdir: []const u8, filename: []const u8, diag: *resolve.Diagnostic) resolve.Error![]const u8 {
        const c = try self.reg.get(arena, diag);
        return (ChannelSource{ .channel_url = c.channel_url }).fetchConda(arena, subdir, filename, diag);
    }
};

/// The channel of the registry `base` names when nothing about it has been read: the production registry's, which
/// is known; no other registry's is.
fn knownChannel(base: []const u8) ?[]const u8 {
    return switch (registry.resolve("prod")) {
        .ok => |prod| if (std.mem.eql(u8, base, prod)) registry.default_channel_url else null,
        .bad => null,
    };
}

/// Where a resolution reads from: the registry, with the staged set (`--overlay`) ahead of it when there is one.
const Layer = struct {
    reg: *Registry,
    staged: ?*const overlay.Overlay,
    /// A package the set does not hold was asked of the registry.
    asked: bool = false,

    /// The versions `input` picks.
    fn pick(self: *Layer, arena: Allocator, input: resolve.Input, diag: *resolve.Diagnostic) resolve.Error!resolve.Resolution {
        const set = self.staged orelse return resolve.resolve(arena, IndexSource{ .config = self.reg.config.? }, input, diag);
        self.asked = false;
        const res = try resolve.resolve(arena, overlay.Index(RegistryIndex){ .overlay = set, .inner = .{ .reg = self.reg }, .asked = &self.asked }, input, diag);
        // The registry is in the conversation anyway: a staged version it already holds with other bytes would
        // lock differently once published, so it is refused rather than shadowed.
        if (self.asked) {
            for (res.packages) |p| {
                const m = set.member(p.record.name) orelse continue;
                const c = try self.reg.get(arena, diag);
                const text = (try (IndexSource{ .config = c }).fetch(arena, m.name, diag)) orelse continue;
                const held = try resolve.parseIndex(arena, m.name, text, diag);
                if (try overlay.registryDiffers(arena, set.dir, m, held)) |why| return resolve.fail(arena, diag, .bad_channel, "{s}", .{why});
            }
        }
        return res;
    }

    /// The lock of `res`, from the channel of the registry.
    fn build(self: *Layer, arena: Allocator, res: resolve.Resolution, old: ?lock.Lock, diag: *resolve.Diagnostic) resolve.Error!lock.Lock {
        const url: []const u8 = if (self.reg.config) |c| c.channel_url else if (knownChannel(self.reg.base)) |k| k else (try self.reg.get(arena, diag)).channel_url;
        const set = self.staged orelse return plan.buildLock(arena, res, url, ChannelSource{ .channel_url = url }, old, diag);
        const channel = overlay.Channel(RegistryChannel){ .overlay = set, .inner = .{ .reg = self.reg }, .registry_subdirs = try overlay.registrySubdirs(arena, set.*, res) };
        return plan.buildLock(arena, res, url, channel, old, diag);
    }
};

/// Reads the staged set `--overlay` names. Null when it is refused (reported).
fn loadOverlay(arena: Allocator, cmd: Command, dir: []const u8) !?overlay.Overlay {
    var why: []const u8 = "";
    return overlay.load(arena, dir, &why) catch |e| switch (e) {
        error.Refused => {
            err(cmd, "--overlay: {s}\n", .{why});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn run(arena: Allocator, cmd: Command, args: Args, cli_version: []const u8) !u8 {
    if (cmd == .add or cmd == .remove) return edit(arena, cmd, args, cli_version);
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
    const r = (try resolveProject(arena, cmd, project, old, args, cli_version)) orelse return null;
    try writeLock(arena, old, r);
    return r.lock;
}

const Resolved = struct { lock: lock.Lock, count: usize, mojo: []const u8 };

/// Writes mopm.lock and prints what changed.
fn writeLock(arena: Allocator, old: ?lock.Lock, r: Resolved) !void {
    const text = try lock.render(arena, r.lock);
    try std.fs.cwd().writeFile(lock_path, text);
    const out = std.io.getStdOut().writer();
    try plan.writeChanges(old, r.lock, out);
    try out.print("locked {d} packages for mojo {s}\n", .{ r.count, r.mojo });
}

/// Resolves the project into a lock and writes nothing. The lock's pins are
/// kept, except those of `args.packages` (of every package for `update`
/// with none named). Null when it failed (already reported).
fn resolveProject(arena: Allocator, cmd: Command, project: Project, old: ?lock.Lock, args: Args, cli_version: []const u8) !?Resolved {
    const toolchains = project.m.mojo;
    const base = switch (registry.resolve(args.registry)) {
        .ok => |b| b,
        .bad => |why| {
            err(cmd, "--registry {s}: {s}\n", .{ args.registry, why });
            return null;
        },
    };
    // A project with no registry dependency (no version requirement, its path dependencies' included) has
    // nothing to ask a registry: it is locked offline, so `mopm lock` works with no network.
    // With a staged set (--overlay) the registry's configuration is read only when a package the set lacks, or the
    // channel of the lock, needs it: a closure the set holds needs no network.
    var staged: ?overlay.Overlay = null;
    if (args.overlay) |dir| staged = (try loadOverlay(arena, cmd, dir)) orelse return null;
    var reg = Registry{ .base = base, .cli_version = cli_version };
    if (project.roots.len == 0) {
        reg.config = registry.offlineConfig(base);
    } else if (staged == null) {
        switch (try registry.load(arena, base, cli_version)) {
            .ok => |c| reg.config = c,
            .bad => |why| {
                err(cmd, "{s}: {s}\n", .{ base, why });
                return null;
            },
        }
    }
    var layer = Layer{ .reg = &reg, .staged = if (staged) |*s| s else null };

    var failures = std.ArrayList(u8).init(arena);
    var warnings = std.ArrayList([]const u8).init(arena);
    defer printWarnings(cmd, warnings.items);
    if (project.m.mojo_all) return resolveAll(arena, cmd, project, old, args, &layer, &warnings);
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
        const res = layer.pick(arena, .{ .mojo = mojo, .roots = project.roots, .pins = pins.items, .warnings = &warnings }, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            try failures.writer().print("  with mojo {s}: {s}\n", .{ mojo, diag.message });
            continue;
        };
        const from_registry = layer.build(arena, res, old, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        const new = plan.addPaths(arena, from_registry, project.paths, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        const pinned = (try withSystemLibs(arena, cmd, project, new)) orelse return null;
        return .{ .lock = pinned, .count = res.packages.len + project.paths.len, .mojo = mojo };
    }
    err(cmd, "cannot resolve the dependencies of {s}:\n{s}", .{ project.m.package.name, failures.items });
    return null;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `l` with the system libraries the project loads pinned (system_libs.zig): the libraries its manifest and its path
/// dependencies' manifests load, and its registry packages' `loads`. `l` itself when nothing is loaded. Null when mopm
/// cannot pin one (reported).
fn withSystemLibs(arena: Allocator, cmd: Command, project: Project, l: lock.Lock) !?lock.Lock {
    var needs = std.ArrayList(system_libs.Need).init(arena);
    var why: []const u8 = "";
    const root = system_libs.needsOf(arena, manifest_path, project.m.native_dependencies, &why) catch |e| switch (e) {
        error.Refused => {
            err(cmd, "{s}\n", .{why});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    try needs.appendSlice(root);
    for (project.paths) |d| {
        const file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ d.path, manifest_path });
        const own = system_libs.needsOf(arena, file, d.native_deps, &why) catch |e| switch (e) {
            error.Refused => {
                err(cmd, "{s}\n", .{why});
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try needs.appendSlice(own);
    }
    return system_libs.attach(arena, l, needs.items, &why) catch |e| switch (e) {
        error.Refused => {
            err(cmd, "{s}\n", .{why});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// `[package] mojo`: resolves the project once for each Mojo version it lists
/// (each takes the newest version that has a build for it) and makes one
/// version 2 lock of the results. Null when a version cannot be resolved or
/// has no toolchain pinned by this mopm (reported).
fn resolveAll(arena: Allocator, cmd: Command, project: Project, old: ?lock.Lock, args: Args, layer: *Layer, warnings: *std.ArrayList([]const u8)) !?Resolved {
    var versions = std.ArrayList([]const u8).init(arena);
    try versions.appendSlice(project.m.mojo);
    std.mem.sort([]const u8, versions.items, {}, lessStr);
    var per = std.ArrayList(lock.Lock).init(arena);
    var closures = std.ArrayList(lock.Closure).init(arena);
    for (versions.items) |mojo| {
        // A version mopm pins no toolchain for cannot be locked: say so first.
        var why: []const u8 = "";
        for (unit_graph.lock_subdirs) |subdir| {
            const tc = unit_graph.toolchainFor(arena, mojo, subdir, &why) catch |e| {
                if (e == error.Refused) {
                    err(cmd, "{s}\n", .{why});
                    return null;
                }
                return e;
            };
            try closures.append(.{ .mojo = mojo, .subdir = subdir, .sha256 = tc.closure_sha256 });
        }
        var pins = std.ArrayList(resolve.Pin).init(arena);
        if (old) |o| {
            const update_all = cmd == .update and args.packages.len == 0;
            if (!update_all and (o.mojos.len > 0 or std.mem.eql(u8, o.mojo, mojo))) {
                for ((try lock.forMojo(arena, o, mojo)).packages) |p| {
                    if (p.source == .path) continue;
                    var named = false;
                    for (args.packages) |n| named = named or std.mem.eql(u8, n, p.name);
                    if (!named) try pins.append(.{ .name = p.name, .version = p.version });
                }
            }
        }
        var diag: resolve.Diagnostic = .{};
        const res = layer.pick(arena, .{ .mojo = mojo, .roots = project.roots, .pins = pins.items, .warnings = warnings, .mojoc_message = true }, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            if (diag.kind == .compiler_mismatch) {
                std.io.getStdErr().writer().print("error: {s}\n", .{diag.message}) catch {};
            } else {
                err(cmd, "cannot resolve the dependencies of {s} with mojo {s}: {s}\n", .{ project.m.package.name, mojo, diag.message });
            }
            return null;
        };
        const one = layer.build(arena, res, old, &diag) catch |e| {
            if (e != error.ResolveFailed) return e;
            err(cmd, "{s}\n", .{diag.message});
            return null;
        };
        try per.append(one);
    }
    var diag: resolve.Diagnostic = .{};
    plan.checkNativesAgree(arena, per.items, &diag) catch |e| {
        if (e != error.ResolveFailed) return e;
        err(cmd, "{s}\n", .{diag.message});
        return null;
    };
    const merged = try plan.mergeMojos(arena, per.items, closures.items);
    const new = plan.addPaths(arena, merged, project.paths, &diag) catch |e| {
        if (e != error.ResolveFailed) return e;
        err(cmd, "{s}\n", .{diag.message});
        return null;
    };
    const pinned = (try withSystemLibs(arena, cmd, project, new)) orelse return null;
    return .{ .lock = pinned, .count = merged.packages.len + project.paths.len, .mojo = try std.mem.join(arena, ", ", new.mojos) };
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
    const staged: ?overlay.Overlay = if (args.overlay) |dir| ((try loadOverlay(arena, .sync, dir)) orelse return 1) else null;
    return install(arena, l, args, staged);
}

/// `--cache`, else `$XDG_CACHE_HOME/mopm/pkgs` when that is set and not empty, else `$HOME/.cache/mopm/pkgs` (the
/// places core/repodata.zig keeps its cache in).
fn cacheDir(arena: Allocator, flag: ?[]const u8) ![]const u8 {
    if (flag) |f| return f;
    if (std.process.getEnvVarOwned(arena, "XDG_CACHE_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(arena, &.{ x, "mopm", "pkgs" });
    } else |_| {}
    const home = std.process.getEnvVarOwned(arena, "HOME") catch {
        err(.sync, "no HOME, so no cache directory for the toolchain's files: pass --cache <dir>\n", .{});
        return error.NoCacheDirectory;
    };
    return std.fs.path.join(arena, &.{ home, ".cache", "mopm", "pkgs" });
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

    var from_set: usize = 0;
    const have = conda_env.readStamp(arena, parent, inst.env_name);
    const current = have != null and std.mem.eql(u8, have.?, stamp);
    if (!current) {
        // The toolchain's files are the same for every project: the cache. The locked packages are this project's.
        const cache_path = cacheDir(arena, args.cache) catch |e| {
            if (e == error.NoCacheDirectory) return 1;
            return e;
        };
        var cache = cwd.makeOpenPath(cache_path, .{}) catch |e| {
            err(.sync, "cannot make the cache directory {s}: {s}\n", .{ cache_path, @errorName(e) });
            return 1;
        };
        defer cache.close();
        var locked_dir = try cwd.makeOpenPath(inst.pkgs_dir, .{});
        defer locked_dir.close();

        var files = std.ArrayList(conda_env.Pkg).init(arena);
        for (items) |item| {
            const into = if (item.locked != null) locked_dir else cache;
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
        const prefix_abs = try std.fs.path.join(arena, &.{ try parent.realpathAlloc(arena, "."), inst.env_name });
        var diag = conda_env.Diag{};
        _ = conda_env.installEnv(arena, parent, inst.env_name, prefix_abs, files.items, stamp, &diag) catch |e| {
            err(.sync, "cannot install into {s}: {s}; the environment is as it was\n", .{ inst.prefix, if (diag.message.len > 0) diag.message else @errorName(e) });
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
    if (current) {
        try out.print("{s} is current: {d} packages for {s} (mojo {s}, {d} toolchain files); nothing to download\n", .{ inst.prefix, pkgs.len, subdir, l.mojo, tc.packages.len });
        return 0;
    }
    if (from_set > 0) try out.print("read {d} packages from the staged set {s}\n", .{ from_set, staged.?.dir });
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

/// `<package>[@<requirement>]`: the name and the requirement, if any.
const Spec = struct { name: []const u8, req: ?[]const u8 };

fn splitSpec(spec: []const u8) Spec {
    const at = std.mem.indexOfScalar(u8, spec, '@') orelse return .{ .name = spec, .req = null };
    return .{ .name = spec[0..at], .req = spec[at + 1 ..] };
}

/// `s` as a TOML basic string.
fn tomlString(arena: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try out.append('"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        0...0x1f, 0x7f => try out.writer().print("\\u{x:0>4}", .{c}),
        else => try out.append(c),
    };
    try out.append('"');
    return out.toOwnedSlice();
}

/// The requirement `add` writes for the version it picked: `^X.Y.Z`.
fn caretOf(arena: Allocator, version: []const u8) ![]const u8 {
    const v = resolve.semverOf(version) orelse return std.fmt.allocPrint(arena, "^{s}", .{version});
    return std.fmt.allocPrint(arena, "^{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

/// The TOML value `add` writes: `{ path = "<dir>" }` for a path dependency,
/// else the requirement as a string.
fn depValue(arena: Allocator, req: []const u8, path: ?[]const u8) ![]const u8 {
    if (path) |p| return std.fmt.allocPrint(arena, "{{ path = {s} }}", .{try tomlString(arena, p)});
    return tomlString(arena, req);
}

const Edited = union(enum) { ok: []const u8, bad: []const u8 };

/// `setKey` for `add`, `removeKey` for `remove` (null: no such entry).
fn applyEdit(arena: Allocator, cmd: Command, src: []const u8, table: []const u8, name: []const u8, value: []const u8) anyerror!?[]const u8 {
    if (cmd == .remove) return toml_edit.removeKey(arena, src, table, name);
    return try toml_edit.setKey(arena, src, table, name, value);
}

/// mopm.toml's text `src` with `name` set to `value` (`add`) or taken out
/// (`remove`, which ignores `value`) in [dependencies], or with `dev` in
/// [dev-dependencies]. Every other byte is kept.
fn editText(arena: Allocator, cmd: Command, src: []const u8, dev: bool, name: []const u8, value: []const u8) !Edited {
    const table = if (dev) "dev-dependencies" else "dependencies";
    const result = applyEdit(arena, cmd, src, table, name, value) catch |e| switch (e) {
        error.UnsupportedEdit => return .{ .bad = try std.fmt.allocPrint(arena, "[{s}] of {s} is written in a form mopm does not edit (a dotted key, an inline table or [[{s}]]); edit it by hand", .{ table, manifest_path, table }) },
        error.InvalidToml => return .{ .bad = try std.fmt.allocPrint(arena, "{s} with {s} = {s} in [{s}] would not be a TOML file mopm reads", .{ manifest_path, name, value, table }) },
        else => return e,
    };
    return .{ .ok = result orelse return .{ .bad = try std.fmt.allocPrint(arena, "{s} is not a dependency: [{s}] of {s} does not name it", .{ name, table, manifest_path }) } };
}

/// `mopm add` and `mopm remove`: edit one entry of mopm.toml, resolve the
/// edited manifest, and only then write mopm.toml and mopm.lock.
fn edit(arena: Allocator, cmd: Command, args: Args, cli_version: []const u8) !u8 {
    const spec = splitSpec(args.spec);
    if (try manifest.nameProblem(arena, "dependency name", spec.name)) |why| {
        err(cmd, "{s}\n", .{why});
        return 1;
    }
    if (spec.req) |r| {
        var why: []const u8 = "";
        _ = semver.parseReq(arena, r, &why) catch |e| switch (e) {
            error.Invalid => {
                err(cmd, "{s}@{s}: invalid version requirement: {s}\n", .{ spec.name, r, why });
                return 1;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    const src = std.fs.cwd().readFileAlloc(arena, manifest_path, 1 << 20) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s} in this directory\n", .{manifest_path});
            return 1;
        }
        return e;
    };
    _ = (try parseManifest(arena, cmd, manifest_path, src)) orelse return 1;
    const old = readLock(arena, cmd) catch |e| {
        if (e == error.Invalid) return 1;
        return e;
    };

    // Without a requirement, any version: the resolver picks the newest that
    // fits, and the caret requirement on it is written below.
    const trial_value = try depValue(arena, spec.req orelse "*", args.path);
    const trial = switch (try editText(arena, cmd, src, args.dev, spec.name, trial_value)) {
        .ok => |t| t,
        .bad => |why| {
            err(cmd, "{s}\n", .{why});
            return 1;
        },
    };
    const m = (try parseManifest(arena, cmd, manifest_path, trial)) orelse return 1;
    if (m.mojo.len == 0) {
        err(cmd, "{s} has no [toolchain] mojo; a lock pins the one compiler every package is built with\n", .{manifest_path});
        return 1;
    }
    const project = (try projectOf(arena, cmd, m)) orelse return 1;
    var resolve_args = args;
    resolve_args.packages = if (cmd == .add) try arena.dupe([]const u8, &.{spec.name}) else &.{};
    const r = (try resolveProject(arena, cmd, project, old, resolve_args, cli_version)) orelse return 1;

    var final = trial;
    if (cmd == .add and spec.req == null and args.path == null) {
        const picked = r.lock.versionOf(spec.name) orelse return error.AddedPackageNotLocked;
        final = switch (try editText(arena, cmd, src, args.dev, spec.name, try tomlString(arena, try caretOf(arena, picked)))) {
            .ok => |t| t,
            .bad => |why| {
                err(cmd, "{s}\n", .{why});
                return 1;
            },
        };
    }
    try std.fs.cwd().writeFile(manifest_path, final);
    try writeLock(arena, old, r);
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
    for ([_][]const []const u8{ &.{"--cache"}, &.{"--toolchain"}, &.{ "--cache", "" }, &.{ "--toolchain", "" }, &.{ "--cache", "a", "--cache", "b" }, &.{ "--toolchain", "a", "--toolchain", "b" } }) |bad| {
        try std.testing.expect((try parseArgs(a, .sync, bad)) == null);
    }
    // sync runs no pixi, so there is no flag for one.
    try std.testing.expect((try parseArgs(a, .sync, &.{ "--pixi", "/opt/pixi" })) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{ "--toolchain", "tc.json" })) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{ "--cache", "/c" })) == null);
    try std.testing.expect((try parseArgs(a, .sync, &.{"tls"})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{"--locked"})) == null);
}

test "--overlay names a staged set for add, lock and sync, once, and for no other command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try parseArgs(a, .lock, &.{})).?.overlay == null);
    try std.testing.expectEqualStrings("/work/staged", (try parseArgs(a, .lock, &.{ "--overlay", "/work/staged" })).?.overlay.?);
    const s = (try parseArgs(a, .sync, &.{ "--locked", "--overlay", "set", "--registry", "beta" })).?;
    try std.testing.expectEqualStrings("set", s.overlay.?);
    try std.testing.expect(s.locked);
    const x = (try parseArgs(a, .add, &.{ "--overlay", "set", "http_client@=0.4.0" })).?;
    try std.testing.expectEqualStrings("set", x.overlay.?);
    try std.testing.expectEqualStrings("http_client@=0.4.0", x.spec);
    // The set is named, and once.
    try std.testing.expect((try parseArgs(a, .lock, &.{"--overlay"})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{ "--overlay", "" })) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{ "--overlay", "a", "--overlay", "b" })) == null);
    try std.testing.expect((try parseArgs(a, .add, &.{ "pkg", "--overlay" })) == null);
    // update, remove and tree read no staged set.
    try std.testing.expect((try parseArgs(a, .update, &.{ "--overlay", "set" })) == null);
    try std.testing.expect((try parseArgs(a, .remove, &.{ "tls", "--overlay", "set" })) == null);
    try std.testing.expect((try parseArgs(a, .tree, &.{ "--overlay", "set" })) == null);
}

test "the channel of a registry nothing was read from is known for production only" {
    try std.testing.expectEqualStrings("https://conda.mopm.dev/", knownChannel("https://api.mopm.dev").?);
    try std.testing.expect(knownChannel("https://api.gamma.mopm.dev") == null);
    try std.testing.expect(knownChannel("https://api.beta.mopm.dev") == null);
    try std.testing.expect(knownChannel("http://127.0.0.1:8080") == null);
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

test "add and remove arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const x = (try parseArgs(a, .add, &.{ "http_client@0.4", "--dev", "--registry", "beta" })).?;
    try std.testing.expectEqualStrings("http_client@0.4", x.spec);
    try std.testing.expect(x.dev);
    try std.testing.expect(x.path == null);
    try std.testing.expectEqualStrings("beta", x.registry);
    const p = (try parseArgs(a, .add, &.{ "--path", "../local", "local" })).?;
    try std.testing.expectEqualStrings("../local", p.path.?);
    try std.testing.expect(!p.dev);
    try std.testing.expect((try parseArgs(a, .add, &.{})) == null); // no package
    try std.testing.expect((try parseArgs(a, .add, &.{ "a", "b" })) == null); // one package
    try std.testing.expect((try parseArgs(a, .add, &.{ "a", "--path" })) == null);
    try std.testing.expect((try parseArgs(a, .add, &.{ "a@1", "--path", "x" })) == null); // a path has no requirement
    try std.testing.expect((try parseArgs(a, .add, &.{ "a", "--locked" })) == null);
    try std.testing.expect((try parseArgs(a, .remove, &.{ "tls", "--dev" })).?.dev);
    try std.testing.expect((try parseArgs(a, .remove, &.{"tls@1"})) == null); // remove takes a name
    try std.testing.expect((try parseArgs(a, .remove, &.{ "tls", "--path", "x" })) == null);
    try std.testing.expect((try parseArgs(a, .remove, &.{})) == null);
    try std.testing.expect((try parseArgs(a, .lock, &.{"--dev"})) == null);
}

test "a package spec, the caret requirement add writes, and TOML values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("tls", splitSpec("tls").name);
    try std.testing.expect(splitSpec("tls").req == null);
    try std.testing.expectEqualStrings("tls", splitSpec("tls@>=1.2, <2").name);
    try std.testing.expectEqualStrings(">=1.2, <2", splitSpec("tls@>=1.2, <2").req.?);
    try std.testing.expectEqualStrings("^0.5.0", try caretOf(a, "0.5.0"));
    try std.testing.expectEqualStrings("^1.0.0", try caretOf(a, "1.0")); // a two-part index version is X.Y.0
    try std.testing.expectEqualStrings("\"^1.2.5\"", try depValue(a, "^1.2.5", null));
    try std.testing.expectEqualStrings("{ path = \"../local\" }", try depValue(a, "*", "../local"));
    try std.testing.expectEqualStrings("{ path = \"a\\\\b \\\"q\\\" \\u0009\" }", try depValue(a, "*", "a\\b \"q\" \t"));
}

// The golden files of the add/remove tests: every byte outside the edited
// entry must survive, so each comparison is of the whole file.
const golden_before =
    \\# The project. Comments, blank lines, order and spacing survive add and remove.
    \\[package]
    \\name    = "app"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"   # one compiler
    \\
    \\[dependencies]
    \\# transport
    \\tls   =   "1"        # the major only
    \\legacy = "1"
    \\
    \\[dev-dependencies]  # tests only
    \\
    \\# trailing comment
    \\
;

test "add keeps every other byte of mopm.toml, in [dependencies] and [dev-dependencies]" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = (try editText(a, .add, golden_before, false, "http_client", try depValue(a, try caretOf(a, "0.5.0"), null))).ok;
    const two = (try editText(a, .add, one, true, "http_core", try depValue(a, try caretOf(a, "1.2.5"), null))).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\tls   =   "1"        # the major only
        \\legacy = "1"
        \\http_client = "^0.5.0"
        \\
        \\[dev-dependencies]  # tests only
        \\http_core = "^1.2.5"
        \\
        \\# trailing comment
        \\
    , two);
    const path = (try editText(a, .add, golden_before, false, "local", try depValue(a, "*", "local"))).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\tls   =   "1"        # the major only
        \\legacy = "1"
        \\local = { path = "local" }
        \\
        \\[dev-dependencies]  # tests only
        \\
        \\# trailing comment
        \\
    , path);
}

test "add of an existing dependency replaces its value in place" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = (try editText(a, .add, golden_before, false, "tls", try depValue(a, "~1.1", null))).ok;
    const want = try std.mem.replaceOwned(u8, a, golden_before, "tls   =   \"1\"        #", "tls   =   \"~1.1\"        #");
    try std.testing.expectEqualStrings(want, got);
}

test "remove of a key in the middle of a table takes its line and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const three = (try editText(a, .add, golden_before, false, "http_client", "\"^0.5.0\"")).ok;
    const got = (try editText(a, .remove, three, false, "legacy", "")).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\tls   =   "1"        # the major only
        \\http_client = "^0.5.0"
        \\
        \\[dev-dependencies]  # tests only
        \\
        \\# trailing comment
        \\
    , got);
}

test "remove of an absent dependency is an error, and so is the other table's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("nosuch is not a dependency: [dependencies] of mopm.toml does not name it", (try editText(a, .remove, golden_before, false, "nosuch", "")).bad);
    // A value that would leave mopm.toml unreadable is refused with the file, the entry and the table named.
    const unreadable = (try editText(a, .add, golden_before, false, "tls", "\"1.0\"\nbroken = =")).bad;
    try std.testing.expectEqualStrings("mopm.toml with tls = \"1.0\"\nbroken = = in [dependencies] would not be a TOML file mopm reads", unreadable);
    // tls is in [dependencies], not [dev-dependencies].
    try std.testing.expectEqualStrings("tls is not a dependency: [dev-dependencies] of mopm.toml does not name it", (try editText(a, .remove, golden_before, true, "tls", "")).bad);
    // No [dev-dependencies] table at all.
    try std.testing.expect((try editText(a, .remove, "[package]\nname = \"a\"\n", true, "tls", "")) == .bad);
    // A table written as dotted keys is not edited.
    try std.testing.expect((try editText(a, .add, "dependencies.tls = \"1\"\n\n[package]\nname = \"a\"\n", false, "x", "\"1\"")) == .bad);
}

/// A loopback server that answers every GET with `body`, for one connection at a time, until it is closed.
const BodyServer = struct {
    server: std.net.Server,
    body: []const u8,

    fn serve(self: *BodyServer) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var buf: [8 * 1024]u8 = undefined;
            var http_server = std.http.Server.init(conn, &buf);
            var req = http_server.receiveHead() catch continue;
            req.respond(self.body, .{ .status = .ok, .keep_alive = false }) catch continue;
        }
    }
};

// Defect it catches: a package file read past the size a package may be, or cut short without saying so. Variant
// Defect caught: fetchConda passes the HTTP client's own limit (64 MiB) instead of `max_conda`.
test "fetchConda reads a package file up to its limit and refuses a longer one by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    // The serving thread is detached and outlives this test, so the server it reads must not live on this stack:
    // once the test returned, the next test reused those bytes and the thread's accept() got a garbage handle
    // (EBADF, which std turns into `unreachable`, aborting the whole test binary). Same convention as the stubs
    // in http.zig and pkg_fetch.zig: a page-allocated server that is never freed.
    const srv = try std.heap.page_allocator.create(BodyServer);
    srv.* = .{ .server = try address.listen(.{ .reuse_address = true }), .body = "x" ** 2000 };
    const t = try std.Thread.spawn(.{}, BodyServer.serve, .{srv});
    t.detach();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{srv.server.listen_address.getPort()});
    var diag: resolve.Diagnostic = .{};
    // The default limit is publish's maximum, which is more than the 64 MiB the HTTP client used to impose.
    try std.testing.expectEqual(@as(usize, 100_000_000), (ChannelSource{ .channel_url = url }).max_conda);
    const ok = try (ChannelSource{ .channel_url = url, .max_conda = 2000 }).fetchConda(a, "linux-64", "f.conda", &diag);
    try std.testing.expectEqual(@as(usize, 2000), ok.len);
    try std.testing.expectError(error.ResolveFailed, (ChannelSource{ .channel_url = url, .max_conda = 1999 }).fetchConda(a, "linux-64", "f.conda", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "f.conda is larger than 1999 bytes, the most a package file may be") != null);
}
