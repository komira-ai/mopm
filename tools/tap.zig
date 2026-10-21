//! `cut_release tap`: the `tap` stage of a mopm release. After `publish`, open a pull request in the Homebrew tap
//! repository that adds or updates `Formula/<name>.rb` with the formula `channels formula` rendered from the
//! release's verified SHA256SUMS, and ask for auto-merge with squash. Zig only, standard library only; imported by
//! tools/cut_release.zig (which parses the flags). It shares its gh/git plumbing with tools/bump_internal.zig
//! (tools/ghtool.zig).
//!
//!     cut_release --repo komira-ai/mopm tap --version 1.2.3 --formula-file <rendered mopm.rb> \
//!         --tap-repo komira-ai/homebrew-tap --formula mopm --workdir <empty dir>
//!
//! The tap admits such a pull request only through its path guard (`.github/guard/guard.js` of the tap), which
//! accepts the pull request of the release bot when ALL of these hold: the branch is `bump/<formula>-v<semver>`;
//! exactly one changed path, `Formula/<formula>.rb`, added or modified; the whole file is the renderer's output for
//! that name and version (an exact line-for-line allow-list); the version is higher than the formula on the base;
//! the tag `v<semver>` exists in the released repository. This tool produces exactly that and refuses (before it
//! writes anything) what it can see the guard refusing, so a mistake is red here and not a stuck pull request.
//!
//! Steps, every one a `gh` or `git` call with no shell:
//!   1. the file is the formula of THIS version (the renderer writes no version line; the version is the one the release urls
//!      carry, as in the tap's guard: every url `/releases/download/v<V>/<name>-<V>-<target>.tar.gz`, all the same <V>), and
//!      the tag v<version> of --repo exists;
//!   2. monotonic: the formula on the tap's main branch is read, and its version is the one its release urls carry. A version above --version is refused (red: the
//!      tap must never move down). The same version means the tap already has this release: nothing to open;
//!   3. `gh pr list` of the tap: an open or merged bump pull request for this or a NEWER version means there is
//!      nothing to open (an open one for this version without auto-merge gets it asked for: idempotent);
//!   4. when the branch bump/<formula>-v<version> already exists (an earlier run stopped after its push), its
//!      formula must be these bytes and it is reused; otherwise a shallow clone, the file written, `git add` of that
//!      one path, a check that the staged change is that one path and nothing else, the commit, and a push of the
//!      branch (never forced);
//!   5. `gh pr create`, then `gh pr merge --auto --squash`. GitHub refuses to enable auto-merge on a pull request
//!      that has no required checks (and on a repository that does not allow it): that is NOT a failure of this
//!      step. The pull request stays open, a notice says so, and the tap's owner merges it by hand; once the tap
//!      requires checks, the next run's step 3 asks again for the open pull request;
//!   6. every older open bump pull request is closed in favour of the new one (never a force-push).
//!
//! The token is the environment variable GH_TOKEN (the App installation token of the release bot, for the tap
//! only), handled as in bump_internal.zig: in the environment, never an argument.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gt = @import("ghtool.zig");

const die = gt.die;
const out = gt.out;
const pf = gt.pf;
const Tool = gt.Tool;

pub const Options = struct {
    gh: []const u8 = "gh",
    git: []const u8 = "git",
    /// The released repository: its tag must exist, and the formula's urls point into its releases.
    repo: []const u8,
    tap_repo: []const u8,
    /// The formula's name: `mopm`, the file Formula/mopm.rb and the branch bump/mopm-v<version>.
    formula: []const u8,
    version: []const u8,
    /// The rendered formula (the output of `channels formula`).
    formula_file: []const u8,
    /// Where the clone goes: it must not exist or be empty.
    workdir: []const u8,
    base: []const u8 = "main",
};

/// The exact lines the guard reads a version from: `  version "X.Y.Z"`.
const version_prefix = "  version \"";

/// The versions a formula text declares, each of the form `  version "<text>"` (exactly the lines the guard reads).
fn declaredVersions(a: Allocator, text: []const u8) []const []const u8 {
    var found = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len <= version_prefix.len or !std.mem.startsWith(u8, l, version_prefix) or !std.mem.endsWith(u8, l, "\"")) continue;
        found.append(l[version_prefix.len .. l.len - 1]) catch @panic("oom");
    }
    return found.items;
}

pub fn run(a: Allocator, o: Options) void {
    gt.prefix = "cut_release tap";
    const mine = gt.parseSemver(o.version) orelse die("--version '{s}' is not <major>.<minor>.<patch> (plain numbers, no leading v)", .{o.version});
    if (!gt.ownerName(o.repo)) die("--repo '{s}' is not owner/name", .{o.repo});
    if (!gt.ownerName(o.tap_repo)) die("--tap-repo '{s}' is not owner/name", .{o.tap_repo});
    if (!gt.namePart(o.formula)) die("--formula '{s}' is not a formula name", .{o.formula});
    const text = std.fs.cwd().readFileAlloc(a, o.formula_file, 1 << 20) catch |err| die("cannot read --formula-file {s}: {s}", .{ o.formula_file, @errorName(err) });
    const tag = pf(a, "v{s}", .{o.version});
    requireFormulaOf(a, text, o);
    const t = Tool.init(a, o.gh, o.git);
    const branch = pf(a, "bump/{s}-v{s}", .{ o.formula, o.version });
    const path = pf(a, "Formula/{s}.rb", .{o.formula});
    const title = pf(a, "{s} {s}", .{ o.formula, o.version });

    // 1. The guard's last rule, checked first: the tag exists in the released repository.
    _ = t.ghMust(&.{ "api", pf(a, "repos/{s}/commits/{s}", .{ o.repo, tag }), "--jq", ".sha" });

    // 2. Monotonic: never open a pull request that would not move the tap up.
    if (formulaAt(t, o, path, o.base)) |live| {
        const have = liveVersion(a, live, o, path);
        const current = gt.parseSemver(have) orelse die("{s} on {s} of {s} has version '{s}', which is not <major>.<minor>.<patch>", .{ path, o.base, o.tap_repo, have });
        switch (gt.order(mine, current)) {
            .lt => die("refusing to open a pull request for v{s}: the tap already has v{s} (a tap never moves down)", .{ o.version, have }),
            .eq => return out("{s} on {s} of {s} is already at v{s}: nothing to open.\n", .{ path, o.base, o.tap_repo, o.version }),
            .gt => {},
        }
    }

    // 3. Is there a bump for this or a newer version already?
    const found = gt.classify(a, gt.listPrs(t, o.tap_repo), o.formula, mine);
    var opened: []const u8 = "";
    if (found.covered) |p| {
        opened = p.url;
        const same = gt.order(gt.branchVersion(a, o.formula, p.headRefName).?, mine) == .eq;
        if (same and std.mem.eql(u8, p.state, "OPEN")) {
            if (p.autoMergeRequest == null) askAutoMerge(t, o, p.url) else out("the pull request {s} for v{s} is open with auto-merge on: nothing to open.\n", .{ p.url, o.version });
        } else {
            out("a bump pull request for v{s} or newer exists ({s}, {s}): nothing to open.\n", .{ o.version, p.url, p.state });
        }
    } else if (formulaAt(t, o, path, branch)) |held| {
        // 4a. An earlier run pushed the branch and stopped: reuse it if it holds this formula.
        if (!std.mem.eql(u8, held, text)) die("the branch {s} exists in {s} with another {s} than this release's; delete the branch by hand", .{ branch, o.tap_repo, path });
        opened = openPr(t, o, branch, title, tag);
    } else {
        // 4b. Build the commit and push the branch.
        pushFormula(t, o, text, path, branch, title, tag);
        opened = openPr(t, o, branch, title, tag);
    }

    // 6. Older open bumps are superseded.
    gt.closeOlder(t, o.tap_repo, found.older, opened, o.version);
}

/// The version a formula's release urls carry, as the tap's guard reads it: every `url "` line is
/// `https://github.com/<repo>/releases/download/v<V>/<name>-<V>-<target>.tar.gz` with a plain <major>.<minor>.<patch>
/// <V> that is the same in the directory and the file name, and all urls carry the same <V>. Dies on the first url that
/// does not, or when there is no url. `where` names the formula in the message.
fn urlVersion(a: Allocator, text: []const u8, repo: []const u8, name: []const u8, where: []const u8) []const u8 {
    const head = pf(a, "https://github.com/{s}/releases/download/v", .{repo});
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const at = std.mem.indexOf(u8, l, "url \"") orelse continue;
        const shown = std.mem.trim(u8, l, " ");
        const rest = l[at + 5 ..];
        if (!std.mem.startsWith(u8, rest, head)) die("{s}: the url line '{s}' is not under {s}<X.Y.Z>/", .{ where, shown, head });
        const after = rest[head.len..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse die("{s}: the url line '{s}' is not under {s}<X.Y.Z>/", .{ where, shown, head });
        const v = after[0..slash];
        if (gt.parseSemver(v) == null) die("{s}: the url line '{s}' has version '{s}', which is not <major>.<minor>.<patch>", .{ where, shown, v });
        const file = after[slash + 1 ..];
        const stem = pf(a, "{s}-{s}-", .{ name, v });
        const target_ok = std.mem.startsWith(u8, file, stem) and std.mem.endsWith(u8, file, ".tar.gz\"") and file.len > stem.len + ".tar.gz\"".len;
        if (!target_ok) die("{s}: the url line '{s}' does not have the file name {s}<target>.tar.gz of its directory's version v{s}", .{ where, shown, stem, v });
        if (found) |f| {
            if (!std.mem.eql(u8, f, v)) die("{s}: its urls carry different versions ({s} and {s}), expected one", .{ where, f, v });
        }
        found = v;
    }
    return found orelse die("{s} has no url line", .{where});
}

/// The file is the formula of this release: its urls (all of them) carry --version and point into --repo's releases,
/// and it has no version line (the renderer writes none; brew audit refuses one that repeats the urls').
fn requireFormulaOf(a: Allocator, text: []const u8, o: Options) void {
    const v = urlVersion(a, text, o.repo, o.formula, o.formula_file);
    if (!std.mem.eql(u8, v, o.version)) die("{s}: its urls carry v{s}, so it is not the formula of v{s}", .{ o.formula_file, v, o.version });
    const have = declaredVersions(a, text);
    if (have.len != 0) die("{s} declares {d} version line(s): the rendered formula has none, the version is in its urls", .{ o.formula_file, have.len });
}

/// The version of the formula live on the tap, read from its urls. A formula in the older shape, with one
/// `version "<v>"` line, is accepted when that line equals the urls' version; two version lines, or one that differs, die.
fn liveVersion(a: Allocator, live: []const u8, o: Options, path: []const u8) []const u8 {
    const where = pf(a, "{s} on {s} of {s}", .{ path, o.base, o.tap_repo });
    const v = urlVersion(a, live, o.repo, o.formula, where);
    const have = declaredVersions(a, live);
    if (have.len > 1) die("{s} declares {d} version lines, expected at most 1", .{ where, have.len });
    if (have.len == 1 and !std.mem.eql(u8, have[0], v)) die("{s} declares version '{s}' but its urls carry v{s}", .{ where, have[0], v });
    return v;
}

/// The text of `path` at `ref` of the tap, or null when the tap has no such file (or no such ref).
fn formulaAt(t: Tool, o: Options, path: []const u8, ref: []const u8) ?[]const u8 {
    const a = t.a;
    const r = t.gh_(&.{ "api", "-H", "Accept: application/vnd.github.raw+json", pf(a, "repos/{s}/contents/{s}?ref={s}", .{ o.tap_repo, path, ref }) });
    if (!r.ok) {
        if (std.mem.indexOf(u8, r.stderr, "404") != null or std.mem.indexOf(u8, r.stderr, "Not Found") != null) return null;
        die("cannot read {s} at {s} of {s}: {s}", .{ path, ref, o.tap_repo, std.mem.trim(u8, r.stderr, " \r\n") });
    }
    return r.stdout;
}

/// Clones, writes the formula, stages it, commits and pushes the branch (never forced).
fn pushFormula(t: Tool, o: Options, text: []const u8, path: []const u8, branch: []const u8, title: []const u8, tag: []const u8) void {
    const a = t.a;
    gt.requireEmptyDir(o.workdir);
    const url = pf(a, "https://github.com/{s}.git", .{o.tap_repo});
    _ = t.gitMust(&.{ "clone", "--quiet", "--depth", "1", "--no-tags", "--single-branch", "--branch", o.base, url, o.workdir });

    const file = std.fs.path.join(a, &.{ o.workdir, path }) catch @panic("oom");
    if (std.fs.path.dirname(file)) |d| std.fs.cwd().makePath(d) catch |err| die("cannot make {s}: {s}", .{ d, @errorName(err) });
    std.fs.cwd().writeFile(file, text) catch |err| die("cannot write {s}: {s}", .{ file, @errorName(err) });
    _ = t.gitMust(&.{ "-C", o.workdir, "add", "--", path });
    requireOnePath(t, o, path);

    const body = pf(a,
        \\{s} for the release v{s} of {s}, rendered by `channels formula` from the SHA256SUMS the release pipeline verified.
        \\
        \\Release: https://github.com/{s}/releases/tag/{s}
        \\
        \\Opened by the release pipeline of {s} after it published the release. The only change is {s}.
    , .{ path, o.version, o.repo, o.repo, tag, o.repo, path });
    _ = t.gitMust(&.{ "-C", o.workdir, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", title, "-m", body });
    _ = t.gitMust(&.{ "-C", o.workdir, "push", "--quiet", "origin", pf(a, "HEAD:refs/heads/{s}", .{branch}) });
}

/// The staged change is exactly one path, `path`, a regular file added or modified.
fn requireOnePath(t: Tool, o: Options, path: []const u8) void {
    const raw = t.gitMust(&.{ "-C", o.workdir, "diff", "--cached", "--raw", "-z", "--no-renames", "--ignore-submodules=none", "HEAD" });
    var it = std.mem.splitScalar(u8, raw, 0);
    const meta = it.next() orelse "";
    const got = it.next() orelse "";
    const rest = it.next() orelse "";
    const more = it.next();
    // ":<old mode> 100644 <old> <new> A|M" then the path, then nothing but the end of the output.
    const shape = std.mem.startsWith(u8, meta, ":") and std.mem.indexOf(u8, meta, " 100644 ") != null and (std.mem.endsWith(u8, meta, " A") or std.mem.endsWith(u8, meta, " M"));
    if (meta.len == 0 or !shape or !std.mem.eql(u8, got, path) or rest.len != 0 or more != null) {
        die("the staged change is not exactly one added or modified file at {s} (git diff says '{s}'): refusing to commit, the guard would refuse it", .{ path, std.mem.trim(u8, raw, "\x00\n") });
    }
}

/// Opens the pull request of `branch`, asks for auto-merge. Returns its url.
fn openPr(t: Tool, o: Options, branch: []const u8, title: []const u8, tag: []const u8) []const u8 {
    const a = t.a;
    const body = pf(a, "Formula/{s}.rb for the release v{s} of {s}.\n\nRelease: https://github.com/{s}/releases/tag/{s}\n\nOpened by the release pipeline of {s}. The only change is Formula/{s}.rb, rendered from the verified SHA256SUMS of the release.", .{ o.formula, o.version, o.repo, o.repo, tag, o.repo, o.formula });
    const made = t.ghMust(&.{ "pr", "create", "-R", o.tap_repo, "--base", o.base, "--head", branch, "--title", title, "--body", body });
    const url = gt.createdUrl(made);
    out("opened {s}: {s} v{s}.\n", .{ url, o.formula, o.version });
    askAutoMerge(t, o, url);
    return url;
}

/// Asks for auto-merge with squash. GitHub refuses when the tap has no required checks (or does not allow
/// auto-merge): the pull request then stays open for its owner to merge, and this says so; it is not a failure.
fn askAutoMerge(t: Tool, o: Options, pr: []const u8) void {
    const r = t.gh_(&.{ "pr", "merge", pr, "-R", o.tap_repo, "--auto", "--squash" });
    if (!r.ok) {
        const why = std.mem.trim(u8, r.stderr, " \r\n");
        out("::notice title=The tap pull request is open without auto-merge::{s} stays open: GitHub refused to enable auto-merge on it ({s}). A tap without required checks cannot auto-merge; squash-merge it by hand. Once the tap requires checks, a re-run of this job turns auto-merge on.\n", .{ pr, why });
        return;
    }
    const on = t.ghMust(&.{ "pr", "view", pr, "-R", o.tap_repo, "--json", "autoMergeRequest", "--jq", ".autoMergeRequest != null" });
    if (!std.mem.eql(u8, on, "true")) {
        out("::notice title=The tap pull request is open without auto-merge::{s} stays open: `gh pr merge --auto --squash` succeeded but auto-merge is not on; squash-merge it by hand.\n", .{pr});
        return;
    }
    out("auto-merge (squash) is on for {s}.\n", .{pr});
}
