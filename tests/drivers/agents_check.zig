//! The check of AGENTS.md (the rules every change is written and reviewed against) and CLAUDE.md (which imports it): pure functions of
//! the texts, so agents_check_test.zig tests each rule against edited copies as well as against the real files.
//!
//! What the rules catch:
//!  - a shared core that drifted: the text between the two marker lines of AGENTS.md is, byte for byte, tests/agents/shared_core.md
//!    (the first line that differs is named, in both files);
//!  - a copy edited along with it: tests/agents/shared_core.sha256 is `<sha256 of the copy, lowercase hex>  shared_core.md` and one
//!    newline, the form `sha256sum` writes, and the digest is the copy's;
//!  - markers that cannot delimit the core: each of the two is a line of its own, exactly once, the begin before the end;
//!  - a CLAUDE.md that no longer imports AGENTS.md: a line that is exactly `@AGENTS.md`, outside a fenced code block of backticks or
//!    tildes and outside a code span (an import inside either, inside a sentence or with anything after it, a carriage return included,
//!    is not read as one).
const std = @import("std");

pub const Findings = std.ArrayList([]const u8);

pub const begin_marker = "<!-- shared-core:begin -->";
pub const end_marker = "<!-- shared-core:end -->";
pub const import_line = "@AGENTS.md";
const copy_name = "shared_core.md";

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(try std.fmt.allocPrint(a, fmt, args));
}

/// A marker line of `text`: its 1-based line number, where the line starts and where the text after it starts.
const Marker = struct { line: usize, start: usize, after: usize };

/// Every line of `text` that is exactly `marker`.
fn markers(a: std.mem.Allocator, text: []const u8, marker: []const u8) ![]Marker {
    var out = std.ArrayList(Marker).init(a);
    var start: usize = 0;
    var n: usize = 1;
    while (start <= text.len) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const stop = nl orelse text.len;
        if (std.mem.eql(u8, text[start..stop], marker)) try out.append(.{ .line = n, .start = start, .after = if (nl) |i| i + 1 else text.len });
        start = stop + 1;
    }
    return out.items;
}

/// The shared core of AGENTS.md (the text after the begin line, up to the end line) and the line it starts on, or null with findings.
pub fn core(a: std.mem.Allocator, f: *Findings, agents: []const u8) !?struct { text: []const u8, first_line: usize } {
    const b = try markers(a, agents, begin_marker);
    const e = try markers(a, agents, end_marker);
    if (b.len != 1) try add(a, f, "AGENTS.md: the line `{s}` is there {d} times, not once", .{ begin_marker, b.len });
    if (e.len != 1) try add(a, f, "AGENTS.md: the line `{s}` is there {d} times, not once", .{ end_marker, e.len });
    if (b.len != 1 or e.len != 1) return null;
    if (e[0].start < b[0].after) {
        try add(a, f, "AGENTS.md:{d}: the end of the shared core comes before its begin (line {d})", .{ e[0].line, b[0].line });
        return null;
    }
    return .{ .text = agents[b[0].after..e[0].start], .first_line = b[0].line + 1 };
}

/// The lines of a text, without their newlines: an empty text has none, and a final newline ends the last line rather than starting one.
const Lines = struct {
    rest: ?[]const u8,

    fn of(text: []const u8) Lines {
        if (text.len == 0) return .{ .rest = null };
        return .{ .rest = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text };
    }

    fn next(self: *Lines) ?[]const u8 {
        const r = self.rest orelse return null;
        if (std.mem.indexOfScalar(u8, r, '\n')) |i| {
            self.rest = r[i + 1 ..];
            return r[0..i];
        }
        self.rest = null;
        return r;
    }
};

/// The first line where `got` (the core of AGENTS.md, starting on line `first_line`) and `want` (tests/agents/shared_core.md) differ.
pub fn sameCore(a: std.mem.Allocator, f: *Findings, got: []const u8, first_line: usize, want: []const u8) !void {
    if (std.mem.eql(u8, got, want)) return;
    var g = Lines.of(got);
    var w = Lines.of(want);
    var n: usize = 1;
    while (true) : (n += 1) {
        const gl = g.next();
        const wl = w.next();
        if (gl == null and wl == null) {
            // every line the same: the texts differ in the newline after the last one
            try add(a, f, "AGENTS.md:{d}: the shared core differs from tests/agents/{s} in the newline after its last line", .{ first_line + n - 2, copy_name });
            return;
        }
        if (gl != null and wl != null and std.mem.eql(u8, gl.?, wl.?)) continue;
        try add(a, f, "AGENTS.md:{d}: the shared core differs from tests/agents/{s}:{d}: `{s}` against `{s}` (change the core in AGENTS.md, tests/agents/{s} and tests/agents/shared_core.sha256 together)", .{
            first_line + n - 1, copy_name, n, gl orelse "(the end of the core)", wl orelse "(the end of the copy)", copy_name,
        });
        return;
    }
}

/// tests/agents/shared_core.sha256 is the `sha256sum` line of tests/agents/shared_core.md, and its digest is the copy's.
pub fn sameHash(a: std.mem.Allocator, f: *Findings, sums: []const u8, copy: []const u8) !void {
    const tail = "  " ++ copy_name ++ "\n";
    const well_formed = sums.len == 64 + tail.len and std.mem.eql(u8, sums[64..], tail) and for (sums[0..64]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) break false;
    } else true;
    if (!well_formed) {
        try add(a, f, "tests/agents/shared_core.sha256 is not one line `<64 lowercase hex>  {s}` (what `sha256sum {s}` writes): `{s}`", .{ copy_name, copy_name, sums });
        return;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    const have = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, sums[0..64], &have)) try add(a, f, "tests/agents/shared_core.sha256 names {s}, but tests/agents/{s} hashes to {s}: the canonical core changed", .{ sums[0..64], copy_name, &have });
}

/// A fence of a fenced code block: its character (backtick or tilde) and length.
const Fence = struct { char: u8, len: usize };

/// The run of three or more backticks or tildes a line starts with, after up to three spaces, and the rest of the line after it.
fn fenceRun(line: []const u8) ?struct { fence: Fence, rest: []const u8 } {
    const s = std.mem.trimLeft(u8, line, " ");
    if (line.len - s.len > 3 or s.len == 0 or (s[0] != '`' and s[0] != '~')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) n += 1;
    if (n < 3) return null;
    return .{ .fence = .{ .char = s[0], .len = n }, .rest = s[n..] };
}

/// The fence `line` opens (CommonMark 0.31.2, fenced code blocks): any info string may follow, but a backtick fence's holds no backtick.
fn opener(line: []const u8) ?Fence {
    const r = fenceRun(line) orelse return null;
    if (r.fence.char == '`' and std.mem.indexOfScalar(u8, r.rest, '`') != null) return null;
    return r.fence;
}

/// `line` closes the block `open` opened: the same character, at least as many, then nothing but spaces and tabs.
fn closes(line: []const u8, open: Fence) bool {
    const r = fenceRun(line) orelse return false;
    return r.fence.char == open.char and r.fence.len >= open.len and std.mem.trim(u8, r.rest, " \t").len == 0;
}

/// A line that ends a paragraph: blank (spaces and tabs only), or an ATX heading (up to three spaces, one to six `#`, then a space, a tab or
/// the end of the line). A code span never reaches past one.
fn breaksParagraph(line: []const u8) bool {
    if (std.mem.trim(u8, line, " \t").len == 0) return true;
    const s = std.mem.trimLeft(u8, line, " ");
    if (line.len - s.len > 3) return false;
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    return n >= 1 and n <= 6 and (n == s.len or s[n] == ' ' or s[n] == '\t');
}

/// The number of backticks in the run that starts at `i`.
fn runOf(text: []const u8, i: usize) usize {
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == '`') n += 1;
    return n;
}

/// One of `lines` (a paragraph, outside any fenced block) is exactly `@AGENTS.md` and starts outside a code span. A code span (CommonMark
/// 0.31.2, code spans) opens at a run of backticks not escaped by a backslash and closes at the next run of exactly as many, on the same
/// line or a later one of the paragraph; a run with no such closer is literal text.
fn importIn(a: std.mem.Allocator, lines: []const []const u8) !bool {
    const text = try std.mem.join(a, "\n", lines);
    const code = try a.alloc(bool, text.len);
    @memset(code, false);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and std.ascii.isPrint(text[i + 1]) and !std.ascii.isAlphanumeric(text[i + 1]) and text[i + 1] != ' ') {
            i += 2; // a backslash escape: `\`` is a literal backtick, `\\` a literal backslash
            continue;
        }
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        const n = runOf(text, i);
        var j = i + n;
        const close: ?usize = while (j < text.len) {
            if (text[j] != '`') {
                j += 1;
                continue;
            }
            const m = runOf(text, j);
            if (m == n) break j;
            j += m;
        } else null;
        if (close) |c| {
            @memset(code[i .. c + n], true);
            i = c + n;
        } else i += n;
    }
    var at: usize = 0;
    for (lines) |line| {
        if (std.mem.eql(u8, line, import_line) and !code[at]) return true;
        at += line.len + 1;
    }
    return false;
}

/// CLAUDE.md imports AGENTS.md: a line that is exactly `@AGENTS.md`, outside a fenced code block and outside a code span (an import in
/// either is not read as one).
pub fn imports(a: std.mem.Allocator, f: *Findings, claude: []const u8) !void {
    var open: ?Fence = null;
    var para = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, claude, '\n');
    while (it.next()) |line| {
        if (open) |o| {
            if (closes(line, o)) open = null;
        } else if (opener(line)) |fence| {
            if (try importIn(a, para.items)) return;
            para.clearRetainingCapacity();
            open = fence;
        } else if (breaksParagraph(line)) {
            if (try importIn(a, para.items)) return;
            para.clearRetainingCapacity();
        } else {
            try para.append(line);
        }
    }
    if (try importIn(a, para.items)) return;
    try add(a, f, "CLAUDE.md does not import AGENTS.md: no line is exactly `{s}` outside a code block or code span", .{import_line});
}

/// The most bytes a file of the check may hold; a larger one is an error, not a finding.
pub const max_bytes = 1 << 20;

/// The four files the check reads.
pub const Texts = struct { agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8 };

/// The four files, read from the repository root `root`: a missing, unreadable or larger-than-`max_bytes` file is the error that read gave.
pub fn load(a: std.mem.Allocator, root: std.fs.Dir) !Texts {
    return .{
        .agents = try root.readFileAlloc(a, "AGENTS.md", max_bytes),
        .copy = try root.readFileAlloc(a, "tests/agents/shared_core.md", max_bytes),
        .sums = try root.readFileAlloc(a, "tests/agents/shared_core.sha256", max_bytes),
        .claude = try root.readFileAlloc(a, "CLAUDE.md", max_bytes),
    };
}

/// Everything wrong with AGENTS.md, tests/agents/shared_core.md, tests/agents/shared_core.sha256 and CLAUDE.md.
pub fn check(a: std.mem.Allocator, agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8) !Findings {
    var f = Findings.init(a);
    if (try core(a, &f, agents)) |c| try sameCore(a, &f, c.text, c.first_line, copy);
    try sameHash(a, &f, sums, copy);
    try imports(a, &f, claude);
    return f;
}
