//! `cut_release bump-internal`: the last step of a mopm release. After `publish`, open a pull request in the
//! internal repository that moves its `mopm` submodule to the released commit, and turn auto-merge on.
//! Zig only, standard library only; imported by tools/cut_release.zig (which parses the flags).
//!
//!     cut_release --repo komira-ai/mopm bump-internal --version 1.2.3 --sha <commit> \
//!         --internal-repo komira-ai/komira-internal --submodule mopm --workdir <empty dir>
//!
//! The internal repository admits such a pull request only through its bump guard, which accepts the pull
//! request of the release bot when ALL of these hold: exactly one changed path, the submodule's gitlink; the
//! branch is `bump/<submodule>-v<semver>`; the new commit descends from the old; the tag `v<semver>` of the
//! released repository names the new commit. This tool produces exactly that, and refuses (before it writes
//! anything) whatever the guard would refuse, so a mistake is red here and not a stuck pull request.
//!
//! Steps, every one a `gh` or `git` call with no shell:
//!   1. the tag v<version> of --repo names --sha (the guard's last rule);
//!   2. `gh pr list` of the internal repository: an open or merged bump pull request for this or a NEWER
//!      version means there is nothing to open (an open one for this version without auto-merge gets it);
//!   3. when the branch bump/<submodule>-v<version> already exists (an earlier run stopped after its push),
//!      its gitlink must be --sha and it is reused; otherwise a shallow clone (no submodule is initialised),
//!      the gitlink set with `git update-index --cacheinfo 160000,<sha>,<submodule>` (no submodule checkout),
//!      a check that the staged change is that one gitlink and nothing else, the commit, and a push of the
//!      branch (never forced);
//!   4. `gh pr create`, then `gh pr merge --auto --merge`, then a check that auto-merge is on;
//!   5. every older open bump pull request is closed in favour of the new one.
//! The old gitlink must be an ancestor of --sha (GitHub's compare says ahead): the tool never moves the
//! submodule backwards. A run for a version that is already the gitlink does nothing.
//!
//! The token is the environment variable GH_TOKEN (the App installation token of the release bot). `gh` reads
//! it from there. `git` gets it as an HTTP header through GIT_CONFIG_* in its environment (and GH_TOKEN is
//! removed from git's environment). It is never an argument of any process, and the tool refuses to run a
//! command whose arguments contain it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The identity of the commit: the bot's login, and the noreply address GitHub gives a bot user,
/// `<user id>+<login>@users.noreply.github.com`. The id is the id of the bot USER
/// (`gh api /users/komira-release-bot%5Bbot%5D --jq .id`), not the id of the App.
pub const bot_name = "komira-release-bot[bot]";
pub const bot_email = "345322945+komira-release-bot[bot]@users.noreply.github.com";

pub const Options = struct {
    gh: []const u8 = "gh",
    git: []const u8 = "git",
    /// The released repository: its tag names the commit.
    repo: []const u8,
    internal_repo: []const u8,
    submodule: []const u8,
    version: []const u8,
    sha: []const u8,
    /// Where the clone goes: it must not exist or be empty.
    workdir: []const u8,
    base: []const u8 = "main",
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cut_release bump-internal: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn out(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch {};
}

// ---- names ------------------------------------------------------------------------------

fn canonical(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 9) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
    }
    if (s.len > 1 and s[0] == '0') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// <major>.<minor>.<patch>, plain numbers: the version of a stable release.
fn parseSemver(s: []const u8) ?[3]u64 {
    var parts = std.mem.splitScalar(u8, s, '.');
    var v: [3]u64 = undefined;
    for (&v) |*slot| slot.* = canonical(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return v;
}

fn order(x: [3]u64, y: [3]u64) std.math.Order {
    for (x, y) |p, q| {
        if (p != q) return std.math.order(p, q);
    }
    return .eq;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// A repository or submodule name part: letters, digits, `.`, `_`, `-`; not starting with `.`.
fn namePart(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn ownerName(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    return namePart(s[0..slash]) and namePart(s[slash + 1 ..]);
}

// ---- running gh and git ----------------------------------------------------------------

const Ran = struct { ok: bool, stdout: []u8, stderr: []u8 };

const Tool = struct {
    a: Allocator,
    gh: []const u8,
    git: []const u8,
    token: []const u8,
    /// The environment of git: no GH_TOKEN, the token as an HTTP header, the bot as author and committer.
    git_env: std.process.EnvMap,

    /// Refuses a command whose arguments hold the token: the token is world-readable in argv.
    fn noToken(t: Tool, exe: []const u8, args: []const []const u8) void {
        if (std.mem.indexOf(u8, exe, t.token) != null) die("refusing to run a command with the token in its name", .{});
        for (args) |x| {
            if (std.mem.indexOf(u8, x, t.token) != null) die("refusing to run {s} with the token in its arguments (the token goes in the environment only)", .{std.fs.path.basename(exe)});
        }
    }

    fn exec(t: Tool, exe: []const u8, args: []const []const u8, env: ?*const std.process.EnvMap) Ran {
        t.noToken(exe, args);
        var argv = std.ArrayList([]const u8).init(t.a);
        argv.append(exe) catch @panic("oom");
        argv.appendSlice(args) catch @panic("oom");
        const r = std.process.Child.run(.{ .allocator = t.a, .argv = argv.items, .env_map = env, .max_output_bytes = 1 << 22 }) catch |err| {
            die("could not run {s}: {s}", .{ exe, @errorName(err) });
        };
        return .{ .ok = r.term == .Exited and r.term.Exited == 0, .stdout = r.stdout, .stderr = r.stderr };
    }

    fn gh_(t: Tool, args: []const []const u8) Ran {
        return t.exec(t.gh, args, null);
    }

    fn git_(t: Tool, args: []const []const u8) Ran {
        return t.exec(t.git, args, &t.git_env);
    }

    /// Standard output of a gh call that must succeed, trimmed.
    fn ghMust(t: Tool, args: []const []const u8) []const u8 {
        const r = t.gh_(args);
        if (!r.ok) die("gh {s} failed: {s}", .{ args[0], std.mem.trim(u8, r.stderr, " \r\n") });
        return std.mem.trim(u8, r.stdout, " \r\n");
    }

    fn gitMust(t: Tool, args: []const []const u8) []const u8 {
        const r = t.git_(args);
        if (!r.ok) die("git {s} failed: {s}", .{ firstNonFlag(args), std.mem.trim(u8, r.stderr, " \r\n") });
        return r.stdout;
    }
};

fn firstNonFlag(args: []const []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-C") or std.mem.eql(u8, args[i], "-c")) {
            i += 1;
            continue;
        }
        return args[i];
    }
    return "?";
}

fn pf(a: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch @panic("oom");
}

fn buildGitEnv(a: Allocator, token: []const u8) std.process.EnvMap {
    var env = std.process.getEnvMap(a) catch @panic("oom");
    env.remove("GH_TOKEN");
    env.remove("GITHUB_TOKEN");
    const cred = pf(a, "x-access-token:{s}", .{token});
    const enc = std.base64.standard.Encoder;
    const buf = a.alloc(u8, enc.calcSize(cred.len)) catch @panic("oom");
    const b64 = enc.encode(buf, cred);
    env.put("GIT_CONFIG_COUNT", "1") catch @panic("oom");
    env.put("GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader") catch @panic("oom");
    env.put("GIT_CONFIG_VALUE_0", pf(a, "AUTHORIZATION: basic {s}", .{b64})) catch @panic("oom");
    env.put("GIT_TERMINAL_PROMPT", "0") catch @panic("oom");
    env.put("GIT_ALLOW_PROTOCOL", "https") catch @panic("oom");
    env.put("GIT_AUTHOR_NAME", bot_name) catch @panic("oom");
    env.put("GIT_AUTHOR_EMAIL", bot_email) catch @panic("oom");
    env.put("GIT_COMMITTER_NAME", bot_name) catch @panic("oom");
    env.put("GIT_COMMITTER_EMAIL", bot_email) catch @panic("oom");
    return env;
}

// ---- the pull requests of the internal repository ---------------------------------------

const Pr = struct {
    number: u64 = 0,
    state: []const u8 = "",
    headRefName: []const u8 = "",
    url: []const u8 = "",
    autoMergeRequest: ?std.json.Value = null,
};

fn listPrs(t: Tool, o: Options) []const Pr {
    const json = t.ghMust(&.{ "pr", "list", "-R", o.internal_repo, "--state", "all", "--limit", "500", "--json", "number,state,headRefName,url,autoMergeRequest" });
    const parsed = std.json.parseFromSlice([]const Pr, t.a, json, .{ .ignore_unknown_fields = true }) catch |err| {
        die("cannot read the pull request list: {s}", .{@errorName(err)});
    };
    return parsed.value;
}

/// The version a bump branch `bump/<submodule>-v<semver>` names, or null for any other branch.
fn branchVersion(a: Allocator, submodule: []const u8, head: []const u8) ?[3]u64 {
    const want = pf(a, "bump/{s}-v", .{submodule});
    if (!std.mem.startsWith(u8, head, want)) return null;
    return parseSemver(head[want.len..]);
}

fn enableAutoMerge(t: Tool, o: Options, pr: []const u8) void {
    _ = t.ghMust(&.{ "pr", "merge", pr, "-R", o.internal_repo, "--auto", "--merge" });
    const on = t.ghMust(&.{ "pr", "view", pr, "-R", o.internal_repo, "--json", "autoMergeRequest", "--jq", ".autoMergeRequest != null" });
    if (!std.mem.eql(u8, on, "true")) die("auto-merge is not on for {s} after `gh pr merge --auto --merge`", .{pr});
}

// ---- the bump ---------------------------------------------------------------------------

pub fn run(a: Allocator, o: Options) void {
    const mine = parseSemver(o.version) orelse die("--version '{s}' is not <major>.<minor>.<patch> (plain numbers, no leading v)", .{o.version});
    if (!isHex40(o.sha)) die("--sha '{s}' is not a 40-character lowercase commit sha", .{o.sha});
    if (!ownerName(o.repo)) die("--repo '{s}' is not owner/name", .{o.repo});
    if (!ownerName(o.internal_repo)) die("--internal-repo '{s}' is not owner/name", .{o.internal_repo});
    if (!namePart(o.submodule)) die("--submodule '{s}' is not a submodule name", .{o.submodule});
    const token = std.process.getEnvVarOwned(a, "GH_TOKEN") catch die("GH_TOKEN is not set (the App installation token of the release bot)", .{});
    if (token.len == 0) die("GH_TOKEN is empty", .{});

    const t = Tool{ .a = a, .gh = o.gh, .git = o.git, .token = token, .git_env = buildGitEnv(a, token) };
    const tag = pf(a, "v{s}", .{o.version});
    const branch = pf(a, "bump/{s}-v{s}", .{ o.submodule, o.version });
    const title = pf(a, "chore({s}): bump to v{s}", .{ o.submodule, o.version });

    // 1. The guard's last rule, checked first: the tag names the commit.
    const tagged = t.ghMust(&.{ "api", pf(a, "repos/{s}/commits/{s}", .{ o.repo, tag }), "--jq", ".sha" });
    if (!std.mem.eql(u8, tagged, o.sha)) die("the tag {s} of {s} names {s}, not {s}: the guard would refuse this bump", .{ tag, o.repo, tagged, o.sha });

    // 2. Is there a bump for this or a newer version already?
    const prs = listPrs(t, o);
    var covered: ?Pr = null;
    var older = std.ArrayList(Pr).init(a);
    for (prs) |p| {
        const v = branchVersion(a, o.submodule, p.headRefName) orelse continue;
        const open = std.mem.eql(u8, p.state, "OPEN");
        const merged = std.mem.eql(u8, p.state, "MERGED");
        if (!open and !merged) continue;
        switch (order(v, mine)) {
            .lt => if (open) older.append(p) catch @panic("oom"),
            else => {
                if (covered == null or (open and std.mem.eql(u8, covered.?.state, "MERGED"))) covered = p;
            },
        }
    }

    var opened: []const u8 = "";
    if (covered) |p| {
        opened = p.url;
        const same = order(branchVersion(a, o.submodule, p.headRefName).?, mine) == .eq;
        if (same and std.mem.eql(u8, p.state, "OPEN") and p.autoMergeRequest == null) {
            enableAutoMerge(t, o, pf(a, "{d}", .{p.number}));
            out("the bump pull request {s} for v{s} was open without auto-merge: turned it on.\n", .{ p.url, o.version });
        } else {
            out("a bump pull request for v{s} or newer exists ({s}, {s}): nothing to open.\n", .{ o.version, p.url, p.state });
        }
    } else if (branchGitlink(t, o, branch)) |held| {
        // 3a. An earlier run pushed the branch and stopped: reuse it if it is the right commit.
        if (!std.mem.eql(u8, held, o.sha)) die("the branch {s} exists in {s} with {s} at {s}, not {s}; delete the branch by hand", .{ branch, o.internal_repo, o.submodule, held, o.sha });
        opened = openPr(t, o, branch, title, tag);
    } else {
        // 3b. Build the commit and push the branch.
        if (!pushBump(t, o, branch, title, tag)) {
            out("{s} is already at {s}: nothing to open.\n", .{ o.submodule, o.sha });
        } else opened = openPr(t, o, branch, title, tag);
    }

    // 5. Older open bumps are superseded.
    for (older.items) |p| {
        const note = if (opened.len != 0) pf(a, "Superseded by {s}.", .{opened}) else pf(a, "Superseded by the bump to v{s}.", .{o.version});
        _ = t.ghMust(&.{ "pr", "close", pf(a, "{d}", .{p.number}), "-R", o.internal_repo, "--comment", note, "--delete-branch" });
        out("closed {s} (older than v{s}).\n", .{ p.url, o.version });
    }
}

/// The commit of the submodule's gitlink on `branch` of the internal repository, or null when the branch
/// does not exist.
fn branchGitlink(t: Tool, o: Options, branch: []const u8) ?[]const u8 {
    const a = t.a;
    const r = t.gh_(&.{ "api", pf(a, "repos/{s}/git/ref/heads/{s}", .{ o.internal_repo, branch }), "--jq", ".object.sha" });
    if (!r.ok) {
        if (std.mem.indexOf(u8, r.stderr, "404") != null or std.mem.indexOf(u8, r.stderr, "Not Found") != null) return null;
        die("cannot look for the branch {s}: {s}", .{ branch, std.mem.trim(u8, r.stderr, " \r\n") });
    }
    return t.ghMust(&.{ "api", pf(a, "repos/{s}/contents/{s}?ref={s}", .{ o.internal_repo, o.submodule, branch }), "--jq", ".sha" });
}

/// Clones, sets the gitlink, commits and pushes the branch. False when the gitlink is already --sha.
fn pushBump(t: Tool, o: Options, branch: []const u8, title: []const u8, tag: []const u8) bool {
    const a = t.a;
    // The clone goes into a directory this run made.
    std.fs.cwd().makePath(o.workdir) catch |err| die("cannot make {s}: {s}", .{ o.workdir, @errorName(err) });
    {
        var d = std.fs.cwd().openDir(o.workdir, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ o.workdir, @errorName(err) });
        defer d.close();
        var it = d.iterate();
        if (it.next() catch null) |_| die("{s} is not empty; give an empty directory", .{o.workdir});
    }
    const url = pf(a, "https://github.com/{s}.git", .{o.internal_repo});
    // No submodule is initialised: `clone` without --recurse-submodules leaves the gitlink as it is.
    _ = t.gitMust(&.{ "clone", "--quiet", "--depth", "1", "--no-tags", "--single-branch", "--branch", o.base, url, o.workdir });

    // The old gitlink: mode 160000, type commit, exactly the submodule's path.
    const old = gitlinkAt(t, o);
    if (std.mem.eql(u8, old, o.sha)) return false;
    // Forward only (the guard's rule): --sha descends from the old commit.
    const status = t.ghMust(&.{ "api", pf(a, "repos/{s}/compare/{s}...{s}", .{ o.repo, old, o.sha }), "--jq", ".status" });
    if (!std.mem.eql(u8, status, "ahead")) die("{s} is not ahead of {s} in {s} (compare says '{s}'): the bump would move {s} backwards or sideways", .{ o.sha, old, o.repo, status, o.submodule });

    _ = t.gitMust(&.{ "-C", o.workdir, "update-index", "--cacheinfo", pf(a, "160000,{s},{s}", .{ o.sha, o.submodule }) });
    requireOneGitlink(t, o);

    const body = pf(a,
        \\Moves the `{s}` submodule to the commit of the release v{s} ({s}).
        \\
        \\Release: https://github.com/{s}/releases/tag/{s}
        \\
        \\Opened by the release pipeline of {s} after it published the release. Auto-merge fires when the required checks pass, among them the bump guard.
    , .{ o.submodule, o.version, o.sha, o.repo, tag, o.repo });
    _ = t.gitMust(&.{ "-C", o.workdir, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", title, "-m", body });
    if (!std.mem.eql(u8, gitlinkAt(t, o), o.sha)) die("after the commit the gitlink of {s} is not {s}", .{ o.submodule, o.sha });
    _ = t.gitMust(&.{ "-C", o.workdir, "push", "--quiet", "origin", pf(a, "HEAD:refs/heads/{s}", .{branch}) });
    return true;
}

/// The commit of the submodule's gitlink at HEAD of the clone.
fn gitlinkAt(t: Tool, o: Options) []const u8 {
    const text = t.gitMust(&.{ "-C", o.workdir, "ls-tree", "HEAD", "--", o.submodule });
    const line = std.mem.trim(u8, text, " \r\n");
    // <mode> SP <type> SP <sha> TAB <path>
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse die("git ls-tree HEAD {s} printed '{s}': the path is not in the repository", .{ o.submodule, line });
    if (!std.mem.eql(u8, line[tab + 1 ..], o.submodule)) die("git ls-tree printed the path '{s}', not {s}", .{ line[tab + 1 ..], o.submodule });
    var f = std.mem.splitScalar(u8, line[0..tab], ' ');
    const mode = f.next() orelse "";
    const kind = f.next() orelse "";
    const sha = f.next() orelse "";
    if (!std.mem.eql(u8, mode, "160000") or !std.mem.eql(u8, kind, "commit") or !isHex40(sha)) {
        die("{s} is not a gitlink in {s} ('{s}'): the guard would refuse a bump of it", .{ o.submodule, o.internal_repo, line });
    }
    return sha;
}

/// The staged change is exactly one path, the submodule's, a gitlink before and after, modified.
fn requireOneGitlink(t: Tool, o: Options) void {
    const raw = t.gitMust(&.{ "-C", o.workdir, "diff", "--cached", "--raw", "-z", "--no-renames", "--ignore-submodules=none", "HEAD" });
    var it = std.mem.splitScalar(u8, raw, 0);
    const meta = it.next() orelse "";
    const path = it.next() orelse "";
    const rest = it.next() orelse "";
    const more = it.next();
    // ":160000 160000 <old> <new> M" then the path, then nothing but the end of the output.
    const shape = std.mem.startsWith(u8, meta, ":160000 160000 ") and std.mem.endsWith(u8, meta, " M");
    if (meta.len == 0 or !shape or !std.mem.eql(u8, path, o.submodule) or rest.len != 0 or more != null) {
        die("the staged change is not exactly one modified gitlink at {s} (git diff says '{s}'): refusing to commit, the guard would refuse it", .{ o.submodule, std.mem.trim(u8, raw, "\x00\n") });
    }
}

/// Opens the pull request of `branch` and turns auto-merge on. Returns its url.
fn openPr(t: Tool, o: Options, branch: []const u8, title: []const u8, tag: []const u8) []const u8 {
    const a = t.a;
    const body = pf(a, "Moves the `{s}` submodule to release v{s}.\n\nRelease: https://github.com/{s}/releases/tag/{s}\n\nOpened by the release pipeline of {s}. Auto-merge fires when the required checks pass, among them the bump guard.", .{ o.submodule, o.version, o.repo, tag, o.repo });
    const made = t.ghMust(&.{ "pr", "create", "-R", o.internal_repo, "--base", o.base, "--head", branch, "--title", title, "--body", body });
    // The url is the last line of what `gh pr create` prints.
    const nl = std.mem.lastIndexOfScalar(u8, made, '\n');
    const url = if (nl) |i| made[i + 1 ..] else made;
    if (!std.mem.startsWith(u8, url, "https://")) die("gh pr create printed '{s}', not a pull request url", .{made});
    enableAutoMerge(t, o, url);
    out("opened {s} with auto-merge: {s} to v{s}.\n", .{ url, o.submodule, o.version });
    return url;
}
