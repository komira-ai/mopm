//! Where `mopm sync` keeps the toolchain's files, and the check that this place
//! is not inside the environment `mopm sync` replaces.
//!
//! The cache directory is `--cache`, else `$XDG_CACHE_HOME/mopm/pkgs` when that
//! is set and not empty, else `$HOME/.cache/mopm/pkgs` (the places
//! core/repodata.zig keeps its cache in). Each file is kept at
//! `<cache>/<sha256>/<file name>`, so two projects that pin different bytes
//! under one file name never share an entry.
//!
//! `placementProblem` resolves the path (symlinks of its existing part
//! included) and refuses one that is `.mopm/env`, inside it, or inside the
//! `.mopm/.env.tmp-*` or `.mopm/.env.old-*` directory of an install in
//! progress: those are deleted or renamed by the install.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The cache directory for the given `--cache` value and environment values, or null when none of them gives one.
pub fn cacheDirOf(arena: Allocator, flag: ?[]const u8, xdg: ?[]const u8, home: ?[]const u8) Allocator.Error!?[]const u8 {
    if (flag) |f| return f;
    if (xdg) |x| {
        if (x.len > 0) return try std.fs.path.join(arena, &.{ x, "mopm", "pkgs" });
    }
    if (home) |h| {
        if (h.len > 0) return try std.fs.path.join(arena, &.{ h, ".cache", "mopm", "pkgs" });
    }
    return null;
}

/// `cacheDirOf` with the process environment.
pub fn cacheDir(arena: Allocator, flag: ?[]const u8) Allocator.Error!?[]const u8 {
    const xdg = std.process.getEnvVarOwned(arena, "XDG_CACHE_HOME") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    const home = std.process.getEnvVarOwned(arena, "HOME") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return cacheDirOf(arena, flag, xdg, home);
}

/// `path` (relative to the absolute directory `base`) with every symlink of its existing part resolved; what does not
/// exist yet is appended as written, with `.` and `..` applied.
fn canonical(arena: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    var cur: []const u8 = if (std.fs.path.isAbsolute(path)) "/" else base;
    var exists = true;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            cur = std.fs.path.dirname(cur) orelse "/";
            continue;
        }
        const next = try std.fs.path.join(arena, &.{ cur, part });
        if (exists) {
            if (std.fs.cwd().realpathAlloc(arena, next)) |real| {
                cur = real;
                continue;
            } else |_| {
                exists = false;
            }
        }
        cur = next;
    }
    return cur;
}

fn under(path: []const u8, dir: []const u8) bool {
    return std.mem.eql(u8, path, dir) or (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/');
}

/// Why `cache_path` (as given, relative to the project directory `project`) cannot be the cache directory of a sync
/// that replaces `<mopm_dir>/<env_name>`, or null when it can.
pub fn placementProblem(arena: Allocator, project: std.fs.Dir, mopm_dir: []const u8, env_name: []const u8, cache_path: []const u8) !?[]const u8 {
    const root = try project.realpathAlloc(arena, ".");
    const cache = try canonical(arena, root, cache_path);
    const dir = try canonical(arena, root, mopm_dir);
    const env = try std.fs.path.join(arena, &.{ dir, env_name });
    var refused = under(cache, env);
    if (under(cache, dir) and cache.len > dir.len) {
        const first = std.mem.sliceTo(cache[dir.len + 1 ..], '/');
        for ([_][]const u8{ "tmp", "old" }) |kind| {
            const marker = try std.fmt.allocPrint(arena, ".{s}.{s}-", .{ env_name, kind });
            refused = refused or std.mem.startsWith(u8, first, marker);
        }
    }
    if (!refused) return null;
    return try std.fmt.allocPrint(arena, "--cache {s} is inside {s}/{s}, which mopm sync replaces; use a directory outside it", .{ cache_path, mopm_dir, env_name });
}

// ---------------------------------------------------------------- tests

test "cacheDirOf: the flag, else a non-empty XDG_CACHE_HOME, else a non-empty HOME, else none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("flag", (try cacheDirOf(a, "flag", "/x", "/h")).?);
    try std.testing.expectEqualStrings("/x/mopm/pkgs", (try cacheDirOf(a, null, "/x", "/h")).?);
    try std.testing.expectEqualStrings("/h/.cache/mopm/pkgs", (try cacheDirOf(a, null, "", "/h")).?);
    try std.testing.expectEqualStrings("/h/.cache/mopm/pkgs", (try cacheDirOf(a, null, null, "/h")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try cacheDirOf(a, null, "", ""));
    try std.testing.expectEqual(@as(?[]const u8, null), try cacheDirOf(a, null, null, null));
}

test "cacheDir reads the environment the same way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("flag", (try cacheDir(a, "flag")).?);
    const xdg = std.process.getEnvVarOwned(a, "XDG_CACHE_HOME") catch null;
    const home = std.process.getEnvVarOwned(a, "HOME") catch null;
    const want = try cacheDirOf(a, null, xdg, home);
    const got = try cacheDir(a, null);
    try std.testing.expectEqual(want == null, got == null);
    if (want) |w| try std.testing.expectEqualStrings(w, got.?);
}

fn placement(a: Allocator, tmp: *std.testing.TmpDir, path: []const u8) !?[]const u8 {
    return placementProblem(a, tmp.dir, ".mopm", "env", path);
}

test "placementProblem: the environment, what is inside it and the directories of an install in progress are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".mopm/env/lib");
    try tmp.dir.makePath(".mopm/.env.tmp-ab12/x");
    try tmp.dir.makePath(".mopm/.env.old-cd34");
    try tmp.dir.makePath("elsewhere/cache");
    try tmp.dir.symLink("../.mopm/env/lib", "elsewhere/link", .{});
    try tmp.dir.symLink(".mopm", "alias", .{});
    const root = try tmp.dir.realpathAlloc(a, ".");

    for ([_][]const u8{
        ".mopm/env",
        ".mopm/env/lib",
        ".mopm/env/not/yet/there",
        "./.mopm/../.mopm/env/lib",
        "elsewhere/link",
        "elsewhere/link/sub",
        "alias/env/lib",
        ".mopm/.env.tmp-ab12",
        ".mopm/.env.tmp-ab12/x",
        ".mopm/.env.old-cd34",
        ".mopm/.env.old-new/inner",
        ".mopm/.env.tmp-later",
        try std.fs.path.join(a, &.{ root, ".mopm/env/lib" }),
    }) |path| {
        const why = (try placement(a, &tmp, path)) orelse {
            std.debug.print("accepted: {s}\n", .{path});
            return error.TestUnexpectedResult;
        };
        const want = try std.fmt.allocPrint(a, "--cache {s} is inside .mopm/env, which mopm sync replaces; use a directory outside it", .{path});
        try std.testing.expectEqualStrings(want, why);
    }
}

test "placementProblem: a directory outside the environment is accepted, existing or not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".mopm/env");
    try tmp.dir.makePath(".mopm/pkgs");
    try tmp.dir.makePath("elsewhere/cache");
    try tmp.dir.writeFile("afile", "x");
    const root = try tmp.dir.realpathAlloc(a, ".");
    for ([_][]const u8{
        "elsewhere/cache",
        "elsewhere/not/yet",
        "../sibling-of-the-project",
        ".mopm/pkgs",
        ".mopm/env2",
        ".mopm/.envx",
        ".mopm",
        ".",
        "afile/below",
        try std.fs.path.join(a, &.{ root, "elsewhere" }),
        "/",
    }) |path| {
        try std.testing.expectEqual(@as(?[]const u8, null), try placement(a, &tmp, path));
    }
}
