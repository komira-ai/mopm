//! //:user_beta: tests/drivers/user_beta.zig, the user-level beta of a release, run on the build farm with the
//! built CLI (a "candidate" of version 0.0.1+dev) and the real Mojo 1.0.0 toolchain. The farm has no network, no
//! shell and no curl, so this is the reduced form: `mopm sync` installs a stand-in toolchain (two small packages the
//! walk's fake registry serves, named by `--toolchain`) in place of the pinned one, the real compiler is laid into the
//! environment that sync made, and the installer is reported SKIP. Everything else runs for real: new, init, metadata,
//! test (green, and red on a faulty failure), login, whoami, pack, publish to the fake registry, add, tree, lock, update,
//! sync (download, sha256 check, install, and "current" the second time), build and run against the installed dependency,
//! remove, logout. release-beta-user.yml runs the full walk on three platforms with the candidate the release build
//! made, where sync installs the real pinned toolchain.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const beta = @import("user_beta.zig");

/// The farm's Mojo, whose compiler the walk lays into the environment `mopm sync` made.
var farm_mojo: ?mojo_env.Mojo = null;

fn layFarmCompiler(env_dir: []const u8) anyerror!void {
    try farm_mojo.?.prefix(env_dir, true);
}

test "user beta: the walk of a customer, farm form (stand-in toolchain, no installer)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    const m = try mojo_env.Mojo.init(a);
    const prefix = try h.join(a, &.{ m.work, "env" });
    try m.prefix(prefix, true);
    farm_mojo = m;
    try beta.run(a, &rep, .{
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .work = try h.join(a, &.{ m.work, "walk" }),
        .version = "0.0.1+dev",
        .fake_registry = try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"),
        .mojo_env = prefix,
        .stand_in_toolchain = true,
        .lay_compiler = layFarmCompiler,
        .env = &m.base,
    });
    try rep.finish();
}

test "user beta: --ci turns a skipped step into a failure; the farm form only reports it" {
    // The farm form: a SKIP is counted and is not a failure.
    var farm = h.Report{};
    var skipped: usize = 0;
    beta.skipStep(&farm, false, &skipped, "install", "no --tarball");
    try std.testing.expectEqual(@as(usize, 1), skipped);
    try std.testing.expectEqual(@as(usize, 0), farm.failures);
    // CI: the same skip is a failure of the walk, and is not counted as a mere skip.
    var ci = h.Report{};
    var ci_skipped: usize = 0;
    beta.skipStep(&ci, true, &ci_skipped, "install", "no --tarball");
    try std.testing.expectEqual(@as(usize, 1), ci.failures);
    try std.testing.expectEqual(@as(usize, 0), ci_skipped);
    try std.testing.expectError(error.ChecksFailed, ci.finish());
}
