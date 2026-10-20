//! A `cosign` for cut_release_test.zig. It signs nothing: a bundle is the text
//! `fake-cosign-bundle sha256=<hex of the file>`, so `verify-blob` accepts a bundle exactly when the
//! file it is given is the file that was "signed". Its state is the directory $FAKE_GH_DIR (the fake
//! gh's), where it appends every call (the arguments, space-joined) to `cosign_log`.
//!
//!   sign-blob --yes --bundle <bundle> <file>
//!       writes the bundle. Fails when the file `cosign_sign_fail` exists.
//!   verify-blob --bundle <bundle> --certificate-identity <id> --certificate-oidc-issuer <issuer>
//!               [--certificate-github-workflow-sha <sha>] --certificate-github-workflow-trigger <t>
//!               --certificate-github-workflow-repository <owner/name> <file>
//!       Fails when the identity, the issuer, the trigger or the repository is missing (a verification that pins nothing is
//!       not one), when the bundle does not name this file's sha256, or when `cosign_refuse` holds
//!       a name the file's path ends with (that file "has no valid signature").

const std = @import("std");

fn failWith(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("cosign: " ++ msg ++ "\n", .{}) catch {};
    std.process.exit(1);
}

fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn bundleText(a: std.mem.Allocator, file: []const u8) ![]u8 {
    const bytes = std.fs.cwd().readFileAlloc(a, file, 1 << 30) catch failWith("cannot read the file");
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "fake-cosign-bundle sha256={s}\n", .{std.fmt.bytesToHex(d, .lower)});
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const dir_path = std.posix.getenv("FAKE_GH_DIR") orelse @panic("FAKE_GH_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    {
        var f = try dir.createFile("cosign_log", .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writer().print("{s}\n", .{try std.mem.join(a, " ", argv[1..])});
    }
    const args = argv[1..];
    if (args.len < 2) failWith("usage");
    const file = args[args.len - 1];
    if (std.mem.eql(u8, args[0], "sign-blob")) {
        if (dir.access("cosign_sign_fail", .{})) |_| failWith("signing failed") else |_| {}
        var yes = false;
        for (args) |x| yes = yes or std.mem.eql(u8, x, "--yes");
        if (!yes) failWith("sign-blob needs --yes (it would ask a question)");
        const bundle = flag(args, "--bundle") orelse failWith("sign-blob needs --bundle");
        try std.fs.cwd().writeFile(bundle, try bundleText(a, file));
    } else if (std.mem.eql(u8, args[0], "verify-blob")) {
        const bundle = flag(args, "--bundle") orelse failWith("verify-blob needs --bundle");
        if (flag(args, "--certificate-identity") == null) failWith("verify-blob needs --certificate-identity");
        if (flag(args, "--certificate-oidc-issuer") == null) failWith("verify-blob needs --certificate-oidc-issuer");
        if (flag(args, "--certificate-github-workflow-trigger") == null) failWith("verify-blob needs --certificate-github-workflow-trigger");
        if (flag(args, "--certificate-github-workflow-repository") == null) failWith("verify-blob needs --certificate-github-workflow-repository");
        if (dir.readFileAlloc(a, "cosign_refuse", 1 << 16)) |refused| {
            if (std.mem.endsWith(u8, file, std.mem.trim(u8, refused, " \n"))) failWith("no matching signatures");
        } else |_| {}
        const have = std.fs.cwd().readFileAlloc(a, bundle, 1 << 20) catch failWith("cannot read the bundle");
        if (!std.mem.eql(u8, have, try bundleText(a, file))) failWith("invalid signature when validating ASN.1 encoded signature");
    } else {
        std.debug.print("fake cosign: unexpected call: {s}\n", .{args[0]});
        std.process.exit(3);
    }
}
