// Vendored, unmodified, from komira-ai/buildrules pull request #153 (merged to main), commit eec7f9f4cdb509a161095fcc78f7dcd1dc1ca503, file rules/coverage/tools/cov_normalize_exe_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! The shipped cov_normalize executable as a process (README.md#tests):
//! `zig test` of this file, run as a build action by `:cov_normalize_exe_test`,
//! a validation of `:cov_normalize`. The cases in cov_normalize_test.zig call
//! the program's `entry` in-process; these run the executable the public
//! target hands out (its path in the environment as COV_NORMALIZE, the
//! `zig_test`'s `env_tools`) as a child process, with an empty environment,
//! and check what `main` adds: the command line taken from argv[1..], the
//! messages written to stderr and none to stdout, and `entry`'s status as the
//! process's exit status, a write cut short included. Without COV_NORMALIZE
//! every case fails: none passes without running the executable.

const std = @import("std");
const posix = std.posix;

const fixture = @embedFile("fixtures/kcov_full_paths.xml");
const golden = @embedFile("fixtures/kcov_full_paths.golden.xml");

const FX = "kcov_full_paths.xml";
const OUT = "out.xml";

const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";
const ART = "buck-out/v2/art/widget/src/widget_retry/__widget_retry__/fedcba9876543210/src/widget_retry/";
const PKG = "src/widget_retry/";

// The command line of cov_normalize_test.zig's golden case.
const MAPS = [_][]const u8{
    "--map", D ++ "/srcroot/" ++ ART ++ "=" ++ PKG,
    "--map", D ++ "/srcroot/=" ++ PKG,
    "--map", P ++ "/" ++ ART ++ "=" ++ PKG,
    "--exclude", D ++ "/srcroot/buck-out/v2/gen/",
};
const MUST = [_][]const u8{ "--must-contain", PKG ++ "tests/test_refusals.mojo", "--must-contain", PKG ++ "policy.mojo" };
const IO = [_][]const u8{ "--in", FX, "--out", OUT };

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    out: ?[]const u8,
};

/// The path of the executable under test: COV_NORMALIZE, which the
/// zig_test's `env_tools` sets. A run without it fails loudly; it never
/// passes unchecked.
fn tool(a: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, "COV_NORMALIZE") catch {
        std.debug.print("the test target does not pass COV_NORMALIZE (env_tools), so the executable cannot be run\n", .{});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs the executable with `args` in a directory of its own holding the
/// fixture, and reads back its exit status, stdout, stderr and output file.
/// With `fsize`, the child runs under that file size limit, SIGXFSZ ignored
/// (both inherited across exec), so a longer write fails with EFBIG.
fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, args: []const []const u8, fsize: ?u64) !Run {
    {
        var f = try tmp.dir.createFile(FX, .{});
        defer f.close();
        try f.writeAll(fixture);
    }
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try tool(a));
    try argv.appendSlice(a, args);
    // The child's environment is built here, empty: it does not inherit
    // COV_NORMALIZE or anything else of the test's.
    var env = std.process.EnvMap.init(a);
    const r = blk: {
        const limit = fsize orelse break :blk try spawn(a, tmp, argv.items, &env);
        const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
        var old_act: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.XFSZ, &ign, &old_act);
        defer posix.sigaction(posix.SIG.XFSZ, &old_act, null);
        const old = try posix.getrlimit(.FSIZE);
        try posix.setrlimit(.FSIZE, .{ .cur = limit, .max = old.max });
        defer posix.setrlimit(.FSIZE, old) catch {};
        // The probe: under the limit a plain write of the golden output is
        // stopped part way, so the case below tests a failing write.
        {
            var f = try tmp.dir.createFile("probe", .{});
            defer f.close();
            if (f.writeAll(golden)) {
                std.debug.print("probe: the size limit did not stop the write\n", .{});
                return error.TestUnexpectedResult;
            } else |e| if (e != error.FileTooBig) return e;
        }
        try tmp.dir.deleteFile("probe");
        break :blk try spawn(a, tmp, argv.items, &env);
    };
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("cov_normalize did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    const out = tmp.dir.readFileAlloc(a, OUT, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr, .out = out };
}

fn spawn(a: std.mem.Allocator, tmp: *std.testing.TmpDir, argv: []const []const u8, env: *const std.process.EnvMap) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = a,
        .argv = argv,
        .cwd_dir = tmp.dir,
        .env_map = env,
        .max_output_bytes = 1 << 20,
    });
}

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

test "success: exit 0, the golden output, the count line on stderr" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, &(IO ++ MAPS ++ MUST ++ [_][]const u8{ "--forbid", D }), null);
    try expect("success", r, 0, "cov_normalize: 7 class(es) read, 1 excluded, 5 written\n");
    try std.testing.expectEqualStrings(golden, r.out orelse return error.TestUnexpectedResult);
}

test "refusal: exit 1, the refusal on stderr, no output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // MAPS without its second map: the three test files are unmapped.
    const maps = [_][]const u8{ MAPS[0], MAPS[1], MAPS[4], MAPS[5], MAPS[6], MAPS[7] };
    const r = try run(arena.allocator(), &tmp, &(IO ++ maps ++ [_][]const u8{ "--must-contain", PKG ++ "policy.mojo" }), null);
    try expect("refusal", r, 1, "unmapped file name '" ++ D ++ "/srcroot/tests/test_refusals.mojo': no --map or --exclude prefix covers it\n");
    try expect("refusal", r, 1, "cov_normalize: 3 unmapped file name(s) in " ++ FX ++ "; nothing written\n");
    if (r.out != null) {
        std.debug.print("refusal: an output was written\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "bad usage: exit 2, the usage line on stderr, no output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, &(IO ++ MAPS ++ MUST ++ [_][]const u8{ "--in", FX }), null);
    try expect("bad usage", r, 2, "cov_normalize: --in given twice\nusage: cov_normalize --in <report.xml> --out <file>");
    if (r.out != null) {
        std.debug.print("bad usage: an output was written\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "failed write: exit 1, the error on stderr, no output and no temporary" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The output is 1.4 KiB; 512 bytes stops it part way.
    const r = try run(arena.allocator(), &tmp, &(IO ++ MAPS ++ MUST), 512);
    try expect("failed write", r, 1, "cov_normalize: " ++ OUT ++ ": FileTooBig; nothing written\n");
    // The directory holds the fixture alone: no output, partial or temporary.
    var d = try tmp.dir.openDir(".", .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |e| {
        if (!std.mem.eql(u8, e.name, FX)) {
            std.debug.print("failed write: the directory holds '{s}'\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}
