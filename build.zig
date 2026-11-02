const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // -Dstrip=true drops symbols and debug info (the release build, tools/release.zig).
    const strip = b.option(bool, "strip", "Strip the mopm binary") orelse false;
    // -Dversion=<v> is the version `mopm --version` prints (the release build, tools/release.zig, which
    // gets it from release.yml). The default is src/cli/build_options.zig's, the Buck2 build's copy.
    const version = b.option([]const u8, "version", "The version the CLI reports") orelse "0.0.1+dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

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
    exe.root_module.addOptions("build_options", build_options);
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

    // The authenticated group-publish check the `group-e2e` job of .github/workflows/e2e.yml runs against beta and gamma
    // (tests/drivers/group_e2e.zig says what it does).
    const group_e2e = b.addExecutable(.{
        .name = "mopm-group-e2e",
        .root_source_file = b.path("tests/drivers/group_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    group_e2e.root_module.addImport("mopm_core", core);
    b.installArtifact(group_e2e);

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
    cli_tests.root_module.addOptions("build_options", build_options);
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
    // The native-workspace driver (tests/drivers/native_workspace_test.zig; the farm runs it as //:native_workspace_mojo) starts the
    // fake registry, a stand-in pixi and the `mojo_compile` shim of `mopm unit`: built here and installed for this step only.
    const fake_pixi = b.addExecutable(.{ // native-only
        .name = "fake-pixi",
        .root_source_file = b.path("tests/drivers/fake_pixi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_fake_pixi = b.addInstallArtifact(fake_pixi, .{});
    const compile_shim = b.addExecutable(.{ // native-only
        .name = "mojo-compile-shim",
        .root_source_file = b.path("tests/drivers/mojo_compile_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_compile_shim = b.addInstallArtifact(compile_shim, .{});
    const drivers = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "autolink", .root = "tests/drivers/test_autolink_test.zig" },
        .{ .name = "discovery", .root = "tests/drivers/test_discovery_test.zig" },
        .{ .name = "supervisor", .root = "tests/drivers/test_supervisor_test.zig" },
        .{ .name = "flaky", .root = "tests/drivers/test_flaky_test.zig" },
        .{ .name = "native-workspace", .root = "tests/drivers/native_workspace_test.zig" },
        .{ .name = "build-targets", .root = "tests/drivers/build_targets_test.zig" },
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
        run.step.dependOn(&install_fake_pixi.step);
        run.step.dependOn(&install_compile_shim.step);
        run.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
        run.setEnvironmentVariable("MOPM_FAKE_REGISTRY", b.getInstallPath(.bin, "mopm-fake-registry"));
        run.setEnvironmentVariable("FAKE_PIXI", b.getInstallPath(.bin, "fake-pixi"));
        run.setEnvironmentVariable("MOJO_COMPILE_SHIM", b.getInstallPath(.bin, "mojo-compile-shim"));
        run.setEnvironmentVariable("MOPM_E2E_SRC", b.pathFromRoot("tests/e2e"));
        run.setEnvironmentVariable("BUILDRULES_TEST_WORK", work);
        if (mojo_env) |m| run.setEnvironmentVariable("MOJO_TOOLCHAIN", b.pathFromRoot(m));
        const step = b.step("test-" ++ d.name, "Run the " ++ d.name ++ " end-to-end driver natively (-Dmojo-env=<pixi prefix>)");
        step.dependOn(&run.step);
        e2e_step.dependOn(&run.step);
    }
}
