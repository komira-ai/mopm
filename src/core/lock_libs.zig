//! The system libraries of a lock (spec/lock.md, "System libraries"): the pinned conda packages of the
//! native libraries a package opens at run time (`[native-dependencies] <name> = { mode = "load" }`),
//! so that a test runs against the libraries the lock names, not against whatever the machine has.
//!
//! Two optional keys, both left out when there is nothing to say, so a lock written before them is read
//! and written back byte for byte:
//!   - top level `system_libs`: `{subdir: [lib, ...]}`, each list sorted by name. A lib is one conda
//!     package: `name`, `version`, `build`, `url`, `sha256`, `size`, and `deps`, the names of the libs of
//!     the same list it needs to run. The list holds the libraries any manifest or registry package of
//!     the project loads and everything those need.
//!   - per registry package `loads`: the conda names of the libraries that package loads, sorted. They
//!     are read from the `depends` of the package's repodata entry (`loadsOfDepends`).
//!
//! This file knows the shape only: `mopm lock` chooses the pins (system_libs.zig, from the catalog of
//! native_catalog.zig) and the unit graph reads them (unit_graph.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One pinned conda package.
pub const Lib = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    /// Names of the libs, in the same list, this one needs to run. Left out of the file when empty.
    deps: []const []const u8 = &.{},
};

/// The libs of one subdir.
pub const Subdir = struct {
    subdir: []const u8,
    /// Sorted by name.
    libs: []const Lib,
};

/// The libs `system_libs` pins for `subdir`, or null when it pins none.
pub fn libsFor(system_libs: []const Subdir, subdir: []const u8) ?[]const Lib {
    for (system_libs) |s| {
        if (std.mem.eql(u8, s.subdir, subdir)) return s.libs;
    }
    return null;
}

pub fn find(libs: []const Lib, name: []const u8) ?Lib {
    for (libs) |l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The libraries a package loads, from the `depends` of its repodata entry: every name that is not a Mojo
/// package (`mojo-*`, the compiler included), sorted, without repeats.
pub fn loadsOfDepends(arena: Allocator, depends: ?std.json.Value) error{ BadDepends, OutOfMemory }![]const []const u8 {
    const v = depends orelse return &.{};
    const items = switch (v) {
        .array => |a| a.items,
        else => return error.BadDepends,
    };
    var out = std.ArrayList([]const u8).init(arena);
    for (items) |item| {
        const spec = switch (item) {
            .string => |s| s,
            else => return error.BadDepends,
        };
        var it = std.mem.tokenizeAny(u8, spec, " \t");
        const name = it.next() orelse return error.BadDepends;
        if (std.mem.startsWith(u8, name, "mojo-")) continue;
        var have = false;
        for (out.items) |o| have = have or std.mem.eql(u8, o, name);
        if (!have) try out.append(name);
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    return out.items;
}

pub const ClosureError = error{MissingLib} || Allocator.Error;

/// `names` and everything they need to run, by the `deps` of `libs`: sorted, without repeats. A name `libs`
/// does not hold (the first in name order) is `error.MissingLib`, and `missing` is set to it.
pub fn closureNames(arena: Allocator, libs: []const Lib, names: []const []const u8, missing: *[]const u8) ClosureError![]const []const u8 {
    const sorted = try arena.dupe([]const u8, names);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    for (sorted) |n| {
        if (find(libs, n) == null) {
            missing.* = n;
            return error.MissingLib;
        }
    }
    var seen = std.StringHashMap(void).init(arena);
    var todo = std.ArrayList([]const u8).init(arena);
    try todo.appendSlice(sorted);
    while (todo.popOrNull()) |n| {
        if ((try seen.fetchPut(n, {})) != null) continue;
        const lib = find(libs, n) orelse {
            missing.* = n;
            return error.MissingLib;
        };
        for (lib.deps) |d| try todo.append(d);
    }
    var out = std.ArrayList([]const u8).init(arena);
    var it = seen.keyIterator();
    while (it.next()) |k| try out.append(k.*);
    std.mem.sort([]const u8, out.items, {}, lessStr);
    return out.items;
}

// ---------------------------------------------------------------- reading

pub const ParseError = error{ Invalid, OutOfMemory };

fn bad(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) ParseError {
    why.* = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.Invalid;
}

fn field(arena: Allocator, why: *[]const u8, o: std.json.ObjectMap, key: []const u8, what: []const u8) ParseError![]const u8 {
    const v = o.get(key) orelse return bad(arena, why, "{s} has no {s}", .{ what, key });
    return switch (v) {
        .string => |s| s,
        else => bad(arena, why, "{s}'s {s} is not a string", .{ what, key }),
    };
}

fn nameList(arena: Allocator, why: *[]const u8, o: std.json.ObjectMap, key: []const u8, what: []const u8) ParseError![]const []const u8 {
    const v = o.get(key) orelse return &.{};
    const items = switch (v) {
        .array => |a| a.items,
        else => return bad(arena, why, "{s}'s {s} is not an array", .{ what, key }),
    };
    var out = std.ArrayList([]const u8).init(arena);
    for (items) |item| {
        switch (item) {
            .string => |s| try out.append(s),
            else => return bad(arena, why, "{s}'s {s} has an entry that is not a string", .{ what, key }),
        }
    }
    return out.items;
}

/// The `loads` of the package `what` (an object of `packages`): empty when it has none.
pub fn parseLoads(arena: Allocator, why: *[]const u8, o: std.json.ObjectMap, what: []const u8) ParseError![]const []const u8 {
    return nameList(arena, why, o, "loads", what);
}

fn lessSubdir(_: void, a: Subdir, b: Subdir) bool {
    return std.mem.order(u8, a.subdir, b.subdir) == .lt;
}

/// The top-level `system_libs` of a lock (empty when it has none). Shape only; `check` holds the rules.
pub fn parseSubdirs(arena: Allocator, why: *[]const u8, top: std.json.ObjectMap) ParseError![]const Subdir {
    const v = top.get("system_libs") orelse return &.{};
    const obj = switch (v) {
        .object => |o| o,
        else => return bad(arena, why, "system_libs is not a JSON object", .{}),
    };
    var out = std.ArrayList(Subdir).init(arena);
    var it = obj.iterator();
    while (it.next()) |e| {
        const items = switch (e.value_ptr.*) {
            .array => |a| a.items,
            else => return bad(arena, why, "system_libs of {s} is not an array", .{e.key_ptr.*}),
        };
        var libs = std.ArrayList(Lib).init(arena);
        for (items, 0..) |lv, n| {
            const what = try std.fmt.allocPrint(arena, "system_libs {s}[{d}]", .{ e.key_ptr.*, n });
            const o = switch (lv) {
                .object => |x| x,
                else => return bad(arena, why, "{s} is not a JSON object", .{what}),
            };
            const size: i64 = switch (o.get("size") orelse return bad(arena, why, "{s} has no size", .{what})) {
                .integer => |s| s,
                else => return bad(arena, why, "{s}'s size is not an integer", .{what}),
            };
            if (size < 1) return bad(arena, why, "{s}'s size is not positive", .{what});
            try libs.append(.{
                .name = try field(arena, why, o, "name", what),
                .version = try field(arena, why, o, "version", what),
                .build = try field(arena, why, o, "build", what),
                .url = try field(arena, why, o, "url", what),
                .sha256 = try field(arena, why, o, "sha256", what),
                .size = @intCast(size),
                .deps = try nameList(arena, why, o, "deps", what),
            });
        }
        try out.append(.{ .subdir = e.key_ptr.*, .libs = libs.items });
    }
    std.mem.sort(Subdir, out.items, {}, lessSubdir);
    return out.items;
}

// ---------------------------------------------------------------- rules

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The first rule of spec/lock.md ("System libraries") that `system_libs` breaks, worded, or null.
pub fn checkLibs(arena: Allocator, system_libs: []const Subdir) Allocator.Error!?[]const u8 {
    for (system_libs, 0..) |s, i| {
        if (i > 0 and std.mem.order(u8, system_libs[i - 1].subdir, s.subdir) != .lt) {
            return try std.fmt.allocPrint(arena, "system_libs lists {s} twice or out of order", .{s.subdir});
        }
        if (s.libs.len == 0) return try std.fmt.allocPrint(arena, "system_libs of {s} is empty", .{s.subdir});
        for (s.libs, 0..) |lib, j| {
            if (j > 0 and std.mem.order(u8, s.libs[j - 1].name, lib.name) != .lt) {
                return try std.fmt.allocPrint(arena, "system_libs of {s} is not sorted by name with no repeats (at {s})", .{ s.subdir, lib.name });
            }
            if (lib.name.len == 0 or lib.version.len == 0 or lib.build.len == 0) {
                return try std.fmt.allocPrint(arena, "system_libs of {s}: {s} has an empty name, version or build", .{ s.subdir, lib.name });
            }
            if (std.mem.startsWith(u8, lib.name, "mojo-")) {
                return try std.fmt.allocPrint(arena, "system_libs of {s}: {s} is a Mojo package, not a system library", .{ s.subdir, lib.name });
            }
            if (!isSha256(lib.sha256)) {
                return try std.fmt.allocPrint(arena, "system_libs of {s}: {s}'s sha256 is not 64 lowercase hex digits", .{ s.subdir, lib.name });
            }
            if (!std.mem.startsWith(u8, lib.url, "https://") or !std.mem.endsWith(u8, lib.url, ".conda")) {
                return try std.fmt.allocPrint(arena, "system_libs of {s}: {s}'s url {s} is not an https .conda file", .{ s.subdir, lib.name, lib.url });
            }
            for (lib.deps) |d| {
                if (std.mem.eql(u8, d, lib.name) or find(s.libs, d) == null) {
                    return try std.fmt.allocPrint(arena, "system_libs of {s}: {s} needs {s}, which is not another entry of the list", .{ s.subdir, lib.name, d });
                }
            }
        }
    }
    return null;
}

/// The first rule that `loads` (of the registry package `name` in `subdir`) breaks, worded, or null: sorted,
/// without repeats, and every library pinned in `system_libs` for that subdir.
pub fn checkLoads(arena: Allocator, name: []const u8, subdir: []const u8, loads: []const []const u8, system_libs: []const Subdir) Allocator.Error!?[]const u8 {
    for (loads, 0..) |n, i| {
        if (i > 0 and std.mem.order(u8, loads[i - 1], n) != .lt) {
            return try std.fmt.allocPrint(arena, "{s}: loads is not sorted with no repeats (at {s})", .{ name, n });
        }
        const libs = libsFor(system_libs, subdir) orelse &[_]Lib{};
        if (find(libs, n) == null) {
            return try std.fmt.allocPrint(arena, "{s}: loads {s}, which system_libs does not pin for {s}", .{ name, n, subdir });
        }
    }
    return null;
}

// ---------------------------------------------------------------- writing

fn str(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

/// `,"system_libs": {...}` (the layout of the lock: two-space indent), or nothing for no libs.
pub fn writeSubdirs(w: anytype, subdirs: []const Subdir) !void {
    if (subdirs.len == 0) return;
    try w.writeAll(",\n  \"system_libs\": {");
    for (subdirs, 0..) |sd, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try str(w, sd.subdir);
        try w.writeAll(": [");
        for (sd.libs, 0..) |lib, j| {
            try w.writeAll(if (j == 0) "\n      {" else ",\n      {");
            const fields = [_]struct { []const u8, []const u8 }{
                .{ "name", lib.name },   .{ "version", lib.version }, .{ "build", lib.build },
                .{ "url", lib.url },     .{ "sha256", lib.sha256 },
            };
            for (fields, 0..) |f, n| {
                try w.print("{s}\n        \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
                try str(w, f[1]);
            }
            try w.print(",\n        \"size\": {d}", .{lib.size});
            if (lib.deps.len > 0) {
                try w.writeAll(",\n        \"deps\": [");
                for (lib.deps, 0..) |d, k| {
                    try w.writeAll(if (k == 0) "\n          " else ",\n          ");
                    try str(w, d);
                }
                try w.writeAll("\n        ]");
            }
            try w.writeAll("\n      }");
        }
        try w.writeAll(if (sd.libs.len == 0) "]" else "\n    ]");
    }
    try w.writeAll("\n  }");
}

/// `,"loads": [...]` of a package entry, or nothing for none.
pub fn writeLoads(w: anytype, loads: []const []const u8) !void {
    if (loads.len == 0) return;
    try w.writeAll(",\n      \"loads\": [");
    for (loads, 0..) |n, i| {
        try w.writeAll(if (i == 0) "\n        " else ",\n        ");
        try str(w, n);
    }
    try w.writeAll("\n      ]");
}
