//! Tests of tools/api_gen/cli_cmds.zig on small hand-built models: how a command's arguments and flags are derived from the
//! request, the text of the table, the help and the list, and each refusal with its message.

const std = @import("std");
const model = @import("model.zig");
const cli_cmds = @import("cli_cmds.zig");
const literal = @import("zig_client.zig").literal;
const Allocator = std.mem.Allocator;

const base: model.Api = .{
    .package = "t.v2",
    .service = "Registry",
    .doc = "",
    .title = "T",
    .version = "2",
    .summary = "",
    .license_name = "",
    .license_identifier = "",
    .base_path = "/api/v2",
    .servers = &.{},
    .tags = &.{},
    .security_schemes = &.{},
    .headers = &.{},
    .error_response = "Error",
    .messages = &messages,
    .enums = &enums,
    .order = &.{},
    .rpcs = &.{},
    .sources_sha256 = "feed",
};

fn fld(comptime name: []const u8, comptime doc: []const u8, label: model.Label, t: model.Type, rules: model.Rules) model.Field {
    return .{ .name = name, .number = 1, .doc = doc, .label = label, .type = t, .rules = rules };
}

fn plain(comptime name: []const u8, fields: []const model.Field) model.Message {
    return .{ .name = name, .path = name, .doc = "", .parent = null, .file = "t.proto", .fields = fields };
}

const str: model.Type = .{ .scalar = .string };
const required: model.Rules = .{ .required = true };
const none: model.Rules = .{};

// Messages: 0 Error, 1 Namespace (a wrapper of a string), 2 Names (a wrapper of repeated strings), 3 Pkgs (names or the
// constant `all_current`), 4 Detail, 5 MemberBody, 6 MemberReq, 7 FileBody (has a message field), 8 FileReq, 9 PkgReq,
// 10 KindsBody, 11 KindsReq, 12 JsonReq, 13 ClashBody, 14 ClashReq, 15 ObjReq, 16 MapBody (has a map), 17 MapReq, 18 StrBodyReq, 19 EnumBodyReq, 20 WrapBodyReq, 21 UnionBodyReq, 22 ListBodyReq,
// 23 NothingBody (a field of the empty type), 24 NothingReq.
const messages = [_]model.Message{
    plain("Error", &.{fld("message", "", .single, str, required)}),
    .{ .name = "Namespace", .path = "Namespace", .doc = "", .parent = null, .file = "t.proto", .wrapper = true, .fields = &.{fld("value", "", .single, str, required)} },
    .{ .name = "Names", .path = "Names", .doc = "", .parent = null, .file = "t.proto", .wrapper = true, .fields = &.{fld("value", "", .repeated, str, none)} },
    .{ .name = "Pkgs", .path = "Pkgs", .doc = "", .parent = null, .file = "t.proto", .is_union = true, .fields = &.{
        fld("names", "", .single, .{ .message = 2 }, none),
        fld("all", "", .single, str, .{ .@"const" = "all_current" }),
    } },
    plain("Detail", &.{fld("x", "", .single, str, none)}),
    plain("MemberBody", &.{
        fld("role", "The role.", .optional, .{ .enumeration = 0 }, none),
        fld("note", "A note.", .optional, str, required),
        fld("count", "", .optional, .{ .scalar = .int64 }, none),
        fld("force", "Overwrite.", .optional, .{ .scalar = .bool }, none),
        fld("labels", "Labels.", .repeated, str, none),
        fld("scope", "Which packages.", .optional, .{ .message = 3 }, none),
    }),
    plain("MemberReq", &.{
        fld("namespace", "The namespace.", .single, .{ .message = 1 }, required),
        fld("user", "The GitHub login.\nIn lower case.", .single, str, required),
        fld("verbose", "Say more.", .optional, .{ .scalar = .bool }, none),
        fld("limit", "", .optional, .{ .scalar = .int32 }, none),
        fld("body", "", .single, .{ .message = 5 }, required),
    }),
    plain("FileBody", &.{
        fld("detail", "", .single, .{ .message = 4 }, none),
        fld("name", "", .single, str, none),
    }),
    plain("FileReq", &.{
        fld("id", "The thing.", .single, str, required),
        fld("body", "", .single, .{ .message = 7 }, required),
    }),
    plain("PkgReq", &.{
        fld("namespace", "Owner.", .single, .{ .message = 1 }, required),
        fld("name", "Package name.", .single, str, required),
        fld("q", "Search text.", .optional, str, none),
    }),
    plain("KindsBody", &.{
        fld("keywords", "", .single, .{ .message = 2 }, none),
        fld("roles", "", .repeated, .{ .enumeration = 0 }, none),
        fld("ids", "", .repeated, .{ .scalar = .int64 }, none),
        fld("scope", "", .single, .{ .message = 3 }, none),
    }),
    plain("KindsReq", &.{fld("body", "", .single, .{ .message = 10 }, required)}),
    plain("JsonReq", &.{fld("json", "", .optional, .{ .scalar = .bool }, none)}),
    plain("ClashBody", &.{fld("note", "", .single, str, none)}),
    plain("ClashReq", &.{
        fld("note", "", .optional, str, none),
        fld("body", "", .single, .{ .message = 13 }, required),
    }),
    plain("ObjReq", &.{fld("detail", "", .optional, .{ .message = 4 }, none)}),
    plain("MapBody", &.{.{ .name = "m", .number = 1, .doc = "", .label = .single, .type = str, .map = true }}),
    plain("MapReq", &.{fld("body", "", .single, .{ .message = 16 }, required)}),
    plain("StrBodyReq", &.{fld("body", "", .single, str, required)}),
    plain("EnumBodyReq", &.{fld("body", "", .single, .{ .enumeration = 0 }, required)}),
    plain("WrapBodyReq", &.{fld("body", "", .single, .{ .message = 1 }, required)}),
    plain("UnionBodyReq", &.{fld("body", "", .single, .{ .message = 3 }, required)}),
    plain("ListBodyReq", &.{fld("body", "", .repeated, .{ .message = 4 }, required)}),
    plain("NothingBody", &.{fld("nothing", "", .single, .empty, none)}),
    plain("NothingReq", &.{fld("body", "", .single, .{ .message = 23 }, required)}),
};

const enums = [_]model.Enum{.{ .name = "Role", .path = "Role", .doc = "", .parent = null, .file = "t.proto", .values = &.{
    .{ .name = "ROLE_UNSPECIFIED", .number = 0, .doc = "" },
    .{ .name = "ROLE_OWNER", .number = 1, .doc = "" },
    .{ .name = "ROLE_MEMBER", .number = 2, .doc = "" },
} }};

fn rpc(name: []const u8, method: model.Method, path: []const u8, input: model.Type, body: ?[]const u8, cmds: []const model.Command) model.Rpc {
    return .{ .name = name, .doc = "", .input = input, .output = .empty, .method = method, .path = path, .body = body, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{}, .commands = cmds };
}

fn healthRpc() model.Rpc {
    var r = rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "health", .summary = "Show health." }});
    r.doc = "Whether it is up.";
    return r;
}

const member_command: model.Command = .{
    .name = "member set",
    .args = &.{ "namespace", "user" },
    .set = &.{"force=true"},
    .defaults = &.{"role=member"},
    .summary = "Add a member.",
};

fn memberRpc() model.Rpc {
    var r = rpc("SetMember", .PUT, "/api/v2/namespaces/{namespace}/members/{user}", .{ .message = 6 }, "body", &.{member_command});
    r.doc = "Adds a member.";
    r.security = &.{"bearer"};
    return r;
}

fn uploadRpc(cmds: []const model.Command) model.Rpc {
    return rpc("Upload", .POST, "/api/v2/things/{id}", .{ .message = 8 }, "body", cmds);
}

fn packageRpc(cmds: []const model.Command) model.Rpc {
    return rpc("GetPackage", .GET, "/api/v2/packages/{namespace}/{name}", .{ .message = 9 }, null, cmds);
}

fn kindsRpc() model.Rpc {
    return rpc("Kinds", .POST, "/api/v2/kinds", .{ .message = 11 }, "body", &.{.{ .name = "kinds", .summary = "Kinds." }});
}

/// The member operation with a command `member set` of other `args`, `set` and `defaults`.
fn member(a: Allocator, args: []const []const u8, set: []const []const u8, defaults: []const []const u8) !model.Rpc {
    const cmds = try a.alloc(model.Command, 1);
    cmds[0] = .{ .name = "member set", .args = args, .set = set, .defaults = defaults, .summary = "S" };
    var r = memberRpc();
    r.commands = cmds;
    return r;
}

fn apiOf(a: Allocator, rpcs: []const model.Rpc) !model.Api {
    var api = base;
    api.rpcs = try a.dupe(model.Rpc, rpcs);
    return api;
}

fn written(a: Allocator, rpcs: []const model.Rpc) ![]const cli_cmds.File {
    return switch (try cli_cmds.write(a, try apiOf(a, rpcs))) {
        .ok => |files| files,
        .bad => |why| {
            std.debug.print("unexpected refusal: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectBad(rpcs: []const model.Rpc, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    switch (try cli_cmds.write(a, try apiOf(a, rpcs))) {
        .ok => return error.TestUnexpectedResult,
        .bad => |why| try std.testing.expectEqualStrings(want, why),
    }
}

fn expectMemberBad(args: []const []const u8, set: []const []const u8, defaults: []const []const u8, why: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const want = try std.fmt.allocPrint(arena_state.allocator(), "rpc SetMember: command 'member set': {s}", .{why});
    try expectBad(&.{try member(arena_state.allocator(), args, set, defaults)}, want);
}

fn expectUploadBad(cmd: model.Command, why: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const want = try std.fmt.allocPrint(arena_state.allocator(), "rpc Upload: command '{s}': {s}", .{ cmd.name, why });
    const cmds = [_]model.Command{cmd};
    try expectBad(&.{uploadRpc(&cmds)}, want);
}

fn fileText(files: []const cli_cmds.File, path: []const u8) ![]const u8 {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f.text;
    std.debug.print("no output {s}\n", .{path});
    return error.TestUnexpectedResult;
}

fn expectContains(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    }
}

/// `text` without the lines that start with one of `prefixes`.
fn dropLines(a: Allocator, text: []const u8, prefixes: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var drop = false;
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, line, p)) drop = true;
        }
        if (drop) continue;
        try out.appendSlice(line);
        if (it.peek() != null) try out.append('\n');
    }
    return out.items;
}

const member_usage = "usage: mopm member set <namespace> <user> [--verbose] [--limit <n>] [--role <owner|member>] --note <note> [--count <n>] [--labels <labels>...] [--scope <full name>...|all_current] [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n";

test "the help of a command with every part is exactly this, and is its golden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const files = try written(arena_state.allocator(), &.{memberRpc()});
    const help = try fileText(files, "tests/golden/registry/member-set.txt");
    try std.testing.expectEqualStrings(member_usage ++
        \\
        \\Add a member.
        \\
        \\Adds a member.
        \\
        \\arguments:
        \\  <namespace>
        \\      The namespace.
        \\  <user>
        \\      The GitHub login.
        \\      In lower case.
        \\options:
        \\  --verbose
        \\      Say more.
        \\  --limit <n>
        \\  --role <owner|member>
        \\      default: member. The role.
        \\  --note <note>
        \\      required. A note.
        \\  --count <n>
        \\  --labels <labels>...
        \\      Labels.
        \\  --scope <full name>...|all_current
        \\      Which packages.
        \\  --registry <prod|gamma|beta|url>
        \\      the registry (default prod)
        \\  --config-dir <dir>
        \\      where 'mopm login' keeps credentials.json (default ~/.config/mopm)
        \\  --json
        \\      print the registry's answer as JSON instead of text
        \\
        \\Sends PUT /api/v2/namespaces/{namespace}/members/{user} (setMember) with the token 'mopm login' stored, or $MOPM_TOKEN.
        \\
    , help);
}

test "the table entry of a command with every part is exactly this" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{memberRpc()});
    try std.testing.expectEqualStrings("src/cli/registry_commands.zig", files[0].path);
    const table = try dropLines(a, files[0].text, &.{ "        .usage = ", "        .help = " });
    try std.testing.expectEqualStrings(
        \\//! Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto (`zig build gen-api`); do not edit.
        \\//! The registry commands of the command line: one entry per `commands` of an operation's `(operation)` option, run by
        \\//! src/cli/api_cmd.zig.
        \\
        \\const v2 = @import("mopm_core").registry_v2;
        \\const spec = @import("api_spec.zig");
        \\
        \\pub const commands = [_]spec.Command{
        \\    .{
        \\        .name = "member set",
        \\        .Op = v2.SetMember,
        \\        .summary = "Add a member.",
        \\        .token = true,
        \\        .body = .flags,
        \\        .args = &.{
        \\            .{ .meta = "<namespace>", .key = "namespace" },
        \\            .{ .meta = "<user>", .key = "user" },
        \\        },
        \\        .flags = &.{
        \\            .{ .flag = "--verbose", .meta = "", .key = "verbose", .in = .params, .kind = .boolean },
        \\            .{ .flag = "--limit", .meta = "<n>", .key = "limit", .in = .params, .kind = .integer },
        \\            .{ .flag = "--role", .meta = "<owner|member>", .key = "role", .in = .body, .kind = .enumeration, .values = &.{ "owner", "member" }, .default = "\"member\"" },
        \\            .{ .flag = "--note", .meta = "<note>", .key = "note", .in = .body, .kind = .string, .required = true },
        \\            .{ .flag = "--count", .meta = "<n>", .key = "count", .in = .body, .kind = .integer },
        \\            .{ .flag = "--labels", .meta = "<labels>...", .key = "labels", .in = .body, .kind = .string, .repeated = true },
        \\            .{ .flag = "--scope", .meta = "<full name>...|all_current", .key = "scope", .in = .body, .kind = .names_or_const, .repeated = true, .const_value = "all_current" },
        \\        },
        \\        .set = &.{
        \\            .{ .key = "force", .json = "true" },
        \\        },
        \\    },
        \\};
        \\
        \\/// The list of commands `mopm --help` prints, equal to tests/golden/registry/commands.txt.
        \\pub const list = "registry commands (one call of the registry API each; mopm <command> --help):\n  member set  Add a member.\n";
        \\
    , table);
    // The usage and help lines are the escaped usage line and golden.
    try expectContains(files[0].text, try std.fmt.allocPrint(a, "        .usage = {s},\n", .{try literal(a, member_usage)}));
    try expectContains(files[0].text, try std.fmt.allocPrint(a, "        .help = {s},\n", .{try literal(a, files[2].text)}));
}

test "a command with no argument, no flag and no token is the bare entry, and the generated table is what zig fmt writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmds = [_]model.Command{.{ .name = "thing upload", .args = &.{"id"}, .summary = "Upload a thing." }};
    const map_cmds = [_]model.Command{.{ .name = "map", .summary = "Map." }};
    const map_rpc = rpc("MapRpc", .POST, "/api/v2/map", .{ .message = 17 }, "body", &map_cmds);
    const files = try written(a, &.{ healthRpc(), memberRpc(), uploadRpc(&cmds), packageRpc(&.{.{ .name = "package info", .args = &.{"namespace/name"}, .summary = "Show a package." }}), kindsRpc(), map_rpc });
    const table = try dropLines(a, files[0].text, &.{ "        .usage = ", "        .help = " });
    try expectContains(table,
        \\    .{
        \\        .name = "health",
        \\        .Op = v2.Health,
        \\        .summary = "Show health.",
        \\        .token = false,
        \\        .body = .none,
        \\    },
        \\
    );
    const text = try a.dupeZ(u8, files[0].text);
    const tree = try std.zig.Ast.parse(a, text, .zig);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expectEqualStrings(text, try tree.render(a));
}

test "the help of an operation without a token or flags names no token and has no arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const files = try written(arena_state.allocator(), &.{healthRpc()});
    try std.testing.expectEqualStrings(
        \\usage: mopm health [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]
        \\
        \\Show health.
        \\
        \\Whether it is up.
        \\
        \\options:
        \\  --registry <prod|gamma|beta|url>
        \\      the registry (default prod)
        \\  --config-dir <dir>
        \\      where 'mopm login' keeps credentials.json (default ~/.config/mopm)
        \\  --json
        \\      print the registry's answer as JSON instead of text
        \\
        \\Sends GET /api/v2/health (health).
        \\
    , try fileText(files, "tests/golden/registry/health.txt"));
}

test "a body with a field that cannot be a flag is sent as --body <file>" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{uploadRpc(&.{.{ .name = "thing upload", .args = &.{"id"}, .summary = "Upload a thing." }})});
    try std.testing.expectEqualStrings(
        \\usage: mopm thing upload <id> --body <file> [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]
        \\
        \\Upload a thing.
        \\
        \\arguments:
        \\  <id>
        \\      The thing.
        \\options:
        \\  --body <file>
        \\      the request body, JSON (`-`: standard input), as `FileBody` of spec/api/openapi-v2.yaml
        \\  --registry <prod|gamma|beta|url>
        \\      the registry (default prod)
        \\  --config-dir <dir>
        \\      where 'mopm login' keeps credentials.json (default ~/.config/mopm)
        \\  --json
        \\      print the registry's answer as JSON instead of text
        \\
        \\Sends POST /api/v2/things/{id} (upload).
        \\
    , try fileText(files, "tests/golden/registry/thing-upload.txt"));
    try expectContains(files[0].text, "        .body = .file,\n        .args = &.{\n            .{ .meta = \"<id>\", .key = \"id\" },\n        },\n    },\n");
    try std.testing.expect(std.mem.indexOf(u8, files[0].text, ".flags = ") == null);

    // A map is no flag either.
    const cmds = [_]model.Command{.{ .name = "map", .summary = "Map." }};
    const map_files = try written(a, &.{rpc("MapRpc", .POST, "/api/v2/map", .{ .message = 17 }, "body", &cmds)});
    try expectContains(map_files[2].text, "  --body <file>\n      the request body, JSON (`-`: standard input), as `MapBody` of spec/api/openapi-v2.yaml\n");
    try expectContains(map_files[0].text, "        .body = .file,\n");
}

test "each kind of field is the flag of its kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{kindsRpc()});
    const table = files[0].text;
    // A wrapper of repeated strings: a string flag that may be given more than once.
    try expectContains(table, "            .{ .flag = \"--keywords\", .meta = \"<keywords>...\", .key = \"keywords\", .in = .body, .kind = .string, .repeated = true },\n");
    // A repeated enum has the values of the enum, without the unspecified one.
    try expectContains(table, "            .{ .flag = \"--roles\", .meta = \"<owner|member>...\", .key = \"roles\", .in = .body, .kind = .enumeration, .values = &.{ \"owner\", \"member\" }, .repeated = true },\n");
    // A repeated integer.
    try expectContains(table, "            .{ .flag = \"--ids\", .meta = \"<n>...\", .key = \"ids\", .in = .body, .kind = .integer, .repeated = true },\n");
    // A union of a wrapper of strings and a constant.
    try expectContains(table, "            .{ .flag = \"--scope\", .meta = \"<full name>...|all_current\", .key = \"scope\", .in = .body, .kind = .names_or_const, .repeated = true, .const_value = \"all_current\" },\n");
    try expectContains(table, "        .body = .flags,\n");
}

test "a wrapper of a string is a string flag, and a path parameter that is no argument is a required flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{packageRpc(&.{.{ .name = "package find", .args = &.{"q"}, .summary = "Find." }})});
    const help = try fileText(files, "tests/golden/registry/package-find.txt");
    try std.testing.expect(std.mem.startsWith(u8, help, "usage: mopm package find [<q>] --namespace <namespace> --name <name> [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n"));
    try expectContains(help, "arguments:\n  <q>\n      Search text.\noptions:\n  --namespace <namespace>\n      required. Owner.\n  --name <name>\n      required. Package name.\n  --registry");
    try expectContains(files[0].text, "            .{ .meta = \"<q>\", .key = \"q\", .optional = true },\n");
    try expectContains(files[0].text, "            .{ .flag = \"--namespace\", .meta = \"<namespace>\", .key = \"namespace\", .in = .params, .kind = .string, .required = true },\n");
    try expectContains(files[0].text, "            .{ .flag = \"--name\", .meta = \"<name>\", .key = \"name\", .in = .params, .kind = .string, .required = true },\n");
}

test "a full name is one argument that fills the namespace and the name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{packageRpc(&.{.{ .name = "package info", .args = &.{"namespace/name"}, .summary = "Show a package." }})});
    const help = try fileText(files, "tests/golden/registry/package-info.txt");
    try std.testing.expect(std.mem.startsWith(u8, help, "usage: mopm package info <namespace>/<name> [--q <q>] [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n"));
    try expectContains(help, "arguments:\n  <namespace>/<name>\n      Owner.\n      Package name.\noptions:\n  --q <q>\n      Search text.\n  --registry");
    try expectContains(files[0].text, "            .{ .meta = \"<namespace>/<name>\", .key = \"namespace/name\", .full_name = true },\n");
    try expectContains(files[0].text, "            .{ .flag = \"--q\", .meta = \"<q>\", .key = \"q\", .in = .params, .kind = .string },\n");
    try std.testing.expect(std.mem.indexOf(u8, files[0].text, "\"--namespace\"") == null);
}

test "a field of the body can be an argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{try member(a, &.{ "namespace", "user", "note" }, &.{}, &.{})});
    try expectContains(files[0].text, "            .{ .meta = \"<note>\", .key = \"note\", .in = .body },\n");
    try expectContains(files[2].text, "usage: mopm member set <namespace> <user> <note> [--verbose]");
    try std.testing.expect(std.mem.indexOf(u8, files[0].text, "\"--note\"") == null);
}

test "set fixes a body field and defaults make a flag optional with its JSON text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{try member(a, &.{ "namespace", "user" }, &.{ "force=true", "count=3" }, &.{ "note=hi", "limit=10" })});
    const table = files[0].text;
    try expectContains(table, "        .set = &.{\n            .{ .key = \"force\", .json = \"true\" },\n            .{ .key = \"count\", .json = \"3\" },\n        },\n");
    // A default is quoted for a string and bare for an integer; the flag is no longer required.
    try expectContains(table, "            .{ .flag = \"--note\", .meta = \"<note>\", .key = \"note\", .in = .body, .kind = .string, .default = \"\\\"hi\\\"\" },\n");
    try expectContains(table, "            .{ .flag = \"--limit\", .meta = \"<n>\", .key = \"limit\", .in = .params, .kind = .integer, .default = \"10\" },\n");
    try expectContains(files[2].text, "  --note <note>\n      default: hi. A note.\n");
    try expectContains(files[2].text, "  --limit <n>\n      default: 10.\n");
    // The fixed fields are no flags.
    try std.testing.expect(std.mem.indexOf(u8, table, "\"--force\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, table, "\"--count\"") == null);
    // A default with a quote and a backslash is escaped as JSON and then as a Zig string.
    const quoted = try written(a, &.{try member(a, &.{ "namespace", "user" }, &.{}, &.{"note=a\"b\\c"})});
    try expectContains(quoted[0].text, ".default = \"\\\"a\\\\\\\"b\\\\\\\\c\\\"\" },\n");
    try expectContains(quoted[2].text, "      default: a\"b\\c. A note.\n");
}

test "the token sentence is written when the operation has a security requirement" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const files = try written(arena_state.allocator(), &.{ healthRpc(), memberRpc() });
    try std.testing.expect(std.mem.endsWith(u8, try fileText(files, "tests/golden/registry/member-set.txt"), "(setMember) with the token 'mopm login' stored, or $MOPM_TOKEN.\n"));
    try std.testing.expect(std.mem.endsWith(u8, try fileText(files, "tests/golden/registry/health.txt"), "(health).\n"));
    try expectContains(files[0].text, "        .token = true,\n");
    try expectContains(files[0].text, "        .token = false,\n");
}

test "the list pads the names to the longest and the files are the table, the list, then the goldens by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = try written(a, &.{
        packageRpc(&.{.{ .name = "package info", .args = &.{"namespace/name"}, .summary = "Show a package." }}),
        healthRpc(),
        memberRpc(),
    });
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try std.testing.expectEqualStrings(
        \\registry commands (one call of the registry API each; mopm <command> --help):
        \\  package info  Show a package.
        \\  health        Show health.
        \\  member set    Add a member.
        \\
    , files[1].text);
    try std.testing.expectEqualStrings("src/cli/registry_commands.zig", files[0].path);
    try std.testing.expectEqualStrings("tests/golden/registry/commands.txt", files[1].path);
    try std.testing.expectEqualStrings("tests/golden/registry/health.txt", files[2].path);
    try std.testing.expectEqualStrings("tests/golden/registry/member-set.txt", files[3].path);
    try std.testing.expectEqualStrings("tests/golden/registry/package-info.txt", files[4].path);
    // The table lists the commands in the proto's order, and carries the list as its `list`.
    const table = files[0].text;
    const first = std.mem.indexOf(u8, table, ".name = \"package info\"").?;
    const second = std.mem.indexOf(u8, table, ".name = \"health\"").?;
    const third = std.mem.indexOf(u8, table, ".name = \"member set\"").?;
    try std.testing.expect(first < second and second < third);
    try expectContains(table, try std.fmt.allocPrint(a, "pub const list = {s};\n", .{try literal(a, files[1].text)}));
}

test "the golden of a command is named by its words joined with hyphens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("tests/golden/registry/org-add.txt", try cli_cmds.goldenPath(arena_state.allocator(), "org add"));
    try std.testing.expectEqualStrings("tests/golden/registry/whoami.txt", try cli_cmds.goldenPath(arena_state.allocator(), "whoami"));
}

test "a name that is the first word of another command is allowed when it is a different word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const b = rpc("B", .GET, "/api/v2/b", .empty, null, &.{.{ .name = "organ", .summary = "B." }});
    const files = try written(arena_state.allocator(), &.{ rpc("A", .GET, "/api/v2/a", .empty, null, &.{.{ .name = "org add", .summary = "A." }}), b });
    try std.testing.expectEqual(@as(usize, 4), files.len);
}

// ---- refusals ---------------------------------------------------------------------------------------------------

test "an operation without commands is refused" {
    try expectBad(&.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{})}, "rpc Health: has no `commands` in its (operation) option");
    try expectBad(&.{ healthRpc(), rpc("Other", .GET, "/api/v2/o", .empty, null, &.{}) }, "rpc Other: has no `commands` in its (operation) option");
}

test "a command name must be words of lower case letters, digits and hyphens" {
    const bad_names = [_][]const u8{ "Org add", "org  add", "", "1st", "a_b", " x", "x " };
    const words = [_][]const u8{ "Org", "", "", "1st", "a_b", "", "" };
    for (bad_names, words) |name, word| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const want = try std.fmt.allocPrint(arena_state.allocator(), "rpc Health: command name '{s}': '{s}' is not a word of [a-z][a-z0-9-]*", .{ name, word });
        const cmds = [_]model.Command{.{ .name = name, .summary = "S." }};
        try expectBad(&.{rpc("Health", .GET, "/api/v2/health", .empty, null, &cmds)}, want);
    }
}

test "a command needs a summary" {
    try expectBad(&.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "health" }})}, "rpc Health: command 'health': has no summary");
}

test "two commands with one name are refused, in one operation or two" {
    try expectBad(
        &.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{ .{ .name = "a", .summary = "S." }, .{ .name = "a", .summary = "S." } })},
        "rpc Health: command 'a' is also a command of rpc Health",
    );
    try expectBad(
        &.{
            rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "a", .summary = "S." }}),
            rpc("Other", .GET, "/api/v2/o", .empty, null, &.{.{ .name = "a", .summary = "S." }}),
        },
        "rpc Health: command 'a' is also a command of rpc Other",
    );
}

test "a command name that is the first words of another is refused whichever comes first" {
    try expectBad(
        &.{
            rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "org", .summary = "S." }}),
            rpc("Other", .GET, "/api/v2/o", .empty, null, &.{.{ .name = "org add", .summary = "S." }}),
        },
        "rpc Health: command 'org' is the first word(s) of command 'org add' of rpc Other; a name cannot be both",
    );
    try expectBad(
        &.{
            rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "org add", .summary = "S." }}),
            rpc("Other", .GET, "/api/v2/o", .empty, null, &.{.{ .name = "org", .summary = "S." }}),
        },
        "rpc Other: command 'org' is the first word(s) of command 'org add' of rpc Health; a name cannot be both",
    );
    try expectBad(
        &.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{ .{ .name = "a b c", .summary = "S." }, .{ .name = "a b", .summary = "S." } })},
        "rpc Health: command 'a b' is the first word(s) of command 'a b c' of rpc Health; a name cannot be both",
    );
}

test "two names that make one golden file are refused" {
    try expectBad(
        &.{
            rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "a-b c", .summary = "S." }}),
            rpc("Other", .GET, "/api/v2/o", .empty, null, &.{.{ .name = "a b-c", .summary = "S." }}),
        },
        "rpc Health: command 'a-b c' has the golden file tests/golden/registry/a-b-c.txt of command 'a b-c' of rpc Other",
    );
}

test "an argument must be a string field of the request, named once" {
    try expectMemberBad(&.{"nope"}, &.{}, &.{}, "argument 'nope' is not a field of the request (a path parameter, a query parameter or a field of its body)");
    try expectMemberBad(&.{"namespace/name"}, &.{}, &.{}, "argument 'namespace/name' needs the path parameters 'namespace' and 'name'");
    try expectMemberBad(&.{ "user", "user" }, &.{}, &.{}, "argument 'user' is named twice");
    try expectMemberBad(&.{"limit"}, &.{}, &.{}, "argument 'limit' is not a string field");
    try expectMemberBad(&.{"verbose"}, &.{}, &.{}, "argument 'verbose' is not a string field");
    try expectMemberBad(&.{"role"}, &.{}, &.{}, "argument 'role' is not a string field");
    try expectMemberBad(&.{"labels"}, &.{}, &.{}, "argument 'labels' is not a string field");
    try expectBad(
        &.{packageRpc(&.{.{ .name = "p", .args = &.{ "namespace", "namespace/name" }, .summary = "S." }})},
        "rpc GetPackage: command 'p': argument 'namespace/name' repeats the argument 'namespace' or 'name'",
    );
    try expectBad(
        &.{packageRpc(&.{.{ .name = "p", .args = &.{ "namespace/name", "namespace" }, .summary = "S." }})},
        "rpc GetPackage: command 'p': argument 'namespace' is named twice",
    );
    try expectBad(
        &.{packageRpc(&.{.{ .name = "p", .args = &.{ "namespace/name", "namespace/name" }, .summary = "S." }})},
        "rpc GetPackage: command 'p': argument 'namespace/name' is named twice",
    );
    try expectUploadBad(
        .{ .name = "u", .args = &.{"name"}, .summary = "S." },
        "argument 'name' is a field of the body, which is sent as --body <file> because its field 'detail' cannot be a flag",
    );
    try expectBad(&.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "h", .args = &.{"x"}, .summary = "S." }})}, "rpc Health: command 'h': argument 'x' is not a field of the request (a path parameter, a query parameter or a field of its body)");
}

test "a body that is not an object of fields, or has a field of the empty type, is sent as --body <file> named by its type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { input: u32, body_type: []const u8 }{
        .{ .input = 18, .body_type = "string" },
        .{ .input = 19, .body_type = "Role" },
        .{ .input = 20, .body_type = "Namespace" },
        .{ .input = 21, .body_type = "Pkgs" },
        .{ .input = 22, .body_type = "Detail" },
        .{ .input = 24, .body_type = "NothingBody" },
    };
    for (cases) |c| {
        const cmds = [_]model.Command{.{ .name = "send", .summary = "Send." }};
        const files = try written(a, &.{rpc("Send", .POST, "/api/v2/send", .{ .message = c.input }, "body", &cmds)});
        try expectContains(files[0].text, "        .body = .file,\n");
        try std.testing.expect(std.mem.indexOf(u8, files[0].text, ".flags = ") == null);
        const want = try std.fmt.allocPrint(a, "  --body <file>\n      the request body, JSON (`-`: standard input), as `{s}` of spec/api/openapi-v2.yaml\n", .{c.body_type});
        try expectContains(files[2].text, want);
    }
}

test "a set entry names a flag-able field of the body, once, with a value its type reads" {
    const args = [_][]const u8{ "namespace", "user" };
    try expectMemberBad(&args, &.{"force"}, &.{}, "'set' entry 'force' is not field=value");
    try expectMemberBad(&args, &.{"nope=1"}, &.{}, "'set' entry 'nope' is not a field of the body");
    try expectMemberBad(&args, &.{"verbose=true"}, &.{}, "'set' entry 'verbose' is not a field of the body");
    try expectMemberBad(&args, &.{"user=x"}, &.{}, "'set' entry 'user' is not a field of the body");
    try expectMemberBad(&.{ "namespace", "user", "note" }, &.{"note=x"}, &.{}, "field 'note' is both an argument and set");
    try expectMemberBad(&args, &.{ "force=true", "force=false" }, &.{}, "field 'force' is set twice");
    try expectMemberBad(&args, &.{"labels=a"}, &.{}, "'set' entry 'labels': a repeated flag cannot be set or given a default");
    try expectMemberBad(&args, &.{"scope=a"}, &.{}, "'set' entry 'scope': a repeated flag cannot be set or given a default");
    try expectMemberBad(&args, &.{"count=x"}, &.{}, "'set' entry 'count': 'x' is not an integer");
    try expectMemberBad(&args, &.{"force=yes"}, &.{}, "'set' entry 'force': 'yes' is not true or false");
    try expectMemberBad(&args, &.{"role=boss"}, &.{}, "'set' entry 'role': 'boss' is not one of owner|member");
    try expectUploadBad(
        .{ .name = "u", .args = &.{"id"}, .set = &.{"name=x"}, .summary = "S." },
        "'set' entry 'name' is a field of the body, which is sent as --body <file> because its field 'detail' cannot be a flag",
    );
    try expectBad(
        &.{rpc("Health", .GET, "/api/v2/health", .empty, null, &.{.{ .name = "h", .set = &.{"x=1"}, .summary = "S." }})},
        "rpc Health: command 'h': 'set' entry 'x' is not a field of the body",
    );
}

test "a defaults entry names a flag, once, not also set, with a value its type reads" {
    const args = [_][]const u8{ "namespace", "user" };
    try expectMemberBad(&args, &.{}, &.{"role"}, "'defaults' entry 'role' is not field=value");
    try expectMemberBad(&args, &.{}, &.{"nope=1"}, "'defaults' entry 'nope' is not a flag of this command");
    try expectMemberBad(&args, &.{}, &.{"user=x"}, "'defaults' entry 'user' is not a flag of this command");
    try expectMemberBad(&args, &.{"force=true"}, &.{"force=false"}, "field 'force' is both set and given a default");
    try expectMemberBad(&args, &.{}, &.{ "role=owner", "role=member" }, "field 'role' is given a default twice");
    try expectMemberBad(&args, &.{}, &.{"labels=a"}, "'defaults' entry 'labels': a repeated flag cannot be set or given a default");
    try expectMemberBad(&args, &.{}, &.{"count=x"}, "'defaults' entry 'count': 'x' is not an integer");
    try expectMemberBad(&args, &.{}, &.{"limit=x"}, "'defaults' entry 'limit': 'x' is not an integer");
    try expectMemberBad(&args, &.{}, &.{"force=maybe"}, "'defaults' entry 'force': 'maybe' is not true or false");
    try expectMemberBad(&args, &.{}, &.{"role=boss"}, "'defaults' entry 'role': 'boss' is not one of owner|member");
    try expectUploadBad(
        .{ .name = "u", .args = &.{"id"}, .defaults = &.{"name=x"}, .summary = "S." },
        "'defaults' entry 'name' is a field of the body, which is sent as --body <file> because its field 'detail' cannot be a flag",
    );
}

test "a flag may not take the name of a global option or of another flag, and a parameter must be flag-able" {
    try expectBad(
        &.{rpc("Json", .GET, "/api/v2/j", .{ .message = 12 }, null, &.{.{ .name = "j", .summary = "S." }})},
        "rpc Json: command 'j': flag '--json' is a global option of the command line",
    );
    try expectBad(
        &.{rpc("Clash", .POST, "/api/v2/c", .{ .message = 14 }, "body", &.{.{ .name = "c", .summary = "S." }})},
        "rpc Clash: command 'c': flag '--note' is given by two fields",
    );
    try expectBad(
        &.{rpc("Obj", .GET, "/api/v2/obj", .{ .message = 15 }, null, &.{.{ .name = "o", .summary = "S." }})},
        "rpc Obj: command 'o': parameter 'detail' cannot be a flag",
    );
}

test "a refusal leaves no output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try cli_cmds.write(a, try apiOf(a, &.{ healthRpc(), rpc("Other", .GET, "/api/v2/o", .empty, null, &.{}) }));
    try std.testing.expect(got == .bad);
}
