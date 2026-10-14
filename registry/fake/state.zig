//! Everything the fake registry remembers, in memory for the life of the
//! process. Records are allocated one by one, so a pointer to a token, login
//! or user stays valid while lists grow. All memory comes from `alloc`, which
//! is never freed before exit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const util = @import("util.zig");

pub const day: i64 = 24 * 60 * 60;
/// A session token is fresh for 15 minutes and lives for 30 days.
pub const fresh_secs: i64 = 15 * 60;
pub const session_secs: i64 = 30 * day;
/// A device login expires after ten minutes; poll no faster than every 5 s.
pub const device_secs: i64 = 10 * 60;
pub const poll_interval: i64 = 5;
/// A claim with no version expires after 30 days; an invitation after 7.
pub const claim_secs: i64 = 30 * day;
pub const invitation_secs: i64 = 7 * day;
/// An OIDC publish token lives 15 minutes.
pub const oidc_secs: i64 = 15 * 60;

pub const User = struct { github_id: u64, handle: []const u8 };

pub const TokenKind = enum { session, api, oidc };

pub const Scope = enum { publish, yank };

pub const Token = struct {
    id: []const u8,
    secret: []const u8,
    kind: TokenKind,
    user: *User,
    /// API tokens only.
    name: []const u8 = "",
    scopes: []const Scope = &.{},
    /// The packages an API token may act on (for `all_current`, the snapshot).
    packages: []const []const u8 = &.{},
    all_current: bool = false,
    created_at: i64,
    expires_at: i64,
    /// Session tokens only: fresh (for owner and token changes) until then.
    fresh_until: i64 = 0,
    revoked: bool = false,
    last_used_at: ?i64 = null,
    /// OIDC tokens only: the one package and version they may publish.
    oidc_package: []const u8 = "",
    oidc_version: []const u8 = "",
};

pub const PackageState = enum { claimed, active };

pub const Package = struct {
    name: []const u8,
    state: PackageState = .claimed,
    owners: std.ArrayListUnmanaged(*User) = .{},
    /// Repositories (`owner/repo`) whose CI identity may publish it.
    trusted: std.ArrayListUnmanaged([]const u8) = .{},
    created_at: i64,
    updated_at: i64,
    claim_expires_at: i64,
    description: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    license: ?[]const u8 = null,

    pub fn isOwner(p: *const Package, u: *const User) bool {
        for (p.owners.items) |o| {
            if (o == u) return true;
        }
        return false;
    }
};

pub const Invitation = struct {
    id: []const u8,
    package: *Package,
    invitee: *User,
    inviter: *User,
    expires_at: i64,
    accepted: bool = false,
};

pub const Decision = enum { pending, approved, denied };

pub const DeviceLogin = struct {
    device_code: []const u8,
    user_code: []const u8,
    expires_at: i64,
    decision: Decision = .pending,
    /// Who approved it.
    user: ?*User = null,
    /// The session token handed out on the first approved poll.
    token: ?*Token = null,
};

/// A planted failure: the next request to `operation` answers `code`.
pub const Fault = struct { operation: []const u8, code: errors.Code };

pub const State = struct {
    alloc: Allocator,
    /// `http://127.0.0.1:<port>`: the API, the upload URLs and the files.
    base_url: []const u8,
    stage: []const u8,
    read_only: bool = false,
    /// Added to the wall clock: `/_fake/clock` moves time forward.
    clock_offset: i64 = 0,
    next_request: u64 = 1,
    next_github_id: u64 = 1000,
    users: std.ArrayListUnmanaged(*User) = .{},
    tokens: std.ArrayListUnmanaged(*Token) = .{},
    logins: std.ArrayListUnmanaged(*DeviceLogin) = .{},
    faults: std.ArrayListUnmanaged(Fault) = .{},
    packages: std.ArrayListUnmanaged(*Package) = .{},
    invitations: std.ArrayListUnmanaged(*Invitation) = .{},

    pub fn now(s: *const State) i64 {
        return std.time.timestamp() + s.clock_offset;
    }

    pub fn userByHandle(s: *State, handle: []const u8) ?*User {
        for (s.users.items) |u| {
            if (std.ascii.eqlIgnoreCase(u.handle, handle)) return u;
        }
        return null;
    }

    /// The GitHub account `handle`, made on first use (the fake's stand-in
    /// for GitHub's user directory).
    pub fn ensureUser(s: *State, handle: []const u8) Allocator.Error!*User {
        if (s.userByHandle(handle)) |u| return u;
        const u = try s.alloc.create(User);
        u.* = .{ .github_id = s.next_github_id, .handle = try s.alloc.dupe(u8, handle) };
        s.next_github_id += 1;
        try s.users.append(s.alloc, u);
        return u;
    }

    pub fn userById(s: *State, id: u64) ?*User {
        for (s.users.items) |u| {
            if (u.github_id == id) return u;
        }
        return null;
    }

    pub fn packageByName(s: *State, name: []const u8) ?*Package {
        for (s.packages.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn addPackage(s: *State, p: Package) Allocator.Error!*Package {
        const n = try s.alloc.create(Package);
        n.* = p;
        try s.packages.append(s.alloc, n);
        return n;
    }

    /// The names of the packages `user` owns, sorted.
    pub fn ownedNames(s: *State, arena: Allocator, user: *const User) Allocator.Error![]const []const u8 {
        var out = std.ArrayList([]const u8).init(arena);
        for (s.packages.items) |p| {
            if (p.isOwner(user)) try out.append(p.name);
        }
        std.mem.sort([]const u8, out.items, {}, lessString);
        return try out.toOwnedSlice();
    }

    pub fn addInvitation(s: *State, i: Invitation) Allocator.Error!*Invitation {
        const n = try s.alloc.create(Invitation);
        n.* = i;
        try s.invitations.append(s.alloc, n);
        return n;
    }

    /// `user`'s invitations that are neither accepted nor expired.
    pub fn pendingInvitations(s: *State, arena: Allocator, user: *const User) Allocator.Error![]const *Invitation {
        var out = std.ArrayList(*Invitation).init(arena);
        const now_ = s.now();
        for (s.invitations.items) |i| {
            if (i.invitee == user and !i.accepted and now_ < i.expires_at) try out.append(i);
        }
        return try out.toOwnedSlice();
    }

    pub fn tokenBySecret(s: *State, secret: []const u8) ?*Token {
        for (s.tokens.items) |t| {
            if (std.mem.eql(u8, t.secret, secret)) return t;
        }
        return null;
    }

    pub fn addToken(s: *State, t: Token) Allocator.Error!*Token {
        const p = try s.alloc.create(Token);
        p.* = t;
        try s.tokens.append(s.alloc, p);
        return p;
    }

    /// A session token for `user`, fresh unless `fresh` is false.
    pub fn newSession(s: *State, user: *User, fresh: bool) Allocator.Error!*Token {
        const now_ = s.now();
        return s.addToken(.{
            .id = try util.newId(s.alloc, "ses"),
            .secret = try util.newToken(s.alloc),
            .kind = .session,
            .user = user,
            .created_at = now_,
            .expires_at = now_ + session_secs,
            .fresh_until = if (fresh) now_ + fresh_secs else now_,
        });
    }

    pub fn loginByDeviceCode(s: *State, code: []const u8) ?*DeviceLogin {
        for (s.logins.items) |l| {
            if (std.mem.eql(u8, l.device_code, code)) return l;
        }
        return null;
    }

    pub fn loginByUserCode(s: *State, code: []const u8) ?*DeviceLogin {
        for (s.logins.items) |l| {
            if (std.mem.eql(u8, l.user_code, code)) return l;
        }
        return null;
    }

    pub fn addLogin(s: *State, l: DeviceLogin) Allocator.Error!*DeviceLogin {
        const p = try s.alloc.create(DeviceLogin);
        p.* = l;
        try s.logins.append(s.alloc, p);
        return p;
    }

    /// Removes and returns the planted failure for `operation`, if any.
    pub fn takeFault(s: *State, operation: []const u8) ?errors.Code {
        for (s.faults.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.operation, operation)) {
                _ = s.faults.orderedRemove(i);
                return f.code;
            }
        }
        return null;
    }
};

pub fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
