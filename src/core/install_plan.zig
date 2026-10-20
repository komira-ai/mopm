//! From a resolution to a lock, and the views of a lock that `mopm lock`,
//! `mopm update` and `mopm tree` print.
//!
//! `buildLock` makes one lock entry per file of every picked version (one per
//! subdir), taking `sha256` and `size` from the channel's
//! `<subdir>/repodata.json` (spec/channel.md). The sparse index must carry
//! the same values (spec/index.md, "files[].sha256 and size"); a difference,
//! or a file the repodata does not offer, is an error that names both sides.
//! Only `sha256`, `size` and `removed` are read from repodata.json: a lock
//! entry's `deps` come from the index record's `deps[]`, never from the
//! repodata's `depends`. The channel URL must be one a lock may hold
//! (lock.allowedChannel), or no lock is built.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");

const Error = resolve.Error;
const Diagnostic = resolve.Diagnostic;

const Repodata = struct {
    packages: std.json.ObjectMap,
    removed: []const std.json.Value,
};

fn bad(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    return resolve.fail(arena, diag, .bad_channel, fmt, args);
}

fn parseRepodata(arena: Allocator, subdir: []const u8, text: []const u8, diag: *Diagnostic) Error!Repodata {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return bad(arena, diag, "{s}/repodata.json is not JSON", .{subdir});
    };
    const top = switch (v) {
        .object => |o| o,
        else => return bad(arena, diag, "{s}/repodata.json is not a JSON object", .{subdir}),
    };
    const packages = switch (top.get("packages.conda") orelse return bad(arena, diag, "{s}/repodata.json has no packages.conda", .{subdir})) {
        .object => |o| o,
        else => return bad(arena, diag, "{s}/repodata.json's packages.conda is not an object", .{subdir}),
    };
    const removed: []const std.json.Value = if (top.get("removed")) |r| switch (r) {
        .array => |a| a.items,
        else => return bad(arena, diag, "{s}/repodata.json's removed is not an array", .{subdir}),
    } else &.{};
    return .{ .packages = packages, .removed = removed };
}

/// The lock of `res`: every file of every picked version, from `channel_url`.
/// `channel.fetch(arena, subdir, diag)` returns the text of that subdir's
/// repodata.json, or `error.ResolveFailed` with `diag` set.
pub fn buildLock(arena: Allocator, res: resolve.Resolution, channel_url: []const u8, channel: anytype, diag: *Diagnostic) Error!lock.Lock {
    if (!lock.allowedChannel(channel_url)) return bad(arena, diag, "channel {s} is refused: {s}", .{ channel_url, lock.channel_rule });
    var repodata = std.StringHashMap(Repodata).init(arena);
    var packages = std.ArrayList(lock.Package).init(arena);
    for (res.packages) |p| {
        const rec = p.record;
        var natives = std.ArrayList(lock.Native).init(arena);
        for (rec.native) |n| try natives.append(.{ .id = n.id, .soname = n.soname });
        for (rec.files) |f| {
            const want_name = try std.fmt.allocPrint(arena, "mojo-{s}-{s}-{s}.conda", .{ rec.name, rec.version, rec.build });
            if (!std.mem.eql(u8, want_name, f.filename)) {
                return bad(arena, diag, "the index lists {s} for {s} {s} (build {s}); the channel name is {s}", .{ f.filename, rec.name, rec.version, rec.build, want_name });
            }
            const rd = repodata.get(f.subdir) orelse blk: {
                const text = try channel.fetch(arena, f.subdir, diag);
                const parsed = try parseRepodata(arena, f.subdir, text, diag);
                try repodata.put(f.subdir, parsed);
                break :blk parsed;
            };
            const entry = switch (rd.packages.get(f.filename) orelse {
                for (rd.removed) |r| {
                    if (r == .string and std.mem.eql(u8, r.string, f.filename)) {
                        return bad(arena, diag, "{s}/repodata.json lists {s} as removed, but the index says {s} {s} is published", .{ f.subdir, f.filename, rec.name, rec.version });
                    }
                }
                return bad(arena, diag, "{s}/repodata.json does not offer {s}, which the index lists for {s} {s}", .{ f.subdir, f.filename, rec.name, rec.version });
            }) {
                .object => |o| o,
                else => return bad(arena, diag, "{s}/repodata.json: the entry of {s} is not an object", .{ f.subdir, f.filename }),
            };
            const sha = switch (entry.get("sha256") orelse return bad(arena, diag, "{s}/repodata.json: {s} has no sha256", .{ f.subdir, f.filename })) {
                .string => |s| s,
                else => return bad(arena, diag, "{s}/repodata.json: the sha256 of {s} is not a string", .{ f.subdir, f.filename }),
            };
            const size: i64 = switch (entry.get("size") orelse return bad(arena, diag, "{s}/repodata.json: {s} has no size", .{ f.subdir, f.filename })) {
                .integer => |s| s,
                else => return bad(arena, diag, "{s}/repodata.json: the size of {s} is not an integer", .{ f.subdir, f.filename }),
            };
            if (!std.mem.eql(u8, sha, f.sha256) or size != @as(i64, @intCast(f.size))) {
                return bad(arena, diag, "{s}: the index says sha256 {s}, size {d}; {s}/repodata.json says sha256 {s}, size {d}", .{ f.filename, f.sha256, f.size, f.subdir, sha, size });
            }
            try packages.append(.{
                .name = rec.name,
                .version = rec.version,
                .build = rec.build,
                .subdir = f.subdir,
                .channel = channel_url,
                .url = try lock.fileUrl(arena, channel_url, f.subdir, rec.name, rec.version, rec.build),
                .sha256 = f.sha256,
                .size = f.size,
                .mojo = res.mojo,
                .deps = p.deps,
                .native = natives.items,
            });
        }
    }
    lock.sortPackages(packages.items);
    const channels = try arena.alloc([]const u8, 1);
    channels[0] = channel_url;
    return .{ .mojo = res.mojo, .channels = channels, .packages = packages.items };
}

/// A path dependency of the project, read from its own mopm.toml.
pub const PathDep = struct {
    name: []const u8,
    /// `[package] version` of its mopm.toml.
    version: []const u8,
    /// Its directory, relative to the project, `/`-separated.
    path: []const u8,
    /// Names of its own dependencies (registry and path), sorted.
    deps: []const []const u8 = &.{},
};

/// `l` with one `source = path` entry per path dependency (lock.zig): no
/// file, so nothing to download. A path dependency whose name the registry
/// resolution also picked (some registry package depends on that name) is
/// refused: a name comes from one place.
pub fn addPaths(arena: Allocator, l: lock.Lock, paths: []const PathDep, diag: *Diagnostic) Error!lock.Lock {
    var packages = std.ArrayList(lock.Package).init(arena);
    try packages.appendSlice(l.packages);
    for (paths) |d| {
        for (l.packages) |p| {
            if (!std.mem.eql(u8, p.name, d.name)) continue;
            var by = std.ArrayList(u8).init(arena);
            for (l.packages, 0..) |q, qi| {
                if (qi > 0 and std.mem.eql(u8, l.packages[qi - 1].name, q.name)) continue; // another subdir
                for (q.deps) |x| {
                    if (std.mem.eql(u8, x, d.name)) try by.writer().print("{s}{s} {s}", .{ if (by.items.len == 0) "" else ", ", q.name, q.version });
                }
            }
            return resolve.fail(arena, diag, .conflict, "{s} is a path dependency ({s}), and the registry's {s} needs {s} {s} too; a package comes from one place", .{ d.name, d.path, by.items, d.name, p.version });
        }
        try packages.append(.{ .name = d.name, .version = d.version, .source = .path, .path = d.path, .deps = d.deps });
    }
    lock.sortPackages(packages.items);
    var out = l;
    out.packages = packages.items;
    return out;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessArtifact(_: void, a: lock.Artifact, b: lock.Artifact) bool {
    return std.mem.order(u8, a.mojo, b.mojo) == .lt;
}

/// One version 2 lock from `per`, a lock (as `buildLock` makes it) for each
/// Mojo version in `per[i].mojo`. A package version picked for several Mojo
/// versions becomes one entry with one artifact each; a version picked for
/// one only has one. `closures` are the toolchain hashes of those versions.
pub fn mergeMojos(arena: Allocator, per: []const lock.Lock, closures: []const lock.Closure) Allocator.Error!lock.Lock {
    var packages = std.ArrayList(lock.Package).init(arena);
    var mojos = std.ArrayList([]const u8).init(arena);
    for (per) |l| {
        try mojos.append(l.mojo);
        for (l.packages) |p| {
            const art = lock.Artifact{ .mojo = l.mojo, .build = p.build, .url = p.url, .sha256 = p.sha256, .size = p.size };
            var at: ?usize = null;
            for (packages.items, 0..) |q, i| {
                if (std.mem.eql(u8, q.name, p.name) and std.mem.eql(u8, q.version, p.version) and std.mem.eql(u8, q.subdir, p.subdir)) at = i;
            }
            if (at) |i| {
                const old = packages.items[i].artifacts;
                const grown = try arena.alloc(lock.Artifact, old.len + 1);
                @memcpy(grown[0..old.len], old);
                grown[old.len] = art;
                packages.items[i].artifacts = grown;
                var names = std.ArrayList([]const u8).init(arena);
                try names.appendSlice(packages.items[i].deps);
                for (p.deps) |d| {
                    var have = false;
                    for (names.items) |x| have = have or std.mem.eql(u8, x, d);
                    if (!have) try names.append(d);
                }
                std.mem.sort([]const u8, names.items, {}, lessName);
                packages.items[i].deps = names.items;
            } else {
                var q = p;
                q.build = "";
                q.url = "";
                q.sha256 = "";
                q.size = 0;
                q.mojo = "";
                q.artifacts = try arena.dupe(lock.Artifact, &.{art});
                try packages.append(q);
            }
        }
    }
    for (packages.items) |*p| std.mem.sort(lock.Artifact, @constCast(p.artifacts), {}, lessArtifact);
    std.mem.sort([]const u8, mojos.items, {}, lessName);
    lock.sortPackages(packages.items);
    return .{ .mojo = mojos.items[0], .channels = per[0].channels, .packages = packages.items, .mojos = mojos.items, .closures = closures };
}

/// One line per package whose version changed between `old` and `new`
/// (`adding`, `removing`, `updating a -> b`), by name.
pub fn writeChanges(old: ?lock.Lock, new: lock.Lock, w: anytype) !void {
    const empty = lock.Lock{ .mojo = "", .channels = &.{}, .packages = &.{} };
    const before = old orelse empty;
    var i: usize = 0;
    var j: usize = 0;
    const a = before.packages;
    const b = new.packages;
    while (i < a.len or j < b.len) {
        const o: std.math.Order = if (i == a.len) .gt else if (j == b.len) .lt else std.mem.order(u8, a[i].name, b[j].name);
        switch (o) {
            .lt => try w.print("removing {s} {s}\n", .{ a[i].name, a[i].version }),
            .gt => try w.print("adding {s} {s}\n", .{ b[j].name, b[j].version }),
            .eq => if (!std.mem.eql(u8, a[i].version, b[j].version)) {
                try w.print("updating {s} {s} -> {s}\n", .{ a[i].name, a[i].version, b[j].version });
            },
        }
        // Skip the other subdirs of the same name.
        const name = if (o == .gt) b[j].name else a[i].name;
        if (o != .gt) {
            while (i < a.len and std.mem.eql(u8, a[i].name, name)) i += 1;
        }
        if (o != .lt) {
            while (j < b.len and std.mem.eql(u8, b[j].name, name)) j += 1;
        }
    }
}

fn find(l: lock.Lock, name: []const u8) ?lock.Package {
    for (l.packages) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

const Tree = struct {
    l: lock.Lock,
    l_arena: Allocator,
    expanded: std.StringHashMap(void),
    prefix: std.ArrayList(u8),

    fn node(t: *Tree, name: []const u8, last: bool, w: anytype) anyerror!void {
        const p = find(t.l, name).?;
        const seen = t.expanded.contains(name);
        const from = if (p.source == .path) try std.fmt.allocPrint(t.l_arena, " ({s})", .{p.path}) else "";
        try w.print("{s}{s}{s} {s}{s}{s}\n", .{ t.prefix.items, if (last) "└── " else "├── ", p.name, p.version, from, if (seen and p.deps.len > 0) " (*)" else "" });
        if (seen or p.deps.len == 0) return;
        try t.expanded.put(name, {});
        const mark = t.prefix.items.len;
        try t.prefix.appendSlice(if (last) "    " else "│   ");
        for (p.deps, 0..) |d, n| try t.node(d, n + 1 == p.deps.len, w);
        t.prefix.shrinkRetainingCapacity(mark);
    }
};

/// The name of the first of `names` that `l` does not lock, or null.
pub fn missing(l: lock.Lock, names: []const []const u8) ?[]const u8 {
    for (names) |n| {
        if (find(l, n) == null) return n;
    }
    return null;
}

/// The resolved graph, as cargo tree draws it: the project, then each
/// dependency (sorted by name) with its own below it; a path dependency is
/// followed by its path in parentheses. A package whose
/// dependencies were already drawn is marked `(*)` and not drawn again.
/// Every name in `deps` and `dev_deps` must be in `l` (see `missing`).
pub fn writeTree(arena: Allocator, project: []const u8, version: []const u8, deps: []const []const u8, dev_deps: []const []const u8, l: lock.Lock, w: anytype) !void {
    var t = Tree{ .l = l, .l_arena = arena, .expanded = std.StringHashMap(void).init(arena), .prefix = std.ArrayList(u8).init(arena) };
    try w.print("{s} {s}\n", .{ project, version });
    const groups = [_]struct { []const u8, []const []const u8 }{ .{ "", deps }, .{ "[dev-dependencies]\n", dev_deps } };
    for (groups) |g| {
        if (g[1].len == 0) continue;
        try w.writeAll(g[0]);
        const sorted = try arena.dupe([]const u8, g[1]);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for (sorted, 0..) |name, n| try t.node(name, n + 1 == sorted.len, w);
    }
}

// ---------------------------------------------------------------- tests

const MemoryIndex = resolve.MemoryIndex;

/// A channel held in memory: subdir -> repodata.json text.
const MemoryChannel = struct {
    files: []const struct { []const u8, []const u8 },

    pub fn fetch(self: MemoryChannel, arena: Allocator, subdir: []const u8, diag: *Diagnostic) Error![]const u8 {
        for (self.files) |f| {
            if (std.mem.eql(u8, f[0], subdir)) return f[1];
        }
        return resolve.fail(arena, diag, .bad_channel, "no {s}/repodata.json", .{subdir});
    }
};

const digests = [_][]const u8{
    "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
    "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9",
    "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9",
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
};

fn fileJson(comptime subdir: []const u8, comptime file: []const u8, comptime digest: []const u8) []const u8 {
    return "{\"filename\":\"" ++ file ++ "\",\"sha256\":\"" ++ digest ++ "\",\"size\":1000,\"subdir\":\"" ++ subdir ++ "\"}";
}

fn recJson(comptime name: []const u8, comptime version: []const u8, comptime deps: []const u8, comptime native: []const u8, comptime files: []const u8) []const u8 {
    return "{\"build\":\"mojo1.0.0_0\",\"deps\":[" ++ deps ++ "],\"files\":[" ++ files ++ "],\"manifest_sha256\":\"" ++ digests[0] ++
        "\",\"name\":\"" ++ name ++ "\",\"native\":[" ++ native ++ "],\"published_at\":\"2026-10-13T12:00:00Z\",\"requires_mojo\":\"==1.0.0\",\"state\":\"published\",\"v\":1,\"version\":\"" ++ version ++ "\"}\n";
}

fn entryJson(comptime name: []const u8, comptime version: []const u8, comptime subdir: []const u8, comptime digest: []const u8) []const u8 {
    return "\"mojo-" ++ name ++ "-" ++ version ++ "-mojo1.0.0_0.conda\":{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-" ++ name ++
        "\",\"sha256\":\"" ++ digest ++ "\",\"size\":1000,\"subdir\":\"" ++ subdir ++ "\",\"version\":\"" ++ version ++ "\"}";
}

fn repodataJson(comptime subdir: []const u8, comptime entries: []const u8, comptime removed: []const u8) []const u8 {
    return "{\"info\":{\"subdir\":\"" ++ subdir ++ "\"},\"packages\":{},\"packages.conda\":{" ++ entries ++ "},\"removed\":[" ++ removed ++ "]}\n";
}

/// The diamond of tests/resolve/golden/diamond.lock: http_client and tls
/// both need http_core; crypto ships a native library and has two subdirs.
const diamond_index = MemoryIndex{ .files = &.{
    .{ "http_client", recJson("http_client", "0.4.0", "{\"name\":\"http_core\",\"range\":\">=1.2,<2\"},{\"name\":\"crypto\",\"range\":\"2\"}", "", fileJson("linux-64", "mojo-http_client-0.4.0-mojo1.0.0_0.conda", digests[0])) },
    .{ "tls", recJson("tls", "1.1.0", "{\"name\":\"http_core\",\"range\":\"~1.2\"}", "", fileJson("linux-64", "mojo-tls-1.1.0-mojo1.0.0_0.conda", digests[1])) },
    .{ "http_core", recJson("http_core", "1.2.5", "", "", fileJson("linux-64", "mojo-http_core-1.2.5-mojo1.0.0_0.conda", digests[2])) ++
        recJson("http_core", "1.3.0", "", "", fileJson("linux-64", "mojo-http_core-1.3.0-mojo1.0.0_0.conda", digests[4])) },
    .{ "crypto", recJson("crypto", "2.0.1", "", "{\"id\":\"crypto\",\"soname\":\"libcrypto_native.so.1\"}", fileJson("linux-64", "mojo-crypto-2.0.1-mojo1.0.0_0.conda", digests[3]) ++ "," ++
        fileJson("osx-arm64", "mojo-crypto-2.0.1-mojo1.0.0_0.conda", digests[4])) },
} };

const diamond_channel = MemoryChannel{ .files = &.{
    .{ "linux-64", repodataJson("linux-64", entryJson("crypto", "2.0.1", "linux-64", digests[3]) ++ "," ++ entryJson("http_client", "0.4.0", "linux-64", digests[0]) ++ "," ++
        entryJson("http_core", "1.2.5", "linux-64", digests[2]) ++ "," ++ entryJson("http_core", "1.3.0", "linux-64", digests[4]) ++ "," ++ entryJson("tls", "1.1.0", "linux-64", digests[1]), "") },
    .{ "osx-arm64", repodataJson("osx-arm64", entryJson("crypto", "2.0.1", "osx-arm64", digests[4]), "") },
} };

const diamond_roots = [_]resolve.Root{ .{ .name = "tls", .requirement = "1" }, .{ .name = "http_client", .requirement = "0.4" } };

fn diamondLock(a: Allocator, channel: anytype, diag: *Diagnostic) Error!lock.Lock {
    return diamondLockAt(a, "https://conda.mopm.dev/", channel, diag);
}

fn diamondLockAt(a: Allocator, channel_url: []const u8, channel: anytype, diag: *Diagnostic) Error!lock.Lock {
    const res = try resolve.resolve(a, diamond_index, .{ .mojo = "1.0.0", .roots = &diamond_roots }, diag);
    return buildLock(a, res, channel_url, channel, diag);
}

test "the lock is written for a loopback http channel with a path, and refused for any other http channel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const l = diamondLockAt(a, "http://127.0.0.1:5000/channel/", diamond_channel, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    try std.testing.expectEqualStrings("http://127.0.0.1:5000/channel/linux-64/mojo-crypto-2.0.1-mojo1.0.0_0.conda", l.packages[0].url);
    const text = try lock.render(a, l);
    var why: []const u8 = "";
    _ = lock.parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    for ([_][]const u8{ "http://conda.mopm.dev/", "http://example.com:5000/channel/", "http://127.0.0.1/channel/" }) |url| {
        diag = .{};
        try std.testing.expectError(error.ResolveFailed, diamondLockAt(a, url, diamond_channel, &diag));
        try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, lock.channel_rule) != null);
    }
}

test "a lock entry's deps come from the index record's deps[], never from the repodata's depends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The repodata says http_client depends on http_core >=2 and on zlib;
    // the index record says http_core ">=1.2,<2" and crypto "2".
    const disagreeing = comptime MemoryChannel{ .files = &.{
        .{ "linux-64", repodataJson("linux-64", entryJson("crypto", "2.0.1", "linux-64", digests[3]) ++ "," ++
            "\"mojo-http_client-0.4.0-mojo1.0.0_0.conda\":{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-http_core >=2\",\"mojo-zlib 1\"],\"name\":\"mojo-http_client\",\"sha256\":\"" ++ digests[0] ++ "\",\"size\":1000,\"subdir\":\"linux-64\",\"version\":\"0.4.0\"}," ++
            entryJson("http_core", "1.2.5", "linux-64", digests[2]) ++ "," ++ entryJson("http_core", "1.3.0", "linux-64", digests[4]) ++ "," ++ entryJson("tls", "1.1.0", "linux-64", digests[1]), "") },
        .{ "osx-arm64", repodataJson("osx-arm64", entryJson("crypto", "2.0.1", "osx-arm64", digests[4]), "") },
    } };
    var diag: Diagnostic = .{};
    const l = diamondLock(a, disagreeing, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    // Same bytes as with agreeing repodata: http_core 1.2.5, deps crypto and http_core.
    const want = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "tests/resolve/golden/diamond.lock"), 1 << 20);
    try std.testing.expectEqualStrings(want, try lock.render(a, l));
}

test "golden: the diamond's lock is tests/resolve/golden/diamond.lock, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const l = diamondLock(a, diamond_channel, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    const got = try lock.render(a, l);
    const want = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "tests/resolve/golden/diamond.lock"), 1 << 20);
    try std.testing.expectEqualStrings(want, got);
    // What mopm writes, mopm reads back under every rule of spec/lock.md.
    var why: []const u8 = "";
    const again = lock.parse(a, got, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqualStrings(got, try lock.render(a, again));
}

test "a repodata sha256 or size that differs from the index is refused, naming both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const wrong = comptime MemoryChannel{ .files = &.{
        .{ "linux-64", repodataJson("linux-64", entryJson("crypto", "2.0.1", "linux-64", digests[3]) ++ "," ++ entryJson("http_client", "0.4.0", "linux-64", digests[1]) ++ "," ++
            entryJson("http_core", "1.2.5", "linux-64", digests[2]) ++ "," ++ entryJson("tls", "1.1.0", "linux-64", digests[1]), "") },
        .{ "osx-arm64", repodataJson("osx-arm64", entryJson("crypto", "2.0.1", "osx-arm64", digests[4]), "") },
    } };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, diamondLock(a, wrong, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "the index says sha256 " ++ digests[0]) != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "repodata.json says sha256 " ++ digests[1]) != null);

    const gone = comptime MemoryChannel{ .files = &.{
        .{ "linux-64", repodataJson("linux-64", entryJson("crypto", "2.0.1", "linux-64", digests[3]) ++ "," ++
            entryJson("http_core", "1.2.5", "linux-64", digests[2]) ++ "," ++ entryJson("tls", "1.1.0", "linux-64", digests[1]), "\"mojo-http_client-0.4.0-mojo1.0.0_0.conda\"") },
        .{ "osx-arm64", repodataJson("osx-arm64", entryJson("crypto", "2.0.1", "osx-arm64", digests[4]), "") },
    } };
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, diamondLock(a, gone, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "lists mojo-http_client-0.4.0-mojo1.0.0_0.conda as removed") != null);
}

test "tree and changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const l = try diamondLock(a, diamond_channel, &diag);
    var out = std.ArrayList(u8).init(a);
    try writeTree(a, "app", "0.1.0", &.{ "tls", "http_client" }, &.{"crypto"}, l, out.writer());
    try std.testing.expectEqualStrings(
        \\app 0.1.0
        \\├── http_client 0.4.0
        \\│   ├── crypto 2.0.1
        \\│   └── http_core 1.2.5
        \\└── tls 1.1.0
        \\    └── http_core 1.2.5
        \\[dev-dependencies]
        \\└── crypto 2.0.1
        \\
    , out.items);
    try std.testing.expect(missing(l, &.{ "tls", "nope" }) != null);

    out.clearRetainingCapacity();
    const old_pkgs = try a.dupe(lock.Package, l.packages);
    old_pkgs[3].version = "1.2.4"; // http_core
    var gone = std.ArrayList(lock.Package).init(a);
    for (old_pkgs) |p| {
        if (!std.mem.eql(u8, p.name, "tls")) try gone.append(p);
    }
    try gone.append(.{ .name = "zlib", .version = "1.0.0", .build = "b", .subdir = "linux-64", .channel = "", .url = "", .sha256 = "", .size = 1, .mojo = "" });
    const old = lock.Lock{ .mojo = "1.0.0", .channels = l.channels, .packages = gone.items };
    try writeChanges(old, l, out.writer());
    try std.testing.expectEqualStrings("updating http_core 1.2.4 -> 1.2.5\nadding tls 1.1.0\nremoving zlib 1.0.0\n", out.items);
}

test "path dependencies: one entry each with source path, no file; a name the registry also picked is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const base = try diamondLock(a, diamond_channel, &diag);
    const paths = [_]PathDep{
        .{ .name = "util", .version = "0.0.7", .path = "../util" },
        .{ .name = "local", .version = "0.3.0", .path = "local", .deps = &.{ "tls", "util" } },
    };
    const l = try addPaths(a, base, &paths, &diag);
    try std.testing.expectEqual(base.packages.len + 2, l.packages.len);
    const text = try lock.render(a, l);
    try std.testing.expect(std.mem.indexOf(u8, text,
        \\    {
        \\      "name": "local",
        \\      "version": "0.3.0",
        \\      "source": "path",
        \\      "path": "local",
        \\      "deps": [
        \\        "tls",
        \\        "util"
        \\      ]
        \\    },
    ) != null);
    try std.testing.expect(std.mem.endsWith(u8, text,
        \\    {
        \\      "name": "util",
        \\      "version": "0.0.7",
        \\      "source": "path",
        \\      "path": "../util"
        \\    }
        \\  ]
        \\}
        \\
    ));
    var why: []const u8 = "";
    const again = lock.parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqualStrings(text, try lock.render(a, again));

    var out = std.ArrayList(u8).init(a);
    try writeTree(a, "app", "0.1.0", &.{"local"}, &.{}, l, out.writer());
    try std.testing.expectEqualStrings(
        \\app 0.1.0
        \\└── local 0.3.0 (local)
        \\    ├── tls 1.1.0
        \\    │   └── http_core 1.2.5
        \\    └── util 0.0.7 (../util)
        \\
    , out.items);

    const clash = [_]PathDep{.{ .name = "http_core", .version = "9.0.0", .path = "vendor/http_core" }};
    try std.testing.expectError(error.ResolveFailed, addPaths(a, base, &clash, &diag));
    try std.testing.expectEqual(resolve.Kind.conflict, diag.kind);
    try std.testing.expectEqualStrings("http_core is a path dependency (vendor/http_core), and the registry's http_client 0.4.0, tls 1.1.0 needs http_core 1.2.5 too; a package comes from one place", diag.message);
}

fn flatPackage(a: Allocator, name: []const u8, version: []const u8, mojo: []const u8, deps: []const []const u8) !lock.Package {
    const build = try std.fmt.allocPrint(a, "mojo{s}_0", .{mojo});
    return .{
        .name = name,
        .version = version,
        .build = build,
        .subdir = "linux-64",
        .channel = "https://conda.mopm.dev/",
        .url = try lock.fileUrl(a, "https://conda.mopm.dev/", "linux-64", name, version, build),
        .sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        .size = 1000,
        .mojo = mojo,
        .deps = deps,
    };
}

test "mergeMojos: a version picked for two Mojo versions is one entry with two builds; a version picked for one has one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const channels = [_][]const u8{"https://conda.mopm.dev/"};
    // With Mojo 1.0.0 core 1.2.0 is the newest build; with 1.1.0 it is core 1.3.0. app 1.0.0 serves both.
    const for_10 = lock.Lock{ .mojo = "1.0.0", .channels = &channels, .packages = &.{
        try flatPackage(a, "app", "1.0.0", "1.0.0", &.{"core"}),
        try flatPackage(a, "core", "1.2.0", "1.0.0", &.{}),
    } };
    const for_11 = lock.Lock{ .mojo = "1.1.0", .channels = &channels, .packages = &.{
        try flatPackage(a, "app", "1.0.0", "1.1.0", &.{"core"}),
        try flatPackage(a, "core", "1.3.0", "1.1.0", &.{}),
    } };
    const closures = [_]lock.Closure{
        .{ .mojo = "1.0.0", .subdir = "linux-64", .sha256 = "c" ** 64 },
        .{ .mojo = "1.1.0", .subdir = "linux-64", .sha256 = "d" ** 64 },
    };
    const merged = try mergeMojos(a, &.{ for_11, for_10 }, &closures);
    try std.testing.expectEqual(@as(usize, 2), merged.mojos.len);
    try std.testing.expectEqualStrings("1.0.0", merged.mojos[0]);
    try std.testing.expectEqualStrings("1.1.0", merged.mojos[1]);
    try std.testing.expectEqual(@as(usize, 3), merged.packages.len);
    try std.testing.expectEqualStrings("app", merged.packages[0].name);
    try std.testing.expectEqual(@as(usize, 2), merged.packages[0].artifacts.len);
    try std.testing.expectEqualStrings("1.0.0", merged.packages[0].artifacts[0].mojo);
    try std.testing.expectEqualStrings("mojo1.1.0_0", merged.packages[0].artifacts[1].build);
    try std.testing.expectEqualStrings("1.2.0", merged.packages[1].version);
    try std.testing.expectEqual(@as(usize, 1), merged.packages[1].artifacts.len);
    try std.testing.expectEqualStrings("1.0.0", merged.packages[1].artifacts[0].mojo);
    try std.testing.expectEqualStrings("1.3.0", merged.packages[2].version);
    try std.testing.expectEqualStrings("1.1.0", merged.packages[2].artifacts[0].mojo);
    try std.testing.expectEqual(@as(?[]const u8, null), try lock.check(a, merged));

    // What is written reads back to the same bytes.
    const text = try lock.render(a, merged);
    var why: []const u8 = "";
    const back = try lock.parse(a, text, &why);
    try std.testing.expectEqualStrings(text, try lock.render(a, back));

    // A path dependency added after the merge keeps the Mojo versions and the closures.
    var diag: Diagnostic = .{};
    const with_path = try addPaths(a, merged, &.{.{ .name = "util", .version = "0.3.0", .path = "util" }}, &diag);
    try std.testing.expectEqual(@as(usize, 4), with_path.packages.len);
    try std.testing.expectEqual(@as(usize, 2), with_path.mojos.len);
    try std.testing.expectEqual(@as(usize, 2), with_path.closures.len);
}
