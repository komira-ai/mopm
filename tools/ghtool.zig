//! What the two pull-request steps of a release share: `cut_release bump-internal` (tools/bump_internal.zig) and
//! `cut_release tap` (tools/tap.zig). Both open a pull request in ANOTHER repository as the release bot, with
//! `gh` and `git` run without a shell, the App installation token only in the environment, and the pull requests of
//! that repository read the same way. Zig only, standard library only.
//!
//! The token is the environment variable GH_TOKEN. `gh` reads it from there. `git` gets it as an HTTP header through
//! GIT_CONFIG_* in its environment (and GH_TOKEN is removed from git's environment). It is never an argument of any
//! process, and `Tool.exec` refuses to run a command whose arguments contain it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The identity of the commit: the bot's login, and the noreply address GitHub gives a bot user,
/// `<user id>+<login>@users.noreply.github.com`. The id is the id of the bot USER
/// (`gh api /users/komira-release-bot%5Bbot%5D --jq .id`), not the id of the App.
pub const bot_name = "komira-release-bot[bot]";
pub const bot_email = "345322945+komira-release-bot[bot]@users.noreply.github.com";

/// What error messages start with: the subcommand that is running (`cut_release bump-internal`, `cut_release tap`).
pub var prefix: []const u8 = "cut_release";

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("{s}: ", .{prefix});
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn out(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch {};
}

pub fn pf(a: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch @panic("oom");
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
pub fn parseSemver(s: []const u8) ?[3]u64 {
    var parts = std.mem.splitScalar(u8, s, '.');
    var v: [3]u64 = undefined;
    for (&v) |*slot| slot.* = canonical(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return v;
}

pub fn order(x: [3]u64, y: [3]u64) std.math.Order {
    for (x, y) |p, q| {
        if (p != q) return std.math.order(p, q);
    }
    return .eq;
}

pub fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// A repository or submodule name part: letters, digits, `.`, `_`, `-`; not starting with `.`.
pub fn namePart(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn ownerName(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    return namePart(s[0..slash]) and namePart(s[slash + 1 ..]);
}

// ---- running gh and git ----------------------------------------------------------------

pub const Ran = struct { ok: bool, stdout: []u8, stderr: []u8 };

pub const Tool = struct {
    a: Allocator,
    gh: []const u8,
    git: []const u8,
    token: []const u8,
    /// The environment of git: no GH_TOKEN, the token as an HTTP header, the bot as author and committer.
    git_env: std.process.EnvMap,

    /// The tool for the token in GH_TOKEN (refused when unset or empty).
    pub fn init(a: Allocator, gh: []const u8, git: []const u8) Tool {
        const token = std.process.getEnvVarOwned(a, "GH_TOKEN") catch die("GH_TOKEN is not set (the App installation token of the release bot)", .{});
        if (token.len == 0) die("GH_TOKEN is empty", .{});
        return .{ .a = a, .gh = gh, .git = git, .token = token, .git_env = buildGitEnv(a, token) };
    }

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

    pub fn gh_(t: Tool, args: []const []const u8) Ran {
        return t.exec(t.gh, args, null);
    }

    pub fn git_(t: Tool, args: []const []const u8) Ran {
        return t.exec(t.git, args, &t.git_env);
    }

    /// Standard output of a gh call that must succeed, trimmed.
    pub fn ghMust(t: Tool, args: []const []const u8) []const u8 {
        const r = t.gh_(args);
        if (!r.ok) die("gh {s} failed: {s}", .{ args[0], std.mem.trim(u8, r.stderr, " \r\n") });
        return std.mem.trim(u8, r.stdout, " \r\n");
    }

    pub fn gitMust(t: Tool, args: []const []const u8) []const u8 {
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

/// The clone goes into a directory this run made: it is created if missing and must be empty.
pub fn requireEmptyDir(path: []const u8) void {
    std.fs.cwd().makePath(path) catch |err| die("cannot make {s}: {s}", .{ path, @errorName(err) });
    var d = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| die("cannot open {s}: {s}", .{ path, @errorName(err) });
    defer d.close();
    var it = d.iterate();
    if (it.next() catch null) |_| die("{s} is not empty; give an empty directory", .{path});
}

// ---- the pull requests of a repository ---------------------------------------------------

pub const Pr = struct {
    number: u64 = 0,
    state: []const u8 = "",
    headRefName: []const u8 = "",
    url: []const u8 = "",
    autoMergeRequest: ?std.json.Value = null,
};

pub fn listPrs(t: Tool, repo: []const u8) []const Pr {
    const json = t.ghMust(&.{ "pr", "list", "-R", repo, "--state", "all", "--limit", "500", "--json", "number,state,headRefName,url,autoMergeRequest" });
    const parsed = std.json.parseFromSlice([]const Pr, t.a, json, .{ .ignore_unknown_fields = true }) catch |err| {
        die("cannot read the pull request list: {s}", .{@errorName(err)});
    };
    return parsed.value;
}

/// The version a bump branch `bump/<name>-v<semver>` names, or null for any other branch.
pub fn branchVersion(a: Allocator, name: []const u8, head: []const u8) ?[3]u64 {
    const want = pf(a, "bump/{s}-v", .{name});
    if (!std.mem.startsWith(u8, head, want)) return null;
    return parseSemver(head[want.len..]);
}

/// What the pull requests of a repository say about a bump to `mine`.
pub const Bumps = struct {
    /// An open or merged bump pull request for this or a NEWER version (an open one is preferred), if any.
    covered: ?Pr = null,
    /// The open bump pull requests of an OLDER version.
    older: []const Pr,
};

pub fn classify(a: Allocator, prs: []const Pr, name: []const u8, mine: [3]u64) Bumps {
    var covered: ?Pr = null;
    var older = std.ArrayList(Pr).init(a);
    for (prs) |p| {
        const v = branchVersion(a, name, p.headRefName) orelse continue;
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
    return .{ .covered = covered, .older = older.items };
}

/// The url `gh pr create` printed: the last line of its output.
pub fn createdUrl(made: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, made, '\n');
    const url = if (nl) |i| made[i + 1 ..] else made;
    if (!std.mem.startsWith(u8, url, "https://")) die("gh pr create printed '{s}', not a pull request url", .{made});
    return url;
}

/// Closes each older bump in favour of the new one (or of the version, when no new pull request was opened).
pub fn closeOlder(t: Tool, repo: []const u8, older: []const Pr, opened: []const u8, version: []const u8) void {
    const a = t.a;
    for (older) |p| {
        const note = if (opened.len != 0) pf(a, "Superseded by {s}.", .{opened}) else pf(a, "Superseded by the bump to v{s}.", .{version});
        _ = t.ghMust(&.{ "pr", "close", pf(a, "{d}", .{p.number}), "-R", repo, "--comment", note, "--delete-branch" });
        out("closed {s} (older than v{s}).\n", .{ p.url, version });
    }
}
