const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library code shared by the CLI and (later) other front ends.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/mopm_core.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "mopm",
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mopm_core", core);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the mopm CLI").dependOn(&run_cmd.step);

    // The fake registry the CLI is tested against (registry/fake/README.md).
    const fake = b.addExecutable(.{
        .name = "mopm-fake-registry",
        .root_source_file = b.path("registry/fake/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(fake);

    // `zig build test` must be run from the repository root: the golden
    // tests read tests/fixtures and tests/golden relative to the cwd.
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
