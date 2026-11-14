//! Everything the fake registry remembers, in memory for the life of the
//! process. Records are allocated one by one, so a pointer to a token, login
//! or user stays valid while lists grow. All memory comes from `alloc`, which
//! is never freed before exit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const util = @import("util.zig");
const names = @import("names.zig");

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
/// An OIDC publish token lives 10 minutes.
pub const oidc_secs: i64 = 10 * 60;
/// An upload URL expires five minutes after beginUpload.
pub const upload_secs: i64 = 5 * 60;
/// The largest file v1 takes.
pub const max_upload: u64 = 52428800;
/// The most bytes one package's live files (published and yanked versions) may hold: 10 GB.
pub const max_project: u64 = 10_000_000_000;

pub const User = struct {
    github_id: u64,
    /// The GitHub login it has now (`/_fake/rename` changes it).
    handle: []const u8,
    /// A CI identity of `/api/v2`'s OIDC exchange: the repository (`owner/repo`) it stands for. Null for a person.
    ci_repository: ?[]const u8 = null,
};

/// What GitHub says of a member of an organization: role and whether the membership is active (not pending).
pub const OrgRole = enum { admin, member, billing_manager };
pub const Membership = struct { user: *User, role: OrgRole, active: bool = true };

/// A GitHub organization, as the fake's stand-in for GitHub knows it (`/_fake/org`).
pub const Org = struct {
    /// The organization's login now.
    login: []const u8,
    github_id: u64,
    /// The installation of the mopm registry App on it, 0 when it is not installed; each install gets a new id.
    installation_id: u64 = 0,
    members: std.ArrayListUnmanaged(Membership) = .{},

    pub fn membership(o: *const Org, u: *const User) ?Membership {
        for (o.members.items) |m| {
            if (m.user == u) return m;
        }
        return null;
    }
};

pub const NamespaceKind = enum { user, org };

/// Whether an account may write in a namespace, and if not, why.
pub const Right = enum { write, not_member, frozen };

/// An owner namespace (docs/design/namespaces.md section 2): keyed by the GitHub id of its user or organization; its
/// name never changes, whatever the account is called on GitHub now.
pub const Namespace = struct {
    name: []const u8,
    kind: NamespaceKind,
    github_id: u64,
    created_at: i64,
    /// Organization namespaces: the organization, and the App installation an admin bound when creating it.
    org: ?*Org = null,
    installation_id: u64 = 0,
    /// Repositories (`owner/repo`) whose CI identity may write in it: its trusted publishers (`/_fake/trusted`).
    publishers: std.ArrayListUnmanaged([]const u8) = .{},

    /// An organization namespace whose bound installation is gone (the App uninstalled, or installed again and not yet
    /// bound): reads work, every write is refused.
    pub fn frozen(ns: *const Namespace) bool {
        if (ns.kind == .user) return false;
        const o = ns.org orelse return true;
        return o.installation_id == 0 or o.installation_id != ns.installation_id;
    }

    /// The right of `u` in it, checked live: a CI identity by the publishers; a person by being the user of a user
    /// namespace, or an active admin or member of the organization.
    pub fn right(ns: *const Namespace, u: *const User) Right {
        if (ns.frozen()) return .frozen;
        if (u.ci_repository) |repo| {
            for (ns.publishers.items) |r| {
                if (std.mem.eql(u8, r, repo)) return .write;
            }
            return .not_member;
        }
        return switch (ns.kind) {
            .user => if (u.github_id == ns.github_id) .write else .not_member,
            .org => {
                const m = ns.org.?.membership(u) orelse return .not_member;
                return if (m.active and m.role != .billing_manager) .write else .not_member;
            },
        };
    }

    /// The role `GET /api/v2/me` gives `u` in it: `owner` of their user namespace, GitHub's role in an organization's.
    pub fn role(ns: *const Namespace, u: *const User) []const u8 {
        if (ns.kind == .user) return "owner";
        return @tagName(ns.org.?.membership(u).?.role);
    }
};

pub const TokenKind = enum { session, api, oidc };

/// `stage` prepares a group (create, read, abort) and nothing else.
pub const Scope = enum { publish, yank, stage };

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
    oidc_repository: []const u8 = "",
    /// OIDC tokens of the `packages` form only: the package versions they may publish (they hold no `oidc_package`).
    oidc_set: []const NameVersion = &.{},
    /// OIDC tokens minted with `purpose: stage`: they prepare a group and never commit or yank.
    oidc_stage: bool = false,
};

pub const NameVersion = struct { name: []const u8, version: []const u8 };

/// `pending` while its publish runs; `rejected` burns the number.
pub const VersionState = enum { pending, published, yanked, tombstoned, rejected };

pub const File = struct {
    subdir: []const u8,
    filename: []const u8,
    /// Lowercase hex.
    sha256: []const u8,
    size: u64,
    /// Where the bytes are, under the data directory.
    path: []const u8,
};

pub const Version = struct {
    package: *Package,
    version: []const u8,
    state: VersionState = .pending,
    files: []const File,
    manifest_sha256: []const u8,
    published_at: i64 = 0,
    published_by: []const u8,
    yank_reason: ?[]const u8 = null,
    tombstone_reason: ?[]const u8 = null,
    tombstone_at: i64 = 0,
    /// The CI repository when published with an OIDC token.
    provenance: ?[]const u8 = null,
    /// The group that reserved this number (a `pending` row of a group), or null. The group may have ended: its
    /// rows are then free for another group or a single publish to take.
    group: ?*Group = null,
    /// The id of the group that published this version, kept after the group is visible (`group` is then null). getVersion shows it.
    group_id: ?[]const u8 = null,
    /// `source_commit` of the commit request that published this version: informational, never checked. Null when it had none.
    source_commit: ?[]const u8 = null,
    /// The readme text of the commit request that published this version, in either form. Null when it had none.
    readme: ?[]const u8 = null,

    /// Shown by getVersion and listed: every state but pending and rejected.
    pub fn visible(v: *const Version) bool {
        return v.state == .published or v.state == .yanked or v.state == .tombstoned;
    }
};

pub const Upload = struct {
    id: []const u8,
    user: *User,
    package: []const u8,
    version: []const u8,
    subdir: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
    expires_at: i64,
    /// Set by the PUT of the bytes.
    path: ?[]const u8 = null,
    used: bool = false,
};

pub const Publish = struct {
    id: []const u8,
    user: *User,
    version: *Version,
    upload_ids: []const []const u8,
    /// 0 pending, 1 validating, 2 indexing, 3 published; each status poll
    /// moves one step.
    stage: u8 = 0,
    rejection: ?[]const u8 = null,
};

/// Where a group is (the `GroupStatusName` of the contract).
pub const GroupStatus = enum { open, validating, committed, visible, rejected, failed, expired, aborted, superseded };

/// A group that has ended without committing: its numbers are free.
pub fn groupIsDead(s: GroupStatus) bool {
    return switch (s) {
        .rejected, .expired, .aborted, .superseded => true,
        else => false,
    };
}

pub const YankState = enum { yanking, yanked, unyanking, restored };

/// One declared file of a group member, and the upload that carries its bytes.
pub const GroupFile = struct {
    subdir: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
    upload: *Upload,
};

/// The readme a member declared at create, and the upload that carries its bytes.
pub const GroupReadme = struct { sha256: []const u8, size: u64, upload: *Upload };

pub const GroupMember = struct {
    package: *Package,
    version: []const u8,
    files: []const GroupFile,
    /// The row that holds the number (`pending` until the group is visible).
    row: *Version,
    manifest_sha256: []const u8 = "",
    /// `source_commit` of this member in the commit request, copied to its row when the group is visible.
    source_commit: ?[]const u8 = null,
    /// The readme declared at create (readme objects on), or null.
    readme: ?GroupReadme = null,
    /// The readme text of this member in the commit request, copied to its row when the group is visible.
    readme_text: ?[]const u8 = null,
    /// Set when the group's yank changed this member: an unyank restores these and no others.
    yanked_by_group: bool = false,
};

pub const GroupFailure = struct { code: []const u8, message: []const u8, member: ?[]const u8 = null };

pub const GroupYank = struct {
    state: YankState,
    reason: []const u8,
    requested_at: i64,
};

/// A set of versions declared up front and published together (spec/api/openapi.yaml, `createGroup`).
pub const Group = struct {
    id: []const u8,
    user: *User,
    attempt: u32 = 1,
    status: GroupStatus = .open,
    created_at: i64,
    deadline_at: i64,
    committed_at: i64 = 0,
    failure: ?GroupFailure = null,
    /// In package-name order.
    members: []GroupMember,
    /// What the commit request said, as one string; a different request for the same group is refused.
    commit_hash: []const u8 = "",
    yank: ?GroupYank = null,
};

pub const PackageState = enum { claimed, active };

pub const Package = struct {
    /// The v1 name, or the full name `<namespace>/<name>` of a package in a namespace.
    name: []const u8,
    /// The namespace of a package created through `/api/v2`; null for a v1 package.
    namespace: ?*Namespace = null,
    state: PackageState = .claimed,
    owners: std.ArrayListUnmanaged(*User) = .{},
    /// Repositories (`owner/repo`) whose CI identity may publish it.
    trusted: std.ArrayListUnmanaged([]const u8) = .{},
    versions: std.ArrayListUnmanaged(*Version) = .{},
    created_at: i64,
    updated_at: i64,
    claim_expires_at: i64,
    description: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    license: ?[]const u8 = null,

    /// Whether `u` may write it: an owner of a v1 package; for a package in a namespace, whoever may write in the
    /// namespace now (it has no owners of its own).
    pub fn isOwner(p: *const Package, u: *const User) bool {
        if (p.namespace) |ns| return ns.right(u) == .write;
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

/// A faulty failure: the next request to `operation` answers `code`.
pub const Fault = struct { operation: []const u8, code: errors.Code };

pub const State = struct {
    alloc: Allocator,
    /// `http://127.0.0.1:<port>`: the API, the upload URLs and the files.
    base_url: []const u8,
    /// The data directory (`--dir`): uploads, channel and index files.
    dir: []const u8 = ".",
    stage: []const u8,
    /// The `interval` a device login tells the client to poll at (seconds).
    poll_secs: i64 = poll_interval,
    read_only: bool = false,
    /// The per-project byte limit; `/_fake/limits` lowers it.
    project_bytes: u64 = max_project,
    /// Added to the wall clock: `/_fake/clock` moves time forward.
    clock_offset: i64 = 0,
    next_request: u64 = 1,
    /// Requests answered that were not a `/_fake/` control (uploads to `/_fake/upload/` count): `/_fake/requests` reads it.
    api_requests: u64 = 0,
    next_github_id: u64 = 1000,
    /// The id the next App installation (`/_fake/org`) gets.
    next_installation_id: u64 = 1,
    users: std.ArrayListUnmanaged(*User) = .{},
    tokens: std.ArrayListUnmanaged(*Token) = .{},
    logins: std.ArrayListUnmanaged(*DeviceLogin) = .{},
    faults: std.ArrayListUnmanaged(Fault) = .{},
    packages: std.ArrayListUnmanaged(*Package) = .{},
    /// Repositories the deployment trusts as CI publishers by configuration (`/_fake/ci_publisher`): the `packages` form
    /// of the OIDC exchange is for these, and it creates a package it is first to name.
    ci_repos: std.ArrayListUnmanaged([]const u8) = .{},
    invitations: std.ArrayListUnmanaged(*Invitation) = .{},
    uploads: std.ArrayListUnmanaged(*Upload) = .{},
    publishes: std.ArrayListUnmanaged(*Publish) = .{},
    groups: std.ArrayListUnmanaged(*Group) = .{},
    /// Owner namespaces, and the GitHub organizations the fake knows (`/_fake/org`).
    namespaces: std.ArrayListUnmanaged(*Namespace) = .{},
    orgs: std.ArrayListUnmanaged(*Org) = .{},
    /// Whether `/api/v1` still creates packages (`claimPackage`, and the OIDC `packages` form for a new name). Off
    /// (`/_fake/v1_creation`), both answer `name_reserved` with the hint to update mopm, as the registry does once
    /// package names are in namespaces.
    v1_creation: bool = true,
    /// Whether the registry has group publishing on. Off, `createGroup` answers `route_not_found`, as a registry that
    /// has not enabled groups for the caller does.
    groups_enabled: bool = true,
    /// How many `.conda` files `GET /channel/...` has answered 200 for (`/_fake/served`).
    conda_served: u64 = 0,
    /// Whether the registry takes a readme as an uploaded object (`/_fake/readme_objects`). Off, `/health` lists no features, a
    /// create ignores member `readme`, and a commit takes a readme as a string only.
    readme_objects: bool = true,
    /// The PUT of an upload answers 503 once, after this many more PUTs have succeeded (`/_fake/put_fault`).
    put_fault_after: ?u32 = null,
    /// The clock moves forward by this many seconds when the next group commit arrives, once (`/_fake/commit_clock`):
    /// time passing between the create and the commit.
    clock_jump_on_commit: i64 = 0,

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

    /// The names of the v1 packages `user` owns, sorted.
    pub fn ownedNames(s: *State, arena: Allocator, user: *const User) Allocator.Error![]const []const u8 {
        var out = std.ArrayList([]const u8).init(arena);
        for (s.packages.items) |p| {
            if (p.namespace == null and p.isOwner(user)) try out.append(p.name);
        }
        std.mem.sort([]const u8, out.items, {}, lessString);
        return try out.toOwnedSlice();
    }

    pub fn namespaceByName(s: *State, name: []const u8) ?*Namespace {
        for (s.namespaces.items) |ns| {
            if (std.mem.eql(u8, ns.name, name)) return ns;
        }
        return null;
    }

    /// The organization whose login is `login` now (GitHub logins ignore case).
    pub fn orgByLogin(s: *State, login: []const u8) ?*Org {
        for (s.orgs.items) |o| {
            if (std.ascii.eqlIgnoreCase(o.login, login)) return o;
        }
        return null;
    }

    /// The namespace `u`'s login names, lower-cased, when it fits the grammar; null when it does not.
    fn loginNamespaceName(buf: *[39]u8, u: *const User) ?[]const u8 {
        if (u.ci_repository != null or u.handle.len > buf.len) return null;
        const lower = std.ascii.lowerString(buf[0..u.handle.len], u.handle);
        if (!names.isNamespace(lower) or names.isReservedNamespace(lower)) return null;
        return lower;
    }

    /// At a login (docs/design/namespaces.md 2.1): `u`'s login, lower-cased, becomes `u`'s user namespace if no namespace
    /// has it and it fits the grammar and is not reserved. Answers the namespace of that name when it is `u`'s, else null.
    pub fn loginNamespace(s: *State, u: *User) Allocator.Error!?*Namespace {
        var buf: [39]u8 = undefined;
        const name = loginNamespaceName(&buf, u) orelse return null;
        if (s.namespaceByName(name)) |ns| return if (ns.kind == .user and ns.github_id == u.github_id) ns else null;
        return try s.add(Namespace, &s.namespaces, .{ .name = try s.alloc.dupe(u8, name), .kind = .user, .github_id = u.github_id, .created_at = s.now() });
    }

    /// `u`'s login when it cannot be `u`'s namespace: outside the grammar, reserved, or held by another account. Null when
    /// it is `u`'s namespace, or is free (made at the next login).
    pub fn unavailableNamespace(s: *State, u: *const User) ?[]const u8 {
        var buf: [39]u8 = undefined;
        const name = loginNamespaceName(&buf, u) orelse return u.handle;
        const ns = s.namespaceByName(name) orelse return null;
        return if (ns.kind == .user and ns.github_id == u.github_id) null else u.handle;
    }

    /// The account a `/api/v2` CI identity token acts as: one per repository.
    pub fn ciUser(s: *State, repository: []const u8) Allocator.Error!*User {
        for (s.users.items) |u| {
            if (u.ci_repository) |r| {
                if (std.mem.eql(u8, r, repository)) return u;
            }
        }
        const u = try s.add(User, &s.users, .{
            .github_id = s.next_github_id,
            .handle = try std.fmt.allocPrint(s.alloc, "ci:{s}", .{repository}),
            .ci_repository = try s.alloc.dupe(u8, repository),
        });
        s.next_github_id += 1;
        return u;
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

    /// Allocates `value` in `alloc` and appends it to `list`.
    pub fn add(s: *State, comptime T: type, list: *std.ArrayListUnmanaged(*T), value: T) Allocator.Error!*T {
        const n = try s.alloc.create(T);
        n.* = value;
        try list.append(s.alloc, n);
        return n;
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

    /// Removes and returns the faulty failure for `operation`, if any.
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
