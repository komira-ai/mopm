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

/// Why a graph of format `format` cannot be read, or null when this mopm reads it.
pub fn formatProblem(arena: Allocator, path: []const u8, format: u32) Allocator.Error!?[]const u8 {
    const g = core.unit_graph;
    if (format == g.format_version or format == g.format_loads or format == g.format_provided or format == g.format_link) return null;
    return try std.fmt.allocPrint(arena, "{s} is unit graph format {d}; this mopm reads {d}, {d}, {d} and {d}", .{ path, format, g.format_version, g.format_loads, g.format_provided, g.format_link });
}

/// Why a graph file cannot be used, or null: a unit's `link` names a system library outside `native_link.allowed`, or
/// names one twice. `mopm unit` turns each name into `-l<name>` on a linker command line, so a graph file is held to the
/// list that `mopm.toml`, the metadata and the lock are held to.
pub fn linkProblem(arena: Allocator, path: []const u8, g: core.unit_graph.Graph) Allocator.Error!?[]const u8 {
    for (g.units) |u| {
        if (try core.native_link.problem(arena, u.link)) |why| {
            return try std.fmt.allocPrint(arena, "{s}: unit {s}: link: {s}", .{ path, u.id, why });
        }
    }
    return null;
}

/// Why `mopm unit test` cannot run `u`, or null: a unit with `loads` needs the system libraries of the graph on the
/// loader path, which this command does not provide, so it would run against the machine's libraries.
pub fn testLoadsProblem(arena: Allocator, u: core.unit_graph.Unit) Allocator.Error!?[]const u8 {
    if (u.loads.len == 0) return null;
    const list = try std.mem.join(arena, ", ", u.loads);
    return try std.fmt.allocPrint(arena, "{s} loads system libraries ({s}); mopm unit test does not put them on the loader path, so the test would run against the machine's libraries", .{ u.id, list });
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
    if (try formatProblem(arena, a.graph, g.unit_graph)) |why| {
        say("{s}\n", .{why});
        return 1;
    }
    if (try linkProblem(arena, a.graph, g)) |why| {
        say("{s}\n", .{why});
        return 1;
    }
    const idx = g.find(a.unit) orelse {
        std.io.getStdErr().writer().print("error: {s} has no unit {s}\n", .{ a.graph, a.unit }) catch {};
        return exit_refused;
    };
    if (a.verb == .@"test") {
        if (try testLoadsProblem(arena, g.units[idx])) |why| {
            std.io.getStdErr().writer().print("error: {s}\n", .{why}) catch {};
            return exit_refused;
        }
    }
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
    // The dependency and native-library directories a unit is built against (a member's natives are found through --natives).
    const dirs = build ++ [_][]const u8{ "--deps", "d", "--natives", "n" };
    const c = parseArgs(&dirs).?;
    try std.testing.expectEqualStrings("d", c.deps);
    try std.testing.expectEqualStrings("n", c.natives);
    try std.testing.expectEqualStrings("deps", b.deps);
    try std.testing.expectEqualStrings("natives", b.natives);
    const with_cpu = build ++ [_][]const u8{ "--target-cpu", "x86-64-v3" };
    try std.testing.expectEqualStrings("x86-64-v3", parseArgs(&with_cpu).?.target_cpu.?);
    const empty_cpu = build ++ [_][]const u8{ "--target-cpu", "" };
    try std.testing.expect(parseArgs(&empty_cpu) == null);
}

const empty_graph =
    \\{"unit_graph": @F@, "package": "p@1.0.0", "mojo": "1.0.0",
    \\ "toolchain": {"mojo": "1.0.0", "subdir": "linux-64", "cc_target": "x86_64-linux-gnu.2.34", "closure_sha256": "c", "zig": {"version": "0.12.0", "url": "u", "sha256": "f", "size": 1}, "components": []},
    \\ "units": [@U@]}
;

const lib_unit =
    \\{"id": "p@1.0.0#mojo1.0.0/lib", "package": "p", "version": "1.0.0", "kind": "lib", "root": "src/p", "deps": [], "natives": [], "outputs": ["p.mojoc"]}
;

test "a unit graph of another format is refused with its message; this format is read" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try formatProblem(a, "g.json", core.unit_graph.format_version)) == null);
    try std.testing.expectEqualStrings("g.json is unit graph format 1; this mopm reads 2, 3, 4 and 5", (try formatProblem(a, "g.json", 1)).?);
    try std.testing.expect((try formatProblem(a, "g.json", core.unit_graph.format_loads)) == null);
    try std.testing.expect((try formatProblem(a, "g.json", core.unit_graph.format_provided)) == null);
    try std.testing.expect((try formatProblem(a, "g.json", core.unit_graph.format_link)) == null);
    try std.testing.expect((try formatProblem(a, "g.json", core.unit_graph.format_link + 1)) != null);

    var with_loads = core.unit_graph.Unit{ .id = "p@1.0.0#mojo1.0.0/test:tests/test_p.mojo", .package = "p", .version = "1.0.0", .kind = "test" };
    try std.testing.expect((try testLoadsProblem(a, with_loads)) == null);
    with_loads.loads = &.{ "libbrotlicommon", "libbrotlidec" };
    const refused = (try testLoadsProblem(a, with_loads)).?;
    try std.testing.expect(std.mem.indexOf(u8, refused, "loads system libraries (libbrotlicommon, libbrotlidec)") != null);

    // `run` stops at a format 1 graph (exit 1) before it looks for the unit, and goes on with a format 2 one (the unit is unknown: exit 4).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const no_units = try std.mem.replaceOwned(u8, a, empty_graph, "@U@", "");
    try tmp.dir.writeFile("old.json", try std.mem.replaceOwned(u8, a, no_units, "@F@", "1"));
    try tmp.dir.writeFile("new.json", try std.mem.replaceOwned(u8, a, no_units, "@F@", "2"));
    try tmp.dir.writeFile("one.json", try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, empty_graph, "@U@", lib_unit), "@F@", "2"));
    try tmp.dir.writeFile("junk.json", "not json");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const base = Args{ .verb = .build, .unit = "p@1.0.0#mojo1.0.0/lib", .graph = "", .out = "o", .toolchain = "t" };
    var old = base;
    old.graph = try std.fs.path.join(a, &.{ root, "old.json" });
    try std.testing.expectEqual(@as(u8, 1), try run(a, old, null));
    var new = base;
    new.graph = try std.fs.path.join(a, &.{ root, "new.json" });
    try std.testing.expectEqual(exit_refused, try run(a, new, null));
    // A unit that is there is checked before anything runs: the toolchain directory is missing, so it is refused (4).
    var one = base;
    one.graph = try std.fs.path.join(a, &.{ root, "one.json" });
    one.out = try std.fs.path.join(a, &.{ root, "out" });
    one.toolchain = try std.fs.path.join(a, &.{ root, "no-toolchain" });
    try std.testing.expectEqual(exit_refused, try run(a, one, null));
    // With every input there, the wrapper is run; one that cannot be executed (not an executable file) is an error
    // that is passed on, not a refusal.
    try tmp.dir.makePath("tc");
    try tmp.dir.writeFile("tc/CLOSURE_SHA256", "c\n");
    try tmp.dir.writeFile("tc/mojo_compile", "not executable\n");
    var spawn = one;
    spawn.toolchain = try std.fs.path.join(a, &.{ root, "tc" });
    if (run(a, spawn, null)) |_| {
        return error.TestUnexpectedResult;
    } else |e| try std.testing.expect(e != error.Refused);
    // A graph that is not there, or is not a graph: exit 1.
    var gone = base;
    gone.graph = try std.fs.path.join(a, &.{ root, "gone.json" });
    try std.testing.expectEqual(@as(u8, 1), try run(a, gone, null));
    var junk = base;
    junk.graph = try std.fs.path.join(a, &.{ root, "junk.json" });
    try std.testing.expectEqual(@as(u8, 1), try run(a, junk, null));
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

// Defect it catches: `mopm unit test` running a test that loads system libraries against the machine's own libraries (the graph's
// libraries are not on the loader path), or `mopm unit build` refusing the same unit.
test "unit test refuses a unit that loads system libraries, before it looks at the toolchain; unit build does not" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const loading_unit =
        \\{"id": "p@1.0.0#mojo1.0.0/test:tests/test_p.mojo", "package": "p", "version": "1.0.0", "kind": "test", "root": "src/p", "deps": [], "natives": [], "outputs": [], "loads": ["libbrotlicommon"]}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("loads.json", try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, empty_graph, "@U@", loading_unit), "@F@", "3"));
    try tmp.dir.makePath("tc");
    try tmp.dir.writeFile("tc/CLOSURE_SHA256", "c\n");
    try tmp.dir.writeFile("tc/mojo_compile", "not executable\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    var args = Args{ .verb = .@"test", .unit = "p@1.0.0#mojo1.0.0/test:tests/test_p.mojo", .graph = try std.fs.path.join(a, &.{ root, "loads.json" }), .out = try std.fs.path.join(a, &.{ root, "out" }), .toolchain = try std.fs.path.join(a, &.{ root, "tc" }) };
    // The toolchain is complete, so only the loads refuse the test.
    try std.testing.expectEqual(exit_refused, try run(a, args, null));
    // The same unit as a build is not refused for its loads: the run goes on to the wrapper, which here cannot be executed.
    args.verb = .build;
    if (run(a, args, null)) |_| {
        return error.TestUnexpectedResult;
    } else |e| try std.testing.expect(e != error.Refused);
}

// Defect it catches: `mopm unit` putting any string from a graph file after -Xlinker as -l<string>.
test "a graph file whose link has a name outside the list, or a repeated name, is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var units = [_]core.unit_graph.Unit{.{ .id = "p@1.0.0#mojo1.0.0/lib", .package = "p", .version = "1.0.0", .kind = "lib", .link = &.{ "c++", "m" } }};
    const g = core.unit_graph.Graph{ .package = "p@1.0.0", .mojo = "1.0.0", .toolchain = undefined, .units = &units };
    try std.testing.expect((try linkProblem(a, "g.json", g)) == null);
    units[0].link = &.{ "c++", "-Wl,-z,execstack" };
    try std.testing.expectEqualStrings("g.json: unit p@1.0.0#mojo1.0.0/lib: link: '-Wl,-z,execstack' is not a system library a native may link; the allowed ones are c++, dl, m and pthread", (try linkProblem(a, "g.json", g)).?);
    units[0].link = &.{ "m", "m" };
    try std.testing.expect(std.mem.indexOf(u8, (try linkProblem(a, "g.json", g)).?, "'m' is named twice") != null);
}
