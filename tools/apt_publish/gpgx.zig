//! The `gpg` command lines that sign the index. Pure: they build argument lists, they run nothing.
//!
//! The index is signed with the SIGNING SUBKEY of the archive key: the key spec is the subkey's fingerprint followed by
//! `!`, which makes gpg use exactly that key and no other. The passphrase is never an argument (arguments are readable by
//! every process of the machine): it is given as a file, with the loopback pinentry.
//!
//! A key rotation signs with two subkeys at once (the old one, which the keyrings already installed trust, and the new one): the fingerprint setting may
//! be a comma-separated list, and the signing command then carries one `--local-user <fingerprint>!` for each, for the clear signature (InRelease) and
//! the detached one (Release.gpg) alike. One fingerprint is the list of one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{BadFingerprint};

/// A fingerprint as hex digits (the spaces gpg prints between groups are tolerated), at least 16 of them. Returns the
/// upper-case fingerprint without spaces.
pub fn cleanFingerprint(a: Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (raw) |ch| {
        if (ch == ' ') continue;
        if (!std.ascii.isHex(ch)) return error.BadFingerprint;
        try out.append(std.ascii.toUpper(ch));
    }
    if (out.items.len < 16) return error.BadFingerprint;
    return out.items;
}

/// The fingerprints of the signing subkeys: one, or several separated by commas (a key rotation signs with the old and the new one at once). Each
/// is cleaned as `cleanFingerprint` does; a list that is empty, has an empty element (a trailing comma) or names a key twice is refused.
pub fn splitFingerprints(a: Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const fpr = try cleanFingerprint(a, part);
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, fpr)) return error.BadFingerprint;
        }
        try out.append(fpr);
    }
    return out.items;
}

/// `<fingerprint>!`: exactly this (sub)key.
pub fn exactKey(a: Allocator, fpr: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}!", .{fpr});
}

fn base(a: Allocator, gpg: []const u8, home: []const u8) !std.ArrayList([]const u8) {
    var v = std.ArrayList([]const u8).init(a);
    try v.appendSlice(&.{ gpg, "--homedir", home, "--batch", "--no-tty", "--yes" });
    return v;
}

pub fn importArgs(a: Allocator, gpg: []const u8, home: []const u8, key_file: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--import", key_file });
    return v.items;
}

/// Is the key there as a secret key? (Exit 0 only when it is.)
pub fn listArgs(a: Allocator, gpg: []const u8, home: []const u8, fpr: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--list-secret-keys", "--with-colons", fpr });
    return v.items;
}

/// The signing command line: one `--local-user <fingerprint>!` for each key, in the order given, so the output carries one signature per key
/// (during a key rotation the index is signed by the old and the new subkey, and a client that trusts either verifies it).
fn signArgs(a: Allocator, gpg: []const u8, home: []const u8, fprs: []const []const u8, pass_file: []const u8, mode: []const u8, input: []const u8, output: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--pinentry-mode", "loopback", "--passphrase-file", pass_file, "--digest-algo", "SHA512" });
    for (fprs) |fpr| try v.appendSlice(&.{ "--local-user", try exactKey(a, fpr) });
    try v.appendSlice(&.{ "--armor", mode, "--output", output, input });
    return v.items;
}

/// `InRelease`: the Release with its signature (one per key) around it.
pub fn clearsignArgs(a: Allocator, gpg: []const u8, home: []const u8, fprs: []const []const u8, pass_file: []const u8, input: []const u8, output: []const u8) ![]const []const u8 {
    return signArgs(a, gpg, home, fprs, pass_file, "--clearsign", input, output);
}

/// `Release.gpg`: the signatures alone, one per key.
pub fn detachArgs(a: Allocator, gpg: []const u8, home: []const u8, fprs: []const []const u8, pass_file: []const u8, input: []const u8, output: []const u8) ![]const []const u8 {
    return signArgs(a, gpg, home, fprs, pass_file, "--detach-sign", input, output);
}

pub fn verifyClearArgs(a: Allocator, gpg: []const u8, home: []const u8, signed: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--verify", signed });
    return v.items;
}

pub fn verifyDetachedArgs(a: Allocator, gpg: []const u8, home: []const u8, sig: []const u8, input: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--verify", sig, input });
    return v.items;
}

const t = std.testing;

test "cleanFingerprint: hex digits, upper case, spaces dropped, at least 16" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("0123456789ABCDEF", try cleanFingerprint(a, "0123 4567 89ab cdef"));
    try t.expectError(error.BadFingerprint, cleanFingerprint(a, "0123"));
    try t.expectError(error.BadFingerprint, cleanFingerprint(a, "0123456789ABCDEG"));
    try t.expectError(error.BadFingerprint, cleanFingerprint(a, "0123456789ABCDEF!"));
    try t.expectError(error.BadFingerprint, cleanFingerprint(a, ""));
}

fn contains(args: []const []const u8, want: []const u8) bool {
    for (args) |x| {
        if (std.mem.eql(u8, x, want)) return true;
    }
    return false;
}

test "signing uses exactly the subkey, a passphrase file and the loopback pinentry, and never a passphrase argument" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clear = try clearsignArgs(a, "gpg", "/h", &.{"ABCDEF0123456789"}, "/h/pass", "Release", "InRelease");
    try t.expect(contains(clear, "ABCDEF0123456789!"));
    try t.expect(contains(clear, "--clearsign"));
    try t.expect(contains(clear, "--passphrase-file"));
    try t.expect(contains(clear, "loopback"));
    try t.expect(!contains(clear, "--passphrase"));
    const det = try detachArgs(a, "gpg", "/h", &.{"ABCDEF0123456789"}, "/h/pass", "Release", "Release.gpg");
    try t.expect(contains(det, "--detach-sign"));
    try t.expect(contains(det, "ABCDEF0123456789!"));
    try t.expect(!contains(det, "--passphrase"));
    try t.expectEqualStrings("gpg", clear[0]);
    try t.expectEqualStrings("Release", clear[clear.len - 1]);
}

test "import, list and verify command lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(contains(try importArgs(a, "gpg", "/h", "/h/key"), "--import"));
    try t.expect(contains(try listArgs(a, "gpg", "/h", "ABCDEF0123456789"), "--list-secret-keys"));
    const v1 = try verifyClearArgs(a, "gpg", "/h", "InRelease");
    try t.expectEqualStrings("InRelease", v1[v1.len - 1]);
    const v2 = try verifyDetachedArgs(a, "gpg", "/h", "Release.gpg", "Release");
    try t.expectEqualStrings("Release.gpg", v2[v2.len - 2]);
    try t.expectEqualStrings("Release", v2[v2.len - 1]);
    try t.expect(contains(v2, "--homedir"));
}

/// The values after each `--local-user`, in order.
fn localUsers(a: Allocator, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, "--local-user")) try out.append(args[i + 1]);
    }
    return out.items;
}

test "splitFingerprints: one fingerprint is a list of one; several are split at commas, cleaned, in order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try splitFingerprints(a, "0123456789abcdef");
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expectEqualStrings("0123456789ABCDEF", one[0]);
    const two = try splitFingerprints(a, "0123 4567 89ab cdef,FEDCBA9876543210");
    try t.expectEqual(@as(usize, 2), two.len);
    try t.expectEqualStrings("0123456789ABCDEF", two[0]);
    try t.expectEqualStrings("FEDCBA9876543210", two[1]);
    const three = try splitFingerprints(a, "AAAAAAAAAAAAAAAA, BBBBBBBBBBBBBBBB ,CCCCCCCCCCCCCCCC");
    try t.expectEqual(@as(usize, 3), three.len);
    try t.expectEqualStrings("BBBBBBBBBBBBBBBB", three[1]);
}

test "splitFingerprints refuses an empty list, an empty element, a bad element and the same key twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",
        ",",
        "0123456789ABCDEF,",
        ",0123456789ABCDEF",
        "0123456789ABCDEF,,FEDCBA9876543210",
        "0123456789ABCDEF,short",
        "0123456789ABCDEF,FEDCBA987654321G",
        "0123456789ABCDEF,0123456789abcdef",
        "0123456789ABCDEF;FEDCBA9876543210",
    }) |bad| {
        try t.expectError(error.BadFingerprint, splitFingerprints(a, bad));
    }
}

test "two keys: one --local-user <fpr>! for each, in order, for the clear signature and the detached one alike" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = [_][]const u8{ "0123456789ABCDEF", "FEDCBA9876543210" };
    const clear = try clearsignArgs(a, "gpg", "/h", &keys, "/h/pass", "Release", "InRelease");
    const det = try detachArgs(a, "gpg", "/h", &keys, "/h/pass", "Release", "Release.gpg");
    for ([_][]const []const u8{ clear, det }) |args| {
        const users = try localUsers(a, args);
        try t.expectEqual(@as(usize, 2), users.len);
        try t.expectEqualStrings("0123456789ABCDEF!", users[0]);
        try t.expectEqualStrings("FEDCBA9876543210!", users[1]);
        // The rest of the line is what it is for one key: the loopback pinentry, the passphrase as a file, SHA512, armor.
        try t.expect(contains(args, "loopback"));
        try t.expect(contains(args, "--passphrase-file"));
        try t.expect(contains(args, "SHA512"));
        try t.expect(contains(args, "--armor"));
        try t.expect(!contains(args, "--passphrase"));
    }
    try t.expect(contains(clear, "--clearsign") and !contains(clear, "--detach-sign"));
    try t.expect(contains(det, "--detach-sign") and !contains(det, "--clearsign"));
    try t.expectEqualStrings("Release", clear[clear.len - 1]);
    try t.expectEqualStrings("InRelease", clear[clear.len - 2]);
    try t.expectEqualStrings("Release.gpg", det[det.len - 2]);
    // One key: exactly one --local-user, as before.
    const single = try clearsignArgs(a, "gpg", "/h", keys[0..1], "/h/pass", "Release", "InRelease");
    try t.expectEqual(@as(usize, 1), (try localUsers(a, single)).len);
}
