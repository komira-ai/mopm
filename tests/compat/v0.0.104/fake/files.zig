//! The static files a client reads without the API: the conda channel
//! (spec/channel.md) and the sparse index (spec/index.md), written under the
//! data directory and served at `/channel/...` and `/index/...`.
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

pub const subdirs = [_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" };

/// The oldest CLI the fake says it supports (index config).
const min_cli_version = "0.0.1";

/// `ht/tp/http_client`: the index path of a package (spec/index.md).
pub fn indexPath(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var pad: [4]u8 = .{ '_', '_', '_', '_' };
    @memcpy(pad[0..@min(name.len, 4)], name[0..@min(name.len, 4)]);
    return std.fmt.allocPrint(arena, "index/{s}/{s}/{s}", .{ pad[0..2], pad[2..4], name });
}

fn writeAll(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(path, data);
}

/// Regenerates every channel and index file from `s`.
pub fn rewrite(arena: Allocator, s: *st.State) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    try writeAll(dir, "index/config.json", try config(arena, s));
    try writeAll(dir, "index/takedowns.json", try takedowns(arena, s));
    for (s.packages.items) |p| {
        if (p.versions.items.len == 0) continue;
        try writeAll(dir, try indexPath(arena, p.name), try indexRecords(arena, s, p));
    }
    for (subdirs) |subdir| {
        try writeAll(dir, try std.fmt.allocPrint(arena, "channel/{s}/repodata.json", .{subdir}), try repodata(arena, s, subdir, false));
        try writeAll(dir, try std.fmt.allocPrint(arena, "channel/{s}/current_repodata.json", .{subdir}), try repodata(arena, s, subdir, true));
    }
}

/// Copies a newly published version's bytes into the channel.
pub fn addFiles(s: *st.State, v: *const st.Version) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    var buf: [512]u8 = undefined;
    for (v.files) |f| {
        const to = try std.fmt.bufPrint(&buf, "channel/{s}/{s}", .{ f.subdir, f.filename });
        if (std.fs.path.dirname(to)) |parent| try dir.makePath(parent);
        try dir.copyFile(f.path, dir, to, .{});
    }
}

/// Removes a taken-down version's bytes from the channel.
pub fn removeFiles(s: *st.State, v: *const st.Version) !void {
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    var buf: [512]u8 = undefined;
    for (v.files) |f| {
        const path = try std.fmt.bufPrint(&buf, "channel/{s}/{s}", .{ f.subdir, f.filename });
        dir.deleteFile(path) catch |e| if (e != error.FileNotFound) return e;
    }
}

fn config(arena: Allocator, s: *const st.State) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(.{
        .api_url = try std.fmt.allocPrint(arena, "{s}/api/v1", .{s.base_url}),
        .channel_url = try std.fmt.allocPrint(arena, "{s}/channel/", .{s.base_url}),
        .index_version = 1,
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

/// One NDJSON line per shown version, keys sorted (spec/index.md).
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
                .url = if (v.state == .tombstoned) null else try std.fmt.allocPrint(arena, "{s}/channel/{s}/{s}", .{ s.base_url, f.subdir, f.filename }),
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
            .v = 1,
            .version = v.version,
            .yank_reason = if (v.state == .yanked) v.yank_reason else null,
        }, .{ .emit_null_optional_fields = false }, out.writer());
        try out.append('\n');
    }
    return out.items;
}

fn takedowns(arena: Allocator, s: *const st.State) ![]const u8 {
    const Takedown = struct { date: []const u8, name: []const u8, reason_code: []const u8, sha256: []const []const u8, version: []const u8 };
    var list = std.ArrayList(Takedown).init(arena);
    for (s.packages.items) |p| {
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
    try std.json.stringify(.{ .index_version = 1, .takedowns = list.items }, .{}, out.writer());
    try out.append('\n');
    return out.items;
}

const Entry = struct { filename: []const u8, version: *const st.Version, file: st.File };

fn byFilename(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.filename, b.filename) == .lt;
}

/// `repodata.json` of `subdir` (or, when `current`, `current_repodata.json`:
/// only each name's newest published version).
fn repodata(arena: Allocator, s: *const st.State, subdir: []const u8, current: bool) ![]const u8 {
    var live = std.ArrayList(Entry).init(arena);
    var removed = std.ArrayList([]const u8).init(arena);
    for (s.packages.items) |p| {
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
            .name = try std.fmt.allocPrint(arena, "mojo-{s}", .{e.version.package.name}),
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
                const gone = try std.fmt.allocPrint(ctx.arena, "channel/{s}/{s}", .{ f.subdir, f.filename });
                if (std.mem.eql(u8, gone, rel)) return resp.empty(.gone);
            }
        }
    }
    var dir = try std.fs.cwd().openDir(s.dir, .{});
    defer dir.close();
    const body = dir.readFileAlloc(ctx.arena, rel, 64 << 20) catch |e| switch (e) {
        error.FileNotFound, error.IsDir, error.NotDir => return resp.empty(.not_found),
        else => return e,
    };
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
