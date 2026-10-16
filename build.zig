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
}
