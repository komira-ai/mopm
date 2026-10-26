//! The stock `mojo` command lines behind `mopm build`, `mopm run` and
//! `mopm repl`, built from a link plan and an environment prefix.
//!
//! Observed on a real Mojo toolchain (probes):
//!   * `mojo` needs `MODULAR_HOME=<prefix>/share/max`, which activation sets;
//!     without it the compiler cannot find `std`.
//!   * `mojo run` (P8/R1): one `-Xlinker <shared object>` per library;
//!     preloading is ignored there and archives have no effect.
//!   * `mojo repl` (R2, R5/R6): no `-Xlinker`; the shared objects go to the
//!     JIT process only, as `-O "settings set target.env-vars LD_PRELOAD=a:b"`
//!     (macOS: `DYLD_INSERT_LIBRARIES`, which the ad-hoc signed conda `mojo`
//!     honours). Every transitive library must be listed.
//!
//! Not probe-observed: the `mojo build` route. The probes proved `-Xlinker`
//! only for `mojo run`. mopm passes the planned `-L`/`-l` (and archives by
//! path) through `-Xlinker`, plus `-Xlinker -rpath -Xlinker <prefix>/lib`, and
//! never sets the config's `shared_libs` (doing so drops the default run
//! path). On Linux the planned libraries are linked with `--no-as-needed`
//! (inside `--push-state`/`--pop-state`), so the binary names a transitive
//! library it never calls. That route is proved by the end-to-end CI job
//! (PR #29), which builds a program against a fixture package, including one
//! that reaches a library only transitively, and runs the binary in an empty
//! environment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const link_planner = @import("link_planner.zig");
const env = @import("env.zig");

pub const Os = enum {
    linux,
    macos,

    pub fn host() Os {
        return if (@import("builtin").os.tag == .macos) .macos else .linux;
    }

    /// The loader's preload variable, as the REPL's JIT process reads it.
    pub fn preloadVar(self: Os) []const u8 {
        return switch (self) {
            .linux => "LD_PRELOAD",
            .macos => "DYLD_INSERT_LIBRARIES",
        };
    }
};

pub const Tool = enum { build, run, repl };

pub const Request = struct {
    tool: Tool,
    /// Absolute environment prefix.
    prefix: []const u8,
    os: Os,
    /// The program (build and run).
    file: []const u8 = "",
    /// `-o` for build; absent means mojo's default name.
    out: ?[]const u8 = null,
    /// Compiler options for build, placed right after `build` (`mopm test`
    /// passes `-D ASSERT=all --optimization-level 1`; `mopm build` none).
    flags: []const []const u8 = &.{},
    /// Import directories for build, one `-I <dir>` each, after `flags`: the directories that hold the package
    /// directories of path dependencies (and of the package itself), so `from dep import f` finds the source.
    include_dirs: []const []const u8 = &.{},
    /// repl: the debugserver lldb is pointed at, as `LLDB_DEBUGSERVER_PATH` in the child's environment (see
    /// debugserver.zig). Null leaves the environment as the caller had it.
    debugserver: ?[]const u8 = null,
};

/// The variable lldb reads to find the debugserver it starts.
pub const debugserver_var = "LLDB_DEBUGSERVER_PATH";

/// `mojo precompile`: one library package directory into a `.mojoc`.
pub const Library = struct {
    /// Absolute environment prefix.
    prefix: []const u8,
    /// The package directory (the one that holds `__init__.mojo`).
    package_dir: []const u8,
    /// One `-I <dir>` each: where the package's path dependencies are imported from.
    include_dirs: []const []const u8 = &.{},
    /// The `.mojoc` to write.
    out: []const u8,
};

pub const Command = struct {
    /// `NAME=value` pairs the child needs on top of the caller's environment.
    env: []const []const u8,
    argv: []const []const u8,
};

/// Whether a planner diagnostic stops `tool`.
pub fn blocks(tool: Tool, c: link_planner.Command) bool {
    return switch (c) {
        .all => true,
        .run => tool == .run,
        .repl => tool == .repl,
    };
}

/// The diagnostics that stop `tool`, in plan order.
pub fn refusals(arena: Allocator, tool: Tool, p: link_planner.Plan) Allocator.Error![]const link_planner.Diagnostic {
    var out = std.ArrayList(link_planner.Diagnostic).init(arena);
    for (p.diagnostics) |d| {
        if (blocks(tool, d.command)) try out.append(d);
    }
    return out.toOwnedSlice();
}

pub fn construct(arena: Allocator, req: Request, p: link_planner.Plan) Allocator.Error!Command {
    var argv = std.ArrayList([]const u8).init(arena);
    try argv.append(try std.fs.path.join(arena, &.{ req.prefix, "bin", "mojo" }));
    try argv.append(@tagName(req.tool));
    switch (req.tool) {
        .build => {
            try argv.appendSlice(req.flags);
            for (req.include_dirs) |dir| try argv.appendSlice(&.{ "-I", dir });
            // Linux: the binary itself must name every planned library
            // (DT_NEEDED). A transitive library (libinner, needed by
            // libouter) is found through the binary's run path only when
            // the binary names it, because a run path does not apply to
            // another library's needs; a linker running --as-needed drops
            // a library the program does not call directly. The state is
            // pushed and popped so that only the planned libraries change.
            const wrap = req.os == .linux and p.build.len > 0;
            if (wrap) try argv.appendSlice(&.{ "-Xlinker", "--push-state", "-Xlinker", "--no-as-needed" });
            for (p.build) |arg| try argv.appendSlice(&.{ "-Xlinker", arg });
            if (wrap) try argv.appendSlice(&.{ "-Xlinker", "--pop-state" });
            const lib = try std.fs.path.join(arena, &.{ req.prefix, "lib" });
            try argv.appendSlice(&.{ "-Xlinker", "-rpath", "-Xlinker", lib });
            if (req.out) |o| try argv.appendSlice(&.{ "-o", o });
            try argv.append(req.file);
        },
        .run => {
            for (p.run) |so| try argv.appendSlice(&.{ "-Xlinker", so });
            try argv.append(req.file);
        },
        .repl => {
            if (p.preload.len > 0) {
                const libs = try std.mem.join(arena, ":", p.preload);
                try argv.append("-O");
                try argv.append(try std.fmt.allocPrint(
                    arena,
                    "settings set target.env-vars {s}={s}",
                    .{ req.os.preloadVar(), libs },
                ));
            }
        },
    }
    var envs = std.ArrayList([]const u8).init(arena);
    try envs.append(try modularHome(arena, req.prefix));
    if (req.tool == .repl) {
        if (req.debugserver) |path| try envs.append(try std.fmt.allocPrint(arena, "{s}={s}", .{ debugserver_var, path }));
    }
    return .{ .env = try envs.toOwnedSlice(), .argv = try argv.toOwnedSlice() };
}

fn modularHome(arena: Allocator, prefix: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "MODULAR_HOME={s}{s}", .{ prefix, env.modular_home_tail });
}

/// `<prefix>/bin/mojo precompile [-I <dir>]... <package dir> -o <out>`: the library as `mopm pack` and `mopm
/// publish` take it (`--mojoc`). Like the unit graph's library unit it compiles the package directory whole.
pub fn constructLibrary(arena: Allocator, req: Library) Allocator.Error!Command {
    var argv = std.ArrayList([]const u8).init(arena);
    try argv.append(try std.fs.path.join(arena, &.{ req.prefix, "bin", "mojo" }));
    try argv.append("precompile");
    for (req.include_dirs) |dir| try argv.appendSlice(&.{ "-I", dir });
    try argv.appendSlice(&.{ req.package_dir, "-o", req.out });
    const envs = try arena.alloc([]const u8, 1);
    envs[0] = try modularHome(arena, req.prefix);
    return .{ .env = envs, .argv = try argv.toOwnedSlice() };
}

/// Put each `NAME=value` of `pairs` into `map`, replacing what the caller
/// had (a stale `MODULAR_HOME` from another environment loses).
pub fn applyEnv(map: *std.process.EnvMap, pairs: []const []const u8) Allocator.Error!void {
    for (pairs) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const value = if (eq < pair.len) pair[eq + 1 ..] else "";
        try map.put(pair[0..eq], value);
    }
}

fn shellSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-./=:,+@%", c) != null;
}

/// One word for a POSIX shell: bare if it needs no quoting, else in single
/// quotes.
pub fn writeWord(w: anytype, s: []const u8) !void {
    var bare = s.len > 0;
    for (s) |c| {
        if (!shellSafe(c)) {
            bare = false;
            break;
        }
    }
    if (bare) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// The command as one shell line: `NAME=value ... argv...`.
pub fn render(cmd: Command, w: anytype) !void {
    var first = true;
    for (cmd.env) |e| {
        if (!first) try w.writeByte(' ');
        first = false;
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse e.len;
        try w.writeAll(e[0..eq]);
        if (eq < e.len) {
            try w.writeByte('=');
            try writeWord(w, e[eq + 1 ..]);
        }
    }
    for (cmd.argv) |a| {
        if (!first) try w.writeByte(' ');
        first = false;
        try writeWord(w, a);
    }
    try w.writeByte('\n');
}

// ---------------------------------------------------------------- tests

const metadata = @import("metadata.zig");

fn chainPlan(a: Allocator, os: Os) !link_planner.Plan {
    const so = switch (os) {
        .linux => [_][]const u8{ "libb.so.1", "liba.so.1" },
        .macos => [_][]const u8{ "libb.1.dylib", "liba.1.dylib" },
    };
    const b = try std.fmt.allocPrint(a,
        \\{{"schema": 1, "name": "b", "native": [{{"id": "b", "soname": "{s}", "file": "../{s}"}}]}}
    , .{ so[0], so[0] });
    const ap = try std.fmt.allocPrint(a,
        \\{{"schema": 1, "name": "a", "deps": [{{"name": "b"}}], "native": [
        \\  {{"id": "a", "soname": "{s}", "file": "../{s}", "needs": ["{s}"]}}]}}
    , .{ so[1], so[1], so[0] });
    return link_planner.plan(a, &.{
        .{ .dir = "/e/lib/mojo", .meta = try metadata.parse(a, b) },
        .{ .dir = "/e/lib/mojo", .meta = try metadata.parse(a, ap) },
    });
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "build: planned -L/-l through -Xlinker plus an absolute run path to <prefix>/lib" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .linux);
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .linux, .file = "m.mojo", .out = "m" }, p);
    try expectArgv(&.{
        "/e/bin/mojo", "build",
        "-Xlinker",    "--push-state",
        "-Xlinker",    "--no-as-needed",
        "-Xlinker",    "-L/e/lib",
        "-Xlinker",    "-lb",
        "-Xlinker",    "-la",
        "-Xlinker",    "--pop-state",
        "-Xlinker",    "-rpath",
        "-Xlinker",    "/e/lib",
        "-o",          "m",
        "m.mojo",
    }, c.argv);
    try expectArgv(&.{"MODULAR_HOME=/e/share/max"}, c.env);
}

test "build: compiler flags come right after build, before the link arguments" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try link_planner.plan(a, &.{});
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .linux, .file = "t.mojo", .out = "t", .flags = &.{ "-D", "ASSERT=all", "--optimization-level", "1" } }, p);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-D", "ASSERT=all", "--optimization-level", "1", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "-o", "t", "t.mojo" }, c.argv);
}

test "build: macOS gets no --as-needed state (ld64 has no such flag; @rpath reaches transitive libraries)" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .macos);
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .macos, .file = "m.mojo" }, p);
    for (c.argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "as-needed") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "-state") == null);
    }
}

test "build: the run path is there even with no natives, and -o is optional" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try link_planner.plan(a, &.{});
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .macos, .file = "m.mojo" }, p);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "m.mojo" }, c.argv);
}

test "build: a static archive is passed by path" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try link_planner.plan(a, &.{.{ .dir = "/e/lib/mojo", .meta = try metadata.parse(a,
        \\{"schema": 1, "name": "s", "native": [{"id": "x", "soname": "libx.a", "kind": "static", "static_file": "../libx.a"}]}
    ) }});
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .linux, .file = "m.mojo" }, p);
    try expectArgv(&.{ "/e/bin/mojo", "build", "-Xlinker", "--push-state", "-Xlinker", "--no-as-needed", "-Xlinker", "/e/lib/libx.a", "-Xlinker", "--pop-state", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "m.mojo" }, c.argv);
    try std.testing.expectEqual(@as(usize, 0), (try refusals(a, .build, p)).len);
    try std.testing.expectEqual(@as(usize, 1), (try refusals(a, .run, p)).len);
    try std.testing.expectEqual(@as(usize, 1), (try refusals(a, .repl, p)).len);
}

test "run: one -Xlinker per shared object, the program last" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .macos);
    const c = try construct(a, .{ .tool = .run, .prefix = "/e", .os = .macos, .file = "m.mojo" }, p);
    try expectArgv(&.{ "/e/bin/mojo", "run", "-Xlinker", "/e/lib/libb.1.dylib", "-Xlinker", "/e/lib/liba.1.dylib", "m.mojo" }, c.argv);
}

test "repl: every transitive library in LD_PRELOAD on Linux" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .linux);
    const c = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .linux }, p);
    try expectArgv(&.{ "/e/bin/mojo", "repl", "-O", "settings set target.env-vars LD_PRELOAD=/e/lib/libb.so.1:/e/lib/liba.so.1" }, c.argv);
}

test "repl: DYLD_INSERT_LIBRARIES on macOS" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .macos);
    const c = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .macos }, p);
    try expectArgv(&.{ "/e/bin/mojo", "repl", "-O", "settings set target.env-vars DYLD_INSERT_LIBRARIES=/e/lib/libb.1.dylib:/e/lib/liba.1.dylib" }, c.argv);
}

test "repl: nothing to preload, no -O" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .linux }, try link_planner.plan(a, &.{}));
    try expectArgv(&.{ "/e/bin/mojo", "repl" }, c.argv);
}

test "build: one -I per import directory, in order, after the compiler flags and before the link arguments" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try chainPlan(a, .linux);
    const c = try construct(a, .{
        .tool = .build,
        .prefix = "/e",
        .os = .linux,
        .file = "m.mojo",
        .out = "m",
        .flags = &.{ "-D", "X=1" },
        .include_dirs = &.{ "/w/dep_a/src", "/w/dep_b/src" },
    }, p);
    try expectArgv(&.{
        "/e/bin/mojo", "build",
        "-D",          "X=1",
        "-I",          "/w/dep_a/src",
        "-I",          "/w/dep_b/src",
        "-Xlinker",    "--push-state",
        "-Xlinker",    "--no-as-needed",
        "-Xlinker",    "-L/e/lib",
        "-Xlinker",    "-lb",
        "-Xlinker",    "-la",
        "-Xlinker",    "--pop-state",
        "-Xlinker",    "-rpath",
        "-Xlinker",    "/e/lib",
        "-o",          "m",
        "m.mojo",
    }, c.argv);
}

test "build: without import directories the command line has no -I" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c = try construct(a, .{ .tool = .build, .prefix = "/e", .os = .linux, .file = "m.mojo" }, try link_planner.plan(a, &.{}));
    for (c.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "-I"));
}

test "library: mojo precompile with one -I per import directory, the package directory, then -o" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c = try constructLibrary(a, .{ .prefix = "/e", .package_dir = "src/app", .include_dirs = &.{ "/w/dep/src", "/w/other/src" }, .out = "target/build/app.mojoc" });
    try expectArgv(&.{ "/e/bin/mojo", "precompile", "-I", "/w/dep/src", "-I", "/w/other/src", "src/app", "-o", "target/build/app.mojoc" }, c.argv);
    try expectArgv(&.{"MODULAR_HOME=/e/share/max"}, c.env);
    const bare = try constructLibrary(a, .{ .prefix = "/e", .package_dir = "src/app", .out = "app.mojoc" });
    try expectArgv(&.{ "/e/bin/mojo", "precompile", "src/app", "-o", "app.mojoc" }, bare.argv);
}

test "repl: a debugserver is LLDB_DEBUGSERVER_PATH in the child's environment, and only for repl" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try link_planner.plan(a, &.{});
    const c = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .macos, .debugserver = "/x/debugserver" }, p);
    try expectArgv(&.{ "MODULAR_HOME=/e/share/max", "LLDB_DEBUGSERVER_PATH=/x/debugserver" }, c.env);
    try expectArgv(&.{ "/e/bin/mojo", "repl" }, c.argv);
    // Without one the environment is as before.
    const none = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .macos }, p);
    try expectArgv(&.{"MODULAR_HOME=/e/share/max"}, none.env);
    // build and run never carry it.
    for ([_]Tool{ .build, .run }) |tool| {
        const other = try construct(a, .{ .tool = tool, .prefix = "/e", .os = .macos, .file = "m.mojo", .debugserver = "/x/debugserver" }, p);
        try expectArgv(&.{"MODULAR_HOME=/e/share/max"}, other.env);
    }
}

test "render: the debugserver variable shows in the printed command, quoted when it needs it" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const c = try construct(a, .{ .tool = .repl, .prefix = "/e", .os = .macos, .debugserver = "/Applications/Xcode 15.app/debugserver" }, try link_planner.plan(a, &.{}));
    var buf = std.ArrayList(u8).init(a);
    try render(c, buf.writer());
    try std.testing.expectEqualStrings("MODULAR_HOME=/e/share/max LLDB_DEBUGSERVER_PATH='/Applications/Xcode 15.app/debugserver' /e/bin/mojo repl\n", buf.items);
}

test "a diagnostic for all stops every command; run and repl ones stop only theirs" {
    try std.testing.expect(blocks(.build, .all));
    try std.testing.expect(blocks(.run, .all));
    try std.testing.expect(blocks(.repl, .all));
    try std.testing.expect(!blocks(.build, .run));
    try std.testing.expect(!blocks(.build, .repl));
    try std.testing.expect(!blocks(.run, .repl));
    try std.testing.expect(!blocks(.repl, .run));
}

test "render quotes only words that need it" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    var buf = std.ArrayList(u8).init(a);
    try render(.{
        .env = &.{"MODULAR_HOME=/e x/share/max"},
        .argv = &.{ "/e/bin/mojo", "repl", "-O", "settings set target.env-vars LD_PRELOAD=/e/lib/it's.so" },
    }, buf.writer());
    try std.testing.expectEqualStrings(
        "MODULAR_HOME='/e x/share/max' /e/bin/mojo repl -O 'settings set target.env-vars LD_PRELOAD=/e/lib/it'\\''s.so'\n",
        buf.items,
    );
}

test "applyEnv overrides the caller's value and keeps the rest" {
    var map = std.process.EnvMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("MODULAR_HOME", "/other/share/max");
    try map.put("PATH", "/usr/bin");
    try applyEnv(&map, &.{ "MODULAR_HOME=/e/share/max", "EMPTY=" });
    try std.testing.expectEqualStrings("/e/share/max", map.get("MODULAR_HOME").?);
    try std.testing.expectEqualStrings("/usr/bin", map.get("PATH").?);
    try std.testing.expectEqualStrings("", map.get("EMPTY").?);
    try std.testing.expectEqual(@as(std.process.EnvMap.Size, 3), map.count());
}
