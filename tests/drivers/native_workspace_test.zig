//! A package that ships its own C library, and a package that links it, from the workspace to an installed set: the
//! walk a user takes to get native code through mopm, on the three platforms mopm supports (Linux x86_64, Linux arm64,
//! macOS arm64). The fixture is tests/e2e/natws: `nativeapp` (a library and the program `demo`) depends on the path
//! member `shimlib`, whose manifest declares `[native.shim]` with C sources (`srcs`), a header, `cflags` and
//! `cflags_by_os`. `shim_answer` is computed by the C code: 42 on Linux, 43 on macOS (the flags of the operating system
//! add the difference), and `nativeapp.plus_one` adds one to it in Mojo.
//!
//! What it does:
//!   1. `mopm lock` of the workspace, then `mopm plan --unit-graph`: the graph holds the `native` unit of the member
//!      (its sources, header, flags and archive name), and the library units and the program list that unit as a built
//!      native.
//!   2. The member's native is built from the C sources the graph names, with the flags it names for the operating
//!      system (what a build system does with a `native` unit): `cc -c` of each source, `ar` of the objects into
//!      `libshim.a`.
//!   3. `mopm unit build` makes the two libraries, then the program, with the archive in `--natives`; the program
//!      runs and prints values only the C code can give. The compiler's command line holds the archive as a linker
//!      operand on the program's build and on no library's.
//!   4. `mopm pack` of both packages for this platform; the member's pack carries the archive. The packed files and a
//!      plan.json are a staged set (spec/staged-set.md).
//!   5. A fresh project locks and syncs the set with `--overlay` (the registry holds none of it): the lock pins the
//!      archive's sha256, the installed environment holds `lib/libshim.a` byte for byte, and a program that imports
//!      both packages is built by `mopm build` against it and run: it prints the same values.
//!
//! Controls that must be able to fail: an archive missing from `--natives` and a file that is not an archive are
//! refused by `mopm unit build` (exit 4); and in the fresh project, an environment whose `lib/libshim.a` is taken away
//! cannot build the program.
//!
//! Two tiers run this file (BUCK): `native_workspace` (pull requests) stands in for the Mojo compiler
//! (tests/drivers/fake_toolchain.zig) and for pixi, so it checks the wiring (the graph, the C build, the link line, the
//! packed archive, the lock and the install) and not the values the program prints; `native_workspace_mojo` (after the
//! merge) runs the real Mojo 1.0.0 and checks the values. `zig build test-native-workspace -Dmojo-env=<pixi prefix>`
//! runs it natively on a GitHub runner (ci.yml, job `mojo e2e`) against the system C compiler and a stand-in pixi.
//!
//! Run by Buck2 as //:native_workspace and //:native_workspace_mojo; MOPM, MOPM_FAKE_REGISTRY and FAKE_PIXI are the
//! built programs, MOJO_COMPILE_SHIM the `mojo_compile` of the toolchain directory `mopm unit` runs, and either
//! MOJO_TOOLCHAIN (the real Mojo) or FAKE_TOOLCHAIN (the stand-in) names the compiler.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const is_macos = builtin.os.tag == .macos;

/// What the C code returns on this operating system, and what the Mojo above it adds.
const shim_value: []const u8 = if (is_macos) "43" else "42";
const app_value: []const u8 = if (is_macos) "44" else "43";

const consumer_toml = "[package]\nname = \"consumer\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n[dependencies]\n";

const consumer_main =
    \\from nativeapp import plus_one
    \\from shimlib import shim_answer
    \\
    \\
    \\def main():
    \\    print("shim", shim_answer())
    \\    print("app", plus_one())
    \\
;

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(out, .lower));
}

/// The value after `key ` on the first line of `text` that has it.
fn valueOf(a: Allocator, text: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (std.mem.startsWith(u8, t, key) and t.len > key.len and t[key.len] == ' ') return a.dupe(u8, t[key.len + 1 ..]);
    }
    return "";
}

/// The conda subdir of the machine the driver runs on.
fn hostSubdir() ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "osx-arm64",
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-64",
            .aarch64 => "linux-aarch64",
            else => error.UnsupportedHost,
        },
        else => error.UnsupportedHost,
    };
}

/// The elements of the array at `key` of `v`; empty when there is none.
fn items(v: Value, key: []const u8) []const Value {
    if (v != .object) return &.{};
    const f = v.object.get(key) orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

/// The strings of the array at `key` of `v`, joined by `sep`.
fn joined(a: Allocator, v: Value, key: []const u8, sep: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).init(a);
    for (items(v, key)) |e| if (e == .string) try parts.append(e.string);
    return std.mem.join(a, sep, parts.items);
}

/// The `path` of each element of the array at `key` of `v` (a source or a header), joined by a space.
fn pathsOf(a: Allocator, v: Value, key: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).init(a);
    for (items(v, key)) |e| try parts.append(h.jsonString(e, "path") orelse "?");
    return std.mem.join(a, " ", parts.items);
}

fn unitById(graph: Value, id: []const u8) ?Value {
    for (items(graph, "units")) |u| {
        if (std.mem.eql(u8, h.jsonString(u, "id") orelse "", id)) return u;
    }
    return null;
}

/// Whether the unit `u` lists the built native `libshim.a` of `native:shimlib/shim`.
fn listsBuiltShim(u: Value) bool {
    for (items(u, "natives")) |n| {
        if (std.mem.eql(u8, h.jsonString(n, "soname") orelse "", "libshim.a") and std.mem.eql(u8, h.jsonString(n, "built") orelse "", "native:shimlib/shim")) return true;
    }
    return false;
}

/// What a build system needs to build the archive of a native: the sources (from the workspace), the flags and the include
/// directories (from the member).
const NativeSpec = struct {
    package: []const u8,
    soname: []const u8,
    srcs: []const []const u8,
    cflags: []const []const u8,
    cflags_linux: []const []const u8,
    cflags_macos: []const []const u8,
    includes: []const []const u8,
};

/// The native of tests/e2e/natws/shimlib/mopm.toml, written out, for a machine whose unit graph mopm cannot make (see
/// `have_graph` in `run`). On linux-64 the spec comes from the graph, and a check holds it to this one.
const manifest_spec = NativeSpec{
    .package = "shimlib",
    .soname = "libshim.a",
    .srcs = &.{ "shimlib/native/scale.c", "shimlib/native/shim.c" },
    .cflags = &.{ "-O1", "-DSHIM_SCALE=6" },
    .cflags_linux = &.{"-DSHIM_OS_ADD=0"},
    .cflags_macos = &.{"-DSHIM_OS_ADD=1"},
    .includes = &.{"native"},
};

/// The spec the `native` unit `unit` of a graph gives.
fn specOf(a: Allocator, unit: Value) !NativeSpec {
    var srcs = std.ArrayList([]const u8).init(a);
    for (items(unit, "srcs")) |s| try srcs.append(h.jsonString(s, "path") orelse return error.BadGraph);
    var cflags = std.ArrayList([]const u8).init(a);
    for (items(unit, "cflags")) |f| try cflags.append(f.string);
    var linux = std.ArrayList([]const u8).init(a);
    var macos = std.ArrayList([]const u8).init(a);
    if (unit.object.get("cflags_by_os")) |by_os| {
        for (items(by_os, "linux")) |f| try linux.append(f.string);
        for (items(by_os, "macos")) |f| try macos.append(f.string);
    }
    var includes = std.ArrayList([]const u8).init(a);
    for (items(unit, "includes")) |i| try includes.append(i.string);
    return .{
        .package = h.jsonString(unit, "package") orelse return error.BadGraph,
        .soname = h.jsonString(unit, "soname") orelse return error.BadGraph,
        .srcs = srcs.items,
        .cflags = cflags.items,
        .cflags_linux = linux.items,
        .cflags_macos = macos.items,
        .includes = includes.items,
    };
}

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    m: mojo_env.Mojo,
    mopm: []const u8,
    /// The stand-in compiler (the unit tier), or null for the real Mojo.
    stand_in: ?[]const u8,
    fake_pixi: []const u8,
    work: []const u8,

    fn env(c: *Ctx) !std.process.EnvMap {
        var e = try c.m.freshEnv();
        e.remove("MOPM_TOKEN");
        return e;
    }

    fn mopmRun(c: *Ctx, e: *const std.process.EnvMap, dir: []const u8, args: []const []const u8) !h.Ran {
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = c.mopm;
        @memcpy(argv[1..], args);
        return h.run(c.a, argv, e, .{ .cwd = dir });
    }

    fn must(c: *Ctx, what: []const u8, r: h.Ran) !void {
        if (r.signaled or r.code != 0) {
            std.debug.print("FAIL {s}: exit {d}\n{s}\n", .{ what, r.code, r.text });
            c.rep.failures += 1;
            return error.Fatal;
        }
        std.debug.print("ok   {s}\n", .{what});
    }

    /// `ar` over `objs` into `out`: zig's on the farm, the system's on a runner.
    fn archive(c: *Ctx, out: []const u8, objs: []const []const u8) !h.Ran {
        var e = try c.m.freshEnv();
        var argv = std.ArrayList([]const u8).init(c.a);
        if (c.m.base.get("MOPM_ZIG")) |zig| {
            try argv.appendSlice(&.{ zig, "ar", "rcs", out });
        } else {
            try argv.appendSlice(&.{ "ar", "rcs", out });
        }
        try argv.appendSlice(objs);
        return h.run(c.a, argv.items, &e, .{});
    }

    /// The program `path` run in an empty environment: with the real Mojo it prints what the C code computes (and the
    /// Mojo above it adds); the stand-in prints a fixed line, so there only the exit status is checked.
    fn runProgram(c: *Ctx, what: []const u8, path: []const u8) !void {
        const a = c.a;
        var empty = std.process.EnvMap.init(a);
        const r = try h.run(a, &.{path}, &empty, .{});
        if (c.stand_in == null) {
            c.rep.check(try h.fmt(a, "{s}: runs in an empty environment and prints what the C code computes", .{what}), !r.signaled and r.code == 0 and
                h.contains(r.text, try h.fmt(a, "shim {s}\n", .{shim_value})) and h.contains(r.text, try h.fmt(a, "app {s}\n", .{app_value})), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
        } else {
            c.rep.check(try h.fmt(a, "{s}: the stand-in program runs (the unit tier does not check the values it prints)", .{what}), !r.signaled and r.code == 0, try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
        }
    }

    /// Builds the archive of a native from its spec, as a build system does: `cc -c` of each source with the flags
    /// (`cflags`, then the `cflags_by_os` of this operating system) and one `-I` per include directory (relative to
    /// the member, which here sits at <ws>/<package>), then `ar` of the objects, in the order of the sources, into
    /// `<natives>/<soname>`.
    fn buildNative(c: *Ctx, spec: NativeSpec, ws: []const u8, natives: []const u8) !void {
        const a = c.a;
        const package = spec.package;
        const soname = spec.soname;
        const member = try h.join(a, &.{ ws, package });
        var flags = std.ArrayList([]const u8).init(a);
        try flags.appendSlice(&.{ "-c", "-fPIC" });
        try flags.appendSlice(spec.cflags);
        try flags.appendSlice(if (is_macos) spec.cflags_macos else spec.cflags_linux);
        for (spec.includes) |inc| try flags.append(try h.fmt(a, "-I{s}", .{try h.join(a, &.{ member, inc })}));
        const objdir = try h.join(a, &.{ c.work, "obj" });
        try std.fs.cwd().makePath(objdir);
        var objs = std.ArrayList([]const u8).init(a);
        for (spec.srcs) |path| {
            const obj = try h.join(a, &.{ objdir, try h.fmt(a, "{s}.o", .{std.fs.path.stem(path)}) });
            var argv = std.ArrayList([]const u8).init(a);
            try argv.appendSlice(flags.items);
            try argv.appendSlice(&.{ "-o", obj, try h.join(a, &.{ ws, path }) });
            try c.must(try h.fmt(a, "cc -c {s} (the flags of the native unit)", .{path}), try c.m.cc(argv.items));
            try objs.append(obj);
        }
        try std.fs.cwd().makePath(natives);
        try c.must(try h.fmt(a, "ar {s} of {d} objects", .{ soname, objs.items.len }), try c.archive(try h.join(a, &.{ natives, soname }), objs.items));
    }

    /// A copy of the stand-in compiler as the executable `dest`.
    fn laySkeleton(c: *Ctx, dest: []const u8) !void {
        const cwd = std.fs.cwd();
        if (std.fs.path.dirname(dest)) |d| try cwd.makePath(d);
        try cwd.copyFile(c.stand_in.?, cwd, dest, .{});
        const f = try cwd.openFile(dest, .{});
        defer f.close();
        try f.chmod(0o755);
    }
};

test "native_workspace: a package with a C library and a package that links it, from the workspace to an installed set" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    run(a, &rep) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
    try rep.finish();
}

fn run(a: Allocator, rep: *h.Report) !void {
    const cwd = std.fs.cwd();
    const stand_in: ?[]const u8 = std.process.getEnvVarOwned(a, "FAKE_TOOLCHAIN") catch null;
    const base_work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const work = try h.join(a, &.{ base_work, "natws" });
    try cwd.makePath(work);

    // The compiler: the real toolchain, or a directory that holds only the stand-in `mojo`.
    var m: mojo_env.Mojo = undefined;
    if (stand_in) |fake| {
        const tc = try h.join(a, &.{ work, "standin_tc" });
        try cwd.makePath(try h.join(a, &.{ tc, "bin" }));
        try cwd.makePath(try h.join(a, &.{ tc, "lib" }));
        try cwd.copyFile(fake, cwd, try h.join(a, &.{ tc, "bin/mojo" }), .{});
        m = try mojo_env.Mojo.initAt(a, tc);
    } else {
        m = try mojo_env.Mojo.init(a);
    }
    var c = Ctx{ .a = a, .rep = rep, .m = m, .mopm = try h.toolPathAbs(a, "MOPM"), .stand_in = stand_in, .fake_pixi = try h.toolPathAbs(a, "FAKE_PIXI"), .work = work };
    const subdir = try hostSubdir();
    const env = try c.env();

    // The prefix the compiler of the toolchain directory runs from.
    const pixi = try h.join(a, &.{ work, "pixi" });
    if (stand_in != null) {
        try c.laySkeleton(try h.join(a, &.{ pixi, "bin/mojo" }));
    } else {
        try m.prefix(pixi, true);
    }

    // The toolchain directory `mopm unit` runs: the `mojo_compile` shim, its configuration, the runtime libraries.
    const tc = try h.join(a, &.{ work, "tc" });
    const log = try h.join(a, &.{ work, "mojo_compile.log" });
    try cwd.makePath(tc);
    try cwd.copyFile(try h.toolPathAbs(a, "MOJO_COMPILE_SHIM"), cwd, try h.join(a, &.{ tc, "mojo_compile" }), .{});
    {
        const f = try cwd.openFile(try h.join(a, &.{ tc, "mojo_compile" }), .{});
        defer f.close();
        try f.chmod(0o755);
    }
    {
        var conf = std.ArrayList(u8).init(a);
        try conf.writer().print("mojo={s}/bin/mojo\nlog={s}\nenv.MODULAR_HOME={s}/share/max\n", .{ pixi, log, pixi });
        var it = m.base.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "MODULAR_HOME")) continue;
            try conf.writer().print("env.{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        try h.writeFile(try h.join(a, &.{ tc, "mojo_compile.conf" }), conf.items);
    }
    try cwd.symLink(try h.join(a, &.{ m.tc, "lib" }), try h.join(a, &.{ tc, "lib" }), .{});

    // 1. The workspace, locked and planned.
    const ws = try h.join(a, &.{ work, "ws" });
    try h.copyTree(a, try h.join(a, &.{ m.work, "tests/e2e/natws" }), ws);
    var r = try c.mopmRun(&env, ws, &.{"lock"});
    try c.must("mopm lock of the workspace (the member is a path dependency, offline)", r);
    const lock_text = try h.readFile(a, try h.join(a, &.{ ws, "mopm.lock" }));
    rep.check("the lock names the member", h.contains(lock_text, "shimlib"), lock_text);
    // This walk builds the unit graph (and runs `mopm unit`) on linux-64 only, the platform of the farm. `mopm plan` also makes a graph
    // for linux-aarch64 and osx-arm64 (unit_graph.zig, `supported`), but nothing here has run a build from one. On the other platforms the walk keeps every step that
    // does not need it: this driver builds the native from the sources of the manifest (a check on linux-64 holds
    // `manifest_spec` to the graph's), and the compiler builds the libraries and the program directly.
    const have_graph = std.mem.eql(u8, subdir, "linux-64");
    const graph_path = try h.join(a, &.{ work, "graph.json" });
    const native_id = "native:shimlib/shim";
    const lib_shim = "shimlib@1.0.0#mojo1.0.0/lib";
    const lib_app = "nativeapp@1.0.0#mojo1.0.0/lib";
    const bin_demo = "nativeapp@1.0.0#mojo1.0.0/bin:demo";
    if (have_graph) {
        r = try c.mopmRun(&env, ws, &.{ "plan", "--unit-graph", "--locked", "--mojo", "1.0.0", "--subdir", subdir, "-o", graph_path });
        try c.must("mopm plan --unit-graph of the workspace", r);
    } else {
        r = try c.mopmRun(&env, ws, &.{ "plan", "--unit-graph", "--locked", "--mojo", "1.0.0", "--subdir", subdir, "-o", graph_path });
        // The same outcome as on linux-64: the plan succeeds, and the graph it wrote names the toolchain of this platform.
        try c.must("control: mopm plan --unit-graph of the workspace on this platform (the graph steps after it are skipped here all the same)", r);
        const other_graph = try h.parseJson(a, try h.readFile(a, graph_path));
        const other_tc = other_graph.object.get("toolchain") orelse return error.BadGraph;
        rep.check("control: the graph's toolchain is the one mopm pins for this platform", if (h.jsonString(other_tc, "subdir")) |got| std.mem.eql(u8, got, subdir) else false, graph_path);
        rep.check("control: the graph's toolchain carries a closure hash", if (h.jsonString(other_tc, "closure_sha256")) |got| got.len == 64 else false, graph_path);
        std.debug.print("SKIP the unit graph, mopm unit build: this walk runs them on linux-64 only; {s} builds the native from the manifest's sources and the libraries and the program with the compiler directly\n", .{subdir});
    }
    var spec = manifest_spec;
    if (have_graph) {
    const graph = try h.parseJson(a, try h.readFile(a, graph_path));
    const closure = blk: {
        const tcv = graph.object.get("toolchain") orelse return error.BadGraph;
        break :blk h.jsonString(tcv, "closure_sha256") orelse return error.BadGraph;
    };
    try h.writeFile(try h.join(a, &.{ tc, "CLOSURE_SHA256" }), try h.fmt(a, "{s}\n", .{closure}));

    const native_unit = unitById(graph, native_id) orelse {
        rep.check("the graph holds the native unit native:shimlib/shim", false, "no such unit");
        return error.Fatal;
    };
    spec = try specOf(a, native_unit);
    rep.check("the native unit names the archive libshim.a and the member's sources, sorted", std.mem.eql(u8, h.jsonString(native_unit, "kind") orelse "", "native") and
        std.mem.eql(u8, h.jsonString(native_unit, "soname") orelse "", "libshim.a") and
        std.mem.eql(u8, try pathsOf(a, native_unit, "srcs"), "shimlib/native/scale.c shimlib/native/shim.c"), "kind, soname or srcs differ");
    rep.check("the native unit names the header, the flags, the flags of each operating system and the include directory", std.mem.eql(u8, try pathsOf(a, native_unit, "hdrs"), "shimlib/native/shim.h") and
        std.mem.eql(u8, try joined(a, native_unit, "cflags", " "), "-O1 -DSHIM_SCALE=6") and
        std.mem.eql(u8, try joined(a, native_unit.object.get("cflags_by_os") orelse .null, "linux", " "), "-DSHIM_OS_ADD=0") and
        std.mem.eql(u8, try joined(a, native_unit.object.get("cflags_by_os") orelse .null, "macos", " "), "-DSHIM_OS_ADD=1") and
        std.mem.eql(u8, try joined(a, native_unit, "includes", " "), "native"), "a field of the native unit differs");
    for ([_][]const u8{ lib_shim, lib_app, bin_demo }) |id| {
        const u = unitById(graph, id);
        rep.check(try h.fmt(a, "{s} lists the built native libshim.a of native:shimlib/shim", .{id}), u != null and listsBuiltShim(u.?), "the unit is missing or does not list the built native");
    }
    {
        const want = manifest_spec;
        const same = std.mem.eql(u8, spec.package, want.package) and std.mem.eql(u8, spec.soname, want.soname) and
            std.mem.eql(u8, try std.mem.join(a, " ", spec.srcs), try std.mem.join(a, " ", want.srcs)) and
            std.mem.eql(u8, try std.mem.join(a, " ", spec.cflags), try std.mem.join(a, " ", want.cflags)) and
            std.mem.eql(u8, try std.mem.join(a, " ", spec.cflags_linux), try std.mem.join(a, " ", want.cflags_linux)) and
            std.mem.eql(u8, try std.mem.join(a, " ", spec.cflags_macos), try std.mem.join(a, " ", want.cflags_macos)) and
            std.mem.eql(u8, try std.mem.join(a, " ", spec.includes), try std.mem.join(a, " ", want.includes));
        rep.check("the graph's native is the one this driver writes out for the platforms that have no graph", same, "manifest_spec differs from the native unit");
    }
    }

    // 2. The member's native, built from its C sources.
    const natives = try h.join(a, &.{ work, "natives" });
    try c.buildNative(spec, ws, natives);
    const archive_path = try h.join(a, &.{ natives, "libshim.a" });
    const archive_bytes = try h.readFile(a, archive_path);
    rep.check("libshim.a is an ar archive", std.mem.startsWith(u8, archive_bytes, "!<arch>\n"), "the archive does not begin with !<arch>");
    rep.check("libshim.a holds the code of both sources (the C functions' names are in it)", h.contains(archive_bytes, "shim_answer") and h.contains(archive_bytes, "shim_scale"), "a symbol name is missing from the archive");

    // 3. The libraries and the program, through `mopm unit build`.
    const deps = try h.join(a, &.{ work, "deps" });
    const lib_out = try h.join(a, &.{ work, "lib_out" });
    try cwd.makePath(deps);
    if (have_graph) {
    for ([_]struct { id: []const u8, name: []const u8 }{ .{ .id = lib_shim, .name = "shimlib" }, .{ .id = lib_app, .name = "nativeapp" } }) |l| {
        r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", l.id, "--graph", graph_path, "--out", lib_out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", try h.fmt(a, "{s}/stage_{s}", .{ work, l.name }) });
        try c.must(try h.fmt(a, "mopm unit build: the library {s}", .{l.name}), r);
        try cwd.copyFile(try h.join(a, &.{ lib_out, try h.fmt(a, "{s}.mojoc", .{l.name}) }), cwd, try h.join(a, &.{ deps, try h.fmt(a, "{s}.mojoc", .{l.name}) }), .{});
    }
    const bin_out = try h.join(a, &.{ work, "bin_out" });
    r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", bin_demo, "--graph", graph_path, "--out", bin_out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", try h.join(a, &.{ work, "stage_demo" }) });
    try c.must("mopm unit build: the program demo, with libshim.a in --natives", r);
    try c.runProgram("the program built by mopm unit build", try h.join(a, &.{ bin_out, "demo" }));
    const logged = try h.readFile(a, log);
    var with_operand: usize = 0;
    var build_lines: usize = 0;
    var lib_with_operand: usize = 0;
    var lines = std.mem.splitScalar(u8, logged, '\n');
    while (lines.next()) |l| {
        // The archive as a linker operand: `-Xlinker <natives dir>/libshim.a`. (The directory is not compared as text: a
        // runner's temporary directory may be reached through a link.)
        const has_operand = h.contains(l, "-Xlinker ") and h.contains(l, "/natives/libshim.a");
        if (h.contains(l, " build ")) {
            build_lines += 1;
            if (has_operand) with_operand += 1;
        } else if (has_operand) {
            lib_with_operand += 1;
        }
    }
    rep.check("the compiler's link line: the program's build holds the archive as a linker operand", build_lines == 1 and with_operand == 1, logged);
    rep.check("the compiler's command lines for the libraries do not link the archive", lib_with_operand == 0, logged);

    // Controls of the unit build: each must be able to fail.
    const bare = try h.join(a, &.{ work, "natives_bare" });
    try cwd.makePath(bare);
    r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", bin_demo, "--graph", graph_path, "--out", try h.join(a, &.{ work, "out_a" }), "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", bare, "--stage", try h.join(a, &.{ work, "stage_a" }) });
    rep.check("control: an archive missing from --natives is refused (4), naming it", !r.signaled and r.code == 4 and h.contains(r.text, "missing input: libshim.a, the archive of native:shimlib/shim") and h.contains(r.text, "is not in"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
    const not_ar = try h.join(a, &.{ work, "natives_not_ar" });
    try h.writeFile(try h.join(a, &.{ not_ar, "libshim.a" }), "this is not an archive\n");
    r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", bin_demo, "--graph", graph_path, "--out", try h.join(a, &.{ work, "out_b" }), "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", not_ar, "--stage", try h.join(a, &.{ work, "stage_b" }) });
    rep.check("control: a file that is not an archive is refused (4), naming libshim.a", !r.signaled and r.code == 4 and h.contains(r.text, "libshim.a"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));

    } else {
        // No unit graph here: the compiler builds the libraries and the program directly (the same sources, the same
        // archive on the link line). Each directory given with -I holds one .mojoc.
        const inc_shim = try h.join(a, &.{ work, "inc/shimlib" });
        const inc_app = try h.join(a, &.{ work, "inc/nativeapp" });
        try cwd.makePath(inc_shim);
        try cwd.makePath(inc_app);
        const shim_mojoc = try h.join(a, &.{ deps, "shimlib.mojoc" });
        const app_mojoc = try h.join(a, &.{ deps, "nativeapp.mojoc" });
        r = try m.run(pixi, &.{ "precompile", try h.join(a, &.{ ws, "shimlib/src/shimlib" }), "-o", shim_mojoc }, null);
        try c.must("mojo precompile shimlib", r);
        try cwd.copyFile(shim_mojoc, cwd, try h.join(a, &.{ inc_shim, "shimlib.mojoc" }), .{});
        r = try m.run(pixi, &.{ "precompile", try h.fmt(a, "-I{s}", .{inc_shim}), try h.join(a, &.{ ws, "src/nativeapp" }), "-o", app_mojoc }, null);
        try c.must("mojo precompile nativeapp", r);
        try cwd.copyFile(app_mojoc, cwd, try h.join(a, &.{ inc_app, "nativeapp.mojoc" }), .{});
        const demo = try h.join(a, &.{ work, "demo" });
        r = try m.run(pixi, &.{ "build", try h.fmt(a, "-I{s}", .{inc_shim}), try h.fmt(a, "-I{s}", .{inc_app}), try h.join(a, &.{ ws, "bin/demo.mojo" }), "-o", demo, "-Xlinker", archive_path }, null);
        try c.must("mojo build: the program demo, with libshim.a as a linker operand", r);
        try c.runProgram("the program built by the compiler", demo);
    }

    // 4. mopm pack of both packages, for this platform; the staged set.
    const dist = try h.join(a, &.{ work, "dist" });
    const Pack = struct { name: []const u8, file: []const u8, bytes: []const u8, manifest_sha256: []const u8 };
    var packs = std.ArrayList(Pack).init(a);
    for ([_][]const u8{ "shimlib", "nativeapp" }) |name| {
        var args = std.ArrayList([]const u8).init(a);
        try args.appendSlice(&.{ "pack", "--compiler", "1.0.0", "--manifest", if (std.mem.eql(u8, name, "shimlib")) "shimlib/mopm.toml" else "mopm.toml", "-o", dist, "--mojoc", try h.fmt(a, "{s}={s}/{s}.mojoc", .{ subdir, deps, name }) });
        if (std.mem.eql(u8, name, "shimlib")) try args.appendSlice(&.{ "--native", try h.fmt(a, "shim={s}:{s}", .{ subdir, archive_path }) });
        r = try c.mopmRun(&env, ws, args.items);
        try c.must(try h.fmt(a, "mopm pack {s}{s}", .{ name, if (std.mem.eql(u8, name, "shimlib")) " with the archive of its native" else "" }), r);
        const file = try h.fmt(a, "mojo-{s}-1.0.0-mojo1.0.0_0.conda", .{name});
        try packs.append(.{ .name = name, .file = file, .bytes = try h.readFile(a, try h.join(a, &.{ dist, subdir, file })), .manifest_sha256 = try valueOf(a, r.text, "manifest_sha256") });
    }
    {
        var plan = std.ArrayList(u8).init(a);
        try plan.appendSlice("{\"version\":1,\"members\":[");
        for (packs.items, 0..) |p, i| {
            if (i > 0) try plan.append(',');
            try plan.writer().print(
                "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
                .{ p.name, p.manifest_sha256, subdir, p.file, try sha256Hex(a, p.bytes), p.bytes.len },
            );
        }
        try plan.appendSlice("]}\n");
        try h.writeFile(try h.join(a, &.{ dist, "plan.json" }), plan.items);
    }

    // 5. A fresh project locks and syncs the staged set; the archive comes from the packed file.
    var fake = try h.Fake.start(a, try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"), try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const consumer = try h.join(a, &.{ work, "consumer" });
    try h.writeFile(try h.join(a, &.{ consumer, "mopm.toml" }), consumer_toml);
    try h.writeFile(try h.join(a, &.{ consumer, "main.mojo" }), consumer_main);
    r = try c.mopmRun(&env, consumer, &.{ "add", "nativeapp@=1.0.0", "--registry", fake.base, "--overlay", dist });
    try c.must("mopm add --overlay locks the staged set in a fresh project", r);
    const consumer_lock = try h.readFile(a, try h.join(a, &.{ consumer, "mopm.lock" }));
    rep.check("the lock pins the sha256 of libshim.a, the archive the member's pack carries", h.contains(consumer_lock, try sha256Hex(a, archive_bytes)), consumer_lock);
    rep.check("the lock does not name the staged set's directory", !h.contains(consumer_lock, dist), consumer_lock);
    r = try c.mopmRun(&env, consumer, &.{ "sync", "--locked", "--overlay", dist, "--registry", fake.base, "--pixi", c.fake_pixi });
    try c.must("mopm sync --locked --overlay installs the set (the registry holds none of it)", r);
    rep.check("sync read the packages from the staged set", h.contains(r.text, "from the staged set"), r.text);
    const env_dir = try h.join(a, &.{ consumer, ".mopm/.pixi/envs/default" });
    const installed = h.readFile(a, try h.join(a, &.{ env_dir, "lib/libshim.a" })) catch "";
    rep.check("the installed environment holds lib/libshim.a, byte for byte the archive that was built", installed.len > 0 and std.mem.eql(u8, installed, archive_bytes), "lib/libshim.a is missing or differs");
    const meta = h.readFile(a, try h.join(a, &.{ env_dir, "lib/mojo/shimlib.mopm.json" })) catch "";
    rep.check("the installed metadata of shimlib declares the static native libshim.a", h.contains(meta, "\"soname\":\"libshim.a\"") and h.contains(meta, "\"kind\":\"static\""), meta);

    // The compiler goes into the environment, as a pixi environment holds it; then the program is built and run.
    if (stand_in != null) {
        try c.laySkeleton(try h.join(a, &.{ env_dir, "bin/mojo" }));
    } else {
        try m.prefix(env_dir, true);
    }
    var build_env = try c.env();
    const consumer_log = try h.join(a, &.{ work, "consumer_mojo.log" });
    if (stand_in != null) try build_env.put("FAKE_TOOLCHAIN_LOG", consumer_log);
    const consumer_bin = try h.join(a, &.{ work, "consumer_demo" });
    r = try c.mopmRun(&build_env, consumer, &.{ "build", "main.mojo", "-o", consumer_bin, "--prefix", env_dir });
    try c.must("mopm build: the program that imports both packages, against the installed set", r);
    try c.runProgram("the program built by mopm build against the installed set", consumer_bin);
    if (stand_in != null) {
        const consumer_logged = try h.readFile(a, consumer_log);
        rep.check("the link line of mopm build holds the installed archive as a linker operand", h.contains(consumer_logged, "-Xlinker ") and h.contains(consumer_logged, "/.pixi/envs/default/lib/libshim.a"), consumer_logged);
    }

    // Control: the same environment without the archive cannot build the program.
    try cwd.rename(try h.join(a, &.{ env_dir, "lib/libshim.a" }), try h.join(a, &.{ env_dir, "lib/libshim.a.away" }));
    r = try c.mopmRun(&build_env, consumer, &.{ "build", "main.mojo", "-o", try h.join(a, &.{ work, "consumer_demo_without" }), "--prefix", env_dir });
    rep.check("control: with lib/libshim.a taken out of the installed environment, mopm build fails", r.signaled or r.code != 0, try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
}

// ------------------------------------------------------------------------------------------------------------------
// A native written in C++: `[native.cxxshim] link = ["c++"]`, from the workspace to a program built and run
// ------------------------------------------------------------------------------------------------------------------
//
// The fixture is tests/e2e/natcxx: `cxxapp` (a library and the program `demo`) depends on the path member `cxxlib`, whose
// native is `native/cxxshim.cpp` behind a C ABI (`cxx_answer`): it uses std::string, operator new[] and a virtual call,
// so its archive leaves libc++'s symbols undefined. The walk is the one above, on linux-64: `mopm lock`, `mopm plan
// --unit-graph` (the graph says format 5 and gives the program `link = ["c++"]`), the archive built with `c++ -c` and
// `ar`, `mopm unit build` of the libraries and the program, the program run in an empty environment (it prints 42, which
// only the C++ code gives), `mopm pack`, an `--overlay` install in a fresh project (the installed metadata carries the
// link name) and `mopm build` of a program against it, run again. Without `link`, the program's link fails on libc++'s
// symbols.
//
// It runs only natively (build.zig, ci.yml job `mojo e2e`, with the real Mojo) and only when MOPM_E2E_CXX is set: the
// archive is compiled against libc++ (`c++ -stdlib=libc++`, so a runner needs clang and libc++ with `c++` and `cc` pointing
// at clang), and the program is linked through `cc` with `-lc++`.

test "native_workspace: a C++ native with link = [\"c++\"] is linked by mopm unit build and mopm build, and the program runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    if (std.process.getEnvVarOwned(a, "FAKE_TOOLCHAIN")) |_| {
        std.debug.print("SKIP the C++ native: the stand-in compiler cannot link it\n", .{});
        return;
    } else |_| {}
    if (std.process.getEnvVarOwned(a, "MOPM_E2E_CXX")) |_| {} else |_| {
        std.debug.print("SKIP the C++ native: MOPM_E2E_CXX is not set (it needs clang with libc++ as c++ and cc)\n", .{});
        return;
    }
    runCxx(a, &rep) catch |e| switch (e) {
        error.Fatal => {},
        else => return e,
    };
    try rep.finish();
}

/// `c++` of `args` against libc++, the library the archive's consumers link.
fn compileCxx(c: *Ctx, args: []const []const u8) !h.Ran {
    var e = try c.m.freshEnv();
    var argv = std.ArrayList([]const u8).init(c.a);
    if (c.m.base.get("MOPM_ZIG")) |zig| {
        try argv.appendSlice(&.{ zig, "c++" });
    } else {
        try argv.appendSlice(&.{ "c++", "-stdlib=libc++" });
    }
    try argv.appendSlice(args);
    return h.run(c.a, argv.items, &e, .{});
}

fn runCxx(a: Allocator, rep: *h.Report) !void {
    const cwd = std.fs.cwd();
    const subdir = try hostSubdir();
    if (!std.mem.eql(u8, subdir, "linux-64")) {
        std.debug.print("SKIP the C++ native on {s}: this walk runs on linux-64\n", .{subdir});
        return;
    }
    const base_work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const work = try h.join(a, &.{ base_work, "natcxx" });
    try cwd.makePath(work);
    const m = try mojo_env.Mojo.init(a);
    var c = Ctx{ .a = a, .rep = rep, .m = m, .mopm = try h.toolPathAbs(a, "MOPM"), .stand_in = null, .fake_pixi = try h.toolPathAbs(a, "FAKE_PIXI"), .work = work };
    const env = try c.env();

    const pixi = try h.join(a, &.{ work, "pixi" });
    try m.prefix(pixi, true);
    const tc = try h.join(a, &.{ work, "tc" });
    const log = try h.join(a, &.{ work, "mojo_compile.log" });
    try cwd.makePath(tc);
    try cwd.copyFile(try h.toolPathAbs(a, "MOJO_COMPILE_SHIM"), cwd, try h.join(a, &.{ tc, "mojo_compile" }), .{});
    {
        const f = try cwd.openFile(try h.join(a, &.{ tc, "mojo_compile" }), .{});
        defer f.close();
        try f.chmod(0o755);
    }
    {
        var conf = std.ArrayList(u8).init(a);
        try conf.writer().print("mojo={s}/bin/mojo\nlog={s}\nenv.MODULAR_HOME={s}/share/max\n", .{ pixi, log, pixi });
        var it = m.base.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "MODULAR_HOME")) continue;
            try conf.writer().print("env.{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        try h.writeFile(try h.join(a, &.{ tc, "mojo_compile.conf" }), conf.items);
    }
    try cwd.symLink(try h.join(a, &.{ m.tc, "lib" }), try h.join(a, &.{ tc, "lib" }), .{});

    // 1. The workspace, locked and planned.
    const ws = try h.join(a, &.{ work, "ws" });
    try h.copyTree(a, try h.join(a, &.{ m.work, "tests/e2e/natcxx" }), ws);
    var r = try c.mopmRun(&env, ws, &.{"lock"});
    try c.must("mopm lock of the workspace", r);
    const graph_path = try h.join(a, &.{ work, "graph.json" });
    r = try c.mopmRun(&env, ws, &.{ "plan", "--unit-graph", "--locked", "--mojo", "1.0.0", "--subdir", subdir, "-o", graph_path });
    try c.must("mopm plan --unit-graph of the workspace", r);
    const graph_text = try h.readFile(a, graph_path);
    const graph = try h.parseJson(a, graph_text);
    const closure = blk: {
        const tcv = graph.object.get("toolchain") orelse return error.BadGraph;
        break :blk h.jsonString(tcv, "closure_sha256") orelse return error.BadGraph;
    };
    try h.writeFile(try h.join(a, &.{ tc, "CLOSURE_SHA256" }), try h.fmt(a, "{s}\n", .{closure}));
    const lib_cxx = "cxxlib@1.0.0#mojo1.0.0/lib";
    const lib_app = "cxxapp@1.0.0#mojo1.0.0/lib";
    const bin_demo = "cxxapp@1.0.0#mojo1.0.0/bin:demo";
    rep.check("the graph is format 5", h.contains(graph_text, "\"unit_graph\": 5"), graph_text);
    for ([_][]const u8{ lib_cxx, lib_app, bin_demo }) |id| {
        const u = unitById(graph, id);
        rep.check(try h.fmt(a, "{s} has link = [\"c++\"]", .{id}), u != null and std.mem.eql(u8, try joined(a, u.?, "link", ","), "c++"), "the unit is missing or names no c++");
    }

    // 2. The member's native, built from its C++ source: `c++ -c`, then `ar`.
    const member = try h.join(a, &.{ ws, "cxxlib" });
    const objdir = try h.join(a, &.{ work, "obj" });
    try cwd.makePath(objdir);
    const obj = try h.join(a, &.{ objdir, "cxxshim.o" });
    try c.must("c++ -c native/cxxshim.cpp (libc++)", try compileCxx(&c, &.{ "-c", "-fPIC", "-O1", "-std=c++17", try h.fmt(a, "-I{s}", .{try h.join(a, &.{ member, "native" })}), "-o", obj, try h.join(a, &.{ member, "native/cxxshim.cpp" }) }));
    const natives = try h.join(a, &.{ work, "natives" });
    try cwd.makePath(natives);
    const archive_path = try h.join(a, &.{ natives, "libcxxshim.a" });
    try c.must("ar libcxxshim.a", try c.archive(archive_path, &.{obj}));
    const archive_bytes = try h.readFile(a, archive_path);

    // 3. The libraries and the program, through `mopm unit build`; the program runs.
    const deps = try h.join(a, &.{ work, "deps" });
    const lib_out = try h.join(a, &.{ work, "lib_out" });
    try cwd.makePath(deps);
    for ([_]struct { id: []const u8, name: []const u8 }{ .{ .id = lib_cxx, .name = "cxxlib" }, .{ .id = lib_app, .name = "cxxapp" } }) |l| {
        r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", l.id, "--graph", graph_path, "--out", lib_out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", try h.fmt(a, "{s}/stage_{s}", .{ work, l.name }) });
        try c.must(try h.fmt(a, "mopm unit build: the library {s}", .{l.name}), r);
        try cwd.copyFile(try h.join(a, &.{ lib_out, try h.fmt(a, "{s}.mojoc", .{l.name}) }), cwd, try h.join(a, &.{ deps, try h.fmt(a, "{s}.mojoc", .{l.name}) }), .{});
    }
    const bin_out = try h.join(a, &.{ work, "bin_out" });
    r = try c.mopmRun(&env, ws, &.{ "unit", "build", "--unit", bin_demo, "--graph", graph_path, "--out", bin_out, "--toolchain", tc, "--src", ".", "--deps", deps, "--natives", natives, "--stage", try h.join(a, &.{ work, "stage_demo" }) });
    try c.must("mopm unit build: the program demo links libcxxshim.a and -lc++", r);
    try runCxxProgram(&c, "the program built by mopm unit build", try h.join(a, &.{ bin_out, "demo" }));
    const logged = try h.readFile(a, log);
    var with_tail = false;
    var log_lines = std.mem.splitScalar(u8, logged, '\n');
    while (log_lines.next()) |l| {
        if (h.contains(l, " build ") and h.contains(l, "/natives/libcxxshim.a") and h.contains(l, "-Xlinker -lc++")) with_tail = true;
    }
    rep.check("the compiler's link line of the program holds the archive and -Xlinker -lc++", with_tail, logged);

    // 4. mopm pack of both packages; the staged set.
    const dist = try h.join(a, &.{ work, "dist" });
    const Pack = struct { name: []const u8, file: []const u8, bytes: []const u8, manifest_sha256: []const u8 };
    var packs = std.ArrayList(Pack).init(a);
    for ([_][]const u8{ "cxxlib", "cxxapp" }) |name| {
        var args = std.ArrayList([]const u8).init(a);
        try args.appendSlice(&.{ "pack", "--compiler", "1.0.0", "--manifest", if (std.mem.eql(u8, name, "cxxlib")) "cxxlib/mopm.toml" else "mopm.toml", "-o", dist, "--mojoc", try h.fmt(a, "{s}={s}/{s}.mojoc", .{ subdir, deps, name }) });
        if (std.mem.eql(u8, name, "cxxlib")) try args.appendSlice(&.{ "--native", try h.fmt(a, "cxxshim={s}:{s}", .{ subdir, archive_path }) });
        r = try c.mopmRun(&env, ws, args.items);
        try c.must(try h.fmt(a, "mopm pack {s}", .{name}), r);
        const file = try h.fmt(a, "mojo-{s}-1.0.0-mojo1.0.0_0.conda", .{name});
        try packs.append(.{ .name = name, .file = file, .bytes = try h.readFile(a, try h.join(a, &.{ dist, subdir, file })), .manifest_sha256 = try valueOf(a, r.text, "manifest_sha256") });
    }
    {
        var plan = std.ArrayList(u8).init(a);
        try plan.appendSlice("{\"version\":1,\"members\":[");
        for (packs.items, 0..) |p, i| {
            if (i > 0) try plan.append(',');
            try plan.writer().print(
                "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
                .{ p.name, p.manifest_sha256, subdir, p.file, try sha256Hex(a, p.bytes), p.bytes.len },
            );
        }
        try plan.appendSlice("]}\n");
        try h.writeFile(try h.join(a, &.{ dist, "plan.json" }), plan.items);
    }

    // 5. A fresh project locks and syncs the set; `mopm build` links the program against the installed set.
    var fake = try h.Fake.start(a, try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"), try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const consumer = try h.join(a, &.{ work, "consumer" });
    try h.writeFile(try h.join(a, &.{ consumer, "mopm.toml" }), "[package]\nname = \"consumer\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n[dependencies]\n");
    try h.writeFile(try h.join(a, &.{ consumer, "main.mojo" }), "from cxxapp import plus_one\nfrom cxxlib import cxx_answer\n\n\ndef main():\n    print(\"cxx\", cxx_answer())\n    print(\"app\", plus_one())\n");
    r = try c.mopmRun(&env, consumer, &.{ "add", "cxxapp@=1.0.0", "--registry", fake.base, "--overlay", dist });
    try c.must("mopm add --overlay locks the staged set in a fresh project", r);
    const consumer_lock = try h.readFile(a, try h.join(a, &.{ consumer, "mopm.lock" }));
    rep.check("the lock carries link = [\"c++\"] for the native", h.contains(consumer_lock, "\"link\": [\n            \"c++\"\n          ]"), consumer_lock);
    r = try c.mopmRun(&env, consumer, &.{ "sync", "--locked", "--overlay", dist, "--registry", fake.base, "--pixi", c.fake_pixi });
    try c.must("mopm sync --locked --overlay installs the set", r);
    const env_dir = try h.join(a, &.{ consumer, ".mopm/.pixi/envs/default" });
    const installed = h.readFile(a, try h.join(a, &.{ env_dir, "lib/libcxxshim.a" })) catch "";
    rep.check("the installed environment holds lib/libcxxshim.a, byte for byte the archive that was built", installed.len > 0 and std.mem.eql(u8, installed, archive_bytes), "lib/libcxxshim.a is missing or differs");
    const meta = h.readFile(a, try h.join(a, &.{ env_dir, "lib/mojo/cxxlib.mopm.json" })) catch "";
    rep.check("the installed metadata of cxxlib carries \"link\":[\"c++\"]", h.contains(meta, "\"link\":[\"c++\"]"), meta);
    try m.prefix(env_dir, true);
    const build_env = try c.env();
    const consumer_bin = try h.join(a, &.{ work, "consumer_demo" });
    r = try c.mopmRun(&build_env, consumer, &.{ "build", "main.mojo", "-o", consumer_bin, "--prefix", env_dir });
    try c.must("mopm build: the program against the installed set links libcxxshim.a and -lc++", r);
    try runCxxProgram(&c, "the program built by mopm build against the installed set", consumer_bin);
}

/// The program `path`, run in an empty environment: it prints what the C++ code computes (42) and what the Mojo above it adds
/// (43). Whether the binary names libc++.so as a needed library is printed, for the record.
fn runCxxProgram(c: *Ctx, what: []const u8, path: []const u8) !void {
    const a = c.a;
    var empty = std.process.EnvMap.init(a);
    const r = try h.run(a, &.{path}, &empty, .{});
    c.rep.check(try h.fmt(a, "{s}: runs in an empty environment and prints what the C++ code computes", .{what}), !r.signaled and r.code == 0 and h.contains(r.text, "cxx 42\n") and h.contains(r.text, "app 43\n"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
    const bytes = h.readFile(a, path) catch "";
    std.debug.print("INFO {s}: the binary names libc++.so as a needed library: {}\n", .{ what, h.contains(bytes, "libc++.so") });
}
