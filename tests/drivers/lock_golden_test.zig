//! The locks mopm's unit tests write, checked against the lock contract, in
//! Zig, for the build farm, which has no Python. (This file replaced
//! tests/resolve/check_golden.py.)
//!
//! Each tests/resolve/golden/*.lock is the exact output of a Zig unit test
//! (src/core/install_plan.zig compares the bytes). Here each one must pass
//! spec/lock.schema.json and the rules of spec/lock.md that the schema cannot
//! express (contract.lockProblems).
//!
//! So that this check is shown to be able to fail, each golden is also broken
//! in the ways a faulty lock writer would break it, and every broken copy must
//! be refused.
//!
//! Run by Buck2 (//:lock_golden) from the repository root.

const std = @import("std");
const c = @import("contract.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// The schema's errors, then (if none) the lock rules'.
fn problems(a: Allocator, schema: Value, doc: Value) !c.Problems {
    var out = c.Problems.init(a);
    const errs = try c.schemaErrors(a, schema, schema, doc);
    for (errs.items) |e| try out.append(e);
    if (out.items.len == 0) {
        const rules = try c.lockProblems(a, doc);
        for (rules.items) |e| try out.append(e);
    }
    return out;
}

const Variant = struct { what: []const u8, doc: Value };

fn setStr(a: Allocator, obj: *Value, key: []const u8, value: []const u8) !void {
    try obj.object.put(key, .{ .string = try a.dupe(u8, value) });
}

/// The packages array of a copy of `doc`.
fn packagesOf(doc: *Value) *std.json.Array {
    return &doc.object.getPtr("packages").?.array;
}

fn firstWithDeps(doc: *Value) ?*Value {
    for (packagesOf(doc).items) |*p| {
        if (c.getArr(p.*, "deps").len != 0) return p;
    }
    return null;
}

/// The artifact of `pkg` for the first Mojo version it has one for.
fn artifactOf(pkg: *Value) *Value {
    return &pkg.object.getPtr("artifacts").?.object.values()[0];
}

/// `pkg`, a registry entry, as an entry of the namespace `ns`: its name, its channel and the name and url of its file.
fn moveToNamespace(a: Allocator, pkg: *Value, ns: []const u8) !void {
    const old_name = c.getStr(pkg.*, "name").?;
    const old_ns = old_name[0..std.mem.indexOfScalar(u8, old_name, '/').?];
    const import_name = old_name[old_ns.len + 1 ..];
    try setStr(a, pkg, "name", try std.fmt.allocPrint(a, "{s}/{s}", .{ ns, import_name }));
    try setStr(a, pkg, "channel", try std.fmt.allocPrint(a, "https://conda.mopm.dev/{s}/", .{ns}));
    const art = artifactOf(pkg);
    const url = c.getStr(art.*, "url").?;
    const moved = try std.mem.replaceOwned(u8, a, url, try std.fmt.allocPrint(a, "/{s}/", .{old_ns}), try std.fmt.allocPrint(a, "/{s}/", .{ns}));
    try setStr(a, art, "url", try std.mem.replaceOwned(u8, a, moved, try std.fmt.allocPrint(a, "mojo-{s}.", .{old_ns}), try std.fmt.allocPrint(a, "mojo-{s}.", .{ns})));
}

/// The ways a faulty writer breaks `doc`: (what it does, the broken lock).
fn variants(a: Allocator, doc: Value) ![]Variant {
    var out = std.ArrayList(Variant).init(a);

    var d = try c.clone(a, doc);
    std.mem.reverse(Value, packagesOf(&d).items);
    try out.append(.{ .what = "writes packages out of order", .doc = d });

    d = try c.clone(a, doc);
    try packagesOf(&d).append(try c.clone(a, packagesOf(&d).items[0]));
    try out.append(.{ .what = "writes an entry twice", .doc = d });

    d = try c.clone(a, doc);
    _ = artifactOf(&packagesOf(&d).items[0]).object.orderedRemove("sha256");
    try out.append(.{ .what = "drops a sha256", .doc = d });

    d = try c.clone(a, doc);
    {
        const art = artifactOf(&packagesOf(&d).items[0]);
        const lower = c.getStr(art.*, "sha256").?;
        try setStr(a, art, "sha256", try std.ascii.allocUpperString(a, lower));
    }
    try out.append(.{ .what = "writes a sha256 in upper case", .doc = d });

    d = try c.clone(a, doc);
    {
        const first = &packagesOf(&d).items[0];
        const art = artifactOf(first);
        const url = c.getStr(art.*, "url").?;
        try setStr(a, art, "url", try std.mem.replaceOwned(u8, a, url, c.getStr(first.*, "version").?, "9.9.9"));
    }
    try out.append(.{ .what = "builds the url from the wrong version", .doc = d });

    d = try c.clone(a, doc);
    {
        const first = &packagesOf(&d).items[0];
        const art = artifactOf(first);
        const url = c.getStr(art.*, "url").?;
        // The old flat name, `mojo-<name>-...`, in place of `mojo-<namespace>.<name>-...`.
        try setStr(a, art, "url", try std.mem.replaceOwned(u8, a, url, "mojo-acme.", "mojo-"));
    }
    try out.append(.{ .what = "builds the url from the name without its namespace", .doc = d });

    d = try c.clone(a, doc);
    {
        const artifacts = &packagesOf(&d).items[0].object.getPtr("artifacts").?.object;
        const art = artifacts.get("1.0.0").?;
        _ = artifacts.orderedRemove("1.0.0");
        try artifacts.put("9.9.9", art);
    }
    try out.append(.{ .what = "pins a build for another mojo", .doc = d });

    d = try c.clone(a, doc);
    {
        const p = firstWithDeps(&d) orelse return error.NoPackageWithDeps;
        var deps = std.json.Array.init(a);
        try deps.append(.{ .string = "acme/not_locked" });
        try p.object.put("deps", .{ .array = deps });
    }
    try out.append(.{ .what = "names a dependency it did not lock", .doc = d });

    d = try c.clone(a, doc);
    {
        const p = firstWithDeps(&d) orelse return error.NoPackageWithDeps;
        var deps = std.json.Array.init(a);
        try deps.append(.{ .string = "http_core" });
        try p.object.put("deps", .{ .array = deps });
    }
    try out.append(.{ .what = "names a dependency by its import name", .doc = d });

    d = try c.clone(a, doc);
    {
        var chans = std.json.Array.init(a);
        try chans.append(.{ .string = "https://conda.example/" });
        try d.object.put("channels", .{ .array = chans });
    }
    try out.append(.{ .what = "writes a channel the project does not list", .doc = d });

    d = try c.clone(a, doc);
    try setStr(a, &packagesOf(&d).items[0], "channel", "https://conda.mopm.dev/");
    try out.append(.{ .what = "writes an entry's channel without its namespace", .doc = d });

    d = try c.clone(a, doc);
    try setStr(a, &packagesOf(&d).items[0], "name", "crypto");
    try out.append(.{ .what = "names an entry without its namespace", .doc = d });

    d = try c.clone(a, doc);
    {
        // Another namespace's package with the import name of the first entry: Mojo could import only one of them.
        var twin = try c.clone(a, packagesOf(&d).items[0]);
        _ = twin.object.orderedRemove("native");
        try moveToNamespace(a, &twin, "zeta");
        try packagesOf(&d).append(twin);
    }
    try out.append(.{ .what = "locks two packages of one import name", .doc = d });

    d = try c.clone(a, doc);
    try d.object.put("lock_version", .{ .integer = 2 });
    try out.append(.{ .what = "writes lock_version 2", .doc = d });

    return out.items;
}

test "the locks mopm's unit tests write pass the lock contract, and a faulty writer's do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = c.Tally{};

    const schema = try c.loadJson(a, "spec/lock.schema.json");
    const goldens = try c.listFiles(a, "tests/resolve/golden", ".lock");
    if (goldens.len == 0) t.fail("no golden locks under tests/resolve/golden", .{});
    for (goldens) |name| {
        const path = try std.fmt.allocPrint(a, "tests/resolve/golden/{s}", .{name});
        const doc = try c.loadJson(a, path);
        const found = try problems(a, schema, doc);
        for (found.items) |p| t.fail("{s}: {s}", .{ path, p });
        std.debug.print("ok   {s} passes the schema and the lock rules\n", .{path});
        for (try variants(a, doc)) |m| {
            const refused = try problems(a, schema, m.doc);
            if (refused.items.len == 0) {
                t.fail("{s}: a writer that {s} would pass this check", .{ path, m.what });
            } else {
                std.debug.print("ok   {s} refused when the writer {s}\n", .{ path, m.what });
            }
        }
    }
    try t.finish();
}
