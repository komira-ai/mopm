const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // -Dstrip=true drops symbols and debug info (the release build, tools/release.zig).
    const strip = b.option(bool, "strip", "Strip the mopm binary") orelse false;

    // Library code shared by the CLI and (later) other front ends.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/mopm_core.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "mopm",
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe.root_module.addImport("mopm_core", core);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the mopm CLI").dependOn(&run_cmd.step);

    // mopm-closure makes the Mojo toolchain closure files from a pixi lock
    // (src/core/closure.zig, toolchain/README.md).
    const closure_gen = b.addExecutable(.{
        .name = "mopm-closure",
        .root_source_file = b.path("tools/closure_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    closure_gen.root_module.addImport("mopm_core", core);
    b.installArtifact(closure_gen);
    const closure_cmd = b.addRunArtifact(closure_gen);
    if (b.args) |args| closure_cmd.addArgs(args);
    b.step("run-closure", "Make the toolchain closure files: -- <lock> <output directory>").dependOn(&closure_cmd.step);

    // The fake registry the CLI is tested against (registry/fake/README.md).
    const fake = b.addExecutable(.{
        .name = "mopm-fake-registry",
        .root_source_file = b.path("registry/fake/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(fake);

    // `zig build test` is run from the repository root: the golden tests read
    // tests/fixtures and tests/golden relative to the cwd, unless
    // MOPM_SOURCE_ROOT names the root (src/core/testroot.zig), for a runner
    // that starts the tests somewhere else.
    const test_step = b.step("test", "Run all unit and golden tests");

    const core_tests = b.addTest(.{
        .root_source_file = b.path("src/core/mopm_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const cli_tests = b.addTest(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests.root_module.addImport("mopm_core", core);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    const fake_tests = b.addTest(.{
        .root_source_file = b.path("registry/fake/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(fake_tests).step);

    // `zig build test-e2e -Dmojo-env=<pixi environment>` runs the Mojo end-to-end
    // drivers (tests/drivers/test_*_test.zig, the same files Buck2 runs on the
    // farm as //:autolink, //:discovery, //:supervisor and //:flaky) natively,
    // against the real mojo of that environment (tests/e2e/pixi.toml) and the
    // system C compiler. CI runs them on Linux x86_64, Linux aarch64 and macOS
    // arm64. Each step is its own: test-autolink, test-discovery,
    // test-supervisor, test-flaky. The work directories
    // (.zig-cache/e2e/<driver>) are emptied first.
    const mojo_env = b.option([]const u8, "mojo-env", "The Mojo environment (a pixi prefix) the e2e drivers run against");
    const e2e_step = b.step("test-e2e", "Run the Mojo end-to-end drivers natively (-Dmojo-env=<pixi prefix>)");
    const drivers = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "autolink", .root = "tests/drivers/test_autolink_test.zig" },
        .{ .name = "discovery", .root = "tests/drivers/test_discovery_test.zig" },
        .{ .name = "supervisor", .root = "tests/drivers/test_supervisor_test.zig" },
        .{ .name = "flaky", .root = "tests/drivers/test_flaky_test.zig" },
    };
    inline for (drivers) |d| {
        const drv = b.addTest(.{ // native-only
            .root_source_file = b.path(d.root),
            .target = target,
            .optimize = optimize,
        });
        const work = b.cache_root.join(b.allocator, &.{ "e2e", d.name }) catch @panic("OOM");
        const run = b.addRunArtifact(drv);
        run.step.dependOn(&b.addRemoveDirTree(work).step);
        run.step.dependOn(b.getInstallStep());
        run.has_side_effects = true;
        run.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
        run.setEnvironmentVariable("MOPM_E2E_SRC", b.pathFromRoot("tests/e2e"));
        run.setEnvironmentVariable("BUILDRULES_TEST_WORK", work);
        if (mojo_env) |m| run.setEnvironmentVariable("MOJO_TOOLCHAIN", b.pathFromRoot(m));
        const step = b.step("test-" ++ d.name, "Run the " ++ d.name ++ " end-to-end driver natively (-Dmojo-env=<pixi prefix>)");
        step.dependOn(&run.step);
        e2e_step.dependOn(&run.step);
    }
}
