//! A `gh` for cut_release_test.zig. Its state is the directory $FAKE_GH_DIR: the files below say
//! what GitHub would answer, `log` gets one line per call (the arguments, space-joined), and the
//! mutating calls (creating a tag, a release, an asset) change the files, so a test can read what
//! the tool did.
//!
//!   main_sha       the sha of main (the default commit of a tag)
//!   tags           one line per tag, `<name> <commit>`; a tag-ref POST appends one
//!                  (the tag listings: `git/matching-refs/tags/<prefix>` answers every match on every page, as GitHub does;
//!                  `tags?per_page=&page=` pages)
//!   race           `<name> <commit>`: the next tag-ref POST first creates that tag (another run took
//!                  the number) and fails with HTTP 422 "Reference already exists"
//!   ref_taken      every tag-ref POST fails with HTTP 422 "Reference already exists"
//!   tag_commit     the commit every tag resolves to when there is no `tags` file (default main_sha); with a
//!                  `tags` file, a tag not in it is HTTP 404
//!   compare_status main...<sha> (default behind)
//!   compare_tag_<commit>  <commit>...<sha> for another base than main (a release tag's commit);
//!                  tag_compare_status is the answer when that file is missing (default ahead)
//!   releases_page_<n>  page n of the release listing (JSON array; a missing page is [])
//!   release_exists the release exists (`release view`, `releases/tags/`)   release_state "<draft> <prerelease>"
//!   assets/        the release's files (a download copies them; create and upload add to them)
//!   asset_list     the release's asset names, one per line (default: the file names in assets/)
//!   tag_packaging/ the .deb metadata files (control, copyright, lintian-overrides) `contents/packaging/deb/<file>?ref=` answers with;
//!                  without the directory it answers with the working tree's packaging/deb; a file missing from the directory is HTTP 404
//!   attest_refuse  a file name: `attestation verify` of that file fails
//!   release_error  `release view` fails with HTTP 500 (not a 404)
//!   upload_fail    `release upload` fails
//!
//! For cut_release bump-internal (the pull requests of komira-ai/komira-internal):
//!   prs            one line per pull request, `<number> <OPEN|CLOSED|MERGED> <head branch> <auto-merge 0|1>`;
//!                  `pr create` appends one (number 100 + the count, OPEN, 0), `pr merge` sets the last field
//!                  (not with auto_noop), `pr close` sets CLOSED
//!   branches       one branch name per line: the branches `git/ref/heads/<name>` finds (else HTTP 404)
//!   branch_gitlink the commit `contents/<submodule>?ref=<branch>` reports
//!   create_fail, merge_fail, close_fail, auto_noop   `pr create` / `pr merge` / `pr close` fail; `pr merge` succeeds
//!                  but leaves auto-merge off
//!
//! For cut_release tap (the pull requests of komira-ai/homebrew-tap; the pr calls above answer for whichever repository -R names):
//!   tap_main_formula   the text `contents/Formula/mopm.rb?ref=main` answers with (else HTTP 404: the tap has no formula yet)
//!   tap_branch_formula the text it answers with for any other ref, i.e. a pushed bump branch (else HTTP 404)
//!   tap_read_error reading the tap's formula fails with HTTP 500 (not a 404)
//!   merge_clean    `pr merge` fails as GitHub does for a pull request with no required checks (HTTP 200, GraphQL: Pull request is in clean status)
//!   `pr merge` takes --merge or --squash.
//! Written by the tool's calls: pending_tag (the tag object a git/tags POST made), release_notes (the
//! notes file a `release create` was given).
//! A missing file means: no tag, no release, state "false false", no refusal.

const std = @import("std");

fn failWith(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("gh: " ++ msg ++ "\n", .{}) catch {};
    std.process.exit(1);
}

fn fileText(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]u8 {
    return dir.readFileAlloc(a, name, 1 << 20) catch null;
}

fn field(args: []const []const u8, key: []const u8) []const u8 {
    for (args) |x| {
        if (std.mem.startsWith(u8, x, key) and x.len > key.len and x[key.len] == '=') return x[key.len + 1 ..];
    }
    return "";
}

/// The commit of tag `name` in the `tags` file, if it is there.
fn tagCommit(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]const u8 {
    const text = fileText(a, dir, "tags") orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
        if (std.mem.eql(u8, l[0..sp], name)) return l[sp + 1 ..];
    }
    return null;
}

fn appendFile(dir: std.fs.Dir, name: []const u8, line: []const u8) !void {
    var f = try dir.createFile(name, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writer().print("{s}\n", .{line});
}

/// The file arguments of `release create|upload <tag> <files...> [flags]`.
fn fileArgs(args: []const []const u8) []const []const u8 {
    var end: usize = 3;
    while (end < args.len and !std.mem.startsWith(u8, args[end], "-")) end += 1;
    return args[3..end];
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const dir_path = std.posix.getenv("FAKE_GH_DIR") orelse @panic("FAKE_GH_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const line = try std.mem.join(a, " ", argv[1..]);
    try appendFile(dir, "log", line);
    const w = std.io.getStdOut().writer();
    const args = argv[1..];
    const repo = "repos/komira-ai/mopm/";
    const internal = "repos/komira-ai/komira-internal/";
    const tap = "repos/komira-ai/homebrew-tap/";
    try dir.makePath("assets");

    if (std.mem.eql(u8, args[0], "api")) {
        var path: []const u8 = "";
        for (args) |x| {
            if (std.mem.startsWith(u8, x, "repos/")) path = x;
        }
        if (std.mem.indexOf(u8, line, "-X POST") != null) {
            if (std.mem.eql(u8, path, repo ++ "git/tags")) {
                try dir.writeFile("pending_tag", try std.fmt.allocPrint(a, "{s} {s}", .{ field(args, "tag"), field(args, "object") }));
                try w.writeAll("1111111111111111111111111111111111111111\n");
            } else if (std.mem.eql(u8, path, repo ++ "git/refs")) {
                const name = field(args, "ref")["refs/tags/".len..];
                if (fileText(a, dir, "race")) |r| {
                    try appendFile(dir, "tags", std.mem.trim(u8, r, "\n"));
                    try dir.deleteFile("race");
                    failWith("Reference already exists (HTTP 422)");
                }
                if (fileText(a, dir, "ref_taken") != null or tagCommit(a, dir, name) != null) failWith("Reference already exists (HTTP 422)");
                const pending = fileText(a, dir, "pending_tag") orelse failWith("no tag object (HTTP 422)");
                const sp = std.mem.indexOfScalar(u8, pending, ' ') orelse failWith("bad pending tag");
                if (!std.mem.eql(u8, pending[0..sp], name)) failWith("the ref names another tag than the object (HTTP 422)");
                try appendFile(dir, "tags", try std.fmt.allocPrint(a, "{s} {s}", .{ name, pending[sp + 1 ..] }));
            } else {
                std.debug.print("fake gh: unexpected POST: {s}\n", .{line});
                std.process.exit(3);
            }
            return;
        }
        if (std.mem.startsWith(u8, path, repo ++ "git/matching-refs/tags/")) {
            const rest = path[(repo ++ "git/matching-refs/tags/").len..];
            const q = std.mem.indexOf(u8, rest, "?per_page=") orelse @panic("no per_page");
            const prefix = rest[0..q];
            // Like GitHub: this listing is not paginated. It answers every match whatever `page` and `per_page` say,
            // so a caller that pages through it gets the same answer on every page.
            var matched = std.ArrayList([]const u8).init(a);
            var lines = std.mem.splitScalar(u8, fileText(a, dir, "tags") orelse "", '\n');
            while (lines.next()) |l| {
                const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
                if (std.mem.startsWith(u8, l[0..sp], prefix)) try matched.append(l[0..sp]);
            }
            try w.writeAll("[");
            for (matched.items, 0..) |n, i| try w.print("{s}{{\"ref\":\"refs/tags/{s}\"}}", .{ if (i == 0) "" else ",", n });
            try w.writeAll("]\n");
        } else if (std.mem.startsWith(u8, path, repo ++ "tags?")) {
            // The tag list proper: `per_page` tags a page (at most 100), an empty page past the end.
            const q = std.mem.indexOf(u8, path, "per_page=") orelse @panic("no per_page");
            const amp = std.mem.indexOfScalarPos(u8, path, q, '&') orelse @panic("no page");
            const per = @min(try std.fmt.parseInt(usize, path[q + 9 .. amp], 10), 100);
            const at = std.mem.indexOf(u8, path, "page=") orelse @panic("no page");
            const page = try std.fmt.parseInt(usize, path[at + 5 ..], 10);
            var names = std.ArrayList([]const u8).init(a);
            var lines = std.mem.splitScalar(u8, fileText(a, dir, "tags") orelse "", '\n');
            while (lines.next()) |l| {
                const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
                try names.append(l[0..sp]);
            }
            const from = @min((page - 1) * per, names.items.len);
            const to = @min(page * per, names.items.len);
            try w.writeAll("[");
            for (names.items[from..to], 0..) |n, i| try w.print("{s}{{\"name\":\"{s}\"}}", .{ if (i == 0) "" else ",", n });
            try w.writeAll("]\n");
        } else if (std.mem.startsWith(u8, path, repo ++ "releases?")) {
            const at = std.mem.indexOf(u8, path, "&page=") orelse @panic("no page");
            const name = try std.fmt.allocPrint(a, "releases_page_{s}", .{path[at + 6 ..]});
            try w.print("{s}\n", .{fileText(a, dir, name) orelse "[]"});
        } else if (std.mem.startsWith(u8, path, repo ++ "commits/v")) {
            const name = path[(repo ++ "commits/").len..];
            if (tagCommit(a, dir, name)) |c| {
                try w.print("{s}\n", .{c});
            } else if (fileText(a, dir, "tags") != null) {
                failWith("Not Found (HTTP 404)");
            } else {
                const t = fileText(a, dir, "tag_commit") orelse fileText(a, dir, "main_sha") orelse "";
                try w.print("{s}\n", .{std.mem.trim(u8, t, " \n")});
            }
        } else if (std.mem.startsWith(u8, path, repo ++ "compare/main...")) {
            const t = fileText(a, dir, "compare_status") orelse "behind";
            try w.print("{s}\n", .{std.mem.trim(u8, t, " \n")});
        } else if (std.mem.startsWith(u8, path, repo ++ "compare/")) {
            // <tag commit>...<sha>: is the sha ahead of that release's commit?
            const rest = path[(repo ++ "compare/").len..];
            const dots = std.mem.indexOf(u8, rest, "...") orelse @panic("compare without ...");
            const file = try std.fmt.allocPrint(a, "compare_tag_{s}", .{rest[0..dots]});
            const t = fileText(a, dir, file) orelse fileText(a, dir, "tag_compare_status") orelse "ahead";
            try w.print("{s}\n", .{std.mem.trim(u8, t, " \n")});
        } else if (std.mem.startsWith(u8, path, repo ++ "contents/packaging/deb/")) {
            // The .deb metadata at a tag: tag_packaging/<file> when the scenario has it, else the repository's own.
            const rest = path[(repo ++ "contents/packaging/deb/").len..];
            const name = rest[0..std.mem.indexOfScalar(u8, rest, '?').?];
            const held = if (dir.openDir("tag_packaging", .{})) |d0| blk: {
                var d = d0;
                defer d.close();
                break :blk fileText(a, d, name);
            } else |_| std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "packaging/deb/{s}", .{name}), 1 << 20) catch null;
            try w.writeAll(held orelse failWith("Not Found (HTTP 404)"));
        } else if (std.mem.startsWith(u8, path, internal ++ "git/ref/heads/")) {
            const name = path[(internal ++ "git/ref/heads/").len..];
            var found = false;
            var bl = std.mem.splitScalar(u8, fileText(a, dir, "branches") orelse "", '\n');
            while (bl.next()) |b| {
                if (std.mem.eql(u8, b, name)) found = true;
            }
            if (!found) failWith("Not Found (HTTP 404)");
            try w.writeAll("2222222222222222222222222222222222222222\n");
        } else if (std.mem.startsWith(u8, path, tap ++ "contents/Formula/")) {
            if (fileText(a, dir, "tap_read_error") != null) failWith("Server Error (HTTP 500)");
            const at = std.mem.indexOf(u8, path, "?ref=") orelse @panic("no ref");
            const file = if (std.mem.eql(u8, path[at + 5 ..], "main")) "tap_main_formula" else "tap_branch_formula";
            try w.writeAll(fileText(a, dir, file) orelse failWith("Not Found (HTTP 404)"));
        } else if (std.mem.startsWith(u8, path, internal ++ "contents/")) {
            const held = fileText(a, dir, "branch_gitlink") orelse failWith("no branch_gitlink");
            try w.print("{s}\n", .{std.mem.trim(u8, held, " \n")});
        } else {
            std.debug.print("fake gh: unexpected api call: {s}\n", .{line});
            std.process.exit(3);
        }
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "view")) {
        if (fileText(a, dir, "release_error") != null) failWith("Server Error (HTTP 500)");
        if (fileText(a, dir, "release_exists") == null) failWith("release not found");
        var want_assets = false;
        var want_json = false;
        for (args) |x| {
            if (std.mem.eql(u8, x, "assets")) want_assets = true;
            if (std.mem.eql(u8, x, "isDraft,isPrerelease,assets")) want_json = true;
        }
        const state = std.mem.trim(u8, fileText(a, dir, "release_state") orelse "false false", " \n");
        if (want_json) {
            try w.print("{{\"isDraft\":{s},\"isPrerelease\":{s},\"assets\":[", .{ state[0 .. std.mem.indexOfScalar(u8, state, ' ').?], state[std.mem.indexOfScalar(u8, state, ' ').? + 1 ..] });
            var assets = try dir.openDir("assets", .{ .iterate = true });
            defer assets.close();
            var it = assets.iterate();
            var first = true;
            while (try it.next()) |e| {
                try w.print("{s}{{\"name\":\"{s}\"}}", .{ if (first) "" else ",", e.name });
                first = false;
            }
            try w.writeAll("]}\n");
        } else if (want_assets) {
            if (fileText(a, dir, "asset_list")) |l| {
                try w.print("{s}\n", .{std.mem.trim(u8, l, "\n")});
            } else {
                var assets = try dir.openDir("assets", .{ .iterate = true });
                defer assets.close();
                var it = assets.iterate();
                while (try it.next()) |e| try w.print("{s}\n", .{e.name});
            }
        } else {
            try w.print("{s}\n", .{state});
        }
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "download")) {
        var dest: []const u8 = "";
        for (args, 0..) |x, i| {
            if (std.mem.eql(u8, x, "-D")) dest = args[i + 1];
        }
        var assets = try dir.openDir("assets", .{ .iterate = true });
        defer assets.close();
        var out = try std.fs.cwd().openDir(dest, .{});
        defer out.close();
        var it = assets.iterate();
        while (try it.next()) |e| try assets.copyFile(e.name, out, e.name, .{});
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "create")) {
        if (fileText(a, dir, "release_exists") != null) failWith("a release with this tag already exists (HTTP 422)");
        var assets = try dir.openDir("assets", .{});
        defer assets.close();
        for (fileArgs(args)) |p| try std.fs.cwd().copyFile(p, assets, std.fs.path.basename(p), .{});
        var pre = false;
        for (args, 0..) |x, i| {
            if (std.mem.eql(u8, x, "--prerelease")) pre = true;
            if (std.mem.eql(u8, x, "--notes-file")) try dir.writeFile("release_notes", try std.fs.cwd().readFileAlloc(a, args[i + 1], 1 << 20));
        }
        try dir.writeFile("release_exists", "");
        try dir.writeFile("release_state", if (pre) "false true\n" else "false false\n");
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "upload")) {
        if (fileText(a, dir, "upload_fail") != null) failWith("upload failed");
        var assets = try dir.openDir("assets", .{});
        defer assets.close();
        for (fileArgs(args)) |p| {
            const name = std.fs.path.basename(p);
            if (assets.access(name, .{})) |_| failWith("an asset with this name already exists (HTTP 422)") else |_| {}
            try std.fs.cwd().copyFile(p, assets, name, .{});
        }
    } else if (std.mem.eql(u8, args[0], "pr")) {
        try pr(a, dir, args, w);
    } else if (std.mem.eql(u8, args[0], "attestation") and std.mem.eql(u8, args[1], "verify")) {
        const refused = fileText(a, dir, "attest_refuse");
        if (refused) |r| {
            if (std.mem.endsWith(u8, args[2], std.mem.trim(u8, r, " \n"))) failWith("no attestation found");
        }
    } else {
        std.debug.print("fake gh: unexpected call: {s}\n", .{line});
        std.process.exit(3);
    }
}

/// The value after `flag` in `args`, or "".
fn flagValue(args: []const []const u8, flag: []const u8) []const u8 {
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, flag) and i + 1 < args.len) return args[i + 1];
    }
    return "";
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |x| {
        if (std.mem.eql(u8, x, flag)) return true;
    }
    return false;
}

/// `gh pr list|create|merge|view|close` over the file `prs` (see the header).
fn pr(a: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8, w: anytype) !void {
    const url_head = try std.fmt.allocPrint(a, "https://github.com/{s}/pull/", .{flagValue(args, "-R")});
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, fileText(a, dir, "prs") orelse "", '\n');
    while (it.next()) |l| {
        if (l.len != 0) try lines.append(l);
    }
    const verb = args[1];
    if (std.mem.eql(u8, verb, "list")) {
        try w.writeAll("[");
        for (lines.items, 0..) |l, i| {
            var f = std.mem.splitScalar(u8, l, ' ');
            const n = f.next().?;
            const state = f.next().?;
            const head = f.next().?;
            const auto = f.next().?;
            const am = if (std.mem.eql(u8, auto, "1")) "{\"mergeMethod\":\"MERGE\"}" else "null";
            try w.print("{s}{{\"number\":{s},\"state\":\"{s}\",\"headRefName\":\"{s}\",\"url\":\"{s}{s}\",\"autoMergeRequest\":{s}}}", .{ if (i == 0) "" else ",", n, state, head, url_head, n, am });
        }
        try w.writeAll("]\n");
        return;
    }
    if (std.mem.eql(u8, verb, "create")) {
        if (fileText(a, dir, "create_fail") != null) failWith("pull request create failed");
        const n = 100 + lines.items.len;
        try appendFile(dir, "prs", try std.fmt.allocPrint(a, "{d} OPEN {s} 0", .{ n, flagValue(args, "--head") }));
        try w.print("{s}{d}\n", .{ url_head, n });
        return;
    }
    // merge, view and close name the pull request by number or url.
    const ref = args[2];
    const number = ref[if (std.mem.lastIndexOfScalar(u8, ref, '/')) |s| s + 1 else 0..];
    var found = false;
    var next = std.ArrayList(u8).init(a);
    for (lines.items) |l| {
        var f = std.mem.splitScalar(u8, l, ' ');
        const n = f.next().?;
        var state = f.next().?;
        const head = f.next().?;
        var auto = f.next().?;
        if (std.mem.eql(u8, n, number)) {
            found = true;
            if (std.mem.eql(u8, verb, "merge")) {
                if (fileText(a, dir, "merge_fail") != null) failWith("auto-merge cannot be enabled (GraphQL)");
                if (fileText(a, dir, "merge_clean") != null) failWith("GraphQL: Pull request is in clean status (enablePullRequestAutoMerge)");
                if (!hasFlag(args, "--auto") or !(hasFlag(args, "--merge") or hasFlag(args, "--squash"))) failWith("this fake wants gh pr merge --auto --merge|--squash");
                if (fileText(a, dir, "auto_noop") == null) auto = "1";
            } else if (std.mem.eql(u8, verb, "close")) {
                if (fileText(a, dir, "close_fail") != null) failWith("cannot close");
                state = "CLOSED";
            } else if (std.mem.eql(u8, verb, "view")) {
                try w.print("{s}\n", .{if (std.mem.eql(u8, auto, "1")) "true" else "false"});
            }
        }
        try next.writer().print("{s} {s} {s} {s}\n", .{ n, state, head, auto });
    }
    if (!found) failWith("no pull request found");
    try dir.writeFile("prs", next.items);
}
