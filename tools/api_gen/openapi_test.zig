//! Tests of openapi.zig, the OpenAPI writer.

const std = @import("std");
const model = @import("model.zig");
const openapi = @import("openapi.zig");
const Allocator = std.mem.Allocator;
const write = openapi.write;
const Writer = openapi.Writer;
const Entries = openapi.Entries;

const fixture_rules_namespace = model.Rules{ .min_length = 1, .max_length = 39, .pattern = "^[a-z]+$" };

const fixture_messages = [_]model.Message{
    // 0
    .{
        .name = "Namespace",
        .path = "Namespace",
        .doc = "A namespace.\nLowercase only.",
        .parent = null,
        .fields = &.{.{ .name = "value", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = fixture_rules_namespace }},
        .wrapper = true,
        .file = "t.proto",
    },
    // 1
    .{
        .name = "Error",
        .path = "Error",
        .doc = "An error.",
        .parent = null,
        .fields = &.{
            .{ .name = "code", .number = 1, .doc = "", .label = .single, .type = .{ .enumeration = 0 }, .rules = .{ .required = true } },
            .{ .name = "message", .number = 2, .doc = "Text for people.", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .required = true } },
        },
        .file = "t.proto",
    },
    // 2
    .{
        .name = "Thing",
        .path = "Thing",
        .doc = "A thing.",
        .parent = null,
        .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "", .label = .single, .type = .{ .message = 0 }, .rules = .{ .required = true } },
            .{ .name = "size", .number = 2, .doc = "How big.", .label = .single, .type = .{ .scalar = .int64 }, .rules = .{ .minimum = 1, .default = "20" } },
            .{
                .name = "tags",
                .number = 3,
                .doc = "",
                .label = .repeated,
                .type = .{ .scalar = .string },
                .rules = .{ .max_items = 3, .unique_items = true, .items = &.{ .min_length = 1 } },
            },
            .{ .name = "note", .number = 4, .doc = "A note.\nTwo lines.", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .nullable = true } },
            .{ .name = "kind", .number = 5, .doc = "", .label = .single, .type = .{ .enumeration = 1 } },
            .{ .name = "parent", .number = 6, .doc = "", .label = .single, .type = .{ .message = 0 }, .rules = .{ .nullable = true } },
            .{ .name = "labels", .number = 7, .doc = "", .label = .single, .type = .{ .scalar = .string }, .map = true },
            .{ .name = "choice", .number = 8, .doc = "", .label = .single, .type = .{ .message = 4 } },
            .{ .name = "flag", .number = 9, .doc = "", .label = .single, .type = .{ .scalar = .bool }, .rules = .{ .default = "true" } },
            .{ .name = "extra", .number = 10, .doc = "", .label = .single, .type = .{ .message = 3 } },
        },
        .one_of = &.{.{ .required = &.{"namespace"} }},
        .when = .{ .field = "kind", .equals = "b", .required = &.{"note"} },
        .file = "t.proto",
    },
    // 3
    .{
        .name = "Extra",
        .path = "Thing.Extra",
        .doc = "Inline.",
        .parent = 2,
        .fields = &.{.{ .name = "n", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .int32 }, .rules = .{ .required = true } }},
        .file = "t.proto",
    },
    // 4
    .{
        .name = "Choice",
        .path = "Choice",
        .doc = "",
        .parent = null,
        .fields = &.{
            .{ .name = "names", .number = 1, .doc = "", .label = .single, .type = .{ .message = 5 }, .oneof = "choice" },
            .{ .name = "all", .number = 2, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "choice", .rules = .{ .@"const" = "all" } },
        },
        .is_union = true,
        .file = "t.proto",
    },
    // 5
    .{
        .name = "Names",
        .path = "Choice.Names",
        .doc = "",
        .parent = 4,
        .fields = &.{.{ .name = "value", .number = 1, .doc = "", .label = .repeated, .type = .{ .message = 0 }, .rules = .{ .min_items = 1 } }},
        .wrapper = true,
        .file = "t.proto",
    },
    // 6
    .{
        .name = "GetThingParams",
        .path = "GetThingParams",
        .doc = "",
        .parent = null,
        .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "The namespace.", .label = .single, .type = .{ .message = 0 }, .rules = .{ .param = "Namespace" } },
            .{ .name = "sort", .number = 2, .doc = "", .label = .single, .type = .{ .enumeration = 2 }, .rules = .{ .param = "Sort", .default = "name" } },
            .{ .name = "limit", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .int64 }, .rules = .{ .param = "Limit", .minimum = 1, .maximum = 100, .default = "20" } },
        },
        .file = "t.proto",
    },
    // 7
    .{
        .name = "PutThingParams",
        .path = "PutThingParams",
        .doc = "",
        .parent = null,
        .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "The namespace.", .label = .single, .type = .{ .message = 0 }, .rules = .{ .param = "Namespace" } },
            .{ .name = "body", .number = 2, .doc = "", .label = .single, .type = .{ .message = 2 } },
        },
        .file = "t.proto",
    },
};

const fixture_error_values = [_]model.EnumValue{
    .{ .name = "ERROR_CODE_UNSPECIFIED", .number = 0, .doc = "" },
    .{ .name = "ERROR_CODE_BAD_THING", .number = 1, .doc = "", .err = .{ .status = 400, .message = "Bad \"{x}\".", .hint = "Fix it.\nThen retry.", .reasons = &.{ "a", "b" } } },
    .{ .name = "ERROR_CODE_GONE", .number = 2, .doc = "", .err = .{ .status = 410, .message = "Gone.", .hint = "" } },
};

const fixture_enums = [_]model.Enum{
    .{ .name = "ErrorCode", .path = "ErrorCode", .doc = "", .parent = null, .values = &fixture_error_values, .file = "t.proto" },
    .{
        .name = "Kind",
        .path = "Thing.Kind",
        .doc = "The kind.",
        .parent = 2,
        .values = &.{
            .{ .name = "KIND_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "KIND_A", .number = 1, .doc = "" },
            .{ .name = "KIND_B", .number = 2, .doc = "" },
        },
        .file = "t.proto",
    },
    .{
        .name = "Sort",
        .path = "Sort",
        .doc = "Sort order.",
        .parent = null,
        .values = &.{
            .{ .name = "SORT_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "SORT_NAME", .number = 1, .doc = "" },
            .{ .name = "SORT_UPDATED", .number = 2, .doc = "", .json_option = "last-updated" },
        },
        .file = "t.proto",
    },
};

const fixture_order = [_]model.Decl{
    .{ .message = 0 }, .{ .message = 1 }, .{ .enumeration = 0 }, .{ .message = 2 }, .{ .message = 4 }, .{ .message = 6 }, .{ .message = 7 }, .{ .enumeration = 2 },
};

const fixture_rpcs = [_]model.Rpc{
    .{
        .name = "GetThing",
        .doc = "Gets a thing.\n\nSecond paragraph.",
        .input = .{ .message = 6 },
        .output = .{ .message = 2 },
        .method = .GET,
        .path = "/api/v2/things/{namespace}",
        .body = null,
        .tags = &.{"things"},
        .summary = "Get a thing.",
        .security = &.{ "userToken", "otherToken" },
        .responses = &.{
            .{ .status = 200, .description = "The thing." },
            .{ .status = 404, .description = "Not here.", .is_error = true },
        },
    },
    .{
        .name = "PutThing",
        .doc = "",
        .input = .{ .message = 7 },
        .output = .empty,
        .method = .PUT,
        .path = "/api/v2/things/{namespace}",
        .body = "body",
        .tags = &.{"things"},
        .summary = "Store a thing.",
        .security = &.{},
        .responses = &.{.{ .status = 204, .description = "Stored." }},
    },
};

fn sample() model.Api {
    return .{
        .package = "t.v1",
        .service = "Things",
        .doc = "The things API.\n\n- one\n- two",
        .title = "Things",
        .version = "1.0.0",
        .summary = "A tiny API.",
        .license_name = "Apache-2.0",
        .license_identifier = "Apache-2.0",
        .base_path = "/api/v2",
        .servers = &.{.{ .url = "https://{host}/api/v2", .description = "One host.", .variable = "host", .default = "a.example", .values = &.{ "a.example", "b.example" } }},
        .tags = &.{"things"},
        .security_schemes = &.{
            .{ .name = "userToken", .bearer_format = "token", .description = "A user token." },
            .{ .name = "otherToken", .bearer_format = "token", .description = "Two\nlines." },
        },
        .headers = &.{
            .{ .name = "RequestId", .wire = "x-request-id", .description = "The request.", .required = true, .type = "string", .min_length = 1, .on_success = true },
            .{ .name = "RetryAfter", .wire = "retry-after", .description = "Seconds.", .required = false, .type = "integer", .minimum = 0, .on_success = false },
        },
        .error_response = "Any error.",
        .messages = &fixture_messages,
        .enums = &fixture_enums,
        .order = &fixture_order,
        .rpcs = &fixture_rpcs,
        .sources_sha256 = "abc123",
    };
}

const expected_sample =
    \\# Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto (sources sha256 abc123); do not edit, run 'zig build gen-api'.
    \\openapi: "3.1.0"
    \\info:
    \\  title: "Things"
    \\  version: "1.0.0"
    \\  summary: "A tiny API."
    \\  description: |
    \\    The things API.
    \\
    \\    - one
    \\    - two
    \\  license:
    \\    name: "Apache-2.0"
    \\    identifier: "Apache-2.0"
    \\servers:
    \\  - url: "https://{host}/api/v2"
    \\    description: "One host."
    \\    variables:
    \\      host:
    \\        default: "a.example"
    \\        enum:
    \\          - "a.example"
    \\          - "b.example"
    \\tags:
    \\  - name: "things"
    \\security: []
    \\paths:
    \\  /things/{namespace}:
    \\    get:
    \\      operationId: "getThing"
    \\      tags:
    \\        - "things"
    \\      summary: "Get a thing."
    \\      description: |
    \\        Gets a thing.
    \\
    \\        Second paragraph.
    \\      security:
    \\        - userToken: []
    \\        - otherToken: []
    \\      parameters:
    \\        - $ref: "#/components/parameters/Namespace"
    \\        - $ref: "#/components/parameters/Sort"
    \\        - $ref: "#/components/parameters/Limit"
    \\      responses:
    \\        "200":
    \\          description: "The thing."
    \\          headers:
    \\            x-request-id:
    \\              $ref: "#/components/headers/RequestId"
    \\          content:
    \\            application/json:
    \\              schema:
    \\                $ref: "#/components/schemas/Thing"
    \\        "404":
    \\          description: "Not here."
    \\          headers:
    \\            x-request-id:
    \\              $ref: "#/components/headers/RequestId"
    \\          content:
    \\            application/json:
    \\              schema:
    \\                $ref: "#/components/schemas/Error"
    \\        default:
    \\          $ref: "#/components/responses/Error"
    \\    put:
    \\      operationId: "putThing"
    \\      tags:
    \\        - "things"
    \\      summary: "Store a thing."
    \\      security: []
    \\      parameters:
    \\        - $ref: "#/components/parameters/Namespace"
    \\      requestBody:
    \\        required: true
    \\        content:
    \\          application/json:
    \\            schema:
    \\              $ref: "#/components/schemas/Thing"
    \\      responses:
    \\        "204":
    \\          description: "Stored."
    \\          headers:
    \\            x-request-id:
    \\              $ref: "#/components/headers/RequestId"
    \\        default:
    \\          $ref: "#/components/responses/Error"
    \\components:
    \\  securitySchemes:
    \\    userToken:
    \\      type: "http"
    \\      scheme: "bearer"
    \\      bearerFormat: "token"
    \\      description: "A user token."
    \\    otherToken:
    \\      type: "http"
    \\      scheme: "bearer"
    \\      bearerFormat: "token"
    \\      description: |
    \\        Two
    \\        lines.
    \\  headers:
    \\    RequestId:
    \\      description: "The request."
    \\      required: true
    \\      schema:
    \\        type: "string"
    \\        minLength: 1
    \\    RetryAfter:
    \\      description: "Seconds."
    \\      schema:
    \\        type: "integer"
    \\        minimum: 0
    \\  responses:
    \\    Error:
    \\      description: "Any error."
    \\      headers:
    \\        x-request-id:
    \\          $ref: "#/components/headers/RequestId"
    \\        retry-after:
    \\          $ref: "#/components/headers/RetryAfter"
    \\      content:
    \\        application/json:
    \\          schema:
    \\            $ref: "#/components/schemas/Error"
    \\  parameters:
    \\    Namespace:
    \\      name: "namespace"
    \\      in: "path"
    \\      required: true
    \\      description: "The namespace."
    \\      schema:
    \\        $ref: "#/components/schemas/Namespace"
    \\    Sort:
    \\      name: "sort"
    \\      in: "query"
    \\      required: false
    \\      schema:
    \\        $ref: "#/components/schemas/Sort"
    \\        default: "name"
    \\    Limit:
    \\      name: "limit"
    \\      in: "query"
    \\      required: false
    \\      schema:
    \\        type: "integer"
    \\        minimum: 1
    \\        maximum: 100
    \\        default: 20
    \\  schemas:
    \\    Namespace:
    \\      description: |
    \\        A namespace.
    \\        Lowercase only.
    \\      type: "string"
    \\      pattern: "^[a-z]+$"
    \\      minLength: 1
    \\      maxLength: 39
    \\    Error:
    \\      description: "An error."
    \\      type: "object"
    \\      required:
    \\        - "code"
    \\        - "message"
    \\      properties:
    \\        code:
    \\          $ref: "#/components/schemas/ErrorCode"
    \\        message:
    \\          description: "Text for people."
    \\          type: "string"
    \\    ErrorCode:
    \\      type: "string"
    \\      enum:
    \\        - "bad_thing"
    \\        - "gone"
    \\    Thing:
    \\      description: "A thing."
    \\      type: "object"
    \\      required:
    \\        - "namespace"
    \\      oneOf:
    \\        - required:
    \\            - "namespace"
    \\      properties:
    \\        namespace:
    \\          $ref: "#/components/schemas/Namespace"
    \\        size:
    \\          description: "How big."
    \\          type: "integer"
    \\          minimum: 1
    \\          default: 20
    \\        tags:
    \\          type: "array"
    \\          maxItems: 3
    \\          uniqueItems: true
    \\          items:
    \\            type: "string"
    \\            minLength: 1
    \\        note:
    \\          description: |
    \\            A note.
    \\            Two lines.
    \\          type:
    \\            - "string"
    \\            - "null"
    \\        kind:
    \\          description: "The kind."
    \\          type: "string"
    \\          enum:
    \\            - "a"
    \\            - "b"
    \\        parent:
    \\          oneOf:
    \\            - $ref: "#/components/schemas/Namespace"
    \\            - type: "null"
    \\        labels:
    \\          type: "object"
    \\          additionalProperties:
    \\            type: "string"
    \\        choice:
    \\          $ref: "#/components/schemas/Choice"
    \\        flag:
    \\          type: "boolean"
    \\          default: true
    \\        extra:
    \\          description: "Inline."
    \\          type: "object"
    \\          required:
    \\            - "n"
    \\          properties:
    \\            n:
    \\              type: "integer"
    \\      if:
    \\        properties:
    \\          kind:
    \\            const: "b"
    \\      then:
    \\        required:
    \\          - "note"
    \\    Choice:
    \\      oneOf:
    \\        - type: "array"
    \\          minItems: 1
    \\          items:
    \\            $ref: "#/components/schemas/Namespace"
    \\        - type: "string"
    \\          const: "all"
    \\    Sort:
    \\      description: "Sort order."
    \\      type: "string"
    \\      enum:
    \\        - "name"
    \\        - "last-updated"
    \\x-mopm-errors:
    \\  bad_thing:
    \\    status: 400
    \\    message: "Bad \"{x}\"."
    \\    hint: |
    \\      Fix it.
    \\      Then retry.
    \\  gone:
    \\    status: 410
    \\    message: "Gone."
    \\    hint: ""
    \\x-mopm-error-reasons:
    \\  bad_thing:
    \\    - "a"
    \\    - "b"
    \\
;

fn writeOk(arena: Allocator, api: model.Api) ![]const u8 {
    return switch (try write(arena, api)) {
        .ok => |t| t,
        .bad => |m| {
            std.debug.print("unexpected refusal: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectBad(api: model.Api, want: []const u8) !void {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    switch (try write(state.allocator(), api)) {
        .ok => return error.TestUnexpectedResult,
        .bad => |m| try std.testing.expectEqualStrings(want, m),
    }
}

test "a small API is written as the exact YAML" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const got = try writeOk(state.allocator(), sample());
    try std.testing.expectEqualStrings(expected_sample, got);
}

test "the output has no tabs, no trailing spaces and ends with one newline" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const got = try writeOk(state.allocator(), sample());
    try std.testing.expect(std.mem.indexOfScalar(u8, got, '\t') == null);
    try std.testing.expect(std.mem.indexOf(u8, got, " \n") == null);
    try std.testing.expect(got[got.len - 1] == '\n' and got[got.len - 2] != '\n');
}

test "keys that are not plain are quoted, strings are escaped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var out = std.ArrayList(u8).init(state.allocator());
    try Writer.quote(&out, "a\"b\\c\n\r\t\x01\x7f é");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\\u0001\\u007f é\"", out.items);
    try std.testing.expect(Writer.plainKey("x-mopm-errors"));
    try std.testing.expect(Writer.plainKey("/a/{b}/c.d"));
    try std.testing.expect(Writer.plainKey("$ref"));
    try std.testing.expect(!Writer.plainKey("200"));
    try std.testing.expect(!Writer.plainKey(""));
    try std.testing.expect(!Writer.plainKey("a b"));
    try std.testing.expect(!Writer.plainKey("-a"));
}

test "an API with nothing optional is written with empty lists and maps" {
    var api = sample();
    api.servers = &.{};
    api.summary = "";
    api.doc = "";
    api.rpcs = &.{};
    api.headers = &.{};
    api.security_schemes = &.{};
    api.order = &.{.{ .message = 1 }};
    api.messages = &.{ fixture_messages[0], fixture_messages[1] };
    api.enums = &.{fixture_enums[0]};
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const got = try writeOk(state.allocator(), api);
    const want =
        \\# Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto (sources sha256 abc123); do not edit, run 'zig build gen-api'.
        \\openapi: "3.1.0"
        \\info:
        \\  title: "Things"
        \\  version: "1.0.0"
        \\  license:
        \\    name: "Apache-2.0"
        \\    identifier: "Apache-2.0"
        \\tags:
        \\  - name: "things"
        \\security: []
        \\paths: {}
        \\components:
        \\  securitySchemes: {}
        \\  headers: {}
        \\  responses:
        \\    Error:
        \\      description: "Any error."
        \\      content:
        \\        application/json:
        \\          schema:
        \\            $ref: "#/components/schemas/Error"
        \\  parameters: {}
        \\  schemas:
        \\    Error:
        \\      description: "An error."
        \\      type: "object"
        \\      required:
        \\        - "code"
        \\        - "message"
        \\      properties:
        \\        code:
        \\          $ref: "#/components/schemas/ErrorCode"
        \\        message:
        \\          description: "Text for people."
        \\          type: "string"
        \\x-mopm-errors:
        \\  bad_thing:
        \\    status: 400
        \\    message: "Bad \"{x}\"."
        \\    hint: |
        \\      Fix it.
        \\      Then retry.
        \\  gone:
        \\    status: 410
        \\    message: "Gone."
        \\    hint: ""
        \\x-mopm-error-reasons:
        \\  bad_thing:
        \\    - "a"
        \\    - "b"
        \\
    ;
    try std.testing.expectEqualStrings(want, got);
}

test "a nullable union, enum and map get a null alternative or type" {
    const fields = [_]model.Field{
        .{ .name = "u", .number = 1, .doc = "", .label = .single, .type = .{ .message = 4 }, .rules = .{ .nullable = true } },
        .{ .name = "k", .number = 2, .doc = "", .label = .single, .type = .{ .enumeration = 1 }, .rules = .{ .nullable = true } },
        .{ .name = "m", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .string }, .map = true, .rules = .{ .nullable = true, .items = &.{ .pattern = "^x$" } } },
        .{ .name = "r", .number = 4, .doc = "", .label = .repeated, .type = .{ .scalar = .int64 }, .rules = .{ .nullable = true, .items = &.{ .nullable = true, .minimum = 0 } } },
    };
    var msgs = fixture_messages;
    msgs[2].fields = &fields;
    msgs[2].one_of = &.{};
    msgs[2].when = null;
    msgs[4].parent = 2;
    var api = sample();
    api.messages = &msgs;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const got = try writeOk(state.allocator(), api);
    const want =
        \\    Thing:
        \\      description: "A thing."
        \\      type: "object"
        \\      properties:
        \\        u:
        \\          oneOf:
        \\            - type: "array"
        \\              minItems: 1
        \\              items:
        \\                $ref: "#/components/schemas/Namespace"
        \\            - type: "string"
        \\              const: "all"
        \\            - type: "null"
        \\        k:
        \\          description: "The kind."
        \\          type:
        \\            - "string"
        \\            - "null"
        \\          enum:
        \\            - "a"
        \\            - "b"
        \\        m:
        \\          type:
        \\            - "object"
        \\            - "null"
        \\          additionalProperties:
        \\            type: "string"
        \\            pattern: "^x$"
        \\        r:
        \\          type:
        \\            - "array"
        \\            - "null"
        \\          items:
        \\            type:
        \\              - "integer"
        \\              - "null"
        \\            minimum: 0
        \\    Choice:
        \\
    ;
    const start = std.mem.indexOf(u8, got, "    Thing:\n") orelse return error.TestUnexpectedResult;
    const end = (std.mem.indexOf(u8, got, "    Choice:\n") orelse return error.TestUnexpectedResult) + "    Choice:\n".len;
    try std.testing.expectEqualStrings(want, got[start..end]);
}

test "a keyword on a nested wrapper replaces the wrapper's own" {
    const fields = [_]model.Field{
        .{ .name = "ns", .number = 1, .doc = "Mine.", .label = .single, .type = .{ .message = 5 }, .rules = .{ .max_length = 5 } },
    };
    var msgs = fixture_messages;
    msgs[2].fields = &fields;
    msgs[2].one_of = &.{};
    msgs[2].when = null;
    // Choice.Names as a plain wrapper of a string with its own max_length.
    msgs[5].fields = &.{.{ .name = "value", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .max_length = 9 } }};
    var api = sample();
    api.messages = &msgs;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const got = try writeOk(state.allocator(), api);
    try std.testing.expect(std.mem.indexOf(u8, got,
        \\        ns:
        \\          description: "Mine."
        \\          type: "string"
        \\          maxLength: 5
        \\
    ) != null);
}

test "refuses a parameter that two rpcs define differently" {
    var msgs = fixture_messages;
    msgs[7].fields = &.{
        .{ .name = "namespace", .number = 1, .doc = "Another text.", .label = .single, .type = .{ .message = 0 }, .rules = .{ .param = "Namespace" } },
        .{ .name = "body", .number = 2, .doc = "", .label = .single, .type = .{ .message = 2 } },
    };
    var api = sample();
    api.messages = &msgs;
    try expectBad(api, "rpc PutThing parameter namespace: the parameter 'Namespace' is defined differently by rpc GetThing");
}

test "refuses a path or query field without a param option" {
    var msgs = fixture_messages;
    msgs[6].fields = &.{.{ .name = "namespace", .number = 1, .doc = "", .label = .single, .type = .{ .message = 0 } }};
    var api = sample();
    api.messages = &msgs;
    try expectBad(api, "rpc GetThing: the path parameter 'namespace' has no param option");
}

test "refuses a description a literal block cannot hold" {
    var api = sample();
    api.doc = "Starts fine.\n  indented is fine\nok";
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    _ = try writeOk(state.allocator(), api);

    api.doc = " leading\nsecond";
    try expectBad(api, "the text \" leading\" cannot be written as a literal block: its first line starts with a space");
    api.doc = "\nsecond";
    try expectBad(api, "the text \"\" cannot be written as a literal block: its first line is empty");
    api.doc = "first\nsecond\n";
    try expectBad(api, "the text \"first\" cannot be written as a literal block: it ends with a newline");
    api.doc = "first\n\tsecond";
    try expectBad(api, "the text \"first\" cannot be written as a literal block: it holds a tab or a carriage return");
    api.doc = "first\n   \nsecond";
    try expectBad(api, "the text \"first\" cannot be written as a literal block: a line of it is only spaces");
    api.doc = " a very long first line that goes beyond forty characters in all\nsecond";
    try expectBad(api, "the text \" a very long first line that goes beyond\" cannot be written as a literal block: its first line starts with a space");
}

test "refuses a text with several lines in a list" {
    var api = sample();
    api.servers = &.{.{ .url = "u", .description = "", .variable = "host", .default = "d", .values = &.{"a\nb"} }};
    try expectBad(api, "the text \"a\" is in a list and has several lines");
}

test "refuses what is not a document of the contract" {
    var api = sample();
    api.base_path = "/other";
    try expectBad(api, "rpc GetThing: the path '/api/v2/things/{namespace}' does not start with the base path '/other/'");

    api = sample();
    api.tags = &.{};
    try expectBad(api, "rpc GetThing: the tag 'things' is not one of the API's tags");

    api = sample();
    api.security_schemes = &.{};
    try expectBad(api, "rpc GetThing: the security scheme 'userToken' is not declared");

    api = sample();
    api.rpcs = &.{ fixture_rpcs[0], fixture_rpcs[0] };
    try expectBad(api, "rpc GetThing: the operationId 'getThing' is used twice");

    var twin = fixture_rpcs[0];
    twin.name = "GetThingAgain";
    api.rpcs = &.{ fixture_rpcs[0], twin };
    try expectBad(api, "rpc GetThingAgain: the path '/things/{namespace}' has two get operations");

    var bad = fixture_rpcs[0];
    bad.path = "/api/v2/things/{nope}";
    api.rpcs = &.{bad};
    try expectBad(api, "rpc GetThing: a path parameter of '/api/v2/things/{nope}' is not a field of the input");

    bad = fixture_rpcs[0];
    bad.path = "/api/v2";
    api.rpcs = &.{bad};
    try expectBad(api, "rpc GetThing: the path '/api/v2' does not start with the base path '/api/v2/'");

    api = sample();
    api.enums = &.{ fixture_enums[1], fixture_enums[2] };
    api.order = &.{};
    api.rpcs = &.{};
    try expectBad(api, "there is no enum named ErrorCode");

    api = sample();
    var values = fixture_error_values;
    values[2].err = null;
    var enums = fixture_enums;
    enums[0].values = &values;
    api.enums = &enums;
    try expectBad(api, "the ErrorCode value ERROR_CODE_GONE has no error option");
}

test "refuses a body, an output or an Error that cannot be written" {
    var api = sample();
    var msgs7 = fixture_messages;
    msgs7[7].fields = msgs7[7].fields[0..1];
    api.messages = &msgs7;
    var rpc = fixture_rpcs[1];
    rpc.body = "nothing";
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc PutThing: the body 'nothing' is not a field of PutThingParams");

    rpc = fixture_rpcs[1];
    rpc.input = .empty;
    rpc.path = "/api/v2/things";
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc PutThing: the body 'body' is a field of no input");

    rpc = fixture_rpcs[0];
    rpc.output = .{ .message = 3 };
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc GetThing: the response is the nested message Thing.Extra");

    rpc.output = .{ .message = 6 };
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc GetThing: the response GetThingParams is also the input of an rpc");

    rpc.output = .{ .scalar = .string };
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc GetThing: the response is not a message");

    rpc = fixture_rpcs[0];
    var msgs = fixture_messages;
    msgs[1].name = "Err";
    msgs[1].path = "Err";
    api.messages = &msgs;
    api.rpcs = &.{rpc};
    try expectBad(api, "rpc GetThing: an rpc answers with an Error but there is no message named Error");
}

test "refuses a field that cannot be written" {
    var api = sample();
    var msgs = fixture_messages;
    api.messages = &msgs;
    msgs[2].one_of = &.{};
    msgs[2].when = null;

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .repeated, .type = .{ .scalar = .string }, .rules = .{ .pattern = "p" } }};
    try expectBad(api, "Thing.x: a repeated field has no string or number keywords of its own; those of its items are in items");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .map = true, .rules = .{ .max_items = 1 } }};
    try expectBad(api, "Thing.x: a map has no keywords of its own; those of its values are in items");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .unique_items = true } }};
    try expectBad(api, "Thing.x: a field that is not repeated has no min_items, max_items, unique_items or items");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .repeated, .type = .{ .scalar = .string }, .rules = .{ .items = &.{ .max_items = 2 } } }};
    try expectBad(api, "Thing.x: min_items, max_items, unique_items and items apply to a repeated field only");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .empty }};
    try expectBad(api, "Thing.x: google.protobuf.Empty is not the type of a field");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .message = 6 } }};
    try expectBad(api, "Thing.x: GetThingParams is the input of an rpc, not a schema");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .int64 }, .rules = .{ .default = "twenty" } }};
    try expectBad(api, "Thing.x: 'twenty' is not an integer");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .bool }, .rules = .{ .@"const" = "yes" } }};
    try expectBad(api, "Thing.x: 'yes' is not true or false");

    msgs[2].fields = &.{.{ .name = "x", .number = 1, .doc = "", .label = .single, .type = .{ .message = 3 }, .rules = .{ .nullable = true } }};
    msgs[3].fields = &.{};
    msgs[3].is_union = true;
    msgs[3].wrapper = true;
    try expectBad(api, "Thing.Extra: a message cannot be both a wrapper and a union");

    msgs[3].is_union = false;
    try expectBad(api, "Thing.Extra: a wrapper has exactly one field, named value");
}

test "refuses a message whose schema names fields that are not there" {
    var api = sample();
    var msgs = fixture_messages;
    api.messages = &msgs;

    msgs[2].one_of = &.{.{ .required = &.{"nope"} }};
    try expectBad(api, "Thing: 'nope' is not a field");

    msgs[2].one_of = &.{};
    msgs[2].when = .{ .field = "nope", .equals = "b", .required = &.{} };
    try expectBad(api, "Thing: 'nope' is not a field");

    msgs[2].when = .{ .field = "kind", .equals = "b", .required = &.{"nope"} };
    try expectBad(api, "Thing: 'nope' is not a field");
}

test "refuses nested messages that contain themselves" {
    var api = sample();
    var msgs = fixture_messages;
    api.messages = &msgs;
    msgs[3].fields = &.{.{ .name = "again", .number = 1, .doc = "", .label = .single, .type = .{ .message = 3 } }};
    try expectBad(api, "Thing.Extra: nested messages refer to each other without end");
}

test "a nullable schema that has nothing to make nullable is refused" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var w = Writer{ .arena = state.allocator(), .api = sample() };
    var e = Entries.init(state.allocator());
    try std.testing.expectError(error.Invalid, w.makeNullable(&e));
    try std.testing.expectEqualStrings("a nullable field has no type", w.msg);
    // A `type` that is already a list is left as it is.
    try Writer.add(&e, "type", .{ .seq = &.{} });
    try w.makeNullable(&e);
}
