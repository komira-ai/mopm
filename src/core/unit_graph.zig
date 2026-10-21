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

pub const format_version: u32 = 1;

pub const Src = struct { path: []const u8, sha256: []const u8 };
/// A native library in a unit's dependency closure: pinned by `sha256`, from `package`. `kind`, `needs` and `exclusive`
/// are the package's declarations (the lock copies them); the unit's natives are in link order (see `orderNatives`).
pub const NativeRef = struct {
    id: []const u8,
    soname: []const u8,
    sha256: []const u8,
    package: []const u8,
    kind: metadata.Kind = .shared,
    needs: []const []const u8 = &.{},
    exclusive: []const u8 = "",
};
/// A prebuilt unit's download: the `.conda` holding its `.mojoc`.
pub const Archive = struct { url: []const u8, sha256: []const u8, size: u64 };
pub const Profile = struct { opt: u32, assert: []const u8, debug: bool };

pub const Unit = struct {
    id: []const u8,
    package: []const u8,
    version: []const u8,
    /// `lib`, `test`, `bin` or `prebuilt`.
    kind: []const u8,
    /// lib: the package directory, relative to the workspace.
    root: []const u8 = "",
    srcs: []const Src = &.{},
    deps: []const []const u8 = &.{},
    natives: []const NativeRef = &.{},
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

pub const Graph = struct {
    unit_graph: u32 = format_version,
    /// `<name>@<version>` of the root package.
    package: []const u8,
    /// The consumer's Mojo version: the one every unit id names.
    mojo: []const u8,
    toolchain: Toolchain,
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

const closure_linux_64 = @embedFile("toolchain/mojo-1.0.0-linux-64.json");
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

/// The subdir whose toolchain closure a version 2 lock records.
pub const lock_subdir = "linux-64";

/// The Mojo versions and subdirs a unit graph can be made for.
pub const supported = "mojo 1.0.0 on linux-64";

/// mopm's pinned toolchain for `mojo` on `subdir`, or a refusal.
pub fn toolchainFor(arena: Allocator, mojo: []const u8, subdir: []const u8, why: *[]const u8) anyerror!Toolchain {
    if (!std.mem.eql(u8, mojo, "1.0.0") or !std.mem.eql(u8, subdir, "linux-64")) {
        return refuse(arena, why, "mopm has no pinned toolchain for mojo {s} on {s} (it pins {s})", .{ mojo, subdir, supported });
    }
    const c = closure.parse(arena, closure_linux_64) catch return error.BadPins;
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
        const wanted = std.mem.eql(u8, p.name, "mojo-compiler") or std.mem.eql(u8, p.name, "libgcc") or std.mem.eql(u8, p.name, "libstdcxx");
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
    if (comps.items.len != 3) return error.BadPins;
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
    /// The workspace directory: every path below is relative to it.
    dir: []const u8,
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
        if (rel.len == 0 or rel[0] == '/' or std.mem.eql(u8, rel, "..") or std.mem.startsWith(u8, rel, "../") or std.mem.indexOf(u8, rel, "/../") != null or std.mem.endsWith(u8, rel, "/..")) {
            return b.fail("{s} is {s}, which is not below the workspace; a unit graph takes members below the workspace only", .{ what, rel });
        }
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
        const at = try b.join(member_rel, rel);
        const full = try std.fs.path.join(b.arena, &.{ b.in.dir, at });
        var d = std.fs.cwd().openDir(full, .{}) catch return null;
        d.close();
        return at;
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
            try b.checkBelow("the path dependency", p.path);
            const file = try b.join(p.path, "mopm.toml");
            const text = try b.readRel(file);
            var diag: manifest.Diagnostic = .{};
            const pm = manifest.parse(b.arena, text, &diag) catch |e| {
                return b.fail("{s}:{d}:{d}: {s}", .{ file, diag.pos.line, diag.pos.col, if (e == error.Invalid) diag.message else @errorName(e) });
            };
            try b.listsMojo(file, pm);
            const lib_rel = (try b.defaultLib(pm, p.path)) orelse return b.fail("{s} has no library directory (src/{s} or [targets] lib)", .{ file, pm.package.name });
            try b.checkBelow("the library of a path dependency", lib_rel);
            try b.addLib(pm, p.path, ids, lib_rel);
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
        for (b.units.items, 0..) |_, i| {
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
                        try found.append(.{ .id = n.id, .soname = n.soname, .sha256 = sha, .package = p.name, .kind = n.kind, .needs = n.needs, .exclusive = n.exclusive });
                    }
                }
                for (u.deps) |d| {
                    const di = index.get(d) orelse return b.fail("{s} depends on {s}, which is no unit", .{ u.id, d });
                    try todo.append(di);
                }
            }
            std.mem.sort(NativeRef, found.items, {}, Builder.lessNative);
            b.units.items[i].natives = try b.orderNatives(b.units.items[i].id, found.items);
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
    var b = Builder{ .arena = arena, .in = in, .why = why, .units = std.ArrayList(Unit).init(arena) };
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

    const dep_ids = try b.depIds(root_id, dep_names.items);
    const dev_ids = try b.depIds(root_id, dev_names.items);

    // The root package: its library, its binaries, its tests.
    const lib_rel = try b.defaultLib(m, "");
    var lib_id: ?[]const u8 = null;
    if (lib_rel) |lr| {
        try b.checkBelow("the library of the root package", lr);
        try b.addLib(m, "", dep_ids, lr);
        lib_id = b.units.items[b.units.items.len - 1].id;
    }
    var bin_deps = std.ArrayList([]const u8).init(arena);
    if (lib_id) |id| try bin_deps.append(id) else try bin_deps.appendSlice(dep_ids);
    for (m.targets.bins) |bin| {
        try b.checkBelow("a binary's source", bin.path);
        try b.units.append(.{
            .id = try std.fmt.allocPrint(arena, "{s}/bin:{s}", .{ root_id, bin.name }),
            .package = m.package.name,
            .version = m.package.version,
            .kind = "bin",
            .srcs = try arena.dupe(Src, &.{try b.src(bin.path)}),
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
    const files = try test_harness.findTestFiles(arena, in.dir);
    for (files) |f| {
        const stem = std.fs.path.stem(f);
        try b.units.append(.{
            .id = try std.fmt.allocPrint(arena, "{s}/test:{s}", .{ root_id, f }),
            .package = m.package.name,
            .version = m.package.version,
            .kind = "test",
            .srcs = try arena.dupe(Src, &.{try b.src(f)}),
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
    try b.keys();
    return .{
        .package = try std.fmt.allocPrint(arena, "{s}@{s}", .{ m.package.name, m.package.version }),
        .mojo = in.mojo,
        .toolchain = tc,
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
    if (u.srcs.len > 0) {
        try w.print(",\n{s}  \"srcs\": [", .{ind});
        for (u.srcs, 0..) |s, i| {
            try w.print("{s}\n{s}    {{\"path\": ", .{ if (i == 0) "" else ",", ind });
            try str(w, s.path);
            try w.writeAll(", \"sha256\": ");
            try str(w, s.sha256);
            try w.writeAll("}");
        }
        try w.print("\n{s}  ]", .{ind});
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
        try w.writeAll(", \"sha256\": ");
        try str(w, n.sha256);
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
        try w.writeAll("}");
    }
    if (u.natives.len == 0) try w.writeAll("]") else try w.print("\n{s}  ]", .{ind});
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
    try w.writeAll("\n    ]\n  },\n  \"units\": [");
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
    \\  "unit_graph": 1,
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

test "planted defects: a reordered dependency, a changed source or another artifact changes the keys, and only the right ones" {
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
    try std.testing.expectEqualStrings("mopm has no pinned toolchain for mojo 1.1.0 on linux-64 (it pins mojo 1.0.0 on linux-64)", why);
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
// Mutant planted: `orderNatives` returns `natives` as sorted by soname.
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
// otherwise (and a unit key that should change with it) prints the same. Mutant planted: `writeUnit` drops `kind`.
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
