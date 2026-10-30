//! The unit graph (spec/unit-graph.md): what `mopm plan --unit-graph --locked`
//! prints and `mopm unit build` reads.
//!
//! One unit is one package (a library, compiled whole by `mojo precompile`),
//! one test file or one binary of a workspace member; a registry dependency is
//! a `prebuilt` unit (a `.conda` holding a `.mojoc`, fetched by url and
//! sha256, never compiled). `build` reads mopm.toml's manifest, the checked
//! lock and the member sources, and touches no network. The text `render`
//! prints is one fixed layout: the same inputs give the same bytes.
//!
//! The toolchain section is mopm's own pin: the Mojo closure (src/core/toolchain/
//! mojo-<version>-<subdir>.json, made from a pixi lock), the Zig that links
//! (zig-for-mojo-<version>.json) and a hash of both, `closure_sha256`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const closure = @import("closure.zig");
const install_plan = @import("install_plan.zig");
const test_harness = @import("test_harness.zig");
const resolve = @import("resolve.zig");
const semver = @import("semver.zig");
const metadata = @import("metadata.zig");
const native_files = @import("native_files.zig");
const lock_libs = @import("lock_libs.zig");
const conda = @import("conda.zig");
const native_link = @import("native_link.zig");

/// 2: a `native` unit, and a `built` entry (no `sha256`) in `natives`, for a workspace member's own native libraries.
pub const format_version: u32 = 2;

/// 3: a graph in which a `test` or `bin` unit has `loads`, and the graph's `system_libs` (spec/unit-graph.md). A
/// graph with no `loads` is format 2, byte for byte what mopm printed before they existed: a reader that did not
/// know `loads` would run such a test against the machine's libraries, so a graph that has them says 3.
pub const format_loads: u32 = 3;

/// 4: a `native` unit with `provided` (its archive is built by another rule, not compiled from `srcs`). A reader that
/// did not know `provided` would make an empty archive of a unit with no sources, so a graph that has one says 4. A
/// format 4 graph also has `system_libs` and `loads` exactly when a format 3 graph would.
pub const format_provided: u32 = 4;

/// 5: a unit with `link` (system libraries its final link adds, `-l<name>` after every archive). A reader that did not
/// know `link` would link without them and fail on the undefined symbols of a C++ archive, so a graph that has one says 5.
/// A format 5 graph also has `provided`, `system_libs` and `loads` exactly when a format 4 graph would.
pub const format_link: u32 = 5;

pub const Src = struct { path: []const u8, sha256: []const u8 };
/// A native library in a unit's dependency closure: pinned by `sha256`, from `package`. `kind`, `needs` and `exclusive`
/// are the package's declarations (the lock copies them); the unit's natives are in link order (see `orderNatives`).
pub const NativeRef = struct {
    id: []const u8,
    soname: []const u8,
    /// Empty for a `built` native: its archive is a product of this build, so no hash can be known before it.
    sha256: []const u8 = "",
    package: []const u8,
    kind: metadata.Kind = .shared,
    needs: []const []const u8 = &.{},
    exclusive: []const u8 = "",
    /// System libraries the package's metadata (or the manifest, for a built native) names for the final link.
    link: []const []const u8 = &.{},
    /// The id of the `native` unit (`native:<package>/<id>`) that builds this library, for a workspace member's own
    /// native; empty for a prebuilt one, which `sha256` pins.
    built: []const u8 = "",
};
/// A prebuilt unit's download: the `.conda` holding its `.mojoc`.
pub const Archive = struct { url: []const u8, sha256: []const u8, size: u64 };
pub const Profile = struct { opt: u32, assert: []const u8, debug: bool };

pub const Unit = struct {
    id: []const u8,
    package: []const u8,
    version: []const u8,
    /// `lib`, `test`, `bin`, `prebuilt` or `native`.
    kind: []const u8,
    /// lib: the package directory, relative to the workspace.
    root: []const u8 = "",
    /// native: the archive's file name.
    soname: []const u8 = "",
    /// native: the archive is built by another rule and given to the build; there are no sources to compile.
    provided: bool = false,
    srcs: []const Src = &.{},
    /// native: the headers, the flags (common, then per OS), the include directories (relative to the member) and
    /// the sonames of the libraries this one needs.
    hdrs: []const Src = &.{},
    cflags: []const []const u8 = &.{},
    cflags_by_os: manifest.OsFlags = .{},
    includes: []const []const u8 = &.{},
    needs: []const []const u8 = &.{},
    deps: []const []const u8 = &.{},
    natives: []const NativeRef = &.{},
    /// lib, test, bin, prebuilt: the system libraries the final link of the unit's `natives` adds, each once, as
    /// `-l<name>` after every archive: the `link` of those natives in link order, the first place of a name kept.
    link: []const []const u8 = &.{},
    /// test and bin: the conda names of the system libraries the unit loads at run time, run dependencies included,
    /// sorted; each is an entry of the graph's `system_libs`.
    loads: []const []const u8 = &.{},
    /// prebuilt: the `.conda` and the `.mojoc` inside it.
    artifact: ?Archive = null,
    mojoc: []const u8 = "",
    profile: ?Profile = null,
    outputs: []const []const u8 = &.{},
    key: []const u8 = "",
};

pub const ZigPin = struct { version: []const u8, url: []const u8, sha256: []const u8, size: u64 };
pub const Component = struct { name: []const u8, version: []const u8, url: []const u8, sha256: []const u8, size: u64 };

pub const Toolchain = struct {
    mojo: []const u8,
    subdir: []const u8,
    cc_target: []const u8,
    closure_sha256: []const u8,
    zig: ZigPin,
    components: []const Component,
};

/// A system library the lock pins for the graph's subdir: a conda package (lock_libs.Lib without `deps`).
pub const SystemLib = struct { name: []const u8, version: []const u8, build: []const u8, url: []const u8, sha256: []const u8, size: u64 };

pub const Graph = struct {
    unit_graph: u32 = format_version,
    /// `<name>@<version>` of the root package.
    package: []const u8,
    /// The consumer's Mojo version: the one every unit id names.
    mojo: []const u8,
    toolchain: Toolchain,
    /// Format 3 only: the lock's system libraries for this subdir, sorted by name.
    system_libs: []const SystemLib = &.{},
    units: []const Unit,

    pub fn find(self: Graph, id: []const u8) ?usize {
        for (self.units, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, id)) return i;
        }
        return null;
    }
};

pub fn parse(arena: Allocator, text: []const u8) !Graph {
    return std.json.parseFromSliceLeaky(Graph, arena, text, .{ .ignore_unknown_fields = true });
}

pub fn sha256Hex(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return arena.dupe(u8, &hex);
}

/// The units `idx` depends on, transitively, dependencies first, each once.
pub fn closureOf(arena: Allocator, g: Graph, idx: usize) error{ UnknownUnit, OutOfMemory }![]const usize {
    var out = std.ArrayList(usize).init(arena);
    const seen = try arena.alloc(bool, g.units.len);
    @memset(seen, false);
    try visitDeps(g, idx, seen, &out);
    return out.items;
}

fn visitDeps(g: Graph, at: usize, seen: []bool, out: *std.ArrayList(usize)) error{ UnknownUnit, OutOfMemory }!void {
    for (g.units[at].deps) |d| {
        const di = g.find(d) orelse return error.UnknownUnit;
        if (seen[di]) continue;
        seen[di] = true;
        try visitDeps(g, di, seen, out);
        try out.append(di);
    }
}

// ------------------------------------------------------------------ toolchain

/// A platform mopm pins a toolchain for: its closure, and the packages of it that
/// a unit graph lists as components (the linker's C runtime libraries exist in
/// the Linux closures only; macOS has none).
pub const Target = struct {
    subdir: []const u8,
    closure: []const u8,
    components: []const []const u8,
};

pub const targets = [_]Target{
    .{ .subdir = "linux-64", .closure = @embedFile("toolchain/mojo-1.0.0-linux-64.json"), .components = &.{ "mojo-compiler", "libgcc", "libstdcxx" } },
    .{ .subdir = "linux-aarch64", .closure = @embedFile("toolchain/mojo-1.0.0-linux-aarch64.json"), .components = &.{ "mojo-compiler", "libgcc", "libstdcxx" } },
    .{ .subdir = "osx-arm64", .closure = @embedFile("toolchain/mojo-1.0.0-osx-arm64.json"), .components = &.{"mojo-compiler"} },
};

const zig_pins_1_0_0 = @embedFile("toolchain/zig-for-mojo-1.0.0.json");

const ZigFile = struct {
    format: u32,
    mojo: []const u8,
    pins: []const struct { subdir: []const u8, cc_target: []const u8, zig: ZigPin },
};

pub const Refused = error{Refused};

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) (Refused || Allocator.Error) {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

/// The subdirs whose toolchain closure a version 2 lock records, for each Mojo version.
pub const lock_subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64" };

/// The Mojo versions and subdirs a unit graph can be made for.
pub const supported = "mojo 1.0.0 on linux-64, linux-aarch64 and osx-arm64";

/// mopm's pinned toolchain for `mojo` on `subdir`, or a refusal.
pub fn toolchainFor(arena: Allocator, mojo: []const u8, subdir: []const u8, why: *[]const u8) anyerror!Toolchain {
    var target: ?Target = null;
    for (targets) |t| {
        if (std.mem.eql(u8, t.subdir, subdir)) target = t;
    }
    if (!std.mem.eql(u8, mojo, "1.0.0") or target == null) {
        return refuse(arena, why, "mopm has no pinned toolchain for mojo {s} on {s} (it pins {s})", .{ mojo, subdir, supported });
    }
    const c = closure.parse(arena, target.?.closure) catch return error.BadPins;
    if (!std.mem.eql(u8, c.subdir, subdir)) return error.BadPins;
    const zf = std.json.parseFromSliceLeaky(ZigFile, arena, zig_pins_1_0_0, .{}) catch return error.BadPins;
    var zig_pin: ?ZigPin = null;
    var cc_target: []const u8 = "";
    for (zf.pins) |p| {
        if (std.mem.eql(u8, p.subdir, subdir)) {
            zig_pin = p.zig;
            cc_target = p.cc_target;
        }
    }
    const zig = zig_pin orelse return error.BadPins;

    var h = Sha256.init(.{});
    var line = std.ArrayList(u8).init(arena);
    try line.writer().print("mopm-toolchain 1\nmojo {s}\nsubdir {s}\n", .{ c.mojo, c.subdir });
    h.update(line.items);
    var comps = std.ArrayList(Component).init(arena);
    for (c.packages) |p| {
        line.clearRetainingCapacity();
        try line.writer().print("{s} {s} {s} {s}\n", .{ p.name, p.version, p.build, p.sha256 });
        h.update(line.items);
        var wanted = false;
        for (target.?.components) |n| wanted = wanted or std.mem.eql(u8, p.name, n);
        if (wanted) {
            try comps.append(.{ .name = p.name, .version = p.version, .url = try closure.urlOf(arena, c, p), .sha256 = p.sha256, .size = p.size });
        }
    }
    line.clearRetainingCapacity();
    try line.writer().print("zig {s} {s}\ncc_target {s}\n", .{ zig.version, zig.sha256, cc_target });
    h.update(line.items);
    var d: [32]u8 = undefined;
    h.final(&d);
    const hex = std.fmt.bytesToHex(d, .lower);
    if (comps.items.len != target.?.components.len) return error.BadPins;
    return .{
        .mojo = c.mojo,
        .subdir = c.subdir,
        .cc_target = cc_target,
        .closure_sha256 = try arena.dupe(u8, &hex),
        .zig = zig,
        .components = comps.items,
    };
}

// ---------------------------------------------------------------------- build

pub const Input = struct {
    /// The workspace directory: every path in the graph is relative to it.
    dir: []const u8,
    /// The root package's directory relative to `dir`, `/`-separated, without `.` or `..` ("" when it is `dir`). The
    /// path dependencies in `members` are relative to this directory; the graph's paths are relative to `dir`.
    pkg: []const u8 = "",
    m: manifest.Manifest,
    /// The path dependencies of the project at any depth (workspace members).
    members: []const install_plan.PathDep,
    l: lock.Lock,
    subdir: []const u8,
    /// The consumer's Mojo version (`#mojo<M>` of every unit id).
    mojo: []const u8,
    /// A toolchain other than mopm's pin for `mojo`; tests only.
    toolchain: ?Toolchain = null,
};

const Builder = struct {
    arena: Allocator,
    in: Input,
    why: *[]const u8,
    units: std.ArrayList(Unit),
    /// The natives a workspace member builds, by package name: what its units link (see `addNatives`).
    member_natives: std.StringHashMap([]const NativeRef),
    /// The conda names of the system libraries each package loads, by package name: a member's and the root's from
    /// their manifests, a registry package's from the lock's `loads`.
    own_loads: std.StringHashMap([]const []const u8),
    /// The lock's system libraries for this subdir, once `loadsPass` has run.
    libs: []const lock_libs.Lib = &.{},
    closure: []const u8 = "",

    fn fail(b: *Builder, comptime fmt: []const u8, args: anytype) (Refused || Allocator.Error) {
        return refuse(b.arena, b.why, fmt, args);
    }

    /// The entry for `name` in this subdir: a path dependency; else the
    /// registry version that has a build for the consumer's Mojo; else, when
    /// none has one, the newest version (the caller refuses it).
    fn lockEntry(b: *Builder, name: []const u8) ?lock.Package {
        var best: ?lock.Package = null;
        for (b.in.l.packages) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            if (p.source == .path) return p;
            if (!std.mem.eql(u8, p.subdir, b.in.subdir)) continue;
            if (lock.artifactFor(p, b.in.mojo) != null) return p;
            if (best == null) {
                best = p;
            } else {
                const x = resolve.semverOf(p.version);
                const y = resolve.semverOf(best.?.version);
                if (x != null and (y == null or semver.compare(x.?, y.?) == .gt)) best = p;
            }
        }
        return best;
    }

    fn base(b: *Builder, name: []const u8, version: []const u8) ![]const u8 {
        return std.fmt.allocPrint(b.arena, "{s}@{s}#mojo{s}", .{ name, version, b.in.mojo });
    }

    fn libId(b: *Builder, name: []const u8) !?[]const u8 {
        const p = b.lockEntry(name) orelse return null;
        return try std.fmt.allocPrint(b.arena, "{s}/lib", .{try b.base(p.name, p.version)});
    }

    fn join(b: *Builder, a: []const u8, c: []const u8) ![]const u8 {
        if (a.len == 0) return c;
        return std.fmt.allocPrint(b.arena, "{s}/{s}", .{ a, c });
    }

    fn readRel(b: *Builder, rel: []const u8) ![]u8 {
        const full = try std.fs.path.join(b.arena, &.{ b.in.dir, rel });
        return std.fs.cwd().readFileAlloc(b.arena, full, 64 << 20) catch |e| {
            return b.fail("cannot read {s}: {s}", .{ rel, @errorName(e) });
        };
    }

    fn src(b: *Builder, rel: []const u8) !Src {
        return .{ .path = rel, .sha256 = try sha256Hex(b.arena, try b.readRel(rel)) };
    }

    /// A member's directory must sit below the workspace: Buck2 inputs do.
    fn checkBelow(b: *Builder, what: []const u8, rel: []const u8) !void {
        return b.checkBelowWritten(what, rel, rel);
    }

    /// As `checkBelow`, for a path written in a manifest or lock as `written` that resolves to `rel`: the refusal
    /// shows the path as written, and the resolved one when it differs (`.` is the workspace itself).
    fn checkBelowWritten(b: *Builder, what: []const u8, written: []const u8, rel: []const u8) !void {
        if (rel.len == 0 or rel[0] == '/' or std.mem.eql(u8, rel, "..") or std.mem.startsWith(u8, rel, "../") or std.mem.indexOf(u8, rel, "/../") != null or std.mem.endsWith(u8, rel, "/..")) {
            const resolved = if (rel.len == 0) "." else rel;
            const shown = if (written.len == 0) "." else written;
            if (std.mem.eql(u8, shown, resolved)) {
                return b.fail("{s} is {s}, which is not below the workspace {s}; a unit graph takes members below the workspace only", .{ what, shown, b.in.dir });
            }
            return b.fail("{s} is {s} (resolves to {s}), which is not below the workspace {s}; a unit graph takes members below the workspace only", .{ what, shown, resolved, b.in.dir });
        }
    }

    /// `rel`, a path written in the manifest of the package at `owner` (relative to the workspace), as a path relative
    /// to the workspace. With the workspace at the root package (`in.pkg` empty) it is the plain join, as it always
    /// was; otherwise `.` and `..` are resolved, so that a path leaving the workspace shows as a leading `..`.
    fn fromWorkspace(b: *Builder, owner: []const u8, rel: []const u8) ![]const u8 {
        if (b.in.pkg.len == 0) return b.join(owner, rel);
        if (rel.len > 0 and rel[0] == '/') return rel;
        var parts = std.ArrayList([]const u8).init(b.arena);
        for ([_][]const u8{ owner, rel }) |text| {
            var it = std.mem.splitScalar(u8, text, '/');
            while (it.next()) |seg| {
                if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
                if (std.mem.eql(u8, seg, "..")) {
                    if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                        _ = parts.pop();
                        continue;
                    }
                }
                try parts.append(seg);
            }
        }
        return std.mem.join(b.arena, "/", parts.items);
    }

    /// The library or source `rel` of the package at `owner` must stay inside that package.
    fn checkInside(b: *Builder, what: []const u8, owner: []const u8, rel: []const u8) !void {
        if (owner.len == 0) return;
        if (rel.len > owner.len and std.mem.startsWith(u8, rel, owner) and rel[owner.len] == '/') return;
        return b.fail("{s} is {s}, which is not inside its package {s}", .{ what, rel, owner });
    }

    /// The `.mojo` files under `lib_rel` (relative to the workspace), sorted,
    /// without the test files of the package at `member_rel`.
    fn libSrcs(b: *Builder, member_rel: []const u8, lib_rel: []const u8) ![]const Src {
        const full = try std.fs.path.join(b.arena, &.{ b.in.dir, lib_rel });
        var dir = std.fs.cwd().openDir(full, .{ .iterate = true }) catch |e| {
            return b.fail("the library directory {s} cannot be read: {s}", .{ lib_rel, @errorName(e) });
        };
        defer dir.close();
        var out = std.ArrayList(Src).init(b.arena);
        var walker = try dir.walk(b.arena);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".mojo")) continue;
            if (std.mem.startsWith(u8, entry.path, ".") or std.mem.indexOf(u8, entry.path, "/.") != null) continue;
            const rel = try std.fmt.allocPrint(b.arena, "{s}/{s}", .{ lib_rel, entry.path });
            const in_member = if (member_rel.len == 0) rel else rel[member_rel.len + 1 ..];
            if (test_harness.isTestPath(in_member)) continue;
            try out.append(try b.src(rel));
        }
        std.mem.sort(Src, out.items, {}, Builder.lessSrc);
        if (out.items.len == 0) return b.fail("{s} holds no .mojo file", .{lib_rel});
        return out.items;
    }

    fn lessSrc(_: void, a: Src, c: Src) bool {
        return std.mem.lessThan(u8, a.path, c.path);
    }

    fn defaultLib(b: *Builder, m: manifest.Manifest, member_rel: []const u8) !?[]const u8 {
        const rel = m.targets.lib orelse try std.fmt.allocPrint(b.arena, "src/{s}", .{m.package.name});
        const lib_at = try b.fromWorkspace(member_rel, rel);
        const full = try std.fs.path.join(b.arena, &.{ b.in.dir, lib_at });
        var d = std.fs.cwd().openDir(full, .{}) catch return null;
        d.close();
        return lib_at;
    }

    fn lib_profile() Profile {
        return .{ .opt = 1, .assert = "all", .debug = false };
    }

    fn addLib(b: *Builder, m: manifest.Manifest, member_rel: []const u8, deps: []const []const u8, lib_rel: []const u8) !void {
        try b.units.append(.{
            .id = try std.fmt.allocPrint(b.arena, "{s}/lib", .{try b.base(m.package.name, m.package.version)}),
            .package = m.package.name,
            .version = m.package.version,
            .kind = "lib",
            .root = lib_rel,
            .srcs = try b.libSrcs(member_rel, lib_rel),
            .deps = deps,
            .profile = Builder.lib_profile(),
            .outputs = try b.arena.dupe([]const u8, &.{try std.fmt.allocPrint(b.arena, "{s}.mojoc", .{m.package.name})}),
        });
    }

    /// The files `patterns` of `[native.<id>]` `what` name below the member, as sources of the graph (paths relative
    /// to the workspace, sorted), or a refusal naming the pattern that matches nothing.
    fn nativeFiles(b: *Builder, file: []const u8, id: []const u8, what: []const u8, member_rel: []const u8, patterns: []const []const u8) ![]const Src {
        const root = try std.fs.path.join(b.arena, &.{ b.in.dir, member_rel });
        const found = try native_files.expand(b.arena, root, patterns);
        const files = switch (found) {
            .files => |f| f,
            .unmatched => |pat| return b.fail("{s}: {s} \"{s}\" of [native.{s}] matches no file", .{ file, what, pat, id }),
            .link => |pat| return b.fail("{s}: {s} \"{s}\" of [native.{s}] is a symbolic link or passes through one; a unit graph reads the files of the member itself", .{ file, what, pat, id }),
        };
        var out = std.ArrayList(Src).init(b.arena);
        for (files) |f| try out.append(try b.src(try b.join(member_rel, f)));
        return out.items;
    }

    /// A workspace member's own natives (`[native.<id>]` of its mopm.toml `file`): one `native` unit each, which the
    /// build system builds, and the entries that the member's units, and those of every package that depends on it,
    /// list in `natives` as `built`. Only a static archive made from `srcs` can be built; the others are refused,
    /// so that a native is never dropped from a graph without a word.
    fn addNatives(b: *Builder, m: manifest.Manifest, member_rel: []const u8, file: []const u8) !void {
        if (m.native.len == 0) return;
        var refs = std.ArrayList(NativeRef).init(b.arena);
        for (m.native) |n| {
            if (n.kind != .static) {
                return b.fail("{s}: [native.{s}] is kind = \"{s}\"; a unit graph builds a member's native as a static archive only (kind = \"static\")", .{ file, n.id, @tagName(n.kind) });
            }
            if (n.mode != .link) {
                return b.fail("{s}: [native.{s}] is mode = \"load\"; a static archive is linked, not loaded", .{ file, n.id });
            }
            if (n.srcs.len == 0 and !n.provided) {
                return b.fail("{s}: [native.{s}] has no srcs; a unit graph builds a member's native from its C sources (or give provided = true, if another rule builds the archive)", .{ file, n.id });
            }
            const soname = try n.archiveName(b.arena);
            const srcs = try b.nativeFiles(file, n.id, "srcs", member_rel, n.srcs);
            const hdrs = try b.nativeFiles(file, n.id, "hdrs", member_rel, n.hdrs);
            for (srcs) |s| {
                for (hdrs) |h| {
                    if (std.mem.eql(u8, s.path, h.path)) return b.fail("{s}: {s} is named by both srcs and hdrs of [native.{s}]", .{ file, s.path, n.id });
                }
            }
            const includes = if (n.includes.len > 0) n.includes else blk: {
                var rels = std.ArrayList([]const u8).init(b.arena);
                for (hdrs) |h| try rels.append(if (member_rel.len == 0) h.path else h.path[member_rel.len + 1 ..]);
                break :blk try native_files.dirsOf(b.arena, rels.items);
            };
            const id = try std.fmt.allocPrint(b.arena, "native:{s}/{s}", .{ m.package.name, n.id });
            try b.units.append(.{
                .id = id,
                .package = m.package.name,
                .version = m.package.version,
                .kind = "native",
                .soname = soname,
                .provided = n.provided,
                .srcs = srcs,
                .hdrs = hdrs,
                .cflags = n.cflags,
                .cflags_by_os = n.cflags_by_os,
                .includes = includes,
                .needs = n.needs,
                .outputs = try b.arena.dupe([]const u8, &.{soname}),
            });
            try refs.append(.{ .id = n.id, .soname = soname, .package = m.package.name, .kind = .static, .needs = n.needs, .exclusive = n.exclusive, .link = n.link, .built = id });
        }
        try b.member_natives.put(m.package.name, refs.items);
    }

    /// The unit ids of dependencies named in `names`, in order.
    fn depIds(b: *Builder, owner: []const u8, names: []const []const u8) ![]const []const u8 {
        var out = std.ArrayList([]const u8).init(b.arena);
        for (names) |n| {
            const id = (try b.libId(n)) orelse return b.fail("{s} needs {s}, which mopm.lock does not lock for {s}", .{ owner, n, b.in.subdir });
            try out.append(id);
        }
        return out.items;
    }

    fn visit(b: *Builder, name: []const u8, seen: *std.StringHashMap(void), todo: *std.ArrayList([]const u8)) !void {
        if (seen.contains(name)) return;
        try seen.put(name, {});
        const p = b.lockEntry(name) orelse return b.fail("{s} is not in mopm.lock for {s}", .{ name, b.in.subdir });
        const ids = try b.depIds(name, p.deps);
        for (p.deps) |d| try todo.append(d);
        if (p.source == .path) {
            const mp = try b.fromWorkspace(b.in.pkg, p.path);
            const what = try std.fmt.allocPrint(b.arena, "the path dependency {s}", .{name});
            try b.checkBelowWritten(what, p.path, mp);
            const file = try b.join(mp, "mopm.toml");
            const text = try b.readRel(file);
            var diag: manifest.Diagnostic = .{};
            const pm = manifest.parse(b.arena, text, &diag) catch |e| {
                return b.fail("{s}:{d}:{d}: {s}", .{ file, diag.pos.line, diag.pos.col, if (e == error.Invalid) diag.message else @errorName(e) });
            };
            try b.listsMojo(file, pm);
            try b.noteLoads(pm.package.name, pm.native_dependencies);
            const lib_rel = (try b.defaultLib(pm, mp)) orelse return b.fail("{s} has no library directory (src/{s} or [targets] lib)", .{ file, pm.package.name });
            try b.checkBelow("the library of a path dependency", lib_rel);
            try b.checkInside("the library of a path dependency", mp, lib_rel);
            try b.addLib(pm, mp, ids, lib_rel);
            try b.addNatives(pm, mp, file);
            return;
        }
        // A registry package: a prebuilt .mojoc for the consumer's Mojo,
        // pinned by the lock's sha256 of that build.
        const art = lock.artifactFor(p, b.in.mojo) orelse {
            const published = try lock.publishedFor(b.arena, p);
            return b.fail("{s}", .{try lock.noMojocMessage(b.arena, p.name, p.version, b.in.mojo, published)});
        };
        try b.units.append(.{
            .id = try std.fmt.allocPrint(b.arena, "{s}/lib", .{try b.base(p.name, p.version)}),
            .package = p.name,
            .version = p.version,
            .kind = "prebuilt",
            .deps = ids,
            .artifact = .{ .url = art.url, .sha256 = art.sha256, .size = art.size },
            .mojoc = try std.fmt.allocPrint(b.arena, "lib/mojo/{s}.mojoc", .{p.name}),
        });
        if (p.loads.len > 0) try b.own_loads.put(p.name, p.loads);
    }

    /// Records the libraries the package `package` loads, from the `[native-dependencies]` `deps` of its manifest:
    /// `mode = "load"` ones, as the conda packages that provide them.
    fn noteLoads(b: *Builder, package: []const u8, deps: []const manifest.NativeDep) !void {
        var out = std.ArrayList([]const u8).init(b.arena);
        for (deps) |d| {
            if (d.mode != .load) continue;
            const pkg = conda.condaPackageFor(d.name);
            var have = false;
            for (out.items) |o| have = have or std.mem.eql(u8, o, pkg);
            if (!have) try out.append(pkg);
        }
        if (out.items.len > 0) try b.own_loads.put(package, out.items);
    }

    /// Sets `loads` of every `test` and `bin` unit: the libraries its closure loads and what they need, from the
    /// lock's `system_libs` for this subdir. A lock with no `system_libs` at all was written before they existed:
    /// it gives no `loads`, and the graph is what it always was. A library any manifest or registry package of the
    /// project loads that the lock does not pin (a manifest changed since `mopm lock`) is refused.
    fn loadsPass(b: *Builder) !void {
        if (b.in.l.system_libs.len == 0) return;
        b.libs = lock_libs.libsFor(b.in.l.system_libs, b.in.subdir) orelse &[_]lock_libs.Lib{};
        var all = std.ArrayList([]const u8).init(b.arena);
        var values = b.own_loads.valueIterator();
        while (values.next()) |v| try all.appendSlice(v.*);
        var missing: []const u8 = "";
        _ = lock_libs.closureNames(b.arena, b.libs, all.items, &missing) catch |e| switch (e) {
            error.MissingLib => return b.fail("mopm.lock has no system library {s} for {s}; run 'mopm lock'", .{ missing, b.in.subdir }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        var index = std.StringHashMap(usize).init(b.arena);
        for (b.units.items, 0..) |u, i| try index.put(u.id, i);
        for (b.units.items, 0..) |start, i| {
            if (!(std.mem.eql(u8, start.kind, "test") or std.mem.eql(u8, start.kind, "bin"))) continue;
            var wanted = std.ArrayList([]const u8).init(b.arena);
            var seen = std.StringHashMap(void).init(b.arena);
            var todo = std.ArrayList(usize).init(b.arena);
            try todo.append(i);
            while (todo.popOrNull()) |at| {
                const u = b.units.items[at];
                if (seen.contains(u.id)) continue;
                try seen.put(u.id, {});
                if (b.own_loads.get(u.package)) |own| try wanted.appendSlice(own);
                for (u.deps) |d| try todo.append(index.get(d) orelse return b.fail("{s} depends on {s}, which is no unit", .{ u.id, d }));
            }
            if (wanted.items.len == 0) continue;
            b.units.items[i].loads = lock_libs.closureNames(b.arena, b.libs, wanted.items, &missing) catch |e| switch (e) {
                error.MissingLib => return b.fail("mopm.lock has no system library {s} for {s}; run 'mopm lock'", .{ missing, b.in.subdir }),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }

    /// A package builds for the consumer's Mojo only if its mopm.toml lists it.
    fn listsMojo(b: *Builder, what: []const u8, m: manifest.Manifest) !void {
        if (m.mojo.len == 0) return;
        for (m.mojo) |v| {
            if (std.mem.eql(u8, v, b.in.mojo)) return;
        }
        return b.fail("{s} lists mojo {s}, not {s}; add {s} to it, or build for one it lists", .{ what, try std.mem.join(b.arena, ", ", m.mojo), b.in.mojo, b.in.mojo });
    }

    fn natives(b: *Builder) !void {
        var index = std.StringHashMap(usize).init(b.arena);
        for (b.units.items, 0..) |u, i| try index.put(u.id, i);
        for (b.units.items, 0..) |start, i| {
            // A `native` unit is built, not linked: it lists no natives.
            if (std.mem.eql(u8, start.kind, "native")) continue;
            var found = std.ArrayList(NativeRef).init(b.arena);
            var seen = std.StringHashMap(void).init(b.arena);
            var todo = std.ArrayList(usize).init(b.arena);
            try todo.append(i);
            while (todo.popOrNull()) |at| {
                const u = b.units.items[at];
                if (seen.contains(u.id)) continue;
                try seen.put(u.id, {});
                if (std.mem.eql(u8, u.kind, "prebuilt")) {
                    const p = b.lockEntry(u.package).?;
                    for (p.native) |n| {
                        const sha = n.sha256 orelse return b.fail("{s} {s}: its native library {s} ({s}) has no sha256 in mopm.lock; a unit graph takes only pinned natives", .{ p.name, p.version, n.id, n.soname });
                        try found.append(.{ .id = n.id, .soname = n.soname, .sha256 = sha, .package = p.name, .kind = n.kind, .needs = n.needs, .exclusive = n.exclusive, .link = n.link });
                    }
                } else if (b.member_natives.get(u.package)) |built| {
                    // A member's lib, tests and binaries all link its natives; each is listed once.
                    for (built) |n| {
                        var have = false;
                        for (found.items) |f| have = have or std.mem.eql(u8, f.built, n.built);
                        if (!have) try found.append(n);
                    }
                }
                for (u.deps) |d| {
                    const di = index.get(d) orelse return b.fail("{s} depends on {s}, which is no unit", .{ u.id, d });
                    try todo.append(di);
                }
            }
            std.mem.sort(NativeRef, found.items, {}, Builder.lessNative);
            const ordered = try b.orderNatives(b.units.items[i].id, found.items);
            b.units.items[i].natives = ordered;
            var system = std.ArrayList([]const u8).init(b.arena);
            for (ordered) |n| try native_link.merge(&system, n.link);
            b.units.items[i].link = system.items;
        }
    }

    fn lessNative(_: void, a: NativeRef, c: NativeRef) bool {
        return std.mem.lessThan(u8, a.soname, c.soname);
    }

    /// The natives of unit `owner` in the order a linker wants them: a library before every library it `needs` (an
    /// archive's undefined symbols are looked for only in the archives after it), the sonames' order between
    /// libraries that do not constrain one another. `found` is sorted by soname. A static library that needs one no
    /// package in the closure ships, and libraries that need each other, are refused; a shared library resolves its
    /// needs at run time, so a need it names that is not here is not the graph's to judge.
    fn orderNatives(b: *Builder, owner: []const u8, found: []NativeRef) ![]const NativeRef {
        // One library of an exclusive group per closure: two would link, and keep two copies of the library's state.
        for (found, 0..) |n, i| {
            if (n.exclusive.len == 0) continue;
            for (found[i + 1 ..]) |m| {
                if (std.mem.eql(u8, n.exclusive, m.exclusive)) {
                    return b.fail("{s}: native libraries {s} of {s} and {s} of {s} are both in exclusive group {s}; a unit links one library of a group", .{ owner, n.soname, n.package, m.soname, m.package, n.exclusive });
                }
            }
        }
        // The natives directory holds one file per soname: a built archive cannot share its name with another library.
        for (found, 0..) |n, i| {
            for (found[i + 1 ..]) |m| {
                if ((n.built.len > 0 or m.built.len > 0) and std.mem.eql(u8, n.soname, m.soname)) {
                    return b.fail("{s}: native library {s} of {s} ({s}) and {s} of {s} ({s}) have one name; a unit links one library of a name", .{ owner, n.soname, n.package, n.id, m.soname, m.package, m.id });
                }
            }
        }
        for (found) |n| {
            for (n.needs) |need| {
                if (std.mem.eql(u8, need, n.soname)) return b.fail("{s}: native library {s} of {s} needs itself", .{ owner, n.soname, n.package });
            }
            if (n.kind != .static) continue;
            for (n.needs) |need| {
                var provided = false;
                for (found) |m| provided = provided or std.mem.eql(u8, m.soname, need);
                if (!provided) return b.fail("{s}: native library {s} of {s} needs {s}, which no package in its dependency closure ships", .{ owner, n.soname, n.package, need });
            }
        }
        const placed = try b.arena.alloc(bool, found.len);
        @memset(placed, false);
        var out = std.ArrayList(NativeRef).init(b.arena);
        while (out.items.len < found.len) {
            var next: ?usize = null;
            for (found, 0..) |cand, i| {
                if (placed[i]) continue;
                // A library some other library still to be placed needs must wait for it.
                var wanted = false;
                for (found, 0..) |other, j| {
                    if (j == i or placed[j]) continue;
                    for (other.needs) |need| wanted = wanted or std.mem.eql(u8, need, cand.soname);
                }
                if (!wanted) {
                    next = i;
                    break;
                }
            }
            const at = next orelse {
                var left = std.ArrayList(u8).init(b.arena);
                for (found, 0..) |n, i| {
                    if (placed[i]) continue;
                    if (left.items.len > 0) try left.appendSlice(", ");
                    try left.appendSlice(n.soname);
                }
                return b.fail("{s}: native libraries {s} need each other; a link order cannot put one before the other", .{ owner, left.items });
            };
            placed[at] = true;
            try out.append(found[at]);
        }
        return out.items;
    }

    /// `key`: sha256 of the unit's rendering (without key) and its deps' keys.
    fn keys(b: *Builder) !void {
        var index = std.StringHashMap(usize).init(b.arena);
        for (b.units.items, 0..) |u, i| try index.put(u.id, i);
        const state = try b.arena.alloc(u8, b.units.items.len);
        @memset(state, 0);
        for (b.units.items, 0..) |_, i| try b.keyOf(i, &index, state);
    }

    fn keyOf(b: *Builder, i: usize, index: *std.StringHashMap(usize), state: []u8) error{ Refused, OutOfMemory }!void {
        if (state[i] == 2) return;
        if (state[i] == 1) return b.fail("dependency cycle at {s}", .{b.units.items[i].id});
        state[i] = 1;
        var h = Sha256.init(.{});
        var buf = std.ArrayList(u8).init(b.arena);
        try writeUnit(buf.writer(), b.units.items[i], "    ");
        h.update("toolchain ");
        h.update(b.closure);
        h.update("\n");
        h.update(buf.items);
        for (b.units.items[i].deps) |d| {
            const di = index.get(d) orelse return b.fail("{s} depends on {s}, which is no unit", .{ b.units.items[i].id, d });
            try b.keyOf(di, index, state);
            h.update("\n");
            h.update(b.units.items[di].key);
        }
        // A built archive is linked into this unit: when its sources, headers or flags change, so does the result.
        for (b.units.items[i].natives) |n| {
            if (n.built.len == 0) continue;
            const ni =index.get(n.built) orelse return b.fail("{s} links {s}, which is no unit", .{ b.units.items[i].id, n.built });
            try b.keyOf(ni, index, state);
            h.update("\nnative ");
            h.update(b.units.items[ni].key);
        }
        // The names in `loads` do not move when a pin does: the bytes of each library are part of the key.
        for (b.units.items[i].loads) |n| {
            const lib = lock_libs.find(b.libs, n) orelse continue;
            h.update("\nsystem_lib ");
            h.update(lib.name);
            h.update(" ");
            h.update(lib.sha256);
        }
        var d: [32]u8 = undefined;
        h.final(&d);
        const hex = std.fmt.bytesToHex(d, .lower);
        b.units.items[i].key = try b.arena.dupe(u8, &hex);
        state[i] = 2;
    }

    fn lessUnit(_: void, a: Unit, c: Unit) bool {
        return std.mem.lessThan(u8, a.id, c.id);
    }
};

/// The unit graph of the project: a refusal (`error.Refused`, `why` set) when
/// the lock, the toolchain or the sources cannot make one. Reads the member
/// sources below `in.dir`; no network, no run of any program.
pub fn build(arena: Allocator, in: Input, why: *[]const u8) !Graph {
    var b = Builder{ .arena = arena, .in = in, .why = why, .units = std.ArrayList(Unit).init(arena), .member_natives = std.StringHashMap([]const NativeRef).init(arena), .own_loads = std.StringHashMap([]const []const u8).init(arena) };
    const tc = if (in.toolchain) |t| t else toolchainFor(arena, in.mojo, in.subdir, why) catch |e| switch (e) {
        error.BadPins => return refuse(arena, why, "the toolchain pins compiled into this mopm are unreadable", .{}),
        else => |x| return x,
    };
    b.closure = tc.closure_sha256;
    if (in.l.mojos.len > 0) {
        var locked = false;
        for (in.l.mojos) |v| locked = locked or std.mem.eql(u8, v, in.mojo);
        if (!locked) {
            return refuse(arena, why, "mopm.lock is not locked for mojo {s} (it locks {s}); run 'mopm lock'", .{ in.mojo, try std.mem.join(arena, ", ", in.l.mojos) });
        }
        for (in.l.closures) |c| {
            if (std.mem.eql(u8, c.mojo, in.mojo) and std.mem.eql(u8, c.subdir, in.subdir) and !std.mem.eql(u8, c.sha256, tc.closure_sha256)) {
                return refuse(arena, why, "mopm.lock records toolchain closure {s} for mojo {s} on {s}, but this mopm pins {s}; run 'mopm lock'", .{ c.sha256, in.mojo, in.subdir, tc.closure_sha256 });
            }
        }
    }
    const m = in.m;
    try b.listsMojo("mopm.toml", m);
    const root_id = try b.base(m.package.name, m.package.version);

    // The root package's dependency names, in manifest order.
    var dep_names = std.ArrayList([]const u8).init(arena);
    for (m.dependencies) |d| try dep_names.append(d.name);
    var dev_names = std.ArrayList([]const u8).init(arena);
    for (m.dev_dependencies) |d| try dev_names.append(d.name);

    var seen = std.StringHashMap(void).init(arena);
    var todo = std.ArrayList([]const u8).init(arena);
    for (dep_names.items) |n| try todo.append(n);
    for (dev_names.items) |n| try todo.append(n);
    while (todo.popOrNull()) |n| try b.visit(n, &seen, &todo);

    try b.noteLoads(m.package.name, m.native_dependencies);
    const dep_ids = try b.depIds(root_id, dep_names.items);
    const dev_ids = try b.depIds(root_id, dev_names.items);

    // The root package: its library, its binaries, its tests.
    const lib_rel = try b.defaultLib(m, in.pkg);
    var lib_id: ?[]const u8 = null;
    if (lib_rel) |lr| {
        try b.checkBelow("the library of the root package", lr);
        try b.checkInside("the library of the root package", in.pkg, lr);
        try b.addLib(m, in.pkg, dep_ids, lr);
        lib_id = b.units.items[b.units.items.len - 1].id;
    }
    try b.addNatives(m, in.pkg, try b.join(in.pkg, "mopm.toml"));
    var bin_deps = std.ArrayList([]const u8).init(arena);
    if (lib_id) |id| try bin_deps.append(id) else try bin_deps.appendSlice(dep_ids);
    for (m.targets.bins) |bin| {
        const bin_at = try b.fromWorkspace(in.pkg, bin.path);
        try b.checkBelow("a binary's source", bin_at);
        try b.checkInside("a binary's source", in.pkg, bin_at);
        try b.units.append(.{
            .id = try std.fmt.allocPrint(arena, "{s}/bin:{s}", .{ root_id, bin.name }),
            .package = m.package.name,
            .version = m.package.version,
            .kind = "bin",
            .srcs = try arena.dupe(Src, &.{try b.src(bin_at)}),
            .deps = bin_deps.items,
            .profile = .{ .opt = 3, .assert = "none", .debug = false },
            .outputs = try arena.dupe([]const u8, &.{bin.name}),
        });
    }
    var test_deps = std.ArrayList([]const u8).init(arena);
    try test_deps.appendSlice(bin_deps.items);
    for (dev_ids) |d| {
        var have = false;
        for (test_deps.items) |t| have = have or std.mem.eql(u8, t, d);
        if (!have) try test_deps.append(d);
    }
    // The root package's tests are found in the package directory, whatever the workspace; the unit names them by
    // their path from the workspace.
    const files = try test_harness.findTestFiles(arena, try std.fs.path.join(arena, &.{ in.dir, in.pkg }));
    for (files) |f| {
        const stem = std.fs.path.stem(f);
        const test_at = try b.join(in.pkg, f);
        try b.units.append(.{
            .id = try std.fmt.allocPrint(arena, "{s}/test:{s}", .{ root_id, test_at }),
            .package = m.package.name,
            .version = m.package.version,
            .kind = "test",
            .srcs = try arena.dupe(Src, &.{try b.src(test_at)}),
            .deps = test_deps.items,
            .profile = Builder.lib_profile(),
            .outputs = try arena.dupe([]const u8, &.{try std.fmt.allocPrint(arena, "{s}.pass", .{stem})}),
        });
    }

    // Two library units may not share a package name: the import path is by name.
    for (b.units.items, 0..) |u, i| {
        if (!(std.mem.eql(u8, u.kind, "lib") or std.mem.eql(u8, u.kind, "prebuilt"))) continue;
        for (b.units.items[0..i]) |v| {
            if ((std.mem.eql(u8, v.kind, "lib") or std.mem.eql(u8, v.kind, "prebuilt")) and std.mem.eql(u8, v.package, u.package)) {
                return refuse(arena, why, "two versions of {s} are in the graph ({s} and {s}); a package is imported by name, so one version is allowed", .{ u.package, v.version, u.version });
            }
        }
    }
    std.mem.sort(Unit, b.units.items, {}, Builder.lessUnit);
    try b.natives();
    try b.loadsPass();
    try b.keys();
    var with_loads = false;
    var with_provided = false;
    var with_link = false;
    for (b.units.items) |u| {
        with_loads = with_loads or u.loads.len > 0;
        with_provided = with_provided or u.provided;
        with_link = with_link or u.link.len > 0;
    }
    var libs: []const SystemLib = &.{};
    if (with_loads) {
        const out = try arena.alloc(SystemLib, b.libs.len);
        for (b.libs, 0..) |l, i| out[i] = .{ .name = l.name, .version = l.version, .build = l.build, .url = l.url, .sha256 = l.sha256, .size = l.size };
        libs = out;
    }
    return .{
        .unit_graph = if (with_link) format_link else if (with_provided) format_provided else if (with_loads) format_loads else format_version,
        .package = try std.fmt.allocPrint(arena, "{s}@{s}", .{ m.package.name, m.package.version }),
        .mojo = in.mojo,
        .toolchain = tc,
        .system_libs = libs,
        .units = b.units.items,
    };
}

// --------------------------------------------------------------------- render

fn str(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

fn strList(w: anytype, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try str(w, s);
    }
    try w.writeAll("]");
}

/// `"<key>": [{"path": ..., "sha256": ...}, ...]` on its own lines (after a comma); nothing for no sources.
fn srcList(w: anytype, ind: []const u8, key: []const u8, items: []const Src) !void {
    if (items.len == 0) return;
    try w.print(",\n{s}  \"{s}\": [", .{ ind, key });
    for (items, 0..) |s, i| {
        try w.print("{s}\n{s}    {{\"path\": ", .{ if (i == 0) "" else ",", ind });
        try str(w, s.path);
        try w.writeAll(", \"sha256\": ");
        try str(w, s.sha256);
        try w.writeAll("}");
    }
    try w.print("\n{s}  ]", .{ind});
}

/// One unit as an object, indented by `ind` (the object's own indent); the
/// key is printed only when set.
pub fn writeUnit(w: anytype, u: Unit, ind: []const u8) !void {
    try w.print("{s}{{\n{s}  \"id\": ", .{ ind, ind });
    try str(w, u.id);
    try w.print(",\n{s}  \"package\": ", .{ind});
    try str(w, u.package);
    try w.print(",\n{s}  \"version\": ", .{ind});
    try str(w, u.version);
    try w.print(",\n{s}  \"kind\": ", .{ind});
    try str(w, u.kind);
    if (std.mem.eql(u8, u.kind, "lib")) {
        try w.print(",\n{s}  \"root\": ", .{ind});
        try str(w, u.root);
    }
    const is_native = std.mem.eql(u8, u.kind, "native");
    if (is_native) {
        try w.print(",\n{s}  \"soname\": ", .{ind});
        try str(w, u.soname);
        if (u.provided) try w.print(",\n{s}  \"provided\": true", .{ind});
    }
    try srcList(w, ind, "srcs", u.srcs);
    if (is_native) {
        try srcList(w, ind, "hdrs", u.hdrs);
        if (u.cflags.len > 0) {
            try w.print(",\n{s}  \"cflags\": ", .{ind});
            try strList(w, u.cflags);
        }
        if (u.cflags_by_os.linux.len > 0 or u.cflags_by_os.macos.len > 0) {
            try w.print(",\n{s}  \"cflags_by_os\": {{", .{ind});
            if (u.cflags_by_os.linux.len > 0) {
                try w.writeAll("\"linux\": ");
                try strList(w, u.cflags_by_os.linux);
            }
            if (u.cflags_by_os.macos.len > 0) {
                if (u.cflags_by_os.linux.len > 0) try w.writeAll(", ");
                try w.writeAll("\"macos\": ");
                try strList(w, u.cflags_by_os.macos);
            }
            try w.writeAll("}");
        }
        if (u.includes.len > 0) {
            try w.print(",\n{s}  \"includes\": ", .{ind});
            try strList(w, u.includes);
        }
        if (u.needs.len > 0) {
            try w.print(",\n{s}  \"needs\": ", .{ind});
            try strList(w, u.needs);
        }
    }
    if (u.artifact) |c| {
        try w.print(",\n{s}  \"artifact\": {{\"url\": ", .{ind});
        try str(w, c.url);
        try w.writeAll(", \"sha256\": ");
        try str(w, c.sha256);
        try w.print(", \"size\": {d}}},\n{s}  \"mojoc\": ", .{ c.size, ind });
        try str(w, u.mojoc);
    }
    try w.print(",\n{s}  \"deps\": ", .{ind});
    try strList(w, u.deps);
    try w.print(",\n{s}  \"natives\": [", .{ind});
    for (u.natives, 0..) |n, i| {
        try w.print("{s}\n{s}    {{\"id\": ", .{ if (i == 0) "" else ",", ind });
        try str(w, n.id);
        try w.writeAll(", \"soname\": ");
        try str(w, n.soname);
        if (n.sha256.len > 0) {
            try w.writeAll(", \"sha256\": ");
            try str(w, n.sha256);
        }
        try w.writeAll(", \"package\": ");
        try str(w, n.package);
        // Left out when they are what a lock written before them means, so such a graph (and each key) is what it was.
        if (n.kind != .shared) try w.print(", \"kind\": \"{s}\"", .{@tagName(n.kind)});
        if (n.needs.len > 0) {
            try w.writeAll(", \"needs\": ");
            try strList(w, n.needs);
        }
        if (n.exclusive.len > 0) {
            try w.writeAll(", \"exclusive\": ");
            try str(w, n.exclusive);
        }
        if (n.built.len > 0) {
            try w.writeAll(", \"built\": ");
            try str(w, n.built);
        }
        try w.writeAll("}");
    }
    if (u.natives.len == 0) try w.writeAll("]") else try w.print("\n{s}  ]", .{ind});
    if (u.link.len > 0) {
        try w.print(",\n{s}  \"link\": ", .{ind});
        try strList(w, u.link);
    }
    if (u.loads.len > 0) {
        try w.print(",\n{s}  \"loads\": ", .{ind});
        try strList(w, u.loads);
    }
    if (u.profile) |p| {
        try w.print(",\n{s}  \"profile\": {{\"opt\": {d}, \"assert\": ", .{ ind, p.opt });
        try str(w, p.assert);
        try w.print(", \"debug\": {s}}}", .{if (p.debug) "true" else "false"});
    }
    if (u.outputs.len > 0) {
        try w.print(",\n{s}  \"outputs\": ", .{ind});
        try strList(w, u.outputs);
    }
    if (u.key.len > 0) {
        try w.print(",\n{s}  \"key\": ", .{ind});
        try str(w, u.key);
    }
    try w.print("\n{s}}}", .{ind});
}

pub fn render(arena: Allocator, g: Graph) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.print("{{\n  \"unit_graph\": {d},\n  \"package\": ", .{g.unit_graph});
    try str(w, g.package);
    try w.writeAll(",\n  \"mojo\": ");
    try str(w, g.mojo);
    const t = g.toolchain;
    try w.writeAll(",\n  \"toolchain\": {\n    \"mojo\": ");
    try str(w, t.mojo);
    try w.writeAll(",\n    \"subdir\": ");
    try str(w, t.subdir);
    try w.writeAll(",\n    \"cc_target\": ");
    try str(w, t.cc_target);
    try w.writeAll(",\n    \"closure_sha256\": ");
    try str(w, t.closure_sha256);
    try w.writeAll(",\n    \"zig\": {\"version\": ");
    try str(w, t.zig.version);
    try w.writeAll(", \"url\": ");
    try str(w, t.zig.url);
    try w.writeAll(", \"sha256\": ");
    try str(w, t.zig.sha256);
    try w.print(", \"size\": {d}}},\n    \"components\": [", .{t.zig.size});
    for (t.components, 0..) |c, i| {
        try w.print("{s}\n      {{\"name\": ", .{if (i == 0) "" else ","});
        try str(w, c.name);
        try w.writeAll(", \"version\": ");
        try str(w, c.version);
        try w.writeAll(", \"url\": ");
        try str(w, c.url);
        try w.writeAll(", \"sha256\": ");
        try str(w, c.sha256);
        try w.print(", \"size\": {d}}}", .{c.size});
    }
    try w.writeAll("\n    ]\n  }");
    if (g.system_libs.len > 0) {
        try w.writeAll(",\n  \"system_libs\": [");
        for (g.system_libs, 0..) |l, i| {
            try w.print("{s}\n    {{\"name\": ", .{if (i == 0) "" else ","});
            try str(w, l.name);
            try w.writeAll(", \"version\": ");
            try str(w, l.version);
            try w.writeAll(", \"build\": ");
            try str(w, l.build);
            try w.writeAll(", \"url\": ");
            try str(w, l.url);
            try w.writeAll(", \"sha256\": ");
            try str(w, l.sha256);
            try w.print(", \"size\": {d}}}", .{l.size});
        }
        try w.writeAll("\n  ]");
    }
    try w.writeAll(",\n  \"units\": [");
    for (g.units, 0..) |u, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try writeUnit(w, u, "    ");
    }
    try w.writeAll(if (g.units.len == 0) "]\n}\n" else "\n  ]\n}\n");
    return out.items;
}

// ---------------------------------------------------------------------- tests

const install = @import("install.zig");

const test_hex_a = "a" ** 64;
const test_hex_b = "b" ** 64;
const test_hex_c = "c" ** 64;
const test_hex_d = "d" ** 64;

/// The fixture's native library bytes and their sha256.
const native_bytes = "ELF-stand-in\n";
const native_sha = "348e8aa89787ad18546c8d63acb1b223332611eb25829fb6a451253f7aa8649a";

const app_init = "from http_core import get\nfrom util import hello\n";
const app_init_changed = "from http_core import get\nfrom util import hello\n\ndef run():\n    pass\n";
const test_app = "from app import run\n\ndef main():\n    run()\n";
const util_init = "def hello():\n    pass\n";

const toml_app = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\", \"1.1.0\"]\n\n[dependencies]\n";
const toml_util_dep = "util = { path = \"util\" }\n";
const toml_core_dep = "http_core = \"1.2\"\n";
const toml_util = "[package]\nname = \"util\"\nversion = \"0.3.0\"\nmojo = [\"1.0.0\", \"1.1.0\"]\n";

/// The lock of the fixture: http_core 1.2.5 built for both Mojo versions, util a member.
const lock_two =
    \\{
    \\  "lock_version": 2,
    \\  "mojo": ["1.0.0", "1.1.0"],
    \\  "toolchain": {"1.0.0": {"linux-64": "@C@"}, "1.1.0": {"linux-64": "@D@"}},
    \\  "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    {"name": "http_core", "version": "1.2.5", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "artifacts": {
    \\       "1.0.0": {"build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "@A@", "size": 1000},
    \\       "1.1.0": {"build": "mojo1.1.0_0", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.1.0_0.conda", "sha256": "@B@", "size": 1100}},
    \\     "native": [{"id": "z", "soname": "libz_native.so.1", "sha256": "@N@"}]},
    \\    {"name": "util", "version": "0.3.0", "source": "path", "path": "util"}
    \\  ]
    \\}
    \\
;

/// The same, with http_core built for Mojo 1.0.0 only (the version 2 lock still lists both).
const lock_one_build =
    \\{
    \\  "lock_version": 2,
    \\  "mojo": ["1.0.0", "1.1.0"],
    \\  "toolchain": {"1.0.0": {"linux-64": "@C@"}, "1.1.0": {"linux-64": "@D@"}},
    \\  "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    {"name": "http_core", "version": "1.2.5", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "artifacts": {
    \\       "1.0.0": {"build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "@A@", "size": 1000}}},
    \\    {"name": "util", "version": "0.3.0", "source": "path", "path": "util"}
    \\  ]
    \\}
    \\
;

/// A version 1 lock: one Mojo version, http_core's flat entry.
const lock_v1 =
    \\{
    \\  "lock_version": 1,
    \\  "toolchain": {"mojo": "1.0.0"},
    \\  "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    {"name": "http_core", "version": "1.2.5", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "@A@", "size": 1000, "mojo": "1.0.0"},
    \\    {"name": "util", "version": "0.3.0", "source": "path", "path": "util"}
    \\  ]
    \\}
    \\
;

fn fill(a: Allocator, template: []const u8) ![]const u8 {
    const pairs = [_][2][]const u8{
        .{ "@A@", test_hex_a }, .{ "@B@", test_hex_b }, .{ "@C@", test_hex_c }, .{ "@D@", test_hex_d }, .{ "@N@", native_sha },
    };
    var text: []const u8 = template;
    for (pairs) |pair| text = try std.mem.replaceOwned(u8, a, text, pair[0], pair[1]);
    return text;
}

fn put(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, bytes);
}

/// The fixture workspace: app (root), util (member), the sources and tests.
fn writeWorkspace(dir: std.fs.Dir, app_src: []const u8) !void {
    try put(dir, "src/app/__init__.mojo", app_src);
    try put(dir, "tests/test_app.mojo", test_app);
    try put(dir, "util/mopm.toml", toml_util);
    try put(dir, "util/src/util/__init__.mojo", util_init);
}

fn fakeToolchain(mojo: []const u8) Toolchain {
    return .{
        .mojo = mojo,
        .subdir = "linux-64",
        .cc_target = "x86_64-linux-gnu.2.34",
        .closure_sha256 = if (std.mem.eql(u8, mojo, "1.1.0")) test_hex_d else test_hex_c,
        .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig.tar.xz", .sha256 = "f" ** 64, .size = 1 },
        .components = &.{},
    };
}

const members = [_]install_plan.PathDep{.{ .name = "util", .version = "0.3.0", .path = "util" }};

fn graphOf(a: Allocator, dir: []const u8, deps_toml: []const u8, lock_template: []const u8, mojo: []const u8, why: *[]const u8) !Graph {
    return graphOfIn(a, dir, deps_toml, lock_template, mojo, "linux-64", why);
}

/// As `graphOf`, for the packages of `subdir`.
fn graphOfIn(a: Allocator, dir: []const u8, deps_toml: []const u8, lock_template: []const u8, mojo: []const u8, subdir: []const u8, why: *[]const u8) !Graph {
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ toml_app, deps_toml }), &diag);
    const l = try lock.parse(a, try fill(a, lock_template), why);
    return build(a, .{
        .dir = dir,
        .m = m,
        .members = &members,
        .l = l,
        .subdir = subdir,
        .mojo = mojo,
        .toolchain = fakeToolchain(mojo),
    }, why);
}

fn keyOfId(g: Graph, id: []const u8) ![]const u8 {
    return g.units[g.find(id) orelse return error.NoSuchUnit].key;
}

const id_app = "app@1.0.0#mojo1.0.0/lib";
const id_test = "app@1.0.0#mojo1.0.0/test:tests/test_app.mojo";
const id_core = "http_core@1.2.5#mojo1.0.0/lib";
const id_util = "util@0.3.0#mojo1.0.0/lib";

const golden_1_0_0 =
    \\{
    \\  "unit_graph": 2,
    \\  "package": "app@1.0.0",
    \\  "mojo": "1.0.0",
    \\  "toolchain": {
    \\    "mojo": "1.0.0",
    \\    "subdir": "linux-64",
    \\    "cc_target": "x86_64-linux-gnu.2.34",
    \\    "closure_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    \\    "zig": {"version": "0.12.0", "url": "https://example.invalid/zig.tar.xz", "sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "size": 1},
    \\    "components": [
    \\    ]
    \\  },
    \\  "units": [
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/lib",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "lib",
    \\      "root": "src/app",
    \\      "srcs": [
    \\        {"path": "src/app/__init__.mojo", "sha256": "3e506d235e62bd8c64c14afbc28e1b4bdb66724f64110066d425f438d6f0486e"}
    \\      ],
    \\      "deps": ["http_core@1.2.5#mojo1.0.0/lib", "util@0.3.0#mojo1.0.0/lib"],
    \\      "natives": [
    \\        {"id": "z", "soname": "libz_native.so.1", "sha256": "348e8aa89787ad18546c8d63acb1b223332611eb25829fb6a451253f7aa8649a", "package": "http_core"}
    \\      ],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["app.mojoc"],
    \\      "key": "62329562a983dd9960e3c5ac59b372b1ed193242319678aff26b160d476b8db3"
    \\    },
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/test:tests/test_app.mojo",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "test",
    \\      "srcs": [
    \\        {"path": "tests/test_app.mojo", "sha256": "2abc11daffb9e8bcb9eb8bbd62b0fd4d9754b3fed5647f63ef18f49dfd669b1b"}
    \\      ],
    \\      "deps": ["app@1.0.0#mojo1.0.0/lib"],
    \\      "natives": [
    \\        {"id": "z", "soname": "libz_native.so.1", "sha256": "348e8aa89787ad18546c8d63acb1b223332611eb25829fb6a451253f7aa8649a", "package": "http_core"}
    \\      ],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["test_app.pass"],
    \\      "key": "452690ec97a3810da2c94ef0a8d1e3ffe9e32f84fecc9c64c9836be12798b99a"
    \\    },
    \\    {
    \\      "id": "http_core@1.2.5#mojo1.0.0/lib",
    \\      "package": "http_core",
    \\      "version": "1.2.5",
    \\      "kind": "prebuilt",
    \\      "artifact": {"url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1000},
    \\      "mojoc": "lib/mojo/http_core.mojoc",
    \\      "deps": [],
    \\      "natives": [
    \\        {"id": "z", "soname": "libz_native.so.1", "sha256": "348e8aa89787ad18546c8d63acb1b223332611eb25829fb6a451253f7aa8649a", "package": "http_core"}
    \\      ],
    \\      "key": "b6bc7cf04b02d7f207a8b1fdf5177f960352ea5bd00ced5c39c89eed5fc3db01"
    \\    },
    \\    {
    \\      "id": "util@0.3.0#mojo1.0.0/lib",
    \\      "package": "util",
    \\      "version": "0.3.0",
    \\      "kind": "lib",
    \\      "root": "util/src/util",
    \\      "srcs": [
    \\        {"path": "util/src/util/__init__.mojo", "sha256": "e3163528c26697e825dd5eec25279a8679ef2c05095c92a8a952de7fe7514ea5"}
    \\      ],
    \\      "deps": [],
    \\      "natives": [],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["util.mojoc"],
    \\      "key": "1872d9824509bfd4943fffe927349417aef361fc70a880fa5c281e4ce9535c9e"
    \\    }
    \\  ]
    \\}
;

test "golden: the unit graph of a two-Mojo workspace for Mojo 1.0.0, and the same package for 1.1.0 is other units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");

    var why: []const u8 = "";
    const g0 = graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    const text = try render(a, g0);
    std.testing.expectEqualStrings(golden_1_0_0 ++ "\n", text) catch |e| {
        std.debug.print("---- actual ----\n{s}---- end ----\n", .{text});
        return e;
    };

    // The text reads back to the same graph.
    try std.testing.expectEqualStrings(text, try render(a, try parse(a, text)));

    // Mojo 1.1.0: every id names it, http_core is the 1.1.0 build, the keys are other keys.
    const g1 = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.1.0", &why);
    try std.testing.expectEqual(g0.units.len, g1.units.len);
    try std.testing.expectEqualStrings("1.1.0", g1.mojo);
    for (g1.units) |u| try std.testing.expect(std.mem.indexOf(u8, u.id, "#mojo1.1.0/") != null);
    const core1 = g1.units[g1.find("http_core@1.2.5#mojo1.1.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings(test_hex_b, core1.artifact.?.sha256);
    try std.testing.expectEqual(@as(u64, 1100), core1.artifact.?.size);
    const core0 = g0.units[g0.find(id_core) orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings(test_hex_a, core0.artifact.?.sha256);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(g1, "app@1.0.0#mojo1.1.0/lib"), try keyOfId(g0, id_app)));
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(g1, "util@0.3.0#mojo1.1.0/lib"), try keyOfId(g0, id_util)));
}

test "a dependency with no .mojoc for the consumer's Mojo is refused with the specified error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const want = "http_core 1.2.5 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ask the publisher for a 1.1.0 build, or pin a version that has one.";

    // A version 2 lock that has the build for 1.0.0 only.
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_one_build, "1.1.0", &why));
    try std.testing.expectEqualStrings(want, why);
    // The build it has still plans.
    _ = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_one_build, "1.0.0", &why);

    // A version 1 lock (one Mojo version) says the same for another.
    why = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_v1, "1.1.0", &why));
    try std.testing.expectEqualStrings(want, why);
}

test "a package builds only for the Mojo versions it lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    // util lists 1.0.0 only.
    try put(tmp.dir, "util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.3.0\"\nmojo = [\"1.0.0\"]\n");
    var why: []const u8 = "";
    _ = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why);
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.1.0", &why));
    try std.testing.expectEqualStrings("util/mopm.toml lists mojo 1.0.0, not 1.1.0; add 1.1.0 to it, or build for one it lists", why);
}

/// The reason a lock is stale; the test fails, not panics, when it is not.
fn expectStale(why: ?[]const u8) ![]const u8 {
    return why orelse {
        std.debug.print("the lock was taken for fresh\n", .{});
        return error.TestUnexpectedResult;
    };
}

test "a stale lock is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    var diag: manifest.Diagnostic = .{};
    const l = try lock.parse(a, try fill(a, lock_two), &why);
    const roots = [_]resolve.Root{.{ .name = "http_core", .requirement = "1.2" }};

    // `mopm plan` asks this before it plans: the lock fits mopm.toml.
    const m = try manifest.parse(a, toml_app ++ toml_core_dep ++ toml_util_dep, &diag);
    try std.testing.expectEqual(@as(?[]const u8, null), try install.staleness(a, m.mojo, &roots, &members, l));

    // mopm.toml moved on: http_core "2" is not what the lock holds.
    const newer = [_]resolve.Root{.{ .name = "http_core", .requirement = "2" }};
    try std.testing.expectEqualStrings("mopm.toml needs http_core \"2\", but mopm.lock has http_core 1.2.5", try expectStale(try install.staleness(a, m.mojo, &newer, &members, l)));
    // mopm.toml lists one Mojo version fewer than the lock.
    try std.testing.expectEqualStrings("mopm.lock is for mojo 1.0.0, 1.1.0; mopm.toml's mojo is 1.0.0", try expectStale(try install.staleness(a, &.{"1.0.0"}, &roots, &members, l)));
    // mopm.toml gained a dependency the lock does not hold.
    const more = [_]resolve.Root{ .{ .name = "http_core", .requirement = "1.2" }, .{ .name = "tls", .requirement = "1" } };
    try std.testing.expectEqualStrings("mopm.toml needs tls, which mopm.lock does not lock", try expectStale(try install.staleness(a, m.mojo, &more, &members, l)));

    // The graph itself refuses a lock made for another toolchain of the same Mojo.
    var stale = l;
    var closures = [_]lock.Closure{ .{ .mojo = "1.0.0", .subdir = "linux-64", .sha256 = test_hex_a }, l.closures[1] };
    stale.closures = &closures;
    try writeWorkspace(tmp.dir, app_init);
    try std.testing.expectError(error.Refused, build(a, .{ .dir = dir, .m = m, .members = &members, .l = stale, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, &why));
    try std.testing.expectEqualStrings("mopm.lock records toolchain closure " ++ test_hex_a ++ " for mojo 1.0.0 on linux-64, but this mopm pins " ++ test_hex_c ++ "; run 'mopm lock'", why);
    // And one that does not lock the consumer's Mojo at all.
    try std.testing.expectError(error.Refused, build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.2.0", .toolchain = fakeToolchain("1.2.0") }, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "mopm.lock is not locked for mojo 1.2.0 (it locks 1.0.0, 1.1.0)"));
}

test "a missing source is refused when the graph is made" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    try tmp.dir.deleteFile("util/src/util/__init__.mojo");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "util/src/util holds no .mojo file") != null);
}

test "known defects: a reordered dependency, a changed source or another artifact changes the keys, and only the right ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const base = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why);

    // The same inputs again: the same keys (the keys are a function of the inputs).
    const again = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why);
    for (base.units) |u| try std.testing.expectEqualStrings(u.key, try keyOfId(again, u.id));

    // 1. The dependencies in the other order: app's library and what builds on it change.
    const swapped = try graphOf(a, dir, toml_util_dep ++ toml_core_dep, lock_two, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_app), try keyOfId(swapped, id_app)));
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_test), try keyOfId(swapped, id_test)));
    try std.testing.expectEqualStrings(try keyOfId(base, id_core), try keyOfId(swapped, id_core));
    try std.testing.expectEqualStrings(try keyOfId(base, id_util), try keyOfId(swapped, id_util));

    // 2. A changed source: its library and its dependents change, nothing else.
    try put(tmp.dir, "src/app/__init__.mojo", app_init_changed);
    const edited = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_app), try keyOfId(edited, id_app)));
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_test), try keyOfId(edited, id_test)));
    try std.testing.expectEqualStrings(try keyOfId(base, id_core), try keyOfId(edited, id_core));
    try std.testing.expectEqualStrings(try keyOfId(base, id_util), try keyOfId(edited, id_util));
    try put(tmp.dir, "src/app/__init__.mojo", app_init);

    // 3. Another artifact for the dependency (a republished build): it and its dependents change.
    const other = try std.mem.replaceOwned(u8, a, lock_two, "@A@", "@B@");
    const rebuilt = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, other, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_core), try keyOfId(rebuilt, id_core)));
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_app), try keyOfId(rebuilt, id_app)));
    try std.testing.expectEqualStrings(try keyOfId(base, id_util), try keyOfId(rebuilt, id_util));

    // 4. Another toolchain closure: every key.
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, toml_app ++ toml_core_dep ++ toml_util_dep, &diag);
    const l = try lock.parse(a, try fill(a, lock_v1), &why);
    var tc = fakeToolchain("1.0.0");
    const with_c = try build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = tc }, &why);
    tc.closure_sha256 = test_hex_b;
    const with_b = try build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = tc }, &why);
    for (with_c.units) |u| try std.testing.expect(!std.mem.eql(u8, u.key, try keyOfId(with_b, u.id)));
}

test "a native library without a sha256 in the lock is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const bare = try std.mem.replaceOwned(u8, a, lock_two, ", \"sha256\": \"@N@\"", "");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_core_dep ++ toml_util_dep, bare, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "has no sha256 in mopm.lock") != null);
}

test "mopm pins the toolchain of the Mojo it names, and refuses another" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const tc = try toolchainFor(a, "1.0.0", "linux-64", &why);
    try std.testing.expect(lock.isSha256(tc.closure_sha256));
    try std.testing.expectEqual(@as(usize, 3), tc.components.len);
    try std.testing.expectEqualStrings("0.12.0", tc.zig.version);
    // The same pins, the same hash.
    try std.testing.expectEqualStrings(tc.closure_sha256, (try toolchainFor(a, "1.0.0", "linux-64", &why)).closure_sha256);
    try std.testing.expectError(error.Refused, toolchainFor(a, "1.1.0", "linux-64", &why));
    try std.testing.expectEqualStrings("mopm has no pinned toolchain for mojo 1.1.0 on linux-64 (it pins mojo 1.0.0 on linux-64, linux-aarch64 and osx-arm64)", why);
}

/// tls_sys (a static library) over crypto_sys (another, in the exclusivity group libcrypto): the lock of a project
/// that links an archive that needs an archive. By soname crypto_sys is first; by `needs` tls_sys must be.
const lock_static_chain =
    \\{
    \\  "lock_version": 1,
    \\  "toolchain": {"mojo": "1.0.0"},
    \\  "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    {"name": "crypto_sys", "version": "1.39.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "url": "https://conda.mopm.dev/linux-64/mojo-crypto_sys-1.39.0-mojo1.0.0_0.conda", "sha256": "@A@", "size": 1000, "mojo": "1.0.0",
    \\     "native": [{"id": "crypto_sys", "soname": "libcrypto_sys.a", "sha256": "@N@", "kind": "static", "exclusive": "libcrypto"}]},
    \\    {"name": "tls_sys", "version": "2.4.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "url": "https://conda.mopm.dev/linux-64/mojo-tls_sys-2.4.0-mojo1.0.0_0.conda", "sha256": "@B@", "size": 1000, "mojo": "1.0.0",
    \\     "deps": ["crypto_sys"],
    \\     "native": [{"id": "tls_sys", "soname": "libtls_sys.a", "sha256": "@D@", "kind": "static", "needs": ["libcrypto_sys.a"]}]}
    \\  ]
    \\}
    \\
;

const toml_tls_dep = "tls_sys = \"2.4\"\n";

fn nativeSonames(a: Allocator, u: Unit) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (u.natives, 0..) |n, i| {
        if (i > 0) try out.append(' ');
        try out.appendSlice(n.soname);
    }
    return out.items;
}

// Defect it catches: static archives handed to the linker in soname order, so that an archive comes after the
// archive it needs and the symbols it leaves undefined are not found (the link fails, or worse, links less).
// Defect caught: `orderNatives` returns `natives` as sorted by soname.
test "the natives of a unit are in link order: an archive before the archives it needs, with its kind, needs and group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = graphOf(a, dir, toml_tls_dep, lock_static_chain, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    // The unit that links (the test) and the library under it see both archives, the needer first.
    for ([_][]const u8{ id_app, id_test }) |id| {
        const u = g.units[g.find(id).?];
        try std.testing.expectEqualStrings("libtls_sys.a libcrypto_sys.a", try nativeSonames(a, u));
        try std.testing.expectEqual(metadata.Kind.static, u.natives[0].kind);
        try std.testing.expectEqualStrings("libcrypto_sys.a", u.natives[0].needs[0]);
        try std.testing.expectEqualStrings("", u.natives[0].exclusive);
        try std.testing.expectEqualStrings("libcrypto", u.natives[1].exclusive);
        try std.testing.expectEqual(@as(usize, 0), u.natives[1].needs.len);
    }
    // The unit of crypto_sys alone sees only its own.
    const crypto = g.units[g.find("crypto_sys@1.39.0#mojo1.0.0/lib").?];
    try std.testing.expectEqualStrings("libcrypto_sys.a", try nativeSonames(a, crypto));

    // What is printed reads back as the same graph (kind, needs and exclusive survive the text).
    const text = try render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\": \"static\", \"needs\": [\"libcrypto_sys.a\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"exclusive\": \"libcrypto\"}") != null);
    const back = try parse(a, text);
    const again = back.units[back.find(id_app).?];
    try std.testing.expectEqualStrings("libtls_sys.a libcrypto_sys.a", try nativeSonames(a, again));
    try std.testing.expectEqual(metadata.Kind.static, again.natives[1].kind);
    try std.testing.expectEqualStrings("libcrypto", again.natives[1].exclusive);
    try std.testing.expectEqualStrings(text, try render(a, back));
}

// Defect it catches: a graph whose native libraries are all "shared, no needs" in the text, so a lock that says
// otherwise (and a unit key that should change with it) prints the same. Defect caught: `writeUnit` drops `kind`.
test "a native's kind, needs and group are in the unit's key: changing one changes the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const base = try graphOf(a, dir, toml_tls_dep, lock_static_chain, "1.0.0", &why);
    const variants = [_][2][]const u8{
        .{ "\"kind\": \"static\", \"exclusive\": \"libcrypto\"", "\"kind\": \"both\", \"exclusive\": \"libcrypto\"" },
        .{ "\"exclusive\": \"libcrypto\"", "\"exclusive\": \"libcrypto2\"" },
        .{ "\"kind\": \"static\", \"exclusive\": \"libcrypto\"", "\"kind\": \"static\"" },
    };
    for (variants) |v| {
        const other = try std.mem.replaceOwned(u8, a, lock_static_chain, v[0], v[1]);
        const g = try graphOf(a, dir, toml_tls_dep, other, "1.0.0", &why);
        try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_app), try keyOfId(g, id_app)));
    }
}

test "a static library that needs an archive nobody ships, and archives that need each other, are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    const lonely = try std.mem.replaceOwned(u8, a, lock_static_chain, "\"needs\": [\"libcrypto_sys.a\"]", "\"needs\": [\"libnothing.a\"]");
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_tls_dep, lonely, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "native library libtls_sys.a of tls_sys needs libnothing.a, which no package in its dependency closure ships") != null);

    const cycle = try std.mem.replaceOwned(u8, a, lock_static_chain, "\"kind\": \"static\", \"exclusive\": \"libcrypto\"", "\"kind\": \"static\", \"needs\": [\"libtls_sys.a\"]");
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_tls_dep, cycle, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "native libraries libcrypto_sys.a, libtls_sys.a need each other") != null);

    // A shared library's needs are resolved by the loader at run time: a need that is not in the closure is not refused here.
    const shared = try std.mem.replaceOwned(u8, a, lock_static_chain, "\"soname\": \"libtls_sys.a\", \"sha256\": \"@D@\", \"kind\": \"static\", \"needs\": [\"libcrypto_sys.a\"]", "\"soname\": \"libtls_sys.so.1\", \"sha256\": \"@D@\", \"needs\": [\"libnothing.so.1\"]");
    const g = try graphOf(a, dir, toml_tls_dep, shared, "1.0.0", &why);
    try std.testing.expectEqual(@as(usize, 2), g.units[g.find(id_app).?].natives.len);
}

// Defect it catches: the system libraries of a published archive dropped from the graph, so a Buck2 consumer of a C++
// archive links without libc++; a name listed twice (once per archive that names it); the format staying 2, which a reader
// that does not know `link` would take and link without them.
test "prebuilt natives that name system libraries give their units one link list, in link order, and the format 5" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const base = try graphOf(a, dir, toml_tls_dep, lock_static_chain, "1.0.0", &why);
    try std.testing.expectEqual(format_version, base.unit_graph);
    try std.testing.expectEqual(@as(usize, 0), base.units[base.find(id_app).?].link.len);
    try std.testing.expect(std.mem.indexOf(u8, try render(a, base), "\"link\"") == null);

    // tls_sys (first in link order) names libc++ and libm, crypto_sys libc++ again: libc++ once, libm after it.
    const with_tls = try std.mem.replaceOwned(u8, a, lock_static_chain, "\"kind\": \"static\", \"needs\": [\"libcrypto_sys.a\"]", "\"kind\": \"static\", \"needs\": [\"libcrypto_sys.a\"], \"link\": [\"c++\", \"m\"]");
    const linked = try std.mem.replaceOwned(u8, a, with_tls, "\"kind\": \"static\", \"exclusive\": \"libcrypto\"", "\"kind\": \"static\", \"exclusive\": \"libcrypto\", \"link\": [\"c++\"]");
    const g = graphOf(a, dir, toml_tls_dep, linked, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(format_link, g.unit_graph);
    for ([_][]const u8{ id_app, id_test }) |id| {
        const u = g.units[g.find(id).?];
        try std.testing.expectEqualStrings("libtls_sys.a libcrypto_sys.a", try nativeSonames(a, u));
        try std.testing.expectEqual(@as(usize, 2), u.link.len);
        try std.testing.expectEqualStrings("c++", u.link[0]);
        try std.testing.expectEqualStrings("m", u.link[1]);
    }
    // The unit of crypto_sys alone links its own archive and so only what that names.
    const crypto = g.units[g.find("crypto_sys@1.39.0#mojo1.0.0/lib").?];
    try std.testing.expectEqual(@as(usize, 1), crypto.link.len);
    try std.testing.expectEqualStrings("c++", crypto.link[0]);

    const text = try render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit_graph\": 5,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"link\": [\"c++\", \"m\"]") != null);
    const back = try parse(a, text);
    try std.testing.expectEqual(format_link, back.unit_graph);
    try std.testing.expectEqualStrings("m", back.units[back.find(id_app).?].link[1]);
    try std.testing.expectEqualStrings(text, try render(a, back));

    // A name that a lock adds moves the key of every unit that links the archive.
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_app), try keyOfId(g, id_app)));
}

test "a graph for a lock whose natives carry no kind, needs or group prints exactly what it printed before they existed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try graphOf(a, dir, toml_core_dep ++ toml_util_dep, lock_two, "1.0.0", &why);
    const text = try render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\": \"static\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"needs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"exclusive\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"id\": \"z\", \"soname\": \"libz_native.so.1\", \"sha256\": \"" ++ native_sha ++ "\", \"package\": \"http_core\"}") != null);
}

// Spike (natives design, PR 1a): does a native-bearing candidate resolve by subdir? The resolver is blind to subdirs
// (it picks by version and compiler); `buildLock` makes one lock entry per file; this graph takes, for each package,
// the entry of exactly the build's subdir. So the natives of a package, which differ per platform, are the ones of the
// platform being built, and a package published for another subdir only is not there at all.
test "spike: a package that ships natives is taken by exact subdir, with that subdir's pins; a noarch-only one has no fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const osx_entry =
        \\    {"name": "crypto_sys", "version": "1.39.0", "build": "mojo1.0.0_0", "subdir": "osx-arm64", "channel": "https://conda.mopm.dev/",
        \\     "url": "https://conda.mopm.dev/osx-arm64/mojo-crypto_sys-1.39.0-mojo1.0.0_0.conda", "sha256": "@C@", "size": 1000, "mojo": "1.0.0",
        \\     "native": [{"id": "crypto_sys", "soname": "libcrypto_sys.a", "sha256": "@B@", "kind": "static", "exclusive": "libcrypto"}]},
        \\
    ;
    const both = try std.mem.replaceOwned(u8, a, lock_static_chain, "    {\"name\": \"tls_sys\"", osx_entry ++ "    {\"name\": \"tls_sys\"");

    const linux = try graphOfIn(a, dir, "crypto_sys = \"1\"\n", both, "1.0.0", "linux-64", &why);
    const mac = try graphOfIn(a, dir, "crypto_sys = \"1\"\n", both, "1.0.0", "osx-arm64", &why);
    const lin_native = linux.units[linux.find(id_app).?].natives;
    const mac_native = mac.units[mac.find(id_app).?].natives;
    try std.testing.expectEqual(@as(usize, 1), lin_native.len);
    try std.testing.expectEqual(@as(usize, 1), mac_native.len);
    try std.testing.expectEqualStrings(native_sha, lin_native[0].sha256);
    try std.testing.expectEqualStrings(test_hex_b, mac_native[0].sha256);
    // The prebuilt unit's archive is the subdir's own file too.
    try std.testing.expectEqualStrings(test_hex_a, linux.units[linux.find("crypto_sys@1.39.0#mojo1.0.0/lib").?].artifact.?.sha256);
    try std.testing.expectEqualStrings(test_hex_c, mac.units[mac.find("crypto_sys@1.39.0#mojo1.0.0/lib").?].artifact.?.sha256);
    // The graph of a subdir the package is not published for is refused: tls_sys has linux-64 only.
    try std.testing.expectError(error.Refused, graphOfIn(a, dir, toml_tls_dep, both, "1.0.0", "osx-arm64", &why));
    try std.testing.expectEqualStrings("tls_sys is not in mopm.lock for osx-arm64", why);

    // No noarch fallback: a package published as noarch alone (what `mopm pack` makes without a subdir) is not in the
    // graph of linux-64.
    const noarch = try std.mem.replaceOwned(u8, a, lock_static_chain, "linux-64", "noarch");
    try std.testing.expectError(error.Refused, graphOfIn(a, dir, toml_tls_dep, noarch, "1.0.0", "linux-64", &why));
    try std.testing.expectEqualStrings("tls_sys is not in mopm.lock for linux-64", why);
}

// Spike (natives design, PR 1a): does a package whose Mojo module is empty -- the `-sys` package of a C library, which
// has no Mojo code and exists to carry an archive -- make a graph? The library directory holds one `__init__.mojo`
// of no bytes. (That `mojo precompile` accepts such a module, and that the archive links, is run on a real Mojo by
// tests/drivers/native_static_test.zig.)
test "spike: a package with an empty Mojo module is a library unit with that empty source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, "");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = graphOf(a, dir, "", lock_v1, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    const lib = g.units[g.find(id_app).?];
    try std.testing.expectEqualStrings("lib", lib.kind);
    try std.testing.expectEqual(@as(usize, 1), lib.srcs.len);
    try std.testing.expectEqualStrings("src/app/__init__.mojo", lib.srcs[0].path);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", lib.srcs[0].sha256);
    // Only the directory with no .mojo file at all is refused.
    try tmp.dir.deleteFile("src/app/__init__.mojo");
    try std.testing.expectError(error.Refused, graphOf(a, dir, "", lock_v1, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "holds no .mojo file") != null);
}

test "a native library that needs its own soname is refused, shared or static, when the graph is made" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    // The lock reader refuses this lock; the graph must too when handed one (a lock made by hand into a struct).
    var l = try lock.parse(a, try fill(a, lock_static_chain), &why);
    const pk = try a.dupe(lock.Package, l.packages);
    for (pk) |*p| {
        if (std.mem.eql(u8, p.name, "crypto_sys")) p.native = try a.dupe(lock.Native, &.{.{ .id = "crypto_sys", .soname = "libcrypto_sys.a", .sha256 = native_sha, .kind = .static, .needs = &.{"libcrypto_sys.a"} }});
    }
    l.packages = pk;
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ toml_app, toml_tls_dep }), &diag);
    try std.testing.expectError(error.Refused, build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "native library libcrypto_sys.a of crypto_sys needs itself") != null);
}

/// The graph of lock_static_chain with the exclusive group of each of its two natives set by hand into the parsed
/// lock, so that one helper varies the group of both natives (the lock reader does not look at groups: a lock that holds
/// two packages in one group parses, and the graph is where the clash is refused).
fn graphWithGroups(a: Allocator, dir: []const u8, crypto_group: []const u8, tls_group: []const u8, why: *[]const u8) !Graph {
    var l = try lock.parse(a, try fill(a, lock_static_chain), why);
    const pk = try a.dupe(lock.Package, l.packages);
    for (pk) |*p| {
        const group = if (std.mem.eql(u8, p.name, "crypto_sys")) crypto_group else tls_group;
        const native = try a.dupe(lock.Native, p.native);
        for (native) |*n| n.exclusive = group;
        p.native = native;
    }
    l.packages = pk;
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ toml_app, toml_tls_dep }), &diag);
    return build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, why);
}

/// The graph of lock_static_chain with the natives of tls_sys replaced by two (soname libtls_mid.a with no group, then
/// libtls_z.a in `z_group`), so that the closure's natives by soname are crypto_sys' (group libcrypto), mid, z.
fn graphWithThree(a: Allocator, dir: []const u8, z_group: []const u8, why: *[]const u8) !Graph {
    var l = try lock.parse(a, try fill(a, lock_static_chain), why);
    const pk = try a.dupe(lock.Package, l.packages);
    for (pk) |*p| {
        if (!std.mem.eql(u8, p.name, "tls_sys")) continue;
        p.native = try a.dupe(lock.Native, &.{
            .{ .id = "tls_mid", .soname = "libtls_mid.a", .sha256 = native_sha, .kind = .static },
            .{ .id = "tls_z", .soname = "libtls_z.a", .sha256 = native_sha, .kind = .static, .exclusive = z_group },
        });
    }
    l.packages = pk;
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ toml_app, toml_tls_dep }), &diag);
    return build(a, .{ .dir = dir, .m = m, .members = &members, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, why);
}

// Defects it catches: a clash found only between natives that are next to each other in link order, so that a library
// with no group between two of one group hides the second; and group names compared without regard to case, so that
// `libcrypto` and `LibCrypto` are one group. Defect caught: the inner loop looks only at `found[i + 1]`; the
// comparison is `std.ascii.eqlIgnoreCase`.
test "an exclusive clash is found between natives that are not next to each other; group names are exact, case included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    // By soname: libcrypto_sys.a (libcrypto), libtls_mid.a (none), libtls_z.a (libcrypto).
    try std.testing.expectError(error.Refused, graphWithThree(a, dir, "libcrypto", &why));
    try std.testing.expectEqualStrings(
        id_app ++ ": native libraries libcrypto_sys.a of crypto_sys and libtls_z.a of tls_sys are both in exclusive group libcrypto; a unit links one library of a group",
        why,
    );
    // The same names in another case are another group; so is a group that merely contains the other's name.
    for ([_][]const u8{ "LibCrypto", "LIBCRYPTO", "libcrypto2", "libcrypt" }) |other| {
        const g = try graphWithThree(a, dir, other, &why);
        try std.testing.expectEqual(@as(usize, 3), g.units[g.find(id_app).?].natives.len);
    }
}

// Defect it catches: a closure that links two libraries of one exclusive group (two copies of a crypto library, each
// with its own error queue and CPU-capability word) and builds. Defect caught: the comparison of the two groups is
// negated; the check returns at once; the group is compared only when the two natives are of one package.
test "two natives of one exclusive group in a unit's closure are refused, naming both; different groups, and no group, are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeWorkspace(tmp.dir, app_init);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    try std.testing.expectError(error.Refused, graphWithGroups(a, dir, "libcrypto", "libcrypto", &why));
    try std.testing.expectEqualStrings(
        id_app ++ ": native libraries libcrypto_sys.a of crypto_sys and libtls_sys.a of tls_sys are both in exclusive group libcrypto; a unit links one library of a group",
        why,
    );

    const distinct = try graphWithGroups(a, dir, "libcrypto", "libtls", &why);
    try std.testing.expectEqual(@as(usize, 2), distinct.units[distinct.find(id_app).?].natives.len);
    // Natives with no group never conflict (an empty group is no group).
    const none = try graphWithGroups(a, dir, "", "", &why);
    try std.testing.expectEqual(@as(usize, 2), none.units[none.find(id_app).?].natives.len);
    // One group and no other member of it is fine.
    const one = try graphWithGroups(a, dir, "libcrypto", "", &why);
    try std.testing.expectEqual(@as(usize, 2), one.units[one.find(id_app).?].natives.len);
}

// ------------------------------------------------------- a member's own natives

const c_app = "int app_shim(void) { return 1; }\n";
const h_app = "int app_shim(void);\n";
const c_util = "int util_shim(void) { return 7; }\n";
const h_util = "int util_shim(void);\n";
const main_src = "def main():\n    pass\n";

const id_bin = "app@1.0.0#mojo1.0.0/bin:appbin";
const id_crypto = "crypto_sys@1.39.0#mojo1.0.0/lib";
const id_native_app = "native:app/app_shim";
const id_native_util = "native:util/util_shim";

const toml_bin = "\n[targets]\nbins = [{ name = \"appbin\", path = \"src/main.mojo\" }]\n";
const toml_crypto_dep = "crypto_sys = \"1\"\n";
/// app's own native, with flags for every OS and one OS each, and no needs.
const toml_app_alone = "\n[native.app_shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/*.h\"]\ncflags = [\"-O2\"]\ncflags_by_os = { linux = [\"-DLINUX\"], macos = [\"-DMACOS\"] }\n";
/// app's own native, which needs the native of util.
const toml_app_needs_util = "\n[native.app_shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/*.h\"]\nneeds = [\"libutil_shim.a\"]\n";
/// util's native, which needs a prebuilt archive; its include directories are given.
const toml_util_native = toml_util ++ "\n[native.util_shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/*.h\"]\ncflags = [\"-O2\"]\nincludes = [\"native\", \"extra\"]\nneeds = [\"libcrypto_sys.a\"]\n";

/// crypto_sys (a prebuilt archive in the group libcrypto) and util, which is a member that depends on it.
const lock_member_chain =
    \\{
    \\  "lock_version": 1,
    \\  "toolchain": {"mojo": "1.0.0"},
    \\  "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    {"name": "crypto_sys", "version": "1.39.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\     "url": "https://conda.mopm.dev/linux-64/mojo-crypto_sys-1.39.0-mojo1.0.0_0.conda", "sha256": "@A@", "size": 1000, "mojo": "1.0.0",
    \\     "native": [{"id": "crypto_sys", "soname": "libcrypto_sys.a", "sha256": "@N@", "kind": "static", "exclusive": "libcrypto"}]},
    \\    {"name": "util", "version": "0.3.0", "source": "path", "path": "util", "deps": ["crypto_sys"]}
    \\  ]
    \\}
    \\
;

/// The fixture workspace with the sources of the native libraries of app and util, and a binary for app.
fn writeNativeWorkspace(dir: std.fs.Dir, util_toml: []const u8) !void {
    try writeWorkspace(dir, app_init);
    try put(dir, "util/mopm.toml", util_toml);
    try put(dir, "src/main.mojo", main_src);
    try put(dir, "native/app.c", c_app);
    try put(dir, "native/app.h", h_app);
    try put(dir, "util/native/shim.c", c_util);
    try put(dir, "util/native/shim.h", h_util);
}

fn natives_of(a: Allocator, g: Graph, id: []const u8) ![]const u8 {
    return nativeSonames(a, g.units[g.find(id) orelse return error.NoSuchUnit]);
}

// Defect it catches: a member's own C library missing from the graph, so a build system links a test without it (or
// builds nothing for it); an archive entry that carries a hash it cannot have before it is built.
test "a member's static native is a native unit, and its lib, test and bin units list it as built" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeWorkspace(tmp.dir, toml_util);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = graphOf(a, dir, toml_util_dep ++ toml_bin ++ toml_app_alone, lock_two, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };

    // The native unit: what the build system compiles, and the name of the archive it makes.
    const nu = g.units[g.find(id_native_app) orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("native", nu.kind);
    try std.testing.expectEqualStrings("app", nu.package);
    try std.testing.expectEqualStrings("libapp_shim.a", nu.soname);
    try std.testing.expectEqual(@as(usize, 1), nu.srcs.len);
    try std.testing.expectEqualStrings("native/app.c", nu.srcs[0].path);
    try std.testing.expectEqualStrings(try sha256Hex(a, c_app), nu.srcs[0].sha256);
    try std.testing.expectEqualStrings("native/app.h", nu.hdrs[0].path);
    try std.testing.expectEqualStrings(try sha256Hex(a, h_app), nu.hdrs[0].sha256);
    try std.testing.expectEqualStrings("native", nu.includes[0]);
    try std.testing.expectEqualStrings("-O2", nu.cflags[0]);
    try std.testing.expectEqualStrings("-DLINUX", nu.cflags_by_os.linux[0]);
    try std.testing.expectEqualStrings("-DMACOS", nu.cflags_by_os.macos[0]);
    try std.testing.expectEqualStrings("libapp_shim.a", nu.outputs[0]);
    try std.testing.expect(nu.artifact == null);
    try std.testing.expectEqual(@as(usize, 0), nu.natives.len);
    try std.testing.expectEqual(@as(usize, 64), nu.key.len);

    // The root's lib, its test and its binary all link it; util, which does not depend on app, does not.
    for ([_][]const u8{ id_app, id_test, id_bin }) |id| {
        const u = g.units[g.find(id) orelse return error.NoSuchUnit];
        try std.testing.expectEqual(@as(usize, 1), u.natives.len);
        const n = u.natives[0];
        try std.testing.expectEqualStrings("app_shim", n.id);
        try std.testing.expectEqualStrings("libapp_shim.a", n.soname);
        try std.testing.expectEqualStrings("app", n.package);
        try std.testing.expectEqual(metadata.Kind.static, n.kind);
        try std.testing.expectEqualStrings(id_native_app, n.built);
        try std.testing.expectEqualStrings("", n.sha256);
    }
    try std.testing.expectEqual(@as(usize, 0), g.units[g.find(id_util).?].natives.len);

    // What is printed has no sha256 for the built entry, and reads back as the same graph.
    const text = try render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"id\": \"app_shim\", \"soname\": \"libapp_shim.a\", \"package\": \"app\", \"kind\": \"static\", \"built\": \"native:app/app_shim\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sha256\": \"\"") == null);
    const back = try parse(a, text);
    try std.testing.expectEqualStrings(text, try render(a, back));
    try std.testing.expectEqualStrings(id_native_app, back.units[back.find(id_test).?].natives[0].built);
}

// Defect it catches: a dependent member's link order that is the soname order, or that drops the dependency's archive:
// an archive then comes before the archive it leaves its symbols to. Here libapp_shim.a needs libutil_shim.a, which needs
// the prebuilt libcrypto_sys.a; by soname the prebuilt archive would sit between the two.
test "a dependent member lists the native of the member it depends on after its own and before what that needs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeWorkspace(tmp.dir, toml_util_native);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = graphOf(a, dir, toml_crypto_dep ++ toml_util_dep ++ toml_app_needs_util, lock_member_chain, "1.0.0", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqualStrings("libapp_shim.a libutil_shim.a libcrypto_sys.a", try natives_of(a, g, id_app));
    try std.testing.expectEqualStrings("libapp_shim.a libutil_shim.a libcrypto_sys.a", try natives_of(a, g, id_test));
    // util's own unit links its native, then the prebuilt archive it needs; the prebuilt package links its own only.
    try std.testing.expectEqualStrings("libutil_shim.a libcrypto_sys.a", try natives_of(a, g, id_util));
    try std.testing.expectEqualStrings("libcrypto_sys.a", try natives_of(a, g, id_crypto));
    // Built entries carry no hash; the prebuilt entry keeps its own.
    const u = g.units[g.find(id_app).?];
    try std.testing.expectEqualStrings("", u.natives[1].sha256);
    try std.testing.expectEqualStrings(id_native_util, u.natives[1].built);
    try std.testing.expectEqualStrings("libcrypto_sys.a", u.natives[1].needs[0]);
    try std.testing.expectEqualStrings(native_sha, u.natives[2].sha256);
    try std.testing.expectEqualStrings("", u.natives[2].built);
    // Both natives are units; util's keeps the include directories it was given, whatever holds its headers.
    const nu = g.units[g.find(id_native_util).?];
    try std.testing.expectEqualStrings("util/native/shim.c", nu.srcs[0].path);
    try std.testing.expectEqualStrings("util/native/shim.h", nu.hdrs[0].path);
    try std.testing.expectEqual(@as(usize, 2), nu.includes.len);
    try std.testing.expectEqualStrings("extra", nu.includes[1]);
    try std.testing.expectEqualStrings("libcrypto_sys.a", nu.needs[0]);
    _ = g.find(id_native_app) orelse return error.NoSuchUnit;
    // The native unit prints its needs (after its includes, before its deps), and they read back.
    const text = try render(a, g);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"includes\": [\"native\", \"extra\"],\n      \"needs\": [\"libcrypto_sys.a\"],\n      \"deps\": []") != null);
    const back = try parse(a, text);
    try std.testing.expectEqualStrings("libcrypto_sys.a", back.units[back.find(id_native_util).?].needs[0]);
    try std.testing.expectEqualStrings(text, try render(a, back));
}

// Defect it catches: a member native that is silently left out (or half-understood) so that the link fails late, far
// from the manifest that caused it.
test "a member's native that the graph cannot build is refused, naming the manifest and the native" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Case = struct { native: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .native = "kind = \"shared\"\nsrcs = [\"native/*.c\"]\n", .want = "util/mopm.toml: [native.s] is kind = \"shared\"; a unit graph builds a member's native as a static archive only" },
        .{ .native = "srcs = [\"native/*.c\"]\n", .want = "util/mopm.toml: [native.s] is kind = \"shared\"" },
        .{ .native = "kind = \"both\"\nsrcs = [\"native/*.c\"]\n", .want = "util/mopm.toml: [native.s] is kind = \"both\"" },
        .{ .native = "kind = \"static\"\nmode = \"load\"\nsrcs = [\"native/*.c\"]\n", .want = "util/mopm.toml: [native.s] is mode = \"load\"" },
        .{ .native = "kind = \"static\"\n", .want = "util/mopm.toml: [native.s] has no srcs" },
        .{ .native = "kind = \"static\"\nsrcs = [\"native/*.cc\"]\n", .want = "util/mopm.toml: srcs \"native/*.cc\" of [native.s] matches no file" },
        .{ .native = "kind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/*.hpp\"]\n", .want = "util/mopm.toml: hdrs \"native/*.hpp\" of [native.s] matches no file" },
        .{ .native = "kind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/shim.c\"]\n", .want = "util/mopm.toml: util/native/shim.c is named by both srcs and hdrs of [native.s]" },
        .{ .native = "kind = \"static\"\nsrcs = [\"native/*.c\"]\nneeds = [\"libnothing.a\"]\n", .want = "native library libs.a of util needs libnothing.a, which no package in its dependency closure ships" },
    };
    for (cases) |c| {
        try writeNativeWorkspace(tmp.dir, try std.mem.concat(a, u8, &.{ toml_util, "\n[native.s]\n", c.native }));
        const dir = try tmp.dir.realpathAlloc(a, ".");
        var why: []const u8 = "";
        try std.testing.expectError(error.Refused, graphOf(a, dir, toml_util_dep, lock_two, "1.0.0", &why));
        if (std.mem.indexOf(u8, why, c.want) == null) {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ why, c.want });
            return error.TestUnexpectedResult;
        }
    }
    // The root package's own native is held to the same rules.
    try writeNativeWorkspace(tmp.dir, toml_util);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, graphOf(a, dir, toml_util_dep ++ "\n[native.s]\nkind = \"shared\"\nsrcs = [\"native/*.c\"]\n", lock_two, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "mopm.toml: [native.s] is kind = \"shared\"") != null);
}

// Defect it catches: a source named by a link that leads out of the member, so the graph hashes (and a build system
// compiles) a file the member does not hold, while a glob would have skipped it.
test "a literal srcs or hdrs path that is a symbolic link or passes through one is refused; a glob skips links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeWorkspace(tmp.dir, toml_util);
    try put(tmp.dir, "outside/x.c", "int outside(void) { return 0; }\n");
    try tmp.dir.symLink("../../outside/x.c", "util/native/link.c", .{});
    try tmp.dir.symLink("../outside", "util/ldir", .{ .is_directory = true });
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";

    const Case = struct { native: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .native = "srcs = [\"native/link.c\"]\n", .want = "util/mopm.toml: srcs \"native/link.c\" of [native.s] is a symbolic link or passes through one" },
        .{ .native = "srcs = [\"native/shim.c\"]\nhdrs = [\"ldir/x.c\"]\n", .want = "util/mopm.toml: hdrs \"ldir/x.c\" of [native.s] is a symbolic link or passes through one" },
        .{ .native = "srcs = [\"ldir/*.c\"]\n", .want = "util/mopm.toml: srcs \"ldir/*.c\" of [native.s] is a symbolic link or passes through one" },
    };
    for (cases) |c| {
        try put(tmp.dir, "util/mopm.toml", try std.mem.concat(a, u8, &.{ toml_util, "\n[native.s]\nkind = \"static\"\n", c.native }));
        try std.testing.expectError(error.Refused, graphOf(a, dir, toml_util_dep, lock_two, "1.0.0", &why));
        if (std.mem.indexOf(u8, why, c.want) == null) {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ why, c.want });
            return error.TestUnexpectedResult;
        }
    }
    // A glob over the same directory skips the link: only the member's own file is a source.
    try put(tmp.dir, "util/mopm.toml", try std.mem.concat(a, u8, &.{ toml_util, "\n[native.s]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\n" }));
    const g = try graphOf(a, dir, toml_util_dep, lock_two, "1.0.0", &why);
    const nu = g.units[g.find("native:util/s") orelse return error.NoSuchUnit];
    try std.testing.expectEqual(@as(usize, 1), nu.srcs.len);
    try std.testing.expectEqualStrings("util/native/shim.c", nu.srcs[0].path);
}

// Defect it catches: a unit key that does not move when a native's C source, header or flags do, so a cached test
// or binary is reused with an archive it was not linked with.
test "the graph key changes when a native's source, header, flags or file set change, and only for what links it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeWorkspace(tmp.dir, toml_util_native);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const deps = toml_crypto_dep ++ toml_util_dep ++ toml_app_needs_util;
    const base = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    const again = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    for (base.units) |u| try std.testing.expectEqualStrings(u.key, try keyOfId(again, u.id));

    const Change = struct { what: []const u8, path: []const u8, bytes: []const u8 };
    const changes = [_]Change{
        .{ .what = "a C source", .path = "util/native/shim.c", .bytes = c_util ++ "// edited\n" },
        .{ .what = "a header", .path = "util/native/shim.h", .bytes = h_util ++ "// edited\n" },
        .{ .what = "another file the glob names", .path = "util/native/more.c", .bytes = "int more(void) { return 2; }\n" },
    };
    for (changes) |c| {
        try put(tmp.dir, c.path, c.bytes);
        const g = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
        // The native unit, and what links it: util's lib, app's lib and test. Not what does not.
        for ([_][]const u8{ id_native_util, id_util, id_app, id_test }) |id| {
            if (std.mem.eql(u8, try keyOfId(base, id), try keyOfId(g, id))) {
                std.debug.print("{s}: the key of {s} did not change\n", .{ c.what, id });
                return error.TestUnexpectedResult;
            }
        }
        for ([_][]const u8{ id_native_app, id_crypto }) |id| try std.testing.expectEqualStrings(try keyOfId(base, id), try keyOfId(g, id));
        // Put it back.
        if (std.mem.eql(u8, c.path, "util/native/more.c")) {
            try tmp.dir.deleteFile(c.path);
        } else {
            try put(tmp.dir, c.path, if (std.mem.endsWith(u8, c.path, ".c")) c_util else h_util);
        }
    }
    try std.testing.expectEqualStrings(try keyOfId(base, id_native_util), try keyOfId(try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why), id_native_util));

    // Its flags are part of what it is.
    try put(tmp.dir, "util/mopm.toml", try std.mem.replaceOwned(u8, a, toml_util_native, "cflags = [\"-O2\"]", "cflags = [\"-O3\"]"));
    const flags = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_native_util), try keyOfId(flags, id_native_util)));
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_test), try keyOfId(flags, id_test)));
    try put(tmp.dir, "util/mopm.toml", try std.mem.replaceOwned(u8, a, toml_util_native, "includes = [\"native\", \"extra\"]", "includes = [\"native\"]"));
    const inc = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_native_util), try keyOfId(inc, id_native_util)));
    try put(tmp.dir, "util/mopm.toml", toml_util_native);

    // A Mojo source of util moves util's lib and what imports it, and leaves the native alone.
    try put(tmp.dir, "util/src/util/__init__.mojo", util_init ++ "\ndef more():\n    pass\n");
    const mojo_edit = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    try std.testing.expect(!std.mem.eql(u8, try keyOfId(base, id_util), try keyOfId(mojo_edit, id_util)));
    try std.testing.expectEqualStrings(try keyOfId(base, id_native_util), try keyOfId(mojo_edit, id_native_util));
}

// Defect it catches: two copies of one library's state in a binary, because the exclusive check looked only at
// prebuilt archives; and two archives of one file name, only one of which the natives directory can hold.
test "a built native and a prebuilt one in one exclusive group, or with one soname, are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const deps = toml_crypto_dep ++ toml_util_dep;
    var why: []const u8 = "";

    // util's native joins the group of the prebuilt crypto_sys.
    try writeNativeWorkspace(tmp.dir, try std.mem.replaceOwned(u8, a, toml_util_native, "needs = [\"libcrypto_sys.a\"]", "needs = [\"libcrypto_sys.a\"]\nexclusive = \"libcrypto\""));
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try std.testing.expectError(error.Refused, graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "native libraries libcrypto_sys.a of crypto_sys and libutil_shim.a of util are both in exclusive group libcrypto; a unit links one library of a group") != null);

    // Another group, or none, is no clash.
    try put(tmp.dir, "util/mopm.toml", try std.mem.replaceOwned(u8, a, toml_util_native, "needs = [\"libcrypto_sys.a\"]", "needs = [\"libcrypto_sys.a\"]\nexclusive = \"libutil\""));
    const other = try graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why);
    try std.testing.expectEqualStrings("libutil_shim.a libcrypto_sys.a", try natives_of(a, other, id_util));

    // Two built natives of one group are a clash too.
    try put(tmp.dir, "util/mopm.toml", try std.mem.replaceOwned(u8, a, toml_util_native, "needs = [\"libcrypto_sys.a\"]", "needs = [\"libcrypto_sys.a\"]\nexclusive = \"libutil\""));
    try std.testing.expectError(error.Refused, graphOf(a, dir, deps ++ "\n[native.app_shim]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nexclusive = \"libutil\"\n", lock_member_chain, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "libapp_shim.a of app and libutil_shim.a of util are both in exclusive group libutil") != null);

    // A built archive named like a prebuilt one.
    try put(tmp.dir, "util/mopm.toml", try std.mem.replaceOwned(u8, a, toml_util_native, "needs = [\"libcrypto_sys.a\"]", "soname = \"libcrypto_sys.a\""));
    try std.testing.expectError(error.Refused, graphOf(a, dir, deps, lock_member_chain, "1.0.0", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "have one name; a unit links one library of a name") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, "(util_shim)") != null);
}

const golden_member_natives =
    \\{
    \\  "unit_graph": 2,
    \\  "package": "app@1.0.0",
    \\  "mojo": "1.0.0",
    \\  "toolchain": {
    \\    "mojo": "1.0.0",
    \\    "subdir": "linux-64",
    \\    "cc_target": "x86_64-linux-gnu.2.34",
    \\    "closure_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    \\    "zig": {"version": "0.12.0", "url": "https://example.invalid/zig.tar.xz", "sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "size": 1},
    \\    "components": [
    \\    ]
    \\  },
    \\  "units": [
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/bin:appbin",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "bin",
    \\      "srcs": [
    \\        {"path": "src/main.mojo", "sha256": "cde0429ba5478089419b8a36797f74089554914623c732054e04dd6eb2e49afd"}
    \\      ],
    \\      "deps": ["app@1.0.0#mojo1.0.0/lib"],
    \\      "natives": [
    \\        {"id": "app_shim", "soname": "libapp_shim.a", "package": "app", "kind": "static", "built": "native:app/app_shim"}
    \\      ],
    \\      "profile": {"opt": 3, "assert": "none", "debug": false},
    \\      "outputs": ["appbin"],
    \\      "key": "20b78a507eab7d5f20a459fbbe9c768b7fded9ed2d8f104d6da8c05430b16d4c"
    \\    },
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/lib",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "lib",
    \\      "root": "src/app",
    \\      "srcs": [
    \\        {"path": "src/app/__init__.mojo", "sha256": "3e506d235e62bd8c64c14afbc28e1b4bdb66724f64110066d425f438d6f0486e"}
    \\      ],
    \\      "deps": ["util@0.3.0#mojo1.0.0/lib"],
    \\      "natives": [
    \\        {"id": "app_shim", "soname": "libapp_shim.a", "package": "app", "kind": "static", "built": "native:app/app_shim"}
    \\      ],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["app.mojoc"],
    \\      "key": "eab3b60d4e62aa9d64846d3d8e1e773cfa222e07af0bb9e4ef128381d710bcf9"
    \\    },
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/test:tests/test_app.mojo",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "test",
    \\      "srcs": [
    \\        {"path": "tests/test_app.mojo", "sha256": "2abc11daffb9e8bcb9eb8bbd62b0fd4d9754b3fed5647f63ef18f49dfd669b1b"}
    \\      ],
    \\      "deps": ["app@1.0.0#mojo1.0.0/lib"],
    \\      "natives": [
    \\        {"id": "app_shim", "soname": "libapp_shim.a", "package": "app", "kind": "static", "built": "native:app/app_shim"}
    \\      ],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["test_app.pass"],
    \\      "key": "73c89c1ac5716316d081d9cfc2542bc0da7b964e7cc1047552ee69fa9e057683"
    \\    },
    \\    {
    \\      "id": "native:app/app_shim",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "native",
    \\      "soname": "libapp_shim.a",
    \\      "srcs": [
    \\        {"path": "native/app.c", "sha256": "1638151a5212fd7d82fd67f02d5a8835830a933385978f3b5d4eb2f2ee9be968"}
    \\      ],
    \\      "hdrs": [
    \\        {"path": "native/app.h", "sha256": "2e0a7f87a41ccb68ef9db68d87c46b0ca8bd57ad6115cca26d0fffb5f3e13e8a"}
    \\      ],
    \\      "cflags": ["-O2"],
    \\      "cflags_by_os": {"linux": ["-DLINUX"], "macos": ["-DMACOS"]},
    \\      "includes": ["native"],
    \\      "deps": [],
    \\      "natives": [],
    \\      "outputs": ["libapp_shim.a"],
    \\      "key": "0b9b4f0ae92bd2c62207a527dcbe979123d1547c9e289e8f65627d586aa016ce"
    \\    },
    \\    {
    \\      "id": "util@0.3.0#mojo1.0.0/lib",
    \\      "package": "util",
    \\      "version": "0.3.0",
    \\      "kind": "lib",
    \\      "root": "util/src/util",
    \\      "srcs": [
    \\        {"path": "util/src/util/__init__.mojo", "sha256": "e3163528c26697e825dd5eec25279a8679ef2c05095c92a8a952de7fe7514ea5"}
    \\      ],
    \\      "deps": [],
    \\      "natives": [],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["util.mojoc"],
    \\      "key": "1872d9824509bfd4943fffe927349417aef361fc70a880fa5c281e4ce9535c9e"
    \\    }
    \\  ]
    \\}
;

// The whole graph of a root that builds its own native, with a binary: the exact bytes.
test "golden: the unit graph of a package with a native of its own, a binary and a test" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeWorkspace(tmp.dir, toml_util);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try graphOf(a, dir, toml_util_dep ++ toml_bin ++ toml_app_alone, lock_two, "1.0.0", &why);
    const text = try render(a, g);
    std.testing.expectEqualStrings(golden_member_natives ++ "\n", text) catch |e| {
        std.debug.print("---- actual ----\n{s}---- end ----\n", .{text});
        return e;
    };
}

// ------------------------------------------------- sibling members under a workspace root

const sib_root_toml = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n";

/// A lock of path packages only; `packages` is the JSON of the entries.
fn sibLock(a: Allocator, packages: []const u8) ![]const u8 {
    const head =
        \\{"lock_version": 2, "mojo": ["1.0.0"], "toolchain": {"1.0.0": {"linux-64": "@C@"}}, "channels": ["https://conda.mopm.dev/"], "packages": [
    ;
    return fill(a, try std.mem.concat(a, u8, &.{ head, packages, "]}\n" }));
}

const sib_b_to_c =
    \\{"name": "b", "version": "0.1.0", "source": "path", "path": "../b", "deps": ["c"]},
    \\{"name": "c", "version": "0.1.0", "source": "path", "path": "../c"}
;
const sib_diamond =
    \\{"name": "b", "version": "0.1.0", "source": "path", "path": "../b", "deps": ["c"]},
    \\{"name": "c", "version": "0.1.0", "source": "path", "path": "../c"},
    \\{"name": "d", "version": "0.1.0", "source": "path", "path": "../d", "deps": ["c"]}
;

/// A package `name` at `at` (relative to `dir`) with a library, a test and a manifest listing `deps` (TOML lines).
fn writeSibling(a: Allocator, dir: std.fs.Dir, at: []const u8, name: []const u8, deps: []const u8) !void {
    const toml = try std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"0.1.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n{s}", .{ name, deps });
    try put(dir, try std.fmt.allocPrint(a, "{s}/mopm.toml", .{at}), toml);
    try put(dir, try std.fmt.allocPrint(a, "{s}/src/{s}/__init__.mojo", .{ at, name }), try std.fmt.allocPrint(a, "def {s}_fn():\n    pass\n", .{name}));
    try put(dir, try std.fmt.allocPrint(a, "{s}/tests/test_{s}.mojo", .{ at, name }), test_app);
}

/// The graph of the package `app` at `pkg` under `dir`, whose manifest lists `deps`, from `lock_text`.
fn siblingGraph(a: Allocator, dir: []const u8, pkg: []const u8, deps: []const u8, lock_text: []const u8, why: *[]const u8) !Graph {
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ sib_root_toml, deps }), &diag);
    const l = try lock.parse(a, lock_text, why);
    return build(a, .{ .dir = dir, .pkg = pkg, .m = m, .members = &.{}, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, why);
}

/// Sibling packages app, b, c, d side by side under `dir`, as a repository holds them.
fn writeSiblings(a: Allocator, dir: std.fs.Dir) !void {
    try writeSibling(a, dir, "app", "app", "b = { path = \"../b\" }\n");
    try writeSibling(a, dir, "b", "b", "c = { path = \"../c\" }\n");
    try writeSibling(a, dir, "c", "c", "");
    try writeSibling(a, dir, "d", "d", "c = { path = \"../c\" }\n");
}

fn countKind(g: Graph, kind: []const u8) usize {
    var n: usize = 0;
    for (g.units) |u| {
        if (std.mem.eql(u8, u.kind, kind)) n += 1;
    }
    return n;
}

fn noDotDot(g: Graph) !void {
    for (g.units) |u| {
        try std.testing.expect(std.mem.indexOf(u8, u.root, "..") == null);
        try std.testing.expect(std.mem.indexOf(u8, u.id, "..") == null);
        for (u.srcs) |s| try std.testing.expect(std.mem.indexOf(u8, s.path, "..") == null);
    }
}

test "sibling members under a workspace root have workspace-relative roots and sources, and the root package's own are too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = siblingGraph(a, dir, "app", "b = { path = \"../b\" }\n", try sibLock(a, sib_b_to_c), &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    const app = g.units[g.find(id_app) orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("app/src/app", app.root);
    try std.testing.expectEqualStrings("app/src/app/__init__.mojo", app.srcs[0].path);
    const b = g.units[g.find("b@0.1.0#mojo1.0.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("b/src/b", b.root);
    try std.testing.expectEqual(@as(usize, 1), b.srcs.len);
    try std.testing.expectEqualStrings("b/src/b/__init__.mojo", b.srcs[0].path);
    try std.testing.expectEqualStrings("b@0.1.0#mojo1.0.0/lib", app.deps[0]);
    try noDotDot(g);
}

test "a nested sibling (app, b, c) gives c one unit, the dependency of b" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try siblingGraph(a, dir, "app", "b = { path = \"../b\" }\n", try sibLock(a, sib_b_to_c), &why);
    var c_units: usize = 0;
    for (g.units) |u| {
        if (std.mem.eql(u8, u.package, "c")) c_units += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), c_units);
    const c = g.units[g.find("c@0.1.0#mojo1.0.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("c/src/c", c.root);
    const b = g.units[g.find("b@0.1.0#mojo1.0.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqual(@as(usize, 1), b.deps.len);
    try std.testing.expectEqualStrings("c@0.1.0#mojo1.0.0/lib", b.deps[0]);
    try noDotDot(g);
}

test "a diamond (b and d both use c) gives c exactly one unit, and both depend on it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try siblingGraph(a, dir, "app", "b = { path = \"../b\" }\nd = { path = \"../d\" }\n", try sibLock(a, sib_diamond), &why);
    var c_units: usize = 0;
    for (g.units) |u| {
        if (std.mem.eql(u8, u.package, "c")) c_units += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), c_units);
    try std.testing.expectEqual(@as(usize, 4), countKind(g, "lib"));
    for ([_][]const u8{ "b@0.1.0#mojo1.0.0/lib", "d@0.1.0#mojo1.0.0/lib" }) |id| {
        const u = g.units[g.find(id) orelse return error.NoSuchUnit];
        try std.testing.expectEqualStrings("c@0.1.0#mojo1.0.0/lib", u.deps[0]);
    }
    try noDotDot(g);
}

test "the root package's tests are planned from its own directory, named from the workspace; members' tests are not planned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const g = try siblingGraph(a, dir, "app", "b = { path = \"../b\" }\n", try sibLock(a, sib_b_to_c), &why);
    // b, c and d each have tests/test_<name>.mojo; none of them is a unit, and no unit lists one as a source.
    try std.testing.expectEqual(@as(usize, 1), countKind(g, "test"));
    for (g.units) |u| {
        if (std.mem.eql(u8, u.kind, "test")) try std.testing.expectEqualStrings("app", u.package);
        for (u.srcs) |s| {
            try std.testing.expect(std.mem.indexOf(u8, s.path, "test_b.mojo") == null);
            try std.testing.expect(std.mem.indexOf(u8, s.path, "test_c.mojo") == null);
        }
    }
    const t =g.units[g.find("app@1.0.0#mojo1.0.0/test:app/tests/test_app.mojo") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("app/tests/test_app.mojo", t.srcs[0].path);
    try std.testing.expectEqualStrings("test_app.pass", t.outputs[0]);
}

test "a graph is the same bytes wherever the workspace is on disk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var one = std.testing.tmpDir(.{});
    defer one.cleanup();
    var two = std.testing.tmpDir(.{});
    defer two.cleanup();
    try writeSiblings(a, one.dir);
    try writeSiblings(a, two.dir);
    var why: []const u8 = "";
    const lock_text = try sibLock(a, sib_b_to_c);
    const g1 = try siblingGraph(a, try one.dir.realpathAlloc(a, "."), "app", "b = { path = \"../b\" }\n", lock_text, &why);
    const g2 = try siblingGraph(a, try two.dir.realpathAlloc(a, "."), "app", "b = { path = \"../b\" }\n", lock_text, &why);
    try std.testing.expectEqualStrings(try render(a, g1), try render(a, g2));
}

test "a member outside the workspace root is refused, naming the member and the root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // repo/app depends on ../../outside: below tmp, but not below the root repo.
    try writeSibling(a, tmp.dir, "repo/app", "app", "outside = { path = \"../../outside\" }\n");
    try writeSibling(a, tmp.dir, "outside", "outside", "");
    const dir = try tmp.dir.realpathAlloc(a, "repo");
    var why: []const u8 = "";
    const lock_text = try sibLock(a,
        \\{"name": "outside", "version": "0.1.0", "source": "path", "path": "../../outside"}
    );
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "app", "outside = { path = \"../../outside\" }\n", lock_text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the path dependency outside is ../../outside (resolves to ../outside), which is not below the workspace ") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, "not below the workspace ") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, dir) != null);
}

test "a member reached through another member is checked against the workspace root too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSibling(a, tmp.dir, "repo/app", "app", "b = { path = \"../b\" }\n");
    try writeSibling(a, tmp.dir, "repo/b", "b", "far = { path = \"../../far\" }\n");
    try writeSibling(a, tmp.dir, "far", "far", "");
    const dir = try tmp.dir.realpathAlloc(a, "repo");
    var why: []const u8 = "";
    // The lock holds every member's path relative to the package, whatever member names it.
    const lock_text = try sibLock(a,
        \\{"name": "b", "version": "0.1.0", "source": "path", "path": "../b", "deps": ["far"]},
        \\{"name": "far", "version": "0.1.0", "source": "path", "path": "../../far"}
    );
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "app", "b = { path = \"../b\" }\n", lock_text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the path dependency far is ../../far (resolves to ../far), which is not below the workspace ") != null);
}

test "a path that goes up and back down shows as written and as resolved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSibling(a, tmp.dir, "repo/app", "app", "x = { path = \"../x/../../x\" }\n");
    try writeSibling(a, tmp.dir, "x", "x", "");
    const dir = try tmp.dir.realpathAlloc(a, "repo");
    var why: []const u8 = "";
    const lock_text = try sibLock(a,
        \\{"name": "x", "version": "0.1.0", "source": "path", "path": "../x/../../x"}
    );
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "app", "x = { path = \"../x/../../x\" }\n", lock_text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the path dependency x is ../x/../../x (resolves to ../x), which is not below the workspace ") != null);
}

test "a member that is the workspace itself is refused with a path shown, not an empty one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSibling(a, tmp.dir, "repo/app", "app", "top = { path = \"..\" }\n");
    try put(tmp.dir, "repo/mopm.toml", "[package]\nname = \"top\"\nversion = \"0.1.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n");
    const dir = try tmp.dir.realpathAlloc(a, "repo");
    var why: []const u8 = "";
    const lock_text = try sibLock(a,
        \\{"name": "top", "version": "0.1.0", "source": "path", "path": ".."}
    );
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "app", "top = { path = \"..\" }\n", lock_text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the path dependency top is .. (resolves to .), which is not below the workspace ") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, " is , ") == null);
}

test "a path written with ./ segments or a trailing slash is the same member as the plain one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const lock_text = try sibLock(a,
        \\{"name": "b", "version": "0.1.0", "source": "path", "path": "./../b/./", "deps": ["c"]},
        \\{"name": "c", "version": "0.1.0", "source": "path", "path": "../c/"}
    );
    const g = try siblingGraph(a, dir, "app", "b = { path = \"./../b/./\" }\n", lock_text, &why);
    const plain = try siblingGraph(a, dir, "app", "b = { path = \"../b\" }\n", try sibLock(a, sib_b_to_c), &why);
    try std.testing.expectEqual(@as(usize, 3), countKind(g, "lib"));
    const b = g.units[g.find("b@0.1.0#mojo1.0.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("b/src/b", b.root);
    try std.testing.expectEqualStrings("b/src/b/__init__.mojo", b.srcs[0].path);
    const c = g.units[g.find("c@0.1.0#mojo1.0.0/lib") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("c/src/c", c.root);
    try std.testing.expectEqualStrings(try render(a, plain), try render(a, g));
}

test "a library that points into a sibling whose name starts with its package's name is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // app and app2 side by side: ../app2/... starts with "app" but is not inside app. Likewise mem and mem2 for a member.
    try writeSibling(a, tmp.dir, "app", "app", "");
    try writeSibling(a, tmp.dir, "app2", "app2", "");
    try writeSibling(a, tmp.dir, "mem", "mem", "");
    try writeSibling(a, tmp.dir, "mem2", "mem2", "");
    try put(tmp.dir, "mem/mopm.toml", "[package]\nname = \"mem\"\nversion = \"0.1.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n\n[targets]\nlib = { path = \"../mem2/src/mem2\" }\n");
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var diag: manifest.Diagnostic = .{};

    var why: []const u8 = "";
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ sib_root_toml, "\n[targets]\nlib = { path = \"../app2/src/app2\" }\n" }), &diag);
    const l = try lock.parse(a, try sibLock(a, ""), &why);
    try std.testing.expectError(error.Refused, build(a, .{ .dir = dir, .pkg = "app", .m = m, .members = &.{}, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the library of the root package is app2/src/app2, which is not inside its package app") != null);

    const lock_text = try sibLock(a,
        \\{"name": "mem", "version": "0.1.0", "source": "path", "path": "../mem"}
    );
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "app", "mem = { path = \"../mem\" }\n", lock_text, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the library of a path dependency is mem2/src/mem2, which is not inside its package mem") != null);
}

test "without a workspace root a sibling is refused as it always was: the workspace is the package directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    const dir = try tmp.dir.realpathAlloc(a, "app");
    var why: []const u8 = "";
    try std.testing.expectError(error.Refused, siblingGraph(a, dir, "", "b = { path = \"../b\" }\n", try sibLock(a, sib_b_to_c), &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the path dependency b is ../b, which is not below the workspace ") != null);
}

test "a library or binary that leaves its package for a sibling's directory is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    try put(tmp.dir, "b/src/other/__init__.mojo", util_init);
    // app's [targets] lib points into b's tree, which is below the workspace root but not inside app.
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ sib_root_toml, "b = { path = \"../b\" }\n\n[targets]\nlib = { path = \"../b/src/other\" }\n" }), &diag);
    const l = try lock.parse(a, try sibLock(a, sib_b_to_c), &why);
    try std.testing.expectError(error.Refused, build(a, .{ .dir = dir, .pkg = "app", .m = m, .members = &.{}, .l = l, .subdir = "linux-64", .mojo = "1.0.0", .toolchain = fakeToolchain("1.0.0") }, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "the library of the root package is b/src/other, which is not inside its package app") != null);
}

// ----------------------------------------- a member's natives under a workspace root

fn nativeSection(a: Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\n[native.{s}]\nkind = \"static\"\nsrcs = [\"native/*.c\"]\nhdrs = [\"native/*.h\"]\n", .{id});
}

// Defect it catches: a member's native named, or its sources located, by where the package sits in the workspace
// instead of by the package, so that with --workspace-root the unit is `native:src/app/...` or reads files from the
// workspace root (the plan refuses or builds the wrong sources).
test "with a workspace root, the root package's and a sibling's own natives are native:<package>/<id> with workspace paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSiblings(a, tmp.dir);
    try put(tmp.dir, "app/native/app.c", c_app);
    try put(tmp.dir, "app/native/app.h", h_app);
    try put(tmp.dir, "b/native/shim.c", c_util);
    try put(tmp.dir, "b/native/shim.h", h_util);
    // b's manifest, as writeSibling made it, with a native of its own.
    try put(tmp.dir, "b/mopm.toml", try std.mem.concat(a, u8, &.{
        "[package]\nname = \"b\"\nversion = \"0.1.0\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\nc = { path = \"../c\" }\n",
        try nativeSection(a, "b_shim"),
    }));
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    const deps = try std.mem.concat(a, u8, &.{ "b = { path = \"../b\" }\n", try nativeSection(a, "app_shim") });
    const g = siblingGraph(a, dir, "app", deps, try sibLock(a, sib_b_to_c), &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };

    // The root package's native: named by the package, its files by their path from the workspace.
    const na = g.units[g.find("native:app/app_shim") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("app", na.package);
    try std.testing.expectEqualStrings("libapp_shim.a", na.soname);
    try std.testing.expectEqual(@as(usize, 1), na.srcs.len);
    try std.testing.expectEqualStrings("app/native/app.c", na.srcs[0].path);
    try std.testing.expectEqualStrings(try sha256Hex(a, c_app), na.srcs[0].sha256);
    try std.testing.expectEqualStrings("app/native/app.h", na.hdrs[0].path);
    // Its include directory is relative to the member.
    try std.testing.expectEqualStrings("native", na.includes[0]);

    // The sibling's native, reached through a path dependency.
    const nb = g.units[g.find("native:b/b_shim") orelse return error.NoSuchUnit];
    try std.testing.expectEqualStrings("b", nb.package);
    try std.testing.expectEqualStrings("b/native/shim.c", nb.srcs[0].path);
    try std.testing.expectEqualStrings("b/native/shim.h", nb.hdrs[0].path);
    try std.testing.expectEqualStrings("native", nb.includes[0]);
    try std.testing.expectEqual(@as(usize, 2), countKind(g, "native"));

    // The root's library links both (neither needs the other), each listed as built by its own unit.
    const app = g.units[g.find(id_app).?];
    try std.testing.expectEqual(@as(usize, 2), app.natives.len);
    var saw_a = false;
    var saw_b = false;
    for (app.natives) |n| {
        if (std.mem.eql(u8, n.built, "native:app/app_shim")) saw_a = true;
        if (std.mem.eql(u8, n.built, "native:b/b_shim")) saw_b = true;
    }
    try std.testing.expect(saw_a and saw_b);
    // b's library lists only its own.
    const bl = g.units[g.find("b@0.1.0#mojo1.0.0/lib").?];
    try std.testing.expectEqual(@as(usize, 1), bl.natives.len);
    try std.testing.expectEqualStrings("native:b/b_shim", bl.natives[0].built);
    try noDotDot(g);
}

// Defect it catches: a member with `publish = false` treated differently from any other when the graph is made (left out,
// refused, or keyed differently), so a test-support helper stops being usable as a path dependency.
test "a member with publish = false is in the graph exactly as the same member without the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var texts: [2][]const u8 = undefined;
    for ([_][]const u8{ toml_util, toml_util ++ "publish = false\n" }, 0..) |util_toml, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeWorkspace(tmp.dir, app_init);
        try put(tmp.dir, "util/mopm.toml", util_toml);
        const dir = try tmp.dir.realpathAlloc(a, ".");
        var why: []const u8 = "";
        const g = graphOf(a, dir, toml_util_dep, lock_two, "1.0.0", &why) catch |e| {
            std.debug.print("refused: {s}\n", .{why});
            return e;
        };
        try std.testing.expect(g.find("util@0.3.0#mojo1.0.0/lib") != null);
        texts[i] = try std.mem.replaceOwned(u8, a, try render(a, g), dir, "<dir>");
    }
    try std.testing.expectEqualStrings(texts[0], texts[1]);
}
