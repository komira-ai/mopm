//! The pieces of a createGroup request that name a group and its uploads: the parsed member and file, the checks of a hash and a
//! subdir, and the derivation of a group id and an upload id (the fake's own: a client does not compute them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const channel = @import("files.zig");
const gr = @import("group_readmes.zig");

const subdirs = channel.subdirs;

pub const ReqFile = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
pub const ReqMember = struct { name: []const u8, version: []const u8, files: []ReqFile, readme: ?gr.Ref = null };

pub fn isSha(s: []const u8) bool {
    return s.len == 64 and isHex(s);
}

/// The `GroupId` pattern: `grp_` and 32 lowercase hex digits.
pub fn isGroupId(s: []const u8) bool {
    return s.len == 36 and std.mem.startsWith(u8, s, "grp_") and isHex(s[4..]);
}

pub fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

pub fn isSubdir(s: []const u8) bool {
    for (subdirs) |d| {
        if (std.mem.eql(u8, d, s)) return true;
    }
    return false;
}

pub fn memberLess(_: void, a: ReqMember, b: ReqMember) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn fileLess(_: void, a: ReqFile, b: ReqFile) bool {
    const o = std.mem.order(u8, a.subdir, b.subdir);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.filename, b.filename) == .lt;
}

/// `grp_` and 32 hex digits: a hash of the caller and the declared set.
pub fn groupId(arena: Allocator, handle: []const u8, members: []const ReqMember) Allocator.Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(handle);
    h.update("\n");
    for (members) |m| {
        h.update(m.name);
        h.update("\n");
        h.update(m.version);
        h.update("\n");
        for (m.files) |f| {
            const line = try std.fmt.allocPrint(arena, "{s}/{s}:{s}:{d}\n", .{ f.subdir, f.filename, f.sha256, f.size });
            h.update(line);
        }
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "grp_{s}", .{std.fmt.fmtSliceHexLower(digest[0..16])});
}

/// The id of the upload that carries one declared file; the same on every call, so a resume finds it.
pub fn uploadId(arena: Allocator, gid: []const u8, m: ReqMember, f: ReqFile) Allocator.Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const line = try std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}/{s}|{s}|{d}", .{ gid, m.name, m.version, f.subdir, f.filename, f.sha256, f.size });
    h.update(line);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "upl_{s}", .{std.fmt.fmtSliceHexLower(digest[0..12])});
}

