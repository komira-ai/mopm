//! Where the unit tests find the repository's `tests/` tree.
//!
//! Tests that read a fixture or a golden file name it relative to the
//! repository root ("tests/fixtures/..."). `zig build test` is run from the
//! root, so by default that is the working directory, as it always was. A
//! runner that executes the test binary somewhere else (a Buck2 action, with
//! the source tree read-only and a scratch working directory) sets
//! MOPM_SOURCE_ROOT to the root, and `path` prefixes every fixture with it.
//! Nothing here is part of the mopm binary: only test blocks call it.

const std = @import("std");

/// `rel` ("tests/...") under `root` when that is set and not empty, else
/// `rel` unchanged (relative to the working directory).
fn join(a: std.mem.Allocator, root: ?[]const u8, rel: []const u8) ![]const u8 {
    const r = root orelse return rel;
    if (r.len == 0) return rel;
    return std.fs.path.join(a, &.{ r, rel });
}

/// `join` with the root taken from MOPM_SOURCE_ROOT.
pub fn path(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const root = std.process.getEnvVarOwned(a, "MOPM_SOURCE_ROOT") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return rel,
        else => return e,
    };
    return join(a, root, rel);
}

test "an unset or empty root leaves the name relative; a set one prefixes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("tests/x", try join(a, null, "tests/x"));
    try std.testing.expectEqualStrings("tests/x", try join(a, "", "tests/x"));
    try std.testing.expectEqualStrings("/src/tree/tests/x", try join(a, "/src/tree", "tests/x"));
    try std.testing.expectEqualStrings("/src/tree/tests/x", try join(a, "/src/tree/", "tests/x"));
}
