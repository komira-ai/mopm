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

    // mopm-api-gen writes what the registry API's protos (spec/api/mopm/registry/v2/*.proto) make: the OpenAPI document of
    // /api/v2, the TypeScript types and route table of service/api and the Zig client (tools/api_gen.zig). `zig build gen-api`.
    const api_gen = b.addExecutable(.{
        .name = "mopm-api-gen",
        .root_source_file = b.path("tools/api_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const api_gen_cmd = b.addRunArtifact(api_gen);
    api_gen_cmd.addArg(b.pathFromRoot("."));
    b.step("gen-api", "Write the outputs of the registry API's protos").dependOn(&api_gen_cmd.step);

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

    // The read-only sign-in checks the smoke-linux job of .github/workflows/e2e.yml runs after every deploy
    // (tests/drivers/signin_e2e.zig says what they assert). `zig build signin-e2e` builds and installs this program alone.
    const signin_e2e = b.addExecutable(.{
        .name = "mopm-signin-e2e",
        .root_source_file = b.path("tests/drivers/signin_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(signin_e2e);
    b.step("signin-e2e", "Build and install mopm-signin-e2e alone").dependOn(&b.addInstallArtifact(signin_e2e, .{}).step);

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

    // The checked-in outputs of the API's protos are what mopm-api-gen makes of them, and the generator's own tests.
    const api_gen_tests = b.addTest(.{
        .root_source_file = b.path("tools/api_gen_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(api_gen_tests).step);

    // The hand-written commands reach the registry through the generated client, and every operation has a command.
    const registry_client_lint = b.addTest(.{
        .root_source_file = b.path("tests/drivers/registry_client_lint_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(registry_client_lint).step);

    const fake_tests = b.addTest(.{
        .root_source_file = b.path("registry/fake/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(fake_tests).step);

    // The cross-version test of names in namespaces (docs/design/namespaces.md, section 11): the readers and the fake registry of
    // the previous release (v0.0.108, vendored under tests/compat/v0.0.108) against this code, in one process; the farm runs the
    // same file as //:compat_namespaces.
    const fake_fixture = b.createModule(.{
        .root_source_file = b.path("registry/fake/groups_test.zig"),
    });
    const prev_v0_0_108 = b.createModule(.{
        .root_source_file = b.path("tests/compat/prev_v0_0_108.zig"),
    });
    const compat_namespaces = b.addTest(.{
        .root_source_file = b.path("tests/drivers/compat_namespaces_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_namespaces.root_module.addImport("mopm_core", core);
    compat_namespaces.root_module.addImport("fake_fixture", fake_fixture);
    compat_namespaces.root_module.addImport("prev_v0_0_108", prev_v0_0_108);
    test_step.dependOn(&b.addRunArtifact(compat_namespaces).step);

    // The previous command line's readers (main before versions had several builds, vendored under tests/compat/pre_builds) against
    // what this release writes: a line and an answer with `builds`, a package file with `source_sha256`; the farm runs the same
    // file as //:compat_pre_builds.
    const prev_pre_builds = b.createModule(.{
        .root_source_file = b.path("tests/compat/prev_pre_builds.zig"),
    });
    const compat_pre_builds = b.addTest(.{
        .root_source_file = b.path("tests/drivers/compat_pre_builds_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_pre_builds.root_module.addImport("mopm_core", core);
    compat_pre_builds.root_module.addImport("prev_pre_builds", prev_pre_builds);
    test_step.dependOn(&b.addRunArtifact(compat_pre_builds).step);

    // The import-name refusal of `mopm lock`, `tree` and `sync`, run as a command on temporary projects (no network);
    // the farm runs the same file as //:import_clash_cli.
    const import_clash_cli = b.addTest(.{ // native-only
        .root_source_file = b.path("tests/drivers/import_clash_cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_import_clash_cli = b.addRunArtifact(import_clash_cli);
    run_import_clash_cli.step.dependOn(b.getInstallStep());
    run_import_clash_cli.has_side_effects = true;
    run_import_clash_cli.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
    test_step.dependOn(&run_import_clash_cli.step);

    // The registry commands generated from the v2 protos, run as commands: their help goldens, their usage errors and a few
    // calls against the fake registry; the farm runs the same file as //:registry_cli.
    const registry_cli = b.addTest(.{ // native-only
        .root_source_file = b.path("tests/drivers/registry_cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_registry_cli = b.addRunArtifact(registry_cli);
    run_registry_cli.step.dependOn(b.getInstallStep());
    run_registry_cli.has_side_effects = true;
    run_registry_cli.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
    run_registry_cli.setEnvironmentVariable("MOPM_FAKE_REGISTRY", b.getInstallPath(.bin, "mopm-fake-registry"));
    test_step.dependOn(&run_registry_cli.step);

    // `zig build test-pixi -Dpixi=<pixi binary>`: pixi installs packages `mopm pack` wrote from one conda channel per
    // namespace, served on loopback by the test (tests/drivers/pixi_channels_test.zig). The farm has no pixi, so no
    // Buck2 target runs it; the `pixi-channels` job of ci.yml does, with the pinned pixi of tools/install_pixi.sh.
    const pixi = b.option([]const u8, "pixi", "The pixi binary the pixi channel test drives");
    const pixi_channels = b.addTest(.{ // native-only
        .root_source_file = b.path("tests/drivers/pixi_channels_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_pixi_channels = b.addRunArtifact(pixi_channels);
    run_pixi_channels.step.dependOn(b.getInstallStep());
    run_pixi_channels.has_side_effects = true;
    run_pixi_channels.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
    if (pixi) |p| run_pixi_channels.setEnvironmentVariable("PIXI", b.pathFromRoot(p));
    b.step("test-pixi", "Run the pixi channel test natively (-Dpixi=<pixi binary>)").dependOn(&run_pixi_channels.step);

    // `zig build test-e2e -Dmojo-env=<environment>` runs the Mojo end-to-end
    // drivers (tests/drivers/test_*_test.zig, the same files Buck2 runs on the
    // farm as //:autolink, //:discovery, //:supervisor and //:flaky) natively,
    // against the real mojo of that environment (the one `mopm sync --locked`
    // makes in tests/mojo_env) and the system C compiler. CI runs them on Linux x86_64, Linux aarch64 and macOS
    // arm64. Each step is its own: test-autolink, test-discovery,
    // test-supervisor, test-flaky. The work directories
    // (.zig-cache/e2e/<driver>) are emptied first.
    const mojo_env = b.option([]const u8, "mojo-env", "The Mojo environment (a conda prefix) the e2e drivers run against");
    const e2e_step = b.step("test-e2e", "Run the Mojo end-to-end drivers natively (-Dmojo-env=<prefix>)");
    // The native-workspace driver (tests/drivers/native_workspace_test.zig; the farm runs it as //:native_workspace_mojo) starts the
    // fake registry and the `mojo_compile` shim of `mopm unit`: built here and installed for this step only.
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
        run.step.dependOn(&install_compile_shim.step);
        run.setEnvironmentVariable("MOPM", b.getInstallPath(.bin, "mopm"));
        run.setEnvironmentVariable("MOPM_FAKE_REGISTRY", b.getInstallPath(.bin, "mopm-fake-registry"));
        run.setEnvironmentVariable("MOJO_COMPILE_SHIM", b.getInstallPath(.bin, "mojo-compile-shim"));
        run.setEnvironmentVariable("MOPM_E2E_SRC", b.pathFromRoot("tests/e2e"));
        run.setEnvironmentVariable("BUILDRULES_TEST_WORK", work);
        if (mojo_env) |m| run.setEnvironmentVariable("MOJO_TOOLCHAIN", b.pathFromRoot(m));
        const step = b.step("test-" ++ d.name, "Run the " ++ d.name ++ " end-to-end driver natively (-Dmojo-env=<prefix>)");
        step.dependOn(&run.step);
        e2e_step.dependOn(&run.step);
    }
}
