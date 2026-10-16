//! Installing a set of verified `.conda` files as one conda environment, with
//! no conda and no pixi.
//!
//! `installEnv` builds the environment in a temporary directory beside its
//! target, then swaps it in with renames, so the target is always either the
//! environment as it was or the whole new one, never half of either. The files
//! are unpacked by core/conda_unpack.zig with the prefix placeholders pointing
//! at the target's own path; each package gets the `conda-meta/<name>-<version>-
//! <build>.json` record conda writes, so the result is a valid conda prefix
//! (`conda list` and pixi read it).
//!
//! Before a file is unpacked its size and sha256 are checked once more against
//! the pin, wherever it came from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unpack = @import("conda_unpack.zig");
const fetch = @import("pkg_fetch.zig");

pub const Pkg = struct {
    name: []const u8,
    version: []const u8,
    /// The directory holding the file, and its name there.
    dir: std.fs.Dir,
    file_name: []const u8,
    /// The pinned bytes of the file.
    sha256: []const u8,
    size: u64,
    /// For the conda-meta record.
    url: []const u8,
    channel: []const u8 = "",
    md5: []const u8 = "",
};

pub const Diag = unpack.Diag;

const PathRec = struct {
    _path: []const u8,
    path_type: []const u8,
    size_in_bytes: u64,
    sha256: ?[]const u8 = null,
    sha256_in_prefix: ?[]const u8 = null,
    prefix_placeholder: ?[]const u8 = null,
    file_mode: ?[]const u8 = null,
};

const Record = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    build_number: u64,
    subdir: []const u8,
    channel: []const u8,
    @"fn": []const u8,
    url: []const u8,
    sha256: []const u8,
    md5: ?[]const u8 = null,
    size: u64,
    depends: []const []const u8,
    constrains: ?std.json.Value = null,
    license: ?std.json.Value = null,
    timestamp: ?std.json.Value = null,
    files: []const []const u8,
    paths_data: struct { paths_version: u8 = 1, paths: []const PathRec },
    link: struct { source: []const u8, @"type": u8 = 1 },
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn recordOf(arena: Allocator, pkg: Pkg, inst: unpack.Installed) !Record {
    var files = std.ArrayList([]const u8).init(arena);
    var paths = std.ArrayList(PathRec).init(arena);
    for (inst.paths) |p| {
        try files.append(p.path);
        try paths.append(.{
            ._path = p.path,
            .path_type = if (p.kind == .softlink) "softlink" else "hardlink",
            .size_in_bytes = p.size,
            .sha256 = nonEmpty(p.sha256),
            .sha256_in_prefix = nonEmpty(p.sha256_in_prefix),
            .prefix_placeholder = nonEmpty(p.placeholder),
            .file_mode = nonEmpty(p.file_mode),
        });
    }
    return .{
        .name = inst.name,
        .version = inst.version,
        .build = inst.build,
        .build_number = inst.build_number,
        .subdir = inst.subdir,
        .channel = pkg.channel,
        .@"fn" = pkg.file_name,
        .url = pkg.url,
        .sha256 = pkg.sha256,
        .md5 = nonEmpty(pkg.md5),
        .size = pkg.size,
        .depends = inst.depends,
        .constrains = inst.index.object.get("constrains"),
        .license = inst.index.object.get("license"),
        .timestamp = inst.index.object.get("timestamp"),
        .files = files.items,
        .paths_data = .{ .paths = paths.items },
        .link = .{ .source = pkg.file_name },
    };
}

/// "3.15" for the python `version` "3.15.0" (or "3.15.0rc1"), else null.
fn pythonMinor(version: []const u8) ?[]const u8 {
    const dot1 = std.mem.indexOfScalar(u8, version, '.') orelse return null;
    const dot2 = std.mem.indexOfScalarPos(u8, version, dot1 + 1, '.') orelse return null;
    return version[0..dot2];
}

fn exists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

fn tempName(arena: Allocator, env_name: []const u8, kind: []const u8) ![]u8 {
    var r: [6]u8 = undefined;
    std.crypto.random.bytes(&r);
    return std.fmt.allocPrint(arena, ".{s}.{s}-{s}", .{ env_name, kind, std.fmt.bytesToHex(r, .lower) });
}

/// Removes what an earlier, interrupted `installEnv` left beside the target.
fn removeStale(arena: Allocator, parent: std.fs.Dir, env_name: []const u8) void {
    // `parent` may not have been opened for iteration: open it again, so.
    var listing = parent.openDir(".", .{ .iterate = true }) catch return;
    defer listing.close();
    var it = listing.iterate();
    const tmp = std.fmt.allocPrint(arena, ".{s}.tmp-", .{env_name}) catch return;
    const old = std.fmt.allocPrint(arena, ".{s}.old-", .{env_name}) catch return;
    var names = std.ArrayList([]const u8).init(arena);
    while (it.next() catch return) |e| {
        if (std.mem.startsWith(u8, e.name, tmp) or std.mem.startsWith(u8, e.name, old)) {
            names.append(arena.dupe(u8, e.name) catch return) catch return;
        }
    }
    for (names.items) |n| parent.deleteTree(n) catch {};
}

/// The file of an environment that holds its stamp (the caller's digest of
/// what was installed).
pub const stamp_file = ".mopm-stamp";

/// The stamp of the environment `env_name` in `parent`, or null.
pub fn readStamp(arena: Allocator, parent: std.fs.Dir, env_name: []const u8) ?[]const u8 {
    var env = parent.openDir(env_name, .{}) catch return null;
    defer env.close();
    return env.readFileAlloc(arena, stamp_file, 4096) catch null;
}

/// Installs `pkgs` as the environment `env_name` in `parent`, whose absolute
/// path is `prefix` (placeholders are rewritten to it), and records `stamp`
/// in it. Returns what each package unpacked. On an error `parent` is as it
/// was.
pub fn installEnv(arena: Allocator, parent: std.fs.Dir, env_name: []const u8, prefix: []const u8, pkgs: []const Pkg, stamp: []const u8, diag: *Diag) ![]const unpack.Installed {
    removeStale(arena, parent, env_name);

    var python: ?[]const u8 = null;
    for (pkgs) |p| {
        if (std.mem.eql(u8, p.name, "python")) python = pythonMinor(p.version);
    }

    const window = try std.heap.page_allocator.alloc(u8, unpack.window_size);
    defer std.heap.page_allocator.free(window);

    const tmp_name = try tempName(arena, env_name, "tmp");
    try parent.makeDir(tmp_name);
    var committed = false;
    defer {
        if (!committed) parent.deleteTree(tmp_name) catch {};
    }
    var tmp = try parent.openDir(tmp_name, .{});
    defer tmp.close();
    try tmp.makePath("conda-meta");

    var links = std.StringHashMap(void).init(arena);
    var done = std.ArrayList(unpack.Installed).init(arena);
    var records = std.ArrayList(Record).init(arena);
    for (pkgs) |pkg| {
        if (!(try fetch.matches(pkg.dir, pkg.file_name, .{ .sha256 = pkg.sha256, .size = pkg.size }))) {
            diag.message = try std.fmt.allocPrint(arena, "{s} is not the pinned file (size {d}, sha256 {s}); refused", .{ pkg.file_name, pkg.size, pkg.sha256 });
            return error.HashMismatch;
        }
        const file = try pkg.dir.openFile(pkg.file_name, .{});
        defer file.close();
        const inst = unpack.install(arena, file, .{
            .prefix = prefix,
            .dest = tmp,
            .window = window,
            .python = python,
            .links = &links,
        }, diag) catch |e| {
            if (diag.message.len == 0) diag.message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ pkg.file_name, @errorName(e) });
            return e;
        };
        if (!std.mem.eql(u8, inst.name, pkg.name) or !std.mem.eql(u8, inst.version, pkg.version)) {
            diag.message = try std.fmt.allocPrint(arena, "{s} holds {s} {s}, not the {s} {s} that was asked for; refused", .{ pkg.file_name, inst.name, inst.version, pkg.name, pkg.version });
            return error.PackageMismatch;
        }
        try done.append(inst);
        try records.append(try recordOf(arena, pkg, inst));
    }

    for (records.items) |r| {
        const name = try std.fmt.allocPrint(arena, "conda-meta/{s}-{s}-{s}.json", .{ r.name, r.version, r.build });
        var out = std.ArrayList(u8).init(arena);
        try std.json.stringify(r, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 }, out.writer());
        try out.append('\n');
        try tmp.writeFile(name, out.items);
    }
    try tmp.writeFile("conda-meta/history", "");
    try tmp.writeFile(stamp_file, stamp);

    // Swap in. The old environment, if any, is moved aside first and removed
    // only once the new one is in place; if the second rename fails the old one
    // is put back.
    if (exists(parent, env_name)) {
        const old_name = try tempName(arena, env_name, "old");
        try parent.rename(env_name, old_name);
        parent.rename(tmp_name, env_name) catch |e| {
            parent.rename(old_name, env_name) catch {};
            return e;
        };
        committed = true;
        parent.deleteTree(old_name) catch {};
    } else {
        try parent.rename(tmp_name, env_name);
        committed = true;
    }
    return done.items;
}

// ---------------------------------------------------------------- tests

const fx = @import("conda_fixture.zig");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    cache: std.fs.Dir,
    parent: std.fs.Dir,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makeDir("pkgs");
        try tmp.dir.makeDir("m");
        return .{
            .tmp = tmp,
            .cache = try tmp.dir.openDir("pkgs", .{}),
            .parent = try tmp.dir.openDir("m", .{}),
        };
    }

    fn deinit(self: *Fixture) void {
        self.cache.close();
        self.parent.close();
        self.tmp.cleanup();
    }

    /// Stores a package in the cache and returns the pin for it.
    fn add(self: *Fixture, a: Allocator, name: []const u8, version: []const u8, files: []const fx.Item) !Pkg {
        const bytes = try fx.simple(a, name, version, files);
        const file_name = try std.fmt.allocPrint(a, "{s}-{s}-h0_0.conda", .{ name, version });
        try self.cache.writeFile(file_name, bytes);
        return .{
            .name = name,
            .version = version,
            .dir = self.cache,
            .file_name = file_name,
            .sha256 = try fx.sha256Hex(a, bytes),
            .size = bytes.len,
            .url = try std.fmt.allocPrint(a, "http://127.0.0.1:1/{s}", .{file_name}),
            .channel = "http://127.0.0.1:1/",
        };
    }

    /// The names in `m/`, sorted.
    fn listing(self: *Fixture, a: Allocator) ![]const u8 {
        var names = std.ArrayList([]const u8).init(a);
        var dir = try self.tmp.dir.openDir("m", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |e| try names.append(try a.dupe(u8, e.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        return std.mem.join(a, ",", names.items);
    }
};

test "installEnv: files, conda-meta records, history; nothing else is left beside the environment" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n", .mode = 0o755 }});
    const beta = try f.add(a, "beta", "2.5", &.{.{ .name = "lib/b.txt", .data = "B\n" }});

    // A leftover of an earlier interrupted install is removed.
    try f.parent.makePath(".env.tmp-dead/sub");
    var diag = Diag{};
    const done = try installEnv(a, f.parent, "env", "/opt/mopm/env", &.{ alpha, beta }, "stamp", &diag);
    try std.testing.expectEqual(@as(usize, 2), done.len);
    try std.testing.expectEqualStrings("env", try f.listing(a));

    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("A\n", try env.readFileAlloc(a, "bin/a", 100));
    try std.testing.expectEqualStrings("B\n", try env.readFileAlloc(a, "lib/b.txt", 100));
    try std.testing.expect((try env.statFile("bin/a")).mode & 0o111 != 0);
    try env.access("conda-meta/history", .{});
    try std.testing.expectEqualStrings("stamp", readStamp(a, f.parent, "env").?);

    const text = try env.readFileAlloc(a, "conda-meta/alpha-1.0-h0_0.json", 1 << 20);
    const rec = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const o = rec.object;
    try std.testing.expectEqualStrings("alpha", o.get("name").?.string);
    try std.testing.expectEqualStrings("1.0", o.get("version").?.string);
    try std.testing.expectEqualStrings("h0_0", o.get("build").?.string);
    try std.testing.expectEqual(@as(i64, 3), o.get("build_number").?.integer);
    try std.testing.expectEqualStrings(alpha.sha256, o.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(alpha.size)), o.get("size").?.integer);
    try std.testing.expectEqualStrings("alpha-1.0-h0_0.conda", o.get("fn").?.string);
    try std.testing.expectEqualStrings("MIT", o.get("license").?.string);
    try std.testing.expectEqualStrings("bin/a", o.get("files").?.array.items[0].string);
    const p0 = o.get("paths_data").?.object.get("paths").?.array.items[0].object;
    try std.testing.expectEqualStrings("bin/a", p0.get("_path").?.string);
    try std.testing.expectEqualStrings(try fx.sha256Hex(a, "A\n"), p0.get("sha256_in_prefix").?.string);
}

test "installEnv: a file that is not the pinned bytes is refused before anything is unpacked" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const tampered = try f.add(a, "beta", "2.0", &.{.{ .name = "bin/b", .data = "B\n" }});
    // The same size, one byte different: only the sha256 can tell.
    const bytes = try f.cache.readFileAlloc(a, tampered.file_name, 1 << 20);
    bytes[bytes.len / 2] ^= 1;
    try f.cache.writeFile(tampered.file_name, bytes);

    var diag = Diag{};
    try std.testing.expectError(error.HashMismatch, installEnv(a, f.parent, "env", "/opt/e", &.{ alpha, tampered }, "stamp", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "not the pinned file") != null);
    try std.testing.expectEqualStrings("", try f.listing(a));

    // A pin of the wrong size is refused as well.
    var wrong = alpha;
    wrong.size += 1;
    try std.testing.expectError(error.HashMismatch, installEnv(a, f.parent, "env", "/opt/e", &.{wrong}, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));
}

test "installEnv: an install that fails midway leaves no environment, and keeps the old one" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const bad = try f.add(a, "bad", "1.0", &.{.{ .name = "bin/.bad-post-link.sh", .data = "#!/bin/sh\n" }});
    const first = try f.add(a, "first", "1.0", &.{.{ .name = "bin/first", .data = "old\n" }});

    var diag = Diag{};
    // No environment yet: the failure leaves the directory empty.
    try std.testing.expectError(error.LinkScript, installEnv(a, f.parent, "env", "/opt/e", &.{ alpha, bad }, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));

    // An environment exists: the failure leaves it exactly as it was.
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{first}, "stamp", &diag);
    try std.testing.expectError(error.LinkScript, installEnv(a, f.parent, "env", "/opt/e", &.{ alpha, bad }, "stamp", &diag));
    try std.testing.expectEqualStrings("env", try f.listing(a));
    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("old\n", try env.readFileAlloc(a, "bin/first", 100));
    try std.testing.expectError(error.FileNotFound, env.access("bin/a", .{}));
}

test "installEnv: a new install replaces the old environment whole" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    const alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    const beta = try f.add(a, "beta", "2.0", &.{.{ .name = "bin/b", .data = "B\n" }});
    var diag = Diag{};
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{alpha}, "stamp", &diag);
    _ = try installEnv(a, f.parent, "env", "/opt/e", &.{beta}, "stamp", &diag);
    try std.testing.expectEqualStrings("env", try f.listing(a));
    var env = try f.parent.openDir("env", .{});
    defer env.close();
    try env.access("bin/b", .{});
    try std.testing.expectError(error.FileNotFound, env.access("bin/a", .{}));
    try std.testing.expectError(error.FileNotFound, env.access("conda-meta/alpha-1.0-h0_0.json", .{}));
}

test "installEnv: a package that is not the one asked for is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = try Fixture.init();
    defer f.deinit();
    var alpha = try f.add(a, "alpha", "1.0", &.{.{ .name = "bin/a", .data = "A\n" }});
    alpha.name = "gamma";
    var diag = Diag{};
    try std.testing.expectError(error.PackageMismatch, installEnv(a, f.parent, "env", "/opt/e", &.{alpha}, "stamp", &diag));
    try std.testing.expectEqualStrings("", try f.listing(a));
}
