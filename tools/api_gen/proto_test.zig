//! Tests of proto.zig, the parser of the registry protos.

const std = @import("std");
const model = @import("model.zig");
const proto = @import("proto.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Source = proto.Source;
const parse = proto.parse;
const imports = proto.imports;

const testing = std.testing;

const head =
    "syntax = \"proto3\";\n" ++
    "package mopm.registry.v2;\n";

const min_service = "service S {\n  option (api) = { base_path: \"/api/v2\" };\n}\n";

const sample =
    head ++
    \\
    \\import "mopm/registry/v2/options.proto";
    \\import "google/api/annotations.proto";
    \\import "google/protobuf/empty.proto";
    \\
    \\// A short name.
    \\message Name {
    \\  option (schema) = {wrapper: true};
    \\  string value = 1 [(field) = {min_length: 1, max_length: 39, pattern: "^[a-z]+$" "x"}];
    \\}
    \\
    \\// How a thing stands.
    \\enum State {
    \\  STATE_UNSPECIFIED = 0;
    \\  // Live.
    \\  STATE_ACTIVE = 1;
    \\  STATE_LINUX_64 = 2 [(json) = "linux-64"];
    \\}
    \\
    \\// A thing.
    \\//
    \\// Second paragraph.
    \\message Thing {
    \\  option (mopm.registry.v2.schema) = {
    \\    one_of: [{required: ["name", "state"]}, {required: ["tags"]}]
    \\    when { field: "state" equals: "active"; required: ["name"] }
    \\  };
    \\  // The name.
    \\  Name name = 1 [(field) = {required: true, param: "name"}];
    \\  State state = 2;
    \\  repeated string tags = 3 [(field) = {max_items: 10, unique_items: true, items: {min_length: 1}}];
    \\  map<string, string> labels = 4;
    \\  optional int64 size = 5 [(field) = {minimum: -1, default: "20"}];
    \\  Entry entry = 6;
    \\  oneof choice {
    \\    string text = 7;
    \\    .mopm.registry.v2.Name other = 8;
    \\  }
    \\  // Nested.
    \\  message Entry {
    \\    string k = 1;
    \\  }
    \\  enum Kind { KIND_UNSPECIFIED = 0; KIND_A = 1; }
    \\}
    \\
    \\message GetThingParams { string id = 1; }
    \\message PutThingParams { string id = 1; Thing body = 2; int32 limit = 3; }
    \\
    \\// The registry.
    \\// Two lines.
    \\service Registry {
    \\  option (api) = {
    \\    title: "T" version: "1" summary: "S" license_name: "L" license_identifier: "LI" base_path: "/api/v2"
    \\    servers: [{url: "https://x/{env}" description: "d" variable: "env" default: "prod" values: ["prod", "dev"]}]
    \\    tags: ["a", "b"]
    \\    security_schemes { name: "bearerAuth" bearer_format: "JWT" description: "tok" }
    \\    headers: [{name: "RequestId" wire: "X-Request-Id" description: "h" required: true type: "string" min_length: 1 on_success: true}]
    \\    error_response: "oops"
    \\  };
    \\  // Fetch one.
    \\  rpc GetThing(GetThingParams) returns (mopm.registry.v2.Thing) {
    \\    option (google.api.http) = { get: "/api/v2/things/{id}" };
    \\    option (operation) = {
    \\      tags: ["a"] summary: "Get" security: ["bearerAuth"]
    \\      responses: [{status: 200 description: "ok"}, {status: 404 description: "missing" error: true}]
    \\    };
    \\  }
    \\  rpc PutThing(PutThingParams) returns (google.protobuf.Empty) {
    \\    option (google.api.http) = { put: "/api/v2/things/{id}" body: "body" };
    \\  }
    \\}
    \\
;

fn parseOk(arena: Allocator, files: []const Source) !model.Api {
    return switch (try parse(arena, files)) {
        .ok => |api| api,
        .bad => |m| {
            std.debug.print("unexpected refusal: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectRefused(files: []const Source, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    switch (try parse(arena.allocator(), files)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |m| try testing.expectEqualStrings(want, m),
    }
}

/// `text` as the one file `t.proto`.
fn bad(text: []const u8, want: []const u8) !void {
    try expectRefused(&.{.{ .path = "t.proto", .text = text }}, want);
}

/// `body` after the head (its first line is line 3) and before a minimal service.
fn badBody(comptime body: []const u8, want: []const u8) !void {
    try bad(head ++ body ++ min_service, want);
}

/// A message `Req { id, b }` and an rpc with the google.api.http option `http` (line 7; the rpc is on line 6).
fn rpcCase(comptime http: []const u8) []const u8 {
    return head ++ "message Req { string id = 1; string b = 2; }\nservice S {\n  option (api) = { base_path: \"/api/v2\" };\n" ++
        "  rpc R(Req) returns (google.protobuf.Empty) {\n    option (google.api.http) = { " ++ http ++ " };\n  }\n}\n";
}

test "a small API is read into the model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const api = try parseOk(a, &.{.{ .path = "mopm/registry/v2/x.proto", .text = sample }});

    try testing.expectEqualStrings("mopm.registry.v2", api.package);
    try testing.expectEqualStrings("Registry", api.service);
    try testing.expectEqualStrings("The registry.\nTwo lines.", api.doc);
    try testing.expectEqualStrings("T", api.title);
    try testing.expectEqualStrings("/api/v2", api.base_path);
    try testing.expectEqualStrings("oops", api.error_response);
    try testing.expectEqual(@as(usize, 1), api.servers.len);
    try testing.expectEqualStrings("https://x/{env}", api.servers[0].url);
    try testing.expectEqualStrings("env", api.servers[0].variable);
    try testing.expectEqual(@as(usize, 2), api.servers[0].values.len);
    try testing.expectEqualStrings("dev", api.servers[0].values[1]);
    try testing.expectEqual(@as(usize, 2), api.tags.len);
    try testing.expectEqualStrings("JWT", api.security_schemes[0].bearer_format);
    try testing.expectEqualStrings("X-Request-Id", api.headers[0].wire);
    try testing.expect(api.headers[0].required and api.headers[0].on_success);
    try testing.expectEqual(@as(?u64, 1), api.headers[0].min_length);
    try testing.expectEqual(@as(?i64, null), api.headers[0].minimum);

    // Messages in declaration order, nested right after their parent.
    try testing.expectEqual(@as(usize, 5), api.messages.len);
    const names = [_][]const u8{ "Name", "Thing", "Thing.Entry", "GetThingParams", "PutThingParams" };
    for (names, api.messages) |want, m| try testing.expectEqualStrings(want, m.path);
    try testing.expectEqual(@as(?usize, 1), api.messages[2].parent);
    try testing.expectEqualStrings("Entry", api.messages[2].name);
    try testing.expectEqualStrings("Nested.", api.messages[2].doc);
    try testing.expectEqualStrings("x.proto", std.fs.path.basename(api.messages[0].file));
    try testing.expectEqual(@as(usize, 5), api.order.len);
    try testing.expectEqual(model.Decl{ .message = 0 }, api.order[0]);
    try testing.expectEqual(model.Decl{ .enumeration = 0 }, api.order[1]);
    try testing.expectEqual(model.Decl{ .message = 1 }, api.order[2]);
    try testing.expectEqual(model.Decl{ .message = 3 }, api.order[3]);

    const name = api.messages[0];
    try testing.expect(name.wrapper and !name.is_union);
    try testing.expectEqualStrings("A short name.", name.doc);
    try testing.expectEqualStrings("^[a-z]+$x", name.fields[0].rules.pattern.?);
    try testing.expectEqual(@as(?u64, 39), name.fields[0].rules.max_length);

    const thing = api.messages[1];
    try testing.expectEqualStrings("A thing.\n\nSecond paragraph.", thing.doc);
    try testing.expectEqual(@as(usize, 2), thing.one_of.len);
    try testing.expectEqualStrings("state", thing.one_of[0].required[1]);
    try testing.expectEqualStrings("tags", thing.one_of[1].required[0]);
    try testing.expectEqualStrings("active", thing.when.?.equals);
    try testing.expectEqualStrings("name", thing.when.?.required[0]);
    try testing.expectEqual(@as(usize, 8), thing.fields.len);
    const f = thing.fields;
    try testing.expectEqualStrings("The name.", f[0].doc);
    try testing.expectEqual(model.Type{ .message = 0 }, f[0].type);
    try testing.expect(f[0].rules.required);
    try testing.expectEqualStrings("name", f[0].rules.param.?);
    try testing.expectEqual(model.Type{ .enumeration = 0 }, f[1].type);
    try testing.expectEqual(model.Label.repeated, f[2].label);
    try testing.expectEqual(@as(?u64, 10), f[2].rules.max_items);
    try testing.expect(f[2].rules.unique_items);
    try testing.expectEqual(@as(?u64, 1), f[2].rules.items.?.min_length);
    try testing.expect(f[3].map);
    try testing.expectEqual(model.Type{ .scalar = .string }, f[3].type);
    try testing.expectEqual(model.Label.optional, f[4].label);
    try testing.expectEqual(model.Type{ .scalar = .int64 }, f[4].type);
    try testing.expectEqual(@as(?i64, -1), f[4].rules.minimum);
    try testing.expectEqualStrings("20", f[4].rules.default.?);
    try testing.expectEqual(model.Type{ .message = 2 }, f[5].type);
    try testing.expectEqualStrings("choice", f[6].oneof.?);
    try testing.expectEqual(@as(?[]const u8, null), f[5].oneof);
    try testing.expectEqual(model.Type{ .message = 0 }, f[7].type);
    try testing.expectEqual(@as(u32, 8), f[7].number);

    try testing.expectEqual(@as(usize, 2), api.enums.len);
    try testing.expectEqualStrings("Thing.Kind", api.enums[1].path);
    try testing.expectEqual(@as(?usize, 1), api.enums[1].parent);
    try testing.expectEqualStrings("How a thing stands.", api.enums[0].doc);
    try testing.expectEqualStrings("Live.", api.enums[0].values[1].doc);
    const json = try model.jsonValues(a, api.enums[0]);
    try testing.expectEqualStrings("active", json[0]);
    try testing.expectEqualStrings("linux-64", json[1]);

    try testing.expectEqual(@as(usize, 2), api.rpcs.len);
    const get = api.rpcs[0];
    try testing.expectEqualStrings("GetThing", get.name);
    try testing.expectEqualStrings("Fetch one.", get.doc);
    try testing.expectEqual(model.Method.GET, get.method);
    try testing.expectEqualStrings("/api/v2/things/{id}", get.path);
    try testing.expectEqual(@as(?[]const u8, null), get.body);
    try testing.expectEqual(model.Type{ .message = 3 }, get.input);
    try testing.expectEqual(model.Type{ .message = 1 }, get.output);
    try testing.expectEqualStrings("Get", get.summary);
    try testing.expectEqualStrings("bearerAuth", get.security[0]);
    try testing.expectEqual(@as(usize, 2), get.responses.len);
    try testing.expectEqual(@as(u16, 404), get.responses[1].status);
    try testing.expect(get.responses[1].is_error and !get.responses[0].is_error);
    const put = api.rpcs[1];
    try testing.expectEqual(model.Method.PUT, put.method);
    try testing.expectEqualStrings("body", put.body.?);
    try testing.expectEqual(model.Type.empty, put.output);
    try testing.expectEqual(@as(usize, 0), put.responses.len);
    try testing.expectEqualStrings("", put.doc);
    try testing.expectEqual(@as(usize, 1), (try model.pathParams(a, api, put)).len);
    try testing.expectEqualStrings("limit", (try model.queryParams(a, api, put))[0].name);

    var h = Sha256.init(.{});
    h.update("mopm/registry/v2/x.proto\x00" ++ sample ++ "\x00");
    try testing.expectEqualStrings(&std.fmt.bytesToHex(h.finalResult(), .lower), api.sources_sha256);
}

test "files are read in the order given and types resolve across them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const api = try parseOk(a, &.{
        .{ .path = "a.proto", .text = head ++ "message A { B b = 1; }\n" },
        .{ .path = "b.proto", .text = head ++ "message B { string s = 1; }\n" ++ min_service },
    });
    try testing.expectEqualStrings("a.proto", api.messages[0].file);
    try testing.expectEqualStrings("b.proto", api.messages[1].file);
    try testing.expectEqual(model.Type{ .message = 1 }, api.messages[0].fields[0].type);
    try testing.expectEqual(@as(usize, 64), api.sources_sha256.len);
}

test "names resolve from the innermost scope out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = head ++
        \\message Name { string v = 1; }
        \\message Outer {
        \\  message Name { string w = 1; }
        \\  message Inner { Name n = 1; Outer.Name o = 2; mopm.registry.v2.Name p = 3; .mopm.registry.v2.Name q = 4; }
        \\  Name n = 1;
        \\}
        \\
    ++ min_service }});
    // Name = 0, Outer = 1, Outer.Name = 2, Outer.Inner = 3
    try testing.expectEqual(model.Type{ .message = 2 }, api.messages[1].fields[0].type);
    const inner = api.messages[3].fields;
    try testing.expectEqual(model.Type{ .message = 2 }, inner[0].type);
    try testing.expectEqual(model.Type{ .message = 2 }, inner[1].type);
    try testing.expectEqual(model.Type{ .message = 0 }, inner[2].type);
    try testing.expectEqual(model.Type{ .message = 0 }, inner[3].type);
}

test "comments: only the lines directly above a declaration are its doc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = head ++
        \\// detached
        \\
        \\// real doc
        \\// line two
        \\message A { // trailing
        \\  string x = 1; // trailing x
        \\  // doc y
        \\
        \\  string y = 2;
        \\  // p
        \\  //
        \\  //   q
        \\  string z = 3;
        \\}
        \\
    ++ min_service }});
    try testing.expectEqualStrings("real doc\nline two", api.messages[0].doc);
    try testing.expectEqualStrings("", api.messages[0].fields[0].doc);
    try testing.expectEqualStrings("", api.messages[0].fields[1].doc);
    try testing.expectEqualStrings("p\n\n  q", api.messages[0].fields[2].doc);
}

test "option values: escapes, separators, nested literals and qualified names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = head ++
        \\message A {
        \\  string x = 1 [(mopm.registry.v2.field) = {pattern: "a\"b\\c\nd\te\rf\'g" default: 'h'; const: "i" "j", format: "k"}];
        \\}
        \\message B { option (.mopm.registry.v2.schema) = { one_of { required: "x" required: "y" } }; string x = 1; string y = 2; }
        \\
    ++ min_service }});
    const r = api.messages[0].fields[0].rules;
    try testing.expectEqualStrings("a\"b\\c\nd\te\rf'g", r.pattern.?);
    try testing.expectEqualStrings("h", r.default.?);
    try testing.expectEqualStrings("ij", r.@"const".?);
    try testing.expectEqualStrings("k", r.format.?);
    try testing.expectEqual(@as(usize, 1), api.messages[1].one_of.len);
    try testing.expectEqual(@as(usize, 2), api.messages[1].one_of[0].required.len);
}

test "enum values with an error entry, a union and a wrapper of a repeated field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = head ++
        \\enum ErrorCode {
        \\  ERROR_CODE_UNSPECIFIED = 0;
        \\  ERROR_CODE_BAD = 1 [(error) = {status: 400 message: "m {x}" hint: "h" reasons: ["r1", "r2"]}];
        \\}
        \\message Names { option (schema) = {wrapper: true}; repeated string value = 1; }
        \\message U { option (schema) = {union: true}; oneof u { Names names = 1; string all = 2 [(field) = {const: "all"}]; } }
        \\
    ++ min_service }});
    const e = api.enums[0].values[1].err.?;
    try testing.expectEqual(@as(u16, 400), e.status);
    try testing.expectEqualStrings("m {x}", e.message);
    try testing.expectEqualStrings("r2", e.reasons[1]);
    try testing.expectEqual(@as(?model.ErrorEntry, null), api.enums[0].values[0].err);
}

test "imports lists a file's imports in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try imports(arena.allocator(),
        \\syntax = "proto3";
        \\package p;
        \\import "b.proto";
        \\import public "c.proto";
        \\message M { string import = 1; }
        \\
    );
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("b.proto", got[0]);
    try testing.expectEqualStrings("c.proto", got[1]);
    try testing.expectEqual(@as(usize, 0), (try imports(arena.allocator(), "import \"a\" /* x */")).len);
}

test "refused: the shape of a file" {
    try bad("package x;\n", "t.proto:1: the file must start with syntax = \"proto3\";");
    try bad("syntax = \"proto2\";\n", "t.proto:1: only syntax \"proto3\" is supported");
    try bad("syntax = \"proto3\";\nmessage A {}\n", "t.proto:2: the package statement must come before 'message'");
    try bad("syntax = \"proto3\";\n", "t.proto:2: missing package statement");
    try bad(head ++ "package mopm.registry.v2;\n", "t.proto:3: duplicate package statement");
    try expectRefused(&.{
        .{ .path = "a.proto", .text = head },
        .{ .path = "b.proto", .text = "syntax = \"proto3\";\npackage other;\n" },
    }, "b.proto:2: package 'other' differs from 'mopm.registry.v2'");
    try bad(head ++ "message A { string x = 1; }\n", "no service declared in the sources");
    try bad(head ++ "import public \"x.proto\";\n", "t.proto:3: import public is not supported");
    try bad(head ++ "extend A {}\n", "t.proto:3: unexpected 'extend'");
    try bad(head ++ "message A {}\n/* c */\n", "t.proto:4: block comments (/* */) are not supported");
    try bad(head ++ "message A { string x = 1 [(field) = {pattern: \"a}]; }\n", "t.proto:3: unterminated string");
    try bad(head ++ "message A { string x = 1 [(field) = {pattern: \"\\q\"}]; }\n", "t.proto:3: unsupported escape '\\q'");
    try bad(head ++ "message A { string x = 1 [(field) = {pattern: \"a\\", "t.proto:3: unterminated string");
    try bad(head ++ "message A { string x = 99999999999999999999; }\n", "t.proto:3: integer '99999999999999999999' is out of range");
    try bad(head ++ "message A { string x = 1; } @\n", "t.proto:3: unexpected character '@'");
    try bad(head ++ "message A { string x = 1; } /\n", "t.proto:3: unexpected character '/'");
    try bad(head ++ "message A { string x = 1 }\n", "t.proto:3: expected ';' but found '}'");
    try bad(head ++ "message { }\n", "t.proto:3: expected a name but found '{'");
    try bad(head ++ "message A {", "t.proto:3: unexpected end of file");
    try bad(head ++ "message A { string x = \"1\"; }\n", "t.proto:3: expected a number but found \"1\"");
}

test "refused: messages and fields" {
    try badBody("message A {}\nmessage A {}\n", "t.proto:4: duplicate name 'A'");
    try badBody("message A { message B {} enum B { B_X = 0; } }\n", "t.proto:3: duplicate name 'A.B'");
    try badBody("message A { string x = 1;\n string x = 2; }\n", "t.proto:4: duplicate field 'x' in message 'A'");
    try badBody("message A { string x = 1;\n string y = 1; }\n", "t.proto:4: duplicate field number 1 in message 'A'");
    try badBody("message A { string x = 0; }\n", "t.proto:3: field number 0 is out of range");
    try badBody("message A { reserved 2; }\n", "t.proto:3: 'reserved' is not supported");
    try badBody("message A {\n Nmae x = 1;\n}\n", "t.proto:4: unknown type 'Nmae'");
    try badBody("message A { double x = 1; }\n", "t.proto:3: unsupported type 'double'");
    try badBody("message A { google.protobuf.Empty x = 1; }\n", "t.proto:3: 'google.protobuf.Empty' is only allowed as an rpc input or output");
    try badBody("message A { map<int32, string> x = 1; }\n", "t.proto:3: map keys must be string, not 'int32'");
    try badBody("message A { repeated map<string, string> x = 1; }\n", "t.proto:3: a map field cannot have a label");
    try badBody("message A { oneof o { map<string, string> x = 1; } }\n", "t.proto:3: a map field cannot be in a oneof");
    try badBody("message A { oneof o { repeated string x = 1; } }\n", "t.proto:3: a oneof field cannot have a label");
    try badBody("message A { oneof o { } }\n", "t.proto:3: oneof 'o' has no fields");
    try badBody("message A { oneof o { string x = 1; } oneof o { string y = 2; } }\n", "t.proto:3: duplicate oneof 'o' in message 'A'");
    try badBody("message A { oneof o { option (schema) = {}; string x = 1; } }\n", "t.proto:3: options inside a oneof are not supported");
}

test "refused: enums" {
    try badBody("enum E {\n E_A = 1;\n}\n", "t.proto:4: the first value of enum 'E' must be 0");
    try badBody("enum E {\n A = 0;\n}\n", "t.proto:4: enum value 'A' must start with 'E_' or have a (json) option");
    try badBody("enum E { E_A = 0;\n E_A = 1; }\n", "t.proto:4: duplicate enum value name 'E_A'");
    try badBody("enum E { E_A = 0; }\nenum F { E_A = 0 [(json) = \"x\"]; }\n", "t.proto:4: duplicate enum value name 'E_A'");
    try badBody("enum E { E_A = 0;\n E_B = 0; }\n", "t.proto:4: duplicate enum value number 0 in enum 'E'");
    try badBody("enum E { }\n", "t.proto:3: enum 'E' has no values");
    try badBody("enum E { option allow_alias = true; }\n", "t.proto:3: unknown option 'allow_alias'");
    try badBody("enum E { E_A = 99999999999; }\n", "t.proto:3: enum value number 99999999999 is out of range");
    try badBody("enum E { E_A = 0 [(json) = 1]; }\n", "t.proto:3: option (json): the value must be a string");
    try badBody("enum E { E_A = 0 [(field) = {}]; }\n", "t.proto:3: unknown option '(field)'");
    try badBody("enum E { E_A = 0 [(json) = \"a\", (json) = \"b\"]; }\n", "t.proto:3: option '(json)' is set twice");
    try badBody("enum E { E_A = 0 [(error) = {status: 70000}]; }\n", "t.proto:3: option (error): 'status' must be an integer that fits u16");
}

test "refused: options" {
    try badBody("message A { string x = 1 [(nope) = {}]; }\n", "t.proto:3: unknown option '(nope)'");
    try badBody("message A { string x = 1 [deprecated = true]; }\n", "t.proto:3: unknown option 'deprecated'");
    try badBody("message A { string x = 1 [(field) = {nope: 1}]; }\n", "t.proto:3: unknown key 'nope' in option (field)");
    try badBody("message A { string x = 1 [(field) = {required: 1}]; }\n", "t.proto:3: option (field): 'required' must be true or false");
    try badBody("message A { string x = 1 [(field) = {pattern: 1}]; }\n", "t.proto:3: option (field): 'pattern' must be a string");
    try badBody("message A { string x = 1 [(field) = {min_length: -1}]; }\n", "t.proto:3: option (field): 'min_length' must be an integer that fits u64");
    try badBody("message A { string x = 1 [(field) = {min_length: \"1\"}]; }\n", "t.proto:3: option (field): 'min_length' must be an integer");
    try badBody("message A { string x = 1 [(field) = {items: 1}]; }\n", "t.proto:3: option (field): 'items' must be a message literal");
    try badBody("message A { string x = 1 [(field) = {required: true required: false}]; }\n", "t.proto:3: option (field): 'required' is set twice");
    try badBody("message A { string x = 1 [(field) = 1]; }\n", "t.proto:3: option (field): the value must be a message literal");
    try badBody("message A { string x = 1 [(field) = {}, (field) = {}]; }\n", "t.proto:3: option '(field)' is set twice");
    try badBody("message A { string x = 1 [(field) = {required}]; }\n", "t.proto:3: expected ':' after key 'required' but found '}'");
    try badBody("message A { string x = 1 [(field) = {required: ]; }\n", "t.proto:3: expected a value but found ']'");
    try badBody("message A { string x = 1 [(field) = {items: {max_items: [1 2]}}]; }\n", "t.proto:3: expected ',' or ']' but found '2'");
    try badBody("message A { option (field) = {}; }\n", "t.proto:3: unknown option '(field)'");
    try badBody("message A { option (schema) = {nope: 1}; }\n", "t.proto:3: unknown key 'nope' in option (schema)");
    try badBody("message A { option (schema) = {};\n option (schema) = {}; }\n", "t.proto:4: option '(schema)' is set twice");
    try badBody("message A { option (schema) = {one_of: [1]}; }\n", "t.proto:3: option (schema): 'one_of' must be a message literal");
}

test "refused: what the schema option promises" {
    try badBody("message A {\n option (schema) = {wrapper: true union: true};\n string value = 1; }\n", "t.proto:4: message 'A' cannot be both a wrapper and a union");
    try badBody("message A {\n option (schema) = {wrapper: true};\n string v = 1; }\n", "t.proto:4: wrapper message 'A' must have exactly one field named 'value'");
    try badBody("message A {\n option (schema) = {wrapper: true};\n string value = 1; string b = 2; }\n", "t.proto:4: wrapper message 'A' must have exactly one field named 'value'");
    try badBody("message A {\n option (schema) = {union: true};\n string x = 1; }\n", "t.proto:4: union message 'A' must have exactly one oneof holding all its fields");
    try badBody("message A {\n option (schema) = {union: true};\n oneof o { string x = 1; } string y = 2; }\n", "t.proto:4: union message 'A' must have exactly one oneof holding all its fields");
    try badBody("message A {\n option (schema) = {union: true};\n oneof o { string x = 1; } oneof p { string y = 2; } }\n", "t.proto:4: union message 'A' must have exactly one oneof holding all its fields");
    try badBody("message A {\n option (schema) = {one_of: [{required: [\"x\"]}, {required: [\"nope\"]}]};\n string x = 1; }\n", "t.proto:4: message 'A': one_of names unknown field 'nope'");
    try badBody("message A {\n option (schema) = {when: {field: \"nope\" equals: \"a\"}};\n string x = 1; }\n", "t.proto:4: message 'A': when names unknown field 'nope'");
    try badBody("message A {\n option (schema) = {when: {field: \"x\" equals: \"a\" required: [\"nope\"]}};\n string x = 1; }\n", "t.proto:4: message 'A': when requires unknown field 'nope'");
}

test "refused: the service and its rpcs" {
    try bad(head ++ "service S {}\nservice T {}\n", "t.proto:4: second service 'T' (the first is 'S')");
    try bad(head ++ "service S {}\n", "t.proto:3: service 'S' has no option (api)");
    try bad(head ++ "service S { option (api) = {}; option (api) = {}; }\n", "t.proto:3: option '(api)' is set twice");
    try bad(head ++ "service S { option (schema) = {}; }\n", "t.proto:3: unknown option '(schema)'");
    try bad(head ++ "service S { message A {} }\n", "t.proto:3: unexpected 'message'");
    try bad(head ++ "service S { option (api) = {nope: 1}; }\n", "t.proto:3: unknown key 'nope' in option (api)");
    try bad(rpcCase("post: \"/api/v2/x\" get: \"/api/v2/x\""), "t.proto:7: rpc 'R': google.api.http needs exactly one of get, put, post, delete, patch");
    try bad(rpcCase(""), "t.proto:7: rpc 'R': google.api.http needs exactly one of get, put, post, delete, patch");
    try bad(rpcCase("get: \"/other/x\""), "t.proto:6: rpc 'R': path '/other/x' does not start with base_path '/api/v2'");
    try bad(rpcCase("get: \"/api/v2x\""), "t.proto:6: rpc 'R': path '/api/v2x' does not start with base_path '/api/v2'");
    try bad(rpcCase("get: \"/api/v2/x/{nope}\""), "t.proto:6: rpc 'R': path parameter 'nope' is not a field of 'Req'");
    try bad(rpcCase("get: \"/api/v2/x/{id\""), "t.proto:6: rpc 'R': path '/api/v2/x/{id' has an unclosed '{'");
    try bad(rpcCase("put: \"/api/v2/x\" body: \"nope\""), "t.proto:6: rpc 'R': body field 'nope' is not a field of 'Req'");
    try bad(rpcCase("put: \"/api/v2/x\" nope: \"a\""), "t.proto:7: unknown key 'nope' in option (google.api.http)");
    try bad(rpcCase("put: \"/api/v2/x\" body: \"b\" }; option (google.api.http) = { get: \"/api/v2/y\""), "t.proto:7: option '(google.api.http)' is set twice");
}

/// A message `Req { id, b }` and an rpc whose `(operation)` option holds `op` (line 8; the rpc is on line 6).
fn opCase(comptime op: []const u8) []const u8 {
    return head ++ "message Req { string id = 1; string b = 2; }\nservice S {\n  option (api) = { base_path: \"/api/v2\" };\n" ++
        "  rpc R(Req) returns (google.protobuf.Empty) {\n    option (google.api.http) = { get: \"/api/v2/x/{id}\" };\n" ++
        "    option (operation) = { " ++ op ++ " };\n  }\n}\n";
}

test "the commands of an rpc are read in order with their name, args, set, defaults and summary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = comptime opCase("commands { name: \"x one\" args: \"id\" args: \"b\" set: \"k=v\" set: \"j=w\" defaults: \"d=e\" summary: \"One.\" } " ++
        "commands: [{name: \"x two\" summary: \"Two.\"}]");
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = text }});
    const cmds = api.rpcs[0].commands;
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqualStrings("x one", cmds[0].name);
    try testing.expectEqual(@as(usize, 2), cmds[0].args.len);
    try testing.expectEqualStrings("id", cmds[0].args[0]);
    try testing.expectEqualStrings("b", cmds[0].args[1]);
    try testing.expectEqual(@as(usize, 2), cmds[0].set.len);
    try testing.expectEqualStrings("k=v", cmds[0].set[0]);
    try testing.expectEqualStrings("j=w", cmds[0].set[1]);
    try testing.expectEqual(@as(usize, 1), cmds[0].defaults.len);
    try testing.expectEqualStrings("d=e", cmds[0].defaults[0]);
    try testing.expectEqualStrings("One.", cmds[0].summary);
    try testing.expectEqualStrings("x two", cmds[1].name);
    try testing.expectEqual(@as(usize, 0), cmds[1].args.len);
    try testing.expectEqual(@as(usize, 0), cmds[1].set.len);
    try testing.expectEqual(@as(usize, 0), cmds[1].defaults.len);
    try testing.expectEqualStrings("Two.", cmds[1].summary);
}

test "an rpc with no commands has none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = comptime opCase("summary: \"S\"") }});
    try testing.expectEqual(@as(usize, 0), api.rpcs[0].commands.len);
}

test "refused: a command's keys and values" {
    try bad(opCase("commands { name: \"x\" nope: \"a\" }"), "t.proto:8: unknown key 'nope' in option (operation)");
    try bad(opCase("commands { name: \"x\" name: \"y\" }"), "t.proto:8: option (operation): 'name' is set twice");
    try bad(opCase("commands { name: 3 }"), "t.proto:8: option (operation): 'name' must be a string");
}

test "refused: rpc declarations" {
    const pre = head ++ "message Req { string id = 1; }\nenum E { E_A = 0; }\nservice S {\n  option (api) = {};\n";
    try bad(pre ++ "  rpc R(Req) returns (Req);\n}\n", "t.proto:7: rpc 'R' has no option (google.api.http)");
    try bad(pre ++ "  rpc R(stream Req) returns (Req) {}\n}\n", "t.proto:7: streaming rpcs are not supported");
    try bad(pre ++ "  rpc R(Req) returns (stream Req) {}\n}\n", "t.proto:7: streaming rpcs are not supported");
    try bad(pre ++ "  rpc R(Req) returns (Req) { option (google.api.http) = { get: \"/x\" }; }\n  rpc R(Req) returns (Req) {}\n}\n", "t.proto:8: duplicate rpc 'R'");
    try bad(pre ++ "  rpc R(Req) gives (Req) {}\n}\n", "t.proto:7: expected 'returns' but found 'gives'");
    try bad(pre ++ "  rpc R(E) returns (Req) { option (google.api.http) = { get: \"/x\" }; }\n}\n", "t.proto:7: rpc 'R': input 'E' is not a message");
    try bad(pre ++ "  rpc R(Req) returns (E) { option (google.api.http) = { get: \"/x\" }; }\n}\n", "t.proto:7: rpc 'R': output 'E' is not a message");
    try bad(pre ++ "  rpc R(Nope) returns (Req) { option (google.api.http) = { get: \"/x\" }; }\n}\n", "t.proto:7: unknown type 'Nope'");
    try bad(pre ++ "  rpc R(Req) returns (Req) { option (nope) = {}; }\n}\n", "t.proto:7: unknown option '(nope)'");
    try bad(pre ++ "  rpc R(Req) returns (Req) { message A {} }\n}\n", "t.proto:7: unexpected 'message'");
    try bad(pre ++ "  rpc R(Req) returns (Req) { option (operation) = {}; option (operation) = {}; }\n}\n", "t.proto:7: option '(operation)' is set twice");
    try bad(head ++ "service S { option (api) = {base_path: \"/a\"};\n rpc R(google.protobuf.Empty) returns (google.protobuf.Empty) { option (google.api.http) = { get: \"/a/{x}\" }; }\n}\n", "t.proto:4: rpc 'R': path parameter 'x' is not a field of 'google.protobuf.Empty'");
}

test "browser, response headers, a cookie and response_only are read from the options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = head ++ "message Req { string id = 1; }\nservice S {\n" ++
        "  option (api) = { base_path: \"/api/v2\"\n" ++
        "    security_schemes { name: \"web\" cookie: \"sid\" description: \"c\" }\n" ++
        "    headers: [{name: \"Where\" wire: \"Location\" type: \"string\" response_only: true}] };\n" ++
        "  rpc R(Req) returns (google.protobuf.Empty) {\n    option (google.api.http) = { get: \"/api/v2/x/{id}\" };\n" ++
        "    option (operation) = { browser: true responses: [{status: 302 description: \"go\" headers: [\"Where\"]}] };\n  }\n" ++
        "  rpc Q(Req) returns (google.protobuf.Empty) {\n    option (google.api.http) = { get: \"/api/v2/y/{id}\" };\n" ++
        "    option (operation) = { responses: [{status: 204 description: \"ok\"}] };\n  }\n}\n";
    const api = try parseOk(arena.allocator(), &.{.{ .path = "t.proto", .text = text }});
    try testing.expectEqualStrings("sid", api.security_schemes[0].cookie);
    try testing.expectEqualStrings("", api.security_schemes[0].bearer_format);
    try testing.expect(api.headers[0].response_only and !api.headers[0].on_success);
    try testing.expect(api.rpcs[0].browser and !api.rpcs[1].browser);
    try testing.expectEqual(@as(usize, 1), api.rpcs[0].responses[0].headers.len);
    try testing.expectEqualStrings("Where", api.rpcs[0].responses[0].headers[0]);
    try testing.expectEqual(@as(usize, 0), api.rpcs[1].responses[0].headers.len);
}
