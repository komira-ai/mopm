// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/cov_summary_test.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! Unit tests of cov_summary.zig: hits fold across reports, a file nobody compiled is refused, the text is fixed.
const std = @import("std");
const S = @import("cov_summary.zig");
const t = std.testing;

const report_a =
    \\<?xml version="1.0" ?>
    \\<coverage timestamp="0">
    \\    <packages>
    \\        <package name="">
    \\            <classes>
    \\                <class name="p/src/a.mojo" filename="p/src/a.mojo">
    \\                    <lines>
    \\                        <line number="3" hits="1"/>
    \\                        <line number="4" hits="0"/>
    \\                        <line number="5" hits="0"/>
    \\                    </lines>
    \\                </class>
    \\                <class name="p/tests/test_a.mojo" filename="p/tests/test_a.mojo">
    \\                    <lines>
    \\                        <line number="1" hits="1"/>
    \\                    </lines>
    \\                </class>
    \\            </classes>
    \\        </package>
    \\    </packages>
    \\</coverage>
    \\
;

const report_b =
    \\<class name="p/src/a.mojo" filename="p/src/a.mojo">
    \\<lines>
    \\<line number="4" hits="1"/>
    \\<line number="5" hits="0"/>
    \\</lines>
    \\</class>
    \\
;

test "a line is hit when any report hit it, and the files are listed sorted with the total" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    try S.addReport(a, &files, report_b);
    const rows = try S.summarize(a, &files);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("p/src/a.mojo", rows[0].path);
    try t.expectEqual(@as(usize, 2), rows[0].hit);
    try t.expectEqual(@as(usize, 3), rows[0].total);
    try t.expectEqualStrings("p/src/a.mojo 2/3 66%\np/tests/test_a.mojo 1/1 100%\ntotal 3/4 75%\n", try S.render(a, rows, &.{}));
    // With the package's own sources named, the test's lines are listed and not counted.
    try t.expectEqualStrings("p/src/a.mojo 2/3 66%\np/tests/test_a.mojo 1/1 100% (not counted)\ntotal 2/3 66%\n", try S.render(a, rows, &.{"p/src/a.mojo"}));
}

test "one report alone leaves the unhit lines unhit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    const rows = try S.summarize(a, &files);
    try t.expectEqual(@as(usize, 1), rows[0].hit);
}

test "expect: a source no report names is found by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    const rows = try S.summarize(a, &files);
    try t.expect(S.missing(rows, &.{"p/src/a.mojo"}) == null);
    try t.expectEqualStrings("p/src/b.mojo", S.missing(rows, &.{ "p/src/a.mojo", "p/src/b.mojo" }).?);
}

test "a line outside a class and a malformed line are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try t.expectError(error.BadReport, S.addReport(a, &files, "<line number=\"1\" hits=\"1\"/>\n"));
    try t.expectError(error.BadReport, S.addReport(a, &files, "<class name=\"x\" filename=\"x\">\n<line number=\"x\" hits=\"1\"/>\n"));
}

const blocks_a = "# blocks v2\np/src/a.zig\t3\t1\t1\t1\np/src/a.zig\t4\t5\t0\t2\np/src/a.zig\t4\t9\t0\t1\np/tests/a_test.zig\t1\t1\t1\t1\n";
const blocks_b = "# blocks v2\np/src/a.zig\t4\t5\t1\t2\np/src/a.zig\t4\t9\t0\t1\n";

test "blocks: the blocks of a position that ran are the most any report hit; the listing follows the lines' and counts the expected files only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    try S.addBlocks(a, &files, blocks_a);
    try S.addBlocks(a, &files, blocks_b);
    const rows = try S.summarizeBlocks(a, &files);
    try t.expectEqual(@as(usize, 2), rows.len);
    // a.zig: position 3:1 ran (1/1), 4:5 ran one of its two blocks in the second report (1/2), 4:9 never (0/1).
    try t.expectEqual(@as(usize, 2), rows[0].hit);
    try t.expectEqual(@as(usize, 4), rows[0].total);
    try t.expectEqualStrings(
        "branches p/src/a.zig 2/4 50%\nbranches p/tests/a_test.zig 1/1 100% (not counted)\nbranches total 2/4 50%\n",
        try S.renderWith(a, rows, &.{"p/src/a.zig"}, "branches "),
    );
    try t.expect(S.missing(rows, &.{ "p/src/a.zig", "p/src/b.zig" }) != null);
}

test "blocks: two blocks at one position are two blocks, and the same position in two reports is not summed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    try S.addBlocks(a, &files, "# blocks v2\np/a.zig\t5\t5\t1\t2\n");
    try S.addBlocks(a, &files, "# blocks v2\np/a.zig\t5\t5\t1\t2\n");
    const rows = try S.summarizeBlocks(a, &files);
    try t.expectEqual(@as(usize, 1), rows[0].hit);
    try t.expectEqual(@as(usize, 2), rows[0].total);
}

test "blocks: a report that is not zig_cover's is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    for ([_][]const u8{
        "",
        "p/a.zig\t1\t1\t1\t1\n",
        "# blocks v1\np/a.zig\t1\t1\t1\n", // the old format
        "# blocks v2\np/a.zig\t1\t1\t1\n",
        "# blocks v2\np/a.zig\t1\t1\t2\t1\n", // more ran than there are
        "# blocks v2\np/a.zig\t1\t1\t0\t0\n", // a position with no block
        "# blocks v2\np/a.zig\tx\t1\t1\t1\n",
        "# blocks v2\np/a.zig\t1\t1\t1\t1\tz\n",
    }) |text| {
        try t.expectError(error.BadReport, S.addBlocks(a, &files, text));
    }
}
