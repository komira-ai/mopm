//! The native libraries a test may load, as a pre-resolved, pinned catalog.
//!
//! A package can name a system library it loads at run time (`[native-dependencies] libsqlite =
//! { mode = "load" }`). To run its tests hermetically, the library has to come from a pinned conda
//! package, not from whatever the machine has. Like the Mojo toolchain (closure.zig) this has no
//! solver at run time: for each platform (linux-64, linux-aarch64, osx-arm64) a committed file,
//! src/core/toolchain/natives-<subdir>.json, lists the conda packages of every allow-listed native
//! and of everything it needs to run, each with its url, sha256 and size. It does not depend on
//! the Mojo version.
//!
//! The files are made by `mopm-closure --natives` from toolchain/natives.txt (the allow-listed
//! names, the roots) and toolchain/natives.pixi.lock (a solver's answer for all of them at once,
//! made by the `toolchain` job of .github/workflows/kpin-update.yml).
//!
//! What a file leaves out of a native's closure, because the toolchain already supplies it:
//!   - virtual packages (`__glibc`, `__osx`): the machine's, not a package;
//!   - the platform's own packages (`platform_provided`): the toolchain components a unit graph
//!     stages and puts on the loader path (libgcc, libstdcxx, mojo-compiler on Linux), and libcxx on
//!     macOS, which the OS supplies. Every package the toolchain stages is out of the catalog.
//! What is kept: every other package, libzlib included, although the Mojo closure files list it
//! too, because only the toolchain components are staged, not the rest of that closure.
//!
//! Two checks fail the generator, so a catalog is never committed that would not load:
//!   - closed world: after the drops, everything a native needs is in the catalog;
//!   - floors: a dropped Linux component is pinned by each Mojo version's closure, and that
//!     version must satisfy every `libgcc >=N` / `libstdcxx >=N` the natives' packages ask for.
//!     A library built for a newer libgcc than the one staged loads and then misses symbols.
//!
//! A file is JSON, 2-space indented, keys in the order of `Catalog`:
//!
//!   {"format": 1, "subdir": "linux-64", "channels": [...], "roots": ["bzip2", ...],
//!    "provided": ["libgcc", ...],
//!    "packages": [{"name": ..., "version": ..., "build": ..., "build_number": ..., "subdir": ...,
//!                  "channel": ..., "path": ..., "sha256": ..., "size": ..., "depends": [<names>],
//!                  "license": ...}]}
//!
//! `depends` is reduced to names of packages of this file. The download url of a package is its
//! channel's url followed by its path, as in closure.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const closure = @import("closure.zig");
const unit_graph = @import("unit_graph.zig");
const testroot = @import("testroot.zig");
const Package = closure.Package;
const Channel = closure.Channel;

pub const format_version: u32 = 1;

pub const Catalog = struct {
    format: u32 = format_version,
    /// The platform.
    subdir: []const u8,
    channels: []const Channel,
    /// The allow-listed conda names, sorted.
    roots: []const []const u8,
    /// The platform's own packages, left out of every closure (`platform_provided`), sorted.
    provided: []const []const u8,
    /// The roots and everything they need, sorted by name. `depends` holds names of this list.
    packages: []const Package,
};

/// What the toolchain of one platform supplies, so a native's closure does not repeat it. The one
/// list of it in code.
pub const Provided = struct {
    subdir: []const u8,
    /// Package names left out of a closure.
    names: []const []const u8,
    /// Of `names`, the ones a Mojo closure pins and whose version a native's `>=N` must be met by.
    floored: []const []const u8,
};

pub const platform_provided = [_]Provided{
    .{ .subdir = "linux-64", .names = &.{ "libgcc", "libstdcxx", "mojo-compiler" }, .floored = &.{ "libgcc", "libstdcxx" } },
    .{ .subdir = "linux-aarch64", .names = &.{ "libgcc", "libstdcxx", "mojo-compiler" }, .floored = &.{ "libgcc", "libstdcxx" } },
    .{ .subdir = "osx-arm64", .names = &.{ "libcxx", "mojo-compiler" }, .floored = &.{} },
};

pub fn providedFor(subdir: []const u8) ?Provided {
    for (platform_provided) |p| {
        if (std.mem.eql(u8, p.subdir, subdir)) return p;
    }
    return null;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// The package name of a conda spec (`libgcc >=14`: `libgcc`).
pub fn specName(spec: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, spec, " \t");
    return it.next() orelse "";
}

fn isVirtual(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__");
}

// ------------------------------------------------------------ versions

const Tok = union(enum) { num: u64, str: []const u8 };

/// A conda version as runs of digits and letters; `.`, `_`, `-` and `+` only separate.
fn tokens(arena: Allocator, v: []const u8) Allocator.Error![]Tok {
    var out = std.ArrayList(Tok).init(arena);
    var i: usize = 0;
    while (i < v.len) {
        const c = v[i];
        if (std.ascii.isDigit(c)) {
            var j = i;
            while (j < v.len and std.ascii.isDigit(v[j])) j += 1;
            try out.append(.{ .num = std.fmt.parseInt(u64, v[i..j], 10) catch std.math.maxInt(u64) });
            i = j;
        } else if (std.ascii.isAlphabetic(c)) {
            var j = i;
            while (j < v.len and std.ascii.isAlphabetic(v[j])) j += 1;
            try out.append(.{ .str = v[i..j] });
            i = j;
        } else i += 1;
    }
    return out.items;
}

/// Orders two conda versions: a missing component is 0, and a letter run (`a0`, `rc1`) is below
/// any number, so `2.0a0` is below `2.0`.
pub fn compareVersions(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error!std.math.Order {
    const ta = try tokens(arena, a);
    const tb = try tokens(arena, b);
    const zero = Tok{ .num = 0 };
    var i: usize = 0;
    while (i < @max(ta.len, tb.len)) : (i += 1) {
        const x = if (i < ta.len) ta[i] else zero;
        const y = if (i < tb.len) tb[i] else zero;
        switch (x) {
            .num => |xn| switch (y) {
                .num => |yn| if (xn != yn) return std.math.order(xn, yn),
                .str => return .gt,
            },
            .str => |xs| switch (y) {
                .num => return .lt,
                .str => |ys| {
                    const o = std.mem.order(u8, xs, ys);
                    if (o != .eq) return o;
                },
            },
        }
    }
    return .eq;
}

fn tokEql(a: Tok, b: Tok) bool {
    return switch (a) {
        .num => |x| b == .num and b.num == x,
        .str => |x| b == .str and std.mem.eql(u8, x, b.str),
    };
}

pub const SpecError = error{UnsupportedSpec} || Allocator.Error;

/// Whether `version` meets `constraint`, the version part of a conda spec: clauses joined by `,`
/// (all must hold), each `>=v`, `<=v`, `>v`, `<v`, `==v`, `!=v`, `=v`, `v`, `v.*` or `*`. Anything
/// else (`|`, a build string) is `error.UnsupportedSpec`: the floor check fails closed.
pub fn satisfies(arena: Allocator, version: []const u8, constraint: []const u8) SpecError!bool {
    var clauses = std.mem.splitScalar(u8, constraint, ',');
    while (clauses.next()) |raw| {
        const clause = std.mem.trim(u8, raw, " \t");
        if (clause.len == 0) return error.UnsupportedSpec;
        if (std.mem.indexOfAny(u8, clause, "| \t()") != null) return error.UnsupportedSpec;
        if (std.mem.eql(u8, clause, "*")) continue;
        const ops = [_][]const u8{ ">=", "<=", "==", "!=", ">", "<", "=" };
        var op: []const u8 = "";
        for (ops) |o| {
            if (std.mem.startsWith(u8, clause, o)) {
                op = o;
                break;
            }
        }
        const operand = clause[op.len..];
        if (operand.len == 0) return error.UnsupportedSpec;
        const wild = std.mem.endsWith(u8, operand, ".*");
        if (wild or std.mem.endsWith(u8, operand, "*")) {
            if (op.len != 0 and !std.mem.eql(u8, op, "=") and !std.mem.eql(u8, op, "==")) return error.UnsupportedSpec;
            const stem = std.mem.trimRight(u8, operand, ".*");
            const tv = try tokens(arena, version);
            const ts = try tokens(arena, stem);
            if (ts.len > tv.len) return false;
            for (ts, 0..) |t, i| {
                if (!tokEql(t, tv[i])) return false;
            }
            continue;
        }
        const o = try compareVersions(arena, version, operand);
        const ok = if (op.len == 0 or std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "="))
            o == .eq
        else if (std.mem.eql(u8, op, ">="))
            o != .lt
        else if (std.mem.eql(u8, op, "<="))
            o != .gt
        else if (std.mem.eql(u8, op, ">"))
            o == .gt
        else if (std.mem.eql(u8, op, "<"))
            o == .lt
        else
            o != .eq;
        if (!ok) return false;
    }
    return true;
}

// ------------------------------------------------------------ the catalog

pub fn find(c: Catalog, name: []const u8) ?Package {
    for (c.packages) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// The packages `name` needs to run, itself included: its closure in the catalog, sorted by name.
/// An empty list when `name` is not in the catalog.
pub fn closureOf(arena: Allocator, c: Catalog, name: []const u8) Allocator.Error![]const Package {
    var seen = std.StringHashMap(void).init(arena);
    var out = std.ArrayList(Package).init(arena);
    var todo = std.ArrayList([]const u8).init(arena);
    try todo.append(name);
    while (todo.popOrNull()) |n| {
        const p = find(c, n) orelse continue;
        if ((try seen.fetchPut(n, {})) != null) continue;
        try out.append(p);
        for (p.depends) |d| try todo.append(d);
    }
    std.mem.sort(Package, out.items, {}, lessPackage);
    return out.items;
}

fn lessPackage(_: void, a: Package, b: Package) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Why `c` cannot be used, or null: the checks a reader of a committed file relies on (a pinned
/// sha256 and size for every file, no duplicate names, `.conda` files only, the roots present,
/// every `depends` name in the file, nothing the platform provides, nothing unreachable from a
/// root).
pub fn problem(arena: Allocator, c: Catalog) Allocator.Error!?[]const u8 {
    if (c.format != format_version) return try std.fmt.allocPrint(arena, "format {d}; this mopm reads format {d}", .{ c.format, format_version });
    const prov = providedFor(c.subdir) orelse return try std.fmt.allocPrint(arena, "subdir {s} is not one mopm supports", .{c.subdir});
    if (c.roots.len == 0) return "the catalog has no roots";
    for (c.channels) |ch| {
        if (ch.name.len == 0 or !std.mem.endsWith(u8, ch.url, "/"))
            return try std.fmt.allocPrint(arena, "channel '{s}': the url must end with '/'", .{ch.name});
        if (!std.mem.startsWith(u8, ch.url, "https://"))
            return try std.fmt.allocPrint(arena, "channel '{s}': the url must be https", .{ch.name});
    }
    const want_provided = try arena.dupe([]const u8, prov.names);
    std.mem.sort([]const u8, want_provided, {}, lessStr);
    if (c.provided.len != want_provided.len) return "provided is not the platform's list";
    for (c.provided, want_provided) |n, want| {
        if (!std.mem.eql(u8, n, want)) return try std.fmt.allocPrint(arena, "provided lists {s}, not {s}", .{ n, want });
    }
    var names = std.StringHashMap(void).init(arena);
    for (c.packages) |p| {
        if (p.name.len == 0 or p.version.len == 0 or p.build.len == 0)
            return try std.fmt.allocPrint(arena, "a package has no name, version or build ({s})", .{p.path});
        if ((try names.fetchPut(p.name, {})) != null) return try std.fmt.allocPrint(arena, "{s} is listed twice", .{p.name});
        if (contains(prov.names, p.name) or isVirtual(p.name))
            return try std.fmt.allocPrint(arena, "{s} is the platform's, not the catalog's", .{p.name});
        if (p.sha256.len != 64) return try std.fmt.allocPrint(arena, "{s}: sha256 is not 64 lowercase hex digits", .{p.name});
        for (p.sha256) |ch| {
            if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f'))
                return try std.fmt.allocPrint(arena, "{s}: sha256 is not 64 lowercase hex digits", .{p.name});
        }
        if (p.size == 0) return try std.fmt.allocPrint(arena, "{s}: size is 0", .{p.name});
        var have_channel = false;
        for (c.channels) |ch| have_channel = have_channel or std.mem.eql(u8, ch.name, p.channel);
        if (!have_channel) return try std.fmt.allocPrint(arena, "{s}: channel '{s}' is not listed", .{ p.name, p.channel });
        const want_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}-{s}.conda", .{ p.subdir, p.name, p.version, p.build });
        if (!std.mem.eql(u8, want_path, p.path))
            return try std.fmt.allocPrint(arena, "{s}: path {s} is not {s}", .{ p.name, p.path, want_path });
        if (!std.mem.eql(u8, p.subdir, c.subdir) and !std.mem.eql(u8, p.subdir, "noarch"))
            return try std.fmt.allocPrint(arena, "{s}: subdir {s} is neither {s} nor noarch", .{ p.name, p.subdir, c.subdir });
    }
    for (c.packages) |p| {
        for (p.depends) |d| {
            if (!names.contains(d)) return try std.fmt.allocPrint(arena, "{s} needs {s}, which the catalog does not have", .{ p.name, d });
        }
    }
    var reach = std.StringHashMap(void).init(arena);
    for (c.roots) |r| {
        if (!names.contains(r)) return try std.fmt.allocPrint(arena, "root {s} is not in the catalog", .{r});
        for (try closureOf(arena, c, r)) |p| try reach.put(p.name, {});
    }
    for (c.packages) |p| {
        if (!reach.contains(p.name)) return try std.fmt.allocPrint(arena, "{s} is not needed by any root", .{p.name});
    }
    return null;
}

pub fn parse(arena: Allocator, text: []const u8) !Catalog {
    return std.json.parseFromSliceLeaky(Catalog, arena, text, .{});
}

pub fn render(arena: Allocator, c: Catalog) ![]u8 {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(c, .{ .whitespace = .indent_2 }, out.writer());
    try out.append('\n');
    return out.items;
}

/// Where `p` is downloaded from: its channel's url and its path.
pub fn urlOf(arena: Allocator, c: Catalog, p: Package) ![]u8 {
    for (c.channels) |ch| {
        if (std.mem.eql(u8, ch.name, p.channel)) return std.fmt.allocPrint(arena, "{s}{s}", .{ ch.url, p.path });
    }
    return error.UnknownChannel;
}

/// The committed catalog of a platform, embedded; null for a platform with none.
fn embedded(subdir: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, subdir, "linux-64")) return @embedFile("toolchain/natives-linux-64.json");
    if (std.mem.eql(u8, subdir, "linux-aarch64")) return @embedFile("toolchain/natives-linux-aarch64.json");
    if (std.mem.eql(u8, subdir, "osx-arm64")) return @embedFile("toolchain/natives-osx-arm64.json");
    return null;
}

/// The catalog this mopm pins for `subdir`, or null for a platform it has none for.
pub fn forSubdir(arena: Allocator, subdir: []const u8) !?Catalog {
    const text = embedded(subdir) orelse return null;
    return try parse(arena, text);
}

// ------------------------------------------------------------ generation

pub const GenError = error{BadLock} || Allocator.Error;

/// The catalog for `subdir` from the pixi lock `text`, whose environment holds `roots` and what
/// they need. `toolchains` are the Mojo closures of this platform, one per Mojo version, which
/// the floor check reads the staged libgcc and libstdcxx versions from. `diag` says what is wrong
/// when it returns `error.BadLock`.
pub fn fromPixiLock(arena: Allocator, text: []const u8, subdir: []const u8, roots: []const []const u8, toolchains: []const closure.Closure, diag: *[]const u8) GenError!Catalog {
    const prov = providedFor(subdir) orelse {
        diag.* = try std.fmt.allocPrint(arena, "subdir {s} is not one mopm supports", .{subdir});
        return error.BadLock;
    };
    const locked = try closure.lockedPackages(arena, text, subdir, diag);
    var raw = std.StringHashMap(Package).init(arena);
    for (locked.packages) |p| try raw.put(p.name, p);

    // The closure of the roots, through every name that is neither virtual nor the platform's.
    var keep = std.StringHashMap(void).init(arena);
    var todo = std.ArrayList([]const u8).init(arena);
    for (roots) |r| {
        if (!raw.contains(r)) {
            diag.* = try std.fmt.allocPrint(arena, "{s}: the lock has no {s} for {s}; a native that is missing on a platform stays off the allow-list", .{ r, r, subdir });
            return error.BadLock;
        }
        try todo.append(r);
    }
    while (todo.popOrNull()) |n| {
        if ((try keep.fetchPut(n, {})) != null) continue;
        const p = raw.get(n).?;
        for (p.depends) |spec| {
            const d = specName(spec);
            if (isVirtual(d) or contains(prov.names, d)) continue;
            if (!raw.contains(d)) {
                diag.* = try std.fmt.allocPrint(arena, "{s} needs {s}, which is neither in the lock for {s} nor provided by the platform ({s}); the catalog is closed", .{ p.name, d, subdir, try std.mem.join(arena, ", ", prov.names) });
                return error.BadLock;
            }
            try todo.append(d);
        }
    }

    try checkFloors(arena, raw, keep, prov, toolchains, subdir, diag);

    var pkgs = std.ArrayList(Package).init(arena);
    var it = keep.keyIterator();
    while (it.next()) |n| {
        const p = raw.get(n.*).?;
        var deps = std.ArrayList([]const u8).init(arena);
        for (p.depends) |spec| {
            const d = specName(spec);
            if (isVirtual(d) or contains(prov.names, d)) continue;
            var dup = false;
            for (deps.items) |x| dup = dup or std.mem.eql(u8, x, d);
            if (!dup) try deps.append(d);
        }
        std.mem.sort([]const u8, deps.items, {}, lessStr);
        try pkgs.append(.{
            .name = p.name,
            .version = p.version,
            .build = p.build,
            .build_number = p.build_number,
            .subdir = p.subdir,
            .channel = p.channel,
            .path = p.path,
            .sha256 = p.sha256,
            .size = p.size,
            .depends = deps.items,
            .license = p.license,
        });
    }
    std.mem.sort(Package, pkgs.items, {}, lessPackage);
    // Only the channels a kept package comes from.
    var channels = std.ArrayList(Channel).init(arena);
    for (locked.channels) |ch| {
        for (pkgs.items) |p| {
            if (std.mem.eql(u8, p.channel, ch.name)) {
                try channels.append(ch);
                break;
            }
        }
    }
    const sorted_roots = try arena.dupe([]const u8, roots);
    std.mem.sort([]const u8, sorted_roots, {}, lessStr);
    const sorted_prov = try arena.dupe([]const u8, prov.names);
    std.mem.sort([]const u8, sorted_prov, {}, lessStr);
    const cat = Catalog{ .subdir = subdir, .channels = channels.items, .roots = sorted_roots, .provided = sorted_prov, .packages = pkgs.items };
    if (try problem(arena, cat)) |why| {
        diag.* = why;
        return error.BadLock;
    }
    return cat;
}

/// Every kept package's `libgcc >=N`-style spec on a floored platform component is met by the
/// version each Mojo version's closure pins.
fn checkFloors(arena: Allocator, raw: std.StringHashMap(Package), keep: std.StringHashMap(void), prov: Provided, toolchains: []const closure.Closure, subdir: []const u8, diag: *[]const u8) GenError!void {
    var it = keep.keyIterator();
    while (it.next()) |n| {
        const p = raw.get(n.*).?;
        for (p.depends) |spec| {
            const d = specName(spec);
            if (!contains(prov.floored, d)) continue;
            if (toolchains.len == 0) {
                diag.* = try std.fmt.allocPrint(arena, "{s} needs {s}, and no Mojo closure for {s} was given to check the floor against", .{ p.name, spec, subdir });
                return error.BadLock;
            }
            const constraint = std.mem.trim(u8, spec[std.mem.indexOf(u8, spec, d).? + d.len ..], " \t");
            for (toolchains) |tc| {
                var staged: ?[]const u8 = null;
                for (tc.packages) |tp| {
                    if (std.mem.eql(u8, tp.name, d)) staged = tp.version;
                }
                const v = staged orelse {
                    diag.* = try std.fmt.allocPrint(arena, "{s} needs {s}, but the closure of mojo {s} for {s} has no {s}", .{ p.name, spec, tc.mojo, subdir, d });
                    return error.BadLock;
                };
                const ok = satisfies(arena, v, constraint) catch |e| switch (e) {
                    error.UnsupportedSpec => {
                        diag.* = try std.fmt.allocPrint(arena, "{s}: cannot check '{s}' against {s} {s}", .{ p.name, spec, d, v });
                        return error.BadLock;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (!ok) {
                    diag.* = try std.fmt.allocPrint(arena, "{s} {s} needs '{s}', but mojo {s} stages {s} {s} for {s}", .{ p.name, p.version, spec, tc.mojo, d, v, subdir });
                    return error.BadLock;
                }
            }
        }
    }
}

// ---------------------------------------------------------------- tests

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

const Fx = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    deps: []const []const u8,
};

/// A pixi lock for one platform holding `pkgs`, every package a conda-forge file of the platform.
fn lockFor(a: Allocator, subdir: []const u8, pkgs: []const Fx) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.print("version: 7\nenvironments:\n  default:\n    channels:\n    - url: https://conda.anaconda.org/conda-forge/\n    packages:\n      {s}:\n", .{subdir});
    for (pkgs) |p| try w.print("      - conda: https://conda.anaconda.org/conda-forge/{s}/{s}-{s}-{s}.conda\n", .{ subdir, p.name, p.version, p.build });
    try w.writeAll("packages:\n");
    for (pkgs, 0..) |p, i| {
        try w.print("- conda: https://conda.anaconda.org/conda-forge/{s}/{s}-{s}-{s}.conda\n  sha256: {x:0>64}\n  md5: {x:0>32}\n", .{ subdir, p.name, p.version, p.build, i + 1, i + 1 });
        if (p.deps.len == 0) try w.writeAll("  depends: []\n") else {
            try w.writeAll("  depends:\n");
            for (p.deps) |d| try w.print("  - {s}\n", .{d});
        }
        try w.print("  license: blessing\n  size: {d}\n  timestamp: 1700000000000\n", .{100 + i});
    }
    return out.items;
}

fn linuxFixture(a: Allocator, sqlite_dep: []const u8) ![9]Fx {
    return .{
        .{ .name = "libsqlite", .version = "3.54.1", .build = "h1_101", .deps = try a.dupe([]const u8, &.{ "__glibc >=2.17,<3.0.a0", "libgcc >=15", "libzlib >=1.3.2,<2.0a0", sqlite_dep }) },
        .{ .name = "libzlib", .version = "1.3.2", .build = "h2_3", .deps = &.{"__glibc >=2.17,<3.0.a0"} },
        .{ .name = "libbrotlidec", .version = "1.2.1", .build = "h3_0", .deps = &.{ "__glibc >=2.17,<3.0.a0", "libbrotlicommon 1.2.1 h4_0", "libgcc >=15" } },
        .{ .name = "libbrotlicommon", .version = "1.2.1", .build = "h4_0", .deps = &.{ "__glibc >=2.17,<3.0.a0", "libgcc >=15" } },
        .{ .name = "libgcc", .version = "16.2.0", .build = "h5_7", .deps = &.{ "__glibc >=2.17,<3.0.a0", "_openmp_mutex >=4.5" } },
        .{ .name = "_openmp_mutex", .version = "4.5", .build = "20_gnu", .deps = &.{ "libgomp >=7.5.0", "libgcc >=7.5.0" } },
        .{ .name = "libgomp", .version = "16.2.0", .build = "h6_7", .deps = &.{"__glibc >=2.17,<3.0.a0"} },
        .{ .name = "libstdcxx", .version = "16.2.0", .build = "h7_7", .deps = &.{ "__glibc >=2.17,<3.0.a0", "libgcc 16.2.0 h5_7" } },
        .{ .name = "extra-unused", .version = "1.0", .build = "h8_0", .deps = &.{} },
    };
}

fn stagedLinux(libgcc: []const u8, libstdcxx: []const u8) [2]Package {
    return .{
        .{ .name = "libgcc", .version = libgcc, .build = "b", .subdir = "linux-64", .channel = "conda-forge", .path = "", .sha256 = "", .size = 1 },
        .{ .name = "libstdcxx", .version = libstdcxx, .build = "b", .subdir = "linux-64", .channel = "conda-forge", .path = "", .sha256 = "", .size = 1 },
    };
}

fn toolchainOf(pkgs: []const Package) closure.Closure {
    return .{ .mojo = "1.0.0", .subdir = "linux-64", .channels = &.{}, .packages = pkgs };
}

fn nameList(a: Allocator, pkgs: []const Package) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (pkgs, 0..) |p, i| {
        if (i > 0) try out.append(' ');
        try out.appendSlice(p.name);
    }
    return out.items;
}

// The solver's lock holds the toolchain's own libgcc and libstdcxx (and what they need) and the
// machine's virtual packages next to the natives. None of them belongs in a native's closure: the
// toolchain stages libgcc and libstdcxx and the loader path has them. libzlib is not staged, so it stays.
test "dedup: the platform's packages and virtual packages are dropped, libzlib is kept, the run dependency is followed" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    const staged = stagedLinux("16.2.0", "16.2.0");
    const cat = try fromPixiLock(a, try lockFor(a, "linux-64", &fx), "linux-64", &.{ "libbrotlidec", "libsqlite" }, &.{toolchainOf(&staged)}, &why);
    // Everything the roots need, nothing the platform has, nothing the roots do not reach.
    try std.testing.expectEqualStrings("libbrotlicommon libbrotlidec libsqlite libzlib", try nameList(a, cat.packages));
    try std.testing.expectEqualStrings("libgcc libstdcxx mojo-compiler", try std.mem.join(a, " ", cat.provided));
    try std.testing.expectEqualStrings("libbrotlidec libsqlite", try std.mem.join(a, " ", cat.roots));
    // `depends` is reduced to names of the file: no versions, no __glibc, no libgcc.
    try std.testing.expectEqualStrings("libzlib", try std.mem.join(a, ",", find(cat, "libsqlite").?.depends));
    try std.testing.expectEqualStrings("libbrotlicommon", try std.mem.join(a, ",", find(cat, "libbrotlidec").?.depends));
    try std.testing.expectEqual(@as(usize, 0), find(cat, "libzlib").?.depends.len);
    // A native's closure, itself included.
    try std.testing.expectEqualStrings("libsqlite libzlib", try nameList(a, try closureOf(a, cat, "libsqlite")));
    try std.testing.expectEqualStrings("libbrotlicommon libbrotlidec", try nameList(a, try closureOf(a, cat, "libbrotlidec")));
    try std.testing.expectEqual(@as(usize, 0), (try closureOf(a, cat, "libgcc")).len);
    // The file reads back to the same catalog, and the url is channel + path.
    const text = try render(a, cat);
    try std.testing.expectEqualStrings(text, try render(a, try parse(a, text)));
    try std.testing.expectEqualStrings("https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.2-h2_3.conda", try urlOf(a, cat, find(cat, "libzlib").?));
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, cat));
}

test "dedup on macOS: libcxx is the OS's and is dropped, libzlib is kept" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = [_]Fx{
        .{ .name = "libsqlite", .version = "3.54.1", .build = "h1_101", .deps = &.{ "__osx >=11.0", "libzlib >=1.3.2,<2.0a0", "libcxx >=21" } },
        .{ .name = "libzlib", .version = "1.3.2", .build = "h2_3", .deps = &.{"__osx >=11.0"} },
        .{ .name = "libcxx", .version = "23.1.4", .build = "h3_2", .deps = &.{"__osx >=11.0"} },
    };
    const cat = try fromPixiLock(a, try lockFor(a, "osx-arm64", &fx), "osx-arm64", &.{"libsqlite"}, &.{}, &why);
    try std.testing.expectEqualStrings("libsqlite libzlib", try nameList(a, cat.packages));
    try std.testing.expectEqualStrings("libzlib", try std.mem.join(a, ",", cat.packages[0].depends));
}

test "closed world: a native that needs a package the lock does not have fails" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "libicu >=78");
    const staged = stagedLinux("16.2.0", "16.2.0");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, try lockFor(a, "linux-64", &fx), "linux-64", &.{"libsqlite"}, &.{toolchainOf(&staged)}, &why));
    try std.testing.expectEqualStrings("libsqlite needs libicu, which is neither in the lock for linux-64 nor provided by the platform (libgcc, libstdcxx, mojo-compiler); the catalog is closed", why);
    // The same dependency of a package no root reaches is not the catalog's business.
    const fx2 = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    _ = try fromPixiLock(a, try lockFor(a, "linux-64", &fx2), "linux-64", &.{"libzlib"}, &.{toolchainOf(&staged)}, &why);
}

test "a root the lock does not have is refused, naming it" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    const staged = stagedLinux("16.2.0", "16.2.0");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, try lockFor(a, "linux-64", &fx), "linux-64", &.{ "libsqlite", "openssl" }, &.{toolchainOf(&staged)}, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "openssl: the lock has no openssl for linux-64"));
}

test "floors: a native built for a newer libgcc or libstdcxx than the toolchain stages is refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    const text = try lockFor(a, "linux-64", &fx);
    // libsqlite asks for libgcc >=15: a toolchain that stages 14.3.0 cannot supply it.
    const old_gcc = stagedLinux("14.3.0", "16.2.0");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, text, "linux-64", &.{"libsqlite"}, &.{toolchainOf(&old_gcc)}, &why));
    try std.testing.expectEqualStrings("libsqlite 3.54.1 needs 'libgcc >=15', but mojo 1.0.0 stages libgcc 14.3.0 for linux-64", why);
    // The floor is checked against every Mojo version's closure, not the newest.
    const good = stagedLinux("16.2.0", "16.2.0");
    try std.testing.expectError(error.BadLock, fromPixiLock(a, text, "linux-64", &.{"libsqlite"}, &.{ toolchainOf(&good), toolchainOf(&old_gcc) }, &why));
    // Exactly the floor passes.
    const at_floor = stagedLinux("15", "15.0.0");
    _ = try fromPixiLock(a, text, "linux-64", &.{"libsqlite"}, &.{toolchainOf(&at_floor)}, &why);
    // No closure to check against, or one without the component, is not a pass.
    try std.testing.expectError(error.BadLock, fromPixiLock(a, text, "linux-64", &.{"libsqlite"}, &.{}, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "no Mojo closure for linux-64") != null);
    const none = [_]Package{};
    try std.testing.expectError(error.BadLock, fromPixiLock(a, text, "linux-64", &.{"libsqlite"}, &.{toolchainOf(&none)}, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "has no libgcc") != null);
    // libzlib asks for nothing of the platform: no toolchain needed.
    _ = try fromPixiLock(a, text, "linux-64", &.{"libzlib"}, &.{}, &why);
}

test "conda versions: order and constraints" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const lt = std.math.Order.lt;
    try std.testing.expectEqual(lt, try compareVersions(a, "14.3.0", "15"));
    try std.testing.expectEqual(std.math.Order.eq, try compareVersions(a, "15", "15.0.0"));
    try std.testing.expectEqual(std.math.Order.gt, try compareVersions(a, "1.10", "1.9"));
    try std.testing.expectEqual(lt, try compareVersions(a, "2.0a0", "2.0"));
    try std.testing.expectEqual(lt, try compareVersions(a, "3.0.a0", "3.0"));
    const T = struct { v: []const u8, c: []const u8, want: bool };
    for ([_]T{
        .{ .v = "16.2.0", .c = ">=15", .want = true },
        .{ .v = "14.3.0", .c = ">=15", .want = false },
        .{ .v = "15", .c = ">=15", .want = true },
        .{ .v = "15.1", .c = ">=13,<16.0a0", .want = true },
        .{ .v = "16.2.0", .c = ">=13,<16.0a0", .want = false },
        .{ .v = "16.2.0", .c = "<16.0a0", .want = false },
        .{ .v = "1.3.2", .c = ">1.3.2", .want = false },
        .{ .v = "1.3.2", .c = "<=1.3.2", .want = true },
        .{ .v = "1.3.2", .c = "==1.3.2", .want = true },
        .{ .v = "1.3.2", .c = "1.3.2", .want = true },
        .{ .v = "1.3.2", .c = "!=1.3.2", .want = false },
        .{ .v = "1.3.2", .c = "1.3.*", .want = true },
        .{ .v = "1.4.0", .c = "1.3.*", .want = false },
        .{ .v = "1.4.0", .c = "*", .want = true },
        .{ .v = "1.4.0", .c = "", .want = true },
    }) |t| {
        if (t.c.len == 0) {
            try std.testing.expectError(error.UnsupportedSpec, satisfies(a, t.v, t.c));
            continue;
        }
        try std.testing.expectEqual(t.want, try satisfies(a, t.v, t.c));
    }
    // What it cannot evaluate is an error, never a guess.
    try std.testing.expectError(error.UnsupportedSpec, satisfies(a, "15", ">=14|>=16"));
    try std.testing.expectError(error.UnsupportedSpec, satisfies(a, "15", ">=14 *_1"));
    try std.testing.expectError(error.UnsupportedSpec, satisfies(a, "15", ">="));
    try std.testing.expectEqualStrings("libgcc", specName("libgcc >=14"));
    try std.testing.expectEqualStrings("__glibc", specName("__glibc"));
}

test "problem: what a reader of a committed catalog relies on" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    const staged = stagedLinux("16.2.0", "16.2.0");
    const cat = try fromPixiLock(a, try lockFor(a, "linux-64", &fx), "linux-64", &.{"libsqlite"}, &.{toolchainOf(&staged)}, &why);
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, cat));
    const sqlite = find(cat, "libsqlite").?;
    const zlib = find(cat, "libzlib").?;

    var dangling = cat;
    var sq = sqlite;
    sq.depends = &.{ "libzlib", "libicu" };
    dangling.packages = &.{ sq, zlib };
    try std.testing.expectEqualStrings("libsqlite needs libicu, which the catalog does not have", (try problem(a, dangling)).?);

    var platform = cat;
    var gcc = zlib;
    gcc.name = "libgcc";
    gcc.path = "linux-64/libgcc-1.3.2-h2_3.conda";
    platform.packages = &.{ sqlite, zlib, gcc };
    try std.testing.expectEqualStrings("libgcc is the platform's, not the catalog's", (try problem(a, platform)).?);

    var stray = cat;
    var extra = zlib;
    extra.name = "extra";
    extra.path = "linux-64/extra-1.3.2-h2_3.conda";
    stray.packages = &.{ extra, sqlite, zlib };
    try std.testing.expectEqualStrings("extra is not needed by any root", (try problem(a, stray)).?);

    var twice = cat;
    twice.packages = &.{ sqlite, zlib, zlib };
    try std.testing.expectEqualStrings("libzlib is listed twice", (try problem(a, twice)).?);

    var rootless = cat;
    rootless.roots = &.{ "libsqlite", "zstd" };
    try std.testing.expectEqualStrings("root zstd is not in the catalog", (try problem(a, rootless)).?);

    var badsum = cat;
    var z2 = zlib;
    z2.sha256 = "11";
    badsum.packages = &.{ sqlite, z2 };
    try std.testing.expectEqualStrings("libzlib: sha256 is not 64 lowercase hex digits", (try problem(a, badsum)).?);

    var other_provided = cat;
    other_provided.provided = &.{ "libgcc", "libstdcxx" };
    try std.testing.expectEqualStrings("provided is not the platform's list", (try problem(a, other_provided)).?);

    var mirror = cat;
    mirror.channels = &.{.{ .name = "conda-forge", .url = "https://mirror.example/forge/" }};
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, mirror));
    try std.testing.expectEqualStrings("https://mirror.example/forge/linux-64/libzlib-1.3.2-h2_3.conda", try urlOf(a, mirror, zlib));
    mirror.channels = &.{.{ .name = "conda-forge", .url = "http://mirror.example/forge/" }};
    try std.testing.expect((try problem(a, mirror)) != null);
}

test "a package file pinned with other bytes is an alarm for the catalog too" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const fx = try linuxFixture(a, "__glibc >=2.17,<3.0.a0");
    const staged = stagedLinux("16.2.0", "16.2.0");
    const cat = try fromPixiLock(a, try lockFor(a, "linux-64", &fx), "linux-64", &.{"libzlib"}, &.{toolchainOf(&staged)}, &why);
    try std.testing.expectEqual(@as(usize, 0), (try closure.alarmsOfPackages(a, cat.packages, cat.packages)).len);
    var other = cat.packages[0];
    other.sha256 = "9" ** 64;
    const got = try closure.alarmsOfPackages(a, cat.packages, &.{other});
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(std.mem.startsWith(u8, got[0], "linux-64/libzlib-1.3.2-h2_3.conda: was sha256 0000"));
}

// The platform's package list is written once here; the unit graph names the components it stages. They must
// not drift: a component the graph stages but the catalog still lists would be staged twice, and a name dropped
// here that the graph does not stage would be loadable by nothing.
test "platform_provided is the unit graph's components, plus libcxx on macOS" {
    try std.testing.expectEqual(unit_graph.targets.len, platform_provided.len);
    for (unit_graph.targets) |t| {
        const prov = providedFor(t.subdir) orelse return error.NoSuchSubdir;
        for (t.components) |comp| try std.testing.expect(contains(prov.names, comp));
        for (prov.names) |n| try std.testing.expect(contains(t.components, n) or std.mem.eql(u8, n, "libcxx"));
        // Only a package a Mojo closure pins can have a floor.
        for (prov.floored) |n| try std.testing.expect(contains(prov.names, n));
        try std.testing.expectEqual(std.mem.eql(u8, t.subdir, "osx-arm64"), contains(prov.names, "libcxx"));
    }
    for (closure.subdirs) |s| try std.testing.expect(providedFor(s) != null);
}

fn firstDifference(want: []const u8, committed: []const u8) void {
    var at: usize = 0;
    while (at < want.len and at < committed.len and want[at] == committed[at]) at += 1;
    const from = at -| 60;
    std.debug.print("first difference at byte {d}\n  made:      {s}\n  committed: {s}\n", .{ at, want[from..@min(want.len, at + 60)], committed[from..@min(committed.len, at + 60)] });
}

// The committed catalogs are what the generator makes from the committed roots, lock and Mojo closures, so no
// one edits a hash by hand and the lock cannot move without its catalog files.
test "the committed catalog files are the ones made from the committed lock" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const lock_text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/natives.pixi.lock"), 16 << 20);
    const roots_text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/natives.txt"), 1 << 16);
    var roots = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, roots_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try roots.append(line);
    }
    try std.testing.expect(roots.items.len >= 8);
    const versions_text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/versions.txt"), 1 << 16);
    for (closure.subdirs) |subdir| {
        var toolchains = std.ArrayList(closure.Closure).init(a);
        var it = std.mem.tokenizeScalar(u8, versions_text, '\n');
        while (it.next()) |line| {
            const ver = std.mem.trim(u8, line, " \t\r");
            if (ver.len == 0 or ver[0] == '#') continue;
            const text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, try std.fmt.allocPrint(a, "src/core/toolchain/mojo-{s}-{s}.json", .{ ver, subdir })), 16 << 20);
            try toolchains.append(try closure.parse(a, text));
        }
        try std.testing.expect(toolchains.items.len >= 1);
        var why: []const u8 = "";
        const made = fromPixiLock(a, lock_text, subdir, roots.items, toolchains.items, &why) catch |e| {
            std.debug.print("{s}: {s}: {s}\n", .{ subdir, @errorName(e), why });
            return e;
        };
        const file = try std.fmt.allocPrint(a, "src/core/toolchain/natives-{s}.json", .{subdir});
        const committed = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, file), 16 << 20);
        const want = try render(a, made);
        if (!std.mem.eql(u8, want, committed)) {
            firstDifference(want, committed);
            std.debug.print("{s} is not what mopm-closure makes from toolchain/natives.pixi.lock; run: zig build run-closure -- --natives toolchain/natives.pixi.lock toolchain/natives.txt src/core/toolchain\n", .{file});
            return error.CatalogOutOfDate;
        }
        // The file the binary embeds is that file, and it is usable as it stands.
        const embedded_text = embedded(subdir).?;
        try std.testing.expectEqualStrings(committed, embedded_text);
        const cat = (try forSubdir(a, subdir)).?;
        try std.testing.expectEqual(@as(?[]const u8, null), try problem(a, cat));
        // Every allow-listed native is on every platform, with its run dependencies.
        for (roots.items) |r| try std.testing.expect(find(cat, r) != null);
        try std.testing.expect(find(cat, "libbrotlicommon") != null);
        try std.testing.expect(find(cat, "libzlib") != null);
    }
    try std.testing.expect((try forSubdir(a, "linux-32")) == null);
}

// ------------------------------------------------------------ what the packages hold

/// One line of toolchain/natives.libs: a file of a package below `lib/` that is a shared library, or a link.
const LibLine = struct {
    subdir: []const u8,
    package: []const u8,
    sha256: []const u8,
    path: []const u8,
    /// Set for a link: where it points, relative to its directory.
    target: ?[]const u8,
};

fn parseLibs(a: Allocator, text: []const u8) ![]const LibLine {
    var out = std.ArrayList(LibLine).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const subdir = f.next() orelse return error.BadLibsLine;
        const package = f.next() orelse return error.BadLibsLine;
        const sha256 = f.next() orelse return error.BadLibsLine;
        const path = f.next() orelse return error.BadLibsLine;
        var target: ?[]const u8 = null;
        if (f.next()) |arrow| {
            if (!std.mem.eql(u8, arrow, "->")) return error.BadLibsLine;
            target = f.next() orelse return error.BadLibsLine;
        }
        if (f.next() != null) return error.BadLibsLine;
        try out.append(.{ .subdir = subdir, .package = package, .sha256 = sha256, .path = path, .target = target });
    }
    return out.items;
}

fn libOf(lines: []const LibLine, subdir: []const u8, package: []const u8, path: []const u8) ?LibLine {
    for (lines) |l| {
        if (std.mem.eql(u8, l.subdir, subdir) and std.mem.eql(u8, l.package, package) and std.mem.eql(u8, l.path, path)) return l;
    }
    return null;
}

/// Why the shared libraries of `p` (read from toolchain/natives.libs) are not usable, or null: it holds no regular
/// shared library file, or one of its links does not end, through links of the package, at a regular file of it.
fn libsProblem(a: Allocator, lines: []const LibLine, subdir: []const u8, p: Package) Allocator.Error!?[]const u8 {
    var regular: usize = 0;
    for (lines) |l| {
        if (!std.mem.eql(u8, l.subdir, subdir) or !std.mem.eql(u8, l.package, p.name)) continue;
        if (!std.mem.eql(u8, l.sha256, p.sha256)) {
            return try std.fmt.allocPrint(a, "{s}: toolchain/natives.libs reads {s} from a package file with sha256 {s}, the catalog pins {s}", .{ p.name, l.path, l.sha256, p.sha256 });
        }
        if (l.target == null) {
            regular += 1;
            continue;
        }
        var at = l;
        var hops: usize = 0;
        while (at.target) |t| {
            hops += 1;
            const want = try std.fmt.allocPrint(a, "lib/{s}", .{t});
            const next = libOf(lines, subdir, p.name, want);
            if (hops > 8) return try std.fmt.allocPrint(a, "{s}: {s} is in a loop of links", .{ p.name, l.path });
            if (std.mem.indexOfScalar(u8, t, '/') != null or next == null) {
                return try std.fmt.allocPrint(a, "{s}: {s} points to {s}, which the package does not hold", .{ p.name, l.path, t });
            }
            at = next.?;
        }
    }
    if (regular == 0) return try std.fmt.allocPrint(a, "{s}: the package has no shared library", .{p.name});
    return null;
}

test "libsProblem: a package without a shared library, and a dev link to a library another package holds, are caught" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const lines = try parseLibs(a,
        \\linux-64 good aa lib/libgood.so.1.2
        \\linux-64 good aa lib/libgood.so.1 -> libgood.so.1.2
        \\linux-64 good aa lib/libgood.so -> libgood.so.1
        \\linux-64 dev bb lib/libgood.so -> libgood.so.1.2
        \\linux-64 loop cc lib/libloop.so -> libloop.so.1
        \\linux-64 loop cc lib/libloop.so.1 -> libloop.so
        \\linux-64 deep dd lib/libdeep.so -> ../libdeep.so.1
        \\linux-64 stale ee lib/libstale.so.1
        \\
    );
    const pkg = struct {
        fn of(name: []const u8, sha: []const u8) Package {
            return .{ .name = name, .version = "1", .build = "0", .subdir = "linux-64", .channel = "conda-forge", .path = "", .sha256 = sha, .size = 1 };
        }
    };
    try std.testing.expectEqual(@as(?[]const u8, null), try libsProblem(a, lines, "linux-64", pkg.of("good", "aa")));
    try std.testing.expectEqualStrings("dev: lib/libgood.so points to libgood.so.1.2, which the package does not hold", (try libsProblem(a, lines, "linux-64", pkg.of("dev", "bb"))).?);
    try std.testing.expectEqualStrings("loop: lib/libloop.so is in a loop of links", (try libsProblem(a, lines, "linux-64", pkg.of("loop", "cc"))).?);
    try std.testing.expect((try libsProblem(a, lines, "linux-64", pkg.of("deep", "dd"))) != null);
    try std.testing.expect(std.mem.indexOf(u8, (try libsProblem(a, lines, "linux-64", pkg.of("stale", "other"))).?, "sha256") != null);
    try std.testing.expectEqualStrings("none: the package has no shared library", (try libsProblem(a, lines, "linux-64", pkg.of("none", "ff"))).?);
    try std.testing.expectEqualStrings("good: the package has no shared library", (try libsProblem(a, lines, "osx-arm64", pkg.of("good", "aa"))).?);
}

// conda-forge's `xz` is a metapackage whose closure holds packages with no library and a development package whose
// `lib/liblzma.so` points to a file only `liblzma` holds; `conda_unpack --all-libs` refuses both. Every package
// of the catalog must hold a shared library, and every link of it must end at a file of the same package, so a root
// that brings such a package cannot be pinned again.
test "every package of the native catalog holds a shared library, and no link of it points outside it" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/natives.libs"), 1 << 20);
    const lines = try parseLibs(a, text);
    for (closure.subdirs) |subdir| {
        const cat = (try forSubdir(a, subdir)).?;
        for (cat.packages) |p| {
            if (try libsProblem(a, lines, subdir, p)) |why| {
                std.debug.print("{s}: {s}\n", .{ subdir, why });
                return error.CatalogPackageUnusable;
            }
        }
        // No line for a package the catalog does not pin: the file lists what the catalog has, no more.
        for (lines) |l| {
            if (!std.mem.eql(u8, l.subdir, subdir)) continue;
            if (find(cat, l.package) == null) {
                std.debug.print("toolchain/natives.libs has {s} for {s}, which the catalog does not pin\n", .{ l.package, subdir });
                return error.LibsHasUnpinnedPackage;
            }
        }
    }
}
