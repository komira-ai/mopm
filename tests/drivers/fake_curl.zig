//! A `curl` for apt_publish_test.zig: the runner's OIDC token endpoint. It answers only the request the exchange makes: `-sSf`, the
//! bearer header of $FAKE_OIDC_TOKEN, and a URL asking for the audience sts.amazonaws.com. It appends the arguments to
//! $FAKE_AWS_DIR/log and fails (22, as `-f` does) when the file `curl_fail` exists there.

const std = @import("std");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const args = argv[1..];
    const dir_path = std.posix.getenv("FAKE_AWS_DIR") orelse @panic("FAKE_AWS_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    {
        var f = try dir.createFile("log", .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writer().print("curl {s}\n", .{try std.mem.join(a, " ", args)});
    }
    const err = std.io.getStdErr().writer();
    if (dir.access("curl_fail", .{})) |_| {
        try err.writeAll("curl: (22) The requested URL returned error: 403\n");
        std.process.exit(22);
    } else |_| {}
    var silent = false;
    var bearer_ok = false;
    var url: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-sSf")) silent = true;
        if (std.mem.eql(u8, args[i], "-H") and i + 1 < args.len) {
            i += 1;
            const want = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{std.posix.getenv("FAKE_OIDC_TOKEN") orelse "none"});
            bearer_ok = std.mem.eql(u8, args[i], want);
        } else if (std.mem.startsWith(u8, args[i], "http")) url = args[i];
    }
    if (!silent or !bearer_ok or !std.mem.endsWith(u8, url, "audience=sts.amazonaws.com")) {
        try err.writeAll("curl: (22) bad request\n");
        std.process.exit(22);
    }
    try std.io.getStdOut().writeAll("{\"count\":1,\"value\":\"fake.jwt.token\"}\n");
}
