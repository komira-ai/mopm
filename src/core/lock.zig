//! mopm.lock (spec/lock.md, spec/lock.schema.json): reading, checking and
//! writing.
//!
//! `parse` refuses a lock that breaks the schema's required fields or any of
//! the rules spec/lock.md lists under "Rules the schema cannot express": the
//! CLI checks them on every read. `write` prints one fixed layout (two-space
//! indent, the key order of the spec's example, `deps` and `native` left out
//! when empty, a final newline), so the same lock always gives the same bytes.
//!
//! A channel URL (`channels[]` and each `channel`) ends with `/` and may
//! carry a path. Its scheme is https, or plain http only to a loopback host
//! with a port (127.0.0.1, [::1], localhost): the rule `--registry` and
//! config.json follow (registry.allowedUrl). `check` refuses any other
//! channel, so a lock with one is neither read nor written.
//!
//! A path dependency (`name = { path = "..." }` in mopm.toml, at any depth)
//! is locked as one entry with `"source": "path"`: its `name`, the `version`
//! its own mopm.toml gives, its `path` relative to the project, and `deps`.
//! It has no build, subdir, channel, url, sha256, size or mojo: there is no
//! file to pin, and `mopm sync` never downloads it. A name locked as a path
//! dependency has no other entry. A registry entry carries no `source` key.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");
const metadata = @import("metadata.zig");

/// The `lock_version` of a lock for one Mojo version (the `[toolchain]` form).
pub const lock_version: i64 = 1;

/// The `lock_version` of a lock with one artifact per locked Mojo version
/// (spec/lock.md, "Version 2"): written when `Lock.mojos` is not empty.
pub const lock_version_2: i64 = 2;

/// One `.mojoc` build of a package version, for one Mojo version.
pub const Artifact = struct {
    mojo: []const u8,
    build: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
};

/// The closure hash of mopm's pinned toolchain for a Mojo version and subdir
/// (`mopm plan --unit-graph` prints the same value; version 2 locks only).
pub const Closure = struct {
    mojo: []const u8,
    subdir: []const u8,
    sha256: []const u8,
};

/// A native library a package ships. `sha256` is the hash of the library file that carries `soname`
/// (`mopm lock` fetches the package and hashes it); `kind`, `needs` and `exclusive` are the package's own
/// declarations in its `<name>.mopm.json` (spec/package-metadata.schema.json), copied so that a unit graph
/// can be made from the lock alone.
pub const Native = struct {
    id: []const u8,
    soname: []const u8,
    sha256: ?[]const u8 = null,
    kind: metadata.Kind = .shared,
    /// Sonames of other packages' native libraries this one needs.
    needs: []const []const u8 = &.{},
    /// An exclusivity group, or "".
    exclusive: []const u8 = "",
};

/// Where a locked package comes from.
pub const Source = enum { registry, path };

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    source: Source = .registry,
    /// For a path dependency: its directory, relative to the project.
    path: []const u8 = "",
    // A registry entry's file; empty for a path dependency.
    build: []const u8 = "",
    subdir: []const u8 = "",
    channel: []const u8 = "",
    url: []const u8 = "",
    sha256: []const u8 = "",
    size: u64 = 0,
    mojo: []const u8 = "",
    /// Version 2: the builds, one per Mojo version, sorted by `mojo`. Then
    /// `build`, `url`, `sha256`, `size` and `mojo` above are empty; `forMojo`
    /// fills them for one Mojo version.
    artifacts: []const Artifact = &.{},
    deps: []const []const u8 = &.{},
    native: []const Native = &.{},
};

pub const Lock = struct {
    /// Version 1: the one Mojo version. Version 2: the first of `mojos`
    /// (what `mopm sync` installs).
    mojo: []const u8,
    channels: []const []const u8,
    packages: []const Package,
    /// Version 2: the Mojo versions locked, sorted, no repeats. Empty for a
    /// version 1 lock.
    mojos: []const []const u8 = &.{},
    /// Version 2: mopm's toolchain closure hash per (mojo, subdir), sorted.
    closures: []const Closure = &.{},

    /// The version locked for `name`, or null.
    pub fn versionOf(self: Lock, name: []const u8) ?[]const u8 {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.version;
        }
        return null;
    }
};

/// The build of `p` for `mojo`, or null (a path dependency has none).
pub fn artifactFor(p: Package, mojo: []const u8) ?Artifact {
    if (p.source == .path) return null;
    if (p.artifacts.len > 0) {
        for (p.artifacts) |a| {
            if (std.mem.eql(u8, a.mojo, mojo)) return a;
        }
        return null;
    }
    if (!std.mem.eql(u8, p.mojo, mojo)) return null;
    return .{ .mojo = p.mojo, .build = p.build, .url = p.url, .sha256 = p.sha256, .size = p.size };
}

/// The Mojo versions `p` has a build for, sorted.
pub fn publishedFor(arena: Allocator, p: Package) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    if (p.artifacts.len > 0) {
        for (p.artifacts) |a| try out.append(a.mojo);
    } else if (p.source == .registry and p.mojo.len > 0) {
        try out.append(p.mojo);
    }
    return out.items;
}

/// The refusal for a dependency that has no `.mojoc` for the consumer's Mojo
/// (spec/unit-graph.md, "Choosing the Mojo version"). `published` is never empty.
pub fn noMojocMessage(arena: Allocator, name: []const u8, version: []const u8, mojo: []const u8, published: []const []const u8) Allocator.Error![]const u8 {
    const list = try std.mem.join(arena, ", ", published);
    const first = if (published.len > 0) published[0] else "?";
    return std.fmt.allocPrint(arena, "{s} {s} has no .mojoc for Mojo {s} (published for: {s}). Build with mojo {s}, ask the publisher for a {s} build, or pin a version that has one.", .{ name, version, mojo, list, first, mojo });
}

/// `l` seen for one Mojo version: a version 1 lock as it is; a version 2 lock
/// as a lock of the packages that have a build for `mojo`, each with its
/// `build`, `url`, `sha256`, `size` and `mojo` filled in (the shape
/// `mopm sync` and the install code read).
pub fn forMojo(arena: Allocator, l: Lock, mojo: []const u8) Allocator.Error!Lock {
    if (l.mojos.len == 0) return l;
    var out = std.ArrayList(Package).init(arena);
    for (l.packages) |p| {
        if (p.source == .path) {
            try out.append(p);
            continue;
        }
        const a = artifactFor(p, mojo) orelse continue;
        var q = p;
        q.artifacts = &.{};
        q.build = a.build;
        q.url = a.url;
        q.sha256 = a.sha256;
        q.size = a.size;
        q.mojo = a.mojo;
        try out.append(q);
    }
    return .{ .mojo = mojo, .channels = l.channels, .packages = out.items };
}

/// `<channel><subdir>/mojo-<name>-<version>-<build>.conda` (rule 3).
pub fn fileUrl(arena: Allocator, channel: []const u8, subdir: []const u8, name: []const u8, version: []const u8, build: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}/mojo-{s}-{s}-{s}.conda", .{ channel, subdir, name, version, build });
}

fn order(a: Package, b: Package) std.math.Order {
    const n = std.mem.order(u8, a.name, b.name);
    if (n != .eq) return n;
    const v = std.mem.order(u8, a.version, b.version);
    if (v != .eq) return v;
    return std.mem.order(u8, a.subdir, b.subdir);
}

fn lessThan(_: void, a: Package, b: Package) bool {
    return order(a, b) == .lt;
}

/// Sorts by name, then version, then subdir, each as a byte string (rule 1).
pub fn sortPackages(packages: []Package) void {
    std.mem.sort(Package, packages, {}, lessThan);
}

/// Whether `url` may be a lock channel (see the file comment).
pub fn allowedChannel(url: []const u8) bool {
    return std.mem.endsWith(u8, url, "/") and registry.allowedUrl(url);
}

/// Why `url` is not a lock channel, for messages.
pub const channel_rule = "a channel ends with '/' and is https, or plain http only to 127.0.0.1, [::1] or localhost with a port";

/// The first rule of spec/lock.md that `l` breaks, worded, or null.
pub fn check(arena: Allocator, l: Lock) Allocator.Error!?[]const u8 {
    for (l.mojos, 0..) |m, i| {
        if (i > 0 and std.mem.order(u8, l.mojos[i - 1], m) != .lt) {
            return try std.fmt.allocPrint(arena, "mojo is not sorted with no repeats (at {s})", .{m});
        }
    }
    for (l.closures) |c| {
        if (!contains(l.mojos, c.mojo)) return try std.fmt.allocPrint(arena, "toolchain names mojo {s}, which the lock does not list in mojo", .{c.mojo});
    }
    for (l.mojos) |m| {
        var have = false;
        for (l.closures) |c| have = have or std.mem.eql(u8, c.mojo, m);
        if (!have) return try std.fmt.allocPrint(arena, "toolchain has no closure for mojo {s}", .{m});
    }
    for (l.channels) |c| {
        if (!allowedChannel(c)) return try std.fmt.allocPrint(arena, "channel {s} is refused: {s}", .{ c, channel_rule });
    }
    for (l.packages, 0..) |p, i| {
        if (i > 0 and order(l.packages[i - 1], p) != .lt) {
            return try std.fmt.allocPrint(arena, "packages are not sorted by name, version and subdir with no repeats (at {s} {s} {s})", .{ p.name, p.version, p.subdir });
        }
        if (i > 0 and std.mem.eql(u8, l.packages[i - 1].name, p.name) and (l.packages[i - 1].source == .path or p.source == .path)) {
            return try std.fmt.allocPrint(arena, "{s} is locked as a path dependency and has another entry", .{p.name});
        }
        if (p.source == .path) {
            if (p.path.len == 0) return try std.fmt.allocPrint(arena, "{s}: a path dependency with an empty path", .{p.name});
        } else {
            var listed = false;
            for (l.channels) |c| listed = listed or std.mem.eql(u8, c, p.channel);
            if (!listed) return try std.fmt.allocPrint(arena, "{s}: channel {s} is not in channels", .{ p.name, p.channel });
            if (l.mojos.len > 0) {
                if (p.artifacts.len == 0) return try std.fmt.allocPrint(arena, "{s} {s}: no artifacts", .{ p.name, p.version });
                for (p.artifacts, 0..) |a, k| {
                    if (k > 0 and std.mem.order(u8, p.artifacts[k - 1].mojo, a.mojo) != .lt) {
                        return try std.fmt.allocPrint(arena, "{s}: artifacts are not sorted by mojo with no repeats (at {s})", .{ p.name, a.mojo });
                    }
                    if (!contains(l.mojos, a.mojo)) {
                        return try std.fmt.allocPrint(arena, "{s}: an artifact for mojo {s}, which the lock does not list in mojo", .{ p.name, a.mojo });
                    }
                    const want_url = try fileUrl(arena, p.channel, p.subdir, p.name, p.version, a.build);
                    if (!std.mem.eql(u8, want_url, a.url)) return try std.fmt.allocPrint(arena, "{s}: url is {s}, not {s}", .{ p.name, a.url, want_url });
                }
            } else {
                const want = try fileUrl(arena, p.channel, p.subdir, p.name, p.version, p.build);
                if (!std.mem.eql(u8, want, p.url)) return try std.fmt.allocPrint(arena, "{s}: url is {s}, not {s}", .{ p.name, p.url, want });
                if (!std.mem.eql(u8, p.mojo, l.mojo)) {
                    return try std.fmt.allocPrint(arena, "{s}: built with mojo {s}, but the toolchain is mojo {s}", .{ p.name, p.mojo, l.mojo });
                }
            }
        }
        for (p.deps) |d| {
            var found = false;
            for (l.packages) |q| found = found or std.mem.eql(u8, q.name, d);
            if (!found) return try std.fmt.allocPrint(arena, "{s}: dependency {s} is not in packages", .{ p.name, d });
        }
        for (p.native) |n| {
            for (n.needs) |need| {
                if (std.mem.eql(u8, need, n.soname)) return try std.fmt.allocPrint(arena, "{s}: native library {s} needs itself ({s})", .{ p.name, n.id, need });
            }
        }
        for (l.packages[0..i]) |q| {
            if (std.mem.eql(u8, q.name, p.name) and !std.mem.eql(u8, q.channel, p.channel)) {
                return try std.fmt.allocPrint(arena, "{s} comes from two channels, {s} and {s}", .{ p.name, q.channel, p.channel });
            }
            if (std.mem.eql(u8, q.name, p.name)) continue;
            for (p.native) |n| {
                for (q.native) |m| {
                    if (std.mem.eql(u8, n.soname, m.soname)) {
                        return try std.fmt.allocPrint(arena, "soname {s} is shipped by both {s} and {s}", .{ n.soname, q.name, p.name });
                    }
                }
            }
        }
    }
    return null;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

pub const ParseError = error{ Invalid, OutOfMemory };

const Reader = struct {
    arena: Allocator,
    why: *[]const u8,

    fn bad(r: Reader, comptime fmt: []const u8, args: anytype) ParseError {
        r.why.* = std.fmt.allocPrint(r.arena, fmt, args) catch return error.OutOfMemory;
        return error.Invalid;
    }

    fn object(r: Reader, v: std.json.Value, what: []const u8) ParseError!std.json.ObjectMap {
        return switch (v) {
            .object => |o| o,
            else => return r.bad("{s} is not a JSON object", .{what}),
        };
    }

    fn array(r: Reader, o: std.json.ObjectMap, key: []const u8, what: []const u8, required: bool) ParseError![]const std.json.Value {
        const v = o.get(key) orelse {
            if (required) return r.bad("{s} has no {s}", .{ what, key });
            return &.{};
        };
        return switch (v) {
            .array => |a| a.items,
            else => return r.bad("{s}'s {s} is not an array", .{ what, key }),
        };
    }

    fn string(r: Reader, o: std.json.ObjectMap, key: []const u8, what: []const u8) ParseError![]const u8 {
        const v = o.get(key) orelse return r.bad("{s} has no {s}", .{ what, key });
        return switch (v) {
            .string => |s| s,
            else => return r.bad("{s}'s {s} is not a string", .{ what, key }),
        };
    }

    fn sha(r: Reader, s: []const u8, what: []const u8) ParseError![]const u8 {
        if (!isSha256(s)) return r.bad("{s}'s sha256 is not 64 lowercase hex digits", .{what});
        return s;
    }
};

pub fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// Reads a lock and checks it. On `error.Invalid`, `why` says what is wrong.
pub fn parse(arena: Allocator, text: []const u8, why: *[]const u8) ParseError!Lock {
    const r = Reader{ .arena = arena, .why = why };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return r.bad("it is not JSON", .{});
    };
    const top = try r.object(root, "the lock");
    const ver = switch (top.get("lock_version") orelse return r.bad("the lock has no lock_version", .{})) {
        .integer => |n| n,
        else => return r.bad("lock_version is not an integer", .{}),
    };
    if (ver > lock_version_2) return r.bad("lock_version is {d}; this mopm reads {d}. Update mopm.", .{ ver, lock_version_2 });
    if (ver != lock_version and ver != lock_version_2) return r.bad("lock_version {d} is not one mopm writes", .{ver});
    const two = ver == lock_version_2;

    var mojo: []const u8 = "";
    var mojos = std.ArrayList([]const u8).init(arena);
    var closures = std.ArrayList(Closure).init(arena);
    if (two) {
        for (try r.array(top, "mojo", "the lock", true)) |m| {
            switch (m) {
                .string => |s| try mojos.append(s),
                else => return r.bad("a mojo version is not a string", .{}),
            }
        }
        if (mojos.items.len == 0) return r.bad("the lock's mojo lists no version", .{});
        mojo = mojos.items[0];
        const toolchain = try r.object(top.get("toolchain") orelse return r.bad("the lock has no toolchain", .{}), "toolchain");
        var it = toolchain.iterator();
        while (it.next()) |e| {
            const per = try r.object(e.value_ptr.*, "a toolchain entry");
            var jt = per.iterator();
            while (jt.next()) |f| {
                const sum = switch (f.value_ptr.*) {
                    .string => |s| s,
                    else => return r.bad("the closure hash of mojo {s} on {s} is not a string", .{ e.key_ptr.*, f.key_ptr.* }),
                };
                try closures.append(.{ .mojo = e.key_ptr.*, .subdir = f.key_ptr.*, .sha256 = try r.sha(sum, "toolchain") });
            }
        }
        std.mem.sort(Closure, closures.items, {}, lessClosure);
    } else {
        const toolchain = try r.object(top.get("toolchain") orelse return r.bad("the lock has no toolchain", .{}), "toolchain");
        mojo = try r.string(toolchain, "mojo", "toolchain");
    }

    var channels = std.ArrayList([]const u8).init(arena);
    for (try r.array(top, "channels", "the lock", true)) |c| {
        switch (c) {
            .string => |s| try channels.append(s),
            else => return r.bad("a channel is not a string", .{}),
        }
    }
    if (channels.items.len == 0) return r.bad("the lock lists no channels", .{});

    var packages = std.ArrayList(Package).init(arena);
    for (try r.array(top, "packages", "the lock", true), 0..) |pv, n| {
        const what = try std.fmt.allocPrint(arena, "packages[{d}]", .{n});
        const o = try r.object(pv, what);
        if (o.get("source") != null) {
            const source = try r.string(o, "source", what);
            if (!std.mem.eql(u8, source, "path")) return r.bad("{s}'s source is {s}; a lock entry's source is path, or none for the registry", .{ what, source });
            for ([_][]const u8{ "build", "subdir", "channel", "url", "sha256", "size", "mojo", "artifacts" }) |key| {
                if (o.get(key) != null) return r.bad("{s} is a path dependency, which has no {s}", .{ what, key });
            }
            try packages.append(.{
                .name = try r.string(o, "name", what),
                .version = try r.string(o, "version", what),
                .source = .path,
                .path = try r.string(o, "path", what),
                .deps = try stringList(r, o, what),
            });
            continue;
        }
        if (o.get("path") != null) return r.bad("{s} has a path but no \"source\": \"path\"", .{what});
        var p = Package{
            .name = try r.string(o, "name", what),
            .version = try r.string(o, "version", what),
            .subdir = try r.string(o, "subdir", what),
            .channel = try r.string(o, "channel", what),
        };
        if (two) {
            for ([_][]const u8{ "build", "url", "sha256", "size", "mojo" }) |key| {
                if (o.get(key) != null) return r.bad("{s} has {s}; in a version 2 lock it belongs under artifacts", .{ what, key });
            }
            const arts = try r.object(o.get("artifacts") orelse return r.bad("{s} has no artifacts", .{what}), "artifacts");
            var list = std.ArrayList(Artifact).init(arena);
            var it = arts.iterator();
            while (it.next()) |e| {
                const aw = try std.fmt.allocPrint(arena, "{s}'s artifact for mojo {s}", .{ what, e.key_ptr.* });
                const ao = try r.object(e.value_ptr.*, aw);
                const size: i64 = switch (ao.get("size") orelse return r.bad("{s} has no size", .{aw})) {
                    .integer => |s| s,
                    else => return r.bad("{s}'s size is not an integer", .{aw}),
                };
                if (size < 1) return r.bad("{s}'s size is not positive", .{aw});
                try list.append(.{
                    .mojo = e.key_ptr.*,
                    .build = try r.string(ao, "build", aw),
                    .url = try r.string(ao, "url", aw),
                    .sha256 = try r.sha(try r.string(ao, "sha256", aw), aw),
                    .size = @intCast(size),
                });
            }
            std.mem.sort(Artifact, list.items, {}, lessArtifact);
            p.artifacts = list.items;
        } else {
            p.build = try r.string(o, "build", what);
            p.url = try r.string(o, "url", what);
            p.sha256 = try r.sha(try r.string(o, "sha256", what), what);
            p.mojo = try r.string(o, "mojo", what);
            const size: i64 = switch (o.get("size") orelse return r.bad("{s} has no size", .{what})) {
                .integer => |s| s,
                else => return r.bad("{s}'s size is not an integer", .{what}),
            };
            if (size < 1) return r.bad("{s}'s size is not positive", .{what});
            p.size = @intCast(size);
        }
        p.deps = try stringList(r, o, what);
        var natives = std.ArrayList(Native).init(arena);
        for (try r.array(o, "native", what, false)) |nv| {
            const no = try r.object(nv, "a native library");
            try natives.append(try readNative(r, no, what));
        }
        p.native = natives.items;
        try packages.append(p);
    }
    const l = Lock{ .mojo = mojo, .channels = channels.items, .packages = packages.items, .mojos = mojos.items, .closures = closures.items };
    if (try check(arena, l)) |broken| return r.bad("{s}", .{broken});
    return l;
}

fn lessClosure(_: void, a: Closure, b: Closure) bool {
    const m = std.mem.order(u8, a.mojo, b.mojo);
    if (m != .eq) return m == .lt;
    return std.mem.order(u8, a.subdir, b.subdir) == .lt;
}

fn lessArtifact(_: void, a: Artifact, b: Artifact) bool {
    return std.mem.order(u8, a.mojo, b.mojo) == .lt;
}

/// One entry of a package's `native`.
fn readNative(r: Reader, no: std.json.ObjectMap, what: []const u8) ParseError!Native {
    var lib = Native{ .id = try r.string(no, "id", what), .soname = try r.string(no, "soname", what) };
    if (no.get("sha256") != null) lib.sha256 = try r.sha(try r.string(no, "sha256", what), what);
    if (no.get("kind") != null) {
        const k = try r.string(no, "kind", what);
        lib.kind = std.meta.stringToEnum(metadata.Kind, k) orelse return r.bad("{s}'s native library {s} has kind {s}; a kind is shared, static or both", .{ what, lib.id, k });
    }
    var needs = std.ArrayList([]const u8).init(r.arena);
    for (try r.array(no, "needs", what, false)) |n| {
        switch (n) {
            .string => |s| try needs.append(s),
            else => return r.bad("{s}'s native library {s} has a need that is not a string", .{ what, lib.id }),
        }
    }
    lib.needs = needs.items;
    if (no.get("exclusive") != null) lib.exclusive = try r.string(no, "exclusive", what);
    return lib;
}

fn stringList(r: Reader, o: std.json.ObjectMap, what: []const u8) ParseError![]const []const u8 {
    var deps = std.ArrayList([]const u8).init(r.arena);
    for (try r.array(o, "deps", what, false)) |d| {
        switch (d) {
            .string => |s| try deps.append(s),
            else => return r.bad("{s} has a dependency that is not a string", .{what}),
        }
    }
    return deps.items;
}

fn str(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

/// Prints `l` in the lock's fixed layout. `l.packages` must already be sorted.
pub fn write(l: Lock, w: anytype) !void {
    if (l.mojos.len > 0) return writeV2(l, w);
    try w.print("{{\n  \"lock_version\": {d},\n  \"toolchain\": {{\n    \"mojo\": ", .{lock_version});
    try str(w, l.mojo);
    try w.writeAll("\n  },\n  \"channels\": [");
    for (l.channels, 0..) |c, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try str(w, c);
    }
    try w.writeAll("\n  ],\n  \"packages\": [");
    for (l.packages, 0..) |p, i| {
        try w.writeAll(if (i == 0) "\n    {" else ",\n    {");
        if (p.source == .path) {
            const fields = [_]struct { []const u8, []const u8 }{
                .{ "name", p.name }, .{ "version", p.version }, .{ "source", "path" }, .{ "path", p.path },
            };
            for (fields, 0..) |f, n| {
                try w.print("{s}\n      \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
                try str(w, f[1]);
            }
            try writeDeps(w, p.deps);
            try w.writeAll("\n    }");
            continue;
        }
        const fields = [_]struct { []const u8, []const u8 }{
            .{ "name", p.name },       .{ "version", p.version }, .{ "build", p.build },
            .{ "subdir", p.subdir },   .{ "channel", p.channel }, .{ "url", p.url },
            .{ "sha256", p.sha256 },
        };
        for (fields, 0..) |f, n| {
            try w.print("{s}\n      \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
            try str(w, f[1]);
        }
        try w.print(",\n      \"size\": {d},\n      \"mojo\": ", .{p.size});
        try str(w, p.mojo);
        try writeDeps(w, p.deps);
        try writeNatives(w, p.native);
        try w.writeAll("\n    }");
    }
    try w.writeAll(if (l.packages.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

fn writeNatives(w: anytype, native: []const Native) !void {
    if (native.len == 0) return;
    try w.writeAll(",\n      \"native\": [");
    for (native, 0..) |lib, n| {
        try w.writeAll(if (n == 0) "\n        {\n          \"id\": " else ",\n        {\n          \"id\": ");
        try str(w, lib.id);
        try w.writeAll(",\n          \"soname\": ");
        try str(w, lib.soname);
        if (lib.sha256) |s| {
            try w.writeAll(",\n          \"sha256\": ");
            try str(w, s);
        }
        if (lib.kind != .shared) try w.print(",\n          \"kind\": \"{s}\"", .{@tagName(lib.kind)});
        if (lib.needs.len > 0) {
            try w.writeAll(",\n          \"needs\": [");
            for (lib.needs, 0..) |need, k| {
                try w.writeAll(if (k == 0) "\n            " else ",\n            ");
                try str(w, need);
            }
            try w.writeAll("\n          ]");
        }
        if (lib.exclusive.len > 0) {
            try w.writeAll(",\n          \"exclusive\": ");
            try str(w, lib.exclusive);
        }
        try w.writeAll("\n        }");
    }
    try w.writeAll("\n      ]");
}

/// The version 2 layout: `mojo`, `toolchain` by Mojo version then subdir, and
/// each registry package's builds under `artifacts`.
fn writeV2(l: Lock, w: anytype) !void {
    try w.print("{{\n  \"lock_version\": {d},\n  \"mojo\": [", .{lock_version_2});
    for (l.mojos, 0..) |m, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try str(w, m);
    }
    try w.writeAll("\n  ],\n  \"toolchain\": {");
    for (l.closures, 0..) |c, i| {
        const same = i > 0 and std.mem.eql(u8, l.closures[i - 1].mojo, c.mojo);
        if (same) {
            try w.writeAll(",\n      ");
        } else {
            if (i > 0) try w.writeAll("\n    },");
            try w.writeAll("\n    ");
            try str(w, c.mojo);
            try w.writeAll(": {\n      ");
        }
        try str(w, c.subdir);
        try w.writeAll(": ");
        try str(w, c.sha256);
    }
    try w.writeAll(if (l.closures.len == 0) "},\n  \"channels\": [" else "\n    }\n  },\n  \"channels\": [");
    for (l.channels, 0..) |c, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try str(w, c);
    }
    try w.writeAll("\n  ],\n  \"packages\": [");
    for (l.packages, 0..) |p, i| {
        try w.writeAll(if (i == 0) "\n    {" else ",\n    {");
        if (p.source == .path) {
            const fields = [_]struct { []const u8, []const u8 }{
                .{ "name", p.name }, .{ "version", p.version }, .{ "source", "path" }, .{ "path", p.path },
            };
            for (fields, 0..) |f, n| {
                try w.print("{s}\n      \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
                try str(w, f[1]);
            }
            try writeDeps(w, p.deps);
            try w.writeAll("\n    }");
            continue;
        }
        const fields = [_]struct { []const u8, []const u8 }{
            .{ "name", p.name },       .{ "version", p.version },
            .{ "subdir", p.subdir },   .{ "channel", p.channel },
        };
        for (fields, 0..) |f, n| {
            try w.print("{s}\n      \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
            try str(w, f[1]);
        }
        try w.writeAll(",\n      \"artifacts\": {");
        for (p.artifacts, 0..) |a, k| {
            try w.writeAll(if (k == 0) "\n        " else ",\n        ");
            try str(w, a.mojo);
            try w.writeAll(": {\n          \"build\": ");
            try str(w, a.build);
            try w.writeAll(",\n          \"url\": ");
            try str(w, a.url);
            try w.writeAll(",\n          \"sha256\": ");
            try str(w, a.sha256);
            try w.print(",\n          \"size\": {d}\n        }}", .{a.size});
        }
        try w.writeAll(if (p.artifacts.len == 0) "}" else "\n      }");
        try writeDeps(w, p.deps);
        try writeNatives(w, p.native);
        try w.writeAll("\n    }");
    }
    try w.writeAll(if (l.packages.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

fn writeDeps(w: anytype, deps: []const []const u8) !void {
    if (deps.len == 0) return;
    try w.writeAll(",\n      \"deps\": [");
    for (deps, 0..) |d, n| {
        try w.writeAll(if (n == 0) "\n        " else ",\n        ");
        try str(w, d);
    }
    try w.writeAll("\n      ]");
}

/// `write` into a new string.
pub fn render(arena: Allocator, l: Lock) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    write(l, out.writer()) catch return error.OutOfMemory;
    return out.items;
}

test "each valid example lock is read and written back byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        seen += 1;
        const text = try dir.readFileAlloc(a, entry.name, 1 << 20);
        var why: []const u8 = "";
        const l = parse(a, text, &why) catch |e| {
            std.debug.print("{s}: refused: {s}\n", .{ entry.name, why });
            return e;
        };
        std.testing.expectEqualStrings(text, try render(a, l)) catch |e| {
            std.debug.print("{s}: written differently\n", .{entry.name});
            return e;
        };
    }
    try std.testing.expect(seen >= 5);
}

test "each invalid example lock is refused, for the reason its name gives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "bad_sha256.json", "sha256 is not 64 lowercase hex digits" },
        .{ "channel_not_listed.json", "is not in channels" },
        .{ "dep_not_in_lock.json", "is not in packages" },
        .{ "duplicate_entry.json", "not sorted by name, version and subdir with no repeats" },
        .{ "future_lock_version.json", "Update mopm." },
        .{ "http_non_loopback_channel.json", "channel http://conda.mopm.dev/channel/ is refused" },
        .{ "missing_build.json", "has no build" },
        .{ "mojo_mismatch.json", "but the toolchain is mojo" },
        .{ "name_from_two_channels.json", "comes from two channels" },
        .{ "native_bad_kind.json", "has kind weird; a kind is shared, static or both" },
        .{ "native_need_not_string.json", "has a need that is not a string" },
        .{ "soname_clash.json", "is shipped by both" },
        .{ "unsorted.json", "not sorted by name, version and subdir" },
        .{ "url_mismatch.json", "url is " },
    };
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/invalid"), .{ .iterate = true });
    defer dir.close();
    var files: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |_| files += 1;
    // A new invalid example needs a case here.
    try std.testing.expectEqual(cases.len, files);
    for (cases) |case| {
        const text = try dir.readFileAlloc(a, case[0], 1 << 20);
        var why: []const u8 = "";
        if (parse(a, text, &why)) |_| {
            std.debug.print("{s}: accepted\n", .{case[0]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        if (std.mem.indexOf(u8, why, case[1]) == null) {
            std.debug.print("{s}: refused with '{s}', want '{s}'\n", .{ case[0], why, case[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "a channel may carry a path; its scheme is https, or http only to a loopback host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const template =
        \\{
        \\  "lock_version": 1,
        \\  "toolchain": {
        \\    "mojo": "1.0.0"
        \\  },
        \\  "channels": [
        \\    "@C@"
        \\  ],
        \\  "packages": [
        \\    {
        \\      "name": "tls",
        \\      "version": "1.1.0",
        \\      "build": "mojo1.0.0_0",
        \\      "subdir": "linux-64",
        \\      "channel": "@C@",
        \\      "url": "@C@linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda",
        \\      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        \\      "size": 1000,
        \\      "mojo": "1.0.0"
        \\    }
        \\  ]
        \\}
        \\
    ;
    const accepted = [_][]const u8{
        "https://conda.mopm.dev/",
        "https://mopm.dev/channel/",
        "http://127.0.0.1:5000/channel/",
        "http://[::1]:8080/a/b/",
        "http://localhost:1/channel/",
    };
    for (accepted) |c| {
        const text = try std.mem.replaceOwned(u8, a, template, "@C@", c);
        var why: []const u8 = "";
        const l = parse(a, text, &why) catch |e| {
            std.debug.print("{s}: refused: {s}\n", .{ c, why });
            return e;
        };
        try std.testing.expectEqualStrings(text, try render(a, l));
    }
    const refused = [_][]const u8{
        "http://example.com/channel/",
        "http://conda.mopm.dev/",
        "http://127.0.0.2:80/channel/",
        "http://127.0.0.1/channel/",
        "http://localhost.evil:80/",
        "ftp://127.0.0.1:21/",
        "https:///",
        "https://mopm.dev/channel",
    };
    for (refused) |c| {
        const text = try std.mem.replaceOwned(u8, a, template, "@C@", c);
        var why: []const u8 = "";
        if (parse(a, text, &why)) |_| {
            std.debug.print("{s}: accepted\n", .{c});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        try std.testing.expect(std.mem.indexOf(u8, why, channel_rule) != null);
    }
}

test "a path dependency is locked with source path, its version and path, and no file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\{
        \\  "lock_version": 1,
        \\  "toolchain": {
        \\    "mojo": "1.0.0"
        \\  },
        \\  "channels": [
        \\    "https://conda.mopm.dev/"
        \\  ],
        \\  "packages": [
        \\    {
        \\      "name": "local",
        \\      "version": "0.3.0",
        \\      "source": "path",
        \\      "path": "../local",
        \\      "deps": [
        \\        "tls"
        \\      ]
        \\    },
        \\    {
        \\      "name": "tls",
        \\      "version": "1.1.0",
        \\      "build": "mojo1.0.0_0",
        \\      "subdir": "linux-64",
        \\      "channel": "https://conda.mopm.dev/",
        \\      "url": "https://conda.mopm.dev/linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda",
        \\      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        \\      "size": 1000,
        \\      "mojo": "1.0.0"
        \\    }
        \\  ]
        \\}
        \\
    ;
    var why: []const u8 = "";
    const l = parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(Source.path, l.packages[0].source);
    try std.testing.expectEqualStrings("../local", l.packages[0].path);
    try std.testing.expectEqualStrings("", l.packages[0].sha256);
    try std.testing.expectEqual(Source.registry, l.packages[1].source);
    try std.testing.expectEqualStrings(text, try render(a, l));

    const Case = struct { []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        .{ "\"path\": \"../local\",", "\"path\": \"../local\",\n      \"sha256\": \"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\",", "is a path dependency, which has no sha256" },
        .{ "\"source\": \"path\",", "\"source\": \"git\",", "source is git" },
        .{ "\"source\": \"path\",", "", "has a path but no \"source\": \"path\"" },
        .{ "\"path\": \"../local\",", "", "has no path" },
        .{ "\"path\": \"../local\",", "\"path\": \"\",", "a path dependency with an empty path" },
    };
    for (cases) |case| {
        if (std.mem.indexOf(u8, text, case[0]) == null) return error.TestUnexpectedResult;
        const bad = try std.mem.replaceOwned(u8, a, text, case[0], case[1]);
        why = "";
        if (parse(a, bad, &why)) |_| {
            std.debug.print("accepted, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        if (std.mem.indexOf(u8, why, case[2]) == null) {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ why, case[2] });
            return error.TestUnexpectedResult;
        }
    }
    // The registry entry renamed to local (and the path entry's dependency
    // with it): one name, locked both as a path and from a channel.
    const twice = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, text, "\"name\": \"tls\",", "\"name\": \"local\","), "        \"tls\"\n", "        \"local\"\n");
    why = "";
    try std.testing.expectError(error.Invalid, parse(a, twice, &why));
    try std.testing.expectEqualStrings("local is locked as a path dependency and has another entry", why);
}

const lock_v2_text =
    \\{
    \\  "lock_version": 2,
    \\  "mojo": [
    \\    "1.0.0",
    \\    "1.1.0"
    \\  ],
    \\  "toolchain": {
    \\    "1.0.0": {
    \\      "linux-64": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    \\    },
    \\    "1.1.0": {
    \\      "linux-64": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    \\    }
    \\  },
    \\  "channels": [
    \\    "https://conda.mopm.dev/"
    \\  ],
    \\  "packages": [
    \\    {
    \\      "name": "http_core",
    \\      "version": "1.2.5",
    \\      "subdir": "linux-64",
    \\      "channel": "https://conda.mopm.dev/",
    \\      "artifacts": {
    \\        "1.0.0": {
    \\          "build": "mojo1.0.0_0",
    \\          "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda",
    \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\          "size": 1000
    \\        },
    \\        "1.1.0": {
    \\          "build": "mojo1.1.0_0",
    \\          "url": "https://conda.mopm.dev/linux-64/mojo-http_core-1.2.5-mojo1.1.0_0.conda",
    \\          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    \\          "size": 1100
    \\        }
    \\      },
    \\      "native": [
    \\        {
    \\          "id": "z",
    \\          "soname": "libz_native.so.1",
    \\          "sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "name": "http_server",
    \\      "version": "0.2.0",
    \\      "subdir": "linux-64",
    \\      "channel": "https://conda.mopm.dev/",
    \\      "artifacts": {
    \\        "1.1.0": {
    \\          "build": "mojo1.1.0_0",
    \\          "url": "https://conda.mopm.dev/linux-64/mojo-http_server-0.2.0-mojo1.1.0_0.conda",
    \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\          "size": 2000
    \\        }
    \\      },
    \\      "deps": [
    \\        "http_core"
    \\      ]
    \\    },
    \\    {
    \\      "name": "util",
    \\      "version": "0.3.0",
    \\      "source": "path",
    \\      "path": "util"
    \\    }
    \\  ]
    \\}
;

test "a version 2 lock is read and written back byte for byte; forMojo gives the lock of one Mojo version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const l = parse(a, lock_v2_text ++ "\n", &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(usize, 2), l.mojos.len);
    try std.testing.expectEqualStrings("1.0.0", l.mojo);
    try std.testing.expectEqual(@as(usize, 2), l.closures.len);
    try std.testing.expectEqual(@as(usize, 2), l.packages[0].artifacts.len);
    try std.testing.expectEqualStrings(lock_v2_text ++ "\n", try render(a, l));

    // One Mojo version: the packages that have a build for it, flat, as a version 1 lock reads.
    const v10 = try forMojo(a, l, "1.0.0");
    try std.testing.expectEqual(@as(usize, 2), v10.packages.len); // http_core and util; http_server has no 1.0.0 build
    try std.testing.expectEqualStrings("mojo1.0.0_0", v10.packages[0].build);
    try std.testing.expectEqualStrings("a" ** 64, v10.packages[0].sha256);
    const v11 = try forMojo(a, l, "1.1.0");
    try std.testing.expectEqual(@as(usize, 3), v11.packages.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", v11.packages[0].build);
    try std.testing.expectEqual(@as(u64, 1100), v11.packages[0].size);
    try std.testing.expectEqualStrings("1.1.0", v11.packages[0].mojo);

    // artifactFor and what the error words.
    try std.testing.expect(artifactFor(l.packages[1], "1.0.0") == null);
    try std.testing.expect(artifactFor(l.packages[2], "1.0.0") == null); // a path dependency has no build
    const published = try publishedFor(a, l.packages[1]);
    try std.testing.expectEqualStrings(
        "http_server 0.2.0 has no .mojoc for Mojo 1.0.0 (published for: 1.1.0). Build with mojo 1.1.0, ask the publisher for a 1.0.0 build, or pin a version that has one.",
        try noMojocMessage(a, "http_server", "0.2.0", "1.0.0", published),
    );
}

test "a version 2 lock that breaks its rules is refused, saying which" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8, []const u8 };
    const url_10 = "mojo-http_core-1.2.5-mojo1.0.0_0.conda";
    const cases = [_]Case{
        // a build for a Mojo version the lock does not list
        .{ "\"1.0.0\": {\n          \"build\": \"mojo1.0.0_0\"", "\"1.2.0\": {\n          \"build\": \"mojo1.0.0_0\"", "an artifact for mojo 1.2.0, which the lock does not list in mojo" },
        // a toolchain closure for a Mojo version the lock does not list
        .{ "\"mojo\": [\n    \"1.0.0\",\n    \"1.1.0\"\n  ]", "\"mojo\": [\n    \"1.1.0\"\n  ]", "toolchain names mojo 1.0.0, which the lock does not list in mojo" },
        // mojo out of order
        .{ "\"mojo\": [\n    \"1.0.0\",\n    \"1.1.0\"\n  ]", "\"mojo\": [\n    \"1.1.0\",\n    \"1.0.0\"\n  ]", "mojo is not sorted with no repeats" },
        // a url that is not the build's
        .{ url_10, "mojo-http_core-1.2.5-mojo9.9.9_0.conda", "url is " },
        // a flat key in a version 2 entry
        .{ "\"subdir\": \"linux-64\",\n      \"channel\": \"https://conda.mopm.dev/\",\n      \"artifacts\": {\n        \"1.0.0\"", "\"subdir\": \"linux-64\",\n      \"mojo\": \"1.0.0\",\n      \"channel\": \"https://conda.mopm.dev/\",\n      \"artifacts\": {\n        \"1.0.0\"", "in a version 2 lock it belongs under artifacts" },
        // no artifacts
        .{ "\"artifacts\": {\n        \"1.1.0\": {\n          \"build\": \"mojo1.1.0_0\",\n          \"url\": \"https://conda.mopm.dev/linux-64/mojo-http_server-0.2.0-mojo1.1.0_0.conda\",\n          \"sha256\": \"" ++ "a" ** 64 ++ "\",\n          \"size\": 2000\n        }\n      },", "", "has no artifacts" },
    };
    for (cases) |case| {
        if (std.mem.indexOf(u8, lock_v2_text, case[0]) == null) {
            std.debug.print("the case's text is not in the lock: {s}\n", .{case[0]});
            return error.TestUnexpectedResult;
        }
        const bad_text = try std.mem.replaceOwned(u8, a, lock_v2_text, case[0], case[1]);
        var why: []const u8 = "";
        if (parse(a, bad_text, &why)) |_| {
            std.debug.print("accepted, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        if (std.mem.indexOf(u8, why, case[2]) == null) {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ why, case[2] });
            return error.TestUnexpectedResult;
        }
    }
    // A closure missing for a locked Mojo version: take the 1.1.0 closure out.
    const gone = try std.mem.replaceOwned(u8, a, lock_v2_text, ",\n    \"1.1.0\": {\n      \"linux-64\": \"" ++ "d" ** 64 ++ "\"\n    }", "");
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, parse(a, gone, &why));
    try std.testing.expectEqualStrings("toolchain has no closure for mojo 1.1.0", why);
    // A newer lock_version is still "update mopm".
    const future = try std.mem.replaceOwned(u8, a, lock_v2_text, "\"lock_version\": 2", "\"lock_version\": 3");
    try std.testing.expectError(error.Invalid, parse(a, future, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "Update mopm.") != null);
}

test "a native library keeps its kind, needs and exclusive group through a read and a write; a shared one with none of them writes none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{});
    defer dir.close();
    const text = try dir.readFileAlloc(a, "static_natives.json", 1 << 20);
    var why: []const u8 = "";
    const l = try parse(a, text, &why);
    try std.testing.expectEqual(@as(usize, 2), l.packages.len);
    const crypto = l.packages[0].native[0];
    try std.testing.expectEqual(metadata.Kind.static, crypto.kind);
    try std.testing.expectEqualStrings("libcrypto", crypto.exclusive);
    try std.testing.expectEqual(@as(usize, 0), crypto.needs.len);
    try std.testing.expectEqualStrings("5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9", crypto.sha256.?);
    const tls = l.packages[1].native[0];
    try std.testing.expectEqual(metadata.Kind.static, tls.kind);
    try std.testing.expectEqual(@as(usize, 1), tls.needs.len);
    try std.testing.expectEqualStrings("libcrypto_sys.a", tls.needs[0]);
    try std.testing.expectEqualStrings("", tls.exclusive);

    // A native with only an id and a soname (every lock written before these keys) reads as a shared library, and writes back with no new key.
    const plain = try std.mem.replaceOwned(u8, a, text, ",\n          \"kind\": \"static\",\n          \"exclusive\": \"libcrypto\"", "");
    const p = try parse(a, plain, &why);
    try std.testing.expectEqual(metadata.Kind.shared, p.packages[0].native[0].kind);
    const written = try render(a, p);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"exclusive\"") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\"kind\""));
}

test "a native library that needs its own soname is refused when the lock is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{});
    defer dir.close();
    const text = try dir.readFileAlloc(a, "static_natives.json", 1 << 20);
    const selfish = try std.mem.replaceOwned(u8, a, text, "\"libcrypto_sys.a\"\n          ]", "\"libtls_sys.a\"\n          ]");
    try std.testing.expect(!std.mem.eql(u8, text, selfish));
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, parse(a, selfish, &why));
    try std.testing.expectEqualStrings("tls_sys: native library tls_sys needs itself (libtls_sys.a)", why);
}
