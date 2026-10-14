//! `mopm new` and `mopm init`: the files of a new package.
//!
//! A library package has a mopm.toml, the package's source directory
//! `src/<name>/` with its `__init__.mojo`, one test file, a README and a
//! .gitignore. `--bin` adds `src/main.mojo` and its `[targets] bins` entry.
//! Nothing is ever overwritten: `write` refuses before it writes anything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");

pub const Kind = enum { lib, bin };

/// The Mojo version a new package's `[toolchain]` names.
pub const default_mojo = "1.0.0";

/// One file of a new package; `path` is relative to the package root.
pub const File = struct { path: []const u8, contents: []const u8 };

const manifest_lib =
    \\[package]
    \\name = "@NAME@"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "@MOJO@"
    \\
    \\[dependencies]
    \\
    \\[targets]
    \\lib = { path = "src/@NAME@" }
    \\tests = ["tests"]
    \\
;

const manifest_bin =
    \\[package]
    \\name = "@NAME@"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "@MOJO@"
    \\
    \\[dependencies]
    \\
    \\[targets]
    \\lib = { path = "src/@NAME@" }
    \\bins = [{ name = "@NAME@", path = "src/main.mojo" }]
    \\tests = ["tests"]
    \\
;

const init_mojo =
    \\"""@NAME@: a Mojo package."""
    \\
    \\
    \\def greet(who: String) -> String:
    \\    """Returns a greeting for `who`."""
    \\    return "Hello, " + who + "!"
    \\
;

const main_mojo =
    \\from @NAME@ import greet
    \\
    \\
    \\def main():
    \\    print(greet("world"))
    \\
;

const test_mojo =
    \\from std.testing import TestSuite, assert_equal
    \\
    \\from @NAME@ import greet
    \\
    \\
    \\def test_greet() raises:
    \\    assert_equal(greet("Mojo"), "Hello, Mojo!")
    \\
    \\
    \\def main() raises:
    \\    TestSuite.discover_tests[__functions_in_module()]().run()
    \\
;

const readme_md =
    \\# @NAME@
    \\
    \\A Mojo package.
    \\
    \\```sh
    \\mopm build
    \\mopm test
    \\```
    \\
;

const gitignore =
    \\/.mopm/
    \\*.mojoc
    \\
;

fn fill(arena: Allocator, template: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const named = try std.mem.replaceOwned(u8, arena, template, "@NAME@", name);
    return try std.mem.replaceOwned(u8, arena, named, "@MOJO@", default_mojo);
}

/// The files of a new package called `name` (already checked with
/// `manifest.nameProblem`), in a fixed order.
pub fn files(arena: Allocator, name: []const u8, kind: Kind) Allocator.Error![]const File {
    var out = std.ArrayList(File).init(arena);
    const toml_template = switch (kind) {
        .lib => manifest_lib,
        .bin => manifest_bin,
    };
    try out.append(.{ .path = "mopm.toml", .contents = try fill(arena, toml_template, name) });
    try out.append(.{
        .path = try std.fmt.allocPrint(arena, "src/{s}/__init__.mojo", .{name}),
        .contents = try fill(arena, init_mojo, name),
    });
    if (kind == .bin) try out.append(.{ .path = "src/main.mojo", .contents = try fill(arena, main_mojo, name) });
    try out.append(.{
        .path = try std.fmt.allocPrint(arena, "tests/test_{s}.mojo", .{name}),
        .contents = try fill(arena, test_mojo, name),
    });
    try out.append(.{ .path = "README.md", .contents = try fill(arena, readme_md, name) });
    try out.append(.{ .path = ".gitignore", .contents = gitignore });
    return try out.toOwnedSlice();
}

/// The first of `fs` that already exists under `dir`, or null.
pub fn firstExisting(dir: std.fs.Dir, fs: []const File) ?[]const u8 {
    for (fs) |f| {
        dir.access(f.path, .{}) catch continue;
        return f.path;
    }
    return null;
}

/// Writes `fs` under `dir`. Call `firstExisting` first: a file that appeared
/// since then makes this fail rather than be overwritten.
pub fn write(dir: std.fs.Dir, fs: []const File) !void {
    for (fs) |f| {
        if (std.fs.path.dirname(f.path)) |parent| try dir.makePath(parent);
        const file = try dir.createFile(f.path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(f.contents);
    }
}

/// Compares `files(name, kind)` with the tree under `dir_path`, file by file,
/// and checks that the generated mopm.toml passes the manifest checks.
fn expectTree(dir_path: []const u8, kind: Kind) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fs = try files(arena, "demo", kind);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var on_disk: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        on_disk += 1;
        const path = try arena.dupe(u8, entry.path);
        var found = false;
        for (fs) |f| {
            if (std.mem.eql(u8, f.path, path)) found = true;
        }
        if (!found) {
            std.debug.print("{s}/{s} is not generated\n", .{ dir_path, path });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(fs.len, on_disk);
    for (fs) |f| {
        const want = dir.readFileAlloc(arena, f.path, 1 << 20) catch |e| {
            std.debug.print("{s}/{s}: {s}\n", .{ dir_path, f.path, @errorName(e) });
            return e;
        };
        std.testing.expectEqualStrings(want, f.contents) catch |e| {
            std.debug.print("generated {s} differs from {s}/{s}\n", .{ f.path, dir_path, f.path });
            return e;
        };
    }

    var diag: manifest.Diagnostic = .{};
    const m = manifest.parse(arena, fs[0].contents, &diag) catch |e| {
        std.debug.print("generated mopm.toml refused at {d}:{d}: {s}\n", .{ diag.pos.line, diag.pos.col, diag.message });
        return e;
    };
    try std.testing.expectEqualStrings("demo", m.package.name);
    try std.testing.expectEqual(@as(usize, if (kind == .bin) 1 else 0), m.targets.bins.len);
}

test "golden: a new library package equals tests/new/lib" {
    try expectTree("tests/new/lib", .lib);
}

test "golden: a new binary package equals tests/new/bin" {
    try expectTree("tests/new/bin", .bin);
}

test "an existing file is found before anything is written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const fs = try files(arena_state.allocator(), "demo", .lib);
    try std.testing.expect(firstExisting(tmp.dir, fs) == null);
    try tmp.dir.writeFile("README.md", "mine\n");
    try std.testing.expectEqualStrings("README.md", firstExisting(tmp.dir, fs).?);
    try std.testing.expectError(error.PathAlreadyExists, write(tmp.dir, fs));
    const kept = try tmp.dir.readFileAlloc(arena_state.allocator(), "README.md", 100);
    try std.testing.expectEqualStrings("mine\n", kept);
}
