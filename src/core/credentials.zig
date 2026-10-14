//! Where mopm keeps its tokens: `<config dir>/credentials.json`, one entry
//! per registry API URL, `{"<api_url>": {"token": "...", "handle": "..."}}`.
//!
//! The file is written to a temporary name with mode 0600 and renamed into
//! place, so it is never readable by others, not even for a moment. Nothing
//! here prints a token.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const file_name = "credentials.json";

pub const Entry = struct { token: []const u8, handle: []const u8 };

/// `$XDG_CONFIG_HOME/mopm`, else `$HOME/.config/mopm`.
pub fn defaultDir(arena: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(arena, "XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(arena, &.{ x, "mopm" });
    } else |_| {}
    const home = std.process.getEnvVarOwned(arena, "HOME") catch return error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".config", "mopm" });
}

/// Every entry of the file, or an empty map when there is no file.
fn readAll(arena: Allocator, dir_path: []const u8) !std.json.ObjectMap {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return std.json.ObjectMap.init(arena),
        else => return e,
    };
    defer dir.close();
    const text = dir.readFileAlloc(arena, file_name, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => return std.json.ObjectMap.init(arena),
        else => return e,
    };
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.CredentialsNotJson;
    return switch (v) {
        .object => |o| o,
        else => error.CredentialsNotJson,
    };
}

fn writeAll(arena: Allocator, dir_path: []const u8, entries: std.json.ObjectMap) !void {
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(std.json.Value{ .object = entries }, .{ .whitespace = .indent_2 }, out.writer());
    try out.append('\n');
    const tmp = file_name ++ ".tmp";
    {
        const f = try dir.createFile(tmp, .{ .mode = 0o600, .truncate = true });
        defer f.close();
        // The mode above applies only when the file is new.
        try f.chmod(0o600);
        try f.writeAll(out.items);
    }
    try dir.rename(tmp, file_name);
}

pub fn load(arena: Allocator, dir_path: []const u8, api_url: []const u8) !?Entry {
    const all = try readAll(arena, dir_path);
    const e = switch (all.get(api_url) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const token = switch (e.get("token") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const handle = switch (e.get("handle") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    return .{ .token = token, .handle = handle };
}

pub fn store(arena: Allocator, dir_path: []const u8, api_url: []const u8, entry: Entry) !void {
    var all = try readAll(arena, dir_path);
    var e = std.json.ObjectMap.init(arena);
    try e.put("handle", .{ .string = entry.handle });
    try e.put("token", .{ .string = entry.token });
    try all.put(api_url, .{ .object = e });
    try writeAll(arena, dir_path, all);
}

/// Removes the entry; whether there was one.
pub fn remove(arena: Allocator, dir_path: []const u8, api_url: []const u8) !bool {
    var all = try readAll(arena, dir_path);
    if (!all.orderedRemove(api_url)) return false;
    try writeAll(arena, dir_path, all);
    return true;
}

test "store, load and remove, with mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try std.testing.expect((try load(a, dir, "http://127.0.0.1:1/api/v1")) == null);
    try store(a, dir, "http://127.0.0.1:1/api/v1", .{ .token = "mopm_secret", .handle = "octocat" });
    try store(a, dir, "https://mopm.dev/api/v1", .{ .token = "mopm_other", .handle = "hubot" });
    const got = (try load(a, dir, "http://127.0.0.1:1/api/v1")).?;
    try std.testing.expectEqualStrings("mopm_secret", got.token);
    try std.testing.expectEqualStrings("octocat", got.handle);
    const st = try tmp.dir.statFile(file_name);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), st.mode & 0o777);
    try std.testing.expect(try remove(a, dir, "http://127.0.0.1:1/api/v1"));
    try std.testing.expect(!try remove(a, dir, "http://127.0.0.1:1/api/v1"));
    try std.testing.expectEqualStrings("hubot", (try load(a, dir, "https://mopm.dev/api/v1")).?.handle);
}
