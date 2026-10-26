//! From a resolution to a lock, and the views of a lock that `mopm lock`,
//! `mopm update` and `mopm tree` print.
//!
//! `buildLock` makes one lock entry per file of every picked version (one per
//! subdir), taking `sha256` and `size` from the channel's
//! `<subdir>/repodata.json` (spec/channel.md). The sparse index must carry
//! the same values (spec/index.md, "files[].sha256 and size"); a difference,
//! or a file the repodata does not offer, is an error that names both sides.
//!
//! A version that ships native libraries also gets each library's own sha256 in
//! its lock entry, with the `kind`, `needs` and `exclusive` its `<name>.mopm.json`
//! declares (the index record names only the id and soname). Nothing else in the
//! channel holds such a hash, and the lock must (a unit graph takes only pinned
//! natives), so `buildLock` fetches the `.conda` of that subdir once, checks its
//! size and sha256 against the repodata first (a substituted file cannot pin a
//! wrong hash), reads `<name>.mopm.json` and the library files out of it, and
//! hashes each. A `.conda` the old lock already pinned (same name, version,
//! subdir and file sha256, every native hashed) is not fetched again: its natives
//! are copied from the old lock. `mopm sync --locked` never gets here.
//! Only `sha256`, `size` and `removed` are read from repodata.json: a lock
//! entry's `deps` come from the index record's `deps[]`, never from the
//! repodata's `depends`. The channel URL must be one a lock may hold
//! (lock.allowedChannel), or no lock is built.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const lock = @import("lock.zig");
const metadata = @import("metadata.zig");
const conda_unpack = @import("conda_unpack.zig");

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
/// repodata.json, or `error.ResolveFailed` with `diag` set;
/// `channel.fetchConda(arena, subdir, filename, diag)` returns the bytes of one
/// package file (asked only for a version that ships native libraries, and
/// not when `old` already pins that file's natives).
pub fn buildLock(arena: Allocator, res: resolve.Resolution, channel_url: []const u8, channel: anytype, old: ?lock.Lock, diag: *Diagnostic) Error!lock.Lock {
    if (!lock.allowedChannel(channel_url)) return bad(arena, diag, "channel {s} is refused: {s}", .{ channel_url, lock.channel_rule });
    var repodata = std.StringHashMap(Repodata).init(arena);
    var packages = std.ArrayList(lock.Package).init(arena);
    var window: ?[]u8 = null;
    for (res.packages) |p| {
        const rec = p.record;
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
            var natives: []const lock.Native = &.{};
            if (rec.native.len > 0) {
                if (reusable(old, rec, f)) |kept| {
                    natives = kept;
                } else {
                    if (window == null) window = try arena.alloc(u8, conda_unpack.window_size);
                    natives = try pinNatives(arena, rec, f, channel, window.?, diag);
                }
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
                .native = natives,
            });
        }
    }
    lock.sortPackages(packages.items);
    const channels = try arena.alloc([]const u8, 1);
    channels[0] = channel_url;
    return .{ .mojo = res.mojo, .channels = channels, .packages = packages.items };
}

/// The natives `old` pins for the very file `f` (name, version, subdir and sha256 of the file all the same), when
/// every one of them is hashed and they are the library `rec` names; else null.
fn reusable(old: ?lock.Lock, rec: *const resolve.Record, f: resolve.File) ?[]const lock.Native {
    const o = old orelse return null;
    for (o.packages) |q| {
        if (q.source != .registry or !std.mem.eql(u8, q.name, rec.name) or !std.mem.eql(u8, q.version, rec.version)) continue;
        if (!std.mem.eql(u8, q.subdir, f.subdir)) continue;
        var same_file = std.mem.eql(u8, q.sha256, f.sha256);
        for (q.artifacts) |a| same_file = same_file or std.mem.eql(u8, a.sha256, f.sha256);
        if (!same_file or q.native.len != rec.native.len) continue;
        var all = true;
        for (rec.native) |n| {
            var have = false;
            for (q.native) |m| {
                if (std.mem.eql(u8, m.id, n.id) and std.mem.eql(u8, m.soname, n.soname) and m.sha256 != null) have = true;
            }
            all = all and have;
        }
        if (all) return q.native;
    }
    return null;
}

/// Fetches the file `f` of `rec`, checks it is the bytes the repodata and the index agreed on, and returns its
/// natives with the sha256 of each library file.
fn pinNatives(arena: Allocator, rec: *const resolve.Record, f: resolve.File, channel: anytype, window: []u8, diag: *Diagnostic) Error![]const lock.Native {
    const bytes = try channel.fetchConda(arena, f.subdir, f.filename, diag);
    if (bytes.len != f.size) {
        return bad(arena, diag, "{s}/{s}: {d} bytes were served, and the index and repodata.json say {d}", .{ f.subdir, f.filename, bytes.len, f.size });
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got, f.sha256)) {
        return bad(arena, diag, "{s}/{s}: the file served has sha256 {s}, and the index and repodata.json say {s}", .{ f.subdir, f.filename, &got, f.sha256 });
    }

    var unpack_diag = conda_unpack.Diag{};
    const meta_path = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mopm.json", .{rec.name});
    const meta_files = conda_unpack.readFiles(arena, bytes, window, &.{meta_path}, &unpack_diag) catch |e| return unreadable(arena, diag, rec, f, e, unpack_diag);
    const meta_text = meta_files[0] orelse return bad(arena, diag, "{s}/{s} has no {s}", .{ f.subdir, f.filename, meta_path });
    const meta = metadata.parse(arena, meta_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bad(arena, diag, "{s}/{s}: {s} is not valid package metadata ({s})", .{ f.subdir, f.filename, meta_path, @errorName(e) }),
    };
    if (!std.mem.eql(u8, meta.name, rec.name)) {
        return bad(arena, diag, "{s}/{s}: {s} names the package {s}, not {s}", .{ f.subdir, f.filename, meta_path, meta.name, rec.name });
    }
    // The index record and the file must be about the same libraries.
    if (meta.native.len != rec.native.len) {
        return bad(arena, diag, "{s} {s}: the index lists {d} native libraries, and {s}/{s} declares {d}", .{ rec.name, rec.version, rec.native.len, f.subdir, f.filename, meta.native.len });
    }
    var paths = std.ArrayList([]const u8).init(arena);
    for (rec.native) |n| {
        const m = declared(meta, n) orelse {
            return bad(arena, diag, "{s} {s}: the index lists native library {s} ({s}), and {s}/{s} does not declare it", .{ rec.name, rec.version, n.id, n.soname, f.subdir, f.filename });
        };
        try paths.append(try libraryPath(arena, diag, rec, f, m));
    }

    const data = conda_unpack.readFiles(arena, bytes, window, paths.items, &unpack_diag) catch |e| return unreadable(arena, diag, rec, f, e, unpack_diag);
    var out = std.ArrayList(lock.Native).init(arena);
    for (rec.native, 0..) |n, i| {
        const m = declared(meta, n).?;
        const file = data[i] orelse {
            return bad(arena, diag, "{s}/{s} declares native library {s} ({s}) but holds no {s}", .{ f.subdir, f.filename, n.id, n.soname, paths.items[i] });
        };
        if (file.len == 0) return bad(arena, diag, "{s}/{s}: {s} is empty", .{ f.subdir, f.filename, paths.items[i] });
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file, &d, .{});
        try out.append(.{
            .id = n.id,
            .soname = n.soname,
            .sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(d, .lower)),
            .kind = m.kind,
            .needs = m.needs,
            .exclusive = m.exclusive,
        });
    }
    return out.items;
}

fn declared(meta: metadata.Metadata, n: resolve.Native) ?metadata.Native {
    for (meta.native) |m| {
        if (std.mem.eql(u8, m.id, n.id) and std.mem.eql(u8, m.soname, n.soname)) return m;
    }
    return null;
}

/// The path in the package of the file that carries `m`'s soname: the shared object (kind shared or both), else the
/// archive. The registry puts such files directly in `lib/`, named for the soname; a file that is not is not
/// pinned, since the lock's hash is the one `mopm sync` checks against `lib/<soname>`.
fn libraryPath(arena: Allocator, diag: *Diagnostic, rec: *const resolve.Record, f: resolve.File, m: metadata.Native) Error![]const u8 {
    const rel = if (m.kind == .static) m.static_file else m.file;
    const resolved = try fromLibMojo(arena, rel);
    const expected = try std.fmt.allocPrint(arena, "lib/{s}", .{m.soname});
    if (resolved == null or !std.mem.eql(u8, resolved.?, expected)) {
        return bad(arena, diag, "{s} {s}: native library {s} is '{s}' in {s}/{s}; mopm pins a native library by its soname, so the file must be lib/{s}", .{ rec.name, rec.version, m.id, rel, f.subdir, f.filename, m.soname });
    }
    return expected;
}

/// `rel`, a path in a package's metadata, resolved against `lib/mojo/` (`../libx.a` is `lib/libx.a`); null when it is
/// absolute or climbs out of the package.
fn fromLibMojo(arena: Allocator, rel: []const u8) Allocator.Error!?[]const u8 {
    if (rel.len == 0 or rel[0] == '/') return null;
    var parts = std.ArrayList([]const u8).init(arena);
    try parts.append("lib");
    try parts.append("mojo");
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(c);
    }
    return try std.mem.join(arena, "/", parts.items);
}

fn unreadable(arena: Allocator, diag: *Diagnostic, rec: *const resolve.Record, f: resolve.File, e: anyerror, d: conda_unpack.Diag) Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    const why = if (d.message.len > 0) d.message else @errorName(e);
    return bad(arena, diag, "{s} {s}: {s}/{s} cannot be read: {s}", .{ rec.name, rec.version, f.subdir, f.filename, why });
}

/// A version 2 lock holds one entry, and so one set of natives, per package version and subdir, whatever the number
/// of Mojo versions it is built for. The locks `per` (one per Mojo version, as `buildLock` made them) must therefore
/// agree on the natives of every version they share, or the entry would pin the first build's.
pub fn checkNativesAgree(arena: Allocator, per: []const lock.Lock, diag: *Diagnostic) Error!void {
    for (per, 0..) |l, i| {
        for (per[i + 1 ..]) |m| {
            for (l.packages) |p| {
                for (m.packages) |q| {
                    if (p.source != .registry or q.source != .registry) continue;
                    if (!std.mem.eql(u8, p.name, q.name) or !std.mem.eql(u8, p.version, q.version) or !std.mem.eql(u8, p.subdir, q.subdir)) continue;
                    if (sameNatives(p.native, q.native)) continue;
                    return bad(arena, diag, "{s} {s} ({s}) ships different native libraries in its builds for mojo {s} and mojo {s}; a lock holds one set per version", .{ p.name, p.version, p.subdir, l.mojo, m.mojo });
                }
            }
        }
    }
}

fn sameNatives(a: []const lock.Native, b: []const lock.Native) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.soname, y.soname) or x.kind != y.kind or !std.mem.eql(u8, x.exclusive, y.exclusive)) return false;
        if ((x.sha256 == null) != (y.sha256 == null)) return false;
        if (x.sha256) |h| {
            if (!std.mem.eql(u8, h, y.sha256.?)) return false;
        }
        if (x.needs.len != y.needs.len) return false;
        for (x.needs, y.needs) |u, v| {
            if (!std.mem.eql(u8, u, v)) return false;
        }
    }
    return true;
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

/// A channel held in memory: subdir -> repodata.json text, and `<subdir>/<filename>` -> the bytes of a package file.
const MemoryChannel = struct {
    files: []const resolve.Pair,
    conda: []const resolve.Pair = &.{},
    /// Counts the package files asked for, when set.
    fetches: ?*usize = null,

    pub fn fetch(self: MemoryChannel, arena: Allocator, subdir: []const u8, diag: *Diagnostic) Error![]const u8 {
        for (self.files) |f| {
            if (std.mem.eql(u8, f[0], subdir)) return f[1];
        }
        return resolve.fail(arena, diag, .bad_channel, "no {s}/repodata.json", .{subdir});
    }

    pub fn fetchConda(self: MemoryChannel, arena: Allocator, subdir: []const u8, filename: []const u8, diag: *Diagnostic) Error![]const u8 {
        if (self.fetches) |n| n.* += 1;
        const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ subdir, filename });
        for (self.conda) |f| {
            if (std.mem.eql(u8, f[0], key)) return f[1];
        }
        return resolve.fail(arena, diag, .bad_channel, "no {s}", .{key});
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

/// A lock that pins the natives of crypto (the only package of the diamond that ships any), for the two files of it:
/// the lock `mopm lock` made when crypto was first locked. Its digests are the diamond's fake ones, so the `.conda`
/// cannot be served; the natives come from here, which is how a second `mopm lock` finds them.
const diamond_pinned =
    \\{"lock_version": 1, "toolchain": {"mojo": "1.0.0"}, "channels": ["https://conda.mopm.dev/"], "packages": [
    \\  {"name": "crypto", "version": "2.0.1", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\   "url": "https://conda.mopm.dev/linux-64/mojo-crypto-2.0.1-mojo1.0.0_0.conda", "sha256": "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9", "size": 1000, "mojo": "1.0.0",
    \\   "native": [{"id": "crypto", "soname": "libcrypto_native.so.1", "sha256": "1111111111111111111111111111111111111111111111111111111111111111"}]},
    \\  {"name": "crypto", "version": "2.0.1", "build": "mojo1.0.0_0", "subdir": "osx-arm64", "channel": "https://conda.mopm.dev/",
    \\   "url": "https://conda.mopm.dev/osx-arm64/mojo-crypto-2.0.1-mojo1.0.0_0.conda", "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "size": 1000, "mojo": "1.0.0",
    \\   "native": [{"id": "crypto", "soname": "libcrypto_native.so.1", "sha256": "2222222222222222222222222222222222222222222222222222222222222222"}]}
    \\]}
;

fn diamondLockAt(a: Allocator, channel_url: []const u8, channel: anytype, diag: *Diagnostic) Error!lock.Lock {
    const res = try resolve.resolve(a, diamond_index, .{ .mojo = "1.0.0", .roots = &diamond_roots }, diag);
    var why: []const u8 = "";
    const old = lock.parse(a, diamond_pinned, &why) catch return error.ResolveFailed;
    return buildLock(a, res, channel_url, channel, old, diag);
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

// ------------------------------------------------- natives: what `mopm lock` pins

const conda = @import("conda.zig");
const fx = @import("conda_fixture.zig");

fn hexOf(a: Allocator, bytes: []const u8) ![]const u8 {
    return fx.sha256Hex(a, bytes);
}

const ar = conda.ar_magic;

/// Two packages that ship a static archive each, as `mopm pack` makes them: crypto_sys (for linux-64 and osx-arm64,
/// two different archives) and tls_sys, which needs crypto_sys's archive. The index and repodata lines say what the
/// registry would; the channel serves the `.conda` bytes.
const World = struct {
    index: MemoryIndex,
    channel: MemoryChannel,
    crypto_linux_archive: []const u8,
    crypto_osx_archive: []const u8,
    tls_archive: []const u8,
    crypto_linux: conda.Packed,
    tls: conda.Packed,
};

const FileLine = struct { subdir: []const u8, p: conda.Packed };

fn recLine(a: Allocator, name: []const u8, version: []const u8, deps: []const u8, native: []const u8, files: []const FileLine) ![]const u8 {
    var fl = std.ArrayList(u8).init(a);
    for (files, 0..) |f, i| {
        if (i > 0) try fl.append(',');
        try fl.writer().print("{{\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d},\"subdir\":\"{s}\"}}", .{ f.p.file_name, &f.p.sha256, f.p.bytes.len, f.subdir });
    }
    return std.fmt.allocPrint(a, "{{\"build\":\"mojo1.0.0_0\",\"deps\":[{s}],\"files\":[{s}],\"manifest_sha256\":\"{s}\",\"name\":\"{s}\",\"native\":[{s}],\"published_at\":\"2026-10-13T12:00:00Z\",\"requires_mojo\":\"==1.0.0\",\"state\":\"published\",\"v\":1,\"version\":\"{s}\"}}\n", .{ deps, fl.items, digests[0], name, native, version });
}

fn repoEntry(a: Allocator, name: []const u8, version: []const u8, subdir: []const u8, p: conda.Packed) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{s}\":{{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-{s}\",\"sha256\":\"{s}\",\"size\":{d},\"subdir\":\"{s}\",\"version\":\"{s}\"}}", .{ p.file_name, name, &p.sha256, p.bytes.len, subdir, version });
}

fn repoJson(a: Allocator, subdir: []const u8, entries: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"info\":{{\"subdir\":\"{s}\"}},\"packages\":{{}},\"packages.conda\":{{{s}}},\"removed\":[]}}\n", .{ subdir, try std.mem.join(a, ",", entries) });
}

fn world(a: Allocator) !World {
    const crypto_linux_archive = ar ++ "crypto-linux-members\n";
    const crypto_osx_archive = ar ++ "crypto-osx-members\n";
    const tls_archive = ar ++ "tls-members\n";
    const crypto_native = [_]conda.Native{.{ .id = "crypto_sys", .soname = "libcrypto_sys.a", .exclusive = "libcrypto", .archive = crypto_linux_archive }};
    const crypto_osx_native = [_]conda.Native{.{ .id = "crypto_sys", .soname = "libcrypto_sys.a", .exclusive = "libcrypto", .archive = crypto_osx_archive }};
    const tls_native = [_]conda.Native{.{ .id = "tls_sys", .soname = "libtls_sys.a", .needs = &.{"libcrypto_sys.a"}, .archive = tls_archive }};
    const cl = try conda.pack(a, .{ .name = "crypto_sys", .version = "1.39.0", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "MOJOC", .natives = &crypto_native });
    const co = try conda.pack(a, .{ .name = "crypto_sys", .version = "1.39.0", .compiler = "1.0.0", .subdir = "osx-arm64", .mojoc = "MOJOC", .natives = &crypto_osx_native });
    const tl = try conda.pack(a, .{
        .name = "tls_sys",
        .version = "2.4.0",
        .compiler = "1.0.0",
        .subdir = "linux-64",
        .deps = &.{.{ .name = "crypto_sys", .range = ">=1.39,<2" }},
        .mojoc = "MOJOC",
        .natives = &tls_native,
    });
    const crypto_rec = try recLine(a, "crypto_sys", "1.39.0", "", "{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\"}", &.{ .{ .subdir = "linux-64", .p = cl }, .{ .subdir = "osx-arm64", .p = co } });
    const tls_rec = try recLine(a, "tls_sys", "2.4.0", "{\"name\":\"crypto_sys\",\"range\":\"1.39\"}", "{\"id\":\"tls_sys\",\"soname\":\"libtls_sys.a\"}", &.{.{ .subdir = "linux-64", .p = tl }});
    const index_files = try a.dupe(resolve.Pair, &.{ .{ "crypto_sys", crypto_rec }, .{ "tls_sys", tls_rec } });
    const repo_files = try a.dupe(resolve.Pair, &.{
        .{ "linux-64", try repoJson(a, "linux-64", &.{ try repoEntry(a, "crypto_sys", "1.39.0", "linux-64", cl), try repoEntry(a, "tls_sys", "2.4.0", "linux-64", tl) }) },
        .{ "osx-arm64", try repoJson(a, "osx-arm64", &.{try repoEntry(a, "crypto_sys", "1.39.0", "osx-arm64", co)}) },
    });
    const conda_files = try a.dupe(resolve.Pair, &.{
        .{ try std.fmt.allocPrint(a, "linux-64/{s}", .{cl.file_name}), cl.bytes },
        .{ try std.fmt.allocPrint(a, "osx-arm64/{s}", .{co.file_name}), co.bytes },
        .{ try std.fmt.allocPrint(a, "linux-64/{s}", .{tl.file_name}), tl.bytes },
    });
    return .{
        .index = .{ .files = index_files },
        .channel = .{ .files = repo_files, .conda = conda_files },
        .crypto_linux_archive = crypto_linux_archive,
        .crypto_osx_archive = crypto_osx_archive,
        .tls_archive = tls_archive,
        .crypto_linux = cl,
        .tls = tl,
    };
}

const world_roots = [_]resolve.Root{.{ .name = "tls_sys", .requirement = "2" }};

fn worldLock(a: Allocator, w: World, old: ?lock.Lock, diag: *Diagnostic) Error!lock.Lock {
    const res = try resolve.resolve(a, w.index, .{ .mojo = "1.0.0", .roots = &world_roots }, diag);
    return buildLock(a, res, "https://conda.mopm.dev/", w.channel, old, diag);
}

fn nativeOf(l: lock.Lock, name: []const u8, subdir: []const u8) ?lock.Native {
    for (l.packages) |p| {
        if (std.mem.eql(u8, p.name, name) and std.mem.eql(u8, p.subdir, subdir) and p.native.len > 0) return p.native[0];
    }
    return null;
}

// Defects it catches: a lock that records no hash of a native library (a unit graph then refuses the project); the
// hash of the whole `.conda`, or of the metadata, in place of the library's; the hash of one platform's library for
// another's; `kind`, `needs` or `exclusive` dropped or taken from the wrong library. Defect caught: the hash taken
// over `bytes`; over the osx entry's archive for linux; `.kind = .shared`; `.needs = &.{}`.
test "mopm lock pins each native library: the sha256 of the library file, per subdir, with its kind, needs and group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const w = try world(a);
    var diag: Diagnostic = .{};
    const l = worldLock(a, w, null, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    const crypto = nativeOf(l, "crypto_sys", "linux-64").?;
    try std.testing.expectEqualStrings(try hexOf(a, w.crypto_linux_archive), crypto.sha256.?);
    try std.testing.expect(!std.mem.eql(u8, &w.crypto_linux.sha256, crypto.sha256.?)); // not the whole .conda
    try std.testing.expectEqual(metadata.Kind.static, crypto.kind);
    try std.testing.expectEqualStrings("libcrypto", crypto.exclusive);
    try std.testing.expectEqual(@as(usize, 0), crypto.needs.len);
    // The other platform has its own archive, so its own hash.
    const osx = nativeOf(l, "crypto_sys", "osx-arm64").?;
    try std.testing.expectEqualStrings(try hexOf(a, w.crypto_osx_archive), osx.sha256.?);
    try std.testing.expect(!std.mem.eql(u8, osx.sha256.?, crypto.sha256.?));
    const tls = nativeOf(l, "tls_sys", "linux-64").?;
    try std.testing.expectEqualStrings(try hexOf(a, w.tls_archive), tls.sha256.?);
    try std.testing.expectEqual(metadata.Kind.static, tls.kind);
    try std.testing.expectEqual(@as(usize, 1), tls.needs.len);
    try std.testing.expectEqualStrings("libcrypto_sys.a", tls.needs[0]);
    try std.testing.expectEqualStrings("", tls.exclusive);

    // What is written reads back, under every rule of spec/lock.md.
    const text = try lock.render(a, l);
    var why: []const u8 = "";
    const again = lock.parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqualStrings(text, try lock.render(a, again));
}

// Defects it catches: a downloaded file believed without checking that it is the file the repodata and index agreed
// on (a mirror or a man in the middle then chooses the hash that is pinned); a wrong size accepted. Defect caught:
// pinNatives drops the size check; drops the sha256 check.
test "a package file that is not the one the index and repodata name pins nothing: the lock is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w = try world(a);
    const key = try std.fmt.allocPrint(a, "linux-64/{s}", .{w.crypto_linux.file_name});

    // Other bytes of another size.
    const longer = try std.mem.concat(a, u8, &.{ w.crypto_linux.bytes, "x" });
    w.channel.conda = &.{.{ key, longer }};
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, worldLock(a, w, null, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "bytes were served, and the index and repodata.json say") != null);

    // The same size, one byte different: the digest is what refuses it.
    const flipped = try a.dupe(u8, w.crypto_linux.bytes);
    flipped[flipped.len / 2] ^= 1;
    w.channel.conda = &.{.{ key, flipped }};
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, worldLock(a, w, null, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "the file served has sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, &w.crypto_linux.sha256) != null);

    // A package file the channel does not serve at all.
    w.channel.conda = &.{};
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, worldLock(a, w, null, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, key) != null);
}

/// A `.conda` made by hand (not by `mopm pack`) for crypto_sys in linux-64, with `files` as its package files; the
/// world's index and repodata lines for it, so that it is the file the registry would have served.
fn handmade(a: Allocator, files: []const fx.Item) !World {
    var w = try world(a);
    const stem = "mojo-crypto_sys-1.39.0-mojo1.0.0_0";
    const bytes = try fx.simple(a, "crypto_sys", "1.39.0", files);
    var p = w.crypto_linux;
    p.bytes = bytes;
    p.sha256 = (try hexOf(a, bytes))[0..64].*;
    const rec = try recLine(a, "crypto_sys", "1.39.0", "", "{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\"}", &.{.{ .subdir = "linux-64", .p = p }});
    const idx = try a.dupe(resolve.Pair, &.{ .{ "crypto_sys", rec }, w.index.files[1] });
    w.index = .{ .files = idx };
    const tl = try repoEntry(a, "tls_sys", "2.4.0", "linux-64", w.tls);
    w.channel.files = try a.dupe(resolve.Pair, &.{
        .{ "linux-64", try repoJson(a, "linux-64", &.{ try repoEntry(a, "crypto_sys", "1.39.0", "linux-64", p), tl }) },
    });
    w.channel.conda = try a.dupe(resolve.Pair, &.{
        .{ try std.fmt.allocPrint(a, "linux-64/{s}.conda", .{stem}), bytes },
    });
    // tls_sys is not built: only crypto_sys is asked for.
    return w;
}

const good_meta =
    \\{"schema":1,"name":"crypto_sys","version":"1.39.0","native":[{"id":"crypto_sys","soname":"libcrypto_sys.a","kind":"static","static_file":"../libcrypto_sys.a"}]}
;

fn cryptoLock(w: World, a: Allocator, diag: *Diagnostic) Error!lock.Lock {
    const res = try resolve.resolve(a, w.index, .{ .mojo = "1.0.0", .roots = &.{.{ .name = "crypto_sys", .requirement = "1" }} }, diag);
    return buildLock(a, res, "https://conda.mopm.dev/", w.channel, null, diag);
}

// Defects it catches: a package whose own metadata disagrees with the index (a library the index lists that the file
// does not declare, one it does not hold, or one it keeps somewhere the registry would not allow, or under another
// name than its soname) pinned with a hash of something else, or of nothing. Defect caught: the declared() check
// dropped; the file-name check in libraryPath dropped; the missing-file check dropped.
test "a package whose metadata and files do not match what the index says is refused, saying what" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};

    // The control: the same shape, correct, locks.
    const ok = try handmade(a, &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = good_meta }, .{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" } });
    const l = cryptoLock(ok, a, &diag) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @tagName(diag.kind), diag.message });
        return e;
    };
    try std.testing.expectEqualStrings(try hexOf(a, ar ++ "x"), nativeOf(l, "crypto_sys", "linux-64").?.sha256.?);

    const Case = struct { files: []const fx.Item, want: []const u8 };
    const cases = [_]Case{
        // no metadata at all
        .{ .files = &.{.{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" }}, .want = "has no lib/mojo/crypto_sys.mopm.json" },
        // metadata that is not JSON
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{" }, .{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" } }, .want = "is not valid package metadata" },
        // metadata of another package
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"other\",\"native\":[{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\",\"kind\":\"static\",\"static_file\":\"../libcrypto_sys.a\"}]}" }, .{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" } }, .want = "names the package other, not crypto_sys" },
        // the index lists a library the file does not declare
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"crypto_sys\",\"native\":[{\"id\":\"crypto_sys\",\"soname\":\"libother.a\",\"kind\":\"static\",\"static_file\":\"../libother.a\"}]}" }, .{ .name = "lib/libother.a", .data = ar ++ "x" } }, .want = "does not declare it" },
        // the file declares none
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"crypto_sys\"}" }, .{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" } }, .want = "declares 0" },
        // the declared archive is not in the package
        .{ .files = &.{.{ .name = "lib/mojo/crypto_sys.mopm.json", .data = good_meta }}, .want = "holds no lib/libcrypto_sys.a" },
        // the declared archive is empty
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = good_meta }, .{ .name = "lib/libcrypto_sys.a", .data = "" } }, .want = "is empty" },
        // the archive is not named for its soname
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"crypto_sys\",\"native\":[{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\",\"kind\":\"static\",\"static_file\":\"../libelsewhere.a\"}]}" }, .{ .name = "lib/libelsewhere.a", .data = ar ++ "x" } }, .want = "the file must be lib/libcrypto_sys.a" },
        // the archive is not directly under lib/
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"crypto_sys\",\"native\":[{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\",\"kind\":\"static\",\"static_file\":\"sub/libcrypto_sys.a\"}]}" }, .{ .name = "lib/mojo/sub/libcrypto_sys.a", .data = ar ++ "x" } }, .want = "the file must be lib/libcrypto_sys.a" },
        // the archive climbs out of the package
        .{ .files = &.{ .{ .name = "lib/mojo/crypto_sys.mopm.json", .data = "{\"schema\":1,\"name\":\"crypto_sys\",\"native\":[{\"id\":\"crypto_sys\",\"soname\":\"libcrypto_sys.a\",\"kind\":\"static\",\"static_file\":\"../../../libcrypto_sys.a\"}]}" }, .{ .name = "lib/libcrypto_sys.a", .data = ar ++ "x" } }, .want = "the file must be lib/libcrypto_sys.a" },
    };
    for (cases) |c| {
        const w = try handmade(a, c.files);
        diag = .{};
        if (cryptoLock(w, a, &diag)) |_| {
            std.debug.print("locked, want a refusal containing: {s}\n", .{c.want});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.ResolveFailed) return e;
        std.testing.expect(std.mem.indexOf(u8, diag.message, c.want) != null) catch |e| {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ diag.message, c.want });
            return e;
        };
    }
}

// Defects it catches: `mopm lock` and `mopm update` fetching every native `.conda` again each time (slow, and a
// channel that is briefly down breaks a lock that needs nothing from it); the other way, a pin kept for a file that
// is no longer the one pinned. Defect caught: reusable() ignores the file sha256; ignores a missing native sha256.
test "a .conda the old lock already pins is not fetched again; a different file, or a pin without a hash, is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w = try world(a);
    var fetches: usize = 0;
    w.channel.fetches = &fetches;
    var diag: Diagnostic = .{};
    const first = try worldLock(a, w, null, &diag);
    try std.testing.expectEqual(@as(usize, 3), fetches); // crypto_sys linux-64 and osx-arm64, tls_sys linux-64

    // The same files again: nothing is fetched and the lock is the same bytes.
    fetches = 0;
    const second = try worldLock(a, w, first, &diag);
    try std.testing.expectEqual(@as(usize, 0), fetches);
    try std.testing.expectEqualStrings(try lock.render(a, first), try lock.render(a, second));

    // An old lock for another file of the same version (its sha256 is not the file's): fetched, and the new hash wins.
    const other = try a.dupe(lock.Package, first.packages);
    for (other) |*p| {
        if (std.mem.eql(u8, p.name, "crypto_sys") and std.mem.eql(u8, p.subdir, "linux-64")) {
            p.sha256 = "3" ** 64;
            p.native = &.{.{ .id = "crypto_sys", .soname = "libcrypto_sys.a", .sha256 = "4" ** 64, .kind = .static }};
        }
    }
    var old_other = first;
    old_other.packages = other;
    fetches = 0;
    const third = try worldLock(a, w, old_other, &diag);
    try std.testing.expectEqual(@as(usize, 1), fetches);
    try std.testing.expectEqualStrings(try hexOf(a, w.crypto_linux_archive), nativeOf(third, "crypto_sys", "linux-64").?.sha256.?);

    // An old lock that has the file but no hash for its native (written before hashes were): fetched.
    const bare = try a.dupe(lock.Package, first.packages);
    for (bare) |*p| {
        if (p.native.len > 0) p.native = try a.dupe(lock.Native, &.{.{ .id = p.native[0].id, .soname = p.native[0].soname }});
    }
    var old_bare = first;
    old_bare.packages = bare;
    fetches = 0;
    _ = try worldLock(a, w, old_bare, &diag);
    try std.testing.expectEqual(@as(usize, 3), fetches);
}

test "a package without natives is never fetched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fetches: usize = 0;
    var ch = diamond_channel;
    ch.fetches = &fetches;
    var diag: Diagnostic = .{};
    // The diamond's only package with a native is crypto, whose pins the old lock holds; the rest ship none.
    _ = try diamondLock(a, ch, &diag);
    try std.testing.expectEqual(@as(usize, 0), fetches);
}

// Defect it catches: a version 2 lock that keeps the natives of the first Mojo version's build and says nothing when
// the build for another Mojo version ships a different archive. Defect caught: checkNativesAgree returns at once.
test "builds for two Mojo versions that ship different natives are refused before they are merged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const w = try world(a);
    var diag: Diagnostic = .{};
    const one = try worldLock(a, w, null, &diag);
    var two = one;
    two.mojo = "1.1.0";
    try checkNativesAgree(a, &.{ one, two }, &diag);

    var packages = try a.dupe(lock.Package, one.packages);
    for (packages) |*p| {
        if (std.mem.eql(u8, p.name, "tls_sys")) p.native = &.{.{ .id = "tls_sys", .soname = "libtls_sys.a", .sha256 = "5" ** 64, .kind = .static, .needs = &.{"libcrypto_sys.a"} }};
    }
    two.packages = packages;
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, checkNativesAgree(a, &.{ one, two }, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "tls_sys 2.4.0 (linux-64) ships different native libraries in its builds for mojo 1.0.0 and mojo 1.1.0") != null);

    // The needs and the group count as well.
    packages = try a.dupe(lock.Package, one.packages);
    for (packages) |*p| {
        if (std.mem.eql(u8, p.name, "crypto_sys") and p.native.len > 0) {
            var n = p.native[0];
            n.exclusive = "other";
            p.native = try a.dupe(lock.Native, &.{n});
        }
    }
    two.packages = packages;
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, checkNativesAgree(a, &.{ one, two }, &diag));
}

// Defect it catches: a repodata size that differs from the index's accepted when the sha256 agrees (the size is what
// `mopm sync` and the lock hold the download to). Defect caught: the size half of the comparison dropped.
test "a repodata size that differs from the index's, with the same sha256, is refused, naming both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const linux_text = diamond_channel.files[0][1];
    const resized = try std.mem.replaceOwned(u8, a, linux_text, "\"sha256\":\"" ++ digests[0] ++ "\",\"size\":1000", "\"sha256\":\"" ++ digests[0] ++ "\",\"size\":1001");
    try std.testing.expect(!std.mem.eql(u8, linux_text, resized));
    const ch = MemoryChannel{ .files = &.{ .{ "linux-64", resized }, diamond_channel.files[1] } };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ResolveFailed, diamondLock(a, ch, &diag));
    try std.testing.expectEqual(resolve.Kind.bad_channel, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "the index says sha256 " ++ digests[0] ++ ", size 1000; linux-64/repodata.json says sha256 " ++ digests[0] ++ ", size 1001") != null);
}

// Defect it catches: a pin kept for a library the index now names differently, with the very same file bytes: the lock
// would keep the stale soname. Defect caught: reusable() stops comparing sonames.
test "an old pin is not reused when the index names the library differently, even for the same file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w = try world(a);
    var diag: Diagnostic = .{};
    const first = try worldLock(a, w, null, &diag);
    // The same files, the same hashes; only the index's soname for crypto_sys is another.
    const renamed = try std.mem.replaceOwned(u8, a, w.index.files[0][1], "\"soname\":\"libcrypto_sys.a\"", "\"soname\":\"libcrypto_other.a\"");
    try std.testing.expect(!std.mem.eql(u8, renamed, w.index.files[0][1]));
    w.index = .{ .files = try a.dupe(resolve.Pair, &.{ .{ "crypto_sys", renamed }, w.index.files[1] }) };
    diag = .{};
    try std.testing.expectError(error.ResolveFailed, worldLock(a, w, first, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "does not declare it") != null);
}
