// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/cov_summary.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! cov_summary: the line coverage of a package, from the normalized Cobertura reports of its tests (cov_normalize's output).
//!
//!   cov_summary --out <file> [--expect <repository path>]... [--blocks <blocks file>]... <report.xml>...
//!
//! `--blocks` is a zig_cover.zig block report (Zig's branch figure: the compiler's basic blocks, `<file> TAB <line> TAB <column> TAB <hit> TAB <total>`).
//! With any, the output continues after the line total with the same listing prefixed `branches `: the blocks at a position that ran are the most
//! any report hit, `--expect` limits the total to the package's own sources, and a source in no block report is refused as it is in no line report.
//!
//! A line counts as hit when any report records it with hits above 0. The output lists every file the reports name with its hit and
//! recorded lines, then the total. `--expect` names the package's own sources: the tool fails (exit 1, nothing written) when one is not in any
//! report, because kcov drops a file it cannot open without an error and a package whose library no test compiled must not read as
//! covered. What is recorded is what the compiler emitted code for: a function no test reaches emits no lines, so the percentage is an
//! upper bound (a coverage checker may list such functions; this tool does not).

const std = @import("std");

pub const FileCov = struct { path: []const u8, hit: usize, total: usize };

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const rest = tag[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

const Lines = std.AutoArrayHashMapUnmanaged(usize, bool);

/// Folds one report into `files` (path -> line number -> hit).
pub fn addReport(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(Lines), text: []const u8) !void {
    var cur: ?*Lines = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "<class ")) {
            const fname = attr(line, "filename") orelse return error.BadReport;
            const gop = try files.getOrPut(a, try a.dupe(u8, fname));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            cur = gop.value_ptr;
        } else if (std.mem.startsWith(u8, line, "</class>")) {
            cur = null;
        } else if (std.mem.startsWith(u8, line, "<line ")) {
            const lines = cur orelse return error.BadReport;
            const n = std.fmt.parseInt(usize, attr(line, "number") orelse return error.BadReport, 10) catch return error.BadReport;
            const h = std.fmt.parseInt(usize, attr(line, "hits") orelse return error.BadReport, 10) catch return error.BadReport;
            const gop = try lines.getOrPut(a, n);
            gop.value_ptr.* = (gop.found_existing and gop.value_ptr.*) or h > 0;
        }
    }
}

/// The blocks at one source position: how many ran, how many there are.
pub const BlockCount = struct { hit: u32, total: u32 };
pub const BlockPositions = std.AutoArrayHashMapUnmanaged(u64, BlockCount);

/// Folds one block report (zig_cover.zig's) into `files` (path -> `line << 32 | column` -> counts). Two reports of one position (two tests of a
/// package compile the same code) keep the larger of each count: they are the same blocks run by different tests, so the blocks of a position
/// that ran in one report or the other are the larger count, not the sum.
pub fn addBlocks(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(BlockPositions), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = it.next() orelse return error.BadReport;
    if (!std.mem.eql(u8, first, "# blocks v2")) return error.BadReport;
    while (it.next()) |row| {
        if (row.len == 0) continue;
        var f = std.mem.splitScalar(u8, row, '\t');
        const file = f.next() orelse return error.BadReport;
        const line = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const col = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const hit = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const total = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        if (f.next() != null or total == 0 or hit > total) return error.BadReport;
        const gop = try files.getOrPut(a, file);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, file);
            gop.value_ptr.* = .empty;
        }
        const pos = try gop.value_ptr.getOrPut(a, (@as(u64, line) << 32) | col);
        if (pos.found_existing) {
            pos.value_ptr.hit = @max(pos.value_ptr.hit, hit);
            pos.value_ptr.total = @max(pos.value_ptr.total, total);
        } else pos.value_ptr.* = .{ .hit = hit, .total = total };
    }
}

/// Per file, the blocks that ran and the blocks there are, sorted by path.
pub fn summarizeBlocks(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(BlockPositions)) ![]FileCov {
    var out = std.ArrayList(FileCov).empty;
    var it = files.iterator();
    while (it.next()) |e| {
        var hit: usize = 0;
        var total: usize = 0;
        for (e.value_ptr.values()) |c| {
            hit += c.hit;
            total += c.total;
        }
        try out.append(a, .{ .path = e.key_ptr.*, .hit = hit, .total = total });
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

pub fn summarize(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(Lines)) ![]FileCov {
    var out = std.ArrayList(FileCov).empty;
    var it = files.iterator();
    while (it.next()) |e| {
        var hit: usize = 0;
        for (e.value_ptr.values()) |h| {
            if (h) hit += 1;
        }
        try out.append(a, .{ .path = e.key_ptr.*, .hit = hit, .total = e.value_ptr.count() });
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

fn isExpected(expect: []const []const u8, path: []const u8) bool {
    for (expect) |e| if (std.mem.eql(u8, e, path)) return true;
    return false;
}

/// The text of the summary: one line per file, then the total. With `expect` (the package's own sources) the total counts those
/// files only (the tests' own lines are listed but not counted, as covcheck leaves them out); without, every file.
pub fn render(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8) ![]u8 {
    return renderWith(a, rows, expect, "");
}

/// `render`, every row starting with `prefix` (the branch listing's is `branches `).
pub fn renderWith(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8, prefix: []const u8) ![]u8 {
    var o = std.ArrayList(u8).empty;
    var hit: usize = 0;
    var total: usize = 0;
    for (rows) |r| {
        const counted = expect.len == 0 or isExpected(expect, r.path);
        try o.print(a, "{s}{s} {d}/{d} {d}%{s}\n", .{ prefix, r.path, r.hit, r.total, pct(r.hit, r.total), if (counted) "" else " (not counted)" });
        if (counted) {
            hit += r.hit;
            total += r.total;
        }
    }
    try o.print(a, "{s}total {d}/{d} {d}%\n", .{ prefix, hit, total, pct(hit, total) });
    return o.toOwnedSlice(a);
}

fn pct(hit: usize, total: usize) usize {
    return if (total == 0) 0 else hit * 100 / total;
}

/// The first of `expect` that no row names.
pub fn missing(rows: []const FileCov, expect: []const []const u8) ?[]const u8 {
    for (expect) |e| {
        var found = false;
        for (rows) |r| found = found or std.mem.eql(u8, r.path, e);
        if (!found) return e;
    }
    return null;
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_summary: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var out_path: ?[]const u8 = null;
    var expect = std.ArrayList([]const u8).empty;
    var reports = std.ArrayList([]const u8).empty;
    var block_reports = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--out") and i + 1 < argv.len) {
            i += 1;
            out_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--expect") and i + 1 < argv.len) {
            i += 1;
            try expect.append(a, argv[i]);
        } else if (std.mem.eql(u8, argv[i], "--blocks") and i + 1 < argv.len) {
            i += 1;
            try block_reports.append(a, argv[i]);
        } else if (argv[i].len > 0 and argv[i][0] == '-') {
            die(2, "unknown option {s}", .{argv[i]});
        } else {
            try reports.append(a, argv[i]);
        }
    }
    if (out_path == null or reports.items.len == 0) die(2, "usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... <report.xml>...", .{});
    var files: std.StringArrayHashMapUnmanaged(Lines) = .empty;
    for (reports.items) |p| {
        const text = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
        addReport(a, &files, text) catch die(1, "{s} is not a normalized Cobertura report", .{p});
    }
    const rows = try summarize(a, &files);
    if (missing(rows, expect.items)) |m| die(1, "{s} is in no report: no test compiled it, or kcov could not open it", .{m});
    var text = try render(a, rows, expect.items);
    if (block_reports.items.len != 0) {
        var blocks: std.StringArrayHashMapUnmanaged(BlockPositions) = .empty;
        for (block_reports.items) |p| {
            const btext = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
            addBlocks(a, &blocks, btext) catch die(1, "{s} is not a block report", .{p});
        }
        const brows = try summarizeBlocks(a, &blocks);
        if (missing(brows, expect.items)) |m| die(1, "{s} is in no block report: no test compiled it with block counters", .{m});
        text = try std.mem.concat(a, u8, &.{ text, try renderWith(a, brows, expect.items, "branches ") });
    }
    std.fs.cwd().writeFile(.{ .sub_path = out_path.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out_path.?, @errorName(e) });
}
