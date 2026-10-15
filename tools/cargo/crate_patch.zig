//! crate_patch: copies parts of an unpacked crate and edits them, in a build
//! action, where Cargo would run the crate's build script.
//!
//!   crate_patch <spec.json> <crate dir> <out dir>
//!
//! The spec:
//!   {"copy": ["src", ...],                  entries of the crate directory to copy (all if empty)
//!    "sub":  [{"file", "from", "to", "count"}],   exact text substitutions
//!    "add":  [{"file", "content"}]}               generated files
//!
//! A substitution that matches a number of times other than `count` (default
//! 1) is an error: a patch that stops matching after a crate upgrade must
//! fail the build, not silently do nothing. Output is deterministic: the
//! same inputs give the same bytes.

const std = @import("std");

const Sub = struct { file: []const u8, from: []const u8, to: []const u8, count: usize = 1 };
const Add = struct { file: []const u8, content: []const u8 };
const Spec = struct {
    copy: []const []const u8 = &.{},
    sub: []const Sub = &.{},
    add: []const Add = &.{},
};

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("crate_patch: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// `text` with every `from` replaced by `to`; `n` is how many there were.
pub fn replaceAll(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8, n: *usize) ![]u8 {
    n.* = 0;
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    if (from.len == 0) return error.EmptyPattern;
    while (std.mem.indexOfPos(u8, text, i, from)) |at| {
        try out.appendSlice(text[i..at]);
        try out.appendSlice(to);
        i = at + from.len;
        n.* += 1;
    }
    try out.appendSlice(text[i..]);
    return out.toOwnedSlice();
}

fn copyTree(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir, spec: Spec, prefix: []const u8) !void {
    var it = src.iterate();
    while (try it.next()) |e| {
        const rel = if (prefix.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        switch (e.kind) {
            .directory => {
                try dst.makePath(e.name);
                var s = try src.openDir(e.name, .{ .iterate = true });
                defer s.close();
                var d = try dst.openDir(e.name, .{});
                defer d.close();
                try copyTree(a, s, d, spec, rel);
            },
            .file => {
                var data = try src.readFileAlloc(a, e.name, 1 << 28);
                for (spec.sub) |s| {
                    if (!std.mem.eql(u8, s.file, rel)) continue;
                    var n: usize = 0;
                    data = try replaceAll(a, data, s.from, s.to, &n);
                    if (n != s.count) fail("{s}: `{s}` matched {d} times, expected {d}", .{ rel, s.from, n, s.count });
                }
                try dst.writeFile(e.name, data);
            },
            else => fail("{s}: not a file or directory", .{rel}),
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4) fail("usage: crate_patch <spec.json> <crate dir> <out dir>", .{});
    const spec_text = try std.fs.cwd().readFileAlloc(a, args[1], 1 << 24);
    const spec = (try std.json.parseFromSlice(Spec, a, spec_text, .{})).value;

    var in = try std.fs.cwd().openDir(args[2], .{ .iterate = true });
    defer in.close();
    try std.fs.cwd().makePath(args[3]);
    var out = try std.fs.cwd().openDir(args[3], .{});
    defer out.close();

    if (spec.copy.len == 0) {
        try copyTree(a, in, out, spec, "");
    } else {
        for (spec.copy) |name| {
            const st = try in.statFile(name);
            if (st.kind == .directory) {
                try out.makePath(name);
                var s = try in.openDir(name, .{ .iterate = true });
                defer s.close();
                var d = try out.openDir(name, .{});
                defer d.close();
                try copyTree(a, s, d, spec, name);
            } else {
                var data = try in.readFileAlloc(a, name, 1 << 28);
                for (spec.sub) |s| {
                    if (!std.mem.eql(u8, s.file, name)) continue;
                    var n: usize = 0;
                    data = try replaceAll(a, data, s.from, s.to, &n);
                    if (n != s.count) fail("{s}: `{s}` matched {d} times, expected {d}", .{ name, s.from, n, s.count });
                }
                try out.writeFile(name, data);
            }
        }
    }
    for (spec.add) |f| {
        if (std.fs.path.dirname(f.file)) |d| try out.makePath(d);
        try out.writeFile(f.file, f.content);
    }
    // Every substitution must name a file that was copied.
    for (spec.sub) |s| {
        out.access(s.file, .{}) catch fail("sub: {s} is not in the output", .{s.file});
    }
}

test "replaceAll counts and replaces" {
    const a = std.testing.allocator;
    var n: usize = 0;
    const r = try replaceAll(a, "aXbXc", "X", "--", &n);
    defer a.free(r);
    try std.testing.expectEqualStrings("a--b--c", r);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "replaceAll with no match reports zero" {
    const a = std.testing.allocator;
    var n: usize = 7;
    const r = try replaceAll(a, "abc", "Z", "y", &n);
    defer a.free(r);
    try std.testing.expectEqualStrings("abc", r);
    try std.testing.expectEqual(@as(usize, 0), n);
}
