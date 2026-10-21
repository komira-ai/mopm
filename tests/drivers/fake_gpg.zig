//! A `gpg` for apt_publish_test.zig. It signs nothing: a signature is a text that names the sha256 of what it covers and the key spec,
//! so `--verify` accepts a signature exactly when the file is the one that was "signed". State and settings:
//!   $FAKE_GPG_DIR   where it appends every call (the arguments, space-joined) to `log` and the home directory of each call to `homes`.
//!                   A file `sign_fail` there makes every signature fail; a file `bad_detached` makes the detached signature cover other bytes, so
//!                   it does not verify.
//!   $FAKE_GPG_KEY   the exact bytes the key file must hold for --import to accept it
//!   $FAKE_GPG_FPR   the fingerprint of the signing subkey, or several separated by commas: --list-secret-keys finds only those; --local-user must be given
//!                   once for each, in that order, each followed by `!`, and for no other key
//!   $FAKE_GPG_PASS  the passphrase the passphrase file must hold (the loopback pinentry); a signature without one is refused
//! It also refuses a home directory that others can read (gpg warns about it, and the key is in it).

const std = @import("std");

fn fail(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("gpg: " ++ msg ++ "\n", .{}) catch {};
    std.process.exit(2);
}

fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn has(args: []const []const u8, name: []const u8) bool {
    for (args) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

fn sha(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn sigText(a: std.mem.Allocator, covered: []const u8, user: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "-----BEGIN PGP SIGNATURE-----\nfake sha256={s} key={s}\n-----END PGP SIGNATURE-----\n", .{ sha(covered), user });
}

const clear_head = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n";
const sig_begin = "-----BEGIN PGP SIGNATURE-----\n";

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const args = argv[1..];
    const dir_path = std.posix.getenv("FAKE_GPG_DIR") orelse @panic("FAKE_GPG_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const home = flag(args, "--homedir") orelse fail("no --homedir");
    {
        var f = try dir.createFile("log", .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writer().print("{s}\n", .{try std.mem.join(a, " ", args)});
        var h = try dir.createFile("homes", .{ .truncate = false });
        defer h.close();
        try h.seekFromEnd(0);
        try h.writer().print("{s}\n", .{home});
    }
    const st = std.fs.cwd().statFile(home) catch fail("the home directory does not exist");
    if (st.mode & 0o077 != 0) fail("unsafe permissions on homedir");
    if (!has(args, "--batch") or !has(args, "--no-tty")) fail("not batch: it would ask a question");

    if (flag(args, "--import")) |key_file| {
        const bytes = try std.fs.cwd().readFileAlloc(a, key_file, 1 << 20);
        if (std.posix.getenv("FAKE_GPG_KEY")) |want| {
            if (!std.mem.eql(u8, bytes, want)) fail("no valid OpenPGP data found.");
        }
        const kst = try std.fs.cwd().statFile(key_file);
        if (kst.mode & 0o077 != 0) fail("the key file is readable by others");
        try std.fs.cwd().writeFile(try std.fmt.allocPrint(a, "{s}/imported", .{home}), "yes");
        return;
    }
    if (has(args, "--list-secret-keys")) {
        _ = std.fs.cwd().statFile(try std.fmt.allocPrint(a, "{s}/imported", .{home})) catch fail("no secret key");
        // $FAKE_GPG_FPR is one fingerprint or a comma-separated list: the key asked for must be one of them.
        const want = std.posix.getenv("FAKE_GPG_FPR") orelse "";
        var wants = std.mem.splitScalar(u8, want, ',');
        var found = false;
        while (wants.next()) |x| {
            if (std.ascii.eqlIgnoreCase(args[args.len - 1], x)) found = true;
        }
        if (!found) fail("error reading key: No secret key");
        return;
    }
    if (has(args, "--clearsign") or has(args, "--detach-sign")) {
        if (dir.access("sign_fail", .{})) |_| fail("signing failed: Inappropriate ioctl for device") else |_| {}
        // One `--local-user <fpr>!` per signing key, in the order of $FAKE_GPG_FPR (one fingerprint, or several separated by commas), no more and no fewer.
        var users = std.ArrayList([]const u8).init(a);
        for (args, 0..) |x, i| {
            if (std.mem.eql(u8, x, "--local-user") and i + 1 < args.len) try users.append(args[i + 1]);
        }
        if (users.items.len == 0) fail("no --local-user");
        const want = std.posix.getenv("FAKE_GPG_FPR") orelse "";
        var wants = std.mem.splitScalar(u8, want, ',');
        var n: usize = 0;
        while (wants.next()) |w| : (n += 1) {
            if (n >= users.items.len) fail("signing key spec is missing a subkey");
            const u = users.items[n];
            if (u.len != w.len + 1 or u[u.len - 1] != '!' or !std.ascii.eqlIgnoreCase(u[0..w.len], w)) fail("signing key spec is not the subkey with !");
        }
        if (n != users.items.len) fail("signing key spec has a key that is not a signing subkey");
        const user = try std.mem.join(a, ",", users.items);
        const mode = flag(args, "--pinentry-mode") orelse "";
        const pf = flag(args, "--passphrase-file") orelse fail("no passphrase file");
        if (!std.mem.eql(u8, mode, "loopback")) fail("the pinentry would ask");
        const pass = try std.fs.cwd().readFileAlloc(a, pf, 1 << 16);
        if (std.posix.getenv("FAKE_GPG_PASS")) |wp| {
            if (!std.mem.eql(u8, pass, wp)) fail("bad passphrase");
        }
        const input = try std.fs.cwd().readFileAlloc(a, args[args.len - 1], 1 << 28);
        const output = flag(args, "--output") orelse fail("no --output");
        // `bad_detached`: the detached signature covers other bytes than the Release (a signature that does not verify).
        const bad = has(args, "--detach-sign") and blk: {
            dir.access("bad_detached", .{}) catch break :blk false;
            break :blk true;
        };
        const covered: []const u8 = if (bad) "not the release" else input;
        const sig = try sigText(a, covered, user);
        const data = if (has(args, "--clearsign")) try std.mem.concat(a, u8, &.{ clear_head, input, sig }) else sig;
        try std.fs.cwd().writeFile(output, data);
        return;
    }
    if (flag(args, "--verify")) |first| {
        // `--verify <signed>` or `--verify <sig> <data>`: the sub-slice after --verify.
        var at: usize = 0;
        for (args, 0..) |x, i| {
            if (std.mem.eql(u8, x, "--verify")) at = i;
        }
        const files = args[at + 1 ..];
        const sig_bytes = try std.fs.cwd().readFileAlloc(a, first, 1 << 28);
        if (files.len == 1) {
            if (!std.mem.startsWith(u8, sig_bytes, clear_head)) fail("BAD signature: not clearsigned");
            const split = std.mem.indexOf(u8, sig_bytes, sig_begin) orelse fail("BAD signature");
            const covered = sig_bytes[clear_head.len..split];
            const want = try std.fmt.allocPrint(a, "fake sha256={s}", .{sha(covered)});
            if (std.mem.indexOf(u8, sig_bytes[split..], want) == null) fail("BAD signature from the key");
        } else {
            const data = try std.fs.cwd().readFileAlloc(a, files[1], 1 << 28);
            const want = try std.fmt.allocPrint(a, "fake sha256={s}", .{sha(data)});
            if (std.mem.indexOf(u8, sig_bytes, want) == null) fail("BAD signature from the key");
        }
        return;
    }
    fail("unsupported call");
}
