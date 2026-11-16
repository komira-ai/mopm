//! One package per import name in a dependency closure (docs/design/namespaces.md, section 4; spec/mopm-toml.md,
//! "Rules"; spec/lock.md, rule 10; spec/unit-graph.md).
//!
//! Mojo imports a package by its import name, the part of its full name after `/` (`import json` for
//! `komira-ai/json`), so two packages whose full names differ and whose import names are the same cannot both be in
//! one closure: the root, its path packages and its registry packages, from `[dependencies]` and
//! `[dev-dependencies]` together. `check` finds every such import name and says, for each package that has it, the
//! shortest dependency path from the root (ties broken by comparing the full names along the path as bytes; a path
//! that starts in `[dev-dependencies]` is marked `(dev)` and loses a tie to one that does not). Resolution is not
//! changed to avoid a clash: the refusal is deterministic. There is no rename.
//!
//! `ofProject` makes the closure `check` reads from a manifest, its path packages and, when there is one, a lock,
//! whose registry entries are each named by their own full name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const names = @import("names.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const install_plan = @import("install_plan.zig");

/// One package of a closure.
pub const Package = struct {
    /// The full name, `<namespace>/<name>`.
    full: []const u8,
    /// What follows the name in a message: the version, or, for a registry package not resolved yet, its
    /// requirement in quotes.
    label: []const u8,
    /// The full names of the packages it depends on. A name that is no package of the closure is skipped.
    deps: []const []const u8 = &.{},
};

/// The packages to check: the root, whose `deps` are its `[dependencies]`, and every other package.
pub const Closure = struct {
    root: Package,
    /// The root's `[dev-dependencies]`.
    dev_deps: []const []const u8 = &.{},
    packages: []const Package = &.{},
};

const no_node = std.math.maxInt(usize);

/// How the root reaches a package: the package before it on the shortest path, and whether that path starts in
/// `[dev-dependencies]`.
const Reach = struct { parent: usize = no_node, dev: bool = false, seen: bool = false };

/// A first step from the root.
const Edge = struct { to: usize, dev: bool };

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The refusal of every import name that two or more packages of `c` have, or null when there is none. The message
/// has no `error:` prefix and no final newline; the caller adds both.
pub fn check(arena: Allocator, c: Closure) Allocator.Error!?[]const u8 {
    // Node 0 is the root; a full name given twice is one package (the first).
    var nodes = std.ArrayList(Package).init(arena);
    var index = std.StringHashMap(usize).init(arena);
    try nodes.append(c.root);
    try index.put(c.root.full, 0);
    for (c.packages) |p| {
        if (index.contains(p.full)) continue;
        try index.put(p.full, nodes.items.len);
        try nodes.append(p);
    }
    const reach = try arena.alloc(Reach, nodes.items.len);
    @memset(reach, .{});
    reach[0].seen = true;

    // Breadth first, one level at a time. A level is in the order of its paths (compared by the full names along
    // them, a path that starts in [dependencies] before the same path from [dev-dependencies]); each package's own
    // dependencies are taken in byte order. So the first time a package is reached is by its shortest path, and among
    // the shortest by the least.
    var first = std.ArrayList(Edge).init(arena);
    for ([_][]const []const u8{ c.root.deps, c.dev_deps }, 0..) |group, g| {
        for (group) |d| {
            const to = index.get(d) orelse continue;
            try first.append(.{ .to = to, .dev = g == 1 });
        }
    }
    std.mem.sort(Edge, first.items, @as([]const Package, nodes.items), struct {
        fn less(ns: []const Package, a: Edge, b: Edge) bool {
            return switch (std.mem.order(u8, ns[a.to].full, ns[b.to].full)) {
                .lt => true,
                .gt => false,
                .eq => !a.dev and b.dev,
            };
        }
    }.less);
    var level = std.ArrayList(usize).init(arena);
    for (first.items) |e| {
        if (reach[e.to].seen) continue;
        reach[e.to] = .{ .parent = 0, .dev = e.dev, .seen = true };
        try level.append(e.to);
    }
    while (level.items.len > 0) {
        var next = std.ArrayList(usize).init(arena);
        for (level.items) |at| {
            const deps = try arena.dupe([]const u8, nodes.items[at].deps);
            std.mem.sort([]const u8, deps, {}, lessBytes);
            for (deps) |d| {
                const to = index.get(d) orelse continue;
                if (reach[to].seen) continue;
                reach[to] = .{ .parent = at, .dev = reach[at].dev, .seen = true };
                try next.append(to);
            }
        }
        level = next;
    }

    // The packages reached, by import name, then by full name.
    var order = std.ArrayList(usize).init(arena);
    for (reach, 0..) |r, i| {
        if (r.seen) try order.append(i);
    }
    std.mem.sort(usize, order.items, @as([]const Package, nodes.items), struct {
        fn less(ns: []const Package, a: usize, b: usize) bool {
            return switch (std.mem.order(u8, names.importName(ns[a].full), names.importName(ns[b].full))) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, ns[a].full, ns[b].full) == .lt,
            };
        }
    }.less);

    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    var i: usize = 0;
    while (i < order.items.len) {
        const name = names.importName(nodes.items[order.items[i]].full);
        var j = i + 1;
        while (j < order.items.len and std.mem.eql(u8, names.importName(nodes.items[order.items[j]].full), name)) j += 1;
        const group = order.items[i..j];
        i = j;
        if (group.len < 2) continue;
        try w.print("{d} packages in the dependency closure have the import name '{s}'; Mojo imports a package by the part after '/', so a closure holds one package per import name:\n", .{ group.len, name });
        var width: usize = 0;
        for (group) |n| width = @max(width, nodes.items[n].full.len + 1 + nodes.items[n].label.len);
        for (group) |n| {
            const p = nodes.items[n];
            try w.print("  {s} {s}", .{ p.full, p.label });
            try out.appendNTimes(' ', width - (p.full.len + 1 + p.label.len) + 5);
            try writePath(arena, w, nodes.items, reach, n);
            try w.writeByte('\n');
        }
    }
    if (out.items.len == 0) return null;
    try w.writeAll("There is no rename: drop one of the dependencies that brings them in.");
    return out.items;
}

/// The path from the root to `n`: the root's full name alone, then ` -> <full name> <label>` for each step, and
/// ` (dev)` at the end of a path that starts in `[dev-dependencies]`.
fn writePath(arena: Allocator, w: anytype, nodes: []const Package, reach: []const Reach, n: usize) !void {
    var steps = std.ArrayList(usize).init(arena);
    var at = n;
    while (at != 0) : (at = reach[at].parent) try steps.append(at);
    try w.writeAll(nodes[0].full);
    var k = steps.items.len;
    while (k > 0) {
        k -= 1;
        const p = nodes[steps.items[k]];
        try w.print(" -> {s} {s}", .{ p.full, p.label });
    }
    if (reach[n].dev) try w.writeAll(" (dev)");
}

// ------------------------------------------------------------- the closure of a project

/// The closure of the project whose manifest is `m`, with its path packages `members` (at any depth) and the lock
/// `l`'s registry entries. With no lock, each registry dependency a manifest names is a package with no
/// dependencies, labelled with its requirement: what can be checked before resolution. Path entries of `l` are not
/// read: `members` are the path packages.
pub fn ofProject(arena: Allocator, m: manifest.Manifest, members: []const install_plan.PathDep, l: ?lock.Lock) Allocator.Error!Closure {
    // The registry dependencies the manifests of the closure name, by full name, with their requirements.
    var requirement = std.StringArrayHashMap([]const u8).init(arena);
    const lists = [_][]const manifest.Dep{ m.dependencies, m.dev_dependencies };
    for (lists) |group| {
        for (group) |d| {
            if (d.source == .version and !requirement.contains(d.full_name)) try requirement.put(d.full_name, d.source.version);
        }
    }
    for (members) |p| {
        for (p.manifest_deps) |d| {
            if (d.source == .version and !requirement.contains(d.full_name)) try requirement.put(d.full_name, d.source.version);
        }
    }

    var root_deps: [2]std.ArrayList([]const u8) = .{ std.ArrayList([]const u8).init(arena), std.ArrayList([]const u8).init(arena) };
    for (lists, 0..) |group, g| {
        for (group) |d| try root_deps[g].append(d.full_name);
    }
    var packages = std.ArrayList(Package).init(arena);
    for (members) |p| {
        var deps = std.ArrayList([]const u8).init(arena);
        if (p.manifest_deps.len > 0) {
            for (p.manifest_deps) |d| try deps.append(d.full_name);
        } else {
            try deps.appendSlice(p.deps);
        }
        try packages.append(.{ .full = p.full(), .label = p.version, .deps = deps.items });
    }

    if (l) |locked| {
        // One package per full name the lock holds (a lock lists one entry per subdir): the first entry's version,
        // every entry's dependencies.
        var seen = std.StringArrayHashMap(usize).init(arena);
        var entries = std.ArrayList(struct { name: []const u8, version: []const u8, deps: std.ArrayList([]const u8) }).init(arena);
        for (locked.packages) |p| {
            if (p.source == .path) continue;
            const got = try seen.getOrPut(p.name);
            if (!got.found_existing) {
                got.value_ptr.* = entries.items.len;
                try entries.append(.{ .name = p.name, .version = p.version, .deps = std.ArrayList([]const u8).init(arena) });
            }
            try entries.items[got.value_ptr.*].deps.appendSlice(p.deps);
        }
        for (entries.items) |e| try packages.append(.{ .full = e.name, .label = e.version, .deps = e.deps.items });
    } else {
        for (requirement.keys(), requirement.values()) |full, req| {
            try packages.append(.{ .full = full, .label = try std.fmt.allocPrint(arena, "\"{s}\"", .{req}) });
        }
    }
    return .{
        .root = .{ .full = m.package.full_name, .label = m.package.version, .deps = root_deps[0].items },
        .dev_deps = root_deps[1].items,
        .packages = packages.items,
    };
}
