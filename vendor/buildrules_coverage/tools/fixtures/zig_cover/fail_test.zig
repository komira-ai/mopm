// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/fixtures/zig_cover/fail_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! A test that fails: zig_cover must fail with it, and write no report.
const std = @import("std");
const mini = @import("mini.zig");

test "wrong answer" {
    try std.testing.expectEqualStrings("zero", mini.classify(7));
}
