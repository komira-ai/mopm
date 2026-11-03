//! A member's readme as an uploaded object (spec/api/openapi.yaml, `ReadmeRef`, `GroupUploadReadme`): a create names it by
//! `{sha256, size}`, the answer says where to PUT it, and the commit names it again instead of carrying the text. The fake keeps
//! the bytes in its data directory like a file's, checks them when the commit arrives, and records the text on the member's version
//! when the group becomes visible, whichever form the commit used. `/_fake/readme_objects` switches the capability off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const ids = @import("group_ids.zig");

pub const max_readme: usize = 65536;
/// The name `/health` lists in `features` while readme objects are on.
pub const feature = "group_readme_objects";

/// A readme named by the digest and the size of its bytes.
pub const Ref = struct { sha256: []const u8, size: usize };
/// What a commit request says of one member's readme.
pub const Readme = union(enum) { text: []const u8, ref: Ref };

/// The ref in `v`, or null when `v` is not an object holding a 64-digit lowercase hex `sha256` and a `size` of 1 to 65536.
fn refOf(v: Value) ?Ref {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const sha = util.getStr(o, "sha256") orelse return null;
    const size = util.getInt(o, "size") orelse return null;
    if (!ids.isSha(sha) or size < 1 or size > max_readme) return null;
    return .{ .sha256 = sha, .size = @intCast(size) };
}

// ---------------------------------------------------------------------------
// createGroup
// ---------------------------------------------------------------------------

pub const Declared = union(enum) { none, ref: Ref, fail: Response };

/// The `readme` a create member declares. With the capability off the field is ignored, as for a registry that has not got it.
pub fn declared(ctx: *Ctx, m: std.json.ObjectMap, name: []const u8) Allocator.Error!Declared {
    if (!ctx.state.readme_objects) return .none;
    const v = m.get("readme") orelse return .none;
    if (refOf(v)) |r| return .{ .ref = r };
    const detail = try std.fmt.allocPrint(ctx.arena, "'readme' of '{s}' is {{\"sha256\", \"size\"}} of a readme of 1 to {d} bytes", .{ name, max_readme });
    return .{ .fail = try resp.invalid(ctx.arena, detail) };
}

/// The id of the upload that carries a member's readme; the same on every call, so a resume finds it.
fn uploadId(arena: Allocator, gid: []const u8, name: []const u8, sha256: []const u8) Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    const line = try std.fmt.allocPrint(arena, "{s}|{s}|readme|{s}", .{ gid, name, sha256 });
    std.crypto.hash.sha2.Sha256.hash(line, &digest, .{});
    return std.fmt.allocPrint(arena, "upl_r{s}", .{std.fmt.fmtSliceHexLower(digest[0..12])});
}

fn findUpload(s: *st.State, id: []const u8) ?*st.Upload {
    for (s.uploads.items) |u| {
        if (std.mem.eql(u8, u.id, id)) return u;
    }
    return null;
}

/// The upload record of a declared readme, made on first sight.
pub fn declare(ctx: *Ctx, g: *const st.Group, package: []const u8, version: []const u8, r: Ref) Allocator.Error!st.GroupReadme {
    const s = ctx.state;
    const id = try uploadId(ctx.arena, g.id, package, r.sha256);
    if (findUpload(s, id)) |u| {
        // A declaration is the digest and the size: a repeat with another size replaces the size of the record, and an object
        // stored under the old size is not the one now declared.
        if (u.size != r.size) {
            u.size = r.size;
            u.path = null;
        }
        return .{ .sha256 = u.sha256, .size = u.size, .upload = u };
    }
    const u = try s.add(st.Upload, &s.uploads, .{
        .id = try s.alloc.dupe(u8, id),
        .user = g.user,
        .package = try s.alloc.dupe(u8, package),
        .version = try s.alloc.dupe(u8, version),
        .subdir = "",
        .filename = "README.md",
        .sha256 = try s.alloc.dupe(u8, r.sha256),
        .size = r.size,
        .expires_at = s.now() + st.upload_secs,
    });
    return .{ .sha256 = u.sha256, .size = u.size, .upload = u };
}

/// The bytes now in storage for `u`, or null when it has none: never stored, or its file is gone.
fn stored(ctx: *Ctx, u: *const st.Upload) anyerror!?[]const u8 {
    const path = u.path orelse return null;
    var dir = try std.fs.cwd().openDir(ctx.state.dir, .{});
    defer dir.close();
    return dir.readFileAlloc(ctx.arena, path, std.math.maxInt(u32)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn isObject(bytes: []const u8, sha256: []const u8, size: usize) bool {
    if (bytes.len != size) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return std.mem.eql(u8, &hex, sha256);
}

const PutHeaders = struct {
    @"content-length": []const u8,
    @"x-amz-checksum-sha256": []const u8,
};
pub const Answer = struct {
    sha256: []const u8,
    size: u64,
    upload_id: []const u8,
    uploaded: bool,
    put_url: ?[]const u8 = null,
    put_headers: ?PutHeaders = null,
    expires_at: ?[]const u8 = null,
};

/// The upload of one readme: a fresh URL unless the bytes are in storage now, as declared.
pub fn answer(ctx: *Ctx, r: st.GroupReadme) anyerror!Answer {
    const s = ctx.state;
    const now_stored = if (try stored(ctx, r.upload)) |bytes| isObject(bytes, r.sha256, r.size) else false;
    var out = Answer{ .sha256 = r.sha256, .size = r.size, .upload_id = r.upload.id, .uploaded = now_stored };
    if (out.uploaded) return out;
    r.upload.expires_at = s.now() + st.upload_secs;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, r.sha256) catch unreachable;
    var b64: [44]u8 = undefined;
    out.put_url = try std.fmt.allocPrint(ctx.arena, "{s}/_fake/upload/{s}", .{ s.base_url, r.upload.id });
    out.put_headers = .{
        .@"content-length" = try std.fmt.allocPrint(ctx.arena, "{d}", .{r.size}),
        .@"x-amz-checksum-sha256" = try ctx.arena.dupe(u8, std.base64.standard.Encoder.encode(&b64, &digest)),
    };
    out.expires_at = try util.rfc3339(ctx.arena, r.upload.expires_at);
    return out;
}

// ---------------------------------------------------------------------------
// commitGroup
// ---------------------------------------------------------------------------

pub const Display = union(enum) {
    /// `shown` names the description, licence and an inline readme for the request hash; `readme` is the member's, if it sent one.
    ok: struct { shown: []const u8, readme: ?Readme },
    fail: Response,
};

/// The description, licence and readme of one commit member. A readme is a string (empty too, as the registry takes it), or
/// (capability on) a ref. `shown` holds the inline texts only: a ref is for the caller to name in the request hash.
pub fn display(ctx: *Ctx, m: std.json.ObjectMap, name: []const u8) Allocator.Error!Display {
    const a = ctx.arena;
    const objects = ctx.state.readme_objects;
    var shown = std.ArrayList(u8).init(a);
    var readme: ?Readme = null;
    for ([_][]const u8{ "description", "license", "readme" }) |key| {
        const is_readme = std.mem.eql(u8, key, "readme");
        if (m.get(key)) |v| {
            if (if (is_readme and objects) refOf(v) else null) |r| {
                readme = .{ .ref = r };
            } else switch (v) {
                .string => |text| {
                    if ((text.len == 0 and !is_readme) or text.len > (if (is_readme) max_readme else 512)) {
                        return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'{s}' of '{s}' is empty or too long", .{ key, name })) };
                    }
                    if (is_readme) readme = .{ .text = text };
                    try shown.appendSlice(text);
                },
                else => {
                    const detail = if (is_readme and objects)
                        try std.fmt.allocPrint(a, "'readme' of '{s}' is a string or {{\"sha256\", \"size\"}} of a readme of 1 to {d} bytes", .{ name, max_readme })
                    else
                        try std.fmt.allocPrint(a, "'{s}' of '{s}' must be a string", .{ key, name });
                    return .{ .fail = try resp.invalid(a, detail) };
                },
            }
        }
        try shown.append(0);
    }
    return .{ .ok = .{ .shown = shown.items, .readme = readme } };
}

pub const Loaded = union(enum) { ok: []const ?[]const u8, fail: Response };

fn uploadInvalid(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Response {
    return resp.fail(a, .upload_invalid, &.{.{ "detail", try std.fmt.allocPrint(a, fmt, args) }});
}

/// The readme text of each member of an open group: the inline text as sent, or the uploaded object a ref names, read back and
/// checked for its size and UTF-8. Nothing is stored, so a refusal changes nothing.
pub fn load(ctx: *Ctx, g: *const st.Group, readmes: []const ?Readme) anyerror!Loaded {
    const a = ctx.arena;
    const s = ctx.state;
    const out = try a.alloc(?[]const u8, readmes.len);
    for (g.members, readmes, out) |m, readme, *text| {
        const name = m.package.name;
        text.* = null;
        const r = switch (readme orelse continue) {
            .text => |t| {
                text.* = t;
                continue;
            },
            .ref => |r| r,
        };
        const found = findUpload(s, try uploadId(a, g.id, name, r.sha256));
        const bytes = (if (found) |u| try stored(ctx, u) else null) orelse
            return .{ .fail = try uploadInvalid(a, "the readme of '{s}' (sha256 {s}) was not uploaded", .{ name, r.sha256 }) };
        // What is in storage now, not what the PUT stored.
        if (!isObject(bytes, r.sha256, r.size)) {
            return .{ .fail = try uploadInvalid(a, "the readme of '{s}' in storage is not the one named (sha256 {s}, {d} bytes)", .{ name, r.sha256, r.size }) };
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "the readme of '{s}' is not UTF-8 text", .{name})) };
        }
        text.* = bytes;
    }
    return .{ .ok = out };
}

/// `r` with `"readme"` added to its JSON object body when there is a text; a key is absent, not null, when there is nothing to say.
pub fn withReadme(arena: Allocator, r: Response, readme: ?[]const u8) Allocator.Error!Response {
    const text = readme orelse return r;
    var buf = std.ArrayList(u8).init(arena);
    try buf.appendSlice(r.body[0 .. r.body.len - 1]); // without the closing brace
    try buf.appendSlice(",\"readme\":");
    std.json.stringify(text, .{}, buf.writer()) catch return error.OutOfMemory;
    try buf.append('}');
    var out = r;
    out.body = buf.items;
    return out;
}
