//! //:registry_client_lint: the registry client lint (tests/drivers/registry_client_lint.zig) over the real tree, and one
//! faulty sample per rule that it must flag, with the near misses it must not.

const std = @import("std");
const c = @import("lint_common.zig");
const lint = @import("registry_client_lint.zig");

const msg_call = "sends a registry request without the generated client; use v2.send, v2.sendOnce or v2.call, or put `// not the registry API: <why>` on the line or the line above";
const msg_path = "builds a registry path by hand; use the generated client";

test "the real tree: every operation has a generated command, and the hand-written files call the registry through the generated client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    for ([_][]const u8{ lint.client_path, lint.commands_path, "src/core/ci_oidc.zig", "src/cli/main.zig" }) |must| {
        if (!c.hasFile(tree, must)) {
            std.debug.print("the registry client lint lacks {s}: BUCK does not list every file\n", .{must});
            return error.TestUnexpectedResult;
        }
    }
    var files = std.ArrayList(lint.File).init(a);
    for (tree.files) |p| {
        if (!lint.handWritten(p)) continue;
        try files.append(.{ .path = p, .data = try tree.read(a, p) });
    }
    try std.testing.expect(files.items.len > 10);
    const found = try lint.check(a, files.items, try tree.read(a, lint.client_path), try tree.read(a, lint.commands_path));
    var out = c.Out.init(a);
    for (found) |f| try out.append(try lint.render(a, f));
    try c.expectLines("registry client lint", out.items, &.{});
}

test "handWritten: src/cli/*.zig and ci_oidc.zig, not tests, not the generated table, not other directories" {
    try std.testing.expect(lint.handWritten("src/cli/main.zig"));
    try std.testing.expect(lint.handWritten("src/core/ci_oidc.zig"));
    try std.testing.expect(!lint.handWritten("src/cli/group_publish_test.zig"));
    try std.testing.expect(!lint.handWritten("src/cli/registry_commands.zig"));
    try std.testing.expect(!lint.handWritten("src/cli/sub/x.zig"));
    try std.testing.expect(!lint.handWritten("src/cli/notes.md"));
    try std.testing.expect(!lint.handWritten("src/core/http.zig"));
}

const client =
    \\pub const GetHealth = struct {
    \\    pub const operation_id = "getHealth";
    \\    pub const path_template = "/health";
    \\};
    \\
    \\pub const GetMe = struct {
    \\    pub const operation_id = "getMe";
    \\    pub const path_template = "/me";
    \\    pub const Params = struct {};
    \\};
    \\
    \\pub const GetPackage = struct {
    \\    pub const operation_id = "getPackage";
    \\    pub const path_template = "/packages/{namespace}/{name}";
    \\};
    \\
    \\pub const Health = struct {
    \\    ok: bool,
    \\};
    \\
;

const commands = "const v2 = @import(\"x\");\n.Op = v2.GetHealth,\n.Op = v2.GetMe,\n.Op = v2.GetPackage,\n";

/// `check` over `files` (and the sample client and commands unless given) finds exactly `want`, rendered.
fn expectIn(files: []const lint.File, client_text: []const u8, commands_text: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try lint.check(a, files, client_text, commands_text);
    var out = std.ArrayList([]const u8).init(a);
    for (got) |f| try out.append(try lint.render(a, f));
    if (got.len != want.len) {
        std.debug.print("expected {d} finding(s), got {d}:\n", .{ want.len, got.len });
        for (out.items) |l| std.debug.print("  > {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    for (want, out.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

fn expectCode(code: []const u8, want: []const []const u8) !void {
    try expectIn(&.{.{ .path = "src/cli/x.zig", .data = code }}, client, commands, want);
}

test "the sample client and commands are clean" {
    try expectIn(&.{}, client, commands, &.{});
}

test "rule 1: an operation the commands do not name is a finding with its name, id and place" {
    try expectIn(&.{}, client, "v2.GetHealth v2.GetPackage", &.{
        "src/core/registry_v2.zig:6: GetMe (getMe) has no generated command in src/cli/registry_commands.zig",
    });
}

test "rule 1: a command named for a longer operation does not name the shorter one" {
    try expectIn(&.{}, client, "v2.GetHealth v2.GetMeters v2.GetPackage", &.{
        "src/core/registry_v2.zig:6: GetMe (getMe) has no generated command in src/cli/registry_commands.zig",
    });
}

test "rule 1: a struct without an operation id is not an operation" {
    try expectIn(&.{}, client, "v2.GetHealth v2.GetMe v2.GetPackage", &.{});
}

test "rule 2: each call form is a finding" {
    const forms = [_][]const u8{
        "const r = net.request(a, .GET, u, .{});",
        "const r = net.once(a, .GET, u, .{});",
        "const r = net.vtable.request(net.ptr, a, .GET, u, .{});",
        "const r = http.request(a, .GET, u, .{});",
        "const r = http.retrying(a, io, .GET, u, .{}, p);",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (forms) |form| {
        const data = try std.fmt.allocPrint(a, "fn f() void {{\n    {s}\n}}\n", .{form});
        try expectCode(data, &.{"src/cli/x.zig:2: " ++ msg_call});
    }
}

test "rule 2: the generated client's calls are not findings" {
    try expectCode("const r = try v2.send(Op, a, net, net.policy, root, token, p);\nconst s = try v2.sendOnce(Op, a, net, root, token, p);\nconst t = try v2.call(Op, a, net, net.policy, root, token, p);\n", &.{});
}

test "rule 2: the marker on the same line or on a comment line above exempts the call; a trailing marker above does not" {
    try expectCode("const r = net.once(a, .PUT, u, .{}); // not the registry API: a presigned upload\n", &.{});
    try expectCode("// not the registry API: the readme object store\nconst r = net.once(a, .PUT, u, .{});\n", &.{});
    try expectCode("const x = 1; // not the registry API: the static index\nconst r = net.once(a, .PUT, u, .{});\n", &.{"src/cli/x.zig:2: " ++ msg_call});
}

test "rule 2: a marker two lines above, or without a why, exempts nothing" {
    try expectCode("// not the registry API: the readme object store\nconst x = 1;\nconst r = net.once(a, .PUT, u, .{});\n", &.{"src/cli/x.zig:3: " ++ msg_call});
    try expectCode("const r = net.once(a, .PUT, u, .{}); // not the registry API:\n", &.{"src/cli/x.zig:1: " ++ msg_call});
    try expectCode("const r = net.once(a, .PUT, u, .{}); // not the registry API:   \n", &.{"src/cli/x.zig:1: " ++ msg_call});
    try expectCode("// not the registry API:\nconst r = net.once(a, .PUT, u, .{});\n", &.{"src/cli/x.zig:2: " ++ msg_call});
}

test "rule 2: comment lines, multi-line string lines and string contents are not calls" {
    try expectCode("// net.request(a, .GET, u, .{});\n/// http.retrying(x)\nconst s =\n    \\\\ net.once(a)\n;\nconst m = \"call .request( here\";\n", &.{});
}

test "rule 2: a test block is skipped, the code after it is not" {
    const data =
        \\test "calls" {
        \\    if (true) {
        \\        _ = net.request(a, .GET, u, .{});
        \\    }
        \\    _ = http.retrying(a);
        \\}
        \\
        \\test {
        \\    _ = net.once(a);
        \\}
        \\
        \\test "one line" { _ = net.once(a); }
        \\
        \\fn f() void {
        \\    _ = net.once(a);
        \\}
        \\
    ;
    try expectCode(data, &.{"src/cli/x.zig:15: " ++ msg_call});
}

test "rule 2: braces in strings and character literals do not end a test block early" {
    const data =
        \\test "braces" {
        \\    const s = "}";
        \\    const ch = '}';
        \\    _ = net.once(a);
        \\}
        \\fn f() void {
        \\    _ = net.once(a);
        \\}
        \\
    ;
    try expectCode(data, &.{"src/cli/x.zig:7: " ++ msg_call});
}

test "rule 2 and 3 skip test files and the generated table" {
    const bad = "const r = net.request(a, .GET, \"/me\", .{});\n";
    try expectIn(&.{
        .{ .path = "src/cli/x_test.zig", .data = bad },
        .{ .path = "src/cli/registry_commands.zig", .data = bad },
    }, client, commands, &.{});
}

test "rule 2 and 3 report the file of each finding" {
    const bad = "const r = net.once(a, .GET, \"/me\", .{});\n";
    try expectIn(&.{
        .{ .path = "src/cli/a.zig", .data = bad },
        .{ .path = "src/core/ci_oidc.zig", .data = "const x = 1;\n" ++ bad },
    }, client, commands, &.{
        "src/cli/a.zig:1: " ++ msg_call,
        "src/cli/a.zig:1: " ++ msg_path,
        "src/core/ci_oidc.zig:2: " ++ msg_call,
        "src/core/ci_oidc.zig:2: " ++ msg_path,
    });
}

test "rule 3: a literal that starts with a route root of the client is a finding" {
    const lits = [_][]const u8{
        "\"/packages/{s}\"",
        "\"/me\"",
        "\"/me/tokens\"",
        "\"/me?x=1\"",
        "\"/health\"",
        "\"/packages/{s}/{s}/versions/{s}\"",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (lits) |lit| {
        const data = try std.fmt.allocPrint(a, "fn f() void {{\n    const p = try std.fmt.allocPrint(a, {s}, .{{x}});\n}}\n", .{lit});
        try expectCode(data, &.{"src/cli/x.zig:2: " ++ msg_path});
    }
}

test "rule 3: a literal with /api/v2/ or /api/v1/ inside is a finding" {
    try expectCode("const u = \"https://x.example/api/v2/me\";\n", &.{"src/cli/x.zig:1: " ++ msg_path});
    try expectCode("const u = \"/api/v2/...\";\n", &.{"src/cli/x.zig:1: " ++ msg_path});
    try expectCode("const u = \"{s}/api/v1/packages\";\n", &.{"src/cli/x.zig:1: " ++ msg_path});
}

test "rule 3: only whole first segments count" {
    try expectCode("const a = \"/meta\";\nconst b = \"/tmp/x\";\nconst c = \"/healthy\";\nconst d = \"me\";\nconst e = \"x/me\";\nconst f = \"/api/v3/x\";\nconst g = \"/\";\n", &.{});
}

test "rule 3: the roots come from the client's path templates" {
    const small_client =
        \\pub const GetMe = struct {
        \\    pub const operation_id = "getMe";
        \\    pub const path_template = "/me";
        \\};
        \\
    ;
    try expectIn(&.{.{ .path = "src/cli/x.zig", .data = "const a = \"/packages/x\";\nconst b = \"/me\";\n" }}, small_client, "v2.GetMe", &.{"src/cli/x.zig:2: " ++ msg_path});
}

test "rule 3: a comment line, a test block and a marker are not findings" {
    const data =
        \\// the path is "/me" or "/packages/x"
        \\const a = 1; // "/me"
        \\test "paths" {
        \\    const p = "/packages/x";
        \\}
        \\// not the registry API: the static index
        \\const b = "/packages/index.json";
        \\const c = "/me"; // not the registry API: a local file
        \\const d = "/me";
        \\
    ;
    try expectCode(data, &.{"src/cli/x.zig:9: " ++ msg_path});
}

test "a Windows line ending does not hide a finding" {
    try expectCode("const r = net.once(a);\r\n", &.{"src/cli/x.zig:1: " ++ msg_call});
}
