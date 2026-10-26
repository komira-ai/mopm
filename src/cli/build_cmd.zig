//! `mopm build` for a package: the manifest's own targets, and the import directories of path dependencies.
//!
//! `mopm build <file.mojo> [-o <out>]` builds one program (src/cli/main.zig). `mopm build` with no program builds what
//! mopm.toml declares under `[targets]`, with the `mojo` of the environment (the one `mopm build <file>` runs, not the
//! unit graph of a build farm):
//!
//!   * the library, `lib = { path = "src/<name>" }`, with `mojo precompile` into `<out dir>/<package name>.mojoc`, the
//!     file `mopm pack --mojoc` takes;
//!   * each program of `bins = [{ name, path }]` with `mojo build` into `<out dir>/<name>`, linked the way `mopm build
//!     <file>` links (the native libraries of the environment, a run path to `<prefix>/lib`).
//!
//! The out dir is `target/build` unless `--out-dir <dir>` says otherwise. A step that fails ends the build with
//! that program's exit status; the steps already done stay. `--print-cmd` prints the command lines and writes nothing.
//!
//! Both forms pass `-I <dir>` for every path dependency (`name = { path = "../name" }` in [dependencies] or
//! [dev-dependencies], and theirs in turn): the directory that holds the dependency's library package directory, the
//! parent of its `[targets] lib` path, which is where `from name import f` finds the source. They are the same path
//! dependencies `mopm lock` and `mopm sync` read. A dependency without a `[targets] lib` offers nothing to import.
//! A program built from the package's own targets also gets the parent of the package's own `lib` path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const manifest = core.manifest;
const mojo_cmd = core.mojo_cmd;
const link_planner = core.link_planner;
const install_cmd = @import("install_cmd.zig");

/// Where `mopm build` with no program writes.
pub const default_out_dir = "target/build";

/// One compiler run of a build.
pub const Step = struct {
    /// "library app", "binary demo": for the progress line.
    what: []const u8,
    /// The file the step writes.
    out: []const u8,
    cmd: mojo_cmd.Command,
};

pub const Inputs = struct {
    /// `[package] name`.
    package: []const u8,
    targets: manifest.Targets,
    /// Absolute environment prefix.
    prefix: []const u8,
    os: mojo_cmd.Os,
    /// The import directories of the path dependencies.
    dep_dirs: []const []const u8,
    out_dir: []const u8,
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

/// The directory a library package directory is imported from: its parent.
fn parentOf(lib_path: []const u8) []const u8 {
    return std.fs.path.dirname(lib_path) orelse ".";
}

/// The steps that build `in.targets`, library first, then each program in manifest order. Pure: it touches no file.
pub fn steps(arena: Allocator, in: Inputs, plan: link_planner.Plan) Allocator.Error![]const Step {
    var out = std.ArrayList(Step).init(arena);
    if (in.targets.lib) |lib| {
        const dest = try std.fs.path.join(arena, &.{ in.out_dir, try std.fmt.allocPrint(arena, "{s}.mojoc", .{in.package}) });
        try out.append(.{
            .what = try std.fmt.allocPrint(arena, "library {s}", .{in.package}),
            .out = dest,
            .cmd = try mojo_cmd.constructLibrary(arena, .{ .prefix = in.prefix, .package_dir = lib, .include_dirs = in.dep_dirs, .out = dest }),
        });
    }
    var dirs = std.ArrayList([]const u8).init(arena);
    try dirs.appendSlice(in.dep_dirs);
    if (in.targets.lib) |lib| {
        if (!contains(dirs.items, parentOf(lib))) try dirs.append(parentOf(lib));
    }
    for (in.targets.bins) |bin| {
        const dest = try std.fs.path.join(arena, &.{ in.out_dir, bin.name });
        try out.append(.{
            .what = try std.fmt.allocPrint(arena, "binary {s}", .{bin.name}),
            .out = dest,
            .cmd = try mojo_cmd.construct(arena, .{
                .tool = .build,
                .prefix = in.prefix,
                .os = in.os,
                .file = bin.path,
                .out = dest,
                .include_dirs = dirs.items,
            }, plan),
        });
    }
    return out.toOwnedSlice();
}

/// The import directories of the path dependencies of `project`, written relative to the project directory as the
/// dependencies' paths are (`../dep/src`), without repeats, in the order the dependencies were found.
pub fn importDirs(arena: Allocator, project: install_cmd.Project) ![]const []const u8 {
    var dirs = std.ArrayList([]const u8).init(arena);
    for (project.paths) |p| {
        const file = try std.fs.path.join(arena, &.{ p.path, "mopm.toml" });
        const src = try std.fs.cwd().readFileAlloc(arena, file, 1 << 20);
        var diag: manifest.Diagnostic = .{};
        const m = manifest.parse(arena, src, &diag) catch |e| {
            if (e == error.Invalid) {
                std.io.getStdErr().writer().print("mopm build: {s}:{d}:{d}: {s}\n", .{ file, diag.pos.line, diag.pos.col, diag.message }) catch {};
            }
            return e;
        };
        const lib = m.targets.lib orelse continue;
        const dir = try std.fs.path.resolvePosix(arena, &.{ p.path, parentOf(lib) });
        if (!contains(dirs.items, dir)) try dirs.append(dir);
    }
    return dirs.toOwnedSlice();
}

/// The import directories of the project in the current directory: none when there is no mopm.toml (a program may
/// be built outside a package), null when the manifest or a path dependency cannot be read (reported).
pub fn importDirsHere(arena: Allocator) !?[]const []const u8 {
    const none: []const []const u8 = &.{};
    std.fs.cwd().access("mopm.toml", .{}) catch |e| {
        if (e == error.FileNotFound) return none;
    };
    const project = (try install_cmd.readProject(arena, .build)) orelse return null;
    return importDirs(arena, project) catch |e| {
        if (e != error.Invalid) std.io.getStdErr().writer().print("mopm build: reading a path dependency: {s}\n", .{@errorName(e)}) catch {};
        return null;
    };
}

pub const Options = struct {
    prefix: ?[]const u8 = null,
    os: mojo_cmd.Os,
    print_cmd: bool = false,
    out_dir: []const u8 = default_out_dir,
};

fn getEnv(arena: Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(arena, key) catch null;
}

/// `mopm build` with no program. The exit status.
pub fn run(arena: Allocator, o: Options) u8 {
    const err = std.io.getStdErr().writer();
    const project = (install_cmd.readProject(arena, .build) catch |e| {
        err.print("mopm build: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    }) orelse return 1;
    if (project.m.targets.lib == null and project.m.targets.bins.len == 0) {
        err.print("mopm build: mopm.toml declares no [targets] lib or bins, so there is nothing to build; name a program: mopm build <file.mojo>\n", .{}) catch {};
        return 1;
    }
    const tc = switch (core.autolink.prepare(arena, .build, o.prefix, getEnv(arena, "CONDA_PREFIX"), getEnv(arena, "MODULAR_HOME")) catch return 1) {
        .ok => |v| v,
        .refused => |msgs| {
            for (msgs) |m| err.print("mopm build: {s}\n", .{m}) catch {};
            return 1;
        },
    };
    const dep_dirs = importDirs(arena, project) catch |e| {
        if (e != error.Invalid) err.print("mopm build: reading a path dependency: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    const list = steps(arena, .{
        .package = project.m.package.name,
        .targets = project.m.targets,
        .prefix = tc.prefix,
        .os = o.os,
        .dep_dirs = dep_dirs,
        .out_dir = o.out_dir,
    }, tc.plan) catch return 1;

    if (o.print_cmd) {
        var buf = std.ArrayList(u8).init(arena);
        for (list) |s| mojo_cmd.render(s.cmd, buf.writer()) catch return 1;
        std.io.getStdOut().writeAll(buf.items) catch return 1;
        return 0;
    }
    std.fs.cwd().makePath(o.out_dir) catch |e| {
        err.print("mopm build: cannot make {s}: {s}\n", .{ o.out_dir, @errorName(e) }) catch {};
        return 1;
    };
    for (list) |s| {
        err.print("mopm build: {s} -> {s}\n", .{ s.what, s.out }) catch {};
        const code = exec(arena, s);
        if (code != 0) {
            err.print("mopm build: {s} failed (exit {d})\n", .{ s.what, code }) catch {};
            return code;
        }
    }
    return 0;
}

/// Runs a step with the caller's terminal and environment (and the step's own variables on top). Its exit status;
/// 127 when the compiler does not exist, 126 when it could not be run, 1 when it was killed by a signal.
fn exec(arena: Allocator, s: Step) u8 {
    const err = std.io.getStdErr().writer();
    var env_map = core.child_env.forChild(arena) catch return 1;
    mojo_cmd.applyEnv(&env_map, s.cmd.env) catch return 1;
    var child = std.ChildProcess.init(s.cmd.argv, arena);
    child.env_map = &env_map;
    const term = child.spawnAndWait() catch |e| {
        err.print("mopm build: cannot run {s}: {s}\n", .{ s.cmd.argv[0], @errorName(e) }) catch {};
        return if (e == error.FileNotFound) 127 else 126;
    };
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

// ---------------------------------------------------------------- tests

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "steps: the library with mojo precompile, then each binary with mojo build, both with the path dependencies' -I" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const list = try steps(a, .{
        .package = "app",
        .targets = .{ .lib = "src/app", .bins = &.{ .{ .name = "app", .path = "src/main.mojo" }, .{ .name = "tool", .path = "src/tool.mojo" } } },
        .prefix = "/e",
        .os = .linux,
        .dep_dirs = &.{"/w/greet/src"},
        .out_dir = "target/build",
    }, try link_planner.plan(a, &.{}));
    try std.testing.expectEqual(@as(usize, 3), list.len);

    try std.testing.expectEqualStrings("library app", list[0].what);
    try std.testing.expectEqualStrings("target/build/app.mojoc", list[0].out);
    try expectArgv(&.{ "/e/bin/mojo", "precompile", "-I", "/w/greet/src", "src/app", "-o", "target/build/app.mojoc" }, list[0].cmd.argv);

    try std.testing.expectEqualStrings("binary app", list[1].what);
    try std.testing.expectEqualStrings("target/build/app", list[1].out);
    try expectArgv(&.{
        "/e/bin/mojo", "build",
        "-I",          "/w/greet/src",
        "-I",          "src",
        "-Xlinker",    "-rpath",
        "-Xlinker",    "/e/lib",
        "-o",          "target/build/app",
        "src/main.mojo",
    }, list[1].cmd.argv);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-I", "/w/greet/src", "-I", "src", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "-o", "target/build/tool", "src/tool.mojo" }, list[2].cmd.argv);
}

test "steps: a library only, a binary only, and a package with neither" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const plan = try link_planner.plan(a, &.{});
    const base = Inputs{ .package = "p", .targets = .{}, .prefix = "/e", .os = .macos, .dep_dirs = &.{}, .out_dir = "o" };

    var only_lib = base;
    only_lib.targets = .{ .lib = "src/p" };
    const l = try steps(a, only_lib, plan);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try expectArgv(&.{ "/e/bin/mojo", "precompile", "src/p", "-o", "o/p.mojoc" }, l[0].cmd.argv);

    // A program with no library of its own imports from nothing but the dependencies.
    var only_bin = base;
    only_bin.targets = .{ .bins = &.{.{ .name = "p", .path = "main.mojo" }} };
    only_bin.dep_dirs = &.{"/d"};
    const b = try steps(a, only_bin, plan);
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-I", "/d", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "-o", "o/p", "main.mojo" }, b[0].cmd.argv);

    const none = try steps(a, base, plan);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "steps: the package's own source directory is not named twice, and a library at the root imports from ." {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const plan = try link_planner.plan(a, &.{});
    const same = try steps(a, .{
        .package = "p",
        .targets = .{ .lib = "src/p", .bins = &.{.{ .name = "p", .path = "src/main.mojo" }} },
        .prefix = "/e",
        .os = .linux,
        .dep_dirs = &.{"src"},
        .out_dir = "o",
    }, plan);
    var n: usize = 0;
    for (same[1].cmd.argv) |arg| {
        if (std.mem.eql(u8, arg, "-I")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);

    const root = try steps(a, .{ .package = "p", .targets = .{ .lib = "p", .bins = &.{.{ .name = "p", .path = "main.mojo" }} }, .prefix = "/e", .os = .linux, .dep_dirs = &.{}, .out_dir = "o" }, plan);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-I", ".", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "-o", "o/p", "main.mojo" }, root[1].cmd.argv);
}

test "steps: natives of the environment are linked into a binary and not into the library" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const metadata = core.metadata;
    const plan = try link_planner.plan(a, &.{.{ .dir = "/e/lib/mojo", .meta = try metadata.parse(a,
        \\{"schema": 1, "name": "s", "native": [{"id": "x", "soname": "libx.a", "kind": "static", "static_file": "../libx.a"}]}
    ) }});
    const list = try steps(a, .{
        .package = "p",
        .targets = .{ .lib = "src/p", .bins = &.{.{ .name = "p", .path = "src/main.mojo" }} },
        .prefix = "/e",
        .os = .linux,
        .dep_dirs = &.{},
        .out_dir = "o",
    }, plan);
    for (list[0].cmd.argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "libx.a") == null);
    var found = false;
    for (list[1].cmd.argv) |arg| found = found or std.mem.eql(u8, arg, "/e/lib/libx.a");
    try std.testing.expect(found);
}
