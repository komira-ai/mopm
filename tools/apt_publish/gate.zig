//! The fail-safe gate of the apt jobs: do the settings a job needs exist? The settings are the variables of the
//! environment `apt-publish` and the secrets of `apt-signing`, set by the repository owner once. Until they are, a job
//! that finds one of them missing does nothing, writes nothing and ends green with a notice. A gate looks at names of
//! environment variables only; it never prints a value.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One thing the gate requires of the environment of the process.
pub const Check = struct {
    name: []const u8,
    /// false: the variable must be set and not empty. true: it must be exactly `true` (a boolean output of an earlier job).
    must_be_true: bool = false,
};

pub const Verdict = struct {
    enabled: bool,
    /// The names that failed their check, in the order they were asked.
    missing: []const []const u8,
};

pub fn evaluate(a: Allocator, env: *const std.process.EnvMap, checks: []const Check) !Verdict {
    var missing = std.ArrayList([]const u8).init(a);
    for (checks) |c| {
        const v = env.get(c.name) orelse "";
        const ok = if (c.must_be_true) std.mem.eql(u8, v, "true") else v.len > 0;
        if (!ok) try missing.append(c.name);
    }
    return .{ .enabled = missing.items.len == 0, .missing = missing.items };
}

/// The line a gate appends to $GITHUB_OUTPUT.
pub fn outputLine(enabled: bool) []const u8 {
    return if (enabled) "enabled=true\n" else "enabled=false\n";
}

/// The workflow command that shows why a job did nothing. `what` is the name of the job's purpose, `missing` the names
/// (never the values) that were not set.
pub fn notice(a: Allocator, what: []const u8, missing: []const []const u8) ![]u8 {
    const names = try std.mem.join(a, ", ", missing);
    return std.fmt.allocPrint(a, "::notice title={s} skipped::{s} did nothing and wrote nothing: not set up yet ({s}). RELEASING.md says what to set.\n", .{ what, what, names });
}

test "a gate is open only when every named variable is set and not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.EnvMap.init(a);
    try env.put("A", "x");
    try env.put("B", "");
    const v = try evaluate(a, &env, &.{ .{ .name = "A" }, .{ .name = "B" }, .{ .name = "C" } });
    try std.testing.expect(!v.enabled);
    try std.testing.expectEqual(@as(usize, 2), v.missing.len);
    try std.testing.expectEqualStrings("B", v.missing[0]);
    try std.testing.expectEqualStrings("C", v.missing[1]);
    const ok = try evaluate(a, &env, &.{.{ .name = "A" }});
    try std.testing.expect(ok.enabled);
    try std.testing.expectEqual(@as(usize, 0), ok.missing.len);
}

test "a boolean check wants exactly true, not any text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.EnvMap.init(a);
    try env.put("T", "true");
    try env.put("F", "false");
    try env.put("X", "TRUE");
    try std.testing.expect((try evaluate(a, &env, &.{.{ .name = "T", .must_be_true = true }})).enabled);
    try std.testing.expect(!(try evaluate(a, &env, &.{.{ .name = "F", .must_be_true = true }})).enabled);
    try std.testing.expect(!(try evaluate(a, &env, &.{.{ .name = "X", .must_be_true = true }})).enabled);
    try std.testing.expect(!(try evaluate(a, &env, &.{.{ .name = "UNSET", .must_be_true = true }})).enabled);
}

test "the notice names what is missing and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try notice(a, "apt publish", &.{ "APT_BUCKET", "APT_HOSTNAME" });
    try std.testing.expect(std.mem.startsWith(u8, n, "::notice title=apt publish skipped::"));
    try std.testing.expect(std.mem.indexOf(u8, n, "APT_BUCKET, APT_HOSTNAME") != null);
    try std.testing.expectEqualStrings("enabled=true\n", outputLine(true));
    try std.testing.expectEqualStrings("enabled=false\n", outputLine(false));
}
