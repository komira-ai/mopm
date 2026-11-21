//! The digest of a package's sources: `source_sha256` of `<import name>.mopm.json` (spec/package-metadata.schema.json).
//!
//! It is the sha256 of one text, a line per file, `<sha256 of the file, lowercase hex> <path>\n`, sorted by the bytes of the
//! path, where a path is relative to the package directory and uses `/`. The files are the package's manifest, every
//! regular file below its library directory (`[targets] lib`, `src/<import name>` when the manifest names none) and the source
//! of each program (`[targets] bins`). A symlink is read through, to the file or directory it names; anything that is neither
//! a file nor a directory (a socket, a device, a pipe) is refused, because its bytes are not a source.
//!
//! The digest says which sources a build was made from, so the registry can tell that two builds of one version, made with
//! two Mojo compilers, come from the same sources. It does not cover the files a build leaves out, such as tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const manifest = @import("manifest.zig");

pub const Error = error{
    /// The library directory does not exist: there is nothing to digest, and the caller says so.
    NoLibrary,
    /// A file or directory cannot be read or is not a source; `why` says which and why.
    Unreadable,
    OutOfMemory,
};

/// How deep a library directory may nest, which also ends a symlink that leads back into its own directory.
const max_depth: usize = 32;

const Entry = struct { path: []const u8, sha256: [64]u8 };

/// The library directory of `m` relative to the package directory: `[targets] lib`, else `src/<import name>`.
pub fn libraryDir(arena: Allocator, m: manifest.Manifest) Allocator.Error![]const u8 {
    return m.targets.lib orelse try std.fmt.allocPrint(arena, "src/{s}", .{m.package.name});
}

/// The program sources of `m` (`[targets] bins` paths), for `compute`.
pub fn binPaths(arena: Allocator, m: manifest.Manifest) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, m.targets.bins.len);
    for (m.targets.bins, out) |b, *o| o.* = b.path;
    return out;
}

/// The lowercase hex digest of the sources of the package in `dir` (a path that can be opened): its manifest file `manifest_name`,
/// the files below `lib` and the files `bins` name, all relative to `dir`. `error.NoLibrary` when `lib` does not exist;
/// `error.Unreadable` with `why` set when something cannot be read or is not a file or directory.
pub fn compute(arena: Allocator, dir: []const u8, manifest_name: []const u8, lib: []const u8, bins: []const []const u8, why: *[]const u8) Error![64]u8 {
    var root = std.fs.cwd().openDir(dir, .{}) catch |e| {
        why.* = try std.fmt.allocPrint(arena, "source digest: cannot open {s}: {s}", .{ dir, @errorName(e) });
        return error.Unreadable;
    };
    defer root.close();

    var entries = std.ArrayList(Entry).init(arena);
    try addFile(arena, root, try normalize(arena, manifest_name, why), &entries, why);

    const lib_path = try normalize(arena, lib, why);
    var lib_dir = root.openDir(lib_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.NoLibrary,
        else => {
            why.* = try std.fmt.allocPrint(arena, "source digest: cannot open the library directory {s}: {s}", .{ lib_path, @errorName(e) });
            return error.Unreadable;
        },
    };
    defer lib_dir.close();
    try walk(arena, lib_dir, lib_path, 0, &entries, why);

    for (bins) |b| try addFile(arena, root, try normalize(arena, b, why), &entries, why);

    std.mem.sort(Entry, entries.items, {}, lessEntry);
    var h = Sha256.init(.{});
    var previous: ?[]const u8 = null;
    for (entries.items) |e| {
        // A program source below the library directory is one file, listed once.
        if (previous) |p| if (std.mem.eql(u8, p, e.path)) continue;
        previous = e.path;
        h.update(&e.sha256);
        h.update(" ");
        h.update(e.path);
        h.update("\n");
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// What `ofPackage` found.
pub const Outcome = union(enum) {
    digest: [64]u8,
    /// The library directory (relative to the package directory) does not exist: the package carries no digest.
    no_library: []const u8,
    /// Why the sources cannot be digested.
    bad: []const u8,
};

/// The digest of the sources of the package `m` whose manifest is the file `manifest_name` in `dir`: the library directory
/// and the programs are the ones `m` names.
pub fn ofPackage(arena: Allocator, m: manifest.Manifest, dir: []const u8, manifest_name: []const u8) Allocator.Error!Outcome {
    const lib = try libraryDir(arena, m);
    var why: []const u8 = "";
    const digest = compute(arena, dir, std.fs.path.basename(manifest_name), lib, try binPaths(arena, m), &why) catch |e| switch (e) {
        error.NoLibrary => return .{ .no_library = lib },
        error.Unreadable => return .{ .bad = why },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .digest = digest };
}

/// The line that says a package has no digest because its library directory `lib` is not there.
pub fn noLibraryNote(arena: Allocator, m: manifest.Manifest, lib: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "note: {s} does not exist, so {s} {s} carries no source digest; a build for another Mojo can then never be added to this version", .{ lib, m.package.full_name, m.package.version });
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// `path` as it is written in a digest line: `/` separators, no `.` or empty segment. A path that leaves the package
/// directory has no such form and is refused.
fn normalize(arena: Allocator, path: []const u8, why: *[]const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        why.* = try std.fmt.allocPrint(arena, "source digest: {s} is an absolute path; a package's files are named relative to its directory", .{path});
        return error.Unreadable;
    }
    var out = std.ArrayList(u8).init(arena);
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            why.* = try std.fmt.allocPrint(arena, "source digest: {s} leaves the package directory", .{path});
            return error.Unreadable;
        }
        if (out.items.len > 0) try out.append('/');
        try out.appendSlice(seg);
    }
    if (out.items.len == 0) {
        why.* = try std.fmt.allocPrint(arena, "source digest: '{s}' names no file", .{path});
        return error.Unreadable;
    }
    return out.items;
}

fn kindName(k: std.fs.File.Kind) []const u8 {
    return switch (k) {
        .block_device => "block device",
        .character_device => "character device",
        .named_pipe => "named pipe",
        .unix_domain_socket => "socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "event port",
        else => "special file",
    };
}

fn walk(arena: Allocator, dir: std.fs.Dir, prefix: []const u8, depth: usize, out: *std.ArrayList(Entry), why: *[]const u8) Error!void {
    if (depth > max_depth) {
        why.* = try std.fmt.allocPrint(arena, "source digest: {s} is nested more than {d} directories deep (a symlink that leads back into its own directory?)", .{ prefix, max_depth });
        return error.Unreadable;
    }
    var it = dir.iterate();
    while (it.next() catch |e| {
        why.* = try std.fmt.allocPrint(arena, "source digest: cannot list {s}: {s}", .{ prefix, @errorName(e) });
        return error.Unreadable;
    }) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        var kind = entry.kind;
        if (kind == .sym_link or kind == .unknown) {
            // Read through: the kind of what the link names.
            const st = dir.statFile(entry.name) catch |e| {
                why.* = try std.fmt.allocPrint(arena, "source digest: cannot read {s}: {s}", .{ path, @errorName(e) });
                return error.Unreadable;
            };
            kind = st.kind;
        }
        switch (kind) {
            .file => try addFileAs(arena, dir, entry.name, path, out, why),
            .directory => {
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch |e| {
                    why.* = try std.fmt.allocPrint(arena, "source digest: cannot open {s}: {s}", .{ path, @errorName(e) });
                    return error.Unreadable;
                };
                defer sub.close();
                try walk(arena, sub, path, depth + 1, out, why);
            },
            else => {
                why.* = try std.fmt.allocPrint(arena, "source digest: {s} is a {s}, neither a file nor a directory; remove it, or move it out of the library directory", .{ path, kindName(kind) });
                return error.Unreadable;
            },
        }
    }
}

fn addFile(arena: Allocator, dir: std.fs.Dir, path: []const u8, out: *std.ArrayList(Entry), why: *[]const u8) Error!void {
    return addFileAs(arena, dir, path, path, out, why);
}

/// Adds the file `sub_path` of `dir`, listed as `path`.
fn addFileAs(arena: Allocator, dir: std.fs.Dir, sub_path: []const u8, path: []const u8, out: *std.ArrayList(Entry), why: *[]const u8) Error!void {
    var f = dir.openFile(sub_path, .{}) catch |e| {
        why.* = try std.fmt.allocPrint(arena, "source digest: cannot read {s}: {s}", .{ path, @errorName(e) });
        return error.Unreadable;
    };
    defer f.close();
    var h = Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch |e| {
            why.* = try std.fmt.allocPrint(arena, "source digest: cannot read {s}: {s}", .{ path, @errorName(e) });
            return error.Unreadable;
        };
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    try out.append(.{ .path = path, .sha256 = std.fmt.bytesToHex(digest, .lower) });
}

// ---------------------------------------------------------------- tests

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn put(dir: std.fs.Dir, rel: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel)) |d| try dir.makePath(d);
    try dir.writeFile(rel, bytes);
}

fn hexOf(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn digestOf(a: Allocator, tmp: *std.testing.TmpDir, lib: []const u8, bins: []const []const u8) ![64]u8 {
    var why: []const u8 = "";
    return compute(a, try tmp.dir.realpathAlloc(a, "."), "mopm.toml", lib, bins, &why);
}

test "the digest is the sha256 of the sorted '<sha256> <path>' lines, computed here by hand" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "the manifest");
    try put(tmp.dir, "src/fx/a.mojo", "alpha");
    try put(tmp.dir, "src/fx/b.mojo", "beta");
    try put(tmp.dir, "bench/ring.mojo", "ring");
    // Not part of the sources: a file outside the library directory that no program names.
    try put(tmp.dir, "README.md", "not digested");

    const got = try digestOf(a, &tmp, "src/fx", &.{"bench/ring.mojo"});

    const text = try std.fmt.allocPrint(a, "{s} bench/ring.mojo\n{s} mopm.toml\n{s} src/fx/a.mojo\n{s} src/fx/b.mojo\n", .{
        hexOf("ring"), hexOf("the manifest"), hexOf("alpha"), hexOf("beta"),
    });
    try std.testing.expectEqualStrings(&hexOf(text), &got);
    // The same paths spelled with a trailing or leading './' give the same digest.
    try std.testing.expectEqualStrings(&(try digestOf(a, &tmp, "./src/fx/", &.{"./bench/ring.mojo"})), &got);
}

test "the digest is sorted by the bytes of the path, whatever the order the files were made in" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var one = std.testing.tmpDir(.{});
    defer one.cleanup();
    var two = std.testing.tmpDir(.{});
    defer two.cleanup();
    const files = [_][2][]const u8{
        .{ "src/fx/z.mojo", "z" },
        .{ "src/fx/B.mojo", "B" },
        .{ "src/fx/a/b.mojo", "ab" },
        .{ "src/fx/a.mojo", "a" },
        .{ "src/fx/a-b.mojo", "a-b" },
        .{ "mopm.toml", "m" },
    };
    for (files) |f| try put(one.dir, f[0], f[1]);
    var i: usize = files.len;
    while (i > 0) : (i -= 1) try put(two.dir, files[i - 1][0], files[i - 1][1]);
    const x = try digestOf(a, &one, "src/fx", &.{});
    try std.testing.expectEqualStrings(&x, &(try digestOf(a, &two, "src/fx", &.{})));

    // '-' (0x2d) sorts before '.' (0x2e) and '/' (0x2f); an upper case letter sorts before a lower case one.
    const text = try std.fmt.allocPrint(a, "{s} mopm.toml\n{s} src/fx/B.mojo\n{s} src/fx/a-b.mojo\n{s} src/fx/a.mojo\n{s} src/fx/a/b.mojo\n{s} src/fx/z.mojo\n", .{
        hexOf("m"), hexOf("B"), hexOf("a-b"), hexOf("a"), hexOf("ab"), hexOf("z"),
    });
    try std.testing.expectEqualStrings(&hexOf(text), &x);
}

test "a change of one byte of a source, of the manifest, or of a program changes the digest; a file's own name counts" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a.mojo", "a");
    try put(tmp.dir, "bin.mojo", "p");
    const base = try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"});
    try std.testing.expectEqualStrings(&base, &(try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"})));

    try put(tmp.dir, "src/fx/a.mojo", "b");
    const source = try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"});
    try put(tmp.dir, "src/fx/a.mojo", "a");
    try put(tmp.dir, "mopm.toml", "n");
    const manifest_changed = try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"});
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "bin.mojo", "q");
    const program = try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"});
    try put(tmp.dir, "bin.mojo", "p");
    try tmp.dir.rename("src/fx/a.mojo", "src/fx/c.mojo");
    const renamed = try digestOf(a, &tmp, "src/fx", &.{"bin.mojo"});
    const all = [_][]const u8{ &base, &source, &manifest_changed, &program, &renamed };
    for (all, 0..) |x, i| {
        for (all[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x, y));
    }
}

test "nested directories are walked, and a program source below the library directory is listed once" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a/b/c/deep.mojo", "deep");
    try put(tmp.dir, "src/fx/main.mojo", "main");
    try tmp.dir.makePath("src/fx/empty");

    const text = try std.fmt.allocPrint(a, "{s} mopm.toml\n{s} src/fx/a/b/c/deep.mojo\n{s} src/fx/main.mojo\n", .{ hexOf("m"), hexOf("deep"), hexOf("main") });
    try std.testing.expectEqualStrings(&hexOf(text), &(try digestOf(a, &tmp, "src/fx", &.{"src/fx/main.mojo"})));
    try std.testing.expectEqualStrings(&hexOf(text), &(try digestOf(a, &tmp, "src/fx", &.{})));
}

test "a symlink is read through, to a file or to a directory" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a.mojo", "a");
    try put(tmp.dir, "shared/util.mojo", "util");
    try put(tmp.dir, "shared/more/x.mojo", "x");
    try tmp.dir.symLink("../../shared/util.mojo", "src/fx/util.mojo", .{});
    try tmp.dir.symLink("../../shared/more", "src/fx/more", .{ .is_directory = true });

    const text = try std.fmt.allocPrint(a, "{s} mopm.toml\n{s} src/fx/a.mojo\n{s} src/fx/more/x.mojo\n{s} src/fx/util.mojo\n", .{ hexOf("m"), hexOf("a"), hexOf("x"), hexOf("util") });
    try std.testing.expectEqualStrings(&hexOf(text), &(try digestOf(a, &tmp, "src/fx", &.{})));
}

test "something that is neither a file nor a directory is refused, naming it" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a.mojo", "a");
    // A symlink to a device is read through to the device, which is not a source.
    try tmp.dir.symLink("/dev/null", "src/fx/null.mojo", .{});
    var why: []const u8 = "";
    try std.testing.expectError(error.Unreadable, compute(a, try tmp.dir.realpathAlloc(a, "."), "mopm.toml", "src/fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: src/fx/null.mojo is a character device, neither a file nor a directory; remove it, or move it out of the library directory", why);
}

test "a link that does not lead anywhere, and a link back into its own directory, are refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a.mojo", "a");
    try tmp.dir.symLink("missing.mojo", "src/fx/gone.mojo", .{});
    var why: []const u8 = "";
    try std.testing.expectError(error.Unreadable, compute(a, try tmp.dir.realpathAlloc(a, "."), "mopm.toml", "src/fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: cannot read src/fx/gone.mojo: FileNotFound", why);

    try tmp.dir.deleteFile("src/fx/gone.mojo");
    try tmp.dir.symLink("..", "src/fx/loop", .{ .is_directory = true });
    try std.testing.expectError(error.Unreadable, compute(a, try tmp.dir.realpathAlloc(a, "."), "mopm.toml", "src/fx", &.{}, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "nested more than 32 directories deep") != null);
}

test "a missing library directory is its own error, and a library that is a file, a missing manifest or program are refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    var why: []const u8 = "";
    try put(tmp.dir, "mopm.toml", "m");
    try std.testing.expectError(error.NoLibrary, compute(a, root, "mopm.toml", "src/fx", &.{}, &why));

    try put(tmp.dir, "src/fx", "a file, not a directory");
    try std.testing.expectError(error.Unreadable, compute(a, root, "mopm.toml", "src/fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: cannot open the library directory src/fx: NotDir", why);
    try tmp.dir.deleteFile("src/fx");

    try put(tmp.dir, "src/fx/a.mojo", "a");
    try std.testing.expectError(error.Unreadable, compute(a, root, "absent.toml", "src/fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: cannot read absent.toml: FileNotFound", why);
    try std.testing.expectError(error.Unreadable, compute(a, root, "mopm.toml", "src/fx", &.{"bin/gone.mojo"}, &why));
    try std.testing.expectEqualStrings("source digest: cannot read bin/gone.mojo: FileNotFound", why);
    try std.testing.expectError(error.Unreadable, compute(a, try std.fmt.allocPrint(a, "{s}/nowhere", .{root}), "mopm.toml", "src/fx", &.{}, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "source digest: cannot open "));
}

test "a path that leaves the package directory, is absolute or names nothing is refused" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try put(tmp.dir, "mopm.toml", "m");
    try put(tmp.dir, "src/fx/a.mojo", "a");
    var why: []const u8 = "";
    try std.testing.expectError(error.Unreadable, compute(a, root, "mopm.toml", "../fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: ../fx leaves the package directory", why);
    try std.testing.expectError(error.Unreadable, compute(a, root, "mopm.toml", "/abs/fx", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: /abs/fx is an absolute path; a package's files are named relative to its directory", why);
    try std.testing.expectError(error.Unreadable, compute(a, root, "mopm.toml", ".", &.{}, &why));
    try std.testing.expectEqualStrings("source digest: '.' names no file", why);
}

test "the library directory and the program sources come from the manifest" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var diag: manifest.Diagnostic = .{};
    const plain = try manifest.parse(a, "[package]\nname = \"example/fx\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n", &diag);
    try std.testing.expectEqualStrings("src/fx", try libraryDir(a, plain));
    try std.testing.expectEqual(@as(usize, 0), (try binPaths(a, plain)).len);
    const set = try manifest.parse(a, "[package]\nname = \"example/fx\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[targets]\nlib = { path = \"lib/fx\" }\nbins = [{ name = \"one\", path = \"b/one.mojo\" }, { name = \"two\", path = \"b/two.mojo\" }]\n", &diag);
    try std.testing.expectEqualStrings("lib/fx", try libraryDir(a, set));
    const bins = try binPaths(a, set);
    try std.testing.expectEqual(@as(usize, 2), bins.len);
    try std.testing.expectEqualStrings("b/one.mojo", bins[0]);
    try std.testing.expectEqualStrings("b/two.mojo", bins[1]);
}

test "ofPackage digests the manifest, the library directory and the programs the manifest names" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "[package]\nname = \"example/fx\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[targets]\nlib = { path = \"lib/fx\" }\nbins = [{ name = \"one\", path = \"b/one.mojo\" }]\n";
    try put(tmp.dir, "pkg/other.toml", text);
    try put(tmp.dir, "pkg/lib/fx/a.mojo", "a");
    try put(tmp.dir, "pkg/b/one.mojo", "one");
    try put(tmp.dir, "pkg/src/fx/ignored.mojo", "not the library directory this manifest names");
    var diag: manifest.Diagnostic = .{};
    const m = try manifest.parse(a, text, &diag);
    const dir = try tmp.dir.realpathAlloc(a, "pkg");

    const want = try std.fmt.allocPrint(a, "{s} b/one.mojo\n{s} lib/fx/a.mojo\n{s} other.toml\n", .{ hexOf("one"), hexOf("a"), hexOf(text) });
    // The manifest counts by its file name, wherever it is given from.
    const got = try ofPackage(a, m, dir, "pkg/other.toml");
    try std.testing.expectEqualStrings(&hexOf(want), &got.digest);

    // No library directory: no digest, and the note names the directory, the package and the version.
    try tmp.dir.deleteTree("pkg/lib");
    const none = try ofPackage(a, m, dir, "other.toml");
    try std.testing.expectEqualStrings("lib/fx", none.no_library);
    try std.testing.expectEqualStrings("note: lib/fx does not exist, so example/fx 1.0.0 carries no source digest; a build for another Mojo can then never be added to this version", try noLibraryNote(a, m, none.no_library));

    // A source that cannot be digested is reported with its reason.
    try put(tmp.dir, "pkg/lib/fx/a.mojo", "a");
    try tmp.dir.deleteFile("pkg/b/one.mojo");
    const bad = try ofPackage(a, m, dir, "other.toml");
    try std.testing.expectEqualStrings("source digest: cannot read b/one.mojo: FileNotFound", bad.bad);
}
