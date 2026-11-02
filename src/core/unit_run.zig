//! `mopm unit build` and `mopm unit test` (spec/unit-graph.md, "Running a
//! unit"): one unit of a unit graph, built from declared inputs only.
//!
//! A unit is built offline. Nothing is resolved or fetched; `verify` checks
//! every input the graph declares for the unit (its sources by sha256, the
//! `.mojoc` of each dependency, its native libraries by sha256, the pinned
//! toolchain by closure hash) and refuses on the first that is missing or
//! different, before any program runs. Then the sources are staged, and the
//! pinned wrapper `<toolchain>/mojo_compile` is executed with an empty
//! environment (a test binary gets only `LD_LIBRARY_PATH=<toolchain>/lib`, when
//! that directory exists): one implementation of "run the hermetic Mojo compiler", the
//! toolchain's own. mopm builds the wrapper's command line and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const unit_graph = @import("unit_graph.zig");

pub const Refused = error{Refused};

/// Where each kind of input is. Every path may be relative to the working
/// directory; `argv` wants them absolute.
pub const Dirs = struct {
    /// The member sources: a path of the graph is relative to this.
    src: []const u8,
    /// The `.mojoc` of every dependency, flat, as `<package>.mojoc`.
    deps: []const u8,
    /// The pinned toolchain: `mojo_compile` and `CLOSURE_SHA256`.
    toolchain: []const u8,
    /// The native libraries, flat, as `<soname>`.
    natives: []const u8,
    /// Where the outputs of the unit go.
    out: []const u8,
    /// Where the sources and the dependencies are staged for the compiler.
    stage: []const u8,
    /// The value of `mojo build --target-cpu` (`target_cpu.mojoValue`), or null for no CPU argument.
    /// Only a test or a binary is code generation; a `.mojoc` holds none and `mojo precompile`
    /// rejects the option, so a library gets no CPU argument whatever this is.
    target_cpu: ?[]const u8 = null,
};

pub const wrapper_name = "mojo_compile";
pub const closure_file = "CLOSURE_SHA256";

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) (Refused || Allocator.Error) {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

/// The file name of the `.mojoc` of a library or prebuilt unit.
pub fn mojocName(u: unit_graph.Unit) []const u8 {
    if (std.mem.eql(u8, u.kind, "prebuilt")) return std.fs.path.basename(u.mojoc);
    return if (u.outputs.len > 0) u.outputs[0] else "";
}

fn join(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ a, b });
}

fn readInput(arena: Allocator, dir: []const u8, rel: []const u8) ?[]u8 {
    const full = std.fs.path.join(arena, &.{ dir, rel }) catch return null;
    return std.fs.cwd().readFileAlloc(arena, full, 256 << 20) catch null;
}

/// Refuses unless every input of unit `idx` is present and is what the graph
/// says. Reads files; runs no program.
pub fn verify(arena: Allocator, g: unit_graph.Graph, idx: usize, d: Dirs, why: *[]const u8) !void {
    const u = g.units[idx];
    if (std.mem.eql(u8, u.kind, "prebuilt")) {
        return refuse(arena, why, "{s} is a prebuilt unit: its .mojoc is fetched and unpacked, not built", .{u.id});
    }

    if (std.mem.eql(u8, u.kind, "native")) {
        const what = if (u.provided) "the build system supplies the archive" else "the build system compiles its C sources into";
        return refuse(arena, why, "{s} is a native unit: {s} {s}; 'mopm unit build' builds Mojo units", .{ u.id, what, u.soname });
    }

    // The toolchain: the closure the graph pins, and the wrapper.
    const pinned = readInput(arena, d.toolchain, closure_file) orelse {
        return refuse(arena, why, "missing input: {s}/{s}; the toolchain directory must name its closure", .{ d.toolchain, closure_file });
    };
    const have = std.mem.trim(u8, pinned, " \r\n\t");
    if (!std.mem.eql(u8, have, g.toolchain.closure_sha256)) {
        return refuse(arena, why, "the toolchain at {s} is closure {s}, but the graph pins {s}", .{ d.toolchain, have, g.toolchain.closure_sha256 });
    }
    const wrapper = try join(arena, d.toolchain, wrapper_name);
    std.fs.cwd().access(wrapper, .{}) catch {
        return refuse(arena, why, "missing input: {s}", .{wrapper});
    };

    // The sources.
    for (u.srcs) |s| {
        const bytes = readInput(arena, d.src, s.path) orelse {
            return refuse(arena, why, "missing input: {s} (a source of {s}) is not in {s}", .{ s.path, u.id, d.src });
        };
        const got = try unit_graph.sha256Hex(arena, bytes);
        if (!std.mem.eql(u8, got, s.sha256)) {
            return refuse(arena, why, "input {s} has sha256 {s}, but the graph declares {s} for {s}", .{ s.path, got, s.sha256, u.id });
        }
    }

    // The dependencies' .mojoc, all of the closure.
    const closure = try unit_graph.closureOf(arena, g, idx);
    for (closure) |di| {
        const dep = g.units[di];
        const name = mojocName(dep);
        if (name.len == 0) return refuse(arena, why, "{s} declares no .mojoc output", .{dep.id});
        const full = try join(arena, d.deps, name);
        const st = std.fs.cwd().statFile(full) catch {
            return refuse(arena, why, "missing input: {s}, the .mojoc of {s} (a dependency of {s})", .{ full, dep.id, u.id });
        };
        if (st.size == 0) return refuse(arena, why, "input {s}, the .mojoc of {s}, is empty", .{ full, dep.id });
    }

    // The native libraries, each by sha256.
    for (u.natives) |n| {
        if (n.built.len > 0) {
            // A product of this build, so no hash is known before it: the file must be there and be an archive.
            try verifyBuilt(arena, u, n, d, why);
            continue;
        }
        const bytes = readInput(arena, d.natives, n.soname) orelse {
            return refuse(arena, why, "missing input: native library {s} ({s}) is not in {s}", .{ n.soname, n.id, d.natives });
        };
        const got = try unit_graph.sha256Hex(arena, bytes);
        if (!std.mem.eql(u8, got, n.sha256)) {
            return refuse(arena, why, "native library {s} has sha256 {s}, but the graph declares {s}", .{ n.soname, got, n.sha256 });
        }
    }
}

/// The first bytes of a Unix archive (`ar`).
const ar_magic = "!<arch>\n";

/// A `built` native of unit `u`: `<soname>` in the natives directory, and an archive (it starts with `!<arch>\n`).
fn verifyBuilt(arena: Allocator, u: unit_graph.Unit, n: unit_graph.NativeRef, d: Dirs, why: *[]const u8) !void {
    const full = try join(arena, d.natives, n.soname);
    const file = std.fs.cwd().openFile(full, .{}) catch {
        return refuse(arena, why, "missing input: {s}, the archive of {s} (a native library of {s}) is not in {s}", .{ n.soname, n.built, u.id, d.natives });
    };
    defer file.close();
    var head: [ar_magic.len]u8 = undefined;
    const got = file.readAll(&head) catch 0;
    if (got != ar_magic.len or !std.mem.eql(u8, &head, ar_magic)) {
        return refuse(arena, why, "native library {s}, the archive of {s} (a native library of {s}), is not a static archive: it does not start with !<arch>", .{ n.soname, n.built, u.id });
    }
}

/// How the unit is compiled.
pub const Mode = enum { build, run_test };

pub const Plan = struct {
    /// The wrapper and its arguments.
    argv: []const []const u8,
    /// What the compile makes, under `out`.
    product: []const u8,
    /// For a test: the binary to run once built; else empty.
    exe: []const u8,
    /// The file a passing test leaves under `out`; else empty.
    marker: []const u8,
};

fn isLib(u: unit_graph.Unit) bool {
    return std.mem.eql(u8, u.kind, "lib");
}

/// The command line of the wrapper for unit `idx`. `d`'s paths must be
/// absolute (the wrapper runs elsewhere); pure, it touches no file.
pub fn argv(arena: Allocator, g: unit_graph.Graph, idx: usize, d: Dirs) !Plan {
    const u = g.units[idx];
    var a = std.ArrayList([]const u8).init(arena);
    try a.append(try join(arena, d.toolchain, wrapper_name));
    const stage_src = try join(arena, d.stage, "src");
    const is_lib = isLib(u);
    if (!is_lib) try a.append("--runpath=$ORIGIN/lib");
    // The wrapper takes the root to be the directory of the package it compiles (a library) or the tree the
    // sources are in (a test or binary): it replaces the argument that names the root by its basename, so
    // the `.mojoc` records `<package>/<file>.mojo`, not the staged path.
    const root = if (is_lib) try join(arena, stage_src, u.package) else stage_src;
    try a.append(try std.fmt.allocPrint(arena, "--source-root={s}", .{root}));
    try a.append("--");
    try a.append(if (is_lib) "precompile" else "build");
    if (!is_lib) {
        if (d.target_cpu) |cpu| {
            try a.append("--target-cpu");
            try a.append(cpu);
        }
        if (u.profile) |p| {
            try a.append("-D");
            try a.append(try std.fmt.allocPrint(arena, "ASSERT={s}", .{p.assert}));
            try a.append("--optimization-level");
            try a.append(try std.fmt.allocPrint(arena, "{d}", .{p.opt}));
            if (p.debug) try a.append("-g");
        }
    }
    for (try unit_graph.closureOf(arena, g, idx)) |di| {
        const name = mojocName(g.units[di]);
        const stem = name[0 .. name.len - ".mojoc".len];
        try a.append(try std.fmt.allocPrint(arena, "-I{s}/deps/{s}", .{ d.stage, stem }));
    }
    var product: []const u8 = "";
    var exe: []const u8 = "";
    var marker: []const u8 = "";
    if (is_lib) {
        try a.append(try join(arena, stage_src, u.package));
        product = try join(arena, d.out, u.outputs[0]);
        try a.append("-o");
        try a.append(product);
    } else {
        if (u.srcs.len != 1) return error.BadUnit;
        try a.append(try join(arena, stage_src, u.srcs[0].path));
        const out0 = u.outputs[0];
        const is_test = std.mem.eql(u8, u.kind, "test");
        const bin_name = if (is_test) out0[0 .. out0.len - ".pass".len] else out0;
        product = try join(arena, d.out, bin_name);
        try a.append("-o");
        try a.append(product);
        for (u.natives) |n| {
            try a.append("-Xlinker");
            try a.append(try join(arena, d.natives, n.soname));
        }
        // The system libraries the archives leave symbols to come after every archive, once each.
        for (u.link) |name| {
            try a.append("-Xlinker");
            try a.append(try std.fmt.allocPrint(arena, "-l{s}", .{name}));
        }
        if (is_test) {
            exe = product;
            marker = try join(arena, d.out, out0);
        }
    }
    return .{ .argv = a.items, .product = product, .exe = exe, .marker = marker };
}

fn copyInto(arena: Allocator, from: []const u8, to: []const u8) !void {
    if (std.fs.path.dirname(to)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.cwd().copyFile(from, std.fs.cwd(), to, .{});
    _ = arena;
}

/// Puts the sources and the dependencies where `argv` expects them: the
/// sources of a library under `<stage>/src/<package>/` (relative to its
/// root), those of a test or binary under `<stage>/src/<path>`, each
/// dependency's `.mojoc` alone in `<stage>/deps/<package>/`, and the native
/// libraries beside the binary in `<out>/lib/`.
pub fn stage(arena: Allocator, g: unit_graph.Graph, idx: usize, d: Dirs) !void {
    const u = g.units[idx];
    const stage_src = try join(arena, d.stage, "src");
    try std.fs.cwd().makePath(stage_src);
    try std.fs.cwd().makePath(d.out);
    for (u.srcs) |s| {
        const from = try join(arena, d.src, s.path);
        const rel = if (isLib(u)) blk: {
            const root = u.root;
            const inside = if (root.len == 0) s.path else if (std.mem.startsWith(u8, s.path, root) and s.path.len > root.len and s.path[root.len] == '/') s.path[root.len + 1 ..] else return error.BadUnit;
            break :blk try join(arena, u.package, inside);
        } else s.path;
        try copyInto(arena, from, try join(arena, stage_src, rel));
    }
    for (try unit_graph.closureOf(arena, g, idx)) |di| {
        const name = mojocName(g.units[di]);
        const stem = name[0 .. name.len - ".mojoc".len];
        const to = try std.fmt.allocPrint(arena, "{s}/deps/{s}/{s}", .{ d.stage, stem, name });
        try copyInto(arena, try join(arena, d.deps, name), to);
    }
    if (!isLib(u)) {
        for (u.natives) |n| {
            // An archive is linked into the binary: there is nothing to load from beside it.
            if (n.kind == .static) continue;
            try copyInto(arena, try join(arena, d.natives, n.soname), try std.fmt.allocPrint(arena, "{s}/lib/{s}", .{ d.out, n.soname }));
        }
    }
}

pub const runtime_lib_dir = "lib";

/// The runtime environment of a test binary: the toolchain's own `lib/` (where
/// the compiler's runtime, `libKGENCompilerRTShared.so`, is), as the value of
/// `LD_LIBRARY_PATH`, when the toolchain directory has one; else null. This is
/// declared by the toolchain directory the graph's closure hash names, never
/// read from the host.
pub fn runtimeLibs(arena: Allocator, d: Dirs) !?[]const u8 {
    const dir = try join(arena, d.toolchain, runtime_lib_dir);
    const st = std.fs.cwd().statFile(dir) catch return null;
    if (st.kind != .directory) return null;
    return dir;
}

/// Runs `args` with an empty environment, or with the one variable
/// `LD_LIBRARY_PATH` when `ld_library_path` is set; the exit code, or 255 when it did
/// not exit.
pub fn exec(arena: Allocator, args: []const []const u8, cwd: ?[]const u8, ld_library_path: ?[]const u8) !u8 {
    var env = std.process.EnvMap.init(arena);
    if (ld_library_path) |p| try env.put("LD_LIBRARY_PATH", p);
    var child = std.process.Child.init(args, arena);
    child.env_map = &env;
    child.cwd = cwd;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 255,
    };
}

/// Absolute forms of `d`'s paths (made, where they are outputs).
pub fn absolute(arena: Allocator, d: Dirs) !Dirs {
    const cwd = std.fs.cwd();
    try cwd.makePath(d.out);
    try cwd.makePath(d.stage);
    return .{
        .src = try cwd.realpathAlloc(arena, d.src),
        .deps = cwd.realpathAlloc(arena, d.deps) catch try join(arena, try cwd.realpathAlloc(arena, "."), d.deps),
        .toolchain = try cwd.realpathAlloc(arena, d.toolchain),
        .natives = cwd.realpathAlloc(arena, d.natives) catch try join(arena, try cwd.realpathAlloc(arena, "."), d.natives),
        .out = try cwd.realpathAlloc(arena, d.out),
        .stage = try cwd.realpathAlloc(arena, d.stage),
        .target_cpu = d.target_cpu,
    };
}

/// Builds unit `idx` (and, for `run_test`, runs it). Returns the exit code
/// of the first program that failed, or 0. A refusal is `error.Refused` with
/// `why` set, before any program has run.
pub fn run(arena: Allocator, g: unit_graph.Graph, idx: usize, mode: Mode, d0: Dirs, why: *[]const u8) !u8 {
    const u = g.units[idx];
    if (mode == .run_test and !std.mem.eql(u8, u.kind, "test")) {
        return refuse(arena, why, "{s} is a {s} unit; 'mopm unit test' runs test units", .{ u.id, u.kind });
    }
    try verify(arena, g, idx, d0, why);
    const d = try absolute(arena, d0);
    try stage(arena, g, idx, d);
    const plan = try argv(arena, g, idx, d);
    const code = try exec(arena, plan.argv, d.stage, null);
    if (code != 0) return code;
    const made = std.fs.cwd().statFile(plan.product) catch return refuse(arena, why, "the compiler exited 0 but {s} is missing", .{plan.product});
    if (made.size == 0) return refuse(arena, why, "the compiler exited 0 but {s} is empty", .{plan.product});
    if (mode == .run_test) {
        const test_code = try exec(arena, &.{plan.exe}, d.stage, try runtimeLibs(arena, d));
        if (test_code != 0) return test_code;
        try std.fs.cwd().writeFile(plan.marker, "pass\n");
    }
    return 0;
}

// ---------------------------------------------------------------------- tests

const hex_c = "c" ** 64;
const src_p = "def p():\n    pass\n";
const src_t = "from p import p\n\ndef main():\n    p()\n";
const native_bytes = "ELF-stand-in\n";

fn sha(a: Allocator, bytes: []const u8) ![]const u8 {
    return unit_graph.sha256Hex(a, bytes);
}

/// The fixture graph: p (a library) depends on d (prebuilt) and its native
/// library; t is p's test.
fn fixtureGraph(a: Allocator) !unit_graph.Graph {
    const p_srcs = try a.dupe(unit_graph.Src, &.{.{ .path = "src/p/__init__.mojo", .sha256 = try sha(a, src_p) }});
    const t_srcs = try a.dupe(unit_graph.Src, &.{.{ .path = "tests/test_p.mojo", .sha256 = try sha(a, src_t) }});
    const natives = try a.dupe(unit_graph.NativeRef, &.{.{ .id = "n", .soname = "libn.so.1", .sha256 = try sha(a, native_bytes), .package = "d" }});
    const units = try a.dupe(unit_graph.Unit, &.{
        .{ .id = "d@1.0.0#mojo1.0.0/lib", .package = "d", .version = "1.0.0", .kind = "prebuilt", .mojoc = "lib/mojo/d.mojoc", .natives = natives },
        .{
            .id = "p@2.0.0#mojo1.0.0/lib",
            .package = "p",
            .version = "2.0.0",
            .kind = "lib",
            .root = "src/p",
            .srcs = p_srcs,
            .deps = &.{"d@1.0.0#mojo1.0.0/lib"},
            .natives = natives,
            .profile = .{ .opt = 1, .assert = "all", .debug = false },
            .outputs = &.{"p.mojoc"},
        },
        .{
            .id = "p@2.0.0#mojo1.0.0/test:tests/test_p.mojo",
            .package = "p",
            .version = "2.0.0",
            .kind = "test",
            .srcs = t_srcs,
            .deps = &.{"p@2.0.0#mojo1.0.0/lib"},
            .natives = natives,
            .profile = .{ .opt = 1, .assert = "all", .debug = false },
            .outputs = &.{"test_p.pass"},
        },
    });
    return .{
        .package = "p@2.0.0",
        .mojo = "1.0.0",
        .toolchain = .{
            .mojo = "1.0.0",
            .subdir = "linux-64",
            .cc_target = "x86_64-linux-gnu.2.34",
            .closure_sha256 = hex_c,
            .zig = .{ .version = "0.12.0", .url = "https://example.invalid/zig", .sha256 = "f" ** 64, .size = 1 },
            .components = &.{},
        },
        .units = units,
    };
}

/// A workspace for `fixtureGraph`: sources, the dependency's .mojoc, the
/// native library and a toolchain directory. Paths are relative to `tmp`.
fn writeInputs(tmp: std.fs.Dir) !void {
    try tmp.makePath("w/src/p");
    try tmp.makePath("w/tests");
    try tmp.makePath("deps");
    try tmp.makePath("natives");
    try tmp.makePath("tc");
    try tmp.writeFile("w/src/p/__init__.mojo", src_p);
    try tmp.writeFile("w/tests/test_p.mojo", src_t);
    try tmp.writeFile("deps/d.mojoc", "d.mojoc bytes\n");
    try tmp.writeFile("deps/p.mojoc", "p.mojoc bytes\n");
    try tmp.writeFile("natives/libn.so.1", native_bytes);
    try tmp.writeFile("tc/CLOSURE_SHA256", hex_c ++ "\n");
    try tmp.writeFile("tc/mojo_compile", "stand-in\n");
}

fn dirsIn(a: Allocator, root: []const u8) !Dirs {
    return .{
        .src = try join(a, root, "w"),
        .deps = try join(a, root, "deps"),
        .toolchain = try join(a, root, "tc"),
        .natives = try join(a, root, "natives"),
        .out = try join(a, root, "out"),
        .stage = try join(a, root, "stage"),
    };
}

fn expectRefusal(a: Allocator, g: unit_graph.Graph, idx: usize, d: Dirs, want: []const u8) !void {
    var why: []const u8 = "";
    if (verify(a, g, idx, d, &why)) |_| {
        std.debug.print("accepted, want a refusal containing: {s}\n", .{want});
        return error.TestUnexpectedResult;
    } else |e| if (e != error.Refused) return e;
    if (std.mem.indexOf(u8, why, want) == null) {
        std.debug.print("refused with '{s}', want '{s}'\n", .{ why, want });
        return error.TestUnexpectedResult;
    }
}

test "a unit with every declared input verifies; each input missing or different is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    const g = try fixtureGraph(a);
    const root = try tmp.dir.realpathAlloc(a, ".");
    const d = try dirsIn(a, root);
    const lib = g.find("p@2.0.0#mojo1.0.0/lib").?;
    const tst = g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?;
    var why: []const u8 = "";
    try verify(a, g, lib, d, &why);
    try verify(a, g, tst, d, &why);

    // A prebuilt unit is fetched, not built.
    try expectRefusal(a, g, g.find("d@1.0.0#mojo1.0.0/lib").?, d, "is a prebuilt unit");

    // A source that is not there.
    try tmp.dir.deleteFile("w/src/p/__init__.mojo");
    try expectRefusal(a, g, lib, d, "missing input: src/p/__init__.mojo");
    // A source that is not the bytes the graph hashed.
    try tmp.dir.writeFile("w/src/p/__init__.mojo", src_p ++ "# edited\n");
    try expectRefusal(a, g, lib, d, "input src/p/__init__.mojo has sha256");
    try tmp.dir.writeFile("w/src/p/__init__.mojo", src_p);
    try verify(a, g, lib, d, &why);

    // A dependency's .mojoc that is not there: the direct one and a transitive one.
    try tmp.dir.deleteFile("deps/d.mojoc");
    try expectRefusal(a, g, lib, d, "missing input");
    try expectRefusal(a, g, lib, d, "d.mojoc, the .mojoc of d@1.0.0#mojo1.0.0/lib");
    try tmp.dir.writeFile("deps/d.mojoc", "d.mojoc bytes\n");
    try tmp.dir.deleteFile("deps/p.mojoc");
    try expectRefusal(a, g, tst, d, "p.mojoc, the .mojoc of p@2.0.0#mojo1.0.0/lib (a dependency of p@2.0.0#mojo1.0.0/test:tests/test_p.mojo)");
    try tmp.dir.writeFile("deps/p.mojoc", "p.mojoc bytes\n");
    try tmp.dir.writeFile("deps/d.mojoc", "");
    try expectRefusal(a, g, lib, d, "is empty");
    try tmp.dir.writeFile("deps/d.mojoc", "d.mojoc bytes\n");

    // A native library that is not there, and one that is other bytes.
    try tmp.dir.deleteFile("natives/libn.so.1");
    try expectRefusal(a, g, lib, d, "native library libn.so.1 (n) is not in");
    try tmp.dir.writeFile("natives/libn.so.1", "ELF-other\n");
    try expectRefusal(a, g, lib, d, "native library libn.so.1 has sha256");
    try tmp.dir.writeFile("natives/libn.so.1", native_bytes);

    // A toolchain that is not the pinned closure, and one that names none.
    try tmp.dir.writeFile("tc/CLOSURE_SHA256", "d" ** 64 ++ "\n");
    try expectRefusal(a, g, lib, d, "but the graph pins " ++ hex_c);
    try tmp.dir.deleteFile("tc/CLOSURE_SHA256");
    try expectRefusal(a, g, lib, d, "CLOSURE_SHA256");
    try tmp.dir.writeFile("tc/CLOSURE_SHA256", hex_c ++ "\n");
    try tmp.dir.deleteFile("tc/mojo_compile");
    try expectRefusal(a, g, lib, d, "missing input: ");
    try tmp.dir.writeFile("tc/mojo_compile", "stand-in\n");
    try verify(a, g, lib, d, &why);
}

// Defect it catches: a test or program of a C++ archive's consumer linked without libc++ by `mopm unit` (the same link
// the graph describes to a build system); the -l ahead of the archives, or once per archive; a library unit given one.
test "a unit's system libraries come last on the link line of a test, each once, and not at all on a library's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g0 = try fixtureGraph(a);
    const units = try a.dupe(unit_graph.Unit, g0.units);
    for (units) |*u| u.link = &.{ "c++", "m" };
    var g = g0;
    g.units = units;
    const d = Dirs{ .src = "/s", .deps = "/d", .toolchain = "/t", .natives = "/n", .out = "/o", .stage = "/g" };

    const tst = try argv(a, g, g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?, d);
    const tail = [_][]const u8{ "-Xlinker", "/n/libn.so.1", "-Xlinker", "-lc++", "-Xlinker", "-lm" };
    try std.testing.expect(tst.argv.len > tail.len);
    for (tail, tst.argv[tst.argv.len - tail.len ..]) |w, got| try std.testing.expectEqualStrings(w, got);

    const lib = try argv(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, d);
    for (lib.argv) |arg| try std.testing.expect(!std.mem.startsWith(u8, arg, "-l") and !std.mem.eql(u8, arg, "-Xlinker"));
}

test "the wrapper gets the staged tree, the dependencies' -I directories and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try fixtureGraph(a);
    const d = Dirs{ .src = "/s", .deps = "/d", .toolchain = "/t", .natives = "/n", .out = "/o", .stage = "/g" };

    const lib = try argv(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, d);
    const want_lib = [_][]const u8{ "/t/mojo_compile", "--source-root=/g/src/p", "--", "precompile", "-I/g/deps/d", "/g/src/p", "-o", "/o/p.mojoc" };
    try std.testing.expectEqual(want_lib.len, lib.argv.len);
    for (want_lib, lib.argv) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expectEqualStrings("/o/p.mojoc", lib.product);
    try std.testing.expectEqualStrings("", lib.exe);

    const tst = try argv(a, g, g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?, d);
    const want_test = [_][]const u8{
        "/t/mojo_compile", "--runpath=$ORIGIN/lib", "--source-root=/g/src", "--", "build", "-D", "ASSERT=all", "--optimization-level", "1",
        "-I/g/deps/d",     "-I/g/deps/p",           "/g/src/tests/test_p.mojo", "-o", "/o/test_p", "-Xlinker", "/n/libn.so.1",
    };
    try std.testing.expectEqual(want_test.len, tst.argv.len);
    for (want_test, tst.argv) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expectEqualStrings("/o/test_p", tst.exe);
    try std.testing.expectEqualStrings("/o/test_p.pass", tst.marker);
}

test "--target-cpu: each level reaches a test's compiler command, right after build, and no level adds nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try fixtureGraph(a);
    const target_cpu = @import("target_cpu.zig");
    const tid = g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?;
    const bid = g.find("p@2.0.0#mojo1.0.0/lib").?;
    var d = Dirs{ .src = "/s", .deps = "/d", .toolchain = "/t", .natives = "/n", .out = "/o", .stage = "/g" };

    // No level: no CPU argument anywhere.
    for ((try argv(a, g, tid, d)).argv) |x| try std.testing.expect(!std.mem.eql(u8, x, "--target-cpu"));

    for ([_][]const u8{ "x86-64", "x86-64-v2", "x86-64-v3", "x86-64-v4" }) |level| {
        d.target_cpu = try target_cpu.mojoValue(level);
        const t = (try argv(a, g, tid, d)).argv;
        // [wrapper, --runpath, --source-root, --, build, --target-cpu, <level>, -D ...]
        try std.testing.expectEqualStrings("build", t[4]);
        try std.testing.expectEqualStrings("--target-cpu", t[5]);
        try std.testing.expectEqualStrings(level, t[6]);
        try std.testing.expectEqualStrings("-D", t[7]);
        // Exactly one CPU option.
        var n: usize = 0;
        for (t) |x| {
            if (std.mem.eql(u8, x, "--target-cpu")) n += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), n);
        // A library is not code generation: its command is the same at every level.
        for ((try argv(a, g, bid, d)).argv) |x| try std.testing.expect(!std.mem.eql(u8, x, "--target-cpu"));
    }
}

test "mopm unit build stages the tree, runs the wrapper in an empty environment and finds the output" {
    const child_z = std.posix.getenv("MOPM_TEST_CHILD") orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    // The stand-in wrapper: tests/drivers/proc_child.zig in its mojo_compile mode.
    const child: []const u8 = child_z;
    try std.fs.cwd().copyFile(child, tmp.dir, "tc/mojo_compile", .{});
    const g = try fixtureGraph(a);
    const root = try tmp.dir.realpathAlloc(a, ".");
    const d = try dirsIn(a, root);
    var why: []const u8 = "";
    const code = run(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, .build, d, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(u8, 0), code);
    const made = try tmp.dir.readFileAlloc(a, "out/p.mojoc", 1 << 20);
    try std.testing.expectEqualStrings("precompile\np\nenv=0\n", made);
    // The staged tree holds the sources of the package under its own name, and the dependency alone in its -I directory.
    _ = try tmp.dir.statFile("stage/src/p/__init__.mojo");
    _ = try tmp.dir.statFile("stage/deps/d/d.mojoc");

    // A test unit builds its binary; `unit test` would then run it.
    const t = run(a, g, g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?, .build, d, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(u8, 0), t);
    _ = try tmp.dir.statFile("out/test_p");
    _ = try tmp.dir.statFile("out/lib/libn.so.1");

    // A refusal happens before the wrapper runs: nothing new is written.
    try tmp.dir.deleteFile("w/src/p/__init__.mojo");
    try tmp.dir.deleteFile("out/p.mojoc");
    try std.testing.expectError(error.Refused, run(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, .build, d, &why));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out/p.mojoc"));
    // `unit test` on a library is refused.
    try std.testing.expectError(error.Refused, run(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, .run_test, d, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "runs test units") != null);
}

/// Builds the library of the fixture graph in a fresh workspace, staged at `stage_rel`; the bytes of its `.mojoc`.
fn buildLibAt(a: Allocator, child: []const u8, stage_rel: []const u8) ![]const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    try std.fs.cwd().copyFile(child, tmp.dir, "tc/mojo_compile", .{});
    const g = try fixtureGraph(a);
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = try dirsIn(a, root);
    d.stage = try join(a, root, stage_rel);
    var why: []const u8 = "";
    const code = run(a, g, g.find("p@2.0.0#mojo1.0.0/lib").?, .build, d, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(u8, 0), code);
    return tmp.dir.readFileAlloc(a, "out/p.mojoc", 1 << 20);
}

// Defect it catches: `--source-root` naming the parent of the package, not the package. The wrapper then
// replaces no argument, the compiler is given the absolute staged path and the `.mojoc` records it, so
// one package staged at two paths is two different files. Defect caught: argv's `root` is `stage_src`.
test "a library's .mojoc is the same bytes when it is staged at two different paths" {
    const child_z = std.posix.getenv("MOPM_TEST_CHILD") orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = try buildLibAt(a, child_z, "stage");
    const two = try buildLibAt(a, child_z, "a/much/deeper/stage.x");
    try std.testing.expectEqualStrings(one, two);
    // And it names the package, as the wrapper's source root, not a staged path.
    try std.testing.expect(std.mem.indexOf(u8, one, "\np\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "stage") == null);
}

fn testEnvOf(a: Allocator, child: []const u8, with_lib: bool) ![]const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    try std.fs.cwd().copyFile(child, tmp.dir, "tc/mojo_compile", .{});
    if (with_lib) {
        try tmp.dir.makePath("tc/lib");
        try tmp.dir.writeFile("tc/lib/libKGENCompilerRTShared.so", "ELF\n");
    }
    const g = try fixtureGraph(a);
    const root = try tmp.dir.realpathAlloc(a, ".");
    const d = try dirsIn(a, root);
    var why: []const u8 = "";
    const code = run(a, g, g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?, .run_test, d, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(u8, 0), code);
    _ = try tmp.dir.statFile("out/test_p.pass");
    const got = try tmp.dir.readFileAlloc(a, "out/test_p.env", 1 << 16);
    // The path the toolchain is at differs per run: say it relative to the root.
    return std.mem.replaceOwned(u8, a, got, root, "<root>");
}

// Defect it catches: the test binary run with an empty environment cannot load
// libKGENCompilerRTShared.so. Defect caught: run passes null for the library path.
test "a unit test runs with LD_LIBRARY_PATH=<toolchain>/lib and nothing else; no lib dir, no variable" {
    const child_z = std.posix.getenv("MOPM_TEST_CHILD") orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("LD_LIBRARY_PATH=<root>/tc/lib\n", try testEnvOf(a, child_z, true));
    try std.testing.expectEqualStrings("", try testEnvOf(a, child_z, false));
}

// Defects it catches: the archives sorted by name on the way to the compiler (a library before the one it needs, so
// the linker drops the symbols the first leaves undefined); an archive copied beside the binary as if it were loaded
// at run time. Defect caught: argv sorts `u.natives` by soname; stage drops the `.static` skip.
test "a static archive is a linker input in the order the unit gives, and is not copied beside the binary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    const tls_bytes = "!<arch>\ntls\n";
    const crypto_bytes = "!<arch>\ncrypto\n";
    try tmp.dir.writeFile("natives/libtls_sys.a", tls_bytes);
    try tmp.dir.writeFile("natives/libcrypto_sys.a", crypto_bytes);

    var g = try fixtureGraph(a);
    const tid = g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?;
    const units = try a.dupe(unit_graph.Unit, g.units);
    // tls_sys needs crypto_sys, so it is first; by soname, libcrypto_sys.a would be.
    units[tid].natives = try a.dupe(unit_graph.NativeRef, &.{
        .{ .id = "tls_sys", .soname = "libtls_sys.a", .sha256 = try sha(a, tls_bytes), .package = "tls_sys", .kind = .static, .needs = &.{"libcrypto_sys.a"} },
        .{ .id = "crypto_sys", .soname = "libcrypto_sys.a", .sha256 = try sha(a, crypto_bytes), .package = "crypto_sys", .kind = .static },
        .{ .id = "n", .soname = "libn.so.1", .sha256 = try sha(a, native_bytes), .package = "d" },
    });
    g.units = units;
    const root = try tmp.dir.realpathAlloc(a, ".");
    const d = try dirsIn(a, root);

    const plan = try argv(a, g, tid, d);
    var linked = std.ArrayList([]const u8).init(a);
    for (plan.argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, "-Xlinker")) try linked.append(std.fs.path.basename(plan.argv[i + 1]));
    }
    const want = [_][]const u8{ "libtls_sys.a", "libcrypto_sys.a", "libn.so.1" };
    try std.testing.expectEqual(want.len, linked.items.len);
    for (want, linked.items) |w, got| try std.testing.expectEqualStrings(w, got);

    // Each archive is checked against its sha256 like any native library.
    var why: []const u8 = "";
    try verify(a, g, tid, d, &why);
    try tmp.dir.writeFile("natives/libcrypto_sys.a", "!<arch>\nother\n");
    try expectRefusal(a, g, tid, d, "native library libcrypto_sys.a has sha256");
    try tmp.dir.writeFile("natives/libcrypto_sys.a", crypto_bytes);

    // The shared object is copied beside the binary; the archives are not.
    try stage(a, g, tid, d);
    _ = try tmp.dir.statFile("out/lib/libn.so.1");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out/lib/libtls_sys.a"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out/lib/libcrypto_sys.a"));
}

// Defects it catches: a built archive taken on trust when it is missing or is not an archive (the link then fails with
// the linker's words, or links a text file's worth of nothing); a hash demanded of a file that is a product of this very
// build; an archive in the natives directory ordered after the library it is needed by.
test "a built native must be in the natives directory and be an archive, but has no hash to match; its native unit is not built by mopm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);

    var g = try fixtureGraph(a);
    const tid = g.find("p@2.0.0#mojo1.0.0/test:tests/test_p.mojo").?;
    const built_id = "native:p/shim";
    const units = try a.alloc(unit_graph.Unit, g.units.len + 1);
    @memcpy(units[0..g.units.len], g.units);
    units[g.units.len] = .{ .id = built_id, .package = "p", .version = "2.0.0", .kind = "native", .soname = "libshim.a", .outputs = &.{"libshim.a"} };
    // The shim comes first in the test's link line, before the prebuilt shared library.
    units[tid].natives = try a.dupe(unit_graph.NativeRef, &.{
        .{ .id = "shim", .soname = "libshim.a", .package = "p", .kind = .static, .built = built_id },
        .{ .id = "n", .soname = "libn.so.1", .sha256 = try sha(a, native_bytes), .package = "d" },
    });
    g.units = units;
    const root = try tmp.dir.realpathAlloc(a, ".");
    const d = try dirsIn(a, root);
    const who = "(a native library of p@2.0.0#mojo1.0.0/test:tests/test_p.mojo)";

    // Not there.
    try expectRefusal(a, g, tid, d, "missing input: libshim.a, the archive of native:p/shim " ++ who);
    // Not an archive: text, the magic cut short, nothing at all.
    for ([_][]const u8{ "int shim(void);\n", "!<arch>", "" }) |bytes| {
        try tmp.dir.writeFile("natives/libshim.a", bytes);
        try expectRefusal(a, g, tid, d, "native library libshim.a, the archive of native:p/shim " ++ who ++ ", is not a static archive: it does not start with !<arch>");
    }
    // An archive, whatever its bytes: there is no hash to hold it to.
    var why: []const u8 = "";
    try tmp.dir.writeFile("natives/libshim.a", "!<arch>\nfirst build\n");
    try verify(a, g, tid, d, &why);
    try tmp.dir.writeFile("natives/libshim.a", "!<arch>\nanother build, other bytes\n");
    try verify(a, g, tid, d, &why);
    // The prebuilt library beside it is still held to its hash.
    try tmp.dir.writeFile("natives/libn.so.1", "ELF-other\n");
    try expectRefusal(a, g, tid, d, "native library libn.so.1 has sha256");
    try tmp.dir.writeFile("natives/libn.so.1", native_bytes);

    // The archive is a linker input, in the order the unit gives; it is not copied beside the binary.
    const plan = try argv(a, g, tid, d);
    var linked = std.ArrayList([]const u8).init(a);
    for (plan.argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, "-Xlinker")) try linked.append(std.fs.path.basename(plan.argv[i + 1]));
    }
    try std.testing.expectEqual(@as(usize, 2), linked.items.len);
    try std.testing.expectEqualStrings("libshim.a", linked.items[0]);
    try std.testing.expectEqualStrings("libn.so.1", linked.items[1]);
    try stage(a, g, tid, d);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out/lib/libshim.a"));

    // The native unit itself is the build system's to build.
    try expectRefusal(a, g, g.find(built_id).?, d, "native:p/shim is a native unit: the build system compiles its C sources into libshim.a");
}
