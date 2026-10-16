//! Environment discovery: which conda prefix a command works in, and which
//! installed packages it holds.
//!
//! The prefix comes from, in order: the `--prefix` flag; `CONDA_PREFIX` (set
//! by conda or pixi activation to the prefix itself); `MODULAR_HOME` (set by
//! the `mojo` package's activation to `<prefix>/share/max`, so the prefix is
//! derived from it); the environment `mopm sync` made in the current directory
//! (`.mopm/env`), if it is there. A flag beats an environment variable; an
//! empty variable counts as unset.
//!
//! The closure is every `<prefix>/lib/mojo/<name>.mopm.json`: the environment
//! was installed from the lock, so what is installed is the closure. Files are read in
//! name order so the plan does not depend on directory order.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const link_planner = @import("link_planner.zig");

pub const Source = enum {
    flag,
    conda_prefix,
    modular_home,
    /// `mopm sync`'s environment in the current directory.
    project_env,

    pub fn describe(self: Source) []const u8 {
        return switch (self) {
            .flag => "--prefix",
            .conda_prefix => "CONDA_PREFIX",
            .modular_home => "MODULAR_HOME",
            .project_env => "the project environment " ++ project_env_path,
        };
    }
};

pub const Prefix = struct {
    path: []const u8,
    source: Source,
};

pub const PrefixError = error{ NoPrefix, BadModularHome };

/// Where `mopm sync` puts the project's environment (core/install.zig `prefix`).
pub const project_env_path = ".mopm/env";

/// The tail `MODULAR_HOME` carries below the prefix.
pub const modular_home_tail = "/share/max";

fn given(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn trimSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

/// Pick the prefix: flag, then CONDA_PREFIX, then MODULAR_HOME minus
/// `/share/max`. A MODULAR_HOME of another shape is refused rather than guessed.
pub fn choosePrefix(flag: ?[]const u8, conda_prefix: ?[]const u8, modular_home: ?[]const u8) PrefixError!Prefix {
    if (given(flag)) |p| return .{ .path = p, .source = .flag };
    if (given(conda_prefix)) |p| return .{ .path = p, .source = .conda_prefix };
    if (given(modular_home)) |raw| {
        const h = trimSlashes(raw);
        if (!std.mem.endsWith(u8, h, modular_home_tail) or h.len == modular_home_tail.len) return error.BadModularHome;
        return .{ .path = h[0 .. h.len - modular_home_tail.len], .source = .modular_home };
    }
    return error.NoPrefix;
}

/// `choosePrefix`, and when nothing names an environment, the one `mopm sync`
/// made in the current directory (`.mopm/env`), if it is there:
/// after a sync, `mopm build`, `run` and `repl` need no flag and no activation.
/// `cwd` is the current directory (a parameter so a test need not change it). An environment that is named but wrong is still an error, never replaced.
pub fn choosePrefixOrProject(cwd: std.fs.Dir, flag: ?[]const u8, conda_prefix: ?[]const u8, modular_home: ?[]const u8) PrefixError!Prefix {
    return choosePrefix(flag, conda_prefix, modular_home) catch |e| {
        if (e != error.NoPrefix) return e;
        cwd.access(project_env_path ++ "/lib/mojo", .{}) catch return e;
        return .{ .path = project_env_path, .source = .project_env };
    };
}

pub const metadata_suffix = ".mopm.json";

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Paths of every `<prefix>/lib/mojo/<name>.mopm.json`, sorted by name.
/// `error.NotAMojoEnv` if `<prefix>/lib/mojo` is not a directory.
pub fn listMetadata(arena: Allocator, prefix: []const u8) ![]const []const u8 {
    const dir_path = try std.fs.path.join(arena, &.{ prefix, "lib", "mojo" });
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return error.NotAMojoEnv,
        else => return e,
    };
    defer dir.close();
    var names = std.ArrayList([]const u8).init(arena);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (entry.name.len <= metadata_suffix.len) continue;
        if (!std.mem.endsWith(u8, entry.name, metadata_suffix)) continue;
        try names.append(try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    const paths = try arena.alloc([]const u8, names.items.len);
    for (names.items, paths) |n, *p| p.* = try std.fs.path.join(arena, &.{ dir_path, n });
    return paths;
}

pub const Loaded = union(enum) {
    ok: []const link_planner.Input,
    failed: struct { path: []const u8, err: anyerror },
};

/// Read and parse every metadata file; the first failure is reported with
/// its path.
pub fn loadAll(arena: Allocator, paths: []const []const u8) Allocator.Error!Loaded {
    const inputs = try arena.alloc(link_planner.Input, paths.len);
    for (paths, inputs) |p, *inp| {
        inp.* = link_planner.loadInput(arena, p) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .{ .path = p, .err = e } },
        };
    }
    return .{ .ok = inputs };
}

/// Library files the plan names that are not on disk: every shared object
/// (the run and preload lists hold the same ones) and every static archive
/// passed by path to `mojo build`.
pub fn missingFiles(arena: Allocator, p: link_planner.Plan) Allocator.Error![]const []const u8 {
    var missing = std.ArrayList([]const u8).init(arena);
    for (p.run) |path| {
        std.fs.cwd().access(path, .{}) catch try missing.append(path);
    }
    for (p.build) |arg| {
        if (arg.len == 0 or arg[0] == '-') continue;
        std.fs.cwd().access(arg, .{}) catch try missing.append(arg);
    }
    return missing.toOwnedSlice();
}

// ---------------------------------------------------------------- tests

test "the flag beats CONDA_PREFIX, which beats MODULAR_HOME" {
    const p1 = try choosePrefix("/f", "/c", "/m/share/max");
    try std.testing.expectEqualStrings("/f", p1.path);
    try std.testing.expectEqual(Source.flag, p1.source);
    const p2 = try choosePrefix(null, "/c", "/m/share/max");
    try std.testing.expectEqualStrings("/c", p2.path);
    try std.testing.expectEqual(Source.conda_prefix, p2.source);
    const p3 = try choosePrefix(null, null, "/m/share/max");
    try std.testing.expectEqualStrings("/m", p3.path);
    try std.testing.expectEqual(Source.modular_home, p3.source);
}

test "with nothing named, the environment mopm sync made is used; a named one is never replaced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(project_env_path ++ "/lib/mojo");
    const p = try choosePrefixOrProject(tmp.dir, null, "", null);
    try std.testing.expectEqualStrings(project_env_path, p.path);
    try std.testing.expectEqual(Source.project_env, p.source);
    const named = try choosePrefixOrProject(tmp.dir, "/f", null, null);
    try std.testing.expectEqual(Source.flag, named.source);
    try std.testing.expectError(error.BadModularHome, choosePrefixOrProject(tmp.dir, null, null, "/m/other"));
}

test "an empty value counts as unset" {
    const p = try choosePrefix("", "", "/m/share/max/");
    try std.testing.expectEqualStrings("/m", p.path);
    try std.testing.expectError(error.NoPrefix, choosePrefix("", "", ""));
    try std.testing.expectError(error.NoPrefix, choosePrefix(null, null, null));
}

test "a MODULAR_HOME not ending in /share/max is refused, not guessed" {
    try std.testing.expectError(error.BadModularHome, choosePrefix(null, null, "/m/share"));
    try std.testing.expectError(error.BadModularHome, choosePrefix(null, null, "/share/max"));
    try std.testing.expectError(error.BadModularHome, choosePrefix(null, null, "/m/share/maxi"));
}

// Reads tests/fixtures under MOPM_SOURCE_ROOT, else relative to the working
// directory (the repository root, like the golden tests): testroot.zig.
test "discovery lists lib/mojo/*.mopm.json in name order and plans absolute paths" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const prefix = try std.fs.cwd().realpathAlloc(a, try testroot.path(a, "tests/fixtures/env/linux/chain"));
    const paths = try listMetadata(a, prefix);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "/lib/mojo/crypto.mopm.json"));
    try std.testing.expect(std.mem.endsWith(u8, paths[1], "/lib/mojo/http_client.mopm.json"));
    const loaded = try loadAll(a, paths);
    const p = try link_planner.plan(a, loaded.ok);
    try std.testing.expect(p.ok());
    const lib = try std.fs.path.join(a, &.{ prefix, "lib" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "-L{s}", .{lib}), p.build[0]);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ lib, "libcrypto_native.so.1" }), p.preload[0]);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ lib, "libcurl_shim.so.1" }), p.preload[1]);
    try std.testing.expectEqual(@as(usize, 0), (try missingFiles(a, p)).len);
}

test "a prefix without lib/mojo is not a Mojo environment" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectError(error.NotAMojoEnv, listMetadata(t.allocator(), try testroot.path(t.allocator(), "tests/fixtures/env")));
}

test "a library named by the metadata but absent from disk is reported" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const prefix = try std.fs.cwd().realpathAlloc(a, try testroot.path(a, "tests/fixtures/env/linux/nofile"));
    const loaded = try loadAll(a, try listMetadata(a, prefix));
    const p = try link_planner.plan(a, loaded.ok);
    try std.testing.expect(p.ok());
    const missing = try missingFiles(a, p);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ prefix, "lib", "libgone.so.1" }), missing[0]);
}
