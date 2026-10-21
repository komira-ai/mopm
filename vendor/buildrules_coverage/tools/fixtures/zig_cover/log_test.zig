// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/fixtures/zig_cover/log_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! A test that logs an error and otherwise passes: the runner of a coverage build fails the run, as zig's own runner does.
const std = @import("std");
const mini = @import("mini.zig");

test "logs an error" {
    _ = mini.classify(1);
    std.log.err("an error that nobody expected", .{});
}
