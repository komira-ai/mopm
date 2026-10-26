//! //:user_native: the native step of the user-level beta walk (tests/drivers/user_native.zig), on the build farm, on every
//! pull request. The farm has no pixi and runs the Mojo toolchain only in the beta tier, so the step runs here with the stand-ins
//! of the unit tier (tests/drivers/fake_toolchain.zig for the compiler, tests/drivers/fake_pixi.zig for pixi) and everything
//! else real: the zig that compiles and archives the C sources, the built mopm, and the fake registry.
//!
//! What each test proves, and the defect it would catch:
//!   - the switch: linux aarch64 is skipped while `linux_arm64_native_enabled` is off, every other platform runs, and turning
//!     the switch on runs linux aarch64 (a switch that did not decide, or skipped x86_64 or macOS, goes red);
//!   - the skip line: exactly "skipped: waiting on linux-arm64 hardware", counted as a skip and not as a pass (a changed
//!     message, or a skip that is tallied as a pass, goes red);
//!   - the output check: only the C code's value for the platform, exactly (a program that prints the other platform's
//!     value, a wrong value, a partial or an empty output goes red);
//!   - the step end to end: C sources compiled and archived, `mopm stage`, `mopm publish --staged` into the fake registry,
//!     then a new package that adds, syncs and `mopm build`s (no file) and runs the program, with the installed archive
//!     byte for byte the one that was built (a mopm that dropped the archive from the pack, the lock or the install, or that
//!     stopped building the manifest's targets, goes red);
//!   - the archive check: the installed file must be non-empty and equal to the built one (a corrupted, truncated, different
//!     or empty installed archive goes red);
//!   - the same run where the stand-in program prints another value: the step fails on exactly the value check (a step
//!     that does not look at what the program prints goes green).
//! The stand-in compiler prints what FAKE_TOOLCHAIN_PROGRAM_OUTPUT says, so the real values are checked by the walk on the
//! hosted runners, where the real Mojo links the archive.
//!
//! Run by Buck2 as //:user_native. MOPM, MOPM_FAKE_REGISTRY, FAKE_PIXI and FAKE_TOOLCHAIN are the built programs, ZIG_DIR is
//! the pinned zig's directory, and the data is tests/e2e/natws.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const un = @import("user_native.zig");
const Allocator = std.mem.Allocator;

test "user native: the one switch keeps linux aarch64 out and everything else in" {
    try std.testing.expect(!un.linux_arm64_native_enabled);
    try std.testing.expectEqual(un.Decision.skip_waiting_on_arm64, un.decide(.linux, .aarch64, false));
    try std.testing.expectEqual(un.Decision.run, un.decide(.linux, .x86_64, false));
    try std.testing.expectEqual(un.Decision.run, un.decide(.macos, .aarch64, false));
    // Re-enabling is the constant: with it on, linux aarch64 runs.
    try std.testing.expectEqual(un.Decision.run, un.decide(.linux, .aarch64, true));
    // The decision for this machine follows the constant.
    try std.testing.expectEqual(un.decide(builtin.os.tag, builtin.cpu.arch, un.linux_arm64_native_enabled), un.decision());
}

test "user native: the skip prints exactly the waiting line and counts as a skip" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var skipped: usize = 0;
    try un.reportSkip(&skipped, stream.writer());
    try std.testing.expectEqualStrings("skipped: waiting on linux-arm64 hardware\n", stream.getWritten());
    try std.testing.expectEqual(@as(usize, 1), skipped);
}

test "user native: the output check wants the C code's value for the platform, exactly" {
    try std.testing.expect(un.outputOk("native 42\n", .linux));
    try std.testing.expect(un.outputOk("native 43\n", .macos));
    // The value of the other platform, a wrong value, no newline, extra output and nothing at all are each refused.
    try std.testing.expect(!un.outputOk("native 43\n", .linux));
    try std.testing.expect(!un.outputOk("native 42\n", .macos));
    try std.testing.expect(!un.outputOk("native 0\n", .linux));
    try std.testing.expect(!un.outputOk("native 42", .linux));
    try std.testing.expect(!un.outputOk("hello\nnative 42\n", .linux));
    try std.testing.expect(!un.outputOk("", .linux));
}

/// The step against a fresh fake registry, with a stand-in compiler whose programs print `program_output`.
fn stepWith(a: Allocator, rep: *h.Report, tag: []const u8, program_output: []const u8) !void {
    const cwd = std.fs.cwd();
    const base = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const work = try h.join(a, &.{ base, tag });
    try cwd.makePath(work);
    const scratch = try h.join(a, &.{ work, "scratch" });
    try cwd.makePath(scratch);

    var env = std.process.EnvMap.init(a);
    try env.put("PATH", std.process.getEnvVarOwned(a, "PATH") catch try a.dupe(u8, ""));
    try env.put("HOME", scratch);
    try env.put("TMPDIR", scratch);
    try env.put("XDG_CACHE_HOME", scratch);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try h.join(a, &.{ scratch, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try h.join(a, &.{ scratch, "zig-local" }));
    try env.put("FAKE_TOOLCHAIN_PROGRAM_OUTPUT", program_output);

    var fake = try h.Fake.start(a, try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"), try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const session = h.jsonString(try fake.control(a, "/session", "{\"handle\":\"native-user\"}"), "token") orelse "";

    const stand_in = try h.toolPathAbs(a, "FAKE_TOOLCHAIN");
    const prefix = try h.join(a, &.{ work, "prefix" });
    try un.installCompiler(stand_in, try h.join(a, &.{ prefix, "bin", "mojo" }));

    try un.run(a, rep, .{
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .work = try h.join(a, &.{ work, "step" }),
        .fixture = try h.join(a, &.{ base, "tests/e2e/natws/shimlib" }),
        .registry = fake.base,
        .session = session,
        .zig = try h.join(a, &.{ try h.toolPathAbs(a, "ZIG_DIR"), "zig" }),
        .mojo_env = prefix,
        .pixi = try h.toolPathAbs(a, "FAKE_PIXI"),
        .env = &env,
        .cc_target = if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) "x86_64-linux-gnu.2.34" else null,
        .stand_in_mojo = stand_in,
    });
}

test "user native: the installed archive must be the built one, byte for byte" {
    try std.testing.expect(un.archiveOk("!<arch>\nabc", "!<arch>\nabc"));
    try std.testing.expect(!un.archiveOk("!<arch>\nabd", "!<arch>\nabc"));
    try std.testing.expect(!un.archiveOk("!<arch>\nab", "!<arch>\nabc"));
    try std.testing.expect(!un.archiveOk("", "!<arch>\nabc"));
    try std.testing.expect(!un.archiveOk("", ""));
}

test "user native: C sources to a published package to a built and run program, with a stand-in compiler" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    try stepWith(a, &rep, "user_native_ok", un.expectedLine(builtin.os.tag));
    try rep.finish();
}

test "user native: a program that prints another value fails the step on that value alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    try stepWith(a, &rep, "user_native_wrong", "native 41\n");
    try std.testing.expectEqual(@as(usize, 1), rep.failures);
}
