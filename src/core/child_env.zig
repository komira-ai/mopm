//! The environment mopm hands to the programs it starts.
//!
//! `MOPM_TOKEN` is the registry token of `mopm publish` and `mopm yank`
//! (spec/staged-set.md). A program mopm starts (the compiler, a test, the
//! package installer, a test child) has no business with it, and a build or
//! test that prints its environment would put the token in a log. So the token
//! is taken out of the environment of every child, wherever mopm starts one.
//!
//! The same holds for what `mopm publish --oidc` asks GitHub Actions with
//! (src/core/ci_oidc.zig): the job's identity-token request token and URL.
//! The registry token that `--oidc` gets is kept in memory only, so there is no
//! variable to scrub for it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The variables that never reach a child.
pub const scrubbed = [_][]const u8{ "MOPM_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL" };

/// Whether the variable `name` is one that never reaches a child.
pub fn isScrubbed(name: []const u8) bool {
    for (scrubbed) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Removes the scrubbed variables from `map`.
pub fn scrub(map: *std.process.EnvMap) void {
    for (scrubbed) |name| map.remove(name);
}

/// This process's environment without the scrubbed variables: what a child gets when mopm passes the environment on.
pub fn forChild(arena: Allocator) !std.process.EnvMap {
    var map = try std.process.getEnvMap(arena);
    scrub(&map);
    return map;
}

test "the token is taken out and nothing else" {
    var map = std.process.EnvMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("MOPM_TOKEN", "mopm_secret");
    try map.put("MOPM_TOKEN_FILE", "kept: a different name");
    try map.put("PATH", "/bin");
    scrub(&map);
    try std.testing.expect(map.get("MOPM_TOKEN") == null);
    try std.testing.expectEqualStrings("kept: a different name", map.get("MOPM_TOKEN_FILE").?);
    try std.testing.expectEqualStrings("/bin", map.get("PATH").?);
    scrub(&map); // idempotent
    try std.testing.expectEqual(@as(std.process.EnvMap.Size, 2), map.count());
}

test "the job's identity-token request token and URL are taken out too" {
    var map = std.process.EnvMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "request_secret");
    try map.put("ACTIONS_ID_TOKEN_REQUEST_URL", "https://pipelines.example/idtoken?api-version=2.0");
    try map.put("ACTIONS_ID_TOKEN_REQUEST_TOKEN_NOT", "kept: a different name");
    try map.put("GITHUB_ACTIONS", "true");
    scrub(&map);
    try std.testing.expect(map.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN") == null);
    try std.testing.expect(map.get("ACTIONS_ID_TOKEN_REQUEST_URL") == null);
    try std.testing.expectEqualStrings("kept: a different name", map.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN_NOT").?);
    try std.testing.expectEqualStrings("true", map.get("GITHUB_ACTIONS").?);
    try std.testing.expect(isScrubbed("ACTIONS_ID_TOKEN_REQUEST_TOKEN"));
    try std.testing.expect(!isScrubbed("GITHUB_ACTIONS"));
}

test "a child's environment is this process's, without the token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var map = try forChild(arena_state.allocator());
    try std.testing.expect(map.get("MOPM_TOKEN") == null);
    // The rest is the process's own: every variable of this process but the scrubbed ones.
    var own = try std.process.getEnvMap(arena_state.allocator());
    scrub(&own);
    try std.testing.expectEqual(own.count(), map.count());
}
