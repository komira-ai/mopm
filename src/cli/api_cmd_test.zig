//! Tests of the engine that runs generated registry commands (api_cmd.zig), by behaviour. The commands here are small
//! tables of the same shape as the generated `registry_commands.zig`, pointing at real operations of the generated client;
//! the registry is the scripted stand-in of group_publish_test.zig, so a test reads the request a command made and the
//! text it printed. `runDispatch` runs arguments through the generated table itself, for registry_commands_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const credentials = core.credentials;
const v2 = core.registry_v2;
const gp = @import("group_publish.zig");
const gt = @import("group_publish_test.zig");
const registry_cmd = @import("registry_cmd.zig");
const api_cmd = @import("api_cmd.zig");
const spec = @import("api_spec.zig");
const Script = gt.Script;

const api_v1 = "http://127.0.0.1:1/api/v1";
pub const api_v2 = "http://127.0.0.1:1/api/v2";

const tail = " [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n";

const health_cmd = spec.Command{
    .name = "health",
    .Op = v2.GetHealth,
    .summary = "Show whether the registry is up.",
    .usage = "usage: mopm health" ++ tail,
    .help = "HELP OF health\n",
    .token = false,
    .body = .none,
};

const member_cmd = spec.Command{
    .name = "org add",
    .Op = v2.SetMember,
    .summary = "Add a member.",
    .usage = "usage: mopm org add <namespace> <user> [--role <owner|member>]" ++ tail,
    .help = "HELP OF org add\n",
    .token = true,
    .body = .flags,
    .args = &.{
        .{ .meta = "<namespace>", .key = "namespace" },
        .{ .meta = "<user>", .key = "user" },
    },
    .flags = &.{
        .{ .flag = "--role", .meta = "<owner|member>", .key = "role", .in = .body, .kind = .enumeration, .values = &.{ "owner", "member" }, .default = "\"member\"" },
    },
};

const search_cmd = spec.Command{
    .name = "search",
    .Op = v2.SearchPackages,
    .summary = "Search the packages by name.",
    .usage = "usage: mopm search [<q>] [--sort <name|updated>] [--cursor <cursor>] [--limit <n>]" ++ tail,
    .help = "HELP OF search\n",
    .token = false,
    .body = .none,
    .args = &.{
        .{ .meta = "<q>", .key = "q", .optional = true },
    },
    .flags = &.{
        .{ .flag = "--sort", .meta = "<name|updated>", .key = "sort", .in = .params, .kind = .enumeration, .values = &.{ "name", "updated" } },
        .{ .flag = "--cursor", .meta = "<cursor>", .key = "cursor", .in = .params, .kind = .string },
        .{ .flag = "--limit", .meta = "<n>", .key = "limit", .in = .params, .kind = .integer },
    },
};

const token_create_cmd = spec.Command{
    .name = "token create",
    .Op = v2.CreateToken,
    .summary = "Create an API token.",
    .usage = "usage: mopm token create <name> --scope <publish|yank|stage>... --packages <full name>...|all_current [--expires-in-days <n>]" ++ tail,
    .help = "HELP OF token create\n",
    .token = true,
    .body = .flags,
    .args = &.{
        .{ .meta = "<name>", .key = "name", .in = .body },
    },
    .flags = &.{
        .{ .flag = "--scope", .meta = "<publish|yank|stage>...", .key = "scopes", .in = .body, .kind = .enumeration, .values = &.{ "publish", "yank", "stage" }, .required = true, .repeated = true },
        .{ .flag = "--packages", .meta = "<full name>...|all_current", .key = "packages", .in = .body, .kind = .names_or_const, .required = true, .repeated = true, .const_value = "all_current" },
        .{ .flag = "--expires-in-days", .meta = "<n>", .key = "expires_in_days", .in = .body, .kind = .integer, .default = "90" },
    },
};

/// A command whose `set` holds the version of the mopm that sends it.
const token_auto_cmd = spec.Command{
    .name = "token auto",
    .Op = v2.CreateToken,
    .summary = "Create the token of a CI job.",
    .usage = "usage: mopm token auto --scope <publish|yank|stage>..." ++ tail,
    .help = "HELP OF token auto\n",
    .token = true,
    .body = .flags,
    .flags = &.{
        .{ .flag = "--scope", .meta = "<publish|yank|stage>...", .key = "scopes", .in = .body, .kind = .enumeration, .values = &.{ "publish", "yank", "stage" }, .required = true, .repeated = true },
        .{ .flag = "--packages", .meta = "<full name>...|all_current", .key = "packages", .in = .body, .kind = .names_or_const, .repeated = true, .const_value = "all_current", .default = "\"all_current\"" },
        .{ .flag = "--expires-in-days", .meta = "<n>", .key = "expires_in_days", .in = .body, .kind = .integer, .default = "30" },
    },
    .set = &.{
        .{ .key = "name", .json = "\"mopm {cli_version}\"" },
    },
};

const revoke_cmd = spec.Command{
    .name = "token revoke",
    .Op = v2.RevokeToken,
    .summary = "Revoke an API token.",
    .usage = "usage: mopm token revoke <token_id>" ++ tail,
    .help = "HELP OF token revoke\n",
    .token = true,
    .body = .none,
    .args = &.{
        .{ .meta = "<token_id>", .key = "token_id" },
    },
};

const yank_cmd = spec.Command{
    .name = "yank",
    .Op = v2.SetYanked,
    .summary = "Yank a version.",
    .usage = "usage: mopm yank <namespace>/<name> <version> [--reason <reason>]" ++ tail,
    .help = "HELP OF yank\n",
    .token = true,
    .body = .flags,
    .args = &.{
        .{ .meta = "<namespace>/<name>", .key = "namespace/name", .full_name = true },
        .{ .meta = "<version>", .key = "version" },
    },
    .flags = &.{
        .{ .flag = "--reason", .meta = "<reason>", .key = "reason", .in = .body, .kind = .string },
    },
    .set = &.{
        .{ .key = "yanked", .json = "true" },
    },
};

/// A command whose body holds a boolean flag, and so leaves out a field the body needs when the flag is not given.
const yank_flag_cmd = spec.Command{
    .name = "yank flag",
    .Op = v2.SetYanked,
    .summary = "Yank a version.",
    .usage = "usage: mopm yank flag <namespace>/<name> <version> [--yanked]" ++ tail,
    .help = "HELP OF yank flag\n",
    .token = true,
    .body = .flags,
    .args = &.{
        .{ .meta = "<namespace>/<name>", .key = "namespace/name", .full_name = true },
        .{ .meta = "<version>", .key = "version" },
    },
    .flags = &.{
        .{ .flag = "--yanked", .meta = "", .key = "yanked", .in = .body, .kind = .boolean },
    },
};

const group_cmd = spec.Command{
    .name = "api create-group",
    .Op = v2.CreateGroup,
    .summary = "Create or continue a publish group.",
    .usage = "usage: mopm api create-group --body <file>" ++ tail,
    .help = "HELP OF api create-group\n",
    .token = true,
    .body = .file,
};

pub const Opts = struct {
    /// What `$MOPM_TOKEN` holds.
    token_env: ?[]const u8 = null,
    /// The token `mopm login` stored.
    stored: ?[]const u8 = null,
    stdin: []const u8 = "",
    /// The registry serves no API version 2.
    no_v2: bool = false,
    /// The session cannot be opened.
    no_session: bool = false,
};

pub const TestEnv = struct {
    session: ?registry_cmd.Session,
    token: ?[]const u8,
    stdin: []const u8,
    flags: registry_cmd.Flags = .{},

    fn env(t: *TestEnv) api_cmd.Env {
        return .{ .ctx = t, .open_fn = openFn, .token_fn = tokenFn, .stdin_fn = stdinFn, .cli_version = "9.9.9" };
    }

    fn openFn(ctx: *anyopaque, _: Allocator, flags: registry_cmd.Flags, _: []const u8) ?registry_cmd.Session {
        const t: *TestEnv = @ptrCast(@alignCast(ctx));
        t.flags = flags;
        return t.session;
    }

    fn tokenFn(ctx: *anyopaque, _: Allocator) ?[]const u8 {
        const t: *TestEnv = @ptrCast(@alignCast(ctx));
        return t.token;
    }

    fn stdinFn(ctx: *anyopaque, _: Allocator) anyerror![]const u8 {
        const t: *TestEnv = @ptrCast(@alignCast(ctx));
        return t.stdin;
    }
};

pub const Run = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
    script: Script,
    flags: registry_cmd.Flags,

    pub fn expect(r: Run, code: u8, out: []const u8, err: []const u8) !void {
        try std.testing.expectEqualStrings(out, r.out);
        try std.testing.expectEqualStrings(err, r.err);
        try std.testing.expectEqual(code, r.code);
    }

    pub fn requests(r: Run) usize {
        return r.script.seen.items.len;
    }
};

fn runCmd(comptime c: spec.Command, a: Allocator, tmp: *std.testing.TmpDir, steps: []const Script.Step, opts: Opts, args: []const []const u8) !Run {
    var h = try Harness.init(a, tmp, steps, opts);
    const code = try api_cmd.execute(c, a, h.net(), &h.con, h.state.env(), args);
    return h.finish(code);
}

/// What `api_cmd.dispatch` did with `args`: `code` is null when no generated command has that name.
pub const Dispatched = struct {
    code: ?u8,
    out: []const u8,
    err: []const u8,
    script: Script,
};

/// Runs `args` (the arguments after `mopm`) through `api_cmd.dispatch`, that is through the generated table
/// `registry_commands.zig` as built, against the scripted registry.
pub fn runDispatch(a: Allocator, tmp: *std.testing.TmpDir, steps: []const Script.Step, opts: Opts, args: []const []const u8) !Dispatched {
    var h = try Harness.init(a, tmp, steps, opts);
    const code = try api_cmd.dispatch(a, h.net(), &h.con, h.state.env(), args);
    return .{ .code = code, .out = h.con.out.items, .err = h.con.err.items, .script = h.script };
}

/// The session, the environment, the scripted registry and the console of one run of a command.
const Harness = struct {
    state: TestEnv,
    script: Script,
    con: gp.Console,

    fn init(a: Allocator, tmp: *std.testing.TmpDir, steps: []const Script.Step, opts: Opts) !Harness {
        const dir = try tmp.dir.realpathAlloc(a, ".");
        if (opts.stored) |t| try credentials.store(a, dir, api_v1, .{ .token = t, .handle = "ada" });
        return .{
            .state = .{
                .session = if (opts.no_session) null else .{
                    .arena = a,
                    .config = .{
                        .stage = "beta",
                        .api_url = api_v1,
                        .api_v2_url = if (opts.no_v2) "" else api_v2,
                        .channel_url = "http://127.0.0.1:1/",
                        .min_cli_version = "0.0.0",
                        .read_only = false,
                    },
                    .config_dir = dir,
                },
                .token = opts.token_env,
                .stdin = opts.stdin,
            },
            .script = gt.newScript(a, steps),
            .con = gp.Console.init(a, null),
        };
    }

    /// The scripted registry as the network, with no retries; called once the harness is in its final place.
    fn net(h: *Harness) gp.Net {
        var n = h.script.net();
        n.policy = .{ .retries = 0 };
        return n;
    }

    fn finish(h: *Harness, code: u8) Run {
        return .{ .code = code, .out = h.con.out.items, .err = h.con.err.items, .script = h.script, .flags = h.state.flags };
    }
};

pub fn step(method: std.http.Method, suffix: []const u8, status: u16, body: []const u8) Script.Step {
    return .{ .method = method, .suffix = suffix, .status = status, .body = body };
}

const health_body = "{\"status\":\"ok\",\"stage\":\"beta\",\"api_version\":\"v2\",\"read_only\":false}";
const member_body = "{\"user\":\"ada\",\"handle\":\"Ada\",\"github_id\":7,\"role\":\"owner\",\"added_at\":\"2026-10-01T00:00:00Z\"}";
const member_text = "user: ada\nhandle: Ada\ngithub_id: 7\nrole: owner\nadded_at: 2026-10-01T00:00:00Z\n";
const token_body = "{\"id\":\"tok_1\",\"name\":\"ci\",\"token\":\"mopm_secret\",\"scopes\":[\"publish\"],\"packages\":[\"acme/a\"],\"expires_at\":\"2027-01-01T00:00:00Z\"}";
const group_body = "{\"group_id\":\"grp_1\",\"status\":\"open\",\"attempt\":1,\"deadline_at\":\"2026-10-01T00:00:00Z\",\"members\":[]}";

test "--help prints the help text on standard output, exit 0, even beside bad arguments, and makes no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "--bogus", "--help" });
    try r.expect(0, "HELP OF org add\n", "");
    try std.testing.expectEqual(@as(usize, 0), r.requests());
    const short = try runCmd(health_cmd, a, &tmp, &.{}, .{}, &.{"-h"});
    try short.expect(0, "HELP OF health\n", "");
}

test "an unknown option is a usage error: the message and the usage line on standard error, exit 2, no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--bogus" });
    try r.expect(2, "", "mopm org add: unknown option '--bogus'\n" ++ member_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
    const single = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "-x" });
    try single.expect(2, "", "mopm org add: unknown option '-x'\n" ++ member_cmd.usage);
    const body_flag = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--body", "x" });
    try body_flag.expect(2, "", "mopm org add: unknown option '--body'\n" ++ member_cmd.usage);
}

test "a flag with no value is a usage error, also when the next argument is another flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const last = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--role" });
    try last.expect(2, "", "mopm org add: --role needs a value\n" ++ member_cmd.usage);
    const before_flag = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--role", "--json" });
    try before_flag.expect(2, "", "mopm org add: --role needs a value\n" ++ member_cmd.usage);
    const registry_flag = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--registry" });
    try registry_flag.expect(2, "", "mopm org add: --registry needs a value\n" ++ member_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), registry_flag.requests());
}

test "a missing positional argument and an extra one are usage errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{"acme"});
    try missing.expect(2, "", "mopm org add: missing argument <user>\n" ++ member_cmd.usage);
    const extra = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "bob" });
    try extra.expect(2, "", "mopm org add: unexpected argument 'bob'\n" ++ member_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), extra.requests());
}

test "a full name that is not namespace/name is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bare = try runCmd(yank_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "1.0.0" });
    try bare.expect(2, "", "mopm yank: 'acme' is not a full name <namespace>/<name>\n" ++ yank_cmd.usage);
    const deep = try runCmd(yank_cmd, a, &tmp, &.{}, .{}, &.{ "a/b/c", "1.0.0" });
    try deep.expect(2, "", "mopm yank: 'a/b/c' is not a full name <namespace>/<name>\n" ++ yank_cmd.usage);
    const open_end = try runCmd(yank_cmd, a, &tmp, &.{}, .{}, &.{ "acme/", "1.0.0" });
    try open_end.expect(2, "", "mopm yank: 'acme/' is not a full name <namespace>/<name>\n" ++ yank_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), open_end.requests());
}

test "a required flag that is missing is a usage error naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(token_create_cmd, a, &tmp, &.{}, .{}, &.{ "ci", "--packages", "all_current" });
    try r.expect(2, "", "mopm token create: missing required option --scope <publish|yank|stage>...\n" ++ token_create_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "an enumeration value that is not allowed is a usage error listing the allowed ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--role", "admin" });
    try r.expect(2, "", "mopm org add: --role: 'admin' is not one of owner, member\n" ++ member_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "an integer that does not parse is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(search_cmd, a, &tmp, &.{}, .{}, &.{ "--limit", "ten" });
    try r.expect(2, "", "mopm search: --limit: 'ten' is not a whole number\n" ++ search_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "a flag that is not repeatable given twice is a usage error, also in the --flag=value form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(member_cmd, a, &tmp, &.{}, .{}, &.{ "acme", "ada", "--role", "owner", "--role=member" });
    try r.expect(2, "", "mopm org add: --role is given twice\n" ++ member_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "--json takes no value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(health_cmd, a, &tmp, &.{}, .{}, &.{"--json=yes"});
    try r.expect(2, "", "mopm health: --json takes no value\n" ++ health_cmd.usage);
}

test "--flag=value is the same as --flag value, and the body holds the flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.PUT, "/namespaces/acme/members/ada", 200, member_body)};
    const r = try runCmd(member_cmd, a, &tmp, &steps, .{ .token_env = "env-token" }, &.{ "acme", "ada", "--role=owner" });
    try r.expect(0, member_text, "");
    try std.testing.expectEqual(@as(usize, 1), r.requests());
    const seen = r.script.seen.items[0];
    try std.testing.expectEqual(std.http.Method.PUT, seen.method);
    try std.testing.expectEqualStrings(api_v2 ++ "/namespaces/acme/members/ada", seen.url);
    try std.testing.expectEqualStrings("{\"role\":\"owner\"}", seen.body.?);
    try std.testing.expectEqualStrings("env-token", seen.token.?);
}

test "a flag that is not given has its default, and --registry and --config-dir reach the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.PUT, "/namespaces/acme/members/ada", 200, member_body)};
    const r = try runCmd(member_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "acme", "--registry", "gamma", "ada", "--config-dir=/some/dir" });
    try r.expect(0, member_text, "");
    try std.testing.expectEqualStrings("{\"role\":\"member\"}", r.script.seen.items[0].body.?);
    try std.testing.expectEqualStrings("gamma", r.flags.registry);
    try std.testing.expectEqualStrings("/some/dir", r.flags.config_dir.?);
}

test "a set value is sent, with {cli_version} replaced by the version of the mopm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.POST, "/me/tokens", 201, token_body)};
    const r = try runCmd(token_auto_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "--scope", "publish" });
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(
        "{\"name\":\"mopm 9.9.9\",\"scopes\":[\"publish\"],\"packages\":\"all_current\",\"expires_in_days\":30}",
        r.script.seen.items[0].body.?,
    );

    const yank_steps = [_]Script.Step{step(.PUT, "/packages/acme/foo/1.0.0/yank", 200, "{\"version\":\"1.0.0\",\"state\":\"yanked\",\"published_at\":\"2026-10-01T00:00:00Z\",\"yank_reason\":\"bad\"}")};
    const y = try runCmd(yank_cmd, a, &tmp, &yank_steps, .{ .token_env = "t" }, &.{ "acme/foo", "1.0.0", "--reason", "bad" });
    try y.expect(0, "version: 1.0.0\nstate: yanked\npublished_at: 2026-10-01T00:00:00Z\nyank_reason: bad\n", "");
    try std.testing.expectEqualStrings(api_v2 ++ "/packages/acme/foo/1.0.0/yank", y.script.seen.items[0].url);
    try std.testing.expectEqualStrings("{\"yanked\":true,\"reason\":\"bad\"}", y.script.seen.items[0].body.?);
}

test "a repeated flag is a list, and names_or_const takes names or the constant" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.POST, "/me/tokens", 201, token_body)};
    const names = try runCmd(token_create_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "ci", "--scope", "publish", "--scope", "yank", "--packages", "acme/a", "--packages", "acme/b", "--expires-in-days", "7" });
    try names.expect(
        0,
        "id: tok_1\nname: ci\ntoken: mopm_secret\nscopes: publish\npackages: acme/a\nexpires_at: 2027-01-01T00:00:00Z\n",
        "",
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"ci\",\"scopes\":[\"publish\",\"yank\"],\"packages\":[\"acme/a\",\"acme/b\"],\"expires_in_days\":7}",
        names.script.seen.items[0].body.?,
    );
    const all = try runCmd(token_create_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "ci", "--scope", "stage", "--packages", "all_current" });
    try std.testing.expectEqual(@as(u8, 0), all.code);
    try std.testing.expectEqualStrings(
        "{\"name\":\"ci\",\"scopes\":[\"stage\"],\"packages\":\"all_current\",\"expires_in_days\":90}",
        all.script.seen.items[0].body.?,
    );
    const mixed = try runCmd(token_create_cmd, a, &tmp, &.{}, .{}, &.{ "ci", "--scope", "stage", "--packages", "all_current", "--packages", "acme/a" });
    try mixed.expect(2, "", "mopm token create: --packages: 'all_current' cannot be given with names\n" ++ token_create_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), mixed.requests());
}

test "a body file is read from a path and sent as the body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("group.json", "{\"members\": []}");
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "group.json" });
    const steps = [_]Script.Step{step(.POST, "/groups", 201, group_body)};
    const r = try runCmd(group_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "--body", path });
    try r.expect(0, "group_id: grp_1\nstatus: open\nattempt: 1\ndeadline_at: 2026-10-01T00:00:00Z\nmembers: (none)\n", "");
    try std.testing.expectEqualStrings("{\"members\":[]}", r.script.seen.items[0].body.?);
}

test "a body file of - is read from standard input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.POST, "/groups", 201, group_body)};
    const r = try runCmd(group_cmd, a, &tmp, &steps, .{ .token_env = "t", .stdin = "{\"members\":[]}\n" }, &.{"--body=-"});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("{\"members\":[]}", r.script.seen.items[0].body.?);
}

test "a body file that is missing, is not JSON or is not the body is a usage error naming the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try runCmd(group_cmd, a, &tmp, &.{}, .{}, &.{ "--body", "no-such-file.json" });
    try missing.expect(2, "", "mopm api create-group: --body no-such-file.json: FileNotFound\n");
    const not_json = try runCmd(group_cmd, a, &tmp, &.{}, .{ .stdin = "not json" }, &.{ "--body", "-" });
    try not_json.expect(2, "", "mopm api create-group: --body -: SyntaxError\n");
    const wrong = try runCmd(group_cmd, a, &tmp, &.{}, .{ .stdin = "{\"members\":\"x\"}" }, &.{ "--body", "-" });
    try wrong.expect(2, "", "mopm api create-group: --body -: UnexpectedToken\n");
    const no_members = try runCmd(group_cmd, a, &tmp, &.{}, .{ .stdin = "{}" }, &.{ "--body", "-" });
    try no_members.expect(2, "", "mopm api create-group: --body -: MissingField\n");
    try std.testing.expectEqual(@as(usize, 0), no_members.requests());
    const no_flag = try runCmd(group_cmd, a, &tmp, &.{}, .{}, &.{});
    try no_flag.expect(2, "", "mopm api create-group: missing required option --body <file>\n" ++ group_cmd.usage);
}

test "query parameters are encoded in the URL, in the order of the operation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const found = "{\"packages\":[{\"name\":\"acme/foo\",\"latest\":\"1.0.0\",\"description\":null,\"updated_at\":\"2026-10-01T00:00:00Z\"}],\"next_cursor\":null}";
    const steps = [_]Script.Step{step(.GET, "/packages?q=a%20b%26c&sort=updated&cursor=c%2F1&limit=5", 200, found)};
    const r = try runCmd(search_cmd, a, &tmp, &steps, .{}, &.{ "a b&c", "--limit", "5", "--sort=updated", "--cursor", "c/1" });
    try r.expect(0, "packages:\n  - name: acme/foo\n    latest: 1.0.0\n    updated_at: 2026-10-01T00:00:00Z\n", "");
    try std.testing.expect(r.script.seen.items[0].token == null);

    const none = [_]Script.Step{step(.GET, "/packages", 200, "{\"packages\":[],\"next_cursor\":null}")};
    const empty = try runCmd(search_cmd, a, &tmp, &none, .{}, &.{});
    try empty.expect(0, "packages: (none)\n", "");
    try std.testing.expectEqualStrings(api_v2 ++ "/packages", empty.script.seen.items[0].url);
}

test "a command that needs a token and finds none says so and makes no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(revoke_cmd, a, &tmp, &.{}, .{}, &.{"tok_1"});
    try r.expect(1, "", "mopm: not logged in to beta; run 'mopm login'\n");
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "the token of the environment wins over the stored one, the stored one is used without it, and a command without a token sends none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.DELETE, "/me/tokens/tok_1", 204, "")};
    const env_wins = try runCmd(revoke_cmd, a, &tmp, &steps, .{ .token_env = "env-token", .stored = "stored-token" }, &.{"tok_1"});
    try std.testing.expectEqual(@as(u8, 0), env_wins.code);
    try std.testing.expectEqualStrings("env-token", env_wins.script.seen.items[0].token.?);
    const stored = try runCmd(revoke_cmd, a, &tmp, &steps, .{ .stored = "stored-token" }, &.{"tok_1"});
    try std.testing.expectEqual(@as(u8, 0), stored.code);
    try std.testing.expectEqualStrings("stored-token", stored.script.seen.items[0].token.?);

    const health = [_]Script.Step{step(.GET, "/health", 200, health_body)};
    const open = try runCmd(health_cmd, a, &tmp, &health, .{ .token_env = "env-token", .stored = "stored-token" }, &.{});
    try std.testing.expectEqual(@as(u8, 0), open.code);
    try std.testing.expect(open.script.seen.items[0].token == null);
}

test "a registry with no API version 2 is refused before any request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(health_cmd, a, &tmp, &.{}, .{ .no_v2 = true }, &.{});
    try r.expect(1, "", "mopm: beta serves no API version 2\n");
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "a session that cannot be opened ends the command with exit 1 and no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(health_cmd, a, &tmp, &.{}, .{ .no_session = true }, &.{});
    try r.expect(1, "", "");
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}

test "a transport error names the method, the URL and the error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{.{ .method = .GET, .suffix = "/health", .status = 0, .err = error.ConnectionRefused }};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: GET http://127.0.0.1:1/api/v2/health: ConnectionRefused\n");
}

test "a refusal with a known code prints the message, the code, the hint of the body, when to retry and the request id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "{\"error\":{\"code\":\"package_not_found\",\"message\":\"There is no package 'acme/foo'.\",\"hint\":\"Check the spelling.\"}}";
    const steps = [_]Script.Step{.{ .method = .GET, .suffix = "/health", .status = 404, .body = body, .retry_after = 7 }};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: There is no package 'acme/foo'.\n  code: package_not_found\n  hint: Check the spelling.\n  retry after: 7 seconds\n  request id: req-test\n");
}

test "a refusal with a known code and no hint in the body prints the hint of the catalogue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "{\"error\":{\"code\":\"token_unknown\",\"message\":\"The token is not recognised.\",\"hint\":\"\"}}";
    const steps = [_]Script.Step{step(.GET, "/health", 401, body)};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: The token is not recognised.\n  code: token_unknown\n  hint: Create a new token with 'mopm token create', or run 'mopm login'.\n  request id: req-test\n");
}

test "a refusal with a code this client does not know is the HTTP status, its message is not trusted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "{\"error\":{\"code\":\"brand_new\",\"message\":\"Something new.\",\"hint\":\"Wait.\"}}";
    const steps = [_]Script.Step{step(.GET, "/health", 409, body)};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: the registry answered HTTP 409\n  request id: req-test\n");
}

test "a refusal whose body is not an error body is the HTTP status, with the retry time and the request id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{.{ .method = .GET, .suffix = "/health", .status = 502, .body = "<html>bad gateway</html>", .retry_after = 3 }};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: the registry answered HTTP 502\n  retry after: 3 seconds\n  request id: req-test\n");
}

test "an answer that does not decode as the response is reported with the error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.GET, "/health", 200, "{\"status\":\"ok\"}")};
    const r = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try r.expect(1, "", "mopm: the registry's answer to health is not one this mopm reads: MissingField\n");
}

test "an ok answer is printed as text, and with --json as indented JSON without the null fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.GET, "/health", 200, health_body)};
    const text = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{});
    try text.expect(0, "status: ok\nstage: beta\napi_version: v2\nread_only: false\n", "");
    const json = try runCmd(health_cmd, a, &tmp, &steps, .{}, &.{"--json"});
    try json.expect(0, "{\n  \"status\": \"ok\",\n  \"stage\": \"beta\",\n  \"api_version\": \"v2\",\n  \"read_only\": false\n}\n", "");
}

test "an operation with no response prints Done. as text and nothing with --json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const steps = [_]Script.Step{step(.DELETE, "/me/tokens/tok_1", 204, "")};
    const text = try runCmd(revoke_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{"tok_1"});
    try text.expect(0, "Done.\n", "");
    const json = try runCmd(revoke_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "tok_1", "--json" });
    try json.expect(0, "", "");
    try std.testing.expectEqual(std.http.Method.DELETE, json.script.seen.items[0].method);
}

test "the words of a command name match the first words of the arguments" {
    try std.testing.expectEqual(@as(?usize, 2), spec.wordsMatch("publish status", &.{ "publish", "status", "pub_1" }));
    try std.testing.expectEqual(@as(?usize, 1), spec.wordsMatch("yank", &.{ "yank", "acme/foo", "1.0.0" }));
    try std.testing.expectEqual(@as(?usize, null), spec.wordsMatch("publish status", &.{ "publish", "--staged" }));
    try std.testing.expectEqual(@as(?usize, null), spec.wordsMatch("publish status", &.{"publish"}));
    try std.testing.expectEqual(@as(?usize, null), spec.wordsMatch("org add", &.{ "org", "list" }));
}

test "a boolean flag is sent as true, and given a value is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const valued = try runCmd(yank_flag_cmd, a, &tmp, &.{}, .{}, &.{ "acme/foo", "1.0.0", "--yanked=false" });
    try valued.expect(2, "", "mopm yank flag: --yanked takes no value\n" ++ yank_flag_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), valued.requests());
    const steps = [_]Script.Step{step(.PUT, "/yank", 200, "{}")};
    const plain = try runCmd(yank_flag_cmd, a, &tmp, &steps, .{ .token_env = "t" }, &.{ "acme/foo", "1.0.0", "--yanked" });
    try std.testing.expectEqual(@as(usize, 1), plain.requests());
    try std.testing.expectEqualStrings("{\"yanked\":true}", plain.script.seen.items[0].body.?);
}

test "a request that is not valid for the operation is a usage error naming the error, with no request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runCmd(yank_flag_cmd, a, &tmp, &.{}, .{}, &.{ "acme/foo", "1.0.0" });
    try r.expect(2, "", "mopm yank flag: the request is not valid: MissingField\n" ++ yank_flag_cmd.usage);
    try std.testing.expectEqual(@as(usize, 0), r.requests());
}
