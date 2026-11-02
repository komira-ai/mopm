//! `mopm run --bin <package>:<program>`: run a program an installed package ships.
//!
//! A published package lists programs in `[targets] bins`; `mopm pack` and `mopm stage` ship each one as source at
//! `lib/mojo/<package>.bins/<program>.mojo` (src/core/bins.zig), and `mopm sync` installs it with the rest of the
//! package. This file turns `<package>:<program>` into that file, so `mopm run` runs it with the environment's
//! packages importable, built by the Mojo of the machine that runs it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const bins = core.bins;
const conda = core.conda;

pub const Ref = struct { package: []const u8, program: []const u8 };

/// A result that is a value or the reason there is none.
pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, bad: []const u8 };
}

const ref_usage = "--bin takes <package>:<program>, such as benchy:agg_state_bench";

fn validPackage(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// `<package>:<program>`, or why not. Both halves are names, never paths: nothing here can leave `lib/mojo`.
pub fn parseRef(arena: Allocator, text: []const u8) Allocator.Error!Result(Ref) {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{ .bad = try std.fmt.allocPrint(arena, "--bin {s}: {s}", .{ text, ref_usage }) };
    const package = text[0..colon];
    const program = text[colon + 1 ..];
    if (!validPackage(package)) return .{ .bad = try std.fmt.allocPrint(arena, "--bin {s}: '{s}' is not a package name; {s}", .{ text, package, ref_usage }) };
    if (!conda.validBinName(program)) return .{ .bad = try std.fmt.allocPrint(arena, "--bin {s}: '{s}' is not a program name (lower case letters, digits and underscores); {s}", .{ text, program, ref_usage }) };
    return .{ .ok = .{ .package = package, .program = program } };
}

/// The programs `package` ships in `prefix`, by name and sorted, or none.
fn shipped(arena: Allocator, prefix: []const u8, package: []const u8) Allocator.Error![]const []const u8 {
    const dir_path = try std.fmt.allocPrint(arena, "{s}/lib/mojo/{s}{s}", .{ prefix, package, bins.dir_suffix });
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close();
    var names = std.ArrayList([]const u8).init(arena);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, bins.source_suffix)) continue;
        try names.append(try arena.dupe(u8, entry.name[0 .. entry.name.len - bins.source_suffix.len]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

/// The source file of `ref` in the environment at `prefix` (absolute), given the names of the packages installed there
/// (`lib/mojo/<name>.mopm.json`): the package must be installed, and ship the program.
pub fn resolve(arena: Allocator, prefix: []const u8, installed: []const []const u8, ref: Ref) Allocator.Error!Result([]const u8) {
    var present = false;
    for (installed) |n| present = present or std.mem.eql(u8, n, ref.package);
    if (!present) {
        return .{ .bad = try std.fmt.allocPrint(arena, "package '{s}' is not installed in {s}; add it to mopm.toml and run 'mopm sync'", .{ ref.package, prefix }) };
    }
    const file = try std.fmt.allocPrint(arena, "{s}/lib/mojo/{s}{s}/{s}{s}", .{ prefix, ref.package, bins.dir_suffix, ref.program, bins.source_suffix });
    std.fs.cwd().access(file, .{}) catch {
        const have = try shipped(arena, prefix, ref.package);
        if (have.len == 0) return .{ .bad = try std.fmt.allocPrint(arena, "package '{s}' ships no programs", .{ref.package}) };
        return .{ .bad = try std.fmt.allocPrint(arena, "package '{s}' ships no program '{s}'; it ships: {s}", .{ ref.package, ref.program, try std.mem.join(arena, ", ", have) }) };
    };
    return .{ .ok = file };
}

// ---------------------------------------------------------------- tests

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

// Defect caught: a reference that names a path (and so a file outside the package's programs), or one with no program.
test "parseRef: <package>:<program>, and nothing that is a path" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const ok = (try parseRef(a, "benchy:agg_state_bench")).ok;
    try std.testing.expectEqualStrings("benchy", ok.package);
    try std.testing.expectEqualStrings("agg_state_bench", ok.program);
    try std.testing.expectEqualStrings("my-pkg", (try parseRef(a, "my-pkg:x1")).ok.package);
    const bad = [_][]const u8{ "benchy", "benchy:", ":prog", "../x:prog", "a/b:prog", "benchy:../prog", "benchy:a/b", "benchy:Prog", "benchy:a.mojo", "benchy:a:b" };
    for (bad) |text| {
        const r = try parseRef(a, text);
        try std.testing.expect(r == .bad);
        try std.testing.expect(std.mem.startsWith(u8, r.bad, "--bin "));
    }
}

fn writeFile(tmp: *std.testing.TmpDir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try tmp.dir.makePath(d);
    try tmp.dir.writeFile(path, bytes);
}

// Defect caught: a program resolved for a package that is not installed (a stray directory), the wrong file, or an
// unknown program answered with no hint of what the package ships.
test "resolve: the installed file of a shipped program, and a reason for each thing that is not" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, "lib/mojo/benchy.mopm.json", "{}");
    try writeFile(&tmp, "lib/mojo/benchy.bins/zeta.mojo", "z");
    try writeFile(&tmp, "lib/mojo/benchy.bins/alpha.mojo", "a");
    try writeFile(&tmp, "lib/mojo/benchy.bins/notes.txt", "n");
    try writeFile(&tmp, "lib/mojo/plain.mopm.json", "{}");
    // A directory of programs whose package is not installed.
    try writeFile(&tmp, "lib/mojo/ghost.bins/x.mojo", "x");
    const prefix = try tmp.dir.realpathAlloc(a, ".");
    const installed = [_][]const u8{ "benchy", "plain" };

    const got = (try resolve(a, prefix, &installed, .{ .package = "benchy", .program = "alpha" })).ok;
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/lib/mojo/benchy.bins/alpha.mojo", .{prefix}), got);

    const unknown = (try resolve(a, prefix, &installed, .{ .package = "benchy", .program = "nope" })).bad;
    try std.testing.expectEqualStrings("package 'benchy' ships no program 'nope'; it ships: alpha, zeta", unknown);
    const none = (try resolve(a, prefix, &installed, .{ .package = "plain", .program = "x" })).bad;
    try std.testing.expectEqualStrings("package 'plain' ships no programs", none);
    const ghost = (try resolve(a, prefix, &installed, .{ .package = "ghost", .program = "x" })).bad;
    try std.testing.expect(std.mem.startsWith(u8, ghost, "package 'ghost' is not installed in "));
}
