//! `mopm unit build` and `mopm unit test`: one unit of a unit graph, offline,
//! from declared inputs only (spec/unit-graph.md, "Running a unit"). The work
//! is in core/unit_run.zig; this file reads the options and the graph.
//!
//! Exit status: 0 built (and, for a test, passed); 1 any other failure; 2 a
//! usage error; 4 a refusal (an input is missing or is not what the graph
//! declares, the toolchain is not the pinned closure, the unit is unknown);
//! otherwise the exit code of the compiler or of the test that failed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");

pub const exit_usage: u8 = 2;
pub const exit_refused: u8 = 4;

pub const usage =
    \\usage: mopm unit build --unit <id> --graph <file> --out <dir> --toolchain <dir> [options]
    \\       mopm unit test  --unit <id> --graph <file> --out <dir> --toolchain <dir> [options]
    \\
    \\  build one unit of a unit graph (mopm plan --unit-graph), or build and run
    \\  one test unit, from declared inputs only: nothing is resolved or fetched
    \\  --src <dir>        the member sources the graph's paths are relative to (.)
    \\  --deps <dir>       <package>.mojoc of every dependency (deps)
    \\  --natives <dir>    native libraries by soname (natives)
    \\  --stage <dir>      scratch for the compiler's tree (<out>.stage)
    \\  --toolchain <dir>  mojo_compile and CLOSURE_SHA256 of the pinned toolchain
    \\  --target-cpu <l>   the CPU level a test or binary is compiled for: x86-64,
    \\                     x86-64-v2, x86-64-v3 or x86-64-v4 (armv8.0-a..armv8.4-a are
    \\                     named and refused: no verified Mojo spelling); none: no CPU argument
    \\
;

pub const Verb = enum { build, @"test" };

pub const Args = struct {
    verb: Verb,
    unit: []const u8,
    graph: []const u8,
    out: []const u8,
    toolchain: []const u8,
    src: []const u8 = ".",
    deps: []const u8 = "deps",
    natives: []const u8 = "natives",
    stage: ?[]const u8 = null,
    target_cpu: ?[]const u8 = null,
};

/// The options of `unit <verb>`; null on a usage error.
pub fn parseArgs(args: []const []const u8) ?Args {
    if (args.len == 0) return null;
    const verb = std.meta.stringToEnum(Verb, args[0]) orelse return null;
    var unit: ?[]const u8 = null;
    var graph: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var toolchain: ?[]const u8 = null;
    var a = Args{ .verb = verb, .unit = "", .graph = "", .out = "", .toolchain = "" };
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len or args[i + 1].len == 0) return null;
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--unit")) {
            unit = v;
        } else if (std.mem.eql(u8, args[i], "--graph")) {
            graph = v;
        } else if (std.mem.eql(u8, args[i], "--out")) {
            out = v;
        } else if (std.mem.eql(u8, args[i], "--toolchain")) {
            toolchain = v;
        } else if (std.mem.eql(u8, args[i], "--src")) {
            a.src = v;
        } else if (std.mem.eql(u8, args[i], "--deps")) {
            a.deps = v;
        } else if (std.mem.eql(u8, args[i], "--natives")) {
            a.natives = v;
        } else if (std.mem.eql(u8, args[i], "--stage")) {
            a.stage = v;
        } else if (std.mem.eql(u8, args[i], "--target-cpu")) {
            a.target_cpu = v;
        } else return null;
    }
    a.unit = unit orelse return null;
    a.graph = graph orelse return null;
    a.out = out orelse return null;
    a.toolchain = toolchain orelse return null;
    return a;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("mopm unit: " ++ fmt, args) catch {};
}

/// The compiler's `--target-cpu` value for the level the user gave (null: none given). A level that is
/// unknown, or has no verified Mojo spelling, is a usage error with `why` set: nothing runs.
pub fn cpuOf(arena: Allocator, a: Args, why: *[]const u8) error{Usage}!?[]const u8 {
    const level = a.target_cpu orelse return null;
    return core.target_cpu.mojoValue(level) catch |e| {
        why.* = core.target_cpu.explain(arena, level, e) catch "bad --target-cpu";
        return error.Usage;
    };
}

pub fn main(arena: Allocator, args: []const []const u8) u8 {
    const a = parseArgs(args) orelse {
        std.io.getStdErr().writeAll(usage) catch {};
        return exit_usage;
    };
    var why: []const u8 = "";
    const cpu = cpuOf(arena, a, &why) catch {
        say("{s}\n", .{why});
        return exit_usage;
    };
    return run(arena, a, cpu) catch |e| {
        say("{s}\n", .{@errorName(e)});
        return 1;
    };
}

fn run(arena: Allocator, a: Args, cpu: ?[]const u8) !u8 {
    const text = std.fs.cwd().readFileAlloc(arena, a.graph, 256 << 20) catch |e| {
        say("cannot read {s}: {s}\n", .{ a.graph, @errorName(e) });
        return 1;
    };
    const g = core.unit_graph.parse(arena, text) catch |e| {
        say("{s} is not a unit graph: {s}\n", .{ a.graph, @errorName(e) });
        return 1;
    };
    if (g.unit_graph != core.unit_graph.format_version) {
        say("{s} is unit graph format {d}; this mopm reads {d}\n", .{ a.graph, g.unit_graph, core.unit_graph.format_version });
        return 1;
    }
    const idx = g.find(a.unit) orelse {
        std.io.getStdErr().writer().print("error: {s} has no unit {s}\n", .{ a.graph, a.unit }) catch {};
        return exit_refused;
    };
    const dirs = core.unit_run.Dirs{
        .src = a.src,
        .deps = a.deps,
        .toolchain = a.toolchain,
        .natives = a.natives,
        .out = a.out,
        .stage = a.stage orelse try std.fmt.allocPrint(arena, "{s}.stage", .{std.mem.trimRight(u8, a.out, "/")}),
        .target_cpu = cpu,
    };
    var why: []const u8 = "";
    return core.unit_run.run(arena, g, idx, if (a.verb == .build) .build else .run_test, dirs, &why) catch |e| {
        if (e == error.Refused) {
            std.io.getStdErr().writer().print("error: {s}\n", .{why}) catch {};
            return exit_refused;
        }
        return e;
    };
}

test "unit build and test take the unit, the graph, the output and the toolchain" {
    const base = [_][]const u8{ "--unit", "p@1.0.0#mojo1.0.0/lib", "--graph", "g.json", "--out", "o", "--toolchain", "t" };
    const build = [_][]const u8{"build"} ++ base;
    const a = parseArgs(&build).?;
    try std.testing.expectEqual(Verb.build, a.verb);
    try std.testing.expectEqualStrings("p@1.0.0#mojo1.0.0/lib", a.unit);
    try std.testing.expectEqualStrings(".", a.src);
    const test_verb = [_][]const u8{"test"} ++ base;
    try std.testing.expectEqual(Verb.@"test", parseArgs(&test_verb).?.verb);
    try std.testing.expect(parseArgs(&.{}) == null);
    const frob = [_][]const u8{"frob"} ++ base;
    try std.testing.expect(parseArgs(&frob) == null);
    try std.testing.expect(parseArgs(&.{ "build", "--unit", "x" }) == null);
    const dangling = build ++ [_][]const u8{"--src"};
    try std.testing.expect(parseArgs(&dangling) == null);
    const unknown = build ++ [_][]const u8{ "--frob", "x" };
    try std.testing.expect(parseArgs(&unknown) == null);
    const more = build ++ [_][]const u8{ "--src", "w", "--stage", "s" };
    const b = parseArgs(&more).?;
    try std.testing.expectEqualStrings("w", b.src);
    try std.testing.expectEqualStrings("s", b.stage.?);
    try std.testing.expect(b.target_cpu == null);
    const with_cpu = build ++ [_][]const u8{ "--target-cpu", "x86-64-v3" };
    try std.testing.expectEqualStrings("x86-64-v3", parseArgs(&with_cpu).?.target_cpu.?);
    const empty_cpu = build ++ [_][]const u8{ "--target-cpu", "" };
    try std.testing.expect(parseArgs(&empty_cpu) == null);
}

test "--target-cpu: a known level resolves, none resolves to none, anything else is a usage error" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const base = [_][]const u8{ "build", "--unit", "u", "--graph", "g", "--out", "o", "--toolchain", "t" };
    var why: []const u8 = "";
    try std.testing.expect((try cpuOf(a, parseArgs(&base).?, &why)) == null);
    const v3 = base ++ [_][]const u8{ "--target-cpu", "x86-64-v3" };
    try std.testing.expectEqualStrings("x86-64-v3", (try cpuOf(a, parseArgs(&v3).?, &why)).?);
    const bad = base ++ [_][]const u8{ "--target-cpu", "x86-64-v5" };
    try std.testing.expectError(error.Usage, cpuOf(a, parseArgs(&bad).?, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "unknown --target-cpu 'x86-64-v5'") != null);
    const arm = base ++ [_][]const u8{ "--target-cpu", "armv8.2-a" };
    try std.testing.expectError(error.Usage, cpuOf(a, parseArgs(&arm).?, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "no verified Mojo spelling") != null);
}
