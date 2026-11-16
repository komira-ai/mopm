//! The reader of the registry API's protos (spec/api/mopm/registry/v2/*.proto): the subset of proto3 and of the options of
//! options.proto that the registry uses, turned into a `model.Api`. Anything outside the subset is refused with a message
//! that names the file, the line and what is wrong (`mopm/registry/v2/types.proto:12: unknown type 'Nmae'`).
//!
//! `parse` reads the files in the order given (options.proto is not among them: the option names are known here), then
//! resolves every type by proto's scoping and checks what the options promise (a wrapper has one field `value`, a union one
//! oneof, a path parameter is a field of the input, ...). `imports` lists a file's imports so the caller can order the files.

const std = @import("std");
const model = @import("model.zig");
const parser = @import("proto_parser.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Source = struct {
    /// Relative to the proto root (`spec/api`): `mopm/registry/v2/types.proto`.
    path: []const u8,
    text: []const u8,
};

pub const Result = union(enum) {
    ok: model.Api,
    /// The refusal, `<file>:<line>: <what is wrong>`; owned by the arena given to `parse`.
    bad: []const u8,
};

/// Reads `sources` (in this order) into the model. A refusal is a `bad` result, not an error; only running out of memory is.
pub fn parse(arena: Allocator, sources: []const Source) Allocator.Error!Result {
    var b = Builder.init(arena);
    if (b.run(sources)) |api| {
        return .{ .ok = api };
    } else |err| switch (err) {
        error.Bad => return .{ .bad = b.bad.? },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

/// The paths a file imports, in order (`import public` and `import weak` included). A file that cannot be read as tokens gives
/// the empty list: `parse` reports why.
pub fn imports(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var b = Builder.init(arena);
    const toks = tokenize(&b, "", text) catch |err| switch (err) {
        error.Bad => return &.{},
        error.OutOfMemory => return error.OutOfMemory,
    };
    var out = std.ArrayList([]const u8).init(arena);
    var depth: usize = 0;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.kind == .sym and t.text[0] == '{') depth += 1;
        if (t.kind == .sym and t.text[0] == '}' and depth > 0) depth -= 1;
        if (depth != 0 or t.kind != .ident or !std.mem.eql(u8, t.text, "import")) continue;
        var j = i + 1;
        if (j < toks.len and toks[j].kind == .ident) j += 1;
        if (j < toks.len and toks[j].kind == .str) try out.append(toks[j].text);
    }
    return out.items;
}

pub const Error = error{Bad} || Allocator.Error;

pub const pkg_prefix = "mopm.registry.v2.";

// ---------------------------------------------------------------------------------------------------------------- tokens

const Kind = enum { ident, int, str, sym, eof };

pub const Token = struct {
    kind: Kind,
    /// The identifier, the symbol, or the decoded string.
    text: []const u8,
    int: i64 = 0,
    line: u32,
    /// The comment lines directly above the token (no blank line between), as the model's `Doc`.
    doc: []const u8 = "",
};

pub fn tokenize(b: *Builder, path: []const u8, text: []const u8) Error![]const Token {
    var toks = std.ArrayList(Token).init(b.arena);
    var pending = std.ArrayList([]const u8).init(b.arena);
    var last_comment: u32 = 0;
    var line: u32 = 1;
    var i: usize = 0;
    var tok_on_line = false;
    var content_on_line = false;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            if (!content_on_line) pending.clearRetainingCapacity();
            line += 1;
            i += 1;
            tok_on_line = false;
            content_on_line = false;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '/') {
            if (i + 1 < text.len and text[i + 1] == '/') {
                var end = i + 2;
                while (end < text.len and text[end] != '\n') end += 1;
                var body = text[i + 2 .. end];
                if (body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
                if (body.len > 0 and body[0] == ' ') body = body[1..];
                if (!tok_on_line) {
                    try pending.append(body);
                    last_comment = line;
                }
                content_on_line = true;
                i = end;
                continue;
            }
            if (i + 1 < text.len and text[i + 1] == '*') return b.fail(path, line, "block comments (/* */) are not supported", .{});
            return b.fail(path, line, "unexpected character '/'", .{});
        }
        content_on_line = true;
        const doc = if (pending.items.len > 0 and last_comment + 1 == line) try std.mem.join(b.arena, "\n", pending.items) else "";
        pending.clearRetainingCapacity();
        tok_on_line = true;
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = i;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            try toks.append(.{ .kind = .ident, .text = text[i..end], .line = line, .doc = doc });
            i = end;
        } else if (std.ascii.isDigit(c) or (c == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            var end = i + 1;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            const n = std.fmt.parseInt(i64, text[i..end], 10) catch return b.fail(path, line, "integer '{s}' is out of range", .{text[i..end]});
            try toks.append(.{ .kind = .int, .text = text[i..end], .int = n, .line = line, .doc = doc });
            i = end;
        } else if (c == '"' or c == '\'') {
            var buf = std.ArrayList(u8).init(b.arena);
            i += 1;
            while (true) {
                if (i >= text.len or text[i] == '\n') return b.fail(path, line, "unterminated string", .{});
                const d = text[i];
                if (d == c) {
                    i += 1;
                    break;
                }
                if (d == '\\') {
                    if (i + 1 >= text.len) return b.fail(path, line, "unterminated string", .{});
                    const e = text[i + 1];
                    try buf.append(switch (e) {
                        '"' => '"',
                        '\\' => '\\',
                        '\'' => '\'',
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => return b.fail(path, line, "unsupported escape '\\{c}'", .{e}),
                    });
                    i += 2;
                } else {
                    try buf.append(d);
                    i += 1;
                }
            }
            try toks.append(.{ .kind = .str, .text = buf.items, .line = line, .doc = doc });
        } else if (std.mem.indexOfScalar(u8, "{}[]()<>=;,:.", c) != null) {
            try toks.append(.{ .kind = .sym, .text = text[i .. i + 1], .line = line, .doc = doc });
            i += 1;
        } else {
            return b.fail(path, line, "unexpected character '{c}'", .{c});
        }
    }
    try toks.append(.{ .kind = .eof, .text = "", .line = line });
    return toks.items;
}

// ------------------------------------------------------------------------------------------------------- option values

pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    boolean: bool,
    ident: []const u8,
    list: []const Value,
    msg: []const Entry,
};

pub const Entry = struct { key: []const u8, value: Value, line: u32 };

/// The `(schema)` option as written.
pub const SchemaOpt = struct {
    wrapper: bool = false,
    @"union": bool = false,
    one_of: []const model.RequiredSet = &.{},
    when: ?model.Condition = null,
};

const OpResponse = struct { status: u16 = 0, description: []const u8 = "", @"error": bool = false };

const CommandOpt = struct {
    name: []const u8 = "",
    args: []const []const u8 = &.{},
    set: []const []const u8 = &.{},
    defaults: []const []const u8 = &.{},
    summary: []const u8 = "",
};

/// The `(operation)` option as written.
pub const OperationOpt = struct {
    tags: []const []const u8 = &.{},
    summary: []const u8 = "",
    security: []const []const u8 = &.{},
    responses: []const OpResponse = &.{},
    commands: []const CommandOpt = &.{},
};

/// The `(api)` option as written.
pub const ApiOpt = struct {
    title: []const u8 = "",
    version: []const u8 = "",
    summary: []const u8 = "",
    license_name: []const u8 = "",
    license_identifier: []const u8 = "",
    base_path: []const u8 = "",
    servers: []const model.Server = &.{},
    tags: []const []const u8 = &.{},
    security_schemes: []const model.SecurityScheme = &.{},
    headers: []const model.Header = &.{},
    error_response: []const u8 = "",
};

pub const HttpOpt = struct {
    get: ?[]const u8 = null,
    put: ?[]const u8 = null,
    post: ?[]const u8 = null,
    delete: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub fn blank(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .Bool => false,
        .Int => 0,
        .Optional => null,
        .Pointer => &.{},
        else => @compileError("no blank value for " ++ @typeName(T)),
    };
}

pub fn isRepeated(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |p| p.size == .Slice and p.child != u8,
        else => false,
    };
}

// -------------------------------------------------------------------------------------------------------------- builder

pub const Ref = struct { name: []const u8, line: u32 };
pub const TypeRef = struct { t: model.Type, ref: ?Ref };

pub const MsgB = struct {
    name: []const u8,
    path: []const u8,
    doc: []const u8,
    parent: ?usize,
    file: []const u8,
    fields: std.ArrayList(model.Field),
    /// Parallel to `fields`: the unresolved type name, when it is not a scalar.
    refs: std.ArrayList(?Ref),
    oneofs: std.ArrayList([]const u8),
    schema: ?SchemaOpt = null,
    schema_line: u32 = 0,
};

pub const EnumB = struct {
    name: []const u8,
    path: []const u8,
    doc: []const u8,
    parent: ?usize,
    file: []const u8,
    values: std.ArrayList(model.EnumValue),
};

pub const RpcB = struct {
    name: []const u8,
    doc: []const u8,
    line: u32,
    input: Ref,
    output: Ref,
    method: ?model.Method = null,
    path: []const u8 = "",
    body: ?[]const u8 = null,
    op: OperationOpt = .{},
    has_op: bool = false,
};

pub const ServiceB = struct {
    name: []const u8,
    doc: []const u8,
    file: []const u8,
    line: u32,
    api: ?ApiOpt = null,
    rpcs: std.ArrayList(RpcB),
};

pub const Builder = struct {
    arena: Allocator,
    bad: ?[]const u8 = null,
    package: ?[]const u8 = null,
    msgs: std.ArrayList(MsgB),
    enums: std.ArrayList(EnumB),
    order: std.ArrayList(model.Decl),
    names: std.StringHashMap(model.Decl),
    service: ?ServiceB = null,

    pub fn init(arena: Allocator) Builder {
        return .{
            .arena = arena,
            .msgs = std.ArrayList(MsgB).init(arena),
            .enums = std.ArrayList(EnumB).init(arena),
            .order = std.ArrayList(model.Decl).init(arena),
            .names = std.StringHashMap(model.Decl).init(arena),
        };
    }

    pub fn fail(b: *Builder, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) Error {
        b.bad = try std.fmt.allocPrint(b.arena, "{s}:{d}: " ++ fmt, .{ file, line } ++ args);
        return error.Bad;
    }

    pub fn declare(b: *Builder, path: []const u8, d: model.Decl, file: []const u8, line: u32) Error!void {
        if (b.names.contains(path)) return b.fail(file, line, "duplicate name '{s}'", .{path});
        try b.names.put(path, d);
    }

    pub fn qualified(b: *Builder, name: []const u8) ?model.Decl {
        const pkg = b.package.?;
        if (name.len > pkg.len and std.mem.startsWith(u8, name, pkg) and name[pkg.len] == '.') return b.names.get(name[pkg.len + 1 ..]);
        return null;
    }

    /// proto's scoping: the innermost scope that has the first component wins, then the rest must be found in it.
    pub fn lookup(b: *Builder, scope: []const u8, name: []const u8) Allocator.Error!?model.Decl {
        if (name[0] == '.') return b.qualified(name[1..]);
        const dot = std.mem.indexOfScalar(u8, name, '.');
        const first = if (dot) |d| name[0..d] else name;
        var s = scope;
        while (true) {
            const cand = if (s.len == 0) first else try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ s, first });
            if (b.names.contains(cand)) {
                const full = if (dot) |d| try std.fmt.allocPrint(b.arena, "{s}{s}", .{ cand, name[d..] }) else cand;
                return b.names.get(full);
            }
            if (s.len == 0) break;
            s = if (std.mem.lastIndexOfScalar(u8, s, '.')) |d| s[0..d] else "";
        }
        return b.qualified(name);
    }

    pub fn resolve(b: *Builder, file: []const u8, scope: []const u8, ref: Ref, allow_empty: bool) Error!model.Type {
        const bare = if (ref.name[0] == '.') ref.name[1..] else ref.name;
        if (std.mem.eql(u8, bare, "google.protobuf.Empty")) {
            if (!allow_empty) return b.fail(file, ref.line, "'google.protobuf.Empty' is only allowed as an rpc input or output", .{});
            return .empty;
        }
        const d = (try b.lookup(scope, ref.name)) orelse return b.fail(file, ref.line, "unknown type '{s}'", .{ref.name});
        return switch (d) {
            .message => |i| .{ .message = i },
            .enumeration => |i| .{ .enumeration = i },
        };
    }

    pub fn hasField(m: MsgB, name: []const u8) bool {
        for (m.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    pub fn typeName(b: *Builder, t: model.Type) []const u8 {
        return switch (t) {
            .message => |i| b.msgs.items[i].path,
            else => "google.protobuf.Empty",
        };
    }

    pub fn run(b: *Builder, sources: []const Source) Error!model.Api {
        for (sources) |s| try parser.parseFile(b, s);
        const sv = b.service orelse {
            b.bad = "no service declared in the sources";
            return error.Bad;
        };
        const api = sv.api orelse return b.fail(sv.file, sv.line, "service '{s}' has no option (api)", .{sv.name});

        for (b.msgs.items) |*m| {
            for (m.fields.items, m.refs.items) |*f, r| {
                if (r) |ref| f.type = try b.resolve(m.file, m.path, ref, false);
            }
        }
        for (b.msgs.items) |m| try b.checkSchema(m);

        var rpcs = std.ArrayList(model.Rpc).init(b.arena);
        for (sv.rpcs.items) |r| {
            const in_t = try b.resolve(sv.file, "", r.input, true);
            const out_t = try b.resolve(sv.file, "", r.output, true);
            if (in_t == .enumeration) return b.fail(sv.file, r.input.line, "rpc '{s}': input '{s}' is not a message", .{ r.name, r.input.name });
            if (out_t == .enumeration) return b.fail(sv.file, r.output.line, "rpc '{s}': output '{s}' is not a message", .{ r.name, r.output.name });
            try b.checkRpc(sv, api, r, in_t);
            var responses = std.ArrayList(model.Response).init(b.arena);
            for (r.op.responses) |o| try responses.append(.{ .status = o.status, .description = o.description, .is_error = o.@"error" });
            var commands = std.ArrayList(model.Command).init(b.arena);
            for (r.op.commands) |c| try commands.append(.{ .name = c.name, .args = c.args, .set = c.set, .defaults = c.defaults, .summary = c.summary });
            try rpcs.append(.{
                .name = r.name,
                .doc = r.doc,
                .input = in_t,
                .output = out_t,
                .method = r.method.?,
                .path = r.path,
                .body = r.body,
                .tags = r.op.tags,
                .summary = r.op.summary,
                .security = r.op.security,
                .responses = responses.items,
                .commands = commands.items,
            });
        }

        var messages = std.ArrayList(model.Message).init(b.arena);
        for (b.msgs.items) |m| {
            const s = m.schema orelse SchemaOpt{};
            try messages.append(.{
                .name = m.name,
                .path = m.path,
                .doc = m.doc,
                .parent = m.parent,
                .fields = m.fields.items,
                .wrapper = s.wrapper,
                .is_union = s.@"union",
                .one_of = s.one_of,
                .when = s.when,
                .file = m.file,
            });
        }
        var enums = std.ArrayList(model.Enum).init(b.arena);
        for (b.enums.items) |e| {
            try enums.append(.{ .name = e.name, .path = e.path, .doc = e.doc, .parent = e.parent, .values = e.values.items, .file = e.file });
        }

        var h = Sha256.init(.{});
        for (sources) |s| {
            h.update(s.path);
            h.update("\x00");
            h.update(s.text);
            h.update("\x00");
        }
        const hex = try b.arena.dupe(u8, &std.fmt.bytesToHex(h.finalResult(), .lower));

        return .{
            .package = b.package.?,
            .service = sv.name,
            .doc = sv.doc,
            .title = api.title,
            .version = api.version,
            .summary = api.summary,
            .license_name = api.license_name,
            .license_identifier = api.license_identifier,
            .base_path = api.base_path,
            .servers = api.servers,
            .tags = api.tags,
            .security_schemes = api.security_schemes,
            .headers = api.headers,
            .error_response = api.error_response,
            .messages = messages.items,
            .enums = enums.items,
            .order = b.order.items,
            .rpcs = rpcs.items,
            .sources_sha256 = hex,
        };
    }

    pub fn checkSchema(b: *Builder, m: MsgB) Error!void {
        const s = m.schema orelse return;
        const L = m.schema_line;
        if (s.wrapper and s.@"union") return b.fail(m.file, L, "message '{s}' cannot be both a wrapper and a union", .{m.path});
        if (s.wrapper and (m.fields.items.len != 1 or !std.mem.eql(u8, m.fields.items[0].name, "value"))) {
            return b.fail(m.file, L, "wrapper message '{s}' must have exactly one field named 'value'", .{m.path});
        }
        if (s.@"union") {
            var all = m.fields.items.len > 0 and m.oneofs.items.len == 1;
            for (m.fields.items) |f| if (f.oneof == null) {
                all = false;
            };
            if (!all) return b.fail(m.file, L, "union message '{s}' must have exactly one oneof holding all its fields", .{m.path});
        }
        for (s.one_of) |set| for (set.required) |n| {
            if (!hasField(m, n)) return b.fail(m.file, L, "message '{s}': one_of names unknown field '{s}'", .{ m.path, n });
        };
        if (s.when) |w| {
            if (!hasField(m, w.field)) return b.fail(m.file, L, "message '{s}': when names unknown field '{s}'", .{ m.path, w.field });
            for (w.required) |n| {
                if (!hasField(m, n)) return b.fail(m.file, L, "message '{s}': when requires unknown field '{s}'", .{ m.path, n });
            }
        }
    }

    pub fn checkRpc(b: *Builder, sv: ServiceB, api: ApiOpt, r: RpcB, in_t: model.Type) Error!void {
        const base = api.base_path;
        if (!std.mem.startsWith(u8, r.path, base) or (r.path.len > base.len and r.path[base.len] != '/')) {
            return b.fail(sv.file, r.line, "rpc '{s}': path '{s}' does not start with base_path '{s}'", .{ r.name, r.path, base });
        }
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, r.path, i, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, r.path, open, '}') orelse {
                return b.fail(sv.file, r.line, "rpc '{s}': path '{s}' has an unclosed '{{'", .{ r.name, r.path });
            };
            const name = r.path[open + 1 .. close];
            if (!b.inputHas(in_t, name)) {
                return b.fail(sv.file, r.line, "rpc '{s}': path parameter '{s}' is not a field of '{s}'", .{ r.name, name, b.typeName(in_t) });
            }
            i = close + 1;
        }
        if (r.body) |body| if (!b.inputHas(in_t, body)) {
            return b.fail(sv.file, r.line, "rpc '{s}': body field '{s}' is not a field of '{s}'", .{ r.name, body, b.typeName(in_t) });
        };
    }

    pub fn inputHas(b: *Builder, t: model.Type, name: []const u8) bool {
        return switch (t) {
            .message => |i| hasField(b.msgs.items[i], name),
            else => false,
        };
    }
};
