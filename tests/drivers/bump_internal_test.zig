//! //:bump_internal: `cut_release bump-internal` (tools/bump_internal.zig), the step that opens the pull request
//! moving the internal repository's `mopm` submodule to a release, against a fake `gh` (fake_gh.zig) and a fake
//! `git` (fake_git.zig) whose state is a directory. Nothing here reaches GitHub, clones anything or opens a pull
//! request.
//!
//! The internal repository admits such a pull request only through its bump guard: author the release bot,
//! exactly one changed path (the submodule's gitlink), branch bump/<submodule>-v<semver>, the new commit
//! descends from the old, the tag v<semver> names the new commit. The good scenario checks every one of those
//! on the calls the tool made, then each test plants one defect (a mutant) and requires a refusal for that
//! reason with no push and no pull request, so a refusal is the defect's doing. The fakes log their arguments:
//! the token must be in no argument, only in the environment.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const sha = "0123456789abcdef0123456789abcdef01234567";
const old = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const other = "fedcba9876543210fedcba9876543210fedcba98";
const token = "ghs_SECRETINSTALLATIONTOKEN";
const bot = "komira-release-bot[bot] <345322945+komira-release-bot[bot]@users.noreply.github.com>";
const internal = "komira-ai/komira-internal";
const branch = "bump/mopm-v1.2.3";

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

    fn run(w: World, args: []const []const u8) !h.Ran {
        const a = w.a;
        var env = try h.environ(a);
        try env.put("FAKE_GH_DIR", w.root);
        try env.put("FAKE_GIT_DIR", w.root);
        if (w.token.len != 0) try env.put("GH_TOKEN", w.token) else env.remove("GH_TOKEN");
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ w.tools.cut, "--gh", w.tools.gh, "--git", w.tools.git, "--repo", "komira-ai/mopm", "bump-internal" });
        try argv.appendSlice(args);
        return h.run(a, argv.items, &env, .{});
    }

    /// The good arguments, except the ones in `over` (flag, value pairs) which replace theirs.
    fn runWith(w: World, over: []const [2][]const u8) !h.Ran {
        const keys = [_][]const u8{ "--version", "--sha", "--internal-repo", "--submodule", "--workdir" };
        const vals = [_][]const u8{ "1.2.3", sha, internal, "mopm", w.path("wd") };
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

/// A scenario: the tag v1.2.3 names `sha`; the internal repository holds `old` as its mopm gitlink, which
/// `sha` is ahead of; no pull request, no branch.
fn fresh(a: Allocator, tools: Tools, tmp: *std.testing.TmpDir, name: []const u8) !World {
    const root = try h.join(a, &.{ try h.tmpPath(a, tmp), name });
    try std.fs.cwd().makePath(root);
    const w = World{ .a = a, .tools = tools, .root = root };
    try w.put("tags", "v1.2.3 " ++ sha ++ "\n");
    try w.put("git_ls_tree", "160000 commit " ++ old ++ "\tmopm\n");
    try w.put("compare_tag_" ++ old, "ahead\n");
    return w;
}

/// Nothing was pushed, opened or closed.
fn untouched(w: World) bool {
    return w.pushed() == 0 and w.created() == 0 and w.count("log", "pr close ") == 0 and w.count("log", "pr merge ") == 0;
}

fn b64(a: Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(s.len));
    return enc.encode(buf, s);
}

test "bump-internal: the pull request the bump guard admits, and every planted defect refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = Tools{
        .cut = try h.toolPath(a, "MOPM_CUT_RELEASE"),
        .gh = try h.toolPath(a, "MOPM_FAKE_GH"),
        .git = try h.toolPath(a, "MOPM_FAKE_GIT"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};

    // ---- the good run: what the guard looks at, on the calls the tool made -------------------------
    {
        const w = try fresh(a, tools, &tmp, "good");
        const r = try w.go();
        rep.check("good: exits 0 and says it opened the pull request", r.code == 0 and h.contains(r.text, "opened https://github.com/komira-ai/komira-internal/pull/100 with auto-merge"), r.text);
        rep.check("good: the branch is bump/mopm-v1.2.3, pushed once, as a plain refspec (no force, no +)", w.pushed() == 1 and std.mem.eql(u8, std.mem.trim(u8, w.read("pushed"), "\n"), "HEAD:refs/heads/" ++ branch) and w.countHas("git_log", "--force") == 0 and w.countHas("git_log", " -f ") == 0 and w.countHas("git_log", "+HEAD") == 0, w.read("git_log"));
        rep.check("good: the gitlink is set with update-index --cacheinfo 160000,<sha>,mopm", std.mem.eql(u8, w.read("index_entry"), "160000," ++ sha ++ ",mopm"), w.read("index_entry"));
        rep.check("good: a shallow clone, no submodule is initialised", w.count("git_log", "clone ") == 1 and w.countHas("git_log", "--depth 1") == 1 and w.countHas("git_log", "submodule update") == 0 and w.countHas("git_log", "submodule init") == 0 and w.countHas("git_log", "--recurse") == 0 and w.countHas("git_log", "--no-checkout") == 0, w.read("git_log"));
        rep.check("good: the staged change is checked before the commit, the commit is checked before the push", w.countHas("git_log", "diff --cached --raw -z") == 1 and w.countHas("git_log", "ls-tree HEAD -- mopm") == 2, w.read("git_log"));
        rep.check("good: the commit message is 'chore(mopm): bump to v1.2.3' with the release url in the body", h.contains(w.read("commit"), "chore(mopm): bump to v1.2.3\n---\n") and h.contains(w.read("commit"), "Release: https://github.com/komira-ai/mopm/releases/tag/v1.2.3"), w.read("commit"));
        const env_log = w.read("git_env");
        var commit_line: []const u8 = "";
        var env_lines = std.mem.splitScalar(u8, env_log, '\n');
        while (env_lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "commit ")) commit_line = l;
        }
        rep.check("good: the commit is authored and committed by the bot user (the id of the bot USER in the noreply address)", h.contains(commit_line, "AUTHOR=" ++ bot) and h.contains(commit_line, "COMMITTER=" ++ bot), commit_line);
        rep.check("good: the token reaches git as an HTTP header in the environment, and GH_TOKEN does not", w.countHas("git_env", "GH_TOKEN=(unset)") == w.count("git_env", "") - 1 and w.count("git_env", "") > 3 and w.countHas("git_env", try h.fmt(a, "HEADER=AUTHORIZATION: basic {s} ", .{try b64(a, "x-access-token:" ++ token)})) == w.count("git_env", "") - 1, env_log);
        rep.check("good: the token is in no argument of gh or git", w.countHas("log", token) == 0 and w.countHas("git_log", token) == 0 and w.countHas("log", try b64(a, "x-access-token:" ++ token)) == 0 and w.countHas("git_log", try b64(a, "x-access-token:" ++ token)) == 0 and w.count("log", "") > 5, w.read("log"));
        rep.check("good: the tag of the released repository is checked against the commit first", w.count("log", "api repos/komira-ai/mopm/commits/v1.2.3 ") == 1, w.read("log"));
        rep.check("good: the old gitlink is checked to be an ancestor (compare says ahead)", w.count("log", "api repos/komira-ai/mopm/compare/" ++ old ++ "..." ++ sha) == 1, w.read("log"));
        rep.check("good: gh pr create names the base main, the branch and the title", w.countHas("log", "pr create -R " ++ internal ++ " --base main --head " ++ branch ++ " --title chore(mopm): bump to v1.2.3 --body ") == 1, w.read("log"));
        rep.check("good: auto-merge is enabled with --auto --merge, then checked", w.countHas("log", "pr merge https://github.com/komira-ai/komira-internal/pull/100 -R " ++ internal ++ " --auto --merge") == 1 and w.count("log", "pr view ") == 1, w.read("log"));
        rep.check("good: every pr call names the internal repository", w.count("log", "pr ") == w.countHas("log", "-R " ++ internal) and w.count("log", "pr ") == 4, w.read("log"));
        rep.check("good: the pull request is open with auto-merge on, and no other is touched", std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), w.read("prs"));

        // Idempotent: the same run again does nothing.
        const again = try w.go();
        rep.check("idempotent: a second run finds the open pull request and does nothing", again.code == 0 and h.contains(again.text, "nothing to open") and w.count("git_log", "clone ") == 1 and w.created() == 1 and w.pushed() == 1 and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), again.text);
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
            rep.check(try h.fmt(a, "exists ({s}): a bump for this or a newer version exists, nothing is cloned, pushed or opened", .{c.name}), r.code == 0 and h.contains(r.text, "nothing to open") and untouched(w) and w.count("git_log", "clone ") == 0 and std.mem.eql(u8, w.read("prs"), c.prs), r.text);
        }
    }
    {
        const w = try fresh(a, tools, &tmp, "open_without_auto");
        try w.put("prs", "90 OPEN " ++ branch ++ " 0\n");
        const r = try w.go();
        rep.check("exists: an open pull request for this version without auto-merge gets it, and no second is opened", r.code == 0 and std.mem.eql(u8, w.read("prs"), "90 OPEN " ++ branch ++ " 1\n") and w.created() == 0 and w.count("git_log", "clone ") == 0 and w.countHas("log", "pr merge 90 -R " ++ internal ++ " --auto --merge") == 1, r.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "older_open");
        try w.put("prs", "80 OPEN bump/mopm-v1.2.2 1\n81 OPEN bump/mopm-v1.1.9 0\n");
        const r = try w.go();
        const prs = w.read("prs");
        rep.check("older: an older open bump is closed in favour of the new one, which is open with auto-merge", r.code == 0 and h.contains(prs, "80 CLOSED bump/mopm-v1.2.2 1\n") and h.contains(prs, "81 CLOSED bump/mopm-v1.1.9 0\n") and h.contains(prs, "102 OPEN " ++ branch ++ " 1\n"), prs);
        rep.check("older: the new pull request is open and enabled before the old is closed, and the note names the new one", w.countHas("log", "pr close 80 -R " ++ internal ++ " --comment Superseded by https://github.com/komira-ai/komira-internal/pull/102. --delete-branch") == 1, w.read("log"));
        const log = w.read("log");
        const merge_at = std.mem.indexOf(u8, log, "pr merge ") orelse 0;
        const close_at = std.mem.indexOf(u8, log, "pr close ") orelse 0;
        rep.check("older: the older ones are closed last", merge_at != 0 and close_at > merge_at, log);
    }
    {
        const w = try fresh(a, tools, &tmp, "unrelated_prs");
        try w.put("prs", "70 MERGED bump/mopm-v1.2.2 1\n60 CLOSED " ++ branch ++ " 0\n50 OPEN bump/komira-v9.9.9 0\n51 OPEN feature/x 0\n52 OPEN bump/mopm-vnot-a-version 0\n");
        const r = try w.go();
        const prs = w.read("prs");
        rep.check("unrelated: merged, closed-unmerged, other-submodule and non-bump pull requests are neither a reason to stop nor closed", r.code == 0 and h.contains(prs, "70 MERGED") and h.contains(prs, "60 CLOSED") and h.contains(prs, "50 OPEN bump/komira-v9.9.9 0") and h.contains(prs, "51 OPEN feature/x 0") and h.contains(prs, "52 OPEN bump/mopm-vnot-a-version 0") and h.contains(prs, "105 OPEN " ++ branch ++ " 1") and w.count("log", "pr close ") == 0, prs);
    }
    {
        // A run that pushed the branch and stopped (before the pull request) is finished by the next run.
        var w = try fresh(a, tools, &tmp, "branch_exists");
        try w.put("branches", branch ++ "\n");
        try w.put("branch_gitlink", sha ++ "\n");
        const r = try w.go();
        rep.check("retry: a pushed branch without a pull request is reused: no clone, no push, the pull request opened", r.code == 0 and w.count("git_log", "clone ") == 0 and w.pushed() == 0 and w.created() == 1 and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n"), r.text);
        w = try fresh(a, tools, &tmp, "branch_wrong");
        try w.put("branches", branch ++ "\n");
        try w.put("branch_gitlink", other ++ "\n");
        const bad = try w.go();
        rep.check("retry: a branch of that name that holds another commit is refused, not reused", bad.code == 1 and h.contains(bad.text, "not " ++ sha) and untouched(w), bad.text);
    }

    // ---- planted defects: each is refused, for its reason, before anything is pushed or opened -----
    {
        var w = try fresh(a, tools, &tmp, "tag_elsewhere");
        try w.put("tags", "v1.2.3 " ++ other ++ "\n");
        const r = try w.go();
        rep.check("mutant: the tag names another commit (the guard's tag_elsewhere) is refused before the clone", r.code == 1 and h.contains(r.text, "the tag v1.2.3 of komira-ai/mopm names " ++ other) and untouched(w) and w.count("git_log", "clone ") == 0, r.text);
        w = try fresh(a, tools, &tmp, "no_tag");
        try w.put("tags", "v1.2.2 " ++ sha ++ "\n");
        const n = try w.go();
        rep.check("mutant: there is no tag (the guard's not_tagged) is refused before the clone", n.code == 1 and h.contains(n.text, "gh api failed") and untouched(w) and w.count("git_log", "clone ") == 0, n.text);
    }
    {
        const bad = [_]struct { name: []const u8, diff: []const u8, why: []const u8 }{
            .{ .name = "two_paths", .diff = ":160000 160000 x y M\x00mopm\x00:100644 100644 x y M\x00README.md\x00", .why = "more than one changed path" },
            .{ .name = "other_path", .diff = ":160000 160000 x y M\x00komira\x00", .why = "a different submodule" },
            .{ .name = "gitmodules", .diff = ":100644 100644 x y M\x00.gitmodules\x00", .why = ".gitmodules" },
            .{ .name = "file_not_gitlink", .diff = ":100644 100644 x y M\x00mopm\x00", .why = "a file" },
            .{ .name = "mode_changed", .diff = ":160000 100644 x y M\x00mopm\x00", .why = "a gitlink turned file" },
            .{ .name = "deleted", .diff = ":160000 000000 x y D\x00mopm\x00", .why = "deleted" },
            .{ .name = "rename", .diff = ":160000 160000 x y R100\x00mopm\x00other\x00", .why = "a rename" },
            .{ .name = "nothing", .diff = "", .why = "no change" },
        };
        for (bad) |c| {
            const w = try fresh(a, tools, &tmp, c.name);
            try w.put("git_diff", c.diff);
            const r = try w.go();
            rep.check(try h.fmt(a, "mutant: the staged change is {s} is refused before the commit", .{c.why}), r.code == 1 and h.contains(r.text, "not exactly one modified gitlink at mopm") and !w.has("commit") and untouched(w), r.text);
        }
    }
    {
        var w = try fresh(a, tools, &tmp, "not_a_gitlink");
        try w.put("git_ls_tree", "100644 blob " ++ old ++ "\tmopm\n");
        const r = try w.go();
        rep.check("mutant: mopm is a file in the internal repository (not_a_gitlink) is refused before it is staged", r.code == 1 and h.contains(r.text, "is not a gitlink") and !w.has("index_entry") and untouched(w), r.text);
        w = try fresh(a, tools, &tmp, "not_in_tree");
        try w.put("git_ls_tree", "");
        const e = try w.go();
        rep.check("mutant: mopm is not in the internal repository at all is refused", e.code == 1 and h.contains(e.text, "the path is not in the repository") and untouched(w), e.text);
        for ([_][]const u8{ "behind", "diverged" }) |status| {
            w = try fresh(a, tools, &tmp, status);
            try w.put("compare_tag_" ++ old, status);
            const b = try w.go();
            rep.check(try h.fmt(a, "mutant: --sha is {s} the old gitlink (not_descendant) is refused, nothing staged", .{status}), b.code == 1 and h.contains(b.text, try h.fmt(a, "compare says '{s}'", .{status})) and !w.has("index_entry") and untouched(w), b.text);
        }
        w = try fresh(a, tools, &tmp, "already_there");
        try w.put("git_ls_tree", "160000 commit " ++ sha ++ "\tmopm\n");
        const same = try w.go();
        rep.check("the submodule is already at --sha: nothing to open, nothing staged, no empty commit", same.code == 0 and h.contains(same.text, "is already at") and !w.has("index_entry") and !w.has("commit") and untouched(w), same.text);
        w = try fresh(a, tools, &tmp, "commit_wrong");
        try w.put("commit_wrong", "");
        const cw = try w.go();
        rep.check("mutant: the commit holds another gitlink than the one staged is refused before the push", cw.code == 1 and h.contains(cw.text, "after the commit the gitlink of mopm is not") and untouched(w), cw.text);
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
        w = try fresh(a, tools, &tmp, "create_fail");
        try w.put("create_fail", "");
        const cr = try w.go();
        rep.check("failure: a pull request that cannot be created is red", cr.code == 1 and h.contains(cr.text, "gh pr failed") and !w.has("prs"), cr.text);
        w = try fresh(a, tools, &tmp, "merge_fail");
        try w.put("merge_fail", "");
        const mf = try w.go();
        rep.check("failure: auto-merge that cannot be enabled is red (the pull request stays open, the next run turns it on)", mf.code == 1 and h.contains(mf.text, "gh pr failed") and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 0\n"), mf.text);
        try std.fs.cwd().deleteFile(w.path("merge_fail"));
        const retry = try w.go();
        rep.check("failure: ... and the retry finds that pull request and enables auto-merge, opening no second", retry.code == 0 and std.mem.eql(u8, w.read("prs"), "100 OPEN " ++ branch ++ " 1\n") and w.created() == 1, retry.text);
        w = try fresh(a, tools, &tmp, "auto_noop");
        try w.put("auto_noop", "");
        const an = try w.go();
        rep.check("mutant: a merge call that leaves auto-merge off is caught by the check", an.code == 1 and h.contains(an.text, "auto-merge is not on"), an.text);
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
            .{ .flag = "--sha", .value = "0123456", .said = "--sha" },
            .{ .flag = "--sha", .value = "0123456789ABCDEF0123456789ABCDEF01234567", .said = "--sha" },
            .{ .flag = "--submodule", .value = "../mopm", .said = "--submodule" },
            .{ .flag = "--submodule", .value = "a/b", .said = "--submodule" },
            .{ .flag = "--submodule", .value = "", .said = "--submodule" },
            .{ .flag = "--internal-repo", .value = "komira-internal", .said = "--internal-repo" },
            .{ .flag = "--internal-repo", .value = "a/b/c", .said = "--internal-repo" },
        };
        for (bad) |c| {
            const r = try w0.runWith(&.{.{ c.flag, c.value }});
            rep.check(try h.fmt(a, "input: {s} '{s}' is refused before any gh or git call", .{ c.flag, c.value }), r.code == 1 and h.contains(r.text, c.said) and !w0.has("log") and !w0.has("git_log"), r.text);
        }
        var w = w0;
        w.token = "";
        const nt = try w.go();
        rep.check("input: no GH_TOKEN is refused before any gh or git call", nt.code == 1 and h.contains(nt.text, "GH_TOKEN is not set") and !w.has("log") and !w.has("git_log"), nt.text);
    }
    {
        // The guard against the token in an argument is live: a token that is a substring of an argument is refused.
        var w = try fresh(a, tools, &tmp, "token_in_argv");
        w.token = "komira-internal";
        const r = try w.go();
        rep.check("mutant: a token that appears in an argument is refused before the command runs", r.code == 1 and h.contains(r.text, "with the token in its arguments") and !w.has("git_log") and untouched(w), r.text);
    }
    {
        const w = try fresh(a, tools, &tmp, "workdir_busy");
        try w.put("wd/leftover", "x");
        const r = try w.go();
        rep.check("mutant: the work directory is not empty is refused before the clone", r.code == 1 and h.contains(r.text, "is not empty") and w.count("git_log", "clone ") == 0 and untouched(w), r.text);
    }
    try rep.finish();
}
