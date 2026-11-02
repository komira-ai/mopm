//! //:agents: AGENTS.md's shared core is the canonical copy tests/agents/shared_core.md, that copy hashes to
//! tests/agents/shared_core.sha256, and CLAUDE.md imports AGENTS.md (agents_check.zig). Each rule is shown failing on an edited copy of
//! the text, with the exact message, and passing on its near misses.

const std = @import("std");
const ac = @import("agents_check.zig");
const t = std.testing;

/// A file of the repository: under BUILDRULES_TEST_WORK (the target's `data`) in the Buck2 build, else relative to the current directory,
/// the repository root (`zig test tests/drivers/agents_check_test.zig`, as lint.yml runs it).
fn work(a: std.mem.Allocator, sub: []const u8) ![]const u8 {
    const root = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try a.dupe(u8, "."),
        else => return err,
    };
    return std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ root, sub }), 1 << 20);
}

const Real = struct { agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .agents = try work(a, "AGENTS.md"), .copy = try work(a, "tests/agents/shared_core.md"), .sums = try work(a, "tests/agents/shared_core.sha256"), .claude = try work(a, "CLAUDE.md") };
}

/// `text` with its one `from` replaced by `to`.
fn edit(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, from));
    const at = std.mem.indexOf(u8, text, from).?;
    return std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn sumsOf(a: std.mem.Allocator, copy: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    return std.fmt.allocPrint(a, "{s}  shared_core.md\n", .{std.fmt.bytesToHex(digest, .lower)});
}

/// The findings of `check` are exactly `want`, in order.
fn expectFindings(agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const f = try ac.check(arena.allocator(), agents, copy, sums, claude);
    for (f.items) |x| std.debug.print("finding: {s}\n", .{x});
    try t.expectEqual(want.len, f.items.len);
    for (want, f.items) |w, g| try t.expectEqualStrings(w, g);
}

const small_core = "## Core\n\n- X1 BLOCK. One rule.\n- X2 SHOULD. Another.\n";
const small_agents = "# AGENTS.md\n\nIntro.\n\n" ++ ac.begin_marker ++ "\n" ++ small_core ++ ac.end_marker ++ "\n\n## Repo\n";

test "the real AGENTS.md, its core copy, the copy's hash and CLAUDE.md agree" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try real(arena.allocator());
    try expectFindings(r.agents, r.copy, r.sums, r.claude, &.{});
}

test "the real core is the canonical core, and a change in it is found in the real files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try real(a);
    const from = "never demand above 99.";
    const to = "never demand above 95.";
    const changed = try edit(a, r.agents, from, to);
    // the line of T1 in each file, and its text
    const in_agents = std.mem.indexOf(u8, r.agents, from).?;
    const in_copy = std.mem.indexOf(u8, r.copy, from).?;
    const start = std.mem.lastIndexOfScalar(u8, r.copy[0..in_copy], '\n').? + 1;
    const line = r.copy[start..std.mem.indexOfScalarPos(u8, r.copy, in_copy, '\n').?];
    try expectFindings(changed, r.copy, r.sums, r.claude, &.{
        try std.fmt.allocPrint(a, "AGENTS.md:{d}: the shared core differs from tests/agents/shared_core.md:{d}: `{s}` against `{s}` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)", .{
            std.mem.count(u8, r.agents[0..in_agents], "\n") + 1, std.mem.count(u8, r.copy[0..in_copy], "\n") + 1, try edit(a, line, from, to), line,
        }),
    });
    // the same change in the copy too: the hash finds it
    const changed_copy = try edit(a, r.copy, from, to);
    try expectFindings(changed, changed_copy, r.sums, r.claude, &.{
        try std.fmt.allocPrint(a, "tests/agents/shared_core.sha256 names {s}, but tests/agents/shared_core.md hashes to {s}: the canonical core changed", .{ r.sums[0..64], (try sumsOf(a, changed_copy))[0..64] }),
    });
}

test "a small AGENTS.md whose core is its copy, with the copy's hash, has no finding" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    try expectFindings(small_agents, small_core, s, "@AGENTS.md\n", &.{});
}

test "a changed line of the core is named with its line in both files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    try expectFindings(try edit(a, small_agents, "Another.", "Another one."), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from tests/agents/shared_core.md:4: `- X2 SHOULD. Another one.` against `- X2 SHOULD. Another.` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
}

test "a core longer or shorter than its copy is found where one of them ends" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    // a rule added at the end of the core in AGENTS.md alone
    try expectFindings(try edit(a, small_agents, "Another.\n", "Another.\n- X3 SHOULD. New.\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:10: the shared core differs from tests/agents/shared_core.md:5: `- X3 SHOULD. New.` against `(the end of the copy)` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
    // the last rule of the core removed from AGENTS.md alone
    try expectFindings(try edit(a, small_agents, "- X2 SHOULD. Another.\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from tests/agents/shared_core.md:4: `(the end of the core)` against `- X2 SHOULD. Another.` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
    // a core that is empty, against a copy that is not
    const empty = "# AGENTS.md\n" ++ ac.begin_marker ++ "\n" ++ ac.end_marker ++ "\n";
    try expectFindings(empty, small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:3: the shared core differs from tests/agents/shared_core.md:1: `(the end of the core)` against `## Core` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
    // an empty line added at the end of the core: a line, not the end
    try expectFindings(try edit(a, small_agents, "Another.\n", "Another.\n\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:10: the shared core differs from tests/agents/shared_core.md:5: `` against `(the end of the copy)` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
}

test "a core that differs only in its final newline is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the copy lost its last newline (an editor that strips it), the core in AGENTS.md did not
    const short = small_core[0 .. small_core.len - 1];
    try expectFindings(small_agents, short, try sumsOf(a, short), "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from tests/agents/shared_core.md in the newline after its last line",
    });
}

test "a line ending changed to CRLF is a difference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    try expectFindings(try edit(a, small_agents, "One rule.\n", "One rule.\r\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:8: the shared core differs from tests/agents/shared_core.md:3: `- X1 BLOCK. One rule.\r` against `- X1 BLOCK. One rule.` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
    });
}

test "markers that are missing, doubled, not a line of their own or out of order are found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    const begin_twice = "The begin `" ++ ac.begin_marker ++ "` once more.\n";
    try expectFindings(try edit(a, small_agents, ac.begin_marker ++ "\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
    });
    try expectFindings(try edit(a, small_agents, ac.end_marker ++ "\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // both missing: both named
    try expectFindings("# AGENTS.md\n", small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // a second begin line
    try expectFindings(try edit(a, small_agents, "## Repo\n", "## Repo\n" ++ ac.begin_marker ++ "\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 2 times, not once",
    });
    // a marker inside a sentence is not a marker line, so it is neither counted nor taken for the core's edge
    try expectFindings(try edit(a, small_agents, "Intro.\n", begin_twice), small_core, s, "@AGENTS.md\n", &.{});
    // a marker with a trailing space is not the marker
    try expectFindings(try edit(a, small_agents, ac.end_marker ++ "\n", ac.end_marker ++ " \n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // the end before the begin
    const swapped = "# AGENTS.md\n" ++ ac.end_marker ++ "\n" ++ small_core ++ ac.begin_marker ++ "\n";
    try expectFindings(swapped, small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:2: the end of the shared core comes before its begin (line 7)",
    });
}

test "an end marker on the last line without a newline still ends the core" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    try expectFindings(ac.begin_marker ++ "\n" ++ small_core ++ ac.end_marker, small_core, s, "@AGENTS.md\n", &.{});
}

test "a hash file that is not the sha256sum line of the copy is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    const malformed = [_][]const u8{
        s[0 .. s.len - 1], // no newline
        try std.mem.concat(a, u8, &.{ s, "\n" }), // a second line
        try std.ascii.allocUpperString(a, s), // uppercase hex (and name)
        try edit(a, s, "  shared_core.md", " shared_core.md"), // one space
        try edit(a, s, "  shared_core.md", "  AGENTS.md"), // another file
        try std.mem.concat(a, u8, &.{ "g", s[1..] }), // a character that is not hex
        s[1..], // 63 digits
        "",
    };
    for (malformed) |m| {
        const want = try std.fmt.allocPrint(a, "tests/agents/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): `{s}`", .{m});
        try expectFindings(small_agents, small_core, m, "@AGENTS.md\n", &.{want});
    }
    // well formed, but another digest
    const zeros = "0" ** 64 ++ "  shared_core.md\n";
    try expectFindings(small_agents, small_core, zeros, "@AGENTS.md\n", &.{
        try std.fmt.allocPrint(a, "tests/agents/shared_core.sha256 names {s}, but tests/agents/shared_core.md hashes to {s}: the canonical core changed", .{ "0" ** 64, s[0..64] }),
    });
}

test "CLAUDE.md imports AGENTS.md only on a line of its own outside a code block" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    const missing = [_][]const u8{
        "",
        "# CLAUDE.md\n\nRead AGENTS.md.\n",
        "Read @AGENTS.md first.\n", // inside a sentence
        "@AGENTS.md.bak\n", // another file
        "@AGENTS.md \n", // anything after it
        " @AGENTS.md\n", // anything before it
        "@agents.md\n", // another case
        "```\n" ++ ac.import_line ++ "\n```\n", // inside a fence
        "  ```md\n" ++ ac.import_line ++ "\n```\n", // inside an indented fence with a language
        "~~~\n" ++ ac.import_line ++ "\n~~~\n", // inside a tilde fence
        "````\n```\n" ++ ac.import_line ++ "\n````\n", // a shorter fence inside a longer one does not close it
        "~~~\n```\n" ++ ac.import_line ++ "\n~~~\n", // nor does a fence of the other character
        "```\n" ++ ac.import_line ++ "\n", // inside a fence never closed
        "@AGENTS.md\r\n", // a CRLF line: strict, as the core is
    };
    for (missing) |c| try expectFindings(small_agents, small_core, s, c, &.{"CLAUDE.md does not import AGENTS.md: no line is exactly `@AGENTS.md` outside a code block"});
    const present = [_][]const u8{
        "@AGENTS.md\n",
        "@AGENTS.md", // no newline
        "# CLAUDE.md\n\n" ++ ac.import_line ++ "\n\nThe repository's own notes.\n", // among other lines
        "```\nan example\n```\n" ++ ac.import_line ++ "\n", // after a closed fence
        "~~~\nan example\n~~~~\n" ++ ac.import_line ++ "\n", // after a tilde fence closed by a longer one
        "``\n" ++ ac.import_line ++ "\n", // two backticks are no fence
        "``code`` in a sentence\n" ++ ac.import_line ++ "\n", // nor are two backticks followed by text
        "    ```\n" ++ ac.import_line ++ "\n", // four spaces of indent are no fence
    };
    for (present) |c| try expectFindings(small_agents, small_core, s, c, &.{});
}

test "every problem of the four files is reported together" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFindings(try edit(a, small_agents, "One rule.", "One changed rule."), small_core, "", "", &.{
        "AGENTS.md:8: the shared core differs from tests/agents/shared_core.md:3: `- X1 BLOCK. One changed rule.` against `- X1 BLOCK. One rule.` (change the core in AGENTS.md, tests/agents/shared_core.md and tests/agents/shared_core.sha256 together)",
        "tests/agents/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): ``",
        "CLAUDE.md does not import AGENTS.md: no line is exactly `@AGENTS.md` outside a code block",
    });
}
