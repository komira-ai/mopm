//! The `gpg` command lines that sign the index. Pure: they build argument lists, they run nothing.
//!
//! The index is signed with the SIGNING SUBKEY of the archive key: the key spec is the subkey's fingerprint followed by
//! `!`, which makes gpg use exactly that key and no other. The passphrase is never an argument (arguments are readable by
//! every process of the machine): it is given as a file, with the loopback pinentry.

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

/// `InRelease`: the Release with its signature around it.
pub fn clearsignArgs(a: Allocator, gpg: []const u8, home: []const u8, fpr: []const u8, pass_file: []const u8, input: []const u8, output: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--pinentry-mode", "loopback", "--passphrase-file", pass_file, "--digest-algo", "SHA512", "--local-user", try exactKey(a, fpr), "--armor", "--clearsign", "--output", output, input });
    return v.items;
}

/// `Release.gpg`: the signature alone.
pub fn detachArgs(a: Allocator, gpg: []const u8, home: []const u8, fpr: []const u8, pass_file: []const u8, input: []const u8, output: []const u8) ![]const []const u8 {
    var v = try base(a, gpg, home);
    try v.appendSlice(&.{ "--pinentry-mode", "loopback", "--passphrase-file", pass_file, "--digest-algo", "SHA512", "--local-user", try exactKey(a, fpr), "--armor", "--detach-sign", "--output", output, input });
    return v.items;
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
    const clear = try clearsignArgs(a, "gpg", "/h", "ABCDEF0123456789", "/h/pass", "Release", "InRelease");
    try t.expect(contains(clear, "ABCDEF0123456789!"));
    try t.expect(contains(clear, "--clearsign"));
    try t.expect(contains(clear, "--passphrase-file"));
    try t.expect(contains(clear, "loopback"));
    try t.expect(!contains(clear, "--passphrase"));
    const det = try detachArgs(a, "gpg", "/h", "ABCDEF0123456789", "/h/pass", "Release", "Release.gpg");
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
