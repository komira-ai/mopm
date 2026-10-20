//! A `gh` for cut_release_test.zig. Its state is the directory $FAKE_GH_DIR: the files below say
//! what GitHub would answer, `log` gets one line per call (the arguments, space-joined), and the
//! one mutating call (creating a tag ref) makes the file `tag_exists`.
//!
//!   main_sha       the sha of main                         main_zig     src/cli/main.zig at main
//!   runs           the workflow-runs JSON of main's commit       tag_exists   the tag ref exists
//!   release_exists the release exists                      release_state "<draft> <prerelease>"
//!   assets/        the release's files (a download copies them)
//!   attest_refuse  a file name: `attestation verify` of that file fails
//!   releases_page_<n>  page n of the release listing (JSON array; a missing page is [])
//!   asset_list     the release's asset names, one per line (default: the file names in assets/)
//!   tag_commit     the commit the tag resolves to (default main_sha)   compare_status  main...tag (default behind)
//!   tag_error      the tag-ref lookup fails with HTTP 500 (not a 404)
//!   release_error  the release lookup fails with HTTP 500 (not a 404)
//! A missing file means: no tag, no release, state "false false", no refusal.

const std = @import("std");

fn fail404(msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("gh: {s} (HTTP 404)\n", .{msg}) catch {};
    std.process.exit(1);
}

fn fail500() noreturn {
    std.io.getStdErr().writer().print("gh: Server Error (HTTP 500)\n", .{}) catch {};
    std.process.exit(1);
}

fn fileText(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]u8 {
    return dir.readFileAlloc(a, name, 1 << 20) catch null;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const dir_path = std.posix.getenv("FAKE_GH_DIR") orelse @panic("FAKE_GH_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const line = try std.mem.join(a, " ", argv[1..]);
    {
        var log = try dir.createFile("log", .{ .truncate = false });
        defer log.close();
        try log.seekFromEnd(0);
        try log.writer().print("{s}\n", .{line});
    }
    const w = std.io.getStdOut().writer();
    const args = argv[1..];
    const repo = "repos/komira-ai/mopm/";

    if (std.mem.eql(u8, args[0], "api")) {
        var path: []const u8 = "";
        for (args) |x| {
            if (std.mem.startsWith(u8, x, "repos/")) path = x;
        }
        if (std.mem.indexOf(u8, line, "-X POST") != null) {
            try dir.writeFile("tag_exists", "");
            return;
        }
        if (std.mem.eql(u8, path, repo ++ "commits/main")) {
            try w.print("{s}\n", .{fileText(a, dir, "main_sha") orelse ""});
        } else if (std.mem.startsWith(u8, path, repo ++ "contents/src/cli/main.zig?ref=")) {
            try w.writeAll(fileText(a, dir, "main_zig") orelse "");
        } else if (std.mem.indexOf(u8, path, "/actions/runs") != null) {
            try w.print("{s}\n", .{fileText(a, dir, "runs") orelse "{\"workflow_runs\":[]}"});
        } else if (std.mem.startsWith(u8, path, repo ++ "releases?")) {
            const at = std.mem.indexOf(u8, path, "&page=") orelse @panic("no page");
            const name = try std.fmt.allocPrint(a, "releases_page_{s}", .{path[at + 6 ..]});
            try w.print("{s}\n", .{fileText(a, dir, name) orelse "[]"});
        } else if (std.mem.startsWith(u8, path, repo ++ "commits/v")) {
            const t = fileText(a, dir, "tag_commit") orelse fileText(a, dir, "main_sha") orelse "";
            try w.print("{s}\n", .{std.mem.trim(u8, t, " \n")});
        } else if (std.mem.startsWith(u8, path, repo ++ "compare/main...")) {
            const t = fileText(a, dir, "compare_status") orelse "behind";
            try w.print("{s}\n", .{std.mem.trim(u8, t, " \n")});
        } else if (std.mem.startsWith(u8, path, repo ++ "git/ref/tags/")) {
            if (fileText(a, dir, "tag_error") != null) fail500();
            if (fileText(a, dir, "tag_exists") == null) fail404("Not Found");
            try w.writeAll("{}\n");
        } else if (std.mem.startsWith(u8, path, repo ++ "releases/tags/")) {
            if (fileText(a, dir, "release_error") != null) fail500();
            if (fileText(a, dir, "release_exists") == null) fail404("Not Found");
            try w.writeAll("{}\n");
        } else {
            std.debug.print("fake gh: unexpected api call: {s}\n", .{line});
            std.process.exit(3);
        }
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "view")) {
        var want_assets = false;
        for (args) |x| {
            if (std.mem.eql(u8, x, "assets")) want_assets = true;
        }
        if (want_assets) {
            if (fileText(a, dir, "asset_list")) |l| {
                try w.print("{s}\n", .{std.mem.trim(u8, l, "\n")});
            } else {
                var assets = try dir.openDir("assets", .{ .iterate = true });
                defer assets.close();
                var it = assets.iterate();
                while (try it.next()) |e| try w.print("{s}\n", .{e.name});
            }
        } else {
            try w.print("{s}\n", .{fileText(a, dir, "release_state") orelse "false false"});
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
    } else if (std.mem.eql(u8, args[0], "attestation") and std.mem.eql(u8, args[1], "verify")) {
        const refused = fileText(a, dir, "attest_refuse");
        if (refused) |r| {
            if (std.mem.endsWith(u8, args[2], std.mem.trim(u8, r, " \n"))) {
                std.io.getStdErr().writer().print("gh: no attestation found\n", .{}) catch {};
                std.process.exit(1);
            }
        }
    } else {
        std.debug.print("fake gh: unexpected call: {s}\n", .{line});
        std.process.exit(3);
    }
}
