//! A `gh` for cut_release_test.zig. Its state is the directory $FAKE_GH_DIR: the files below say
//! what GitHub would answer, `log` gets one line per call (the arguments, space-joined), and the
//! one mutating call (creating a tag ref) makes the file `tag_exists`.
//!
//!   main_sha       the sha of main                         main_zig     src/cli/main.zig at main
//!   checks         what the check-runs query prints        tag_exists   the tag ref exists
//!   release_exists the release exists                      release_state "<draft> <prerelease>"
//!   assets/        the release's files (a download copies them)
//!   attest_refuse  a file name: `attestation verify` of that file fails
//! A missing file means: no tag, no release, state "false false", no refusal.

const std = @import("std");

fn fail404(msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("gh: {s} (HTTP 404)\n", .{msg}) catch {};
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
        } else if (std.mem.indexOf(u8, path, "/check-runs") != null) {
            try w.print("{s}\n", .{fileText(a, dir, "checks") orelse "0 0"});
        } else if (std.mem.startsWith(u8, path, repo ++ "git/ref/tags/")) {
            if (fileText(a, dir, "tag_exists") == null) fail404("Not Found");
            try w.writeAll("{}\n");
        } else if (std.mem.startsWith(u8, path, repo ++ "releases/tags/")) {
            if (fileText(a, dir, "release_exists") == null) fail404("Not Found");
            try w.writeAll("{}\n");
        } else {
            std.debug.print("fake gh: unexpected api call: {s}\n", .{line});
            std.process.exit(3);
        }
    } else if (std.mem.eql(u8, args[0], "release") and std.mem.eql(u8, args[1], "view")) {
        try w.print("{s}\n", .{fileText(a, dir, "release_state") orelse "false false"});
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
