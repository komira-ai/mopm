//! The environment half of `mopm build`, for callers inside mopm: discover
//! the prefix, load every installed package's metadata, plan the native
//! libraries, and refuse what the plan or the disk does not allow. The
//! result builds the same `mojo build` command line `mopm build` runs
//! (mojo_cmd.construct), so `mopm test` links a test binary exactly as
//! `mopm build` links a program.
//!
//! The command-line `mopm build`/`run`/`repl` (src/cli/main.zig) performs
//! the same steps with the same wording; the messages here carry no
//! `mopm <command>:` prefix, the caller adds its own.

const std = @import("std");
const testroot = @import("testroot.zig");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");
const link_planner = @import("link_planner.zig");
const mojo_cmd = @import("mojo_cmd.zig");

pub const Toolchain = struct {
    /// Absolute environment prefix.
    prefix: []const u8,
    plan: link_planner.Plan,
};

pub const Prepared = union(enum) {
    ok: Toolchain,
    /// Why there is no usable environment: one message per line.
    refused: []const []const u8,
};

pub fn prepare(arena: Allocator, tool: mojo_cmd.Tool, flag: ?[]const u8, conda_prefix: ?[]const u8, modular_home: ?[]const u8) Allocator.Error!Prepared {
    const chosen = env.choosePrefix(flag, conda_prefix, modular_home) catch |e| return refuse(arena, switch (e) {
        error.NoPrefix => "no environment: pass --prefix <dir>, or run in an activated environment (CONDA_PREFIX or MODULAR_HOME)",
        error.BadModularHome => "MODULAR_HOME does not end in /share/max, so the environment prefix cannot be derived from it; pass --prefix <dir>",
    });
    const prefix = std.fs.cwd().realpathAlloc(arena, chosen.path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(arena, try std.fmt.allocPrint(arena, "environment {s} (from {s}) does not exist", .{ chosen.path, chosen.source.describe() })),
    };
    const paths = env.listMetadata(arena, prefix) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotAMojoEnv => return refuse(arena, try std.fmt.allocPrint(arena, "{s} (from {s}) has no lib/mojo: not a Mojo environment", .{ prefix, chosen.source.describe() })),
        else => return refuse(arena, try std.fmt.allocPrint(arena, "reading {s}/lib/mojo: {s}", .{ prefix, @errorName(e) })),
    };
    const inputs = switch (try env.loadAll(arena, paths)) {
        .ok => |v| v,
        .failed => |f| return refuse(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.path, @errorName(f.err) })),
    };
    const plan = try link_planner.plan(arena, inputs);
    var msgs = std.ArrayList([]const u8).init(arena);
    for (try mojo_cmd.refusals(arena, tool, plan)) |d| {
        try msgs.append(try std.fmt.allocPrint(arena, "refused ({s}): {s}", .{ @tagName(d.code), d.message }));
    }
    if (msgs.items.len == 0) {
        for (try env.missingFiles(arena, plan)) |m| {
            try msgs.append(try std.fmt.allocPrint(arena, "refused (missing_file): {s} is named by the installed metadata but is not on disk", .{m}));
        }
    }
    if (msgs.items.len > 0) return .{ .refused = try msgs.toOwnedSlice() };
    return .{ .ok = .{ .prefix = prefix, .plan = plan } };
}

fn refuse(arena: Allocator, msg: []const u8) Allocator.Error!Prepared {
    const one = try arena.alloc([]const u8, 1);
    one[0] = msg;
    return .{ .refused = one };
}

// ---------------------------------------------------------------- tests
// `zig build test` runs from the repository root (tests/fixtures); a runner
// elsewhere sets MOPM_SOURCE_ROOT (testroot.zig).

test "an environment with installed natives: the plan links them" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = switch (try prepare(a, .build, try testroot.path(a, "tests/fixtures/env/linux/chain"), null, null)) {
        .ok => |v| v,
        .refused => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.fs.path.isAbsolute(p.prefix));
    try std.testing.expect(p.plan.build.len > 0);
    const c = try mojo_cmd.construct(a, .{ .tool = .build, .prefix = p.prefix, .os = .linux, .file = "t.mojo", .out = "t", .flags = &.{ "-D", "ASSERT=all" } }, p.plan);
    try std.testing.expectEqualStrings("build", c.argv[1]);
    try std.testing.expectEqualStrings("-D", c.argv[2]);
    try std.testing.expectEqualStrings("ASSERT=all", c.argv[3]);
}

test "no environment, a missing one, and a directory that is not one are refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const cases = [_]struct { flag: ?[]const u8, want: []const u8 }{
        .{ .flag = null, .want = "no environment" },
        .{ .flag = "tests/fixtures/env/no-such-dir", .want = "does not exist" },
        .{ .flag = "tests/fixtures", .want = "not a Mojo environment" },
    };
    for (cases) |c| {
        const flag = if (c.flag) |f| try testroot.path(a, f) else null;
        switch (try prepare(a, .build, flag, null, null)) {
            .ok => return error.TestUnexpectedResult,
            .refused => |m| try std.testing.expect(std.mem.indexOf(u8, m[0], c.want) != null),
        }
    }
}
