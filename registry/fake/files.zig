//! The static files a client reads without the API: the conda channel
//! (spec/channel.md) and the sparse index (spec/index.md), written under the
//! data directory and served at `/channel/...` and `/index/...`.
//!
//! Packages in namespaces (spec/proposed/namespaces.md) are written beside the
//! v1 ones: index version 2 under `index/v2/`, and one channel per namespace,
//! `channel/<namespace>/<subdir>/`, whose conda names are
//! `mojo-<namespace>.<name>`. The flat root `channel/<subdir>/` holds only v1
//! packages, and an empty valid repodata when there are none.
//!
//! `rewrite` regenerates every file from the state after each change (a
//! publish, a yank, a takedown, read-only mode). Writes are deterministic:
//! keys sorted, no timestamps but `published_at` and a takedown's date, so the
//! same state always gives the same bytes. A published file's bytes are
//! copied into the channel once; a takedown removes them and the URL answers
//! 410.

const std = @import("std");
const Allocator = std.mem.Allocator;
const st = @import("state.zig");
const util = @import("util.zig");
const versions = @import("versions.zig");
const publish = @import("publish.zig");
const api = @import("api.zig");
const resp = @import("resp.zig");
const names = @import("names.zig");

pub const subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" };

/// The oldest CLI the fake says it supports (index config).
const min_cli_version = "0.0.1";

/// `index/ht/tp/http_client`: the index path of a package (spec/index.md), or of a package in a namespace,
/// `index/v2/ko/mi/komira-ai/json`.
pub const indexPath = names.indexPath;

fn writeAll(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(path, data);
}

/// Regenerates every channel and index file from `s`.
pub fn rewrite(arena: Allocator, s: *st.State) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    try writeAll(dir, "index/config.json", try config(arena, s));
    try writeAll(dir, "index/takedowns.json", try takedowns(arena, s, 1));
    try writeAll(dir, "index/v2/takedowns.json", try takedowns(arena, s, 2));
    for (s.packages.items) |p| {
        if (p.versions.items.len == 0) continue;
        try writeAll(dir, try indexPath(arena, p.name), try indexRecords(arena, s, p));
    }
    try writeChannel(arena, dir, s, null);
    for (s.namespaces.items) |n| try writeChannel(arena, dir, s, n);
}

/// The repodata of one channel: the flat root (`ns` null, v1 packages) or the channel of namespace `ns`.
fn writeChannel(arena: Allocator, dir: std.fs.Dir, s: *const st.State, ns: ?*const st.Namespace) !void {
    const root = if (ns) |n| try std.fmt.allocPrint(arena, "channel/{s}", .{n.name}) else "channel";
    for (subdirs) |subdir| {
        try writeAll(dir, try std.fmt.allocPrint(arena, "{s}/{s}/repodata.json", .{ root, subdir }), try repodata(arena, s, ns, subdir, false));
        try writeAll(dir, try std.fmt.allocPrint(arena, "{s}/{s}/current_repodata.json", .{ root, subdir }), try repodata(arena, s, ns, subdir, true));
    }
}

/// `channel/<subdir>/<file>` of a v1 package, `channel/<namespace>/<subdir>/<file>` of a package in a namespace.
fn channelPath(arena: Allocator, key: []const u8, f: st.File) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ try names.channelDir(arena, key), f.subdir, f.filename });
}

/// Copies a newly published version's bytes into the channel.
pub fn addFiles(s: *st.State, v: *const st.Version) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    for (v.files) |f| {
        fba.reset();
        const to = try channelPath(fba.allocator(), v.package.name, f);
        if (std.fs.path.dirname(to)) |parent| try dir.makePath(parent);
        try dir.copyFile(f.path, dir, to, .{});
    }
}

/// Removes a taken-down version's bytes from the channel.
pub fn removeFiles(s: *st.State, v: *const st.Version) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    for (v.files) |f| {
        fba.reset();
        const path = try channelPath(fba.allocator(), v.package.name, f);
        dir.deleteFile(path) catch |e| if (e != error.FileNotFound) return e;
    }
}

fn config(arena: Allocator, s: *const st.State) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(.{
        .api_url = try std.fmt.allocPrint(arena, "{s}/api/v1", .{s.base_url}),
        .api_v2_url = try std.fmt.allocPrint(arena, "{s}/api/v2", .{s.base_url}),
        .channel_url = try std.fmt.allocPrint(arena, "{s}/channel/", .{s.base_url}),
        .index_version = 1,
        .index_versions = [_]u32{ 1, 2 },
        .min_cli_version = min_cli_version,
        .read_only = s.read_only,
        .stage = s.stage,
    }, .{}, out.writer());
    try out.append('\n');
    return out.items;
}

fn oldestFirst(_: void, a: *st.Version, b: *st.Version) bool {
    return versions.compare(a.version, b.version) == .lt;
}

/// The shown versions of `p`, oldest first.
fn shown(arena: Allocator, p: *const st.Package) Allocator.Error![]*st.Version {
    var out = std.ArrayList(*st.Version).init(arena);
    for (p.versions.items) |v| {
        if (v.visible()) try out.append(v);
    }
    std.mem.sort(*st.Version, out.items, {}, oldestFirst);
    return out.items;
}

/// The build string of a file name `mojo-<name>-<version>-<build>.conda`.
pub fn build(filename: []const u8) []const u8 {
    const stem = filename[0 .. filename.len - ".conda".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return stem;
    return stem[dash + 1 ..];
}

/// One NDJSON line per shown version, keys sorted (spec/index.md): record `v` 1 for a v1 package, `v` 2 (its `name` the
/// full name, its URLs in the namespace's channel) for a package in a namespace.
fn indexRecords(arena: Allocator, s: *const st.State, p: *const st.Package) ![]const u8 {
    const Dep = struct { name: []const u8, range: []const u8 };
    const Native = struct { id: []const u8, soname: []const u8 };
    const FileRef = struct { filename: []const u8, sha256: []const u8, size: u64, subdir: []const u8, url: ?[]const u8 };
    const Tombstone = struct { date: []const u8, reason_code: []const u8 };
    const Provenance = struct { kind: []const u8, repository: ?[]const u8 };
    const Record = struct {
        build: []const u8,
        deps: []const Dep,
        files: []const FileRef,
        manifest_sha256: []const u8,
        name: []const u8,
        native: []const Native,
        provenance: Provenance,
        published_at: []const u8,
        requires_mojo: []const u8,
        state: []const u8,
        tombstone: ?Tombstone,
        v: u32,
        version: []const u8,
        yank_reason: ?[]const u8,
    };
    var out = std.ArrayList(u8).init(arena);
    for (try shown(arena, p)) |v| {
        var files = std.ArrayList(FileRef).init(arena);
        for (v.files) |f| {
            try files.append(.{
                .filename = f.filename,
                .sha256 = f.sha256,
                .size = f.size,
                .subdir = f.subdir,
                .url = if (v.state == .tombstoned) null else try publish.fileUrl(arena, s, p.name, f),
            });
        }
        try std.json.stringify(Record{
            .build = build(v.files[0].filename),
            .deps = &.{},
            .files = files.items,
            .manifest_sha256 = v.manifest_sha256,
            .name = p.name,
            .native = &.{},
            .provenance = .{ .kind = if (v.provenance == null) "none" else "oidc", .repository = v.provenance },
            .published_at = try util.rfc3339(arena, v.published_at),
            .requires_mojo = try publish.requiresMojo(arena, v.files[0].filename),
            .state = @tagName(v.state),
            .tombstone = if (v.state == .tombstoned) .{ .date = try util.date(arena, v.tombstone_at), .reason_code = v.tombstone_reason.? } else null,
            .v = if (p.namespace == null) @as(u32, 1) else 2,
            .version = v.version,
            .yank_reason = if (v.state == .yanked) v.yank_reason else null,
        }, .{ .emit_null_optional_fields = false }, out.writer());
        try out.append('\n');
    }
    return out.items;
}

/// The takedown log of index version `index_version`: v1 packages for 1, packages in namespaces (full names) for 2.
fn takedowns(arena: Allocator, s: *const st.State, index_version: u32) ![]const u8 {
    const Takedown = struct { date: []const u8, name: []const u8, reason_code: []const u8, sha256: []const []const u8, version: []const u8 };
    var list = std.ArrayList(Takedown).init(arena);
    for (s.packages.items) |p| {
        if ((p.namespace != null) != (index_version == 2)) continue;
        for (p.versions.items) |v| {
            if (v.state != .tombstoned) continue;
            var shas = std.ArrayList([]const u8).init(arena);
            for (v.files) |f| try shas.append(f.sha256);
            try list.append(.{
                .date = try util.date(arena, v.tombstone_at),
                .name = p.name,
                .reason_code = v.tombstone_reason.?,
                .sha256 = shas.items,
                .version = v.version,
            });
        }
    }
    std.mem.sort(Takedown, list.items, {}, struct {
        fn less(_: void, a: Takedown, b: Takedown) bool {
            const d = std.mem.order(u8, a.date, b.date);
            if (d != .eq) return d == .lt;
            const n = std.mem.order(u8, a.name, b.name);
            if (n != .eq) return n == .lt;
            return versions.compare(a.version, b.version) == .lt;
        }
    }.less);
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(.{ .index_version = index_version, .takedowns = list.items }, .{}, out.writer());
    try out.append('\n');
    return out.items;
}

const Entry = struct { filename: []const u8, version: *const st.Version, file: st.File };

fn byFilename(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.filename, b.filename) == .lt;
}

fn sameNamespace(a: ?*const st.Namespace, b: ?*const st.Namespace) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x == y;
}

/// `repodata.json` of `subdir` of one channel (or, when `current`, `current_repodata.json`:
/// only each name's newest published version): the flat root's (`ns` null) or namespace `ns`'s.
fn repodata(arena: Allocator, s: *const st.State, ns: ?*const st.Namespace, subdir: []const u8, current: bool) ![]const u8 {
    var live = std.ArrayList(Entry).init(arena);
    var removed = std.ArrayList([]const u8).init(arena);
    for (s.packages.items) |p| {
        if (!sameNamespace(p.namespace, ns)) continue;
        const newest = publish.latest(p);
        for (p.versions.items) |v| {
            for (v.files) |f| {
                if (!std.mem.eql(u8, f.subdir, subdir)) continue;
                switch (v.state) {
                    .published => {
                        if (current and (newest == null or !std.mem.eql(u8, newest.?, v.version))) continue;
                        try live.append(.{ .filename = f.filename, .version = v, .file = f });
                    },
                    .yanked, .tombstoned => if (!current) try removed.append(f.filename),
                    else => {},
                }
            }
        }
    }
    std.mem.sort(Entry, live.items, {}, byFilename);
    std.mem.sort([]const u8, removed.items, {}, st.lessString);

    var out = std.ArrayList(u8).init(arena);
    var ws = std.json.writeStream(out.writer(), .{});
    try ws.beginObject();
    try ws.objectField("info");
    try ws.write(.{ .subdir = subdir });
    try ws.objectField("packages");
    try ws.beginObject();
    try ws.endObject();
    try ws.objectField("packages.conda");
    try ws.beginObject();
    for (live.items) |e| {
        const requires = try publish.requiresMojo(arena, e.filename);
        const depends = [_][]const u8{try std.fmt.allocPrint(arena, "mojo-compiler {s}", .{requires})};
        try ws.objectField(e.filename);
        try ws.write(.{
            .build = build(e.filename),
            .build_number = 0,
            .depends = depends[0..],
            .name = try names.condaName(arena, e.version.package.name),
            .sha256 = e.file.sha256,
            .size = e.file.size,
            .subdir = subdir,
            .version = e.version.version,
        });
    }
    try ws.endObject();
    try ws.objectField("removed");
    try ws.write(removed.items);
    try ws.endObject();
    try out.append('\n');
    return out.items;
}

/// `GET /channel/...` and `GET /index/...`: the files under the data
/// directory. A taken-down file answers 410; an unknown one 404.
pub fn serve(ctx: *api.Ctx) anyerror!resp.Response {
    if (ctx.method != .GET) return resp.empty(.method_not_allowed);
    const rel = ctx.path[1..];
    if (std.mem.indexOf(u8, rel, "..") != null) return resp.empty(.not_found);
    const s = ctx.state;
    for (s.packages.items) |p| {
        for (p.versions.items) |v| {
            if (v.state != .tombstoned) continue;
            for (v.files) |f| {
                if (std.mem.eql(u8, try channelPath(ctx.arena, p.name, f), rel)) return resp.empty(.gone);
            }
        }
    }
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    const body = dir.readFileAlloc(ctx.arena, rel, 64 << 20) catch |e| switch (e) {
        error.FileNotFound, error.IsDir, error.NotDir => return resp.empty(.not_found),
        else => return e,
    };
    if (std.mem.endsWith(u8, rel, ".conda")) s.conda_served += 1;
    const content_type = if (std.mem.endsWith(u8, rel, ".json"))
        "application/json"
    else if (std.mem.endsWith(u8, rel, ".conda"))
        "application/octet-stream"
    else
        "application/x-ndjson";
    return .{ .status = .ok, .body = body, .content_type = content_type };
}

test "index paths pad short names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("index/ht/tp/http_client", try indexPath(a, "http_client"));
    try std.testing.expectEqualStrings("index/tl/s_/tls", try indexPath(a, "tls"));
    try std.testing.expectEqualStrings("index/ab/__/ab", try indexPath(a, "ab"));
    try std.testing.expectEqualStrings("mojo1.0.0_0", build("mojo-http_client-0.4.0-mojo1.0.0_0.conda"));
}
