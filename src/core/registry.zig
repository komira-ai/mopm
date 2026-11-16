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
const names = @import("names.zig");

/// The index version this mopm reads: version 2, whose packages are named `<namespace>/<name>`
/// (spec/index.md, "Version 2"). `config.json` lists the versions a registry serves in `index_versions`.
pub const index_version: i64 = 2;

const named = [_]struct { []const u8, []const u8 }{
    .{ "prod", "https://api.mopm.dev" },
    .{ "gamma", "https://api.gamma.mopm.dev" },
    .{ "beta", "https://api.beta.mopm.dev" },
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
    /// `api_url`, the API version 1: login, the caller and tokens, which name no package.
    api_url: []const u8,
    /// `api_v2_url`: every operation that names a package, by its full name (`/packages/<namespace>/<name>/...`).
    api_v2_url: []const u8 = "",
    /// The channel root; a namespace's channel is `<channel_url><namespace>/` (`namespaceChannel`).
    channel_url: []const u8,
    min_cli_version: []const u8,
    read_only: bool,
};

pub const Parsed = union(enum) { ok: Config, bad: []const u8 };

/// The channel a lock lists when no registry was asked (a project with no
/// registry dependency): the production channel, never contacted.
pub const default_channel_url = "https://conda.mopm.dev/";

/// The configuration of a lock that needs no registry: nothing is fetched
/// from it, so nothing about it is known but the channel the lock lists.
pub fn offlineConfig(base: []const u8) Config {
    return .{ .base = base, .stage = "", .api_url = "", .channel_url = default_channel_url, .min_cli_version = "", .read_only = false };
}

/// What mopm says of a registry that serves no index version 2: it is older than this mopm.
pub fn noVersion2(arena: Allocator, base: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "the registry at {s} serves no namespaced packages (index version 2); it is older than this mopm", .{base});
}

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
    // `index_versions` lists every version served; when absent it is `[index_version]` (spec/index.md).
    var serves_2 = ver == index_version;
    var newest = ver;
    if (o.get("index_versions")) |list| {
        const items = switch (list) {
            .array => |arr| arr.items,
            else => return .{ .bad = "config.json's index_versions is not a list of integers" },
        };
        if (items.len == 0) return .{ .bad = "config.json's index_versions is empty" };
        serves_2 = false;
        for (items) |item| switch (item) {
            .integer => |n| {
                serves_2 = serves_2 or n == index_version;
                newest = @max(newest, n);
            },
            else => return .{ .bad = "config.json's index_versions is not a list of integers" },
        };
    }
    if (!serves_2) {
        if (newest > index_version) {
            return .{ .bad = try std.fmt.allocPrint(arena, "the registry's index version is {d}; this mopm reads {d}. Update mopm.", .{ newest, index_version }) };
        }
        return .{ .bad = no_version_2 };
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
    c.api_v2_url = switch (o.get("api_v2_url") orelse return .{ .bad = "config.json serves index version 2 but has no api_v2_url" }) {
        .string => |s| s,
        else => return .{ .bad = "config.json's api_v2_url is not a string" },
    };
    if (o.get("read_only")) |r| c.read_only = switch (r) {
        .bool => |b| b,
        else => return .{ .bad = "config.json's read_only is not a boolean" },
    };
    for ([_][]const u8{ c.api_url, c.api_v2_url, c.channel_url }) |url| {
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

/// `parseConfig`'s answer for a registry whose `index_versions` lacks 2; `load` names the registry in its place.
pub const no_version_2 = "the registry serves no namespaced packages (index version 2); it is older than this mopm";

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
        .bad => |why| if (std.mem.eql(u8, why, no_version_2)) return .{ .bad = try noVersion2(arena, base) },
    }
    return parsed;
}

/// `<base>/index/v2/<aa>/<bb>/<namespace>/<name>`: the records of the package whose full name is `full` in the sparse
/// index, version 2 (spec/index.md; `aa` and `bb` are the namespace's first four characters, padded with `_` when it is
/// shorter).
pub fn indexUrl(arena: Allocator, c: Config, full: []const u8) Allocator.Error![]const u8 {
    const ns = names.namespaceOf(full);
    var pad: [4]u8 = .{ '_', '_', '_', '_' };
    const n = @min(ns.len, 4);
    @memcpy(pad[0..n], ns[0..n]);
    return std.fmt.allocPrint(arena, "{s}/index/v2/{s}/{s}/{s}", .{ c.base, pad[0..2], pad[2..4], full });
}

/// The channel of the namespace of `full` below the channel root `root` (which ends with `/`): `<root><namespace>/`
/// (spec/channel.md).
pub fn namespaceChannel(arena: Allocator, root: []const u8, full: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}/", .{ root, names.namespaceOf(full) });
}

/// The root of a namespace channel `channel` of the package `full`: `channel` without its trailing `<namespace>/`, or
/// null when it does not end so.
pub fn channelRoot(channel: []const u8, full: []const u8) ?[]const u8 {
    const ns = names.namespaceOf(full);
    if (ns.len == 0 or channel.len < ns.len + 2 or !std.mem.endsWith(u8, channel, "/")) return null;
    const head = channel[0 .. channel.len - 1];
    if (!std.mem.endsWith(u8, head, ns)) return null;
    const root = head[0 .. head.len - ns.len];
    if (!std.mem.endsWith(u8, root, "/")) return null;
    return root;
}

test "registry names and URLs" {
    try std.testing.expectEqualStrings("https://api.mopm.dev", resolve("prod").ok);
    try std.testing.expectEqualStrings("https://api.beta.mopm.dev", resolve("beta").ok);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", resolve("http://127.0.0.1:8080/").ok);
    try std.testing.expectEqualStrings("http://[::1]:9", resolve("http://[::1]:9").ok);
    for ([_][]const u8{
        "staging",             "http://example.com", "http://127.0.0.1", "http://127.0.0.1:0", "http://localhost.evil:80",
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
    const c = Config{ .base = "https://api.mopm.dev", .stage = "prod", .api_url = "", .channel_url = "", .min_cli_version = "", .read_only = false };
    try std.testing.expectEqualStrings("https://api.mopm.dev/index/v2/ko/mi/komira-ai/json", try indexUrl(a, c, "komira-ai/json"));
    try std.testing.expectEqualStrings("https://api.mopm.dev/index/v2/ab/__/ab/x1", try indexUrl(a, c, "ab/x1"));
    try std.testing.expectEqualStrings("https://api.mopm.dev/index/v2/a_/__/a/tls", try indexUrl(a, c, "a/tls"));
    try std.testing.expectEqualStrings("https://api.mopm.dev/index/v2/ab/cd/abcd/tls", try indexUrl(a, c, "abcd/tls"));
}

test "a namespace's channel, and its root back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("https://conda.mopm.dev/komira-ai/", try namespaceChannel(a, "https://conda.mopm.dev/", "komira-ai/json"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9/channel/a/", try namespaceChannel(a, "http://127.0.0.1:9/channel/", "a/bc"));
    try std.testing.expectEqualStrings("https://conda.mopm.dev/", channelRoot("https://conda.mopm.dev/komira-ai/", "komira-ai/json").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/channel/", channelRoot("http://127.0.0.1:9/channel/a/", "a/bc").?);
    // Not the namespace's channel: another namespace, one that only ends like it, the root itself, no trailing '/'.
    for ([_][]const u8{ "https://conda.mopm.dev/alice/", "https://conda.mopm.dev/xkomira-ai/", "https://conda.mopm.dev/", "https://conda.mopm.dev/komira-ai" }) |ch| {
        if (channelRoot(ch, "komira-ai/json")) |r| {
            std.debug.print("{s} gave the root {s}\n", .{ ch, r });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(channelRoot("https://conda.mopm.dev/json/", "json") == null);
}

test "config.json: a usable one, and each refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good =
        \\{"index_version":1,"index_versions":[1,2],"stage":"beta","api_url":"http://127.0.0.1:5000/api/v1",
        \\ "api_v2_url":"http://127.0.0.1:5000/api/v2",
        \\ "channel_url":"http://127.0.0.1:5000/channel/","min_cli_version":"0.0.1","read_only":true}
    ;
    const c = (try parseConfig(a, good, "0.0.1")).ok;
    try std.testing.expectEqualStrings("http://127.0.0.1:5000/api/v1", c.api_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:5000/api/v2", c.api_v2_url);
    try std.testing.expect(c.read_only);
    // A registry that serves version 2 alone, with no index_versions.
    const only_2 = (try parseConfig(a,
        \\{"index_version":2,"stage":"beta","api_url":"https://api.mopm.dev/api/v1","api_v2_url":"https://api.mopm.dev/api/v2",
        \\ "channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
    , "0.0.1")).ok;
    try std.testing.expectEqualStrings("https://api.mopm.dev/api/v2", only_2.api_v2_url);

    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "{\"index_version\":3}", "the registry's index version is 3; this mopm reads 2. Update mopm." },
        .{ "{\"index_version\":1,\"index_versions\":[1,3]}", "the registry's index version is 3; this mopm reads 2. Update mopm." },
        .{ "{\"index_version\":1}", no_version_2 },
        .{ "{\"index_version\":1,\"index_versions\":[1]}", no_version_2 },
        .{ "{\"index_version\":1,\"index_versions\":[]}", "config.json's index_versions is empty" },
        .{ "{\"index_version\":1,\"index_versions\":2}", "config.json's index_versions is not a list of integers" },
        .{ "{\"index_version\":1,\"index_versions\":[\"2\"]}", "config.json's index_versions is not a list of integers" },
        .{
            \\{"index_version":1,"index_versions":[1,2],"stage":"prod","api_url":"https://api.mopm.dev/api/v1","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
            ,
            "config.json serves index version 2 but has no api_v2_url",
        },
        .{
            \\{"index_version":1,"index_versions":[1,2],"stage":"prod","api_url":"https://api.mopm.dev/api/v1","api_v2_url":2,"channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
            ,
            "config.json's api_v2_url is not a string",
        },
        .{
            \\{"index_version":1,"index_versions":[1,2],"stage":"prod","api_url":"https://api.mopm.dev/api/v1","api_v2_url":"http://api.mopm.dev/api/v2","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
            ,
            "config.json names http://api.mopm.dev/api/v2: mopm uses https, or plain http only to a loopback host",
        },
        .{
            \\{"index_version":2,"stage":"prod","api_url":"http://api.mopm.dev/api/v1","api_v2_url":"https://api.mopm.dev/api/v2","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.0.1"}
            ,
            "config.json names http://api.mopm.dev/api/v1: mopm uses https, or plain http only to a loopback host",
        },
        .{
            \\{"index_version":2,"stage":"prod","api_url":"https://api.mopm.dev/api/v1","api_v2_url":"https://api.mopm.dev/api/v2","channel_url":"https://conda.mopm.dev/","min_cli_version":"0.2.0"}
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
