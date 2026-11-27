//! What a tutorial lesson says each of its actions prints: the fenced blocks of its lesson.md whose info string is
//! `output <action>`, such as
//!
//!     ```output run
//!     Hello, world!
//!     ```
//!
//! The page shows such a block as code under the label `output` (the site's renderer names a block by the first word of
//! its info string). //:tutorial_lessons (tutorial_lessons.zig) holds a lesson to one block for each action of its
//! lesson.json and none for another; //:autolink (test_autolink_test.zig) runs each action with the real Mojo and
//! compares what it prints with the block (`sameOutput`: blank lines at the start, white space at the end and the
//! digits of a test's time, `(81 ms)`, do not count).
//!
//! A fence is read as CommonMark and the site's parser (site/src/markdown/parse.ts) read a fence at the top level of the
//! text (a fence inside a list item or a block quote is not looked for; write output blocks at the top level): a line that starts, after
//! at most three spaces, with three or more backticks or tildes (a backtick fence's info string holds no backtick); the
//! block ends at a line of at least as many of the same character and nothing else but spaces and tabs, or at the end of
//! the text. A block's lines lose the spaces its opening fence was indented by. The lines of any fenced block are never
//! read as fences, so a block that shows a fence holds it as text.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One output block of lesson.md.
pub const Block = struct {
    /// The action it is the output of: the word after `output`.
    action: []const u8,
    /// Its lines, each ended by a newline.
    text: []const u8,
    /// The line of lesson.md (from 1) its opening fence is on.
    line: usize,
};

/// lesson.md's output blocks and what is wrong with them.
pub const Parsed = struct {
    /// The well-formed blocks, in the order of lesson.md; the first of two for one action.
    blocks: []const Block,
    /// `line <n>: <what is wrong>`, in the order of lesson.md.
    problems: []const []const u8,
};

const Fence = struct { indent: usize, char: u8, len: usize, info: []const u8 };

/// The number of spaces `line` starts with, at most three.
fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    return i;
}

/// The number of `ch` at `line[from..]`'s start.
fn runOf(line: []const u8, from: usize, ch: u8) usize {
    var n: usize = 0;
    while (from + n < line.len and line[from + n] == ch) n += 1;
    return n;
}

/// The opening fence `line` is, or null.
fn fenceOpen(line: []const u8) ?Fence {
    const i = indentOf(line);
    if (i == line.len or (line[i] != '`' and line[i] != '~')) return null;
    const n = runOf(line, i, line[i]);
    if (n < 3) return null;
    const info = std.mem.trim(u8, line[i + n ..], " \t");
    if (line[i] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .indent = i, .char = line[i], .len = n, .info = info };
}

/// Whether `line` closes the block `f` opened.
fn closes(line: []const u8, f: Fence) bool {
    const i = indentOf(line);
    const n = runOf(line, i, f.char);
    return n >= f.len and std.mem.trim(u8, line[i + n ..], " \t").len == 0;
}

/// The output blocks of `markdown` (lesson.md) and what is wrong with them: a block that names no action or more than
/// one word after it, a block never closed, and a second block for one action.
pub fn outputBlocks(a: Allocator, markdown: []const u8) !Parsed {
    var blocks = std.ArrayList(Block).init(a);
    var problems = std.ArrayList([]const u8).init(a);
    var lines = std.ArrayList([]const u8).init(a);
    var split = std.mem.splitScalar(u8, markdown, '\n');
    while (split.next()) |l| try lines.append(l);

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const f = fenceOpen(lines.items[i]) orelse continue;
        const line = i + 1;
        var body = std.ArrayList(u8).init(a);
        i += 1;
        while (i < lines.items.len and !closes(lines.items[i], f)) : (i += 1) {
            const l = lines.items[i];
            try body.appendSlice(l[@min(f.indent, indentOf(l))..]);
            try body.append('\n');
        }
        var words = std.mem.tokenizeAny(u8, f.info, " \t");
        if (!std.mem.eql(u8, words.next() orelse "", "output")) continue;
        if (i == lines.items.len) {
            try problems.append(try std.fmt.allocPrint(a, "line {d}: the output block is never closed", .{line}));
            continue;
        }
        const action = words.next() orelse {
            try problems.append(try std.fmt.allocPrint(a, "line {d}: the output block names no action: write ```output run or ```output test", .{line}));
            continue;
        };
        if (words.next() != null) {
            try problems.append(try std.fmt.allocPrint(a, "line {d}: the output block's info string is more than `output <action>`: {s}", .{ line, f.info }));
            continue;
        }
        if (find(blocks.items, action)) |first| {
            try problems.append(try std.fmt.allocPrint(a, "line {d}: a second output block for {s} (the first is on line {d})", .{ line, action, first.line }));
            continue;
        }
        try blocks.append(.{ .action = action, .text = body.items, .line = line });
    }
    return .{ .blocks = blocks.items, .problems = problems.items };
}

/// The block of `action` among `blocks`, or null.
pub fn find(blocks: []const Block, action: []const u8) ?Block {
    for (blocks) |b| {
        if (std.mem.eql(u8, b.action, action)) return b;
    }
    return null;
}

/// `s` without the blank lines it starts with and the spaces, tabs and line ends it ends with.
fn trimmed(s: []const u8) []const u8 {
    var start: usize = 0;
    for (s, 0..) |ch, k| {
        if (ch == '\n') {
            start = k + 1;
        } else if (ch != ' ' and ch != '\t' and ch != '\r') break;
    }
    return std.mem.trimRight(u8, s[@min(start, s.len)..], " \t\r\n");
}

/// `s` with each duration `(<digits> ms)`, as `mopm test` times a test, written `(# ms)`.
fn withoutDurations(a: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '(') {
            var j = i + 1;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j > i + 1 and std.mem.startsWith(u8, s[j..], " ms)")) {
                try out.appendSlice("(# ms)");
                i = j + " ms)".len;
                continue;
            }
        }
        try out.append(s[i]);
        i += 1;
    }
    return out.items;
}

/// Whether `got`, what an action printed, is the block's text `want`: the same bytes once blank lines at the start and
/// spaces, tabs and line ends at the end are removed from each (`mopm test` starts its summary with a blank line), and
/// any duration `(<digits> ms)` matches any other (`mopm test` prints how long each test took).
pub fn sameOutput(a: Allocator, want: []const u8, got: []const u8) !bool {
    return std.mem.eql(u8, trimmed(try withoutDurations(a, want)), trimmed(try withoutDurations(a, got)));
}
