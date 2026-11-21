//! `mopm stage`: the members of a workspace, packed and checked against a registry, as a staged set
//! (spec/staged-set.md) that `mopm publish --staged` publishes.
//!
//!   mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version>
//!              --out <dir> --registry <prod|gamma|beta|url>
//!   mopm stage --workspace-root <dir> [<package>...] --artifacts <mojo version>=<dir>... --out <dir> --registry <...>
//!
//! The artifacts are of one Mojo compiler (`--artifacts <dir>` with one `--compiler`) or of several (`--artifacts <mojo>=<dir>`,
//! once per compiler, and no `--compiler`: a value is of that form when the text before its first '=' is a compiler, digits
//! and dots). Mixing the forms, naming a compiler twice, or `--compiler` with `<mojo>=<dir>` is refused. Each member is packed
//! for every compiler and gets one file per platform directory that holds its artifact for that compiler; a compiler with
//! none for a member is refused. A member's source digest (src/core/source_digest.zig) is computed once, so every compiler's
//! files carry the same metadata.
//!
//! It reads no token and writes nothing to the registry. Steps, each of which refuses before the next:
//!
//! 1. Members. Every directory below `--workspace-root` that holds a `mopm.toml` is a member (a member's own
//!    subdirectories are not searched; hidden directories, `buck-out`, `node_modules` and `zig-out` are skipped). With
//!    packages named, the set is those and the members they depend on, at any depth. A member with
//!    `[package] publish = false` is left out when no package is named (one line says so) and refused when named; a
//!    member that is staged may not have one in its `[dependencies]` closure (its `[dev-dependencies]` may).
//! 2. Order. An edge is a dependency on a member: a path dependency (its `version` must be met by the member it names),
//!    or a registry dependency whose name is a member's (its requirement must be met by that member). A dependency
//!    comes before its dependents; a cycle is refused. Dev-dependencies are not packed and are not edges.
//! 3. Pack. The `.mojoc` of a member for a subdir is `<artifacts>/<subdir>/<namespace>/<import name>.mojoc`; each subdir that has one is
//!    packed, with the path of every path dependency dropped and its version requirement kept (src/core/conda.zig).
//!    A member with `[native.<id>]` libraries also needs, per subdir, each one's static archive at
//!    `<artifacts>/<subdir>/<namespace>/<import name>.native/<archive name>` (`lib<id>.a`, or the native's `soname`), packed as
//!    `mopm pack --native` packs it; one missing is refused, and `noarch` cannot hold natives.
//!    A member with `[targets] bins` ships each program's source (the `.mojo` file the entry names, below the member
//!    directory) in every subdir's package, at `lib/mojo/<import name>.bins/<bin>.mojo` (src/core/bins.zig); an unreadable,
//!    empty or badly named one is refused. Nothing built is packed: the program is built where it is run.
//!    Every file is packed twice and the two must be the same bytes; the metadata inside must hold no URL, no lock
//!    entry and no path.
//! 4. Registry. `GET <api_v2_url>/packages/<namespace>/<name>/<version>` (no token) decides each member from the builds the
//!    version has (a build is the files of one compiler, `mojo<compiler>_0`; `builds` of the answer, or the version's files as one
//!    build when the answer has none). Not there: `upload`, with every staged build. Yanked or tombstoned (its number is burned):
//!    `refuse`. Published: a staged build the version has must be the same files, byte for byte (else `refuse`: a published file is
//!    never replaced, so bump the version); a staged build the version lacks is an add, allowed when the member's
//!    `manifest_sha256` is the version's (else `refuse`: built from other sources) and when it is the only one (else `refuse`: the
//!    registry takes one Mojo build per publish); an add is an `upload` member of the plan whose files are that build's only.
//!    A published version with no new build is `skip`.
//! 5. Write. `<out>/<subdir>/<file>.conda` for each upload member (the file is `mojo-<namespace>.<name>-...`), its readme
//!    at `<out>/<namespace>/<name>/README.md` (none for an add: a published version's readme is not changed), and `plan.json` (version 2, members named by full name) last, which a reader
//!    treats as proof the set is complete. A set with a `refuse` member is written too (`publish --staged` refuses it
//!    whole) and the run ends 1.
//!
//! Exit status: 0 staged; 1 refused or failed; 2 usage error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const manifest = core.manifest;
const conda = core.conda;
const bins_mod = core.bins;
const source_digest = core.source_digest;
const registry = core.registry;
const semver = core.semver;
const publish_cmd = @import("publish_cmd.zig");
const v2 = core.registry_v2;
const gp = @import("group_publish.zig");
const readmes = @import("group_readmes.zig");
const plan_mod = @import("group_plan.zig");
const Net = gp.Net;
const Console = gp.Console;

pub const usage =
    \\usage: mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version>
    \\                  --out <dir> --registry <prod|gamma|beta|url>
    \\       mopm stage --workspace-root <dir> [<package>...] --artifacts <mojo version>=<dir>...
    \\                  --out <dir> --registry <prod|gamma|beta|url>
    \\
    \\  pack the members of the workspace under <dir> (the named packages and what they depend on, or all)
    \\  from <artifacts>/<subdir>/<namespace>/<import name>.mojoc, check each version against the registry, and write the
    \\  staged set (spec/staged-set.md) to <out>. Reads no token. --registry is required: there is no default.
    \\
    \\  One compiler: --artifacts <dir> --compiler <mojo version>. Several: --artifacts <mojo version>=<dir>, once per
    \\  compiler and with no --compiler; each member is packed for every compiler.
    \\  A version the registry has gets a build for a compiler it lacks when the sources are the same, one build per publish.
    \\
;

/// The artifacts of one Mojo compiler: `<dir>/<subdir>/<namespace>/<import name>.mojoc` for each subdir.
pub const Build = struct { compiler: []const u8, artifacts: []const u8 };

pub const Flags = struct {
    workspace_root: []const u8,
    packages: []const []const u8 = &.{},
    /// `--artifacts <dir>` of the form with one `--compiler`; empty in the `<mojo>=<dir>` form.
    artifacts: []const u8 = "",
    /// The `--compiler` of that form.
    compiler: []const u8 = "",
    /// `--artifacts <mojo>=<dir>`, one per compiler, in the order given; empty in the form with `--compiler`.
    builds: []const Build = &.{},
    out: []const u8,
    registry: []const u8,
};

/// The compilers to stage and where each one's artifacts are, by compiler version in numeric order, whatever order they were given in.
pub fn buildsOf(arena: Allocator, f: Flags) Allocator.Error![]const Build {
    const list = if (f.builds.len > 0) try arena.dupe(Build, f.builds) else try arena.dupe(Build, &.{.{ .compiler = f.compiler, .artifacts = f.artifacts }});
    std.mem.sort(Build, list, {}, buildLess);
    return list;
}

fn buildLess(_: void, a: Build, b: Build) bool {
    return conda.compilerOrder(a.compiler, b.compiler) == .lt;
}

/// `<mojo>=<dir>` when the text before the first '=' is a compiler version (digits and dots); null for any other value.
fn namedBuild(value: []const u8) ?Build {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    if (!conda.validCompiler(value[0..eq])) return null;
    return .{ .compiler = value[0..eq], .artifacts = value[eq + 1 ..] };
}

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

pub fn parseFlags(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var root: ?[]const u8 = null;
    var artifacts = std.ArrayList([]const u8).init(arena);
    var compiler: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var reg: ?[]const u8 = null;
    var packages = std.ArrayList([]const u8).init(arena);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "-")) {
            try packages.append(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--artifacts")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return .{ .bad = "--artifacts needs a value" };
            i += 1;
            try artifacts.append(args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--compiler") and compiler != null) {
            return .{ .bad = "--compiler is given twice; to stage several compilers, name each one in --artifacts <mojo version>=<dir> and leave --compiler out" };
        }
        const takes = [_]struct { []const u8, *?[]const u8 }{
            .{ "--workspace-root", &root },
            .{ "--compiler", &compiler },
            .{ "--out", &out },
            .{ "--registry", &reg },
        };
        var matched = false;
        for (takes) |t| {
            if (!std.mem.eql(u8, a, t[0])) continue;
            if (i + 1 >= args.len or args[i + 1].len == 0) return .{ .bad = try std.fmt.allocPrint(arena, "{s} needs a value", .{a}) };
            i += 1;
            t[1].* = args[i];
            matched = true;
        }
        if (!matched) return .{ .bad = try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{a}) };
    }
    if (root == null) return .{ .bad = "--workspace-root <dir> is required" };
    if (artifacts.items.len == 0) return .{ .bad = "--artifacts <dir> is required" };

    // `--artifacts <dir>` (with one --compiler) or `--artifacts <mojo>=<dir>` (one per compiler): one form.
    var named = std.ArrayList(Build).init(arena);
    var plain: usize = 0;
    for (artifacts.items) |value| {
        if (namedBuild(value)) |b| {
            if (b.artifacts.len == 0) return .{ .bad = try std.fmt.allocPrint(arena, "--artifacts {s}: no directory after the '='", .{value}) };
            for (named.items) |seen| {
                if (std.mem.eql(u8, seen.compiler, b.compiler)) return .{ .bad = try std.fmt.allocPrint(arena, "--artifacts names the compiler {s} twice", .{b.compiler}) };
            }
            try named.append(b);
        } else plain += 1;
    }
    if (named.items.len > 0 and plain > 0) return .{ .bad = "--artifacts is given both as <dir> and as <mojo version>=<dir>; use one form" };
    if (plain > 1) return .{ .bad = "--artifacts <dir> is given more than once; with one --compiler give one directory, or name each compiler as --artifacts <mojo version>=<dir>" };
    if (named.items.len > 0 and compiler != null) return .{ .bad = "--compiler cannot be used with --artifacts <mojo version>=<dir>: the compiler is the text before the '='" };
    if (plain == 1 and compiler == null) return .{ .bad = "--compiler <exact mojo version> is required" };
    if (out == null) return .{ .bad = "--out <dir> is required" };
    if (reg == null) return .{ .bad = "--registry is required: there is no default, so a set is never checked against (and later published to) a registry by accident" };
    if (named.items.len > 0) return .{ .ok = .{ .workspace_root = root.?, .packages = packages.items, .builds = named.items, .out = out.?, .registry = reg.? } };
    return .{ .ok = .{ .workspace_root = root.?, .packages = packages.items, .artifacts = artifacts.items[0], .compiler = compiler.?, .out = out.?, .registry = reg.? } };
}

// ----------------------------------------------------------------- members

pub const Member = struct {
    /// The full name, `<namespace>/<name>`: what the registry, the plan and every message call the package.
    name: []const u8,
    /// The import name: what the artifacts' file names and the package's library files use.
    import: []const u8,
    version: []const u8,
    /// Absolute, without a trailing separator.
    dir: []const u8,
    m: manifest.Manifest,
    /// Indices of the members this one depends on.
    deps: []const usize = &.{},
};

/// A result that is a value or the reason there is none.
fn Result(comptime T: type) type {
    return union(enum) { ok: T, bad: []const u8 };
}

fn bad(comptime T: type, arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Result(T) {
    return .{ .bad = try std.fmt.allocPrint(arena, fmt, args) };
}

const skipped_dirs = [_][]const u8{ "buck-out", "node_modules", "zig-out", "zig-cache" };
const max_depth: usize = 12;

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn walk(arena: Allocator, dir: []const u8, depth: usize, found: *std.ArrayList(Member), problem: *?[]const u8) anyerror!void {
    if (problem.* != null or depth > max_depth) return;
    const file = try std.fs.path.join(arena, &.{ dir, "mopm.toml" });
    if (std.fs.cwd().readFileAlloc(arena, file, 1 << 20)) |src| {
        var diag: manifest.Diagnostic = .{};
        const m = manifest.parse(arena, src, &diag) catch |e| {
            problem.* = if (e == error.Invalid)
                try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ file, diag.pos.line, diag.pos.col, diag.message })
            else
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ file, @errorName(e) });
            return;
        };
        try found.append(.{ .name = m.package.full_name, .import = m.package.name, .version = m.package.version, .dir = dir, .m = m });
        return;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => {
            problem.* = try std.fmt.allocPrint(arena, "{s}: {s}", .{ file, @errorName(e) });
            return;
        },
    }
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var names = std.ArrayList([]const u8).init(arena);
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        var skip = false;
        for (skipped_dirs) |s| skip = skip or std.mem.eql(u8, s, entry.name);
        if (!skip) try names.append(try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);
    for (names.items) |n| try walk(arena, try std.fs.path.join(arena, &.{ dir, n }), depth + 1, found, problem);
}

/// The members below `root` (absolute), sorted by directory, or why there are none.
pub fn discover(arena: Allocator, root: []const u8) !Result([]Member) {
    var found = std.ArrayList(Member).init(arena);
    var problem: ?[]const u8 = null;
    try walk(arena, root, 0, &found, &problem);
    if (problem) |p| return .{ .bad = p };
    if (found.items.len == 0) return bad([]Member, arena, "{s} holds no mopm.toml: there are no members to stage", .{root});
    for (found.items, 0..) |m, i| {
        for (found.items[0..i]) |other| {
            if (std.mem.eql(u8, other.m.package.full_name, m.m.package.full_name)) {
                return bad([]Member, arena, "{s} and {s} are both the package {s}", .{ other.dir, m.dir, m.m.package.full_name });
            }
            if (std.mem.eql(u8, other.import, m.import)) {
                return bad([]Member, arena, "{s} and {s} are {s} and {s}, which have the same import name {s}; a staged set holds one package per import name", .{ other.dir, m.dir, other.m.package.full_name, m.m.package.full_name, m.import });
            }
        }
    }
    return .{ .ok = found.items };
}

/// The member with the full name `full`.
fn indexOfFullName(members: []const Member, full: []const u8) ?usize {
    for (members, 0..) |m, i| {
        if (std.mem.eql(u8, m.m.package.full_name, full)) return i;
    }
    return null;
}

/// The member a name on the command line means: the one with that full name, or else the one with that import name.
fn indexOfNamed(members: []const Member, named: []const u8) ?usize {
    if (indexOfFullName(members, named)) |i| return i;
    for (members, 0..) |m, i| {
        if (std.mem.eql(u8, m.import, named)) return i;
    }
    return null;
}

/// Fills in the edges of `members`; the reason when a dependency on a member cannot be staged.
pub fn link(arena: Allocator, members: []Member) !?[]const u8 {
    for (members) |*m| {
        var edges = std.ArrayList(usize).init(arena);
        for (m.m.dependencies) |d| {
            const target: usize = switch (d.source) {
                .path => |p| blk: {
                    const abs = try std.fs.path.resolve(arena, &.{ m.dir, p });
                    var at: ?usize = null;
                    for (members, 0..) |other, i| {
                        if (std.mem.eql(u8, other.dir, abs)) at = i;
                    }
                    const i = at orelse return try std.fmt.allocPrint(arena, "{s} depends on '{s}' at the path '{s}', which is not a member of the workspace", .{ m.m.package.full_name, d.full_name, p });
                    if (!std.mem.eql(u8, members[i].m.package.full_name, d.full_name)) {
                        return try std.fmt.allocPrint(arena, "{s} calls the package at '{s}' {s}, but it is {s}", .{ m.m.package.full_name, p, d.full_name, members[i].m.package.full_name });
                    }
                    if (d.requirement == null) return try std.fmt.allocPrint(arena, "{s}: " ++ conda.path_no_version_fmt, .{ m.m.package.full_name, d.full_name });
                    break :blk i;
                },
                .version => indexOfFullName(members, d.full_name) orelse continue,
            };
            const text: []const u8 = switch (d.source) {
                .path => d.requirement.?,
                .version => |v| v,
            };
            var why: []const u8 = "";
            // The manifest parser checked this requirement and this version already.
            const req = try semver.parseReq(arena, text, &why);
            const have = semver.parseVersion(members[target].version) orelse return error.InvalidVersion;
            if (!req.matches(have)) {
                return try std.fmt.allocPrint(arena, "{s} requires {s} \"{s}\", but the workspace has {s} {s}; change the requirement or the version", .{ m.m.package.full_name, d.full_name, text, d.full_name, members[target].version });
            }
            var seen = false;
            for (edges.items) |e| seen = seen or e == target;
            if (!seen) try edges.append(target);
        }
        m.deps = edges.items;
    }
    return null;
}

/// The members to stage as indices into `members`, dependencies first (ties by name), or why not. `named` empty is all
/// the members that may be published: one with `publish = false` is left out then, and refused when named. A member to
/// stage may not depend (outside `[dev-dependencies]`) on one that is not published, directly or through others.
pub fn order(arena: Allocator, members: []const Member, named: []const []const u8) !Result([]const usize) {
    var wanted = try arena.alloc(bool, members.len);
    var stack = std.ArrayList(usize).init(arena);
    for (members, 0..) |m, i| {
        wanted[i] = named.len == 0 and m.m.package.publish;
        if (wanted[i]) try stack.append(i);
    }
    for (named) |n| {
        const i = indexOfNamed(members, n) orelse return bad([]const usize, arena, "{s} is not a member of the workspace", .{n});
        if (!members[i].m.package.publish) return bad([]const usize, arena, "{s} has publish = false in its mopm.toml, so it cannot be staged or published; remove the key to publish it", .{n});
        if (!wanted[i]) {
            wanted[i] = true;
            try stack.append(i);
        }
    }
    while (stack.popOrNull()) |i| {
        for (members[i].deps) |d| {
            if (!members[d].m.package.publish) {
                return bad([]const usize, arena, "{s} is staged for publishing but depends on {s}, which has publish = false; a published package cannot need one that is never published (a dev-dependency may)", .{ members[i].m.package.full_name, members[d].m.package.full_name });
            }
            if (!wanted[d]) {
                wanted[d] = true;
                try stack.append(d);
            }
        }
    }
    var left = try arena.alloc(usize, members.len);
    var total: usize = 0;
    for (members, 0..) |m, i| {
        left[i] = 0;
        if (!wanted[i]) continue;
        total += 1;
        left[i] = m.deps.len;
    }
    var out = std.ArrayList(usize).init(arena);
    var done = try arena.alloc(bool, members.len);
    @memset(done, false);
    while (out.items.len < total) {
        // The ready member with the least name: the order does not depend on the order the directories were walked.
        var pick: ?usize = null;
        for (members, 0..) |m, i| {
            if (!wanted[i] or done[i] or left[i] != 0) continue;
            if (pick == null or std.mem.lessThan(u8, m.name, members[pick.?].name)) pick = i;
        }
        const i = pick orelse {
            var names = std.ArrayList([]const u8).init(arena);
            for (members, 0..) |m, k| {
                if (wanted[k] and !done[k]) try names.append(m.name);
            }
            std.mem.sort([]const u8, names.items, {}, lessStr);
            return bad([]const usize, arena, "the dependencies of {s} form a cycle (or hang from one); nothing was staged", .{try std.mem.join(arena, ", ", names.items)});
        };
        done[i] = true;
        try out.append(i);
        for (members, 0..) |other, k| {
            if (!wanted[k] or done[k]) continue;
            for (other.deps) |d| {
                if (d == i) left[k] -= 1;
            }
        }
    }
    return .{ .ok = out.items };
}

// -------------------------------------------------------------------- pack

/// The files of a member built with one compiler: one per platform directory that has the member's artifact.
pub const StagedBuild = struct {
    compiler: []const u8,
    /// `mojo<compiler>_0`, as in the file names and in `builds` of the registry's answer.
    build: []const u8,
    packs: []const conda.Packed,
};

pub const Staged = struct {
    member: Member,
    /// Every file of every build, by compiler and then platform directory.
    packs: []const conda.Packed,
    /// The same files by build, in the order of the compiler versions.
    builds: []const StagedBuild = &.{},
    /// The readme text and its path below the staged directory, or null.
    readme: ?[]const u8 = null,
    /// A line to say before going on: the package has no source digest.
    note: ?[]const u8 = null,
};

/// What the metadata inside a package must not hold: it is the manifest as published, so a URL, a lock entry or a
/// path means the packer let something local through.
pub fn metadataProblem(arena: Allocator, in: conda.Input, paths: []const []const u8) Allocator.Error!?[]const u8 {
    const texts = [_][]const u8{ try conda.mopmJson(arena, in), try conda.indexJson(arena, in) };
    for (texts) |t| {
        for ([_][]const u8{ "://", "localhost", "mopm.lock", "\"path\"" }) |needle| {
            if (std.mem.indexOf(u8, t, needle) != null) return try std.fmt.allocPrint(arena, "the packed metadata holds '{s}'", .{needle});
        }
        for (paths) |p| {
            if (std.mem.indexOf(u8, t, p) != null) return try std.fmt.allocPrint(arena, "the packed metadata holds the path '{s}'", .{p});
        }
    }
    return null;
}

/// The directory of a member's native archives beside its `.mojoc`: `<artifacts>/<subdir>/<namespace>/<name>.native/<archive name>`,
/// where the archive name is `lib<id>.a` (or the `soname` of the `[native.<id>]`).
pub const native_dir_suffix = ".native";

/// Packs `m` from the artifacts of every build in `builds`, or the reason it cannot be.
pub fn packMember(arena: Allocator, members: []const Member, m: Member, builds: []const Build) !Result(Staged) {
    const T = Staged;
    if (try publish_cmd.versionProblem(arena, m.version)) |p| return bad(T, arena, "{s}: {s}", .{ m.name, p });
    for (builds) |b| {
        if (!conda.validCompiler(b.compiler)) return bad(T, arena, "--compiler {s}: an exact Mojo version is digits and dots, such as 1.0.0", .{b.compiler});
    }
    var path_versions = std.ArrayList(conda.PathVersion).init(arena);
    var paths = std.ArrayList([]const u8).init(arena);
    for (m.m.dependencies) |d| {
        switch (d.source) {
            .path => |p| {
                try paths.append(p);
                const i = indexOfFullName(members, d.full_name) orelse continue;
                try path_versions.append(.{ .name = d.full_name, .version = members[i].version });
            },
            .version => {},
        }
    }
    var why: []const u8 = "";
    const deps = conda.depsOf(arena, m.m, path_versions.items, &why) catch |e| return if (e == error.Unpackable) try bad(T, arena, "{s}: {s}", .{ m.name, why }) else error.OutOfMemory;
    const native_deps = conda.nativeDepsOf(arena, m.m, &why) catch |e| return if (e == error.Unpackable) try bad(T, arena, "{s}: {s}", .{ m.name, why }) else error.OutOfMemory;
    // The programs of `[targets] bins`, as source: the same files in every subdir's package.
    const bins = bins_mod.read(arena, m.m, m.dir, &why) catch |e| return if (e == error.Unpackable) try bad(T, arena, "{s}: {s}", .{ m.name, why }) else error.OutOfMemory;
    // The packed dependencies on members are the edges, no more and no fewer.
    // A dependency is on a member by full name: a member of another namespace with the same import name is not it.
    for (m.m.dependencies) |d| {
        const is_member = indexOfFullName(members, d.full_name) != null;
        var edge = false;
        for (m.deps) |e| edge = edge or std.mem.eql(u8, members[e].m.package.full_name, d.full_name);
        if (is_member != edge) return bad(T, arena, "{s}: the packed dependency on {s} is not the one the workspace has", .{ m.m.package.full_name, d.full_name });
    }
    // The digest of the member's sources, once: every compiler's files carry the same metadata.
    var source_sha256: []const u8 = "";
    var note: ?[]const u8 = null;
    switch (try source_digest.ofPackage(arena, m.m, m.dir, "mopm.toml")) {
        .digest => |d| source_sha256 = try arena.dupe(u8, &d),
        .no_library => |lib| note = try source_digest.noLibraryNote(arena, m.m, lib),
        .bad => |reason| return bad(T, arena, "{s}: {s}", .{ m.name, reason }),
    }

    const one = Packer{ .m = m, .deps = deps, .native_deps = native_deps, .bins = bins, .source_sha256 = source_sha256, .paths = paths.items };
    var all = std.ArrayList(conda.Packed).init(arena);
    var staged_builds = std.ArrayList(StagedBuild).init(arena);
    for (builds) |b| {
        const packs = switch (try one.pack(arena, b.artifacts, b.compiler)) {
            .ok => |p| p,
            .bad => |why_not| return .{ .bad = why_not },
        };
        if (packs.len == 0) {
            // With one compiler there is no compiler to name.
            if (builds.len == 1) {
                return bad(T, arena, "{s} has no build artifact: expected {s}/<subdir>/{s}/{s}.mojoc for one of noarch, linux-64, linux-aarch64, osx-arm64", .{ m.name, b.artifacts, m.m.package.namespace, m.import });
            }
            return bad(T, arena, "{s} has no build artifact for Mojo {s}: expected {s}/<subdir>/{s}/{s}.mojoc for one of noarch, linux-64, linux-aarch64, osx-arm64", .{ m.name, b.compiler, b.artifacts, m.m.package.namespace, m.import });
        }
        try all.appendSlice(packs);
        try staged_builds.append(.{ .compiler = b.compiler, .build = try std.fmt.allocPrint(arena, "mojo{s}_0", .{b.compiler}), .packs = packs });
    }
    if (all.items.len > plan_mod.max_files_per_member) {
        return bad(T, arena, "{s} would be {d} files for {d} compilers; a version has at most {d} files", .{ m.name, all.items.len, builds.len, plan_mod.max_files_per_member });
    }
    var staged = Staged{ .member = m, .packs = all.items, .builds = staged_builds.items, .note = note };

    var explicit = true;
    const readme_rel = m.m.package.readme orelse blk: {
        explicit = false;
        break :blk "README.md";
    };
    const readme_path = try std.fs.path.join(arena, &.{ m.dir, readme_rel });
    if (std.fs.cwd().readFileAlloc(arena, readme_path, 1 << 24)) |text| {
        if (try publish_cmd.readmeProblem(arena, readme_path, text)) |p| return bad(T, arena, "{s}", .{p});
        staged.readme = text;
    } else |e| {
        if (explicit or e != error.FileNotFound) return bad(T, arena, "{s}: {s}", .{ readme_path, @errorName(e) });
    }
    return .{ .ok = staged };
}

/// What `packMember` has worked out of a member before it packs it for a compiler.
const Packer = struct {
    m: Member,
    deps: []const conda.Dep,
    native_deps: []const conda.Dep,
    bins: []const conda.Bin,
    source_sha256: []const u8,
    paths: []const []const u8,

    /// The member's files for one compiler: one for each subdir that has its artifact below `artifacts`, none when no subdir has.
    fn pack(self: Packer, arena: Allocator, artifacts: []const u8, compiler: []const u8) !Result([]const conda.Packed) {
        const T = []const conda.Packed;
        const m = self.m;
        var packs = std.ArrayList(conda.Packed).init(arena);
        for (conda.subdirs) |subdir| {
            const file = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}.mojoc", .{ artifacts, subdir, m.m.package.namespace, m.import });
            const bytes = std.fs.cwd().readFileAlloc(arena, file, 1 << 30) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return bad(T, arena, "{s}: {s}", .{ file, @errorName(e) }),
            };
            if (bytes.len == 0) return bad(T, arena, "{s} is empty", .{file});
            // The static archives of the member's `[native.<id>]`, as `mopm pack --native` would be given them.
            var natives = std.ArrayList(conda.Native).init(arena);
            if (m.m.native.len > 0) {
                if (std.mem.eql(u8, subdir, "noarch")) {
                    return bad(T, arena, "{s} declares native libraries, which are built for one platform; its artifact must be under linux-64 (or another subdir), not noarch ({s})", .{ m.name, file });
                }
                for (m.m.native) |n| {
                    const archive_name = try n.archiveName(arena);
                    const nfile = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}{s}/{s}", .{ artifacts, subdir, m.m.package.namespace, m.import, native_dir_suffix, archive_name });
                    const nbytes = std.fs.cwd().readFileAlloc(arena, nfile, 1 << 30) catch |e| switch (e) {
                        error.FileNotFound => return bad(T, arena, "{s}: native library '{s}' has no archive for {s}: expected {s}", .{ m.name, n.id, subdir, nfile }),
                        else => return bad(T, arena, "{s}: {s}: {s}", .{ m.name, nfile, @errorName(e) }),
                    };
                    const native = conda.Native{ .id = n.id, .soname = archive_name, .needs = n.needs, .exclusive = n.exclusive, .link = n.link, .archive = nbytes };
                    if (try conda.nativeProblem(arena, native)) |why_not| return bad(T, arena, "{s}: {s}: {s}", .{ m.name, nfile, why_not });
                    try natives.append(native);
                }
            }
            const in = conda.Input{ .name = m.name, .version = m.version, .compiler = compiler, .subdir = subdir, .deps = self.deps, .native_deps = self.native_deps, .mojoc = bytes, .natives = natives.items, .bins = self.bins, .source_sha256 = self.source_sha256 };
            const p = conda.pack(arena, in) catch |e| return bad(T, arena, "{s}: cannot pack {s}: {s}", .{ m.name, file, @errorName(e) });
            const again = conda.pack(arena, in) catch |e| return bad(T, arena, "{s}: cannot pack {s}: {s}", .{ m.name, file, @errorName(e) });
            if (!std.mem.eql(u8, p.bytes, again.bytes)) return bad(T, arena, "{s}: packing {s} twice gave different bytes", .{ m.name, file });
            if (p.bytes.len > plan_mod.max_file_bytes) return bad(T, arena, "{s} is {d} bytes; a package file is at most {d} bytes", .{ p.file_name, p.bytes.len, plan_mod.max_file_bytes });
            if (try metadataProblem(arena, in, self.paths)) |problem| return bad(T, arena, "{s}: {s}", .{ m.name, problem });
            try packs.append(p);
        }
        return .{ .ok = packs.items };
    }
};

// ---------------------------------------------------------------- registry

pub const Verdict = union(enum) {
    /// The registry does not have the version: every staged build is uploaded.
    upload,
    /// The registry has the version but not this build of it (an index into the member's staged builds): only that build is
    /// uploaded.
    add: usize,
    skip,
    refuse: []const u8,
};

/// The `state` of a version answer as the registry wrote it, for the one state this mopm does not know; "" when there is none.
fn rawState(arena: Allocator, body: []const u8) []const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return "";
    const object = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return switch (object.get("state") orelse return "") {
        .string => |text| text,
        else => "",
    };
}

/// What the registry says about the package `name` (a full name) at `version` against the staged `builds` (the member's files, one
/// build per compiler) and the `manifest_sha256` they carry, or why it could not be asked.
pub fn check(arena: Allocator, net: Net, api_v2_url: []const u8, name: []const u8, version: []const u8, builds: []const StagedBuild, manifest_sha256: []const u8) !Result(Verdict) {
    const full = core.names.split(name) orelse return bad(Verdict, arena, "'{s}' is not a full name <namespace>/<name>", .{name});
    const answer = v2.sendOnce(v2.GetVersion, arena, net, api_v2_url, null, .{ .namespace = full.namespace, .name = full.name, .version = version }) catch |e| {
        return bad(Verdict, arena, "cannot ask the registry about {s} {s}: {s}", .{ name, version, @errorName(e) });
    };
    if (answer.status == 404) {
        const e = try http.apiError(arena, answer);
        if (std.mem.eql(u8, e.code, "version_not_found") or std.mem.eql(u8, e.code, "package_not_found")) return .{ .ok = .upload };
    }
    if (!answer.ok()) {
        const e = try http.apiError(arena, answer);
        return bad(Verdict, arena, "the registry answered HTTP {d} about {s} {s}: {s}", .{ answer.status, name, version, e.message });
    }
    const v = v2.decode(v2.GetVersion, arena, answer.body) catch {
        return bad(Verdict, arena, "the registry's answer about {s} {s} is not a version", .{ name, version });
    };
    if (v.state == .tombstoned) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} was taken down by an administrator and its number is burned; bump the version", .{ name, version }) } };
    }
    if (v.state == .yanked) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is yanked{s}{s}; a yanked version cannot be published again, so bump the version", .{ name, version, if (v.yank_reason != null) ": " else "", v.yank_reason orelse "" }) } };
    }
    if (v.state != .published) {
        return bad(Verdict, arena, "the registry reports the state '{s}' for {s} {s}, which this mopm does not know", .{ rawState(arena, answer.body), name, version });
    }
    // Published: a build the version has must be the same files, byte for byte; a build it lacks is an add.
    const have = try versionBuilds(arena, v);
    var fresh = std.ArrayList(usize).init(arena);
    for (builds, 0..) |s, i| {
        const held = for (have) |h| {
            if (std.mem.eql(u8, h.build, s.build)) break h;
        } else {
            try fresh.append(i);
            continue;
        };
        for (s.packs) |p| {
            var same = false;
            for (held.files) |f| {
                if (std.mem.eql(u8, @tagName(f.subdir), p.subdir) and std.mem.eql(u8, f.filename, p.file_name) and std.mem.eql(u8, f.sha256, &p.sha256)) same = true;
            }
            if (!same) {
                return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published with different bytes ({s}/{s} is not what the registry holds); a published file is never replaced, so bump the version", .{ name, version, p.subdir, p.file_name }) } };
            }
        }
        if (held.files.len != s.packs.len) {
            return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published with {d} files and this stages {d} for {s}; a published file is never replaced, so bump the version", .{ name, version, held.files.len, s.packs.len, s.build }) } };
        }
    }
    if (fresh.items.len == 0) return .{ .ok = .skip };
    if (fresh.items.len > 1) {
        var list = std.ArrayList(u8).init(arena);
        for (fresh.items, 0..) |i, k| try list.writer().print("{s}{s}", .{ if (k > 0) ", " else "", builds[i].build });
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published and this stages {d} builds it does not have ({s}); the registry takes one Mojo build per publish, so stage one of them", .{ name, version, fresh.items.len, list.items }) } };
    }
    if (!std.mem.eql(u8, v.manifest_sha256, manifest_sha256)) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published, and the build {s} was built from other sources than the published version (the metadata differs: the registry's manifest_sha256 is {s}, this stages {s}); a build for another Mojo is added only to the same sources, so bump the version", .{ name, version, builds[fresh.items[0]].build, v.manifest_sha256, manifest_sha256 }) } };
    }
    return .{ .ok = .{ .add = fresh.items[0] } };
}

/// The builds of a version: `builds` of the registry's answer, or, from a registry that does not list them, its files as the one build
/// (named by the build string at the end of a file name, `mojo<compiler>_0`).
fn versionBuilds(arena: Allocator, v: v2.VersionDetail) Allocator.Error![]const v2.VersionBuild {
    if (v.builds) |b| return b;
    var name: []const u8 = "";
    if (v.files.len > 0) {
        const file = v.files[0].filename;
        const stem = if (std.mem.endsWith(u8, file, ".conda")) file[0 .. file.len - ".conda".len] else file;
        name = if (std.mem.lastIndexOfScalar(u8, stem, '-')) |dash| stem[dash + 1 ..] else stem;
    }
    const one = try arena.alloc(v2.VersionBuild, 1);
    one[0] = .{ .build = name, .requires_mojo = v.requires_mojo, .files = v.files };
    return one;
}

// ------------------------------------------------------------------- write

const PlanFile = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
const PlanMember = struct {
    name: []const u8,
    version: []const u8,
    action: []const u8,
    reason: ?[]const u8 = null,
    manifest_sha256: ?[]const u8 = null,
    files: ?[]const PlanFile = null,
    readme: ?[]const u8 = null,
};

/// A file of the staged directory: its path below it and its bytes. `plan.json` is the last.
const Write = struct { path: []const u8, bytes: []const u8 };

fn writeFileIn(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(path, bytes);
}

pub const skip_reason = "already published with these bytes";

pub const Run = struct {
    arena: Allocator,
    net: Net,
    console: *Console,
    /// The registry's version 2 API root (`api_v2_url`): the member's full name is in the path.
    api_v2_url: []const u8,
    flags: Flags,
};

/// The whole of `mopm stage` after the flags and the registry are resolved. Returns the exit status.
pub fn run(r: Run) !u8 {
    const arena = r.arena;
    const c = r.console;
    const root = std.fs.cwd().realpathAlloc(arena, r.flags.workspace_root) catch |e| {
        c.fail("--workspace-root {s}: {s}\n", .{ r.flags.workspace_root, @errorName(e) });
        return 1;
    };
    const members = switch (try discover(arena, root)) {
        .ok => |m| m,
        .bad => |why| {
            c.fail("{s}\n", .{why});
            return 1;
        },
    };
    if (try link(arena, members)) |why| {
        c.fail("{s}\n", .{why});
        return 1;
    }
    if (r.flags.packages.len == 0) {
        for (members) |m| {
            if (!m.m.package.publish) c.say("not staged {s} {s}: publish = false\n", .{ m.name, m.version });
        }
    }
    const sequence = switch (try order(arena, members, r.flags.packages)) {
        .ok => |s| s,
        .bad => |why| {
            c.fail("{s}\n", .{why});
            return 1;
        },
    };
    if (sequence.len > plan_mod.max_members) {
        c.fail("{d} members; a group has at most {d}\n", .{ sequence.len, plan_mod.max_members });
        return 1;
    }

    const builds = try buildsOf(arena, r.flags);
    var staged = std.ArrayList(Staged).init(arena);
    for (sequence) |i| {
        switch (try packMember(arena, members, members[i], builds)) {
            .ok => |s| {
                if (s.note) |n| c.fail("{s}\n", .{n});
                try staged.append(s);
            },
            .bad => |why| {
                c.fail("{s}\n", .{why});
                return 1;
            },
        }
    }

    var verdicts = std.ArrayList(Verdict).init(arena);
    for (staged.items) |s| {
        switch (try check(arena, r.net, r.api_v2_url, s.member.name, s.member.version, s.builds, &s.packs[0].manifest_sha256)) {
            .ok => |v| try verdicts.append(v),
            .bad => |why| {
                c.fail("{s}\n", .{why});
                return 1;
            },
        }
    }

    // The commit request carries the readme of every member to upload; a request too large for the registry is refused here,
    // before anything is written (the registry was asked only about the members, as above).
    var entries = std.ArrayList(plan_mod.CommitEntry).init(arena);
    for (staged.items, verdicts.items) |s, v| {
        if (v != .upload and v != .add) continue;
        try entries.append(.{ .name = s.member.name, .manifest_sha256 = &s.packs[0].manifest_sha256, .readme = if (v == .add) null else s.readme });
    }
    // A registry that takes the readmes as objects holds the commit request small, so it is asked only when the readmes are too
    // large to go inline.
    switch (try plan_mod.commitOf(arena, entries.items)) {
        .body => {},
        .bad => |why| {
            const objects = readmes.takesObjects(arena, r.net, r.api_v2_url) catch |e| {
                c.fail("GET /health: {s}; nothing was written\n", .{@errorName(e)});
                return 1;
            };
            if (!objects) {
                c.fail("{s}; nothing was written\n", .{why});
                c.note("{s}\n", .{readmes.inline_note});
                return 1;
            }
        },
    }

    // Everything is known: write. The old plan goes first, so a run that dies half way leaves no plan to publish.
    var out = std.fs.cwd().makeOpenPath(r.flags.out, .{}) catch |e| {
        c.fail("--out {s}: {s}\n", .{ r.flags.out, @errorName(e) });
        return 1;
    };
    defer out.close();
    out.deleteFile(plan_mod.plan_name) catch |e| if (e != error.FileNotFound) {
        c.fail("{s}/{s}: {s}\n", .{ r.flags.out, plan_mod.plan_name, @errorName(e) });
        return 1;
    };
    var members_out = std.ArrayList(PlanMember).init(arena);
    var writes = std.ArrayList(Write).init(arena);
    var refused: usize = 0;
    var uploads: usize = 0;
    var skips: usize = 0;
    for (staged.items, verdicts.items) |s, v| {
        const m = s.member;
        switch (v) {
            .skip => {
                skips += 1;
                try members_out.append(.{ .name = m.name, .version = m.version, .action = "skip", .reason = skip_reason });
                c.say("skip   {s} {s}: {s}\n", .{ m.name, m.version, skip_reason });
            },
            .refuse => |why| {
                refused += 1;
                try members_out.append(.{ .name = m.name, .version = m.version, .action = "refuse", .reason = why });
                c.fail("refused: {s}\n", .{why});
            },
            .upload, .add => {
                uploads += 1;
                // A new version goes up with every build; an add, with the one build the version lacks and no readme.
                const only: ?StagedBuild = if (v == .add) s.builds[v.add] else null;
                const packs = if (only) |b| b.packs else s.packs;
                var files = std.ArrayList(PlanFile).init(arena);
                for (packs) |p| {
                    try writes.append(.{ .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.subdir, p.file_name }), .bytes = p.bytes });
                    try files.append(.{ .subdir = p.subdir, .filename = p.file_name, .sha256 = try arena.dupe(u8, &p.sha256), .size = p.bytes.len });
                }
                var readme: ?[]const u8 = null;
                if (only == null) if (s.readme) |text| {
                    readme = try std.fmt.allocPrint(arena, "{s}/README.md", .{m.name});
                    try writes.append(.{ .path = readme.?, .bytes = text });
                };
                try members_out.append(.{
                    .name = m.name,
                    .version = m.version,
                    .action = "upload",
                    .manifest_sha256 = try arena.dupe(u8, &packs[0].manifest_sha256),
                    .files = files.items,
                    .readme = readme,
                });
                if (only) |b| {
                    var subdirs = std.ArrayList(u8).init(arena);
                    for (b.packs, 0..) |p, k| try subdirs.writer().print("{s}{s}", .{ if (k > 0) ", " else "", p.subdir });
                    c.say("add    {s} {s}: build {s} ({s})\n", .{ m.name, m.version, b.build, subdirs.items });
                } else {
                    c.say("upload {s} {s} ({d} files)\n", .{ m.name, m.version, files.items.len });
                }
            },
        }
    }
    var text = std.ArrayList(u8).init(arena);
    try std.json.stringify(.{ .version = @as(u32, 2), .members = members_out.items }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, text.writer());
    try text.append('\n');
    try writes.append(.{ .path = plan_mod.plan_name, .bytes = text.items });
    for (writes.items) |w| writeFileIn(out, w.path, w.bytes) catch |e| {
        c.fail("{s}/{s}: {s}\n", .{ r.flags.out, w.path, @errorName(e) });
        return 1;
    };
    c.say("staged {d} members in {s}: {d} to upload, {d} skipped, {d} refused\n", .{ staged.items.len, r.flags.out, uploads, skips, refused });
    if (refused > 0) {
        c.fail("the set is not publishable: 'mopm publish --staged' refuses a plan with a refused member\n", .{});
        return 1;
    }
    return 0;
}

pub fn main(arena: Allocator, args: []const []const u8, cli_version: []const u8) u8 {
    const flags = switch (parseFlags(arena, args) catch return 1) {
        .ok => |f| f,
        .bad => |why| {
            std.io.getStdErr().writer().print("mopm: {s}\n", .{why}) catch {};
            std.io.getStdErr().writeAll(usage) catch {};
            return 2;
        },
    };
    var console = Console.init(arena, Console.stdStreams);
    const base = switch (registry.resolve(flags.registry)) {
        .ok => |b| b,
        .bad => |why| {
            console.fail("--registry {s}: {s}\n", .{ flags.registry, why });
            return 1;
        },
    };
    const config = switch (registry.load(arena, base, cli_version) catch |e| {
        console.fail("{s}: {s}\n", .{ base, @errorName(e) });
        return 1;
    }) {
        .ok => |c| c,
        .bad => |why| {
            console.fail("{s}: {s}\n", .{ base, why });
            return 1;
        },
    };
    return run(.{ .arena = arena, .net = gp.realNet(), .console = &console, .api_v2_url = config.api_v2_url, .flags = flags }) catch |e| {
        console.fail("{s}\n", .{@errorName(e)});
        return 1;
    };
}
