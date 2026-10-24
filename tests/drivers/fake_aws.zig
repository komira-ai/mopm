//! An `aws` for apt_publish_test.zig. It is a small S3, CloudFront and STS whose state is the directory $FAKE_AWS_DIR, and it
//! enforces the grants of the publish role (the shared repository's role policy), so a call the real role could not make fails here:
//!
//!   sts assume-role-with-web-identity --role-arn <arn> --role-session-name <n> --web-identity-token <jwt> ...
//!       Needs the token the fake `curl` hands out and, when $FAKE_AWS_ROLE is set, that role. Prints credentials.
//!   s3api get-object --bucket <b> --key <k> <outfile>
//!       Only below `apt/dists/` and the product's own pool `apt/pool/mopm/` (a Get below another product's pool is AccessDenied;
//!       so is every Get below the pool when the file `deny_pool_get` exists). A missing key is NoSuchKey, or AccessDenied when the file
//!       `deny_missing` exists (the role may not list the bucket). Prints {"ETag": ...}. When the file `bump_after_get` holds the key
//!       on a line, another writer "changes" that object right after this read (a new ETag), once.
//!   s3api put-object --bucket <b> --key <k> --body <file> (--if-match <etag> | --if-none-match '*')
//!       Below `apt/pool/mopm/` only with If-None-Match; below `apt/dists/` only with exactly one of the two headers; anything else
//!       is AccessDenied. If-None-Match on an existing key and If-Match on another ETag (or a missing key) are PreconditionFailed.
//!       When the file `fail_at_put` holds N, the N-th put (and any later one) fails with an InternalError and stores nothing: the write is
//!       interrupted there.
//!   cloudfront create-invalidation --distribution-id <id> --paths /apt/dists/*
//!       Fails when the file `invalidate_fail` exists.
//! Every call is appended to `log` (its arguments, space-joined, then the access key id in the environment).
//! Objects are the files `store/<key>`, their ETags the files `etag/<key>`.

const std = @import("std");

fn fail(code: u8, comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print(msg ++ "\n", .{}) catch {};
    std.process.exit(code);
}

fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn denied(op: []const u8) noreturn {
    std.io.getStdErr().writer().print("An error occurred (AccessDenied) when calling the {s} operation: Access Denied\n", .{op}) catch {};
    std.process.exit(254);
}

fn nextEtag(a: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    const old: []const u8 = dir.readFileAlloc(a, "counter", 64) catch "0";
    const n = (std.fmt.parseInt(u64, std.mem.trim(u8, old, "\n "), 10) catch 0) + 1;
    try dir.writeFile("counter", try std.fmt.allocPrint(a, "{d}\n", .{n}));
    return std.fmt.allocPrint(a, "\"e{d}\"", .{n});
}

fn store(a: std.mem.Allocator, dir: std.fs.Dir, key: []const u8, body: []const u8) ![]u8 {
    const etag = try nextEtag(a, dir);
    const sp = try std.fmt.allocPrint(a, "store/{s}", .{key});
    const ep = try std.fmt.allocPrint(a, "etag/{s}", .{key});
    if (std.fs.path.dirname(sp)) |d| try dir.makePath(d);
    if (std.fs.path.dirname(ep)) |d| try dir.makePath(d);
    try dir.writeFile(sp, body);
    try dir.writeFile(ep, etag);
    return etag;
}

fn etagJson(a: std.mem.Allocator, etag: []const u8) ![]u8 {
    // The ETag keeps its quotes, as S3 returns it: "\"e1\"" in JSON.
    return std.fmt.allocPrint(a, "{{\"ETag\": \"\\\"{s}\\\"\"}}\n", .{std.mem.trim(u8, etag, "\"")});
}

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
        try f.writer().print("{s} | key={s}\n", .{ try std.mem.join(a, " ", args), std.posix.getenv("AWS_ACCESS_KEY_ID") orelse "none" });
    }
    if (args.len < 2) fail(252, "aws: usage");
    const out = std.io.getStdOut().writer();
    const want_bucket = std.posix.getenv("FAKE_AWS_BUCKET");
    if (want_bucket) |wb| {
        if (flag(args, "--bucket")) |b| {
            if (!std.mem.eql(u8, b, wb)) fail(254, "An error occurred (NoSuchBucket): the bucket does not exist");
        }
    }

    if (std.mem.eql(u8, args[0], "sts") and std.mem.eql(u8, args[1], "assume-role-with-web-identity")) {
        const jwt = flag(args, "--web-identity-token") orelse fail(252, "aws: no token");
        if (!std.mem.eql(u8, jwt, "fake.jwt.token")) fail(254, "An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation");
        if (std.posix.getenv("FAKE_AWS_ROLE")) |want| {
            if (!std.mem.eql(u8, flag(args, "--role-arn") orelse "", want)) fail(254, "An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation: not authorized");
        }
        try out.writeAll("{\"AccessKeyId\": \"ASIAFAKEKEYID\", \"SecretAccessKey\": \"fakesecretaccesskey\", \"SessionToken\": \"fakesessiontoken\", \"Expiration\": \"2099-01-01T00:00:00+00:00\"}\n");
        return;
    }

    if (std.mem.eql(u8, args[0], "s3api") and std.mem.eql(u8, args[1], "get-object")) {
        const key = flag(args, "--key") orelse fail(252, "aws: no key");
        const outfile = args[args.len - 1];
        const own_pool = std.mem.startsWith(u8, key, "apt/pool/mopm/") and if (dir.access("deny_pool_get", .{})) |_| false else |_| true;
        if (!std.mem.startsWith(u8, key, "apt/dists/") and !own_pool) denied("GetObject");
        const sp = try std.fmt.allocPrint(a, "store/{s}", .{key});
        const body = dir.readFileAlloc(a, sp, 1 << 28) catch {
            if (dir.access("deny_missing", .{})) |_| denied("GetObject") else |_| {}
            fail(254, "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist.");
        };
        const etag = try dir.readFileAlloc(a, try std.fmt.allocPrint(a, "etag/{s}", .{key}), 256);
        try std.fs.cwd().writeFile(outfile, body);
        try out.writeAll(try etagJson(a, etag));
        // Another writer changes this object right after the read.
        if (dir.readFileAlloc(a, "bump_after_get", 1 << 16)) |lines| {
            var keep = std.ArrayList(u8).init(a);
            var hit = false;
            var it = std.mem.splitScalar(u8, lines, '\n');
            while (it.next()) |l| {
                if (l.len == 0) continue;
                if (!hit and std.mem.eql(u8, l, key)) {
                    hit = true;
                } else {
                    try keep.writer().print("{s}\n", .{l});
                }
            }
            if (hit) {
                _ = try store(a, dir, key, try std.mem.concat(a, u8, &.{ body, "X-Other-Writer: yes\n" }));
                try dir.writeFile("bump_after_get", keep.items);
            }
        } else |_| {}
        return;
    }

    if (std.mem.eql(u8, args[0], "s3api") and std.mem.eql(u8, args[1], "put-object")) {
        const key = flag(args, "--key") orelse fail(252, "aws: no key");
        const body_path = flag(args, "--body") orelse fail(252, "aws: no body");
        const if_match = flag(args, "--if-match");
        const if_none = flag(args, "--if-none-match");
        // The grants of the role: a .deb of the product only if absent; the index only conditionally.
        if (std.mem.startsWith(u8, key, "apt/pool/mopm/")) {
            if (if_none == null or if_match != null) denied("PutObject");
        } else if (std.mem.startsWith(u8, key, "apt/dists/")) {
            if ((if_none == null) == (if_match == null)) denied("PutObject");
        } else {
            denied("PutObject");
        }
        if (if_none) |v| {
            if (!std.mem.eql(u8, v, "*")) fail(252, "aws: --if-none-match must be *");
        }
        // The write is interrupted at the N-th put (the file `fail_at_put` holds N): that put and nothing after it is stored; the
        // call answers with a server error that is not a precondition failure.
        if (dir.readFileAlloc(a, "fail_at_put", 64)) |want| {
            const target = std.fmt.parseInt(u64, std.mem.trim(u8, want, "\n "), 10) catch fail(252, "aws: fail_at_put is not a number");
            const seen: []const u8 = dir.readFileAlloc(a, "put_count", 64) catch "0";
            const n = (std.fmt.parseInt(u64, std.mem.trim(u8, seen, "\n "), 10) catch 0) + 1;
            try dir.writeFile("put_count", try std.fmt.allocPrint(a, "{d}\n", .{n}));
            if (n >= target) fail(254, "An error occurred (InternalError) when calling the PutObject operation (reached max retries: 2): We encountered an internal error. Please try again.");
        } else |_| {}
        const sp = try std.fmt.allocPrint(a, "store/{s}", .{key});
        const have = dir.access(sp, .{});
        const cur_etag: ?[]const u8 = if (have) |_| try dir.readFileAlloc(a, try std.fmt.allocPrint(a, "etag/{s}", .{key}), 256) else |_| null;
        const pre = "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold";
        if (if_none != null and cur_etag != null) fail(254, pre);
        if (if_match) |m| {
            if (cur_etag == null or !std.mem.eql(u8, cur_etag.?, m)) fail(254, pre);
        }
        const body = try std.fs.cwd().readFileAlloc(a, body_path, 1 << 28);
        const etag = try store(a, dir, key, body);
        try out.writeAll(try etagJson(a, etag));
        return;
    }

    if (std.mem.eql(u8, args[0], "cloudfront") and std.mem.eql(u8, args[1], "create-invalidation")) {
        if (dir.access("invalidate_fail", .{})) |_| fail(254, "An error occurred (AccessDenied) when calling the CreateInvalidation operation") else |_| {}
        if (flag(args, "--distribution-id") == null) fail(252, "aws: no distribution");
        if (!std.mem.eql(u8, flag(args, "--paths") orelse "", "/apt/dists/*")) fail(252, "aws: unexpected paths");
        try out.writeAll("{}\n");
        return;
    }
    fail(252, "aws: unsupported call");
}
