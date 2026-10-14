//! Publishing (begin an upload, PUT the bytes, commit, poll the status),
//! yank, and the version detail.
//!
//! The fake runs a publish's checks as its status is polled: each poll moves
//! it one stage (pending, validating, indexing, published). It checks that
//! each file name names the package and version (`filename_mismatch`); it
//! does not open archives, so a file whose bytes start with
//! `REJECT:<rejection code>` is rejected with that code, which lets a client
//! test every rejection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const auth = @import("auth.zig");
const versions = @import("versions.zig");

const subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" };

const rejection_codes = [_][]const u8{
    "archive_invalid",  "path_not_allowed", "limit_exceeded",         "manifest_invalid",
    "filename_mismatch", "sha256_mismatch", "dependency_not_allowed",
};

// ---------------------------------------------------------------------------
// Tokens that may publish or yank
// ---------------------------------------------------------------------------

/// A token that may act on `name` (and `version`, for an OIDC token) with one
/// of `scopes`, or the error to answer. `scope` names the scope in that error.
fn scoped(ctx: *Ctx, name: []const u8, version: ?[]const u8, scopes: []const st.Scope, scope: []const u8) anyerror!auth.Auth {
    const a = try auth.authenticate(ctx);
    const t = switch (a) {
        .ok => |t| t,
        .fail => return a,
    };
    const ok = switch (t.kind) {
        .session => false,
        .api => blk: {
            var has_scope = false;
            for (t.scopes) |sc| {
                if (std.mem.indexOfScalar(st.Scope, scopes, sc) != null) has_scope = true;
            }
            var covers = false;
            for (t.packages) |p| {
                if (std.mem.eql(u8, p, name)) covers = true;
            }
            break :blk has_scope and covers;
        },
        .oidc => std.mem.indexOfScalar(st.Scope, scopes, .publish) != null and
            std.mem.eql(u8, t.oidc_package, name) and
            (version == null or versions.same(t.oidc_version, version.?)),
    };
    if (!ok) return .{ .fail = try resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", scope }, .{ "name", name } }) };
    return a;
}

/// Checks the `{name}` and `{version}` of a path: `invalid_name`,
/// `invalid_version`, `package_not_found`.
const Target = union(enum) { ok: *st.Package, fail: Response };

fn target(ctx: *Ctx, name: []const u8, version: []const u8) Allocator.Error!Target {
    if (!util.isName(name)) return .{ .fail = try resp.fail(ctx.arena, .invalid_name, &.{.{ "name", name }}) };
    if (!util.isVersion(version)) return .{ .fail = try resp.fail(ctx.arena, .invalid_version, &.{.{ "version", version }}) };
    const p = ctx.state.packageByName(name) orelse return .{ .fail = try resp.fail(ctx.arena, .package_not_found, &.{.{ "name", name }}) };
    return .{ .ok = p };
}

/// The version of `p` equal to `version` under conda ordering, in any state.
fn findVersion(p: *st.Package, version: []const u8) ?*st.Version {
    for (p.versions.items) |v| {
        if (versions.same(v.version, version)) return v;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Upload and commit
// ---------------------------------------------------------------------------

pub fn beginUpload(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const s = ctx.state;
    if (s.read_only) return resp.fail(ctx.arena, .read_only_mode, &.{});
    const t = switch (try scoped(ctx, params[0], params[1], &.{.publish}, "publish")) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const p = switch (try target(ctx, params[0], params[1])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const subdir = util.getStr(obj, "subdir") orelse return resp.invalid(ctx.arena, "'subdir' must be a string");
    for (subdirs) |d| {
        if (std.mem.eql(u8, d, subdir)) break;
    } else return resp.invalid(ctx.arena, "'subdir' is not a known subdir");
    const filename = util.getStr(obj, "filename") orelse return resp.invalid(ctx.arena, "'filename' must be a string");
    if (!std.mem.startsWith(u8, filename, "mojo-") or !std.mem.endsWith(u8, filename, ".conda")) {
        return resp.invalid(ctx.arena, "'filename' is mojo-<name>-<version>-<build>.conda");
    }
    const sha256 = util.getStr(obj, "sha256") orelse return resp.invalid(ctx.arena, "'sha256' must be a string");
    if (sha256.len != 64) return resp.invalid(ctx.arena, "'sha256' is 64 lowercase hex digits");
    for (sha256) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return resp.invalid(ctx.arena, "'sha256' is 64 lowercase hex digits");
    }
    const size = util.getInt(obj, "size") orelse return resp.invalid(ctx.arena, "'size' must be an integer");
    if (size < 1) return resp.invalid(ctx.arena, "'size' must be at least 1");
    if (size > @as(i64, st.max_upload)) return resp.fail(ctx.arena, .payload_too_large, &.{.{ "limit", std.fmt.comptimePrint("{d}", .{st.max_upload}) }});

    const u = try s.add(st.Upload, &s.uploads, .{
        .id = try util.newId(s.alloc, "upl"),
        .user = t.user,
        .package = p.name,
        .version = try s.alloc.dupe(u8, params[1]),
        .subdir = try s.alloc.dupe(u8, subdir),
        .filename = try s.alloc.dupe(u8, filename),
        .sha256 = try s.alloc.dupe(u8, sha256),
        .size = @intCast(size),
        .expires_at = s.now() + st.upload_secs,
    });
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, sha256) catch unreachable;
    var b64: [44]u8 = undefined;
    return resp.json(ctx.arena, .ok, .{
        .upload_id = u.id,
        .put_url = try std.fmt.allocPrint(ctx.arena, "{s}/_fake/upload/{s}", .{ s.base_url, u.id }),
        .put_headers = .{
            .@"content-length" = try std.fmt.allocPrint(ctx.arena, "{d}", .{u.size}),
            .@"x-amz-checksum-sha256" = std.base64.standard.Encoder.encode(&b64, &digest),
        },
        .expires_at = try util.rfc3339(ctx.arena, u.expires_at),
    });
}

/// `PUT /_fake/upload/<id>`: the presigned URL. Like the storage layer, it
/// refuses bytes of another length or sha256, and an expired URL.
pub fn uploadBytes(ctx: *Ctx, id: []const u8) anyerror!Response {
    if (ctx.method != .PUT) return resp.invalid(ctx.arena, "an upload URL takes PUT");
    const s = ctx.state;
    for (s.uploads.items) |u| {
        if (!std.mem.eql(u8, u.id, id)) continue;
        if (s.now() >= u.expires_at) return resp.invalid(ctx.arena, "the upload URL expired");
        if (ctx.body.len != u.size) return resp.invalid(ctx.arena, "the bytes are not the declared size");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(ctx.body, &digest, .{});
        const hex = try std.fmt.allocPrint(ctx.arena, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
        if (!std.mem.eql(u8, hex, u.sha256)) return resp.invalid(ctx.arena, "the bytes do not have the declared sha256");
        const rel = try std.fmt.allocPrint(s.alloc, "uploads/{s}", .{u.id});
        var dir = try std.fs.cwd().openDir(s.dir, .{});
        defer dir.close();
        try dir.makePath("uploads");
        try dir.writeFile(rel, ctx.body);
        u.path = rel;
        return resp.json(ctx.arena, .ok, .{});
    }
    return resp.invalid(ctx.arena, "no such upload");
}

pub fn commitPublish(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const s = ctx.state;
    const t = switch (try scoped(ctx, params[0], params[1], &.{.publish}, "publish")) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const p = switch (try target(ctx, params[0], params[1])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const manifest_sha256 = util.getStr(obj, "manifest_sha256") orelse return resp.invalid(ctx.arena, "'manifest_sha256' must be a string");
    if (manifest_sha256.len != 64) return resp.invalid(ctx.arena, "'manifest_sha256' is 64 lowercase hex digits");
    const ids_value = switch (obj.get("upload_ids") orelse return resp.invalid(ctx.arena, "'upload_ids' is required")) {
        .array => |a| a.items,
        else => return resp.invalid(ctx.arena, "'upload_ids' must be an array"),
    };
    if (ids_value.len == 0 or ids_value.len > 20) return resp.invalid(ctx.arena, "'upload_ids' holds 1 to 20 ids");

    var uploads = std.ArrayList(*st.Upload).init(ctx.arena);
    var ids = std.ArrayList([]const u8).init(s.alloc);
    for (ids_value) |v| {
        const id = switch (v) {
            .string => |w| w,
            else => return resp.invalid(ctx.arena, "each upload id must be a string"),
        };
        const u = for (s.uploads.items) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) break candidate;
        } else return resp.fail(ctx.arena, .upload_invalid, &.{.{ "detail", "an upload id is unknown" }});
        if (u.user != t.user or !std.mem.eql(u8, u.package, p.name) or !versions.same(u.version, params[1])) {
            return resp.fail(ctx.arena, .upload_invalid, &.{.{ "detail", "an upload belongs to another caller, package or version" }});
        }
        if (u.path == null) return resp.fail(ctx.arena, .upload_invalid, &.{.{ "detail", "a file was not uploaded" }});
        for (uploads.items) |seen| {
            if (seen == u) return resp.invalid(ctx.arena, "'upload_ids' repeats an id");
        }
        try uploads.append(u);
        try ids.append(u.id);
    }

    if (findVersion(p, params[1])) |existing| {
        if (existing.state == .pending) {
            // The same upload ids again resume the publish already running.
            for (s.publishes.items) |pub_| {
                if (pub_.version == existing and sameIds(pub_.upload_ids, ids.items)) return accepted(ctx, pub_);
            }
        } else {
            return resp.fail(ctx.arena, .version_exists, &.{
                .{ "name", p.name },
                .{ "version", existing.version },
                .{ "sha256", existing.files[0].sha256 },
            });
        }
    }
    for (uploads.items) |u| {
        if (u.used) return resp.fail(ctx.arena, .upload_used, &.{.{ "upload_id", u.id }});
    }

    var files = std.ArrayList(st.File).init(s.alloc);
    for (uploads.items) |u| {
        u.used = true;
        try files.append(.{ .subdir = u.subdir, .filename = u.filename, .sha256 = u.sha256, .size = u.size, .path = u.path.? });
    }
    const v = findVersion(p, params[1]) orelse try s.add(st.Version, &p.versions, .{
        .package = p,
        .version = try s.alloc.dupe(u8, params[1]),
        .files = &.{},
        .manifest_sha256 = "",
        .published_by = t.user.handle,
    });
    v.files = try files.toOwnedSlice();
    v.manifest_sha256 = try s.alloc.dupe(u8, manifest_sha256);
    v.provenance = if (t.kind == .oidc) t.oidc_repository else null;
    const pub_ = try s.add(st.Publish, &s.publishes, .{
        .id = try util.newId(s.alloc, "pub"),
        .user = t.user,
        .version = v,
        .upload_ids = try ids.toOwnedSlice(),
    });
    return accepted(ctx, pub_);
}

fn sameIds(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x, y)) break;
        } else return false;
    }
    return true;
}

fn accepted(ctx: *Ctx, p: *const st.Publish) anyerror!Response {
    return resp.json(ctx.arena, .accepted, .{
        .publish_id = p.id,
        .status_url = try std.fmt.allocPrint(ctx.arena, "/api/v1/publishes/{s}", .{p.id}),
    });
}

// ---------------------------------------------------------------------------
// Publish status
// ---------------------------------------------------------------------------

/// The rejection the fake finds in a publish's files, or null.
fn validate(ctx: *Ctx, p: *st.Publish) anyerror!?[]const u8 {
    const v = p.version;
    const want = try std.fmt.allocPrint(ctx.arena, "mojo-{s}-{s}-", .{ v.package.name, v.version });
    var dir = try std.fs.cwd().openDir(ctx.state.dir, .{});
    defer dir.close();
    for (v.files) |f| {
        if (!std.mem.startsWith(u8, f.filename, want)) return "filename_mismatch";
        var head: [64]u8 = undefined;
        const file = try dir.openFile(f.path, .{});
        defer file.close();
        const n = try file.readAll(&head);
        const marker = "REJECT:";
        if (std.mem.startsWith(u8, head[0..n], marker)) {
            const rest = head[marker.len..n];
            for (rejection_codes) |code| {
                if (std.mem.startsWith(u8, rest, code)) return code;
            }
        }
    }
    return null;
}

const stage_names = [_][]const u8{ "pending", "validating", "indexing", "published" };

pub fn getPublishStatus(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const a = try auth.authenticate(ctx);
    const t = switch (a) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    if (t.kind == .session) return resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", "publish" }, .{ "name", "this publish" } });
    const s = ctx.state;
    const p = for (s.publishes.items) |candidate| {
        if (std.mem.eql(u8, candidate.id, params[0]) and candidate.user == t.user) break candidate;
    } else return resp.fail(ctx.arena, .publish_not_found, &.{});

    const shown = p.stage;
    // The poll that finds a rejection still answers "validating"; the next
    // ones answer "rejected".
    var just_rejected = false;
    if (p.rejection == null and p.stage < 3) {
        if (p.stage == 1) {
            p.rejection = try validate(ctx, p);
            if (p.rejection != null) {
                p.version.state = .rejected;
                just_rejected = true;
            }
        }
        if (p.rejection == null) {
            p.stage += 1;
            if (p.stage == 3) try finish(ctx, p.version);
        }
    }
    const v = p.version;
    if (p.rejection) |code| {
        if (just_rejected) {
            return resp.json(ctx.arena, .ok, .{ .publish_id = p.id, .name = v.package.name, .version = v.version, .status = stage_names[1] });
        }
        return resp.json(ctx.arena, .ok, .{
            .publish_id = p.id,
            .name = v.package.name,
            .version = v.version,
            .status = "rejected",
            .rejection_code = code,
            .message = try std.fmt.allocPrint(ctx.arena, "the fake registry rejected the publish: {s}", .{code}),
        });
    }
    return resp.json(ctx.arena, .ok, .{ .publish_id = p.id, .name = v.package.name, .version = v.version, .status = stage_names[shown] });
}

/// A publish has passed its checks: the version is published.
fn finish(ctx: *Ctx, v: *st.Version) anyerror!void {
    const now = ctx.state.now();
    v.state = .published;
    v.published_at = now;
    v.package.state = .active;
    v.package.updated_at = now;
}

// ---------------------------------------------------------------------------
// Yank and the version detail
// ---------------------------------------------------------------------------

pub fn setYanked(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    _ = switch (try scoped(ctx, params[0], params[1], &.{ .yank, .publish }, "yank")) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const p = switch (try target(ctx, params[0], params[1])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const v = findVersion(p, params[1]) orelse return notFound(ctx, p.name, params[1]);
    if (v.state == .rejected) return notFound(ctx, p.name, params[1]);
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const yanked = util.getBool(obj, "yanked") orelse return resp.invalid(ctx.arena, "'yanked' must be a boolean");
    const reason = util.getStr(obj, "reason");
    if (yanked and reason == null) return resp.invalid(ctx.arena, "yanking needs a 'reason'");
    if (reason) |r| {
        if (r.len > 280) return resp.invalid(ctx.arena, "'reason' is at most 280 characters");
    }
    // Only a published version can be yanked (yanking a yanked one again is a
    // no-op), only a yanked one unyanked; a pending or tombstoned version
    // refuses every change.
    const allowed = switch (v.state) {
        .published => yanked,
        .yanked => true,
        .pending, .tombstoned, .rejected => false,
    };
    if (!allowed) {
        return resp.fail(ctx.arena, .invalid_transition, &.{
            .{ "action", if (yanked) "yank" else "unyank" },
            .{ "name", p.name },
            .{ "version", v.version },
            .{ "state", @tagName(v.state) },
        });
    }
    if (yanked and v.state == .published) {
        v.state = .yanked;
        v.yank_reason = try ctx.state.alloc.dupe(u8, reason.?);
        p.updated_at = ctx.state.now();
    } else if (!yanked) {
        v.state = .published;
        v.yank_reason = null;
        p.updated_at = ctx.state.now();
    }
    return resp.json(ctx.arena, .ok, try summary(ctx.arena, v));
}

fn notFound(ctx: *Ctx, name: []const u8, version: []const u8) Allocator.Error!Response {
    return resp.fail(ctx.arena, .version_not_found, &.{ .{ "name", name }, .{ "version", version } });
}

pub const Summary = struct {
    version: []const u8,
    state: []const u8,
    published_at: []const u8,
    yank_reason: ?[]const u8,
};

pub fn summary(arena: Allocator, v: *const st.Version) Allocator.Error!Summary {
    return .{
        .version = v.version,
        .state = @tagName(v.state),
        .published_at = try util.rfc3339(arena, v.published_at),
        .yank_reason = v.yank_reason,
    };
}

fn newestFirst(_: void, a: *st.Version, b: *st.Version) bool {
    return versions.compare(a.version, b.version) == .gt;
}

/// The shown versions of `p`, newest first.
pub fn summaries(arena: Allocator, p: *st.Package) Allocator.Error![]const Summary {
    var shown = std.ArrayList(*st.Version).init(arena);
    for (p.versions.items) |v| {
        if (v.visible()) try shown.append(v);
    }
    std.mem.sort(*st.Version, shown.items, {}, newestFirst);
    var out = std.ArrayList(Summary).init(arena);
    for (shown.items) |v| try out.append(try summary(arena, v));
    return try out.toOwnedSlice();
}

/// The newest published (not yanked), non-prerelease version, or null.
pub fn latest(p: *const st.Package) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (p.versions.items) |v| {
        if (v.state != .published or versions.isPrerelease(v.version)) continue;
        if (best == null or versions.compare(v.version, best.?) == .gt) best = v.version;
    }
    return best;
}

/// The compiler requirement from a build string `mojo<version>_<n>`.
fn requiresMojo(arena: Allocator, filename: []const u8) Allocator.Error![]const u8 {
    const stem = filename[0 .. filename.len - ".conda".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return ">=0";
    const build = stem[dash + 1 ..];
    if (!std.mem.startsWith(u8, build, "mojo")) return ">=0";
    const under = std.mem.lastIndexOfScalar(u8, build, '_') orelse build.len;
    if (under <= 4) return ">=0";
    return std.fmt.allocPrint(arena, "=={s}", .{build[4..under]});
}

pub fn getVersion(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p = switch (try target(ctx, params[0], params[1])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const v = findVersion(p, params[1]) orelse return notFound(ctx, p.name, params[1]);
    if (!v.visible()) return notFound(ctx, p.name, params[1]);
    const s = ctx.state;
    const Dep = struct { name: []const u8, range: []const u8 };
    const Native = struct { id: []const u8, soname: []const u8 };
    const no_deps: []const Dep = &.{};
    const no_native: []const Native = &.{};
    const Provenance = struct {
        kind: []const u8,
        repository: ?[]const u8 = null,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("kind");
            try jw.write(self.kind);
            if (self.repository) |r| {
                try jw.objectField("repository");
                try jw.write(r);
            }
            try jw.endObject();
        }
    };
    const provenance = Provenance{ .kind = if (v.provenance == null) "none" else "oidc", .repository = v.provenance };
    const requires = try requiresMojo(ctx.arena, v.files[0].filename);

    if (v.state == .tombstoned) {
        const BareFile = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
        var bare = std.ArrayList(BareFile).init(ctx.arena);
        for (v.files) |f| try bare.append(.{ .subdir = f.subdir, .filename = f.filename, .sha256 = f.sha256, .size = f.size });
        return resp.json(ctx.arena, .ok, .{
            .name = p.name,
            .version = v.version,
            .state = "tombstoned",
            .yank_reason = v.yank_reason,
            .tombstone = .{ .reason_code = v.tombstone_reason.?, .date = try util.date(ctx.arena, v.tombstone_at) },
            .published_at = try util.rfc3339(ctx.arena, v.published_at),
            .published_by = v.published_by,
            .requires_mojo = requires,
            .deps = no_deps,
            .native = no_native,
            .files = bare.items,
            .manifest_sha256 = v.manifest_sha256,
            .readme_html = @as(?[]const u8, null),
            .provenance = provenance,
        });
    }
    const FileRef = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64, url: []const u8 };
    var files = std.ArrayList(FileRef).init(ctx.arena);
    for (v.files) |f| {
        try files.append(.{
            .subdir = f.subdir,
            .filename = f.filename,
            .sha256 = f.sha256,
            .size = f.size,
            .url = try std.fmt.allocPrint(ctx.arena, "{s}/channel/{s}/{s}", .{ s.base_url, f.subdir, f.filename }),
        });
    }
    return resp.json(ctx.arena, .ok, .{
        .name = p.name,
        .version = v.version,
        .state = @tagName(v.state),
        .yank_reason = v.yank_reason,
        .published_at = try util.rfc3339(ctx.arena, v.published_at),
        .published_by = v.published_by,
        .requires_mojo = requires,
        .deps = no_deps,
        .native = no_native,
        .files = files.items,
        .manifest_sha256 = v.manifest_sha256,
        .readme_html = @as(?[]const u8, null),
        .provenance = provenance,
    });
}

test "requires_mojo comes from the build string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("==1.0.0", try requiresMojo(a, "mojo-http_client-0.4.0-mojo1.0.0_0.conda"));
    try std.testing.expectEqualStrings(">=0", try requiresMojo(a, "mojo-x-1.0-py_0.conda"));
}
