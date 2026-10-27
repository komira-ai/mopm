//! `mopm lock` pins the system libraries a project loads (spec/lock.md, "System libraries").
//!
//! A manifest says `[native-dependencies] libsqlite = { version = ">=3.40", mode = "load" }`; a registry
//! package says the same through the `depends` of its repodata entry (its lock entry's `loads`). This
//! file turns those names into the lock's `system_libs`: for each subdir, the conda packages of the
//! libraries and of everything they need to run, taken from the catalog this mopm pins
//! (native_catalog.zig). There is no solver: a library mopm has no pin for is refused, and so is a
//! requirement the pin does not meet.
//!
//! A project that loads nothing gets no `system_libs`, so its lock is what it always was.

const std = @import("std");
const Allocator = std.mem.Allocator;
const catalog = @import("native_catalog.zig");
const conda = @import("conda.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const lock_libs = @import("lock_libs.zig");
const unit_graph = @import("unit_graph.zig");

pub const Refused = error{Refused};

/// A library a manifest loads: the conda package that provides it and the conda constraint its version must meet
/// (empty for any), and where the manifest is, for messages.
pub const Need = struct { name: []const u8, range: []const u8 = "", from: []const u8 };

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) (Refused || Allocator.Error) {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

/// The libraries `deps` (the `[native-dependencies]` of the manifest at `from`) load, as conda packages: the
/// `mode = "load"` ones, in manifest order, without repeats.
pub fn needsOf(arena: Allocator, from: []const u8, deps: []const manifest.NativeDep, why: *[]const u8) (Refused || Allocator.Error)![]const Need {
    var out = std.ArrayList(Need).init(arena);
    for (deps) |d| {
        if (d.mode != .load) continue;
        const pkg = conda.condaPackageFor(d.name);
        var range: []const u8 = "";
        if (d.version) |v| {
            var reason: []const u8 = "";
            range = conda.condaRange(arena, v, &reason) catch |e| switch (e) {
                error.Unpackable => return refuse(arena, why, "{s}: native dependency '{s}' = \"{s}\": {s}", .{ from, d.name, v, reason }),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        var have = false;
        for (out.items) |o| have = have or std.mem.eql(u8, o.name, pkg);
        if (!have) try out.append(.{ .name = pkg, .range = range, .from = from });
    }
    return out.items;
}

fn lessLib(_: void, a: lock_libs.Lib, b: lock_libs.Lib) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// The libraries of the catalog of `subdir` that `names` need, with everything those need, as lock entries.
fn libsOf(arena: Allocator, cat: catalog.Catalog, names: []const []const u8) !lock_libs.Subdir {
    var seen = std.StringHashMap(void).init(arena);
    var out = std.ArrayList(lock_libs.Lib).init(arena);
    for (names) |n| {
        for (try catalog.closureOf(arena, cat, n)) |p| {
            if ((try seen.fetchPut(p.name, {})) != null) continue;
            try out.append(.{
                .name = p.name,
                .version = p.version,
                .build = p.build,
                .url = try catalog.urlOf(arena, cat, p),
                .sha256 = p.sha256,
                .size = p.size,
                .deps = p.depends,
            });
        }
    }
    std.mem.sort(lock_libs.Lib, out.items, {}, lessLib);
    return .{ .subdir = cat.subdir, .libs = out.items };
}

/// The `system_libs` of `l` for the libraries `needs` (of the root manifest and of the path dependencies) and its
/// registry packages' `loads`: one list per subdir that has any, empty when nothing is loaded. A name mopm has no
/// pin for, or a version the pin does not meet, is `error.Refused` with `why` saying what and what to do.
pub fn pin(arena: Allocator, l: lock.Lock, needs: []const Need, why: *[]const u8) (Refused || Allocator.Error)![]const lock_libs.Subdir {
    var out = std.ArrayList(lock_libs.Subdir).init(arena);
    for (unit_graph.lock_subdirs) |subdir| {
        var names = std.ArrayList([]const u8).init(arena);
        const cat = (catalog.forSubdir(arena, subdir) catch return refuse(arena, why, "the native library catalog of this mopm for {s} is unreadable", .{subdir})) orelse
            return refuse(arena, why, "this mopm pins no native libraries for {s}", .{subdir});
        for (needs) |n| {
            const p = catalog.find(cat, n.name) orelse {
                const known = try std.mem.join(arena, ", ", cat.roots);
                return refuse(arena, why, "{s}: native dependency '{s}' is not a library mopm pins for tests; the pinned ones are: {s}", .{ n.from, n.name, known });
            };
            if (n.range.len > 0) {
                const ok = catalog.satisfies(arena, p.version, n.range) catch |e| switch (e) {
                    error.UnsupportedSpec => return refuse(arena, why, "{s}: the requirement \"{s}\" of {s} is not one mopm can compare with its pin {s} for {s}", .{ n.from, n.range, n.name, p.version, subdir }),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (!ok) return refuse(arena, why, "mopm pins {s} {s} for {s}; requirement \"{s}\" cannot be met; update mopm", .{ n.name, p.version, subdir, n.range });
            }
            try names.append(n.name);
        }
        for (l.packages) |p| {
            if (p.source == .path or !std.mem.eql(u8, p.subdir, subdir)) continue;
            for (p.loads) |n| {
                if (catalog.find(cat, n) == null) {
                    const known = try std.mem.join(arena, ", ", cat.roots);
                    return refuse(arena, why, "{s} {s} loads the system library {s}, which mopm pins no copy of for {s}; the pinned ones are: {s}; update mopm", .{ p.name, p.version, n, subdir, known });
                }
                try names.append(n);
            }
        }
        if (names.items.len == 0) continue;
        const entry = libsOf(arena, cat, names.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refuse(arena, why, "the native library catalog of this mopm for {s} is inconsistent ({s})", .{ subdir, @errorName(e) }),
        };
        try out.append(entry);
    }
    return out.items;
}

/// `l` with its `system_libs` pinned for `needs` and the `loads` of its packages: `l` itself when nothing is
/// loaded. See `pin`.
pub fn attach(arena: Allocator, l: lock.Lock, needs: []const Need, why: *[]const u8) (Refused || Allocator.Error)!lock.Lock {
    const libs = try pin(arena, l, needs, why);
    if (libs.len == 0) return l;
    var out = l;
    out.system_libs = libs;
    return out;
}

// ---------------------------------------------------------------- tests

fn lockOf(a: Allocator, text: []const u8) !lock.Lock {
    var why: []const u8 = "";
    return lock.parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
}

const empty_lock =
    \\{
    \\  "lock_version": 1,
    \\  "toolchain": {
    \\    "mojo": "1.0.0"
    \\  },
    \\  "channels": [
    \\    "https://conda.mopm.dev/"
    \\  ],
    \\  "packages": []
    \\}
    \\
;

fn parseManifest(a: Allocator, text: []const u8) !manifest.Manifest {
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(a, text, &diag);
}

const toml_head = "[package]\nname = \"app\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n";

test "a project that loads nothing keeps its lock: no system_libs, the same bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parseManifest(a, toml_head ++ "[native-dependencies]\nz = { mode = \"link\" }\n");
    var why: []const u8 = "";
    const needs = try needsOf(a, "mopm.toml", m.native_dependencies, &why);
    try std.testing.expectEqual(@as(usize, 0), needs.len);
    const l = try lockOf(a, empty_lock);
    const out = try attach(a, l, needs, &why);
    try std.testing.expectEqual(@as(usize, 0), out.system_libs.len);
    try std.testing.expectEqualStrings(empty_lock, try lock.render(a, out));
}

test "a manifest that loads a library gets it, and what it needs, pinned for every subdir, from the catalog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parseManifest(a, toml_head ++ "[native-dependencies]\nlibsqlite = { version = \">=3.40\", mode = \"load\" }\nlibbrotlidec = { mode = \"load\" }\n");
    var why: []const u8 = "";
    const needs = try needsOf(a, "mopm.toml", m.native_dependencies, &why);
    try std.testing.expectEqual(@as(usize, 2), needs.len);
    const out = try attach(a, try lockOf(a, empty_lock), needs, &why);
    try std.testing.expectEqual(unit_graph.lock_subdirs.len, out.system_libs.len);
    for (out.system_libs) |sd| {
        const cat = (try catalog.forSubdir(a, sd.subdir)).?;
        // Each library is the catalog's own package: the pin, the url, the bytes.
        for (sd.libs) |lib| {
            const p = catalog.find(cat, lib.name).?;
            try std.testing.expectEqualStrings(p.version, lib.version);
            try std.testing.expectEqualStrings(p.sha256, lib.sha256);
            try std.testing.expectEqualStrings(try catalog.urlOf(a, cat, p), lib.url);
        }
        // The roots, and what they run on: libbrotlidec needs libbrotlicommon, libsqlite needs libzlib.
        var missing: []const u8 = "";
        const closure = try lock_libs.closureNames(a, sd.libs, &.{ "libsqlite", "libbrotlidec" }, &missing);
        try std.testing.expect(closure.len >= 4);
        try std.testing.expect(lock_libs.find(sd.libs, "libbrotlicommon") != null);
        try std.testing.expect(lock_libs.find(sd.libs, "libzlib") != null);
        // Nothing else: a library nothing named is not pinned.
        try std.testing.expectEqual(closure.len, sd.libs.len);
        // The platform's own packages are not here (native_catalog.zig).
        try std.testing.expect(lock_libs.find(sd.libs, "libgcc") == null);
    }
    // What mopm writes, mopm reads back, under every rule of the lock.
    const text = try lock.render(a, out);
    const again = try lockOf(a, text);
    try std.testing.expectEqualStrings(text, try lock.render(a, again));
}

test "a requirement the pinned version does not meet is refused, saying what mopm pins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parseManifest(a, toml_head ++ "[native-dependencies]\nlibsqlite = { version = \">=999\", mode = \"load\" }\n");
    var why: []const u8 = "";
    const needs = try needsOf(a, "mopm.toml", m.native_dependencies, &why);
    try std.testing.expectError(error.Refused, attach(a, try lockOf(a, empty_lock), needs, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "mopm pins libsqlite "));
    try std.testing.expect(std.mem.indexOf(u8, why, " for linux-64; requirement \">=999\" cannot be met; update mopm") != null);
}

test "a library mopm pins nothing for is refused for a manifest, naming the manifest and the pinned names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parseManifest(a, toml_head ++ "[native-dependencies]\nnotalib = { mode = \"load\" }\n");
    var why: []const u8 = "";
    const needs = try needsOf(a, "util/mopm.toml", m.native_dependencies, &why);
    try std.testing.expectError(error.Refused, attach(a, try lockOf(a, empty_lock), needs, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "util/mopm.toml: native dependency 'notalib' is not a library mopm pins for tests; the pinned ones are: "));
    try std.testing.expect(std.mem.indexOf(u8, why, "libsqlite") != null);
}

test "the names a manifest uses are the conda packages that provide them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parseManifest(a, toml_head ++ "[native-dependencies]\nlz4 = { mode = \"load\" }\nz = { mode = \"load\" }\nzlib = { mode = \"load\" }\n");
    var why: []const u8 = "";
    const needs = try needsOf(a, "mopm.toml", m.native_dependencies, &why);
    // `z` and `zlib` are one package.
    try std.testing.expectEqual(@as(usize, 2), needs.len);
    try std.testing.expectEqualStrings("lz4-c", needs[0].name);
    try std.testing.expectEqualStrings("libzlib", needs[1].name);
    const out = try attach(a, try lockOf(a, empty_lock), needs, &why);
    try std.testing.expect(lock_libs.find(out.system_libs[0].libs, "lz4-c") != null);
}

test "a registry package's loads are pinned for the subdir of its entry; one mopm has no pin for is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var pkg = lock.Package{ .name = "tls", .version = "1.1.0", .build = "mojo1.0.0_0", .subdir = "linux-64", .channel = "https://conda.mopm.dev/", .url = "https://conda.mopm.dev/linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda", .sha256 = "a" ** 64, .size = 10, .mojo = "1.0.0", .loads = &.{"zstd"} };
    var l = try lockOf(a, empty_lock);
    l.packages = &.{pkg};
    var why: []const u8 = "";
    const out = try attach(a, l, &.{}, &why);
    // Only the subdir that has the entry gets the pin: the entry says nothing of the others.
    try std.testing.expectEqual(@as(usize, 1), out.system_libs.len);
    try std.testing.expectEqualStrings("linux-64", out.system_libs[0].subdir);
    try std.testing.expect(lock_libs.find(out.system_libs[0].libs, "zstd") != null);
    _ = try lockOf(a, try lock.render(a, out));

    pkg.loads = &.{"notalib"};
    l.packages = &.{pkg};
    try std.testing.expectError(error.Refused, attach(a, l, &.{}, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "tls 1.1.0 loads the system library notalib, which mopm pins no copy of for linux-64"));
}
