//! The programs a package ships: `[targets] bins` of a published package, as source.
//!
//! A package lists programs in `[targets] bins = [{ name = "fetch", path = "src/fetch.mojo" }]`. `mopm pack` and
//! `mopm stage` put the Mojo file of each one in the package at `lib/mojo/<package>.bins/<name>.mojo`; they never
//! pack an executable (the registry refuses one, and a program built on one machine would not run on another). The
//! program is built where it is used: `mopm run --bin <package>:<name>` runs that file with the environment's
//! packages importable (src/cli/bin_run.zig).
//!
//! This file reads the sources out of a package directory and refuses what the registry would refuse later.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const conda = @import("conda.zig");

pub const ReadError = error{ Unpackable, OutOfMemory };

/// The directory of a package's program sources inside the package, below `lib/mojo/`, and the file's suffix.
pub const dir_suffix = ".bins";
pub const source_suffix = ".mojo";

/// Why `path` cannot be the Mojo file of a program: it must stay inside the package directory and name a `.mojo` file.
fn pathProblem(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "has an empty path";
    if (std.fs.path.isAbsolute(path)) return "has an absolute path; it is relative to the manifest";
    if (!std.mem.endsWith(u8, path, source_suffix)) return "is not a .mojo file";
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return "has a path that leaves the package directory";
    }
    return null;
}

/// The sources of `m`'s `[targets] bins`, read from below `dir` (the directory of the manifest), in manifest order.
/// `error.Unpackable` with `why` when one cannot be shipped: a name the registry would refuse, a name used twice, a
/// path outside `dir` or not a `.mojo` file, or a file that is missing or empty.
pub fn read(arena: Allocator, m: manifest.Manifest, dir: []const u8, why: *[]const u8) ReadError![]const conda.Bin {
    var out = std.ArrayList(conda.Bin).init(arena);
    for (m.targets.bins, 0..) |b, i| {
        if (!conda.validBinName(b.name)) {
            why.* = try std.fmt.allocPrint(arena, "[targets] bin '{s}': a program's name is lower case letters, digits and underscores, so that it can be the file name '<name>.mojo' in the package", .{b.name});
            return error.Unpackable;
        }
        for (m.targets.bins[0..i]) |other| {
            if (std.mem.eql(u8, other.name, b.name)) {
                why.* = try std.fmt.allocPrint(arena, "[targets] bin '{s}' is declared twice", .{b.name});
                return error.Unpackable;
            }
        }
        if (pathProblem(b.path)) |p| {
            why.* = try std.fmt.allocPrint(arena, "[targets] bin '{s}' {s} ('{s}')", .{ b.name, p, b.path });
            return error.Unpackable;
        }
        const file = try std.fs.path.join(arena, &.{ dir, b.path });
        const bytes = std.fs.cwd().readFileAlloc(arena, file, 1 << 24) catch |e| {
            why.* = try std.fmt.allocPrint(arena, "[targets] bin '{s}': cannot read {s}: {s}", .{ b.name, file, @errorName(e) });
            return error.Unpackable;
        };
        if (bytes.len == 0) {
            why.* = try std.fmt.allocPrint(arena, "[targets] bin '{s}': {s} is empty", .{ b.name, file });
            return error.Unpackable;
        }
        try out.append(.{ .name = b.name, .source = bytes });
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const unpack = @import("conda_unpack.zig");

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn parseWith(a: Allocator, bins: []const u8) !manifest.Manifest {
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(a, try std.fmt.allocPrint(a,
        \\[package]
        \\name = "benchy"
        \\version = "1.0.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[targets]
        \\bins = [{s}]
        \\
    , .{bins}), &diag);
}

fn writeTree(tmp: *std.testing.TmpDir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.makePath(d);
        try tmp.dir.writeFile(f[0], f[1]);
    }
}

// Defect caught: the sources of the declared programs are not the bytes that get packed, or come in another order.
test "read: the sources of the declared programs, in manifest order, from below the manifest directory" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTree(&tmp, &.{ .{ "src/zeta.mojo", "def main(): print(\"zeta\")\n" }, .{ "tools/alpha.mojo", "def main(): print(\"alpha\")\n" } });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const m = try parseWith(a, "{ name = \"zeta_bench\", path = \"src/zeta.mojo\" }, { name = \"alpha\", path = \"tools/alpha.mojo\" }");
    var why: []const u8 = "";
    const got = try read(a, m, root, &why);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("zeta_bench", got[0].name);
    try std.testing.expectEqualStrings("def main(): print(\"zeta\")\n", got[0].source);
    try std.testing.expectEqualStrings("alpha", got[1].name);
    try std.testing.expectEqualStrings("def main(): print(\"alpha\")\n", got[1].source);
    // No bins, nothing to ship.
    const none = try read(a, try parseWith(a, ""), root, &why);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

// Defect caught: a declaration that the registry would refuse (or that reads outside the package) is packed anyway.
test "read: a name, a path or a file that cannot be shipped is refused with the reason" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTree(&tmp, &.{ .{ "src/a.mojo", "def main(): pass\n" }, .{ "src/empty.mojo", "" }, .{ "src/notes.txt", "x" } });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const Case = struct { bins: []const u8, why: []const u8 };
    const cases = [_]Case{
        .{ .bins = "{ name = \"Bench\", path = \"src/a.mojo\" }", .why = "[targets] bin 'Bench': a program's name is lower case letters, digits and underscores, so that it can be the file name '<name>.mojo' in the package" },
        .{ .bins = "{ name = \"a-b\", path = \"src/a.mojo\" }", .why = "[targets] bin 'a-b': a program's name is lower case letters, digits and underscores, so that it can be the file name '<name>.mojo' in the package" },
        .{ .bins = "{ name = \"a\", path = \"src/a.mojo\" }, { name = \"a\", path = \"src/a.mojo\" }", .why = "[targets] bin 'a' is declared twice" },
        .{ .bins = "{ name = \"a\", path = \"../a.mojo\" }", .why = "[targets] bin 'a' has a path that leaves the package directory ('../a.mojo')" },
        .{ .bins = "{ name = \"a\", path = \"src/../../a.mojo\" }", .why = "[targets] bin 'a' has a path that leaves the package directory ('src/../../a.mojo')" },
        .{ .bins = "{ name = \"a\", path = \"/etc/a.mojo\" }", .why = "[targets] bin 'a' has an absolute path; it is relative to the manifest ('/etc/a.mojo')" },
        .{ .bins = "{ name = \"a\", path = \"src/notes.txt\" }", .why = "[targets] bin 'a' is not a .mojo file ('src/notes.txt')" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        try std.testing.expectError(error.Unpackable, read(a, try parseWith(a, c.bins), root, &why));
        try std.testing.expectEqualStrings(c.why, why);
    }
    var why: []const u8 = "";
    try std.testing.expectError(error.Unpackable, read(a, try parseWith(a, "{ name = \"gone\", path = \"src/gone.mojo\" }"), root, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "[targets] bin 'gone': cannot read "));
    try std.testing.expect(std.mem.endsWith(u8, why, "FileNotFound"));
    try std.testing.expectError(error.Unpackable, read(a, try parseWith(a, "{ name = \"e\", path = \"src/empty.mojo\" }"), root, &why));
    try std.testing.expect(std.mem.endsWith(u8, why, "src/empty.mojo is empty"));
}

// Defect caught: a program lands at a path the registry's layout does not allow, is dropped from the file, or makes the
// file differ between two packs of the same input.
test "pack: a program is at lib/mojo/<name>.bins/<bin>.mojo, the same bytes twice, and a package without one is unchanged" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const window = try std.testing.allocator.alloc(u8, unpack.window_size);
    defer std.testing.allocator.free(window);
    const bins = [_]conda.Bin{
        .{ .name = "spsc_ring_bench", .source = "def main(): print(1)\n" },
        .{ .name = "agg_state_bench", .source = "def main(): print(2)\n" },
    };
    const base = conda.Input{ .name = "benchy", .version = "1.0.0", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "MOJOC" };
    var with = base;
    with.bins = &bins;
    const p1 = try conda.pack(a, with);
    const p2 = try conda.pack(a, with);
    try std.testing.expectEqualSlices(u8, p1.bytes, p2.bytes);
    const reversed = [_]conda.Bin{ bins[1], bins[0] };
    with.bins = &reversed;
    try std.testing.expectEqualSlices(u8, p1.bytes, (try conda.pack(a, with)).bytes);
    // The same package with no programs is not the same file, and its bytes are what an empty list gives.
    const plain = try conda.pack(a, base);
    try std.testing.expect(!std.mem.eql(u8, plain.bytes, p1.bytes));
    var empty = base;
    empty.bins = &.{};
    try std.testing.expectEqualSlices(u8, plain.bytes, (try conda.pack(a, empty)).bytes);

    var diag = unpack.Diag{};
    const got = try unpack.readFiles(a, p1.bytes, window, &.{ "lib/mojo/benchy.bins/spsc_ring_bench.mojo", "lib/mojo/benchy.bins/agg_state_bench.mojo", "lib/mojo/benchy.bins/other.mojo", "lib/mojo/benchy.mojoc" }, &diag);
    try std.testing.expectEqualStrings("def main(): print(1)\n", got[0].?);
    try std.testing.expectEqualStrings("def main(): print(2)\n", got[1].?);
    try std.testing.expect(got[2] == null);
    try std.testing.expectEqualStrings("MOJOC", got[3].?);
}

// Defect caught: the packer accepts a program the registry's layout rule refuses (so a publish fails after staging).
test "pack: a program with a name the registry refuses, a name used twice or no source is not packed" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const base = conda.Input{ .name = "benchy", .version = "1.0.0", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "MOJOC" };
    const bad = [_][]const conda.Bin{
        &.{.{ .name = "Upper", .source = "x" }},
        &.{.{ .name = "has-dash", .source = "x" }},
        &.{.{ .name = "../up", .source = "x" }},
        &.{.{ .name = "", .source = "x" }},
        &.{.{ .name = "empty_source", .source = "" }},
        &.{ .{ .name = "twice", .source = "x" }, .{ .name = "twice", .source = "y" } },
    };
    for (bad) |bins| {
        var in = base;
        in.bins = bins;
        try std.testing.expectError(error.BadBin, conda.pack(a, in));
    }
}

// Defect caught: an install that drops the program, or puts it where `mopm run --bin` does not look.
test "install: the program is unpacked at lib/mojo/<package>.bins/<bin>.mojo of the environment" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const window = try std.testing.allocator.alloc(u8, unpack.window_size);
    defer std.testing.allocator.free(window);
    const source = "def main(): print(\"bench\")\n";
    const packed_ = try conda.pack(a, .{ .name = "benchy", .version = "1.0.0", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "MOJOC", .bins = &.{.{ .name = "agg_state_bench", .source = source }} });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("pkgs");
    try tmp.dir.writeFile(packed_.file_name, packed_.bytes);
    try tmp.dir.makePath("env");
    var env = try tmp.dir.openDir("env", .{});
    defer env.close();
    var file = try tmp.dir.openFile(packed_.file_name, .{});
    defer file.close();
    var links = std.StringHashMap(void).init(a);
    var diag = unpack.Diag{};
    _ = try unpack.install(a, file, .{ .prefix = "/env", .dest = env, .window = window, .links = &links }, &diag);
    try std.testing.expectEqualStrings(source, try env.readFileAlloc(a, "lib/mojo/benchy.bins/agg_state_bench.mojo", 1 << 20));
    try std.testing.expectEqualStrings("MOJOC", try env.readFileAlloc(a, "lib/mojo/benchy.mojoc", 1 << 20));
}
