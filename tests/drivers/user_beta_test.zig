//! //:user_beta: tests/drivers/user_beta.zig, the user-level beta of a release, run on the build farm with the
//! built CLI (a "candidate" of version 0.0.1+dev) and the real Mojo 1.0.0 toolchain. The farm has no pixi, no
//! network, no shell and no curl, so this is the reduced form: every step that needs pixi (`mopm sync` of the
//! published package, and the build against it) and the installer are reported SKIP. Everything else runs for
//! real: new, init, metadata, test (green, and red on a planted failure), login, whoami, pack, publish to the
//! fake registry, add, tree, lock, update, remove, build, run, logout. release-beta-user.yml runs the full walk
//! on three platforms with the candidate the release build made.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const beta = @import("user_beta.zig");

test "user beta: the walk of a customer, farm form (no pixi, no installer)" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    try h.watchdog(1500);
    var rep = h.Report{};
    const m = try mojo_env.Mojo.init(a);
    const prefix = try h.join(a, &.{ m.work, "env" });
    try m.prefix(prefix, true);
    try beta.run(a, &rep, .{
        .mopm = try h.toolPathAbs(a, "MOPM"),
        .work = try h.join(a, &.{ m.work, "walk" }),
        .version = "0.0.1+dev",
        .fake_registry = try h.toolPathAbs(a, "MOPM_FAKE_REGISTRY"),
        .mojo_env = prefix,
        .env = &m.base,
    });
    try rep.finish();
}
