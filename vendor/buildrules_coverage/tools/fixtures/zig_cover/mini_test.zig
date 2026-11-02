// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/fixtures/zig_cover/mini_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! The passing tests of zig_cover_exe_test.zig: they reach the negative and the positive arm of `classify` and not the zero arm.
const std = @import("std");
const mini = @import("mini.zig");

test "negative" {
    try std.testing.expectEqualStrings("negative", mini.classify(-3));
}

test "positive" {
    try std.testing.expectEqualStrings("positive", mini.classify(7));
}

test "a skipped test is not a failure" {
    return error.SkipZigTest;
}
