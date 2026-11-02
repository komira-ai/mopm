//! //:agents: AGENTS.md's shared core is the canonical copy tests/agents/shared_core.md, that copy hashes to
//! tests/agents/shared_core.sha256, and CLAUDE.md imports AGENTS.md (agents_check.zig). Each rule is shown failing on an edited copy of
//! the text, with the exact message, and passing on its near misses.

const std = @import("std");
const ac = @import("agents_check.zig");
const t = std.testing;

/// The repository root: BUILDRULES_TEST_WORK (the target's `data`) in the Buck2 build, else the current directory, the repository root
/// (`zig test tests/drivers/agents_check_test.zig`, as lint.yml runs it).
fn real(a: std.mem.Allocator) !ac.Texts {
    const root = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try a.dupe(u8, "."),
        else => return err,
    };
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();
    return ac.load(a, dir);
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
        // the same length as a good line, one part wrong at a time
        try std.mem.concat(a, u8, &.{ try std.ascii.allocUpperString(a, s[0..64]), s[64..] }), // the digest alone in uppercase
        try edit(a, s, "shared_core.md", "shared_core.mx"), // another name of the same length
        try edit(a, s, "  shared", " \tshared"), // a tab in the separator
        try std.mem.concat(a, u8, &.{ s[0 .. s.len - 1], " " }), // a space for the final newline
    };
    try t.expect(!std.mem.eql(u8, s[0..64], malformed[8][0..64])); // the digest has letters to uppercase
    for (malformed[8..]) |m| try t.expectEqual(s.len, m.len);
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

const no_import = "CLAUDE.md does not import AGENTS.md: no line is exactly `@AGENTS.md` as a paragraph of its own (a blank line or the file's edge on each side) outside a code block or HTML comment";

test "CLAUDE.md imports AGENTS.md only as a paragraph of its own outside a code block or HTML comment" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    const I = ac.import_line;
    const missing = [_][]const u8{
        "",
        "# CLAUDE.md\n\nRead AGENTS.md.\n",
        "Read @AGENTS.md first.\n", // inside a sentence
        "@AGENTS.md.bak\n", // another file
        "@AGENTS.md \n", // anything after it
        " @AGENTS.md\n", // anything before it
        "@agents.md\n", // another case
        "@AGENTS.md\r\n", // a CRLF line: strict, as the core is
        // not a paragraph of its own: the line before or after it is text, so it may be part of another construct
        "Notes\n" ++ I ++ "\n", // after text
        I ++ "\nNotes\n", // before text
        "`open\n" ++ I ++ "\n`\n", // inside a code span over three lines
        "text <a title=\"`\"> `open\n" ++ I ++ "\n`\n", // inside a code span after an HTML attribute holding a backtick
        "<http://x/`> `open\n" ++ I ++ "\n`\n", // inside a code span after an autolink holding a backtick
        "`open\n---\n" ++ I ++ "\n`\n", // after a setext underline: outside code, but not a paragraph of its own
        "`open\n***\n" ++ I ++ "\n`\n", // after a thematic break: the same
        "```\nx\n```\n" ++ I ++ "\n", // right after a closed fence
        I ++ "\n---\n", // a setext heading's text
        // inside a fenced code block
        "```\n\n" ++ I ++ "\n\n```\n",
        "  ```md\n\n" ++ I ++ "\n\n```\n", // an indented fence with a language
        "~~~\n\n" ++ I ++ "\n\n~~~\n", // a tilde fence
        "````\n```\n\n" ++ I ++ "\n\n````\n", // a shorter fence inside a longer one does not close it
        "~~~\n```\n\n" ++ I ++ "\n\n~~~\n", // nor does a fence of the other character
        "```\n\n" ++ I ++ "\n", // a fence never closed
        "```\n```example\n\n" ++ I ++ "\n\n```\n", // a backtick line with text after it does not close a fence
        "~~~\n~~~ end\n\n" ++ I ++ "\n\n~~~\n", // nor does a tilde line
        "```\n```\t`\n\n" ++ I ++ "\n\n```\n", // nor a backtick after the closer's spaces
        // inside an HTML comment
        "<!--\n\n" ++ I ++ "\n\n-->\n",
        "   <!-- a note\n\n" ++ I ++ "\n", // indented, never closed
        "<!--\n-- not the end\n\n" ++ I ++ "\n\n-->\n", // `--` alone does not close it
    };
    for (missing) |c| try expectFindings(small_agents, small_core, s, c, &.{no_import});
    const present = [_][]const u8{
        I ++ "\n",
        I, // no newline
        "# CLAUDE.md\n\n" ++ I ++ "\n\nThe repository's own notes.\n", // among other paragraphs
        "Notes\n \t\n" ++ I ++ "\n", // a line of spaces and a tab is blank
        "```\nan example\n```\n\n" ++ I ++ "\n", // after a closed fence
        "~~~\nan example\n~~~~\n\n" ++ I ++ "\n", // after a tilde fence closed by a longer one
        "```\nx\n```  \t\n\n" ++ I ++ "\n", // after a closer followed by spaces and a tab
        "~~~\nx\n  ~~~~ \n\n" ++ I ++ "\n", // after an indented, longer tilde closer with a space
        "```example```\n\n" ++ I ++ "\n", // a backtick line whose text holds a backtick opens no fence (it is a code span)
        "~~~ a `b`\n~~~\n\n" ++ I ++ "\n", // a tilde fence may have backticks in its text
        "``\n\n" ++ I ++ "\n", // two backticks are no fence
        "    ```\n\n" ++ I ++ "\n", // four spaces of indent are no fence
        "`open\n\n" ++ I ++ "\n\n`\n", // a span cannot reach past a blank line
        "text <a title=\"`\"> `open\n\n" ++ I ++ "\n", // nor after an HTML attribute
        "`open\n---\n\n" ++ I ++ "\n\n`\n", // after a setext heading
        "`open\n***\n\n" ++ I ++ "\n", // after a thematic break
        "- a list item\n\n" ++ I ++ "\n", // an unindented line after a blank line ends the list
        "> a quote\n\n" ++ I ++ "\n", // and the block quote
        "<!-- a note -->\n\n" ++ I ++ "\n", // after a comment closed on its line
        "<!--\na note\n-->\n\n" ++ I ++ "\n", // after a comment closed on a later line
        "    <!--\n\n" ++ I ++ "\n", // four spaces of indent are no comment
        "Text <!--\n\n" ++ I ++ "\n", // nor is `<!--` after text
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
        no_import,
    });
}

test "a doubled end marker, or the whole core twice, is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    try expectFindings(try edit(a, small_agents, "## Repo\n", "## Repo\n" ++ ac.end_marker ++ "\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 2 times, not once",
    });
    const twice = small_agents ++ ac.begin_marker ++ "\n" ++ small_core ++ ac.end_marker ++ "\n";
    try expectFindings(twice, small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 2 times, not once",
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 2 times, not once",
    });
}

test "markers that cannot delimit the core still let the hash and the import be checked" {
    // no begin marker, a hash file that is no sha256sum line, no import
    try expectFindings(small_core ++ ac.end_marker ++ "\n", small_core, "", "", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
        "tests/agents/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): ``",
        no_import,
    });
    // the end before the begin, another digest, the import only inside a fence
    const swapped = "# AGENTS.md\n" ++ ac.end_marker ++ "\n" ++ small_core ++ ac.begin_marker ++ "\n";
    try expectFindings(swapped, small_core, "0" ** 64 ++ "  shared_core.md\n", "```\n@AGENTS.md\n```\n", &.{
        "AGENTS.md:2: the end of the shared core comes before its begin (line 7)",
        "tests/agents/shared_core.sha256 names 0000000000000000000000000000000000000000000000000000000000000000, but tests/agents/shared_core.md hashes to " ++ small_core_digest ++ ": the canonical core changed",
        no_import,
    });
}

/// The sha256 of `small_core`, written out so a finding that names it is compared to fixed text.
const small_core_digest = "f812642f680c11b65958bcdf3e2b34fc2ccc2068622ab1bd4add9ae499d740dd";

test "small_core_digest is the digest of small_core" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    try t.expectEqualStrings(small_core_digest, s[0..64]);
}

/// The paths `load` reads, and a repository root holding them (a scratch directory of the test, never the current directory).
const files = [_][]const u8{ "AGENTS.md", "tests/agents/shared_core.md", "tests/agents/shared_core.sha256", "CLAUDE.md" };

fn scratchRepo(a: std.mem.Allocator, dir: std.fs.Dir) !void {
    try dir.makePath("tests/agents");
    const texts = [_][]const u8{ small_agents, small_core, try sumsOf(a, small_core), "@AGENTS.md\n" };
    for (files, texts) |p, x| try dir.writeFile(p, x);
}

test "the four files load from an explicit root, whatever the current directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try scratchRepo(a, tmp.dir);
    const x = try ac.load(a, tmp.dir);
    try t.expectEqualStrings(small_agents, x.agents);
    try t.expectEqualStrings(small_core, x.copy);
    try t.expectEqualStrings("@AGENTS.md\n", x.claude);
    try expectFindings(x.agents, x.copy, x.sums, x.claude, &.{});
}

test "a missing file, or a directory where a file belongs, fails the load" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (files) |gone| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try scratchRepo(a, tmp.dir);
        try tmp.dir.deleteFile(gone);
        try t.expectError(error.FileNotFound, ac.load(a, tmp.dir));
        try tmp.dir.makeDir(gone);
        try t.expectError(error.IsDir, ac.load(a, tmp.dir));
    }
}

test "a file of max_bytes loads, and one byte more fails the load" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try scratchRepo(a, tmp.dir);
    // CLAUDE.md: the import, then a paragraph of `x` up to the limit
    const big = try a.alloc(u8, ac.max_bytes);
    @memset(big, 'x');
    @memcpy(big[0..12], "@AGENTS.md\n\n");
    try tmp.dir.writeFile("CLAUDE.md", big);
    const x = try ac.load(a, tmp.dir);
    try expectFindings(x.agents, x.copy, x.sums, x.claude, &.{});
    try tmp.dir.writeFile("CLAUDE.md", try std.mem.concat(a, u8, &.{ big, "x" }));
    try t.expectError(error.FileTooBig, ac.load(a, tmp.dir));
}
