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

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");

/// The `lock_version` this mopm reads and writes.
pub const lock_version: i64 = 1;

pub const Native = struct {
    id: []const u8,
    soname: []const u8,
    sha256: ?[]const u8 = null,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    subdir: []const u8,
    channel: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    mojo: []const u8,
    deps: []const []const u8 = &.{},
    native: []const Native = &.{},
};

pub const Lock = struct {
    mojo: []const u8,
    channels: []const []const u8,
    packages: []const Package,

    /// The version locked for `name`, or null.
    pub fn versionOf(self: Lock, name: []const u8) ?[]const u8 {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.version;
        }
        return null;
    }
};

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
    for (l.channels) |c| {
        if (!allowedChannel(c)) return try std.fmt.allocPrint(arena, "channel {s} is refused: {s}", .{ c, channel_rule });
    }
    for (l.packages, 0..) |p, i| {
        if (i > 0 and order(l.packages[i - 1], p) != .lt) {
            return try std.fmt.allocPrint(arena, "packages are not sorted by name, version and subdir with no repeats (at {s} {s} {s})", .{ p.name, p.version, p.subdir });
        }
        var listed = false;
        for (l.channels) |c| listed = listed or std.mem.eql(u8, c, p.channel);
        if (!listed) return try std.fmt.allocPrint(arena, "{s}: channel {s} is not in channels", .{ p.name, p.channel });
        const want = try fileUrl(arena, p.channel, p.subdir, p.name, p.version, p.build);
        if (!std.mem.eql(u8, want, p.url)) return try std.fmt.allocPrint(arena, "{s}: url is {s}, not {s}", .{ p.name, p.url, want });
        if (!std.mem.eql(u8, p.mojo, l.mojo)) {
            return try std.fmt.allocPrint(arena, "{s}: built with mojo {s}, but the toolchain is mojo {s}", .{ p.name, p.mojo, l.mojo });
        }
        for (p.deps) |d| {
            var found = false;
            for (l.packages) |q| found = found or std.mem.eql(u8, q.name, d);
            if (!found) return try std.fmt.allocPrint(arena, "{s}: dependency {s} is not in packages", .{ p.name, d });
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
    if (ver > lock_version) return r.bad("lock_version is {d}; this mopm reads {d}. Update mopm.", .{ ver, lock_version });
    if (ver != lock_version) return r.bad("lock_version {d} is not one mopm writes", .{ver});

    const toolchain = try r.object(top.get("toolchain") orelse return r.bad("the lock has no toolchain", .{}), "toolchain");
    const mojo = try r.string(toolchain, "mojo", "toolchain");

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
        var p = Package{
            .name = try r.string(o, "name", what),
            .version = try r.string(o, "version", what),
            .build = try r.string(o, "build", what),
            .subdir = try r.string(o, "subdir", what),
            .channel = try r.string(o, "channel", what),
            .url = try r.string(o, "url", what),
            .sha256 = try r.sha(try r.string(o, "sha256", what), what),
            .size = 0,
            .mojo = try r.string(o, "mojo", what),
        };
        const size: i64 = switch (o.get("size") orelse return r.bad("{s} has no size", .{what})) {
            .integer => |s| s,
            else => return r.bad("{s}'s size is not an integer", .{what}),
        };
        if (size < 1) return r.bad("{s}'s size is not positive", .{what});
        p.size = @intCast(size);
        var deps = std.ArrayList([]const u8).init(arena);
        for (try r.array(o, "deps", what, false)) |d| {
            switch (d) {
                .string => |s| try deps.append(s),
                else => return r.bad("{s} has a dependency that is not a string", .{what}),
            }
        }
        p.deps = deps.items;
        var natives = std.ArrayList(Native).init(arena);
        for (try r.array(o, "native", what, false)) |nv| {
            const no = try r.object(nv, "a native library");
            var lib = Native{ .id = try r.string(no, "id", what), .soname = try r.string(no, "soname", what) };
            if (no.get("sha256") != null) lib.sha256 = try r.sha(try r.string(no, "sha256", what), what);
            try natives.append(lib);
        }
        p.native = natives.items;
        try packages.append(p);
    }
    const l = Lock{ .mojo = mojo, .channels = channels.items, .packages = packages.items };
    if (try check(arena, l)) |broken| return r.bad("{s}", .{broken});
    return l;
}

fn str(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

/// Prints `l` in the lock's fixed layout. `l.packages` must already be sorted.
pub fn write(l: Lock, w: anytype) !void {
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
        if (p.deps.len > 0) {
            try w.writeAll(",\n      \"deps\": [");
            for (p.deps, 0..) |d, n| {
                try w.writeAll(if (n == 0) "\n        " else ",\n        ");
                try str(w, d);
            }
            try w.writeAll("\n      ]");
        }
        if (p.native.len > 0) {
            try w.writeAll(",\n      \"native\": [");
            for (p.native, 0..) |lib, n| {
                try w.writeAll(if (n == 0) "\n        {\n          \"id\": " else ",\n        {\n          \"id\": ");
                try str(w, lib.id);
                try w.writeAll(",\n          \"soname\": ");
                try str(w, lib.soname);
                if (lib.sha256) |s| {
                    try w.writeAll(",\n          \"sha256\": ");
                    try str(w, s);
                }
                try w.writeAll("\n        }");
            }
            try w.writeAll("\n      ]");
        }
        try w.writeAll("\n    }");
    }
    try w.writeAll(if (l.packages.len == 0) "]\n}\n" else "\n  ]\n}\n");
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
    var dir = try std.fs.cwd().openDir("tests/contract/examples/lock/valid", .{ .iterate = true });
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
    try std.testing.expect(seen >= 3);
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
        .{ "missing_build.json", "has no build" },
        .{ "mojo_mismatch.json", "but the toolchain is mojo" },
        .{ "name_from_two_channels.json", "comes from two channels" },
        .{ "soname_clash.json", "is shipped by both" },
        .{ "unsorted.json", "not sorted by name, version and subdir" },
        .{ "url_mismatch.json", "url is " },
    };
    var dir = try std.fs.cwd().openDir("tests/contract/examples/lock/invalid", .{ .iterate = true });
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
