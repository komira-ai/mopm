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
//!    tildes (an import inside a fence, inside a sentence or with anything after it, a carriage return included, is not read as one).
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

/// The fence a line opens or closes: its character (backtick or tilde) and length, when the line, after up to three spaces, starts with three
/// or more of one of them.
fn fenceOf(line: []const u8) ?struct { char: u8, len: usize } {
    const s = std.mem.trimLeft(u8, line, " ");
    if (line.len - s.len > 3 or s.len < 3 or (s[0] != '`' and s[0] != '~')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) n += 1;
    if (n < 3) return null;
    return .{ .char = s[0], .len = n };
}

/// CLAUDE.md has a line that is exactly `@AGENTS.md`, outside a fenced code block (a fence closes with its own character, at least as long).
pub fn imports(a: std.mem.Allocator, f: *Findings, claude: []const u8) !void {
    var open: ?struct { char: u8, len: usize } = null;
    var it = std.mem.splitScalar(u8, claude, '\n');
    while (it.next()) |line| {
        if (fenceOf(line)) |fence| {
            if (open == null) {
                open = .{ .char = fence.char, .len = fence.len };
            } else if (open.?.char == fence.char and fence.len >= open.?.len) {
                open = null;
            }
        } else if (open == null and std.mem.eql(u8, line, import_line)) {
            return;
        }
    }
    try add(a, f, "CLAUDE.md does not import AGENTS.md: no line is exactly `{s}` outside a code block", .{import_line});
}

/// Everything wrong with AGENTS.md, tests/agents/shared_core.md, tests/agents/shared_core.sha256 and CLAUDE.md.
pub fn check(a: std.mem.Allocator, agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8) !Findings {
    var f = Findings.init(a);
    if (try core(a, &f, agents)) |c| try sameCore(a, &f, c.text, c.first_line, copy);
    try sameHash(a, &f, sums, copy);
    try imports(a, &f, claude);
    return f;
}
