//! mopm.lock (spec/lock.md, spec/lock.schema.json): reading, checking and
//! writing.
//!
//! `parse` refuses a lock that breaks the schema's required fields or any of
//! the rules spec/lock.md lists under "Rules the schema cannot express": the
//! CLI checks them on every read. It reads `lock_version` 3 only; a lock of
//! version 1 or 2 predates namespaces and is `error.Stale` (`staleMessage`).
//! `write` prints one fixed layout (two-space indent, the key order of the
//! spec's example, `deps` and `native` left out when empty, a final newline),
//! so the same lock always gives the same bytes. A lock built in memory with
//! `mojos` empty (one `mojo`, each registry entry's file in its flat fields)
//! is written in the same layout, with `mojo` of one version and one artifact
//! per entry.
//!
//! Every package name in a lock, and every name in `deps`, is a full name
//! `<namespace>/<name>`. A registry entry's `channel` is a listed channel root
//! followed by the entry's namespace and `/`, and its file is named by the
//! package's conda name, `mojo-<namespace>.<name>`.
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
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");
const metadata = @import("metadata.zig");
const native_link = @import("native_link.zig");
const lock_libs = @import("lock_libs.zig");
const names = @import("names.zig");

/// The `lock_version` mopm writes and reads. Versions 1 and 2 are read only far enough to report them stale.
pub const lock_version: i64 = 3;

/// The refusal for a lock of `lock_version` `version` (1 or 2), which predates namespaces.
pub fn staleMessage(arena: Allocator, version: i64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "mopm.lock predates namespaces (lock_version {d}); run 'mopm lock'", .{version});
}

/// One `.mojoc` build of a package version, for one Mojo version.
pub const Artifact = struct {
    mojo: []const u8,
    build: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
};

/// The closure hash of mopm's pinned toolchain for a Mojo version and subdir
/// (`mopm plan --unit-graph` prints the same value).
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
    /// System libraries a consumer's final link adds (native_link.allowed), copied from the package's metadata.
    link: []const []const u8 = &.{},
};

/// Where a locked package comes from.
pub const Source = enum { registry, path };

pub const Package = struct {
    /// The full name, `<namespace>/<name>`.
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
    /// The builds, one per Mojo version, sorted by `mojo`. Then `build`, `url`, `sha256`, `size` and `mojo` above are
    /// empty; `forMojo` fills them for one Mojo version. A package built in memory may fill the flat fields instead.
    artifacts: []const Artifact = &.{},
    deps: []const []const u8 = &.{},
    native: []const Native = &.{},
    /// The conda names of the system libraries the package loads, sorted (lock_libs.zig); each is pinned in `system_libs`.
    loads: []const []const u8 = &.{},
};

pub const Lock = struct {
    /// The first of `mojos` (what `mopm sync` installs), or the one Mojo version of a lock built in memory with no `mojos`.
    mojo: []const u8,
    channels: []const []const u8,
    packages: []const Package,
    /// The Mojo versions locked, sorted, no repeats. Never empty in a lock `parse` returns; empty in a lock built in
    /// memory from one Mojo version.
    mojos: []const []const u8 = &.{},
    /// mopm's toolchain closure hash per (mojo, subdir), sorted: one for each Mojo version and subdir mopm pins a toolchain for.
    closures: []const Closure = &.{},
    /// The pinned conda packages of the system libraries that manifests and registry packages load, per subdir
    /// (lock_libs.zig). Empty for a lock that names none.
    system_libs: []const lock_libs.Subdir = &.{},

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

/// `l` seen for one Mojo version: a lock with no `mojos` (flat entries) as it is; any other lock
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
    return .{ .mojo = mojo, .channels = l.channels, .packages = out.items, .system_libs = l.system_libs };
}

/// `<channel><subdir>/mojo-<namespace>.<name>-<version>-<build>.conda` (rule 3); `full` is the full name.
pub fn fileUrl(arena: Allocator, channel: []const u8, subdir: []const u8, full: []const u8, version: []const u8, build: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}/{s}-{s}-{s}.conda", .{ channel, subdir, try names.condaName(arena, full), version, build });
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
    for (l.channels) |c| {
        if (!allowedChannel(c)) return try std.fmt.allocPrint(arena, "channel {s} is refused: {s}", .{ c, channel_rule });
    }
    if (try lock_libs.checkLibs(arena, l.system_libs)) |broken| return broken;
    for (l.packages, 0..) |p, i| {
        if (!names.isFullName(p.name)) return try std.fmt.allocPrint(arena, "{s} is not a full name (<namespace>/<name>)", .{p.name});
        for (p.deps) |d| {
            if (!names.isFullName(d)) return try std.fmt.allocPrint(arena, "{s}: dependency {s} is not a full name (<namespace>/<name>)", .{ p.name, d });
        }
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
            if (registry.channelRoot(p.channel, p.name)) |root| listed = contains(l.channels, root);
            if (!listed) return try std.fmt.allocPrint(arena, "{s}: channel {s} is not a channel of the lock followed by {s}/", .{ p.name, p.channel, names.namespaceOf(p.name) });
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
        if (try lock_libs.checkLoads(arena, p.name, p.subdir, p.loads, l.system_libs)) |broken| return broken;
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
            if (std.mem.eql(u8, names.importName(q.name), names.importName(p.name))) {
                return try std.fmt.allocPrint(arena, "{s} and {s} have the same import name {s}; a closure holds one package per import name", .{ q.name, p.name, names.importName(p.name) });
            }
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

/// `Stale`: a lock of version 1 or 2 (`why` is `staleMessage`). `Invalid`: anything else wrong; `why` says what.
pub const ParseError = error{ Invalid, Stale, OutOfMemory };

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

/// Reads a lock and checks it. On `error.Invalid` or `error.Stale`, `why` says what is wrong.
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
    if (ver > lock_version) return r.bad("lock_version is {d}; this mopm reads {d}. Update mopm.", .{ ver, lock_version });
    if (ver == 1 or ver == 2) {
        r.why.* = try staleMessage(arena, ver);
        return error.Stale;
    }
    if (ver != lock_version) return r.bad("lock_version {d} is not one mopm writes", .{ver});

    var mojos = std.ArrayList([]const u8).init(arena);
    var closures = std.ArrayList(Closure).init(arena);
    for (try r.array(top, "mojo", "the lock", true)) |m| {
        switch (m) {
            .string => |s| try mojos.append(s),
            else => return r.bad("a mojo version is not a string", .{}),
        }
    }
    if (mojos.items.len == 0) return r.bad("the lock's mojo lists no version", .{});
    const mojo = mojos.items[0];
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
            for ([_][]const u8{ "build", "subdir", "channel", "url", "sha256", "size", "mojo", "artifacts", "loads" }) |key| {
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
        for ([_][]const u8{ "build", "url", "sha256", "size", "mojo" }) |key| {
            if (o.get(key) != null) return r.bad("{s} has {s}; it belongs under artifacts", .{ what, key });
        }
        const arts = try r.object(o.get("artifacts") orelse return r.bad("{s} has no artifacts", .{what}), "artifacts");
        var list = std.ArrayList(Artifact).init(arena);
        var at = arts.iterator();
        while (at.next()) |e| {
            const aw = try std.fmt.allocPrint(arena, "{s}'s artifact for mojo {s}", .{ what, e.key_ptr.* });
            const ao = try r.object(e.value_ptr.*, aw);
            const size: i64 = switch (ao.get("size") orelse return r.bad("{s} has no size", .{aw})) {
                .integer => |sz| sz,
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
        p.deps = try stringList(r, o, what);
        var natives = std.ArrayList(Native).init(arena);
        for (try r.array(o, "native", what, false)) |nv| {
            const no = try r.object(nv, "a native library");
            try natives.append(try readNative(r, no, what));
        }
        p.native = natives.items;
        p.loads = try lock_libs.parseLoads(arena, r.why, o, what);
        try packages.append(p);
    }
    const l = Lock{ .mojo = mojo, .channels = channels.items, .packages = packages.items, .mojos = mojos.items, .closures = closures.items, .system_libs = try lock_libs.parseSubdirs(arena, r.why, top) };
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
    var link = std.ArrayList([]const u8).init(r.arena);
    for (try r.array(no, "link", what, false)) |n| {
        switch (n) {
            .string => |s| try link.append(s),
            else => return r.bad("{s}'s native library {s} has a link name that is not a string", .{ what, lib.id }),
        }
    }
    if (try native_link.problem(r.arena, link.items)) |why| return r.bad("{s}'s native library {s}: link: {s}", .{ what, lib.id, why });
    if (link.items.len > 0 and lib.kind != .static) return r.bad("{s}'s native library {s} has a link but is not static", .{ what, lib.id });
    lib.link = link.items;
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
        if (lib.link.len > 0) {
            try w.writeAll(",\n          \"link\": [");
            for (lib.link, 0..) |name, k| {
                try w.writeAll(if (k == 0) "\n            " else ",\n            ");
                try str(w, name);
            }
            try w.writeAll("\n          ]");
        }
        try w.writeAll("\n        }");
    }
    try w.writeAll("\n      ]");
}

/// Prints `l` in the lock's fixed layout: `mojo`, `toolchain` by Mojo version then subdir, and each registry
/// package's builds under `artifacts`. `l.packages` must already be sorted. A lock with no `mojos` is printed with
/// `mojo` as its one Mojo version and each registry entry's flat file as its one artifact.
pub fn write(l: Lock, w: anytype) !void {
    try w.print("{{\n  \"lock_version\": {d},\n  \"mojo\": [", .{lock_version});
    const mojos: []const []const u8 = if (l.mojos.len > 0) l.mojos else &.{l.mojo};
    for (mojos, 0..) |m, i| {
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
            .{ "name", p.name },     .{ "version", p.version },
            .{ "subdir", p.subdir }, .{ "channel", p.channel },
        };
        for (fields, 0..) |f, n| {
            try w.print("{s}\n      \"{s}\": ", .{ if (n == 0) "" else ",", f[0] });
            try str(w, f[1]);
        }
        try w.writeAll(",\n      \"artifacts\": {");
        if (p.artifacts.len == 0) {
            try writeArtifact(w, 0, .{ .mojo = p.mojo, .build = p.build, .url = p.url, .sha256 = p.sha256, .size = p.size });
        }
        for (p.artifacts, 0..) |a, k| try writeArtifact(w, k, a);
        try w.writeAll("\n      }");
        try writeDeps(w, p.deps);
        try writeNatives(w, p.native);
        try lock_libs.writeLoads(w, p.loads);
        try w.writeAll("\n    }");
    }
    try w.writeAll(if (l.packages.len == 0) "]" else "\n  ]");
    try lock_libs.writeSubdirs(w, l.system_libs);
    try w.writeAll("\n}\n");
}

fn writeArtifact(w: anytype, k: usize, a: Artifact) !void {
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
