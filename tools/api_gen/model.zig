//! What tools/api_gen.zig knows of the registry API after reading its protos (spec/api/mopm/registry/v2/*.proto): the
//! messages, enums and the one service, with the options of spec/api/mopm/registry/v2/options.proto resolved. The parser
//! (proto.zig) fills it; the writers (openapi.zig, typescript.zig, zig_client.zig) only read it. Every slice is owned by the
//! arena the parser was given.
//!
//! Names: a message or enum has its simple `name` and its `path`, the names from the top level down joined with `.`
//! (`MeV2.Namespace`), unique in the API. A field's type refers to a declaration by that path, resolved by the parser.

const std = @import("std");

/// The leading comment of a declaration: its lines without `//` and the one space after it, joined with `\n`, with no
/// trailing newline. Empty when there is none.
pub const Doc = []const u8;

pub const Scalar = enum {
    string,
    bool,
    int32,
    int64,
    uint32,
    uint64,

    pub fn isInteger(s: Scalar) bool {
        return s != .string and s != .bool;
    }
};

/// The type of a field, or of a map's value.
pub const Type = union(enum) {
    scalar: Scalar,
    /// A message, by index into `Api.messages`.
    message: usize,
    /// An enum, by index into `Api.enums`.
    enumeration: usize,
    /// google.protobuf.Empty (only as an rpc's input or output).
    empty,
};

pub const Label = enum { single, optional, repeated };

/// The `(field)` option (options.proto `Field`): every keyword that was set; null or false when it was not.
pub const Rules = struct {
    required: bool = false,
    nullable: bool = false,
    param: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    min_length: ?u64 = null,
    max_length: ?u64 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    format: ?[]const u8 = null,
    min_items: ?u64 = null,
    max_items: ?u64 = null,
    unique_items: bool = false,
    /// As written in the option: text the field's type reads (`name`, `20`, `true`); a writer types it by the field.
    default: ?[]const u8 = null,
    /// As `default`.
    @"const": ?[]const u8 = null,
    items: ?*const Rules = null,
};

pub const Field = struct {
    name: []const u8,
    number: u32,
    doc: Doc,
    label: Label,
    type: Type,
    /// For a `map<string, V>` field: `type` is V and this is true (proto3 maps have string keys here).
    map: bool = false,
    /// The name of the `oneof` the field is a member of, if any.
    oneof: ?[]const u8 = null,
    rules: Rules = .{},
};

pub const RequiredSet = struct { required: []const []const u8 };

pub const Condition = struct {
    field: []const u8,
    /// As `Rules.default`: text the field's type reads.
    equals: []const u8,
    required: []const []const u8,
};

pub const Message = struct {
    name: []const u8,
    /// `Outer.Inner`; equal to `name` at the top level.
    path: []const u8,
    doc: Doc,
    /// The message this one is nested in (index into `Api.messages`), or null at the top level.
    parent: ?usize,
    fields: []const Field,
    /// The `(schema)` option.
    wrapper: bool = false,
    is_union: bool = false,
    one_of: []const RequiredSet = &.{},
    when: ?Condition = null,
    /// The file it was declared in (relative to the proto root, `mopm/registry/v2/types.proto`).
    file: []const u8,

    pub fn topLevel(m: Message) bool {
        return m.parent == null;
    }

    pub fn field(m: Message, name: []const u8) ?Field {
        for (m.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

pub const ErrorEntry = struct {
    status: u16,
    message: []const u8,
    hint: []const u8,
    reasons: []const []const u8 = &.{},
};

pub const EnumValue = struct {
    name: []const u8,
    number: i32,
    doc: Doc,
    /// The `(json)` option, when given.
    json_option: ?[]const u8 = null,
    /// The `(error)` option, when given.
    err: ?ErrorEntry = null,
};

pub const Enum = struct {
    name: []const u8,
    path: []const u8,
    doc: Doc,
    /// The message it is nested in, or null at the top level.
    parent: ?usize,
    values: []const EnumValue,
    file: []const u8,

    pub fn topLevel(e: Enum) bool {
        return e.parent == null;
    }
};

pub const Method = enum { GET, PUT, POST, DELETE, PATCH };

pub const Response = struct {
    status: u16,
    description: []const u8,
    /// An `Error` answer the operation names besides `default`.
    is_error: bool = false,
};

pub const Rpc = struct {
    /// `GetHealth`; the operationId is `getHealth` (`operationId`).
    name: []const u8,
    doc: Doc,
    input: Type,
    output: Type,
    method: Method,
    /// The google.api.http path, from the root (`/api/v2/packages/{namespace}/{name}`).
    path: []const u8,
    /// The google.api.http `body`: the name of the input's field that is the JSON body, or null for no body.
    body: ?[]const u8,
    tags: []const []const u8,
    summary: []const u8,
    security: []const []const u8,
    responses: []const Response,
};

pub const Server = struct {
    url: []const u8,
    description: []const u8,
    variable: []const u8,
    default: []const u8,
    values: []const []const u8,
};

pub const SecurityScheme = struct {
    name: []const u8,
    bearer_format: []const u8,
    description: []const u8,
};

pub const Header = struct {
    name: []const u8,
    wire: []const u8,
    description: []const u8,
    required: bool,
    type: []const u8,
    min_length: ?u64 = null,
    minimum: ?i64 = null,
    on_success: bool,
};

pub const Decl = union(enum) { message: usize, enumeration: usize };

pub const Api = struct {
    /// The proto package (`mopm.registry.v2`).
    package: []const u8,
    service: []const u8,
    /// The service's leading comment: `info.description`.
    doc: Doc,
    title: []const u8,
    version: []const u8,
    summary: []const u8,
    license_name: []const u8,
    license_identifier: []const u8,
    base_path: []const u8,
    servers: []const Server,
    tags: []const []const u8,
    security_schemes: []const SecurityScheme,
    headers: []const Header,
    error_response: []const u8,
    /// Every message, top-level and nested, in declaration order (a nested one after its parent), files in the order read.
    messages: []const Message,
    enums: []const Enum,
    /// The top-level messages and enums in declaration order, files in the order read (the order of `components/schemas`).
    order: []const Decl,
    rpcs: []const Rpc,
    /// The sha256, in lowercase hex, of the proto files read, in the order read: each file's path (relative to the proto
    /// root), a NUL byte, its bytes, a NUL byte. The writers put it in their header, so a reader can tell the output is current.
    sources_sha256: []const u8,

    pub fn messageByPath(api: Api, path: []const u8) ?usize {
        for (api.messages, 0..) |m, i| if (std.mem.eql(u8, m.path, path)) return i;
        return null;
    }

    pub fn enumByPath(api: Api, path: []const u8) ?usize {
        for (api.enums, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) return i;
        return null;
    }

    /// The ErrorCode enum: the top-level enum named `ErrorCode`.
    pub fn errorCodes(api: Api) ?Enum {
        for (api.enums) |e| if (e.parent == null and std.mem.eql(u8, e.name, "ErrorCode")) return e;
        return null;
    }
};

/// `getHealth` for `GetHealth`.
pub fn operationId(arena: std.mem.Allocator, rpc_name: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, rpc_name);
    if (out.len > 0) out[0] = std.ascii.toLower(out[0]);
    return out;
}

/// `VERSION_STATE` for `VersionState`, `API_VERSION` for `ApiVersion`, `ME_V2` for `MeV2`: the prefix of an enum's values.
pub fn upperSnake(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (name, 0..) |c, i| {
        if (i > 0 and std.ascii.isUpper(c) and !std.ascii.isUpper(name[i - 1])) try out.append('_');
        try out.append(std.ascii.toUpper(c));
    }
    return out.toOwnedSlice();
}

/// The JSON string of an enum value (options.proto, "An enum value is ..."); null for the zero value `<PREFIX>_UNSPECIFIED`,
/// which is not part of the contract. A value whose name does not start with the prefix and has no `json` option is an
/// error, which the parser reports with the file and line; here it gives the name in lower case.
pub fn jsonValue(arena: std.mem.Allocator, e: Enum, v: EnumValue) std.mem.Allocator.Error!?[]const u8 {
    if (v.json_option) |j| return j;
    const prefix = try upperSnake(arena, e.name);
    var rest: []const u8 = v.name;
    if (std.mem.startsWith(u8, v.name, prefix) and v.name.len > prefix.len and v.name[prefix.len] == '_') rest = v.name[prefix.len + 1 ..];
    if (v.number == 0 and std.mem.eql(u8, rest, "UNSPECIFIED")) return null;
    return try std.ascii.allocLowerString(arena, rest);
}

/// The JSON strings of an enum's values, in order, without the zero value.
pub fn jsonValues(arena: std.mem.Allocator, e: Enum) std.mem.Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for (e.values) |v| if (try jsonValue(arena, e, v)) |j| try out.append(j);
    return out.toOwnedSlice();
}

/// The fields of an rpc's input that are path parameters, in the order the path names them.
pub fn pathParams(arena: std.mem.Allocator, api: Api, rpc: Rpc) std.mem.Allocator.Error![]const Field {
    var out = std.ArrayList(Field).init(arena);
    const input = switch (rpc.input) {
        .message => |i| api.messages[i],
        else => return out.toOwnedSlice(),
    };
    var it = std.mem.splitScalar(u8, rpc.path, '/');
    while (it.next()) |seg| {
        if (seg.len > 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
            if (input.field(seg[1 .. seg.len - 1])) |f| try out.append(f);
        }
    }
    return out.toOwnedSlice();
}

/// The fields of an rpc's input that are query parameters: neither in the path nor the body, in declaration order.
pub fn queryParams(arena: std.mem.Allocator, api: Api, rpc: Rpc) std.mem.Allocator.Error![]const Field {
    var out = std.ArrayList(Field).init(arena);
    const input = switch (rpc.input) {
        .message => |i| api.messages[i],
        else => return out.toOwnedSlice(),
    };
    for (input.fields) |f| {
        if (rpc.body) |b| if (std.mem.eql(u8, b, f.name)) continue;
        const braced = try std.fmt.allocPrint(arena, "{{{s}}}", .{f.name});
        if (std.mem.indexOf(u8, rpc.path, braced) != null) continue;
        try out.append(f);
    }
    return out.toOwnedSlice();
}

/// The body field's type, or null when the rpc takes no body.
pub fn bodyType(api: Api, rpc: Rpc) ?Type {
    const b = rpc.body orelse return null;
    const input = switch (rpc.input) {
        .message => |i| api.messages[i],
        else => return null,
    };
    const f = input.field(b) orelse return null;
    return f.type;
}

/// `rpc.path` without `api.base_path` (`/packages/{namespace}/{name}`).
pub fn relativePath(api: Api, rpc: Rpc) []const u8 {
    if (std.mem.startsWith(u8, rpc.path, api.base_path)) return rpc.path[api.base_path.len..];
    return rpc.path;
}

test "enum prefixes and JSON values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("VERSION_STATE", try upperSnake(a, "VersionState"));
    try std.testing.expectEqualStrings("API_VERSION", try upperSnake(a, "ApiVersion"));
    try std.testing.expectEqualStrings("ME_V2", try upperSnake(a, "MeV2"));
    const values = [_]EnumValue{
        .{ .name = "SUBDIR_UNSPECIFIED", .number = 0, .doc = "" },
        .{ .name = "SUBDIR_LINUX_64", .number = 1, .doc = "", .json_option = "linux-64" },
        .{ .name = "SUBDIR_NOARCH", .number = 2, .doc = "" },
    };
    const e = Enum{ .name = "Subdir", .path = "Subdir", .doc = "", .parent = null, .values = &values, .file = "t.proto" };
    const got = try jsonValues(a, e);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("linux-64", got[0]);
    try std.testing.expectEqualStrings("noarch", got[1]);
    try std.testing.expectEqualStrings("getHealth", try operationId(a, "GetHealth"));
}
