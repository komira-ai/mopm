//! A `git` for bump_internal_test.zig and tap_test.zig. Its state is the directory $FAKE_GIT_DIR: the files below say what
//! git would answer, `git_log` gets one line per call (the arguments, space-joined), `git_env` one line per
//! call with the parts of the environment that matter (the token header, the identity), and the calls that
//! change something (update-index, commit, push) write files a test reads. It knows only the calls
//! cut_release bump-internal makes; any other is exit 3, so a new git call is a visible change.
//!
//!   git_ls_tree    what `ls-tree HEAD -- <path>` prints before the commit (`<mode> <type> <sha>\t<path>`)
//!   git_diff       what `diff --cached --raw -z ...` prints (default: one modified gitlink at the path of
//!                  the last update-index; empty before any)
//!   clone_fail, commit_fail, push_fail   that call fails
//!   commit_wrong   the commit holds another gitlink than the one staged
//!   add_noop       `git add` stages nothing (the file is the one the clone already has)
//!   add_extra      `git add` stages one more path than it was given (README.md)
//! Written by the tool's calls: index_entry (the --cacheinfo value), committed (what ls-tree prints after the
//! commit), commit (the two -m messages, `---` between), pushed (the refspec).
//! For cut_release tap: add (the paths staged, in `added`), and the default `diff --cached --raw -z` then prints one added
//! regular file per staged path; `git_diff` overrides it. A commit with a staged path needs no gitlink (`committed` is not written).

const std = @import("std");

fn failWith(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("git: " ++ msg ++ "\n", .{}) catch {};
    std.process.exit(1);
}

fn fileText(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]u8 {
    return dir.readFileAlloc(a, name, 1 << 20) catch null;
}

fn appendFile(dir: std.fs.Dir, name: []const u8, line: []const u8) !void {
    var f = try dir.createFile(name, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writer().print("{s}\n", .{line});
}

fn env(name: []const u8) []const u8 {
    return std.posix.getenv(name) orelse "(unset)";
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const dir_path = std.posix.getenv("FAKE_GIT_DIR") orelse @panic("FAKE_GIT_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    try appendFile(dir, "git_log", try std.mem.join(a, " ", argv[1..]));

    // Skip `-C <dir>` and `-c <k=v>`.
    var i: usize = 1;
    while (i + 1 < argv.len and (std.mem.eql(u8, argv[i], "-C") or std.mem.eql(u8, argv[i], "-c"))) i += 2;
    const verb = argv[i];
    const args = argv[i + 1 ..];
    try appendFile(dir, "git_env", try std.fmt.allocPrint(a, "{s} GH_TOKEN={s} HEADER={s} AUTHOR={s} <{s}> COMMITTER={s} <{s}>", .{
        verb,
        env("GH_TOKEN"),
        env("GIT_CONFIG_VALUE_0"),
        env("GIT_AUTHOR_NAME"),
        env("GIT_AUTHOR_EMAIL"),
        env("GIT_COMMITTER_NAME"),
        env("GIT_COMMITTER_EMAIL"),
    }));
    const w = std.io.getStdOut().writer();

    if (std.mem.eql(u8, verb, "clone")) {
        if (fileText(a, dir, "clone_fail") != null) failWith("could not read from the remote repository");
        try std.fs.cwd().makePath(args[args.len - 1]);
    } else if (std.mem.eql(u8, verb, "ls-tree")) {
        const text = fileText(a, dir, "committed") orelse fileText(a, dir, "git_ls_tree") orelse failWith("no git_ls_tree");
        try w.writeAll(text);
    } else if (std.mem.eql(u8, verb, "update-index")) {
        try dir.writeFile("index_entry", args[1]);
    } else if (std.mem.eql(u8, verb, "add")) {
        if (fileText(a, dir, "add_noop") == null) try appendFile(dir, "added", args[args.len - 1]);
        if (fileText(a, dir, "add_extra") != null) try appendFile(dir, "added", "README.md");
    } else if (std.mem.eql(u8, verb, "diff")) {
        if (fileText(a, dir, "git_diff")) |d| {
            try w.writeAll(d);
        } else if (fileText(a, dir, "added")) |paths| {
            var it = std.mem.splitScalar(u8, paths, '\n');
            while (it.next()) |p| {
                if (p.len != 0) try w.print(":000000 100644 {s} {s} A\x00{s}\x00", .{ "0" ** 40, "1" ** 40, p });
            }
        } else if (fileText(a, dir, "index_entry")) |e| {
            const path = e[std.mem.lastIndexOfScalar(u8, e, ',').? + 1 ..];
            const zeros = "0" ** 40;
            try w.print(":160000 160000 {s} {s} M\x00{s}\x00", .{ zeros, zeros, path });
        }
    } else if (std.mem.eql(u8, verb, "commit")) {
        if (fileText(a, dir, "commit_fail") != null) failWith("commit failed");
        var msgs = std.ArrayList(u8).init(a);
        for (args, 0..) |x, k| {
            if (std.mem.eql(u8, x, "-m")) {
                if (msgs.items.len != 0) try msgs.appendSlice("\n---\n");
                try msgs.appendSlice(args[k + 1]);
            }
        }
        try dir.writeFile("commit", msgs.items);
        if (fileText(a, dir, "added") != null) return;
        const e = fileText(a, dir, "index_entry") orelse failWith("nothing staged");
        var f = std.mem.splitScalar(u8, e, ',');
        _ = f.next();
        const sha = f.next().?;
        const path = f.next().?;
        const held = if (fileText(a, dir, "commit_wrong") != null) "ffffffffffffffffffffffffffffffffffffffff" else sha;
        try dir.writeFile("committed", try std.fmt.allocPrint(a, "160000 commit {s}\t{s}\n", .{ held, path }));
    } else if (std.mem.eql(u8, verb, "push")) {
        if (fileText(a, dir, "push_fail") != null) failWith("remote rejected");
        try appendFile(dir, "pushed", args[args.len - 1]);
    } else {
        std.debug.print("fake git: unexpected call: {s}\n", .{try std.mem.join(a, " ", argv[1..])});
        std.process.exit(3);
    }
}
