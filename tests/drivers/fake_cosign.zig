//! A `cosign` for cut_release_test.zig. It signs nothing: a bundle is the text
//! `fake-cosign-bundle sha256=<hex of the file>`, so `verify-blob` accepts a bundle exactly when the
//! file it is given is the file that was "signed". Its state is the directory $FAKE_GH_DIR (the fake
//! gh's), where it appends every call (the arguments, space-joined) to `cosign_log`.
//!
//!   sign-blob --yes --bundle <bundle> <file>
//!       writes the bundle, which records the trigger $FAKE_COSIGN_TRIGGER (default push). Fails when the file `cosign_sign_fail` exists.
//!   verify-blob --bundle <bundle> --certificate-identity <id> --certificate-oidc-issuer <issuer>
//!               [--certificate-github-workflow-sha <sha>] --certificate-github-workflow-trigger <t>
//!               --certificate-github-workflow-repository <owner/name> <file>
//!       Fails when the identity, the issuer, the trigger or the repository is missing (a verification that pins nothing is
//!       not one), when the bundle does not name this file's sha256 and exactly the trigger asked for, or when `cosign_refuse` holds
//!       a name the file's path ends with (that file "has no valid signature").
//!       Before all of that it fails with the trusted-root (TUF) fetch error, for the first N calls, when the file `cosign_tuf_fail` holds N.

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

/// The bundle also records the event of the signing run (the certificate's trigger).
fn bundleText(a: std.mem.Allocator, file: []const u8, trigger: []const u8) ![]u8 {
    const bytes = std.fs.cwd().readFileAlloc(a, file, 1 << 30) catch failWith("cannot read the file");
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "fake-cosign-bundle sha256={s} trigger={s}\n", .{ std.fmt.bytesToHex(d, .lower), trigger });
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
        // The signing run's event: push unless $FAKE_COSIGN_TRIGGER says otherwise (a dry run).
        try std.fs.cwd().writeFile(bundle, try bundleText(a, file, std.posix.getenv("FAKE_COSIGN_TRIGGER") orelse "push"));
    } else if (std.mem.eql(u8, args[0], "verify-blob")) {
        const bundle = flag(args, "--bundle") orelse failWith("verify-blob needs --bundle");
        // A flaky network: the first N verify-blob calls (N in `cosign_tuf_fail`, counted down on disk) cannot fetch the trusted root.
        if (dir.readFileAlloc(a, "cosign_tuf_fail", 1 << 8)) |counted| {
            const left = std.fmt.parseInt(u32, std.mem.trim(u8, counted, " \n"), 10) catch 0;
            if (left > 0) {
                try dir.writeFile("cosign_tuf_fail", try std.fmt.allocPrint(a, "{d}\n", .{left - 1}));
                failWith("WARNING: Could not fetch trusted_root.json from the TUF repository: tuf refresh failed: Get https://tuf-repo-cdn.sigstore.dev/timestamp.json: dial tcp: i/o timeout\nError: trusted root is required when using new bundle format");
            }
        } else |_| {}
        if (flag(args, "--certificate-identity") == null) failWith("verify-blob needs --certificate-identity");
        if (flag(args, "--certificate-oidc-issuer") == null) failWith("verify-blob needs --certificate-oidc-issuer");
        const trigger = flag(args, "--certificate-github-workflow-trigger") orelse failWith("verify-blob needs --certificate-github-workflow-trigger");
        if (flag(args, "--certificate-github-workflow-repository") == null) failWith("verify-blob needs --certificate-github-workflow-repository");
        if (dir.readFileAlloc(a, "cosign_refuse", 1 << 16)) |refused| {
            if (std.mem.endsWith(u8, file, std.mem.trim(u8, refused, " \n"))) failWith("no matching signatures");
        } else |_| {}
        const have = std.fs.cwd().readFileAlloc(a, bundle, 1 << 20) catch failWith("cannot read the bundle");
        if (!std.mem.eql(u8, have, try bundleText(a, file, trigger))) failWith("invalid signature when validating ASN.1 encoded signature");
    } else {
        std.debug.print("fake cosign: unexpected call: {s}\n", .{args[0]});
        std.process.exit(3);
    }
}
