//! //:tap: `cut_release tap` (tools/tap.zig), the stage that opens the Homebrew tap's pull request for a release,
//! against a fake `gh` (fake_gh.zig) and a fake `git` (fake_git.zig) whose state is a directory. Nothing here
//! reaches GitHub, clones anything or opens a pull request.
//!
//! The tap admits such a pull request only through its path guard: author the release bot, branch
//! bump/<formula>-v<semver>, exactly one changed path (Formula/<formula>.rb), the whole file the renderer's output,
//! the version higher than the formula on main, the tag v<semver> existing. The good scenario checks each of those
//! on the calls the tool made; then each test plants one defect (a mutant) and requires a refusal for that reason
//! with no push and no pull request, so a refusal is the defect's doing. The formula used is the golden formula
//! (tests/channels/golden/mopm.rb): the default render, which is the tap guard's fixture plus its version line.
//!
//! What it proves that a green run of the good scenario alone would not:
//!   - monotonic: a tap that is ahead (numerically: 1.2.10 is above 1.2.3) is refused with no write; a tap at the
//!     same version is a no-op; an older tap is moved up;
//!   - idempotent: a second run finds the open pull request and opens nothing; a pushed branch without a pull
//!     request is finished, not recreated or re-pushed; an open pull request without auto-merge gets it asked for;
//!   - older open bump pull requests are closed, last, after the new one is open, and no push is ever forced;
//!   - GitHub refusing auto-merge (a tap with no required checks) leaves the pull request open and the run GREEN
//!     with a notice, and a later run turns auto-merge on;
//!   - the staged change must be exactly the one formula path, added or modified, or nothing is committed.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const token = "ghs_SECRETINSTALLATIONTOKEN";
const bot = "komira-release-bot[bot] <345322945+komira-release-bot[bot]@users.noreply.github.com>";
const tap = "komira-ai/homebrew-tap";
const branch = "bump/mopm-v1.2.3";
const sha = "0123456789abcdef0123456789abcdef01234567";
const pr_url = "https://github.com/komira-ai/homebrew-tap/pull/";

const Tools = struct { cut: []const u8, gh: []const u8, git: []const u8 };

const World = struct {
    a: Allocator,
    tools: Tools,
    root: []const u8,
    token: []const u8 = token,

    fn path(w: World, name: []const u8) []const u8 {
        return h.join(w.a, &.{ w.root, name }) catch @panic("oom");
    }

    fn put(w: World, name: []const u8, data: []const u8) !void {
        try h.writeFile(w.path(name), data);
    }

    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(w.path(name), .{}) catch return false;
        return true;
    }

    fn read(w: World, name: []const u8) []const u8 {
        return h.readFile(w.a, w.path(name)) catch "";
    }

    /// Lines of the file `name` that start with `prefix`.
    fn count(w: World, name: []const u8, prefix: []const u8) usize {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, w.read(name), '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, prefix)) n += 1;
        }
        return n;
    }

    /// Lines of `name` that contain `needle`.
    fn countHas(w: World, name: []const u8, needle: []const u8) usize {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, w.read(name), '\n');
        while (lines.next()) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) n += 1;
        }
        return n;
    }

    fn pushed(w: World) usize {
        return w.count("pushed", "HEAD:");
    }

    fn created(w: World) usize {
        return w.count("log", "pr create ");
    }

    fn cloned(w: World) usize {
        return w.count("git_log", "clone ");
    }

    fn run(w: World, args: []const []const u8) !h.Ran {
        const a = w.a;
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        try env.put("FAKE_GIT_DIR", w.root);
        if (w.token.len != 0) try env.put("GH_TOKEN", w.token) else env.remove("GH_TOKEN");
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ w.tools.cut, "--gh", w.tools.gh, "--git", w.tools.git, "--repo", "komira-ai/mopm", "tap" });
        try argv.appendSlice(args);
        return h.run(a, argv.items, &env, .{});
    }

    /// The good arguments, except the ones in `over` (flag, value pairs) which replace theirs.
    fn runWith(w: World, over: []const [2][]const u8) !h.Ran {
        const keys = [_][]const u8{ "--version", "--formula-file", "--tap-repo", "--formula", "--workdir" };
        const vals = [_][]const u8{ "1.2.3", w.path("mopm.rb"), tap, "mopm", w.path("wd") };
        var argv = std.ArrayList([]const u8).init(w.a);
        for (keys, vals) |k, v| {
            var val = v;
            for (over) |o| {
                if (std.mem.eql(u8, o[0], k)) val = o[1];
            }
            try argv.appendSlice(&.{ k, val });
        }
        return w.run(argv.items);
    }

    fn go(w: World) !h.Ran {
        return w.runWith(&.{});
    }
};

/// The formula of 1.2.3 as `channels formula` renders it (the golden file: the default render, with its version line).
fn formula(a: Allocator) ![]const u8 {
    return h.readFile(a, "tests/channels/golden/mopm.rb");
}

/// The same formula at another version (every `1.2.3`: the version line and the urls).
fn formulaAt(a: Allocator, version: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, try formula(a), "1.2.3", version);
}

/// A scenario: the tag v1.2.3 exists; the tap has no formula yet, no pull request, no branch; the file to open is
/// the formula of 1.2.3.
fn fresh(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8) !World {
    const root = try h.join(a, &.{ try h.tmpPath(a, tmp), name });
    try std.fs.cwd().makePath(root);
    const w = World{ .a = a, .tools = tools, .root = root };
    try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
    try w.put("mopm.rb", try formula(a));
    return w;
}

/// Nothing was pushed, opened, merged or closed.
fn untouched(w: World) bool {
    return w.pushed() == 0 and w.created() == 0 and w.count("log", "pr close ") == 0 and w.count("log", "pr merge ") == 0;
}

fn b64(a: Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(s.len));
    return enc.encode(buf, s);
}

test "tap: the pull request the tap's guard admits, and every planted defect refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.watchdog(300);
    const tools = Tools{
        .cut = try h.toolPath(a, "MOPM_CUT_RELEASE"),
        .gh = try h.toolPath(a, "MOPM_FAKE_GH"),
        .git = try h.toolPath(a, "MOPM_FAKE_GIT"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};
    const golden = try formula(a);

    // ---- the good run: what the guard looks at, on the calls the tool made -------------------------
    {
        const w = try fresh(a, tools, &tmp, "good");
        const r = try w.go();
        rep.check("good: exits 0 and says it opened the pull request with auto-merge on", r.code == 0 and h.contains(r.text, "opened " ++ pr_url ++ "100: mopm v1.2.3") and h.contains(r.text, "auto-merge (squash) is on for " ++ pr_url ++ "100"), r.text);
        rep.check("good: the branch is bump/mopm-v1.2.3, pushed once, as a plain refspec (no force, no +)", w.pushed() == 1 and std.mem.eql(u8, std.mem.trim(u8, w.read("pushed"), "\n"), "HEAD:refs/heads/" ++ branch) and w.countHas("git_log", "--force") == 0 and w.countHas("git_log", " -f ") == 0 and w.countHas("git_log", "+HEAD") == 0, w.read("git_log"));
        rep.same("good: the file in the clone is the rendered formula, byte for byte", golden, h.readFile(a, w.path("wd/Formula/mopm.rb")) catch "");
        rep.check("good: a shallow clone of the tap's main, then add of the one path, the staged change checked, the commit", w.cloned() == 1 and w.countHas("git_log", "--depth 1") == 1 and w.countHas("git_log", "--branch main https://github.com/" ++ tap ++ ".git") == 1 and w.countHas("git_log", "add -- Formula/mopm.rb") == 1 and w.countHas("git_log", "diff --cached --raw -z") == 1 and w.countHas("git_log", "commit.gpgsign=false") == 1, w.read("git_log"));
        rep.check("good: the staged change is checked before the commit, the commit before the push", blk: {
            const log = w.read("git_log");
            const add_at = std.mem.indexOf(u8, log, " add -- ") orelse 0;
            const diff_at = std.mem.indexOf(u8, log, " diff --cached") orelse 0;
            const commit_at = std.mem.indexOf(u8, log, " commit ") orelse 0;
            const push_at = std.mem.indexOf(u8, log, " push ") orelse 0;
            break :blk add_at != 0 and diff_at > add_at and commit_at > diff_at and push_at > commit_at;
        }, w.read("git_log"));
        rep.check("good: the commit is 'mopm 1.2.3' and its body says the only change is Formula/mopm.rb", h.contains(w.read("commit"), "mopm 1.2.3\n---\n") and h.contains(w.read("commit"), "The only change is Formula/mopm.rb.") and h.contains(w.read("commit"), "Release: https://github.com/komira-ai/mopm/releases/tag/v1.2.3"), w.read("commit"));
        var commit_line: []const u8 = "";
        var env_lines = std.mem.splitScalar(u8, w.read("git_env"), '\n');
        while (env_lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "commit ")) commit_line = l;
        }
        rep.check("good: the commit is authored and committed by the bot user", h.contains(commit_line, "AUTHOR=" ++ bot) and h.contains(commit_line, "COMMITTER=" ++ bot), commit_line);
        rep.check("good: the token reaches git as an HTTP header in the environment, and GH_TOKEN does not", w.countHas("git_env", "GH_TOKEN=(unset)") == w.count("git_env", "") - 1 and w.count("git_env", "") > 3 and w.countHas("git_env", try h.fmt(a, "HEADER=AUTHORIZATION: basic {s} ", .{try b64(a, "x-access-token:" ++ token)})) == w.count("git_env", "") - 1, w.read("git_env"));
        rep.check("good: the token is in no argument of gh or git", w.countHas("log", token) == 0 and w.countHas("git_log", token) == 0 and w.countHas("log", try b64(a, "x-access-token:" ++ token)) == 0 and w.countHas("git_log", try b64(a, "x-access-token:" ++ token)) == 0 and w.count("log", "") > 4, w.read("log"));
        rep.check("good: the tag of the released repository is checked first", w.count("log", "api repos/komira-ai/mopm/commits/v1.2.3 ") == 1 and std.mem.startsWith(u8, w.read("log"), "api repos/komira-ai/mopm/commits/v1.2.3 "), w.read("log"));
        rep.check("good: the formula on the tap's main is read for the monotonic check", w.countHas("log", "api -H Accept: application/vnd.github.raw+json repos/" ++ tap ++ "/contents/Formula/mopm.rb?ref=main") == 1, w.read("log"));
        rep.check("good: gh pr create names the tap, the base main, the branch and the title", w.countHas("log", "pr create -R " ++ tap ++ " --base main --head " ++ branch ++ " --title mopm 1.2.3 --body ") == 1, w.read("log"));
        rep.check("good: auto-merge is asked for with --auto --squash (never --merge or --admin), then checked", w.countHas("log", "pr merge " ++ pr_url ++ "100 -R " ++ tap ++ " --auto --squash") == 1 and w.countHas("log", "--admin") == 0 and w.countHas("log", "--merge") == 0 and w.count("log", "pr view ") == 1, w.read("log"));
        rep.check("good: every pr call names the tap", w.count("log", "pr ") == w.countHas("log", "-R " ++ tap) and w.count("log", "pr ") == 4, w.read("log"));
        rep.check("good: the pull request is open with auto-merge on, and no other is touched", std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), w.read("prs"));

        // Idempotent: the same run again does nothing.
        const again = try w.go();
        rep.check("idempotent: a second run finds the open pull request and does nothing", again.code == 0 and h.contains(again.text, "nothing to open") and w.cloned() == 1 and w.created() == 1 and w.pushed() == 1 and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), again.text);
    }

    // ---- monotonic: against the formula on the tap's main --------------------------------------------
    {
        const ahead = [_][]const u8{ "1.2.4", "1.3.0", "2.0.0", "1.2.10", "1.10.0" };
        for (ahead) |v| {
            const w = try fresh(a, tools, &tmp, try h.fmt(a, "tap_ahead_{s}", .{v}));
            try w.put("tap_main_formula", try formulaAt(a, v));
            const r = try w.go();
            rep.check(try h.fmt(a, "monotonic: a tap at v{s} (above 1.2.3, numerically) refuses v1.2.3, nothing cloned, pushed or opened", .{v}), r.code == 1 and h.contains(r.text, "a tap never moves down") and untouched(w) and w.cloned() == 0, r.text);
        }
        var w = try fresh(a, tools, &tmp, "tap_same");
        try w.put("tap_main_formula", golden);
        const same = try w.go();
        rep.check("monotonic: a tap already at v1.2.3 is a no-op: exit 0, nothing cloned, pushed or opened", same.code == 0 and h.contains(same.text, "is already at v1.2.3: nothing to open") and untouched(w) and w.cloned() == 0, same.text);
        w = try fresh(a, tools, &tmp, "tap_older");
        try w.put("tap_main_formula", try formulaAt(a, "1.2.2"));
        const older = try w.go();
        rep.check("monotonic: a tap at v1.2.2 is moved up to v1.2.3", older.code == 0 and w.created() == 1 and w.pushed() == 1, older.text);
        w = try fresh(a, tools, &tmp, "tap_two_versions");
        try w.put("tap_main_formula", try std.mem.concat(a, u8, &.{ try formulaAt(a, "1.2.2"), "  version \"9.9.9\"\n" }));
        const two = try w.go();
        rep.check("mutant: a formula on the tap with two version lines is refused (fail closed), as the guard does", two.code == 1 and h.contains(two.text, "declares 2 version lines") and untouched(w), two.text);
        w = try fresh(a, tools, &tmp, "tap_prerelease");
        try w.put("tap_main_formula", try formulaAt(a, "1.2.2-rc.1"));
        const pre = try w.go();
        rep.check("mutant: a formula on the tap whose version is not <major>.<minor>.<patch> is refused", pre.code == 1 and h.contains(pre.text, "which is not <major>.<minor>.<patch>") and untouched(w), pre.text);
        w = try fresh(a, tools, &tmp, "tap_unreadable");
        try w.put("tap_read_error", "");
        const unread = try w.go();
        rep.check("failure: a tap that cannot be read (HTTP 500, not 404) is red, not treated as empty", unread.code == 1 and h.contains(unread.text, "cannot read Formula/mopm.rb at main") and untouched(w) and w.cloned() == 0, unread.text);
    }

    // ---- idempotence and ordering against the pull requests that exist -----------------------------
    {
        const cases = [_]struct { name: []const u8, prs: []const u8 }{
            .{ .name = "merged_same", .prs = "90 MERGED bump/mopm-v1.2.3 1\n" },
            .{ .name = "merged_newer", .prs = "90 MERGED bump/mopm-v1.2.4 1\n" },
            .{ .name = "open_newer", .prs = "90 OPEN bump/mopm-v1.3.0 1\n" },
            // Numeric: 1.10.0 is newer than 1.2.3 (a string comparison puts it below).
            .{ .name = "open_numeric_newer", .prs = "90 OPEN bump/mopm-v1.10.0 1\n" },
            .{ .name = "open_numeric_patch", .prs = "90 OPEN bump/mopm-v1.2.10 0\n" },
        };
        for (cases) |c| {
            const w = try fresh(a, tools, &tmp, c.name);
            try w.put("prs", c.prs);
            const r = try w.go();
            rep.check(try h.fmt(a, "exists ({s}): a bump for this or a newer version exists, nothing is cloned, pushed or opened", .{c.name}), r.code == 0 and h.contains(r.text, "nothing to open") and untouched(w) and w.cloned() == 0 and std.mem.eql(u8, w.read("prs"), c.prs), r.text);
        }
    }
    {
        const w = try fresh(a, tools, &tmp, "open_without_auto");
        try w.put("prs", "90 OPEN " ++ branch ++ " 0\n");
        const r = try w.go();
        rep.check("exists: an open pull request for this version without auto-merge gets it asked for, and no second is opened", r.code == 0 and std.mem.eql(u8, w.read("prs"), "90 OPEN " ++ branch ++ " 1\n") and w.created() == 0 and w.cloned() == 0 and w.countHas("log", "pr merge " ++ pr_url ++ "90 -R " ++ tap ++ " --auto --squash") == 1 and w.pushed() == 0, r.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "older_open");
        try w.put("prs", "80 OPEN bump/mopm-v1.2.2 1\n81 OPEN bump/mopm-v1.1.9 0\n");
        const r = try w.go();
        const prs = w.read("prs");
        rep.check("older: an older open bump is closed in favour of the new one, which is open with auto-merge", r.code == 0 and h.contains(prs, "80 CLOSED bump/mopm-v1.2.2 1\n") and h.contains(prs, "81 CLOSED bump/mopm-v1.1.9 0\n") and h.contains(prs, "102 OPEN " ++ branch ++ " 1\n"), prs);
        rep.check("older: the note names the new pull request, and the branch of the old one goes with it", w.countHas("log", "pr close 80 -R " ++ tap ++ " --comment Superseded by " ++ pr_url ++ "102. --delete-branch") == 1, w.read("log"));
        const log = w.read("log");
        const merge_at = std.mem.indexOf(u8, log, "pr merge ") orelse 0;
        const close_at = std.mem.indexOf(u8, log, "pr close ") orelse 0;
        rep.check("older: the older ones are closed last, after the new one is open and auto-merge is asked for", merge_at != 0 and close_at > merge_at, log);
        rep.check("older: closing an old bump pushes nothing to it (one push, of the new branch only; never forced)", w.pushed() == 1 and w.countHas("git_log", "--force") == 0 and w.countHas("git_log", "+HEAD") == 0, w.read("git_log"));
    }
    {
        const w = try fresh(a, tools, &tmp, "unrelated_prs");
        try w.put("prs", "70 MERGED bump/mopm-v1.2.2 1\n60 CLOSED " ++ branch ++ " 0\n50 OPEN bump/buildrules-v9.9.9 0\n51 OPEN feature/x 0\n52 OPEN bump/mopm-vnot-a-version 0\n");
        const r = try w.go();
        const prs = w.read("prs");
        rep.check("unrelated: merged-older, closed-unmerged, other-formula and non-bump pull requests are neither a reason to stop nor closed", r.code == 0 and h.contains(prs, "70 MERGED") and h.contains(prs, "60 CLOSED") and h.contains(prs, "50 OPEN bump/buildrules-v9.9.9 0") and h.contains(prs, "51 OPEN feature/x 0") and h.contains(prs, "52 OPEN bump/mopm-vnot-a-version 0") and h.contains(prs, "105 OPEN " ++ branch ++ " 1") and w.count("log", "pr close ") == 0, prs);
    }
    {
        // A run that pushed the branch and stopped (before the pull request) is finished by the next run.
        var w = try fresh(a, tools, &tmp, "branch_exists");
        try w.put("tap_branch_formula", golden);
        const r = try w.go();
        rep.check("retry: a pushed branch without a pull request is reused: no clone, no push, the pull request opened", r.code == 0 and w.cloned() == 0 and w.pushed() == 0 and w.created() == 1 and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), r.text);
        w = try fresh(a, tools, &tmp, "branch_wrong");
        try w.put("tap_branch_formula", try std.mem.concat(a, u8, &.{ golden, "# extra\n" }));
        const bad = try w.go();
        rep.check("retry: a branch of that name that holds another formula is refused, not reused", bad.code == 1 and h.contains(bad.text, "another Formula/mopm.rb than this release's") and untouched(w), bad.text);
    }

    // ---- GitHub refuses auto-merge: the pull request stays open and the run stays green ---------------
    {
        const refusals = [_][]const u8{ "merge_clean", "merge_fail" };
        for (refusals) |file| {
            const w = try fresh(a, tools, &tmp, file);
            try w.put(file, "");
            try w.put("prs", "80 OPEN bump/mopm-v1.2.2 1\n");
            const r = try w.go();
            rep.check(try h.fmt(a, "no required checks ({s}): exit 0, the pull request is open without auto-merge, a notice says to merge it by hand", .{file}), r.code == 0 and std.mem.eql(u8, w.read("prs"), "80 CLOSED bump/mopm-v1.2.2 1\n101 OPEN " ++ branch ++ " 0\n") and h.contains(r.text, "::notice title=The tap pull request is open without auto-merge::" ++ pr_url ++ "101 stays open") and h.contains(r.text, "squash-merge it by hand"), r.text);
            rep.check(try h.fmt(a, "no required checks ({s}): the notice carries GitHub's own words", .{file}), h.contains(r.text, if (std.mem.eql(u8, file, "merge_clean")) "Pull request is in clean status" else "auto-merge cannot be enabled"), r.text);
            rep.check(try h.fmt(a, "no required checks ({s}): the branch was pushed once, and the older pull request is still superseded", .{file}), w.pushed() == 1 and w.created() == 1 and w.countHas("log", "pr close 80 ") == 1, w.read("log"));
            try std.fs.cwd().deleteFile(w.path(file));
            const again = try w.go();
            rep.check(try h.fmt(a, "no required checks ({s}): once the tap requires checks, a re-run asks again for the open pull request and opens no second", .{file}), again.code == 0 and std.mem.indexOf(u8, w.read("prs"), "101 OPEN " ++ branch ++ " 1\n") != null and w.created() == 1 and w.pushed() == 1 and w.cloned() == 1 and h.contains(again.text, "auto-merge (squash) is on"), again.text);
        }
        const w = try fresh(a, tools, &tmp, "auto_noop");
        try w.put("auto_noop", "");
        const an = try w.go();
        rep.check("no required checks: a merge call that succeeds but leaves auto-merge off is a notice, not a failure", an.code == 0 and h.contains(an.text, "auto-merge is not on; squash-merge it by hand") and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 0\n"), an.text);
    }

    // ---- planted defects: each is refused, for its reason, before anything is pushed or opened -----
    {
        var w = try fresh(a, tools, &tmp, "no_tag");
        try w.put("tags", "v1.2.2 " ++ sha ++ "\n");
        const n = try w.go();
        rep.check("mutant: there is no tag v1.2.3 in the released repository (the guard's tag rule) is refused before the clone", n.code == 1 and h.contains(n.text, "gh api failed") and untouched(w) and w.cloned() == 0, n.text);

        const bad = [_]struct { name: []const u8, diff: []const u8, why: []const u8 }{
            .{ .name = "other_path", .diff = ":000000 100644 x y A\x00Formula/buildrules.rb\x00", .why = "another formula" },
            .{ .name = "readme", .diff = ":100644 100644 x y M\x00README.md\x00", .why = "README.md" },
            .{ .name = "workflow", .diff = ":000000 100644 x y A\x00.github/workflows/x.yml\x00", .why = "a workflow" },
            .{ .name = "executable", .diff = ":000000 100755 x y A\x00Formula/mopm.rb\x00", .why = "an executable file" },
            .{ .name = "symlink", .diff = ":000000 120000 x y A\x00Formula/mopm.rb\x00", .why = "a symlink" },
            .{ .name = "deleted", .diff = ":100644 000000 x y D\x00Formula/mopm.rb\x00", .why = "a deletion" },
            .{ .name = "rename", .diff = ":100644 100644 x y R100\x00Formula/old.rb\x00Formula/mopm.rb\x00", .why = "a rename" },
            .{ .name = "nothing", .diff = "", .why = "no change" },
        };
        for (bad) |c| {
            w = try fresh(a, tools, &tmp, c.name);
            try w.put("git_diff", c.diff);
            const r = try w.go();
            rep.check(try h.fmt(a, "mutant: the staged change is {s} is refused before the commit", .{c.why}), r.code == 1 and h.contains(r.text, "not exactly one added or modified file at Formula/mopm.rb") and !w.has("commit") and untouched(w), r.text);
        }
        w = try fresh(a, tools, &tmp, "add_extra");
        try w.put("add_extra", "");
        const ex = try w.go();
        rep.check("mutant: git stages a second path beside the formula is refused before the commit", ex.code == 1 and h.contains(ex.text, "not exactly one added or modified file") and !w.has("commit") and untouched(w), ex.text);
        w = try fresh(a, tools, &tmp, "add_noop");
        try w.put("add_noop", "");
        const nop = try w.go();
        rep.check("mutant: nothing is staged (the clone already holds these bytes) is refused, no empty commit", nop.code == 1 and h.contains(nop.text, "not exactly one added or modified file") and !w.has("commit") and untouched(w), nop.text);
    }
    {
        var w = try fresh(a, tools, &tmp, "clone_fail");
        try w.put("clone_fail", "");
        const c = try w.go();
        rep.check("failure: a clone that fails is red, nothing pushed or opened", c.code == 1 and h.contains(c.text, "git clone failed") and untouched(w), c.text);
        w = try fresh(a, tools, &tmp, "push_fail");
        try w.put("push_fail", "");
        const p = try w.go();
        rep.check("failure: a push that fails is red and no pull request is opened", p.code == 1 and h.contains(p.text, "git push failed") and w.created() == 0, p.text);
        w = try fresh(a, tools, &tmp, "commit_fail");
        try w.put("commit_fail", "");
        const cm = try w.go();
        rep.check("failure: a commit that fails is red, nothing pushed", cm.code == 1 and h.contains(cm.text, "git commit failed") and untouched(w), cm.text);
        w = try fresh(a, tools, &tmp, "create_fail");
        try w.put("create_fail", "");
        const cr = try w.go();
        rep.check("failure: a pull request that cannot be created is red (unlike a refused auto-merge)", cr.code == 1 and h.contains(cr.text, "gh pr failed") and !w.has("prs"), cr.text);
        w = try fresh(a, tools, &tmp, "close_fail");
        try w.put("prs", "80 OPEN bump/mopm-v1.2.2 1\n");
        try w.put("close_fail", "");
        const cf = try w.go();
        rep.check("failure: an older bump that cannot be closed is red", cf.code == 1 and h.contains(cf.text, "gh pr failed"), cf.text);
    }
    {
        // Inputs the tool refuses before it runs gh or git at all.
        const w0 = try fresh(a, tools, &tmp, "inputs");
        const bad = [_]struct { flag: []const u8, value: []const u8, said: []const u8 }{
            .{ .flag = "--version", .value = "v1.2.3", .said = "--version" },
            .{ .flag = "--version", .value = "1.2", .said = "--version" },
            .{ .flag = "--version", .value = "1.2.3-rc.1", .said = "--version" },
            .{ .flag = "--version", .value = "1.02.3", .said = "--version" },
            .{ .flag = "--formula", .value = "../mopm", .said = "--formula" },
            .{ .flag = "--formula", .value = "a/b", .said = "--formula" },
            .{ .flag = "--formula", .value = "", .said = "--formula" },
            .{ .flag = "--tap-repo", .value = "homebrew-tap", .said = "--tap-repo" },
            .{ .flag = "--tap-repo", .value = "a/b/c", .said = "--tap-repo" },
            .{ .flag = "--formula-file", .value = "/nonexistent/mopm.rb", .said = "cannot read --formula-file" },
            // The file is a formula, but of another version than --version.
            .{ .flag = "--version", .value = "1.2.4", .said = "it is not the formula of v1.2.4" },
        };
        for (bad) |c| {
            const r = try w0.runWith(&.{.{ c.flag, c.value }});
            rep.check(try h.fmt(a, "input: {s} '{s}' is refused before any gh or git call", .{ c.flag, c.value }), r.code == 1 and h.contains(r.text, c.said) and !w0.has("log") and !w0.has("git_log"), r.text);
        }
        var w = try fresh(a, tools, &tmp, "inputs_formula");
        try w.put("mopm.rb", try std.mem.replaceOwned(u8, a, golden, "komira-ai/mopm/releases", "someone/mopm/releases"));
        const other = try w.go();
        rep.check("input: a formula whose urls point into another repository's releases is refused before any gh or git call", other.code == 1 and h.contains(other.text, "is not under https://github.com/komira-ai/mopm/releases/download/v1.2.3/") and !w.has("log"), other.text);
        w = try fresh(a, tools, &tmp, "inputs_two_versions");
        try w.put("mopm.rb", try std.mem.concat(a, u8, &.{ golden, "  version \"1.2.3\"\n" }));
        const dup = try w.go();
        rep.check("input: a formula with two version lines is refused before any gh or git call", dup.code == 1 and h.contains(dup.text, "does not declare exactly one version line") and !w.has("log"), dup.text);
        w = try fresh(a, tools, &tmp, "inputs_no_url");
        try w.put("mopm.rb", "class Mopm < Formula\n  version \"1.2.3\"\nend\n");
        const nourl = try w.go();
        rep.check("input: a formula with no url line is refused before any gh or git call", nourl.code == 1 and h.contains(nourl.text, "has no url line") and !w.has("log"), nourl.text);
        w = w0;
        w.token = "";
        const nt = try w.go();
        rep.check("input: no GH_TOKEN is refused before any gh or git call", nt.code == 1 and h.contains(nt.text, "GH_TOKEN is not set") and !w.has("log") and !w.has("git_log"), nt.text);
    }
    {
        // The guard against the token in an argument is live: a token that is a substring of an argument is refused.
        var w = try fresh(a, tools, &tmp, "token_in_argv");
        w.token = "homebrew-tap";
        const r = try w.go();
        rep.check("mutant: a token that appears in an argument is refused before the command runs", r.code == 1 and h.contains(r.text, "with the token in its arguments") and !w.has("git_log") and untouched(w), r.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "workdir_busy");
        try w.put("wd/leftover", "x");
        const r = try w.go();
        rep.check("mutant: the work directory is not empty is refused before the clone", r.code == 1 and h.contains(r.text, "is not empty") and w.cloned() == 0 and untouched(w), r.text);
    }
    try rep.finish();
}
