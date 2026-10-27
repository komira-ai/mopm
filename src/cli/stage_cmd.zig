//! `mopm stage`: the members of a workspace, packed and checked against a registry, as a staged set
//! (spec/staged-set.md) that `mopm publish --staged` publishes.
//!
//!   mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version>
//!              --out <dir> --registry <prod|gamma|beta|url>
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
//! 3. Pack. The `.mojoc` of a member for a subdir is `<artifacts>/<subdir>/<name>.mojoc`; each subdir that has one is
//!    packed, with the path of every path dependency dropped and its version requirement kept (src/core/conda.zig).
//!    A member with `[native.<id>]` libraries also needs, per subdir, each one's static archive at
//!    `<artifacts>/<subdir>/<name>.native/<archive name>` (`lib<id>.a`, or the native's `soname`), packed as
//!    `mopm pack --native` packs it; one missing is refused, and `noarch` cannot hold natives.
//!    Every file is packed twice and the two must be the same bytes; the metadata inside must hold no URL, no lock
//!    entry and no path.
//! 4. Registry. `GET /packages/<name>/<version>` (no token) decides each member: not there, `upload`; published with
//!    the same files (same sha256s), `skip`; published with other bytes, yanked, or tombstoned (its number is burned),
//!    `refuse`.
//! 5. Write. `<out>/<subdir>/<file>.conda` for each upload member, its readme, and `plan.json` last, which a reader
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
const registry = core.registry;
const semver = core.semver;
const publish_cmd = @import("publish_cmd.zig");
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const Net = gp.Net;
const Console = gp.Console;

pub const usage =
    \\usage: mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version>
    \\                  --out <dir> --registry <prod|gamma|beta|url>
    \\
    \\  pack the members of the workspace under <dir> (the named packages and what they depend on, or all)
    \\  from <artifacts>/<subdir>/<name>.mojoc, check each version against the registry, and write the
    \\  staged set (spec/staged-set.md) to <out>. Reads no token. --registry is required: there is no default.
    \\
;

pub const Flags = struct {
    workspace_root: []const u8,
    packages: []const []const u8 = &.{},
    artifacts: []const u8,
    compiler: []const u8,
    out: []const u8,
    registry: []const u8,
};

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

pub fn parseFlags(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var root: ?[]const u8 = null;
    var artifacts: ?[]const u8 = null;
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
        const takes = [_]struct { []const u8, *?[]const u8 }{
            .{ "--workspace-root", &root },
            .{ "--artifacts", &artifacts },
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
    const need = [_]struct { []const u8, ?[]const u8 }{
        .{ "--workspace-root <dir>", root },
        .{ "--artifacts <dir>", artifacts },
        .{ "--compiler <exact mojo version>", compiler },
        .{ "--out <dir>", out },
    };
    for (need) |n| {
        if (n[1] == null) return .{ .bad = try std.fmt.allocPrint(arena, "{s} is required", .{n[0]}) };
    }
    if (reg == null) return .{ .bad = "--registry is required: there is no default, so a set is never checked against (and later published to) a registry by accident" };
    return .{ .ok = .{ .workspace_root = root.?, .packages = packages.items, .artifacts = artifacts.?, .compiler = compiler.?, .out = out.?, .registry = reg.? } };
}

// ----------------------------------------------------------------- members

pub const Member = struct {
    name: []const u8,
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
        try found.append(.{ .name = m.package.name, .version = m.package.version, .dir = dir, .m = m });
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
            if (std.mem.eql(u8, other.name, m.name)) {
                return bad([]Member, arena, "{s} and {s} are both the package {s}", .{ other.dir, m.dir, m.name });
            }
        }
    }
    return .{ .ok = found.items };
}

fn indexOfName(members: []const Member, name: []const u8) ?usize {
    for (members, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
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
                    const i = at orelse return try std.fmt.allocPrint(arena, "{s} depends on '{s}' at the path '{s}', which is not a member of the workspace", .{ m.name, d.name, p });
                    if (!std.mem.eql(u8, members[i].name, d.name)) {
                        return try std.fmt.allocPrint(arena, "{s} calls the package at '{s}' {s}, but it is {s}", .{ m.name, p, d.name, members[i].name });
                    }
                    if (d.requirement == null) return try std.fmt.allocPrint(arena, "{s}: " ++ conda.path_no_version_fmt, .{ m.name, d.name });
                    break :blk i;
                },
                .version => indexOfName(members, d.name) orelse continue,
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
                return try std.fmt.allocPrint(arena, "{s} requires {s} \"{s}\", but the workspace has {s} {s}; change the requirement or the version", .{ m.name, d.name, text, d.name, members[target].version });
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
        const i = indexOfName(members, n) orelse return bad([]const usize, arena, "{s} is not a member of the workspace", .{n});
        if (!members[i].m.package.publish) return bad([]const usize, arena, "{s} has publish = false in its mopm.toml, so it cannot be staged or published; remove the key to publish it", .{n});
        if (!wanted[i]) {
            wanted[i] = true;
            try stack.append(i);
        }
    }
    while (stack.popOrNull()) |i| {
        for (members[i].deps) |d| {
            if (!members[d].m.package.publish) {
                return bad([]const usize, arena, "{s} is staged for publishing but depends on {s}, which has publish = false; a published package cannot need one that is never published (a dev-dependency may)", .{ members[i].name, members[d].name });
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

pub const Staged = struct {
    member: Member,
    packs: []const conda.Packed,
    /// The readme text and its path below the staged directory, or null.
    readme: ?[]const u8 = null,
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

/// The directory of a member's native archives beside its `.mojoc`: `<artifacts>/<subdir>/<name>.native/<archive name>`,
/// where the archive name is `lib<id>.a` (or the `soname` of the `[native.<id>]`).
pub const native_dir_suffix = ".native";

/// Packs `m` from the artifacts, or the reason it cannot be.
pub fn packMember(arena: Allocator, members: []const Member, m: Member, artifacts: []const u8, compiler: []const u8) !Result(Staged) {
    const T = Staged;
    if (try publish_cmd.versionProblem(arena, m.version)) |p| return bad(T, arena, "{s}: {s}", .{ m.name, p });
    if (!conda.validCompiler(compiler)) return bad(T, arena, "--compiler {s}: an exact Mojo version is digits and dots, such as 1.0.0", .{compiler});
    var path_versions = std.ArrayList(conda.PathVersion).init(arena);
    var paths = std.ArrayList([]const u8).init(arena);
    for (m.m.dependencies) |d| {
        switch (d.source) {
            .path => |p| {
                try paths.append(p);
                const i = indexOfName(members, d.name) orelse continue;
                try path_versions.append(.{ .name = d.name, .version = members[i].version });
            },
            .version => {},
        }
    }
    var why: []const u8 = "";
    const deps = conda.depsOf(arena, m.m, path_versions.items, &why) catch |e| return if (e == error.Unpackable) try bad(T, arena, "{s}: {s}", .{ m.name, why }) else error.OutOfMemory;
    const native_deps = conda.nativeDepsOf(arena, m.m, &why) catch |e| return if (e == error.Unpackable) try bad(T, arena, "{s}: {s}", .{ m.name, why }) else error.OutOfMemory;
    // The packed dependencies on members are the edges, no more and no fewer.
    for (deps) |d| {
        const is_member = indexOfName(members, d.name) != null;
        var edge = false;
        for (m.deps) |e| edge = edge or std.mem.eql(u8, members[e].name, d.name);
        if (is_member != edge) return bad(T, arena, "{s}: the packed dependency on {s} is not the one the workspace has", .{ m.name, d.name });
    }

    var packs = std.ArrayList(conda.Packed).init(arena);
    for (conda.subdirs) |subdir| {
        const file = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.mojoc", .{ artifacts, subdir, m.name });
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
                const nfile = try std.fmt.allocPrint(arena, "{s}/{s}/{s}{s}/{s}", .{ artifacts, subdir, m.name, native_dir_suffix, archive_name });
                const nbytes = std.fs.cwd().readFileAlloc(arena, nfile, 1 << 30) catch |e| switch (e) {
                    error.FileNotFound => return bad(T, arena, "{s}: native library '{s}' has no archive for {s}: expected {s}", .{ m.name, n.id, subdir, nfile }),
                    else => return bad(T, arena, "{s}: {s}: {s}", .{ m.name, nfile, @errorName(e) }),
                };
                const native = conda.Native{ .id = n.id, .soname = archive_name, .needs = n.needs, .exclusive = n.exclusive, .archive = nbytes };
                if (try conda.nativeProblem(arena, native)) |why_not| return bad(T, arena, "{s}: {s}: {s}", .{ m.name, nfile, why_not });
                try natives.append(native);
            }
        }
        const in = conda.Input{ .name = m.name, .version = m.version, .compiler = compiler, .subdir = subdir, .deps = deps, .native_deps = native_deps, .mojoc = bytes, .natives = natives.items };
        const p = conda.pack(arena, in) catch |e| return bad(T, arena, "{s}: cannot pack {s}: {s}", .{ m.name, file, @errorName(e) });
        const again = conda.pack(arena, in) catch |e| return bad(T, arena, "{s}: cannot pack {s}: {s}", .{ m.name, file, @errorName(e) });
        if (!std.mem.eql(u8, p.bytes, again.bytes)) return bad(T, arena, "{s}: packing {s} twice gave different bytes", .{ m.name, file });
        if (p.bytes.len > plan_mod.max_file_bytes) return bad(T, arena, "{s} is {d} bytes; a package file is at most {d} bytes", .{ p.file_name, p.bytes.len, plan_mod.max_file_bytes });
        if (try metadataProblem(arena, in, paths.items)) |problem| return bad(T, arena, "{s}: {s}", .{ m.name, problem });
        try packs.append(p);
    }
    if (packs.items.len == 0) {
        return bad(T, arena, "{s} has no build artifact: expected {s}/<subdir>/{s}.mojoc for one of noarch, linux-64, linux-aarch64, osx-arm64", .{ m.name, artifacts, m.name });
    }
    var staged = Staged{ .member = m, .packs = packs.items };

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

// ---------------------------------------------------------------- registry

pub const Verdict = union(enum) { upload, skip, refuse: []const u8 };

const RegistryFile = struct { subdir: []const u8 = "", filename: []const u8 = "", sha256: []const u8 = "" };
const RegistryVersion = struct { state: []const u8 = "", yank_reason: ?[]const u8 = null, files: []const RegistryFile = &.{} };

/// What the registry says about `name` `version` against the files `packs`, or why it could not be asked.
pub fn check(arena: Allocator, net: Net, api_url: []const u8, name: []const u8, version: []const u8, packs: []const conda.Packed) !Result(Verdict) {
    const url = try std.fmt.allocPrint(arena, "{s}/packages/{s}/{s}", .{ api_url, name, version });
    const answer = net.vtable.request(net.ptr, arena, .GET, url, .{}) catch |e| {
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
    const v = std.json.parseFromSliceLeaky(RegistryVersion, arena, answer.body, .{ .ignore_unknown_fields = true }) catch {
        return bad(Verdict, arena, "the registry's answer about {s} {s} is not a version", .{ name, version });
    };
    if (std.mem.eql(u8, v.state, "tombstoned")) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} was taken down by an administrator and its number is burned; bump the version", .{ name, version }) } };
    }
    if (std.mem.eql(u8, v.state, "yanked")) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is yanked{s}{s}; a yanked version cannot be published again, so bump the version", .{ name, version, if (v.yank_reason != null) ": " else "", v.yank_reason orelse "" }) } };
    }
    if (!std.mem.eql(u8, v.state, "published")) {
        return bad(Verdict, arena, "the registry reports the state '{s}' for {s} {s}, which this mopm does not know", .{ v.state, name, version });
    }
    // Published: the same files, byte for byte, or another version's worth of bytes under this number.
    for (packs) |p| {
        var same = false;
        for (v.files) |f| {
            if (std.mem.eql(u8, f.subdir, p.subdir) and std.mem.eql(u8, f.filename, p.file_name) and std.mem.eql(u8, f.sha256, &p.sha256)) same = true;
        }
        if (!same) {
            return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published with different bytes ({s}/{s} is not what the registry holds); versions are immutable, so bump the version", .{ name, version, p.subdir, p.file_name }) } };
        }
    }
    if (v.files.len != packs.len) {
        return .{ .ok = .{ .refuse = try std.fmt.allocPrint(arena, "{s} {s} is already published with {d} files and this stages {d}; versions are immutable, so bump the version", .{ name, version, v.files.len, packs.len }) } };
    }
    return .{ .ok = .skip };
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
    /// The registry's API root.
    api_url: []const u8,
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

    var staged = std.ArrayList(Staged).init(arena);
    for (sequence) |i| {
        switch (try packMember(arena, members, members[i], r.flags.artifacts, r.flags.compiler)) {
            .ok => |s| try staged.append(s),
            .bad => |why| {
                c.fail("{s}\n", .{why});
                return 1;
            },
        }
    }

    var verdicts = std.ArrayList(Verdict).init(arena);
    for (staged.items) |s| {
        switch (try check(arena, r.net, r.api_url, s.member.name, s.member.version, s.packs)) {
            .ok => |v| try verdicts.append(v),
            .bad => |why| {
                c.fail("{s}\n", .{why});
                return 1;
            },
        }
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
            .upload => {
                uploads += 1;
                var files = std.ArrayList(PlanFile).init(arena);
                for (s.packs) |p| {
                    try writes.append(.{ .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.subdir, p.file_name }), .bytes = p.bytes });
                    try files.append(.{ .subdir = p.subdir, .filename = p.file_name, .sha256 = try arena.dupe(u8, &p.sha256), .size = p.bytes.len });
                }
                var readme: ?[]const u8 = null;
                if (s.readme) |text| {
                    readme = try std.fmt.allocPrint(arena, "{s}/README.md", .{m.name});
                    try writes.append(.{ .path = readme.?, .bytes = text });
                }
                try members_out.append(.{
                    .name = m.name,
                    .version = m.version,
                    .action = "upload",
                    .manifest_sha256 = try arena.dupe(u8, &s.packs[0].manifest_sha256),
                    .files = files.items,
                    .readme = readme,
                });
                c.say("upload {s} {s} ({d} files)\n", .{ m.name, m.version, files.items.len });
            },
        }
    }
    var text = std.ArrayList(u8).init(arena);
    try std.json.stringify(.{ .version = @as(u32, 1), .members = members_out.items }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, text.writer());
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
    return run(.{ .arena = arena, .net = gp.realNet(), .console = &console, .api_url = config.api_url, .flags = flags }) catch |e| {
        console.fail("{s}\n", .{@errorName(e)});
        return 1;
    };
}
