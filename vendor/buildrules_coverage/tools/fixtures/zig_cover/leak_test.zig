// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/fixtures/zig_cover/leak_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! A test that leaks: the runner of a coverage build fails it, as zig's own runner does.
const std = @import("std");
const mini = @import("mini.zig");

test "leaks one byte" {
    _ = mini.classify(1);
    _ = try std.testing.allocator.alloc(u8, 1);
}
