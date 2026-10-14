//! Which registry mopm talks to, and its index configuration
//! (`<registry>/index/config.json`, spec/index.md).
//!
//! `--registry` takes `prod` (the default), `gamma` or `beta` by name, or a
//! URL. A URL must be https, or plain http to a loopback host with a port
//! (127.0.0.1, [::1], localhost): a local or test registry such as
//! mopm-fake-registry. The same rule holds for the URLs in config.json, as
//! spec/index-config.schema.json says: mopm refuses any other plain-http URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const semver = @import("semver.zig");

/// The `index_version` this mopm reads.
pub const index_version: i64 = 1;

const named = [_]struct { []const u8, []const u8 }{
    .{ "prod", "https://mopm.dev" },
    .{ "gamma", "https://gamma.mopm.dev" },
    .{ "beta", "https://beta.mopm.dev" },
};

/// Whether `url` is plain http to a loopback host with an explicit port.
pub fn isLoopbackHttp(url: []const u8) bool {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return false;
    const rest = url[scheme.len..];
    const hosts = [_][]const u8{ "127.0.0.1:", "[::1]:", "localhost:" };
    for (hosts) |h| {
        if (!std.mem.startsWith(u8, rest, h)) continue;
        const after = rest[h.len..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const port = std.fmt.parseInt(u16, after[0..end], 10) catch return false;
        return port > 0 and after[0] != '0';
    }
    return false;
}

/// Whether mopm may use `url`: https with a host, or loopback http.
pub fn allowedUrl(url: []const u8) bool {
    const https = "https://";
    if (std.mem.startsWith(u8, url, https)) {
        const host_end = std.mem.indexOfScalar(u8, url[https.len..], '/') orelse url.len - https.len;
        return host_end > 0;
    }
    return isLoopbackHttp(url);
}

pub const Resolved = union(enum) { ok: []const u8, bad: []const u8 };

/// The base URL `--registry <spec>` names, without a trailing slash.
pub fn resolve(spec: []const u8) Resolved {
    for (named) |n| {
        if (std.mem.eql(u8, n[0], spec)) return .{ .ok = n[1] };
    }
    if (std.mem.indexOf(u8, spec, "://") == null) {
        return .{ .bad = "a registry is prod, gamma, beta, or a URL" };
    }
    if (!allowedUrl(spec)) {
        return .{ .bad = "a registry URL is https, or plain http only to 127.0.0.1, [::1] or localhost with a port" };
    }
    return .{ .ok = std.mem.trimRight(u8, spec, "/") };
}

pub const Config = struct {
    /// The registry's base URL (what `--registry` resolved to); the index
    /// lives under `<base>/index/`.
    base: []const u8 = "",
    stage: []const u8,
    api_url: []const u8,
    channel_url: []const u8,
    min_cli_version: []const u8,
    read_only: bool,
};

pub const Parsed = union(enum) { ok: Config, bad: []const u8 };

/// Checks a config.json against what this mopm (`cli_version`) can use.
pub fn parseConfig(arena: Allocator, text: []const u8, cli_version: []const u8) Allocator.Error!Parsed {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return .{ .bad = "config.json is not JSON" };
    const o = switch (v) {
        .object => |o| o,
        else => return .{ .bad = "config.json is not a JSON object" },
    };
    const ver = switch (o.get("index_version") orelse return .{ .bad = "config.json has no index_version" }) {
        .integer => |n| n,
        else => return .{ .bad = "config.json's index_version is not an integer" },
    };
    if (ver != index_version) {
        return .{ .bad = try std.fmt.allocPrint(arena, "the registry's index version is {d}; this mopm reads {d}. Update mopm.", .{ ver, index_version }) };
    }
    var c = Config{ .stage = "", .api_url = "", .channel_url = "", .min_cli_version = "", .read_only = false };
    const fields = [_]struct { []const u8, *[]const u8 }{
        .{ "stage", &c.stage },
        .{ "api_url", &c.api_url },
        .{ "channel_url", &c.channel_url },
        .{ "min_cli_version", &c.min_cli_version },
    };
    for (fields) |f| {
        f[1].* = switch (o.get(f[0]) orelse return .{ .bad = try std.fmt.allocPrint(arena, "config.json has no {s}", .{f[0]}) }) {
            .string => |s| s,
            else => return .{ .bad = try std.fmt.allocPrint(arena, "config.json's {s} is not a string", .{f[0]}) },
        };
    }
    if (o.get("read_only")) |r| c.read_only = switch (r) {
        .bool => |b| b,
        else => return .{ .bad = "config.json's read_only is not a boolean" },
    };
    for ([_][]const u8{ c.api_url, c.channel_url }) |url| {
        if (!allowedUrl(url)) {
            return .{ .bad = try std.fmt.allocPrint(arena, "config.json names {s}: mopm uses https, or plain http only to a loopback host", .{url}) };
        }
    }
    const need = semver.parseVersion(c.min_cli_version) orelse return .{ .bad = "config.json's min_cli_version is not a version" };
    const have = semver.parseVersion(cli_version) orelse return .{ .bad = "this mopm's version is not a version" };
    if (semver.compare(have, need) == .lt) {
        return .{ .bad = try std.fmt.allocPrint(arena, "this registry needs mopm {s} or newer; this is {s}. Update mopm.", .{ c.min_cli_version, cli_version }) };
    }
    return .{ .ok = c };
}

/// Fetches and checks `<base>/index/config.json`.
pub fn load(arena: Allocator, base: []const u8, cli_version: []const u8) !Parsed {
    const url = try std.fmt.allocPrint(arena, "{s}/index/config.json", .{base});
    const answer = http.request(arena, .GET, url, .{}) catch |e| {
        return .{ .bad = try std.fmt.allocPrint(arena, "cannot reach {s}: {s}", .{ url, @errorName(e) }) };
    };
    if (!answer.ok()) {
        return .{ .bad = try std.fmt.allocPrint(arena, "{s} answered HTTP {d}", .{ url, answer.status }) };
    }
    var parsed = try parseConfig(arena, answer.body, cli_version);
    switch (parsed) {
        .ok => |*c| c.base = base,
        .bad => {},
    }
    return parsed;
}

/// `<base>/index/<aa>/<bb>/<name>`: a package's records in the sparse index
/// (spec/index.md; `bb` padded with `_` for names shorter than four).
pub fn indexUrl(arena: Allocator, c: Config, name: []const u8) Allocator.Error![]const u8 {
    var pad: [4]u8 = .{ '_', '_', '_', '_' };
    const n = @min(name.len, 4);
    @memcpy(pad[0..n], name[0..n]);
    return std.fmt.allocPrint(arena, "{s}/index/{s}/{s}/{s}", .{ c.base, pad[0..2], pad[2..4], name });
}

test "registry names and URLs" {
    try std.testing.expectEqualStrings("https://mopm.dev", resolve("prod").ok);
    try std.testing.expectEqualStrings("https://beta.mopm.dev", resolve("beta").ok);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", resolve("http://127.0.0.1:8080/").ok);
    try std.testing.expectEqualStrings("http://[::1]:9", resolve("http://[::1]:9").ok);
    for ([_][]const u8{
        "staging", "http://example.com", "http://127.0.0.1", "http://127.0.0.1:0", "http://localhost.evil:80",
        "http://127.0.0.2:80", "ftp://127.0.0.1:21", "https://",
    }) |bad| {
        if (resolve(bad) != .bad) {
            std.debug.print("accepted {s}\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "index URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = Config{ .base = "https://mopm.dev", .stage = "prod", .api_url = "", .channel_url = "", .min_cli_version = "", .read_only = false };
    try std.testing.expectEqualStrings("https://mopm.dev/index/ht/tp/http_client", try indexUrl(a, c, "http_client"));
    try std.testing.expectEqualStrings("https://mopm.dev/index/tl/s_/tls", try indexUrl(a, c, "tls"));
}

test "config.json: a usable one, and each refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good =
        \\{"index_version":1,"stage":"beta","api_url":"http://127.0.0.1:5000/api/v1",
        \\ "channel_url":"http://127.0.0.1:5000/channel/","min_cli_version":"0.0.1","read_only":true}
    ;
    const c = (try parseConfig(a, good, "0.0.1")).ok;
    try std.testing.expectEqualStrings("http://127.0.0.1:5000/api/v1", c.api_url);
    try std.testing.expect(c.read_only);

    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "{\"index_version\":2}", "the registry's index version is 2; this mopm reads 1. Update mopm." },
        .{
            \\{"index_version":1,"stage":"prod","api_url":"http://mopm.dev/api/v1","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
            ,
            "config.json names http://mopm.dev/api/v1: mopm uses https, or plain http only to a loopback host",
        },
        .{
            \\{"index_version":1,"stage":"prod","api_url":"https://mopm.dev/api/v1","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.2.0"}
            ,
            "this registry needs mopm 0.2.0 or newer; this is 0.0.1. Update mopm.",
        },
        .{ "[]", "config.json is not a JSON object" },
    };
    for (cases) |case| {
        const got = try parseConfig(a, case[0], "0.0.1");
        if (got != .bad) return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case[1], got.bad);
    }
}
