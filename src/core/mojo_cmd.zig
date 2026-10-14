//! The stock `mojo` command lines behind `mopm build`, `mopm run` and
//! `mopm repl`, built from a link plan and an environment prefix.
//!
//! Facts it encodes (each one was observed on a real Mojo toolchain):
//!   * `mojo` needs `MODULAR_HOME=<prefix>/share/max`, which activation sets;
//!     without it the compiler cannot find `std`.
//!   * `mojo build`: the planned `-L`/`-l` (and archives by path) go through
//!     `-Xlinker`, plus an absolute run path to `<prefix>/lib`. mopm never
//!     sets the config's `shared_libs`: doing so drops the default run path.
//!   * `mojo run`: one `-Xlinker <shared object>` per library; preloading is
//!     ignored there and archives have no effect.
//!   * `mojo repl`: no `-Xlinker`; the shared objects go to the JIT process as
//!     `-O "settings set target.env-vars LD_PRELOAD=a:b"` (macOS:
//!     `DYLD_INSERT_LIBRARIES`). Every transitive library must be listed.

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
            for (p.build) |arg| try argv.appendSlice(&.{ "-Xlinker", arg });
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
                const libs = try std.mem.join(arena, ":", if (p.preload.len > 1) p.preload[0 .. p.preload.len - 1] else p.preload); // MUTANT: one transitive library dropped
                try argv.append("-O");
                try argv.append(try std.fmt.allocPrint(
                    arena,
                    "settings set target.env-vars {s}={s}",
                    .{ req.os.preloadVar(), libs },
                ));
            }
        },
    }
    const home = try std.fmt.allocPrint(arena, "MODULAR_HOME={s}{s}", .{ req.prefix, env.modular_home_tail });
    const envs = try arena.alloc([]const u8, 1);
    envs[0] = home;
    return .{ .env = envs, .argv = try argv.toOwnedSlice() };
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
        "-Xlinker",    "-L/e/lib",
        "-Xlinker",    "-lb",
        "-Xlinker",    "-la",
        "-Xlinker",    "-rpath",
        "-Xlinker",    "/e/lib",
        "-o",          "m",
        "m.mojo",
    }, c.argv);
    try expectArgv(&.{"MODULAR_HOME=/e/share/max"}, c.env);
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
    try expectArgv(&.{ "/e/bin/mojo", "build", "-Xlinker", "/e/lib/libx.a", "-Xlinker", "-rpath", "-Xlinker", "/e/lib", "m.mojo" }, c.argv);
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
