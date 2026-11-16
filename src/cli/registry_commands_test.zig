//! Tests of the generated command table `registry_commands.zig` as built, by behaviour: each command is run through
//! `api_cmd.dispatch` (the name lookup the command line uses) against the scripted registry of group_publish_test.zig,
//! so a test reads the request the arguments became and what the command printed. api_cmd_test.zig tests the engine on
//! small tables of its own; this file proves the generated entries: every command's route, body, token and help, and
//! the names the table does not have.

const std = @import("std");
const Allocator = std.mem.Allocator;
const at = @import("api_cmd_test.zig");
const gt = @import("group_publish_test.zig");
const api_cmd = @import("api_cmd.zig");
const registry_commands = @import("registry_commands.zig");

const api_v2 = at.api_v2;

/// One generated command run with valid arguments: the request it must make.
const Route = struct {
    /// The command's name in the table.
    name: []const u8,
    /// The arguments after `mopm`.
    args: []const []const u8,
    method: std.http.Method,
    /// The URL after the registry's API version 2 base.
    target: []const u8,
    /// The JSON body sent, or null for none.
    body: ?[]const u8 = null,
    /// Standard input, for the commands that take `--body -`.
    stdin: []const u8 = "",
};

/// One route per generated command, in the table's order.
const routes = [_]Route{
    .{ .name = "health", .args = &.{"health"}, .method = .GET, .target = "/health" },
    .{ .name = "api start-device-login", .args = &.{ "api", "start-device-login" }, .method = .POST, .target = "/auth/device", .body = "{\"client\":\"mopm 9.9.9\"}" },
    .{ .name = "api poll-device-login", .args = &.{ "api", "poll-device-login", "dc_1" }, .method = .POST, .target = "/auth/device/poll", .body = "{\"device_code\":\"dc_1\"}" },
    .{ .name = "api exchange-oidc-token", .args = &.{ "api", "exchange-oidc-token", "--body", "-" }, .method = .POST, .target = "/auth/oidc/exchange", .body = "{\"jwt\":\"j\"}", .stdin = "{\"jwt\": \"j\"}\n" },
    .{ .name = "whoami", .args = &.{"whoami"}, .method = .GET, .target = "/me" },
    .{ .name = "token create", .args = &.{ "token", "create", "ci", "--scopes", "publish", "--scopes=stage", "--packages", "acme/a", "--expires-in-days", "7" }, .method = .POST, .target = "/me/tokens", .body = "{\"name\":\"ci\",\"scopes\":[\"publish\",\"stage\"],\"packages\":[\"acme/a\"],\"expires_in_days\":7}" },
    .{ .name = "token list", .args = &.{ "token", "list" }, .method = .GET, .target = "/me/tokens" },
    .{ .name = "token revoke", .args = &.{ "token", "revoke", "tok_1" }, .method = .DELETE, .target = "/me/tokens/tok_1" },
    .{ .name = "api create-namespace", .args = &.{ "api", "create-namespace", "acme" }, .method = .POST, .target = "/namespaces", .body = "{\"namespace\":\"acme\"}" },
    .{ .name = "api poll-namespace", .args = &.{ "api", "poll-namespace", "dc_2" }, .method = .POST, .target = "/namespaces/poll", .body = "{\"device_code\":\"dc_2\"}" },
    .{ .name = "namespace info", .args = &.{ "namespace", "info", "acme" }, .method = .GET, .target = "/namespaces/acme" },
    .{ .name = "org list", .args = &.{ "org", "list", "acme" }, .method = .GET, .target = "/namespaces/acme/members" },
    .{ .name = "org add", .args = &.{ "org", "add", "acme", "ada" }, .method = .PUT, .target = "/namespaces/acme/members/ada", .body = "{\"role\":\"member\"}" },
    .{ .name = "org remove", .args = &.{ "org", "remove", "acme", "ada" }, .method = .DELETE, .target = "/namespaces/acme/members/ada" },
    .{ .name = "search", .args = &.{ "search", "json", "--sort", "updated", "--limit", "5" }, .method = .GET, .target = "/packages?q=json&sort=updated&limit=5" },
    .{ .name = "package info", .args = &.{ "package", "info", "acme/foo" }, .method = .GET, .target = "/packages/acme/foo" },
    .{ .name = "package create", .args = &.{ "package", "create", "acme/foo" }, .method = .PUT, .target = "/packages/acme/foo" },
    .{ .name = "package versions", .args = &.{ "package", "versions", "acme/foo" }, .method = .GET, .target = "/packages/acme/foo/versions" },
    .{ .name = "package version", .args = &.{ "package", "version", "acme/foo", "1.0.0" }, .method = .GET, .target = "/packages/acme/foo/1.0.0" },
    .{ .name = "api begin-upload", .args = &.{ "api", "begin-upload", "acme/foo", "1.0.0", "--subdir", "noarch", "--filename", "foo.conda", "--sha256", "ab", "--size", "3" }, .method = .POST, .target = "/packages/acme/foo/1.0.0/files", .body = "{\"subdir\":\"noarch\",\"filename\":\"foo.conda\",\"sha256\":\"ab\",\"size\":3}" },
    .{ .name = "api commit-publish", .args = &.{ "api", "commit-publish", "acme/foo", "1.0.0", "--upload-ids", "up_1" }, .method = .POST, .target = "/packages/acme/foo/1.0.0/publish", .body = "{\"upload_ids\":[\"up_1\"]}" },
    .{ .name = "publish status", .args = &.{ "publish", "status", "pub_1" }, .method = .GET, .target = "/publishes/pub_1" },
    .{ .name = "api create-group", .args = &.{ "api", "create-group", "--body", "-" }, .method = .POST, .target = "/groups", .body = "{\"members\":[]}", .stdin = "{\"members\": []}\n" },
    .{ .name = "group status", .args = &.{ "group", "status", "grp_1" }, .method = .GET, .target = "/groups/grp_1" },
    .{ .name = "group abort", .args = &.{ "group", "abort", "grp_1" }, .method = .DELETE, .target = "/groups/grp_1" },
    .{ .name = "api commit-group", .args = &.{ "api", "commit-group", "grp_1", "--body", "-" }, .method = .POST, .target = "/groups/grp_1/commit", .body = "{\"members\":[]}", .stdin = "{\"members\": []}\n" },
    .{ .name = "group yank", .args = &.{ "group", "yank", "grp_1", "--reason", "bad" }, .method = .PUT, .target = "/groups/grp_1/yank", .body = "{\"yanked\":true,\"reason\":\"bad\"}" },
    .{ .name = "group unyank", .args = &.{ "group", "unyank", "grp_1" }, .method = .PUT, .target = "/groups/grp_1/yank", .body = "{\"yanked\":false}" },
    .{ .name = "yank", .args = &.{ "yank", "acme/foo", "1.0.0", "--reason", "bad" }, .method = .PUT, .target = "/packages/acme/foo/1.0.0/yank", .body = "{\"yanked\":true,\"reason\":\"bad\"}" },
    .{ .name = "unyank", .args = &.{ "unyank", "acme/foo", "1.0.0" }, .method = .PUT, .target = "/packages/acme/foo/1.0.0/yank", .body = "{\"yanked\":false}" },
};

/// A refusal every route is answered with: what the command prints for it does not depend on the operation.
const refusal = "{\"error\":{\"code\":\"package_not_found\",\"message\":\"Not here.\",\"hint\":\"Look elsewhere.\"}}";
const refusal_text = "mopm: Not here.\n  code: package_not_found\n  hint: Look elsewhere.\n  request id: req-test\n";

test "the routes of this file name every generated command once, in the table's order" {
    try std.testing.expectEqual(registry_commands.commands.len, routes.len);
    inline for (registry_commands.commands, 0..) |c, i| {
        try std.testing.expectEqualStrings(c.name, routes[i].name);
    }
}

test "every generated command makes its operation's request: method, URL, body, and the token only when it needs one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (registry_commands.commands, 0..) |c, i| {
        const r = comptime routes[i];
        const steps = [_]gt.Script.Step{at.step(r.method, r.target, 404, refusal)};
        const d = try at.runDispatch(a, &tmp, &steps, .{ .token_env = "env-token", .stdin = r.stdin }, r.args);
        // The command's name leads each compared text, so a failure says which command it is.
        const got = try std.fmt.allocPrint(a, "{s}: exit {?d}\n{s}{s}", .{ r.name, d.code, d.out, d.err });
        try std.testing.expectEqualStrings(r.name ++ ": exit 1\n" ++ refusal_text, got);
        try std.testing.expectEqual(@as(usize, 1), d.script.seen.items.len);
        const seen = d.script.seen.items[0];
        const request = try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ r.name, @tagName(seen.method), seen.url });
        try std.testing.expectEqualStrings(r.name ++ ": " ++ @tagName(r.method) ++ " " ++ api_v2 ++ r.target, request);
        if (r.body) |b| try std.testing.expectEqualStrings(b, seen.body.?) else try std.testing.expectEqual(@as(?[]const u8, null), seen.body);
        if (c.token) try std.testing.expectEqualStrings("env-token", seen.token.?) else try std.testing.expectEqual(@as(?[]const u8, null), seen.token);
    }
}

test "every generated command prints its own help for --help, exit 0, and makes no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (registry_commands.commands) |c| {
        var args = std.ArrayList([]const u8).init(a);
        var words = std.mem.splitScalar(u8, c.name, ' ');
        while (words.next()) |w| try args.append(w);
        try args.append("--help");
        const d = try at.runDispatch(a, &tmp, &.{}, .{}, args.items);
        try std.testing.expectEqual(@as(?u8, 0), d.code);
        try std.testing.expectEqualStrings(c.help, d.out);
        try std.testing.expectEqualStrings("", d.err);
        try std.testing.expectEqual(@as(usize, 0), d.script.seen.items.len);
    }
}

test "a generated command answered ok prints the answer as text, and as JSON with --json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const health = "{\"status\":\"ok\",\"stage\":\"beta\",\"api_version\":\"v2\",\"read_only\":false}";
    const steps = [_]gt.Script.Step{at.step(.GET, "/health", 200, health)};
    const text = try at.runDispatch(a, &tmp, &steps, .{}, &.{"health"});
    try std.testing.expectEqual(@as(?u8, 0), text.code);
    try std.testing.expectEqualStrings("status: ok\nstage: beta\napi_version: v2\nread_only: false\n", text.out);
    try std.testing.expectEqualStrings("", text.err);
    const json = try at.runDispatch(a, &tmp, &steps, .{}, &.{ "health", "--json" });
    try std.testing.expectEqual(@as(?u8, 0), json.code);
    try std.testing.expectEqualStrings("{\n  \"status\": \"ok\",\n  \"stage\": \"beta\",\n  \"api_version\": \"v2\",\n  \"read_only\": false\n}\n", json.out);
    const revoked = [_]gt.Script.Step{at.step(.DELETE, "/me/tokens/tok_1", 204, "")};
    const done = try at.runDispatch(a, &tmp, &revoked, .{ .token_env = "t" }, &.{ "token", "revoke", "tok_1" });
    try std.testing.expectEqual(@as(?u8, 0), done.code);
    try std.testing.expectEqualStrings("Done.\n", done.out);
}

test "a mistake in the arguments of a generated command is its usage error, exit 2, and no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const usage_of = struct {
        fn f(comptime name: []const u8) []const u8 {
            inline for (registry_commands.commands) |c| {
                if (comptime std.mem.eql(u8, c.name, name)) return c.usage;
            }
            @compileError("no generated command " ++ name);
        }
    }.f;
    const Case = struct { args: []const []const u8, err: []const u8 };
    const cases = comptime [_]Case{
        .{ .args = &.{ "token", "create", "ci", "--packages", "all_current", "--expires-in-days", "7" }, .err = "mopm token create: missing required option --scopes <publish|yank|stage>...\n" ++ usage_of("token create") },
        .{ .args = &.{ "token", "create", "ci", "--scopes", "admin", "--packages", "all_current", "--expires-in-days", "7" }, .err = "mopm token create: --scopes: 'admin' is not one of publish, yank, stage\n" ++ usage_of("token create") },
        .{ .args = &.{ "token", "create", "ci", "--scopes", "publish", "--packages", "all_current", "--expires-in-days", "soon" }, .err = "mopm token create: --expires-in-days: 'soon' is not a whole number\n" ++ usage_of("token create") },
        .{ .args = &.{ "package", "version", "acme/foo" }, .err = "mopm package version: missing argument <version>\n" ++ usage_of("package version") },
        .{ .args = &.{ "package", "versions", "acme/foo", "1.0.0" }, .err = "mopm package versions: unexpected argument '1.0.0'\n" ++ usage_of("package versions") },
        .{ .args = &.{ "yank", "acme", "1.0.0" }, .err = "mopm yank: 'acme' is not a full name <namespace>/<name>\n" ++ usage_of("yank") },
        .{ .args = &.{ "api", "create-group" }, .err = "mopm api create-group: missing required option --body <file>\n" ++ usage_of("api create-group") },
        .{ .args = &.{ "whoami", "--scopes", "publish" }, .err = "mopm whoami: unknown option '--scopes'\n" ++ usage_of("whoami") },
    };
    for (cases) |case| {
        const d = try at.runDispatch(a, &tmp, &.{}, .{ .token_env = "t" }, case.args);
        try std.testing.expectEqual(@as(?u8, 2), d.code);
        try std.testing.expectEqualStrings("", d.out);
        try std.testing.expectEqualStrings(case.err, d.err);
        try std.testing.expectEqual(@as(usize, 0), d.script.seen.items.len);
    }
}

test "arguments that name no generated command are left to the rest of the command line: null, nothing printed, no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // No arguments, a hand-written command, a group word alone, a group word with a command it lacks, and a word that
    // only begins like a command.
    const cases = [_][]const []const u8{ &.{}, &.{ "publish", "--staged" }, &.{"token"}, &.{ "group", "list" }, &.{"healthy"} };
    for (cases) |args| {
        const d = try at.runDispatch(a, &tmp, &.{}, .{}, args);
        try std.testing.expectEqual(@as(?u8, null), d.code);
        try std.testing.expectEqualStrings("", d.out);
        try std.testing.expectEqualStrings("", d.err);
        try std.testing.expectEqual(@as(usize, 0), d.script.seen.items.len);
    }
}

test "a group word alone lists the generated commands under it, and a word with none, or a part of a word, lists nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "mopm token: which command?\n" ++
            "  token create             Create an API token; its secret is printed once.\n" ++
            "  token list               List the API tokens of the account.\n" ++
            "  token revoke             Revoke an API token.\n",
        api_cmd.groupUsage(a, "token").?,
    );
    try std.testing.expectEqualStrings(
        "mopm group: which command?\n" ++
            "  group status             Show a publish group: its state, its members and its yank.\n" ++
            "  group abort              End an open publish group without publishing it.\n" ++
            "  group yank               Yank every version a publish group published.\n" ++
            "  group unyank             Restore the versions a group's yank changed.\n",
        api_cmd.groupUsage(a, "group").?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), api_cmd.groupUsage(a, "frobnicate"));
    try std.testing.expectEqual(@as(?[]const u8, null), api_cmd.groupUsage(a, "tok"));
    try std.testing.expectEqual(@as(?[]const u8, null), api_cmd.groupUsage(a, "create"));
}
