//! `mopm build` for a package: the targets of mopm.toml, and the path dependencies a program can import.
//!
//! The fixture is tests/e2e/pathdep: `app` (a library `src/app` and the program `src/main.mojo`) has the path dependency
//! `greetlib`, which has the path dependency `basepkg`. `app` imports `greetlib`, which imports `basepkg`, so the program
//! prints a string only the three packages together make: "hello, path deps!".
//!
//! What it checks (each against what the user sees: the files, the program's output, the compiler's command line):
//!   1. `mopm build --print-cmd` prints a `mojo precompile` for the library and a `mojo build` for the program, each with
//!      one `-I` for `greetlib` and one for `basepkg` (a path dependency of a path dependency), and writes nothing.
//!   2. `mopm build` (no program) makes `target/build/app.mojoc` and `target/build/app`; the program, run in an empty
//!      environment, prints the string. The compiler's command lines are the printed ones.
//!   3. `mopm build --out-dir dist` writes there instead.
//!   4. `mopm build examples/dep_only.mojo -o out/dep_only` (a program, not the targets) also gets the `-I` of both
//!      path dependencies, and its output comes from `greetlib` and `basepkg`.
//!   5. Controls that must be able to fail: the same package without the `[dependencies]` entry gets no `-I` for the
//!      dependency (with the real Mojo it does not build); an environment without `bin/mojo` ends 127 naming the
//!      compiler; a package with no `[targets]` and a directory with no mopm.toml are refused, writing nothing.
//!
//! Two tiers run this file (BUCK): `build_targets` (pull requests) stands in for the Mojo compiler
//! (tests/drivers/fake_toolchain.zig), which logs every command line, so it checks what mopm asked the compiler for and
//! not what the compiler made of it; `build_targets_mojo` (after the merge) runs the real Mojo 1.0.0 and checks the
//! values. `zig build test-build-targets -Dmojo-env=<pixi prefix>` runs it natively on a GitHub runner (ci.yml, job
//! `mojo e2e`: Linux x86_64, Linux arm64, macOS arm64).
//!
//! Run by Buck2 as //:build_targets and //:build_targets_mojo; MOPM is the built CLI, and either MOJO_TOOLCHAIN (the real
//! Mojo) or FAKE_TOOLCHAIN (the stand-in) names the compiler.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

const program_prints = "hello, path deps!\n";
const file_prints = "hello, a file\n";

const manifest_without_dep =
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
    \\[dependencies]
    \\
    \\[targets]
    \\lib = { path = "src/app" }
    \\bins = [{ name = "app", path = "src/main.mojo" }]
    \\
;

const manifest_without_targets =
    \\[package]
    \\name = "empty"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
;

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    mopm: []const u8,
    /// The stand-in compiler (the unit tier), or null for the real Mojo.
    stand_in: ?[]const u8,

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

    /// A copy of the stand-in compiler as the executable `dest`.
    fn laySkeleton(c: *Ctx, dest: []const u8) !void {
        const cwd = std.fs.cwd();
        if (std.fs.path.dirname(dest)) |d| try cwd.makePath(d);
        try cwd.copyFile(c.stand_in.?, cwd, dest, .{});
        const f = try cwd.openFile(dest, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    /// The program `path` run in an empty environment: the real Mojo's program prints `want`; the stand-in prints a
    /// fixed line, so there only the exit status is checked.
    fn runProgram(c: *Ctx, what: []const u8, path: []const u8, want: []const u8) !void {
        const a = c.a;
        var empty = std.process.EnvMap.init(a);
        const r = try h.run(a, &.{path}, &empty, .{});
        if (c.stand_in == null) {
            c.rep.check(try h.fmt(a, "{s}: runs in an empty environment and prints what the three packages make", .{what}), !r.signaled and r.code == 0 and std.mem.eql(u8, r.text, want), try h.fmt(a, "exit {d}, want output {s}: {s}", .{ r.code, want, r.text }));
        } else {
            c.rep.check(try h.fmt(a, "{s}: the stand-in program runs (the unit tier does not check the values it prints)", .{what}), !r.signaled and r.code == 0, try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
        }
    }

    /// The size of the file at `path`, 0 when there is none.
    fn size(path: []const u8) u64 {
        const st = std.fs.cwd().statFile(path) catch return 0;
        return st.size;
    }

    fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
};

test "build_targets: mopm build with no program, and the path dependencies a program can import" {
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
    const work = try h.join(a, &.{ base_work, "pathdep" });
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
    var c = Ctx{ .a = a, .rep = rep, .mopm = try h.toolPathAbs(a, "MOPM"), .stand_in = stand_in };

    // The environment: a prefix with the compiler, no packages installed.
    const prefix = try h.join(a, &.{ work, "env" });
    if (stand_in != null) {
        try c.laySkeleton(try h.join(a, &.{ prefix, "bin/mojo" }));
        try cwd.makePath(try h.join(a, &.{ prefix, "lib/mojo" }));
    } else {
        try m.prefix(prefix, true);
    }
    const env_real = try cwd.realpathAlloc(a, prefix);

    // The three packages, side by side.
    const proj = try h.join(a, &.{ work, "proj" });
    try h.copyTree(a, try h.join(a, &.{ m.work, "tests/e2e/pathdep" }), proj);
    const root = try cwd.realpathAlloc(a, proj);
    const app = try h.join(a, &.{ root, "app" });
    // The path dependencies are named relative to the project directory, as mopm.toml writes them.
    const greet_i = "-I ../greetlib/src";
    const base_i = "-I ../basepkg/src";

    var env = try m.freshEnv();
    env.remove("MOPM_TOKEN");

    // 1. --print-cmd: the two command lines, and nothing written.
    var r = try c.mopmRun(&env, app, &.{ "build", "--print-cmd", "--prefix", prefix });
    try c.must("mopm build --print-cmd", r);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, r.text, "\n"), '\n');
    const want_lib = try h.fmt(a, "{s}/bin/mojo precompile {s} {s} src/app -o target/build/app.mojoc", .{ env_real, greet_i, base_i });
    const want_bin = try h.fmt(a, "{s}/bin/mojo build {s} {s} -I src -Xlinker -rpath -Xlinker {s}/lib -o target/build/app src/main.mojo", .{ env_real, greet_i, base_i, env_real });
    const first = lines.next() orelse "";
    const second = lines.next() orelse "";
    rep.check("print-cmd: the first line is the library's mojo precompile, with an -I for greetlib and one for basepkg (a path dependency of a path dependency)", h.contains(first, want_lib), r.text);
    rep.check("print-cmd: the second line is the program's mojo build, with the same -I and the package's own -I src", h.contains(second, want_bin), r.text);
    rep.check("print-cmd: exactly two commands", lines.next() == null, r.text);
    rep.check("print-cmd writes nothing", !Ctx.exists(try h.join(a, &.{ app, "target" })), "app/target exists");

    // 2. mopm build, no program.
    const log_build = try h.join(a, &.{ work, "build.log" });
    if (stand_in != null) try env.put("FAKE_TOOLCHAIN_LOG", log_build);
    r = try c.mopmRun(&env, app, &.{ "build", "--prefix", prefix });
    try c.must("mopm build (no program): the library and the program", r);
    const lib_out = try h.join(a, &.{ app, "target/build/app.mojoc" });
    const bin_out = try h.join(a, &.{ app, "target/build/app" });
    rep.check("the library is target/build/app.mojoc", Ctx.size(lib_out) > 0, "missing or empty");
    rep.check("the program is target/build/app", Ctx.size(bin_out) > 0, "missing or empty");
    try c.runProgram("target/build/app", bin_out, program_prints);
    if (stand_in != null) {
        const logged = try h.readFile(a, log_build);
        var ll = std.mem.splitScalar(u8, std.mem.trimRight(u8, logged, "\n"), '\n');
        const l0 = ll.next() orelse "";
        const l1 = ll.next() orelse "";
        rep.check("the compiler was asked for the library first, as printed", h.contains(l0, want_lib), logged);
        rep.check("the compiler was asked for the program second, as printed", h.contains(l1, want_bin), logged);
        rep.check("the compiler was run twice", ll.next() == null, logged);
        const mojoc = try h.readFile(a, lib_out);
        rep.check("the library file holds what `mojo precompile` of src/app wrote", h.contains(mojoc, "src/app"), mojoc);
    }

    // 3. --out-dir.
    r = try c.mopmRun(&env, app, &.{ "build", "--out-dir", "dist", "--prefix", prefix });
    try c.must("mopm build --out-dir dist", r);
    rep.check("--out-dir: dist/app.mojoc and dist/app", Ctx.size(try h.join(a, &.{ app, "dist/app.mojoc" })) > 0 and Ctx.size(try h.join(a, &.{ app, "dist/app" })) > 0, "missing or empty");

    // 4. A program, not the targets: the path dependencies are importable too.
    const log_file = try h.join(a, &.{ work, "file.log" });
    if (stand_in != null) try env.put("FAKE_TOOLCHAIN_LOG", log_file);
    try cwd.makePath(try h.join(a, &.{ app, "out" }));
    r = try c.mopmRun(&env, app, &.{ "build", "examples/dep_only.mojo", "-o", "out/dep_only", "--prefix", prefix });
    try c.must("mopm build examples/dep_only.mojo (a program that imports a path dependency and its own)", r);
    try c.runProgram("out/dep_only", try h.join(a, &.{ app, "out/dep_only" }), file_prints);
    if (stand_in != null) {
        const logged = try h.readFile(a, log_file);
        const want = try h.fmt(a, "{s}/bin/mojo build {s} {s} -Xlinker -rpath -Xlinker {s}/lib -o out/dep_only examples/dep_only.mojo", .{ env_real, greet_i, base_i, env_real });
        rep.check("a program built by file gets the -I of both path dependencies", h.contains(logged, want), logged);
    }

    // 5. Controls.
    // 5a. The package without its [dependencies] entry: no -I for the dependency, and the real Mojo cannot build it.
    const nodep = try h.join(a, &.{ root, "app_nodep" });
    try h.copyTree(a, app, nodep);
    try cwd.deleteTree(try h.join(a, &.{ nodep, "target" }));
    try cwd.deleteTree(try h.join(a, &.{ nodep, "dist" }));
    try h.writeFile(try h.join(a, &.{ nodep, "mopm.toml" }), manifest_without_dep);
    const log_nodep = try h.join(a, &.{ work, "nodep.log" });
    if (stand_in != null) try env.put("FAKE_TOOLCHAIN_LOG", log_nodep);
    r = try c.mopmRun(&env, nodep, &.{ "build", "--prefix", prefix });
    if (stand_in != null) {
        const logged = try h.readFile(a, log_nodep);
        rep.check("control: without the [dependencies] entry the compiler is given no -I for greetlib", r.code == 0 and !h.contains(logged, "greetlib"), logged);
    } else {
        rep.check("control: without the [dependencies] entry the real Mojo cannot import greetlib, and mopm build fails", !r.signaled and r.code != 0 and h.contains(r.text, "greetlib"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
    }

    // 5b. An environment without bin/mojo.
    const bare = try h.join(a, &.{ work, "env_bare" });
    try cwd.makePath(try h.join(a, &.{ bare, "lib/mojo" }));
    r = try c.mopmRun(&env, app, &.{ "build", "--out-dir", "bare_out", "--prefix", bare });
    rep.check("control: an environment without bin/mojo ends 127 naming the compiler", !r.signaled and r.code == 127 and h.contains(r.text, "cannot run") and h.contains(r.text, "bin/mojo"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));

    // 5c. A package with no [targets].
    const empty = try h.join(a, &.{ root, "empty" });
    try cwd.makePath(empty);
    try h.writeFile(try h.join(a, &.{ empty, "mopm.toml" }), manifest_without_targets);
    r = try c.mopmRun(&env, empty, &.{ "build", "--prefix", prefix });
    rep.check("control: a package with no [targets] is refused (exit 1, saying there is nothing to build)", !r.signaled and r.code == 1 and h.contains(r.text, "nothing to build"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
    rep.check("control: and it writes nothing", !Ctx.exists(try h.join(a, &.{ empty, "target" })), "empty/target exists");

    // 5d. A directory with no mopm.toml.
    const none = try h.join(a, &.{ root, "no_manifest" });
    try cwd.makePath(none);
    r = try c.mopmRun(&env, none, &.{ "build", "--prefix", prefix });
    rep.check("control: no mopm.toml is refused (exit 1, saying so)", !r.signaled and r.code == 1 and h.contains(r.text, "no mopm.toml"), try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));

    // 5e. -o names one program's file: with no program it is a usage error.
    r = try c.mopmRun(&env, app, &.{ "build", "-o", "x", "--prefix", prefix });
    rep.check("control: -o with no program is a usage error (exit 2)", !r.signaled and r.code == 2, try h.fmt(a, "exit {d}: {s}", .{ r.code, r.text }));
}
