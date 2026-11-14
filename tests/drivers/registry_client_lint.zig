//! The registry client lint (//:registry_client_lint): the command line reaches the registry's API only through the
//! generated client (src/core/registry_v2.zig), and every operation of that client has a generated command.
//!
//! Three rules, run over text so the tests can feed samples:
//!   1. every operation of the client (`pub const <Op> = struct {` with a `pub const operation_id`) is named as `v2.<Op>`
//!      in src/cli/registry_commands.zig;
//!   2. a hand-written file (every src/cli/*.zig but registry_commands.zig and the test files, and src/core/ci_oidc.zig)
//!      does not call `.request(`, `.once(`, `.vtable.request(`, `http.request(` or `http.retrying(`;
//!   3. nor does it hold a string literal that builds a registry path: `/api/v1/` or `/api/v2/` inside it, or a first
//!      path segment of the client's routes (`/me`, `/packages/...`) at its start.
//! A request that is not the registry's API says so with `// not the registry API: <why>` on its line or the line above.
//! Comment lines, multi-line string lines and the bodies of `test "..." {` blocks are not code.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const client_path = "src/core/registry_v2.zig";
pub const commands_path = "src/cli/registry_commands.zig";

pub const msg_call = "sends a registry request without the generated client; use v2.send, v2.sendOnce or v2.call, or put `// not the registry API: <why>` on the line or the line above";
pub const msg_path = "builds a registry path by hand; use the generated client";

pub const File = struct { path: []const u8, data: []const u8 };

pub const Finding = struct {
    file: []const u8,
    line: usize,
    message: []const u8,
};

/// `<file>:<line>: <message>`
pub fn render(a: Allocator, f: Finding) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ f.file, f.line, f.message });
}

/// Whether the rules 2 and 3 read the file: src/cli/*.zig except the generated table and the test files, and src/core/ci_oidc.zig.
pub fn handWritten(path: []const u8) bool {
    if (std.mem.eql(u8, path, "src/core/ci_oidc.zig")) return true;
    const dir = "src/cli/";
    if (!std.mem.startsWith(u8, path, dir)) return false;
    const rest = path[dir.len..];
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return false;
    if (!std.mem.endsWith(u8, rest, ".zig")) return false;
    return !skipped(path);
}

fn skipped(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    return std.mem.eql(u8, path, commands_path);
}

const Op = struct { name: []const u8, id: []const u8, line: usize };

fn isIdent(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

/// The operations of the client text, in its order.
fn operations(a: Allocator, client: []const u8) ![]const Op {
    var ops = std.ArrayList(Op).init(a);
    const head = "pub const ";
    const tail = " = struct {";
    const id_head = "    pub const operation_id = \"";
    var cur: []const u8 = "";
    var cur_line: usize = 0;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, client, '\n');
    while (lines.next()) |raw| {
        n += 1;
        const line = trimCr(raw);
        if (std.mem.startsWith(u8, line, head) and std.mem.endsWith(u8, line, tail)) {
            cur = line[head.len .. line.len - tail.len];
            cur_line = n;
            continue;
        }
        if (cur.len > 0 and std.mem.startsWith(u8, line, id_head)) {
            const rest = line[id_head.len..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            try ops.append(.{ .name = cur, .id = rest[0..end], .line = cur_line });
            cur = "";
        }
    }
    return ops.items;
}

/// The first segments of the client's `path_template`s, once each.
fn routeRoots(a: Allocator, client: []const u8) ![]const []const u8 {
    var roots = std.ArrayList([]const u8).init(a);
    const head = "pub const path_template = \"/";
    var lines = std.mem.splitScalar(u8, client, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, trimCr(raw), " \t");
        if (!std.mem.startsWith(u8, t, head)) continue;
        const rest = t[head.len..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != '/' and rest[end] != '"') end += 1;
        if (end == 0) continue;
        const root = rest[0..end];
        var seen = false;
        for (roots.items) |r| {
            if (std.mem.eql(u8, r, root)) seen = true;
        }
        if (!seen) try roots.append(root);
    }
    return roots.items;
}

/// `v2.<name>` occurs in the commands text, not as the start of a longer name.
fn named(commands: []const u8, name: []const u8, a: Allocator) !bool {
    const needle = try std.fmt.allocPrint(a, "v2.{s}", .{name});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, commands, from, needle)) |i| : (from = i + 1) {
        const after = i + needle.len;
        if (after >= commands.len or !isIdent(commands[after])) return true;
    }
    return false;
}

/// One line read for the rules: its code (comment cut, string and character literal contents blanked), the contents of its
/// string literals, and its comment (the text after `//`).
const Split = struct { code: []u8, lits: []const []const u8, comment: []const u8 };

fn split(a: Allocator, line: []const u8) !Split {
    const code = try a.dupe(u8, line);
    var lits = std.ArrayList([]const u8).init(a);
    var comment: []const u8 = "";
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
            comment = line[i + 2 ..];
            @memset(code[i..], ' ');
            break;
        }
        if (ch == '"' or ch == '\'') {
            var j = i + 1;
            while (j < line.len and line[j] != ch) : (j += 1) {
                if (line[j] == '\\') j += 1;
            }
            const end = @min(j, line.len);
            if (ch == '"') try lits.append(line[i + 1 .. end]);
            @memset(code[i + 1 .. end], ' ');
            i = end + 1;
            continue;
        }
        i += 1;
    }
    return .{ .code = code, .lits = lits.items, .comment = comment };
}

/// The comment is `not the registry API: <why>` with a why.
fn isMarker(comment: []const u8) bool {
    const head = "not the registry API:";
    const t = std.mem.trim(u8, comment, " \t");
    if (!std.mem.startsWith(u8, t, head)) return false;
    return std.mem.trim(u8, t[head.len..], " \t").len > 0;
}

const call_forms = [_][]const u8{ ".request(", ".once(", ".vtable.request(", "http.request(", "http.retrying(" };

fn callsTransport(code: []const u8) bool {
    for (call_forms) |form| {
        if (std.mem.indexOf(u8, code, form) != null) return true;
    }
    return false;
}

/// `lit` is a registry path: it holds `/api/v1/` or `/api/v2/`, or it is `/<root>` followed by its end, `/`, `?` or `#`.
fn buildsPath(lit: []const u8, roots: []const []const u8) bool {
    if (std.mem.indexOf(u8, lit, "/api/v2/") != null or std.mem.indexOf(u8, lit, "/api/v1/") != null) return true;
    if (lit.len == 0 or lit[0] != '/') return false;
    for (roots) |root| {
        const rest = lit[1..];
        if (!std.mem.startsWith(u8, rest, root)) continue;
        if (rest.len == root.len) return true;
        const next = rest[root.len];
        if (next == '/' or next == '?' or next == '#') return true;
    }
    return false;
}

fn checkFile(a: Allocator, f: File, roots: []const []const u8, out: *std.ArrayList(Finding)) !void {
    var in_test = false;
    var depth: i32 = 0;
    var seen_open = false;
    var above: []const u8 = "";
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, f.data, '\n');
    while (lines.next()) |raw| {
        n += 1;
        const line = trimCr(raw);
        const t = std.mem.trim(u8, line, " \t");
        const multiline = std.mem.startsWith(u8, t, "\\\\");
        const sp = try split(a, line);
        const prev = above;
        above = if (multiline) "" else sp.comment;
        if (multiline) continue;
        if (!in_test and std.mem.startsWith(u8, line, "test ")) {
            in_test = true;
            depth = 0;
            seen_open = false;
        }
        if (in_test) {
            for (sp.code) |ch| {
                if (ch == '{') {
                    depth += 1;
                    seen_open = true;
                } else if (ch == '}') {
                    depth -= 1;
                }
            }
            if (seen_open and depth <= 0) in_test = false;
            continue;
        }
        if (std.mem.startsWith(u8, t, "//")) continue;
        if (isMarker(sp.comment) or isMarker(prev)) continue;
        if (callsTransport(sp.code)) {
            try out.append(.{ .file = f.path, .line = n, .message = msg_call });
        }
        for (sp.lits) |lit| {
            if (buildsPath(lit, roots)) {
                try out.append(.{ .file = f.path, .line = n, .message = msg_path });
                break;
            }
        }
    }
}

/// Every finding of the three rules, the first rule's first, then each file's in line order.
pub fn check(a: Allocator, files: []const File, client_text: []const u8, commands_text: []const u8) ![]const Finding {
    var out = std.ArrayList(Finding).init(a);
    for (try operations(a, client_text)) |op| {
        if (try named(commands_text, op.name, a)) continue;
        const message = try std.fmt.allocPrint(a, "{s} ({s}) has no generated command in {s}", .{ op.name, op.id, commands_path });
        try out.append(.{ .file = client_path, .line = op.line, .message = message });
    }
    const roots = try routeRoots(a, client_text);
    for (files) |f| {
        if (skipped(f.path)) continue;
        try checkFile(a, f, roots, &out);
    }
    return out.items;
}
