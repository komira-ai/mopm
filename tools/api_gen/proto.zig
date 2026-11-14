//! The reader of the registry API's protos (spec/api/mopm/registry/v2/*.proto): the subset of proto3 and of the options of
//! options.proto that the registry uses, turned into a `model.Api`. Anything outside the subset is refused with a message
//! that names the file, the line and what is wrong (`mopm/registry/v2/types.proto:12: unknown type 'Nmae'`).
//!
//! `parse` reads the files in the order given (options.proto is not among them: the option names are known here), then
//! resolves every type by proto's scoping and checks what the options promise (a wrapper has one field `value`, a union one
//! oneof, a path parameter is a field of the input, ...). `imports` lists a file's imports so the caller can order the files.

const std = @import("std");
const model = @import("model.zig");
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

const Error = error{Bad} || Allocator.Error;

const pkg_prefix = "mopm.registry.v2.";

// ---------------------------------------------------------------------------------------------------------------- tokens

const Kind = enum { ident, int, str, sym, eof };

const Token = struct {
    kind: Kind,
    /// The identifier, the symbol, or the decoded string.
    text: []const u8,
    int: i64 = 0,
    line: u32,
    /// The comment lines directly above the token (no blank line between), as the model's `Doc`.
    doc: []const u8 = "",
};

fn tokenize(b: *Builder, path: []const u8, text: []const u8) Error![]const Token {
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

const Value = union(enum) {
    int: i64,
    str: []const u8,
    boolean: bool,
    ident: []const u8,
    list: []const Value,
    msg: []const Entry,
};

const Entry = struct { key: []const u8, value: Value, line: u32 };

/// The `(schema)` option as written.
const SchemaOpt = struct {
    wrapper: bool = false,
    @"union": bool = false,
    one_of: []const model.RequiredSet = &.{},
    when: ?model.Condition = null,
};

const OpResponse = struct { status: u16 = 0, description: []const u8 = "", @"error": bool = false };

/// The `(operation)` option as written.
const OperationOpt = struct {
    tags: []const []const u8 = &.{},
    summary: []const u8 = "",
    security: []const []const u8 = &.{},
    responses: []const OpResponse = &.{},
};

/// The `(api)` option as written.
const ApiOpt = struct {
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

const HttpOpt = struct {
    get: ?[]const u8 = null,
    put: ?[]const u8 = null,
    post: ?[]const u8 = null,
    delete: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

fn blank(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .Bool => false,
        .Int => 0,
        .Optional => null,
        .Pointer => &.{},
        else => @compileError("no blank value for " ++ @typeName(T)),
    };
}

fn isRepeated(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |p| p.size == .Slice and p.child != u8,
        else => false,
    };
}

// -------------------------------------------------------------------------------------------------------------- builder

const Ref = struct { name: []const u8, line: u32 };
const TypeRef = struct { t: model.Type, ref: ?Ref };

const MsgB = struct {
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

const EnumB = struct {
    name: []const u8,
    path: []const u8,
    doc: []const u8,
    parent: ?usize,
    file: []const u8,
    values: std.ArrayList(model.EnumValue),
};

const RpcB = struct {
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

const ServiceB = struct {
    name: []const u8,
    doc: []const u8,
    file: []const u8,
    line: u32,
    api: ?ApiOpt = null,
    rpcs: std.ArrayList(RpcB),
};

const Builder = struct {
    arena: Allocator,
    bad: ?[]const u8 = null,
    package: ?[]const u8 = null,
    msgs: std.ArrayList(MsgB),
    enums: std.ArrayList(EnumB),
    order: std.ArrayList(model.Decl),
    names: std.StringHashMap(model.Decl),
    service: ?ServiceB = null,

    fn init(arena: Allocator) Builder {
        return .{
            .arena = arena,
            .msgs = std.ArrayList(MsgB).init(arena),
            .enums = std.ArrayList(EnumB).init(arena),
            .order = std.ArrayList(model.Decl).init(arena),
            .names = std.StringHashMap(model.Decl).init(arena),
        };
    }

    fn fail(b: *Builder, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) Error {
        b.bad = try std.fmt.allocPrint(b.arena, "{s}:{d}: " ++ fmt, .{ file, line } ++ args);
        return error.Bad;
    }

    fn declare(b: *Builder, path: []const u8, d: model.Decl, file: []const u8, line: u32) Error!void {
        if (b.names.contains(path)) return b.fail(file, line, "duplicate name '{s}'", .{path});
        try b.names.put(path, d);
    }

    fn qualified(b: *Builder, name: []const u8) ?model.Decl {
        const pkg = b.package.?;
        if (name.len > pkg.len and std.mem.startsWith(u8, name, pkg) and name[pkg.len] == '.') return b.names.get(name[pkg.len + 1 ..]);
        return null;
    }

    /// proto's scoping: the innermost scope that has the first component wins, then the rest must be found in it.
    fn lookup(b: *Builder, scope: []const u8, name: []const u8) Allocator.Error!?model.Decl {
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

    fn resolve(b: *Builder, file: []const u8, scope: []const u8, ref: Ref, allow_empty: bool) Error!model.Type {
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

    fn hasField(m: MsgB, name: []const u8) bool {
        for (m.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    fn typeName(b: *Builder, t: model.Type) []const u8 {
        return switch (t) {
            .message => |i| b.msgs.items[i].path,
            else => "google.protobuf.Empty",
        };
    }

    fn parseFile(b: *Builder, s: Source) Error!void {
        const toks = try tokenize(b, s.path, s.text);
        var p = Parser{ .b = b, .path = s.path, .toks = toks };
        if (!p.isIdent("syntax")) return p.fail(p.peek().line, "the file must start with syntax = \"proto3\";", .{});
        _ = p.next();
        try p.expectSym("=");
        const v = try p.expectString();
        if (!std.mem.eql(u8, v.text, "proto3")) return p.fail(v.line, "only syntax \"proto3\" is supported", .{});
        try p.expectSym(";");
        while (true) {
            const t = p.peek();
            if (t.kind == .eof) break;
            if (t.kind == .sym and t.text[0] == ';') {
                _ = p.next();
                continue;
            }
            if (t.kind != .ident) return p.unexpected(t);
            if (std.mem.eql(u8, t.text, "import")) {
                _ = p.next();
                const mod = p.peek();
                if (mod.kind == .ident) return p.fail(mod.line, "import {s} is not supported", .{mod.text});
                _ = try p.expectString();
                try p.expectSym(";");
            } else if (std.mem.eql(u8, t.text, "package")) {
                _ = p.next();
                const name = try p.dotted();
                try p.expectSym(";");
                if (p.pkg_seen) return p.fail(t.line, "duplicate package statement", .{});
                if (b.package) |old| if (!std.mem.eql(u8, old, name)) return p.fail(t.line, "package '{s}' differs from '{s}'", .{ name, old });
                b.package = name;
                p.pkg_seen = true;
            } else if (std.mem.eql(u8, t.text, "option")) {
                _ = p.next();
                _ = try p.optionName();
                try p.expectSym("=");
                _ = try p.value();
                try p.expectSym(";");
            } else if (std.mem.eql(u8, t.text, "message")) {
                try p.parseMessage(null, "");
            } else if (std.mem.eql(u8, t.text, "enum")) {
                try p.parseEnum(null, "");
            } else if (std.mem.eql(u8, t.text, "service")) {
                try p.parseService();
            } else return p.unexpected(t);
        }
        if (!p.pkg_seen) return p.fail(p.peek().line, "missing package statement", .{});
    }

    fn run(b: *Builder, sources: []const Source) Error!model.Api {
        for (sources) |s| try b.parseFile(s);
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

    fn checkSchema(b: *Builder, m: MsgB) Error!void {
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

    fn checkRpc(b: *Builder, sv: ServiceB, api: ApiOpt, r: RpcB, in_t: model.Type) Error!void {
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

    fn inputHas(b: *Builder, t: model.Type, name: []const u8) bool {
        return switch (t) {
            .message => |i| hasField(b.msgs.items[i], name),
            else => false,
        };
    }
};

// -------------------------------------------------------------------------------------------------------------- parser

const OptName = struct { name: []const u8, line: u32 };

const unsupported_scalars = [_][]const u8{ "double", "float", "bytes", "fixed32", "fixed64", "sfixed32", "sfixed64", "sint32", "sint64" };

const Parser = struct {
    b: *Builder,
    path: []const u8,
    toks: []const Token,
    pos: usize = 0,
    pkg_seen: bool = false,

    fn peek(p: *Parser) Token {
        return p.toks[p.pos];
    }

    fn peekAt(p: *Parser, n: usize) Token {
        return p.toks[@min(p.pos + n, p.toks.len - 1)];
    }

    fn next(p: *Parser) Token {
        const t = p.toks[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    fn fail(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) Error {
        return p.b.fail(p.path, line, fmt, args);
    }

    fn isSym(p: *Parser, c: u8) bool {
        const t = p.peek();
        return t.kind == .sym and t.text[0] == c;
    }

    fn isIdent(p: *Parser, s: []const u8) bool {
        const t = p.peek();
        return t.kind == .ident and std.mem.eql(u8, t.text, s);
    }

    fn found(p: *Parser, t: Token) Allocator.Error![]const u8 {
        return switch (t.kind) {
            .eof => "end of file",
            .str => try std.fmt.allocPrint(p.b.arena, "\"{s}\"", .{t.text}),
            else => try std.fmt.allocPrint(p.b.arena, "'{s}'", .{t.text}),
        };
    }

    fn unexpected(p: *Parser, t: Token) Error {
        return p.fail(t.line, "unexpected {s}", .{try p.found(t)});
    }

    fn expectSym(p: *Parser, s: []const u8) Error!void {
        const t = p.peek();
        if (t.kind != .sym or t.text[0] != s[0]) return p.fail(t.line, "expected '{s}' but found {s}", .{ s, try p.found(t) });
        _ = p.next();
    }

    fn expectIdent(p: *Parser) Error!Token {
        const t = p.peek();
        if (t.kind != .ident) return p.fail(t.line, "expected a name but found {s}", .{try p.found(t)});
        return p.next();
    }

    fn expectString(p: *Parser) Error!Token {
        const t = p.peek();
        if (t.kind != .str) return p.fail(t.line, "expected a string but found {s}", .{try p.found(t)});
        return p.next();
    }

    fn expectInt(p: *Parser) Error!Token {
        const t = p.peek();
        if (t.kind != .int) return p.fail(t.line, "expected a number but found {s}", .{try p.found(t)});
        return p.next();
    }

    /// `a.b.c`, with a leading `.` kept.
    fn dotted(p: *Parser) Error![]const u8 {
        var out = std.ArrayList(u8).init(p.b.arena);
        if (p.isSym('.')) {
            _ = p.next();
            try out.append('.');
        }
        try out.appendSlice((try p.expectIdent()).text);
        while (p.isSym('.') and p.peekAt(1).kind == .ident) {
            _ = p.next();
            try out.append('.');
            try out.appendSlice(p.next().text);
        }
        return out.items;
    }

    fn needPackage(p: *Parser, t: Token) Error!void {
        if (!p.pkg_seen) return p.fail(t.line, "the package statement must come before '{s}'", .{t.text});
    }

    /// `(field)` for `(field)`, `(mopm.registry.v2.field)` and `(.mopm.registry.v2.field)`; a plain name as written.
    fn optionName(p: *Parser) Error!OptName {
        const t = p.peek();
        if (!p.isSym('(')) return .{ .name = (try p.expectIdent()).text, .line = t.line };
        _ = p.next();
        var n = try p.dotted();
        try p.expectSym(")");
        if (n[0] == '.') n = n[1..];
        if (std.mem.startsWith(u8, n, pkg_prefix)) n = n[pkg_prefix.len..];
        return .{ .name = try std.fmt.allocPrint(p.b.arena, "({s})", .{n}), .line = t.line };
    }

    // ---- values and their conversion to the model's option structs

    fn value(p: *Parser) Error!Value {
        const t = p.peek();
        switch (t.kind) {
            .str => {
                var s = std.ArrayList(u8).init(p.b.arena);
                while (p.peek().kind == .str) try s.appendSlice(p.next().text);
                return .{ .str = s.items };
            },
            .int => {
                _ = p.next();
                return .{ .int = t.int };
            },
            .ident => {
                _ = p.next();
                if (std.mem.eql(u8, t.text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, t.text, "false")) return .{ .boolean = false };
                return .{ .ident = t.text };
            },
            .sym => {
                if (t.text[0] == '{') return .{ .msg = try p.messageLiteral() };
                if (t.text[0] == '[') {
                    _ = p.next();
                    var items = std.ArrayList(Value).init(p.b.arena);
                    while (!p.isSym(']')) {
                        try items.append(try p.value());
                        if (p.isSym(',')) _ = p.next() else if (!p.isSym(']')) return p.fail(p.peek().line, "expected ',' or ']' but found {s}", .{try p.found(p.peek())});
                    }
                    _ = p.next();
                    return .{ .list = items.items };
                }
            },
            .eof => {},
        }
        return p.fail(t.line, "expected a value but found {s}", .{try p.found(t)});
    }

    fn messageLiteral(p: *Parser) Error![]const Entry {
        try p.expectSym("{");
        var entries = std.ArrayList(Entry).init(p.b.arena);
        while (true) {
            while (p.isSym(',') or p.isSym(';')) _ = p.next();
            if (p.isSym('}')) break;
            const key = try p.expectIdent();
            if (p.isSym(':')) {
                _ = p.next();
            } else if (!p.isSym('{')) {
                return p.fail(key.line, "expected ':' after key '{s}' but found {s}", .{ key.text, try p.found(p.peek()) });
            }
            try entries.append(.{ .key = key.text, .value = try p.value(), .line = key.line });
        }
        _ = p.next();
        return entries.items;
    }

    fn wrong(p: *Parser, opt: []const u8, key: []const u8, line: u32, what: []const u8) Error {
        return p.fail(line, "option {s}: '{s}' must be {s}", .{ opt, key, what });
    }

    fn convertValue(p: *Parser, comptime T: type, opt: []const u8, key: []const u8, line: u32, v: Value) Error!T {
        switch (@typeInfo(T)) {
            .Bool => return switch (v) {
                .boolean => |x| x,
                else => p.wrong(opt, key, line, "true or false"),
            },
            .Int => switch (v) {
                .int => |x| return std.math.cast(T, x) orelse p.fail(line, "option {s}: '{s}' must be an integer that fits {s}", .{ opt, key, @typeName(T) }),
                else => return p.wrong(opt, key, line, "an integer"),
            },
            .Optional => |o| return try p.convertValue(o.child, opt, key, line, v),
            .Pointer => |ptr| {
                if (T == []const u8) return switch (v) {
                    .str => |s| s,
                    else => p.wrong(opt, key, line, "a string"),
                };
                if (ptr.size == .Slice) {
                    var items = std.ArrayList(ptr.child).init(p.b.arena);
                    switch (v) {
                        .list => |l| for (l) |x| try items.append(try p.convertValue(ptr.child, opt, key, line, x)),
                        else => try items.append(try p.convertValue(ptr.child, opt, key, line, v)),
                    }
                    return items.items;
                }
                const out = try p.b.arena.create(ptr.child);
                out.* = try p.convertValue(ptr.child, opt, key, line, v);
                return out;
            },
            .Struct => switch (v) {
                .msg => |entries| return p.convertStruct(T, opt, entries),
                else => return p.wrong(opt, key, line, "a message literal"),
            },
            else => @compileError("cannot convert an option value to " ++ @typeName(T)),
        }
    }

    /// The struct `T` from the entries of a message literal; a key that is no field of `T` is refused, a repeated field
    /// collects every entry of its key, any other field may be set once.
    fn convertStruct(p: *Parser, comptime T: type, opt: []const u8, entries: []const Entry) Error!T {
        const fields = @typeInfo(T).Struct.fields;
        var out: T = undefined;
        inline for (fields) |f| {
            @field(out, f.name) = if (f.default_value) |dv| @as(*const f.type, @ptrCast(@alignCast(dv))).* else blank(f.type);
        }
        var seen = [_]bool{false} ** fields.len;
        for (entries) |e| {
            var matched = false;
            inline for (fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, e.key)) {
                    matched = true;
                    const v = try p.convertValue(f.type, opt, e.key, e.line, e.value);
                    if (comptime isRepeated(f.type)) {
                        const Elem = @typeInfo(f.type).Pointer.child;
                        @field(out, f.name) = try std.mem.concat(p.b.arena, Elem, &[_][]const Elem{ @field(out, f.name), v });
                    } else {
                        if (seen[i]) return p.fail(e.line, "option {s}: '{s}' is set twice", .{ opt, e.key });
                        seen[i] = true;
                        @field(out, f.name) = v;
                    }
                }
            }
            if (!matched) return p.fail(e.line, "unknown key '{s}' in option {s}", .{ e.key, opt });
        }
        return out;
    }

    fn convertTop(p: *Parser, comptime T: type, opt: []const u8, v: Value, line: u32) Error!T {
        return switch (v) {
            .msg => |entries| p.convertStruct(T, opt, entries),
            else => p.fail(line, "option {s}: the value must be a message literal", .{opt}),
        };
    }

    // ---- declarations

    fn parseMessage(p: *Parser, parent: ?usize, parent_path: []const u8) Error!void {
        const kw = p.next();
        try p.needPackage(kw);
        const name = try p.expectIdent();
        const path = if (parent_path.len == 0) name.text else try std.fmt.allocPrint(p.b.arena, "{s}.{s}", .{ parent_path, name.text });
        const idx = p.b.msgs.items.len;
        try p.b.declare(path, .{ .message = idx }, p.path, kw.line);
        try p.b.msgs.append(.{
            .name = name.text,
            .path = path,
            .doc = kw.doc,
            .parent = parent,
            .file = p.path,
            .fields = std.ArrayList(model.Field).init(p.b.arena),
            .refs = std.ArrayList(?Ref).init(p.b.arena),
            .oneofs = std.ArrayList([]const u8).init(p.b.arena),
        });
        if (parent == null) try p.b.order.append(.{ .message = idx });
        try p.expectSym("{");
        while (true) {
            const t = p.peek();
            if (t.kind == .sym and t.text[0] == '}') {
                _ = p.next();
                break;
            }
            if (t.kind == .sym and t.text[0] == ';') {
                _ = p.next();
                continue;
            }
            if (t.kind == .ident and std.mem.eql(u8, t.text, "message")) {
                try p.parseMessage(idx, path);
            } else if (t.kind == .ident and std.mem.eql(u8, t.text, "enum")) {
                try p.parseEnum(idx, path);
            } else if (t.kind == .ident and std.mem.eql(u8, t.text, "option")) {
                try p.messageOption(idx);
            } else if (t.kind == .ident and std.mem.eql(u8, t.text, "oneof")) {
                try p.parseOneof(idx);
            } else if (t.kind == .ident and (std.mem.eql(u8, t.text, "reserved") or std.mem.eql(u8, t.text, "extend") or std.mem.eql(u8, t.text, "extensions"))) {
                return p.fail(t.line, "'{s}' is not supported", .{t.text});
            } else if (t.kind == .ident or (t.kind == .sym and t.text[0] == '.')) {
                try p.parseField(idx, null);
            } else return p.unexpected(t);
        }
    }

    fn messageOption(p: *Parser, idx: usize) Error!void {
        _ = p.next();
        const o = try p.optionName();
        try p.expectSym("=");
        const v = try p.value();
        try p.expectSym(";");
        if (!std.mem.eql(u8, o.name, "(schema)")) return p.fail(o.line, "unknown option '{s}'", .{o.name});
        if (p.b.msgs.items[idx].schema != null) return p.fail(o.line, "option '(schema)' is set twice", .{});
        const s = try p.convertTop(SchemaOpt, "(schema)", v, o.line);
        p.b.msgs.items[idx].schema = s;
        p.b.msgs.items[idx].schema_line = o.line;
    }

    fn parseOneof(p: *Parser, idx: usize) Error!void {
        const kw = p.next();
        const name = try p.expectIdent();
        for (p.b.msgs.items[idx].oneofs.items) |o| {
            if (std.mem.eql(u8, o, name.text)) return p.fail(name.line, "duplicate oneof '{s}' in message '{s}'", .{ o, p.b.msgs.items[idx].path });
        }
        try p.b.msgs.items[idx].oneofs.append(name.text);
        try p.expectSym("{");
        var n: usize = 0;
        while (true) {
            if (p.isSym('}')) {
                _ = p.next();
                break;
            }
            if (p.isSym(';')) {
                _ = p.next();
                continue;
            }
            if (p.isIdent("option")) return p.fail(p.peek().line, "options inside a oneof are not supported", .{});
            try p.parseField(idx, name.text);
            n += 1;
        }
        if (n == 0) return p.fail(kw.line, "oneof '{s}' has no fields", .{name.text});
    }

    fn typeRef(p: *Parser) Error!TypeRef {
        const t = p.peek();
        const name = try p.dotted();
        if (std.meta.stringToEnum(model.Scalar, name)) |s| return .{ .t = .{ .scalar = s }, .ref = null };
        for (unsupported_scalars) |u| if (std.mem.eql(u8, name, u)) return p.fail(t.line, "unsupported type '{s}'", .{name});
        return .{ .t = .{ .scalar = .string }, .ref = .{ .name = name, .line = t.line } };
    }

    fn parseField(p: *Parser, idx: usize, oneof: ?[]const u8) Error!void {
        const first = p.peek();
        var label: model.Label = .single;
        var labeled = false;
        if (p.isIdent("optional") or p.isIdent("repeated")) {
            label = if (p.isIdent("optional")) .optional else .repeated;
            labeled = true;
            if (oneof != null) return p.fail(first.line, "a oneof field cannot have a label", .{});
            _ = p.next();
        }
        var ft: TypeRef = undefined;
        var is_map = false;
        const t = p.peek();
        if (t.kind == .ident and std.mem.eql(u8, t.text, "map") and p.peekAt(1).kind == .sym and p.peekAt(1).text[0] == '<') {
            if (labeled) return p.fail(first.line, "a map field cannot have a label", .{});
            if (oneof != null) return p.fail(first.line, "a map field cannot be in a oneof", .{});
            _ = p.next();
            _ = p.next();
            const key = try p.expectIdent();
            if (!std.mem.eql(u8, key.text, "string")) return p.fail(key.line, "map keys must be string, not '{s}'", .{key.text});
            try p.expectSym(",");
            ft = try p.typeRef();
            try p.expectSym(">");
            is_map = true;
        } else ft = try p.typeRef();
        const name = try p.expectIdent();
        try p.expectSym("=");
        const num = try p.expectInt();
        if (num.int < 1 or num.int > 536870911) return p.fail(num.line, "field number {d} is out of range", .{num.int});
        var rules = model.Rules{};
        if (p.isSym('[')) {
            _ = p.next();
            var have = false;
            while (true) {
                const o = try p.optionName();
                try p.expectSym("=");
                const v = try p.value();
                if (!std.mem.eql(u8, o.name, "(field)")) return p.fail(o.line, "unknown option '{s}'", .{o.name});
                if (have) return p.fail(o.line, "option '(field)' is set twice", .{});
                have = true;
                rules = try p.convertTop(model.Rules, "(field)", v, o.line);
                if (!p.isSym(',')) break;
                _ = p.next();
            }
            try p.expectSym("]");
        }
        try p.expectSym(";");
        const m = &p.b.msgs.items[idx];
        for (m.fields.items) |f| {
            if (std.mem.eql(u8, f.name, name.text)) return p.fail(name.line, "duplicate field '{s}' in message '{s}'", .{ name.text, m.path });
            if (f.number == num.int) return p.fail(num.line, "duplicate field number {d} in message '{s}'", .{ num.int, m.path });
        }
        try m.fields.append(.{
            .name = name.text,
            .number = @intCast(num.int),
            .doc = first.doc,
            .label = label,
            .type = ft.t,
            .map = is_map,
            .oneof = oneof,
            .rules = rules,
        });
        try m.refs.append(ft.ref);
    }

    fn parseEnum(p: *Parser, parent: ?usize, parent_path: []const u8) Error!void {
        const kw = p.next();
        try p.needPackage(kw);
        const name = try p.expectIdent();
        const path = if (parent_path.len == 0) name.text else try std.fmt.allocPrint(p.b.arena, "{s}.{s}", .{ parent_path, name.text });
        const idx = p.b.enums.items.len;
        try p.b.declare(path, .{ .enumeration = idx }, p.path, kw.line);
        try p.b.enums.append(.{
            .name = name.text,
            .path = path,
            .doc = kw.doc,
            .parent = parent,
            .file = p.path,
            .values = std.ArrayList(model.EnumValue).init(p.b.arena),
        });
        if (parent == null) try p.b.order.append(.{ .enumeration = idx });
        const prefix = try std.fmt.allocPrint(p.b.arena, "{s}_", .{try model.upperSnake(p.b.arena, name.text)});
        try p.expectSym("{");
        while (true) {
            if (p.isSym('}')) {
                _ = p.next();
                break;
            }
            if (p.isSym(';')) {
                _ = p.next();
                continue;
            }
            if (p.isIdent("option")) {
                _ = p.next();
                const o = try p.optionName();
                return p.fail(o.line, "unknown option '{s}'", .{o.name});
            }
            const vt = try p.expectIdent();
            try p.expectSym("=");
            const num = try p.expectInt();
            const number = std.math.cast(i32, num.int) orelse return p.fail(num.line, "enum value number {d} is out of range", .{num.int});
            var json: ?[]const u8 = null;
            var err: ?model.ErrorEntry = null;
            if (p.isSym('[')) {
                _ = p.next();
                while (true) {
                    const o = try p.optionName();
                    try p.expectSym("=");
                    const v = try p.value();
                    if (std.mem.eql(u8, o.name, "(json)")) {
                        if (json != null) return p.fail(o.line, "option '(json)' is set twice", .{});
                        json = switch (v) {
                            .str => |s| s,
                            else => return p.fail(o.line, "option (json): the value must be a string", .{}),
                        };
                    } else if (std.mem.eql(u8, o.name, "(error)")) {
                        if (err != null) return p.fail(o.line, "option '(error)' is set twice", .{});
                        err = try p.convertTop(model.ErrorEntry, "(error)", v, o.line);
                    } else return p.fail(o.line, "unknown option '{s}'", .{o.name});
                    if (!p.isSym(',')) break;
                    _ = p.next();
                }
                try p.expectSym("]");
            }
            try p.expectSym(";");
            const values = &p.b.enums.items[idx].values;
            if (values.items.len == 0 and number != 0) return p.fail(vt.line, "the first value of enum '{s}' must be 0", .{path});
            if (json == null and !std.mem.startsWith(u8, vt.text, prefix)) {
                return p.fail(vt.line, "enum value '{s}' must start with '{s}' or have a (json) option", .{ vt.text, prefix });
            }
            for (p.b.enums.items) |e| {
                if (e.parent != parent) continue;
                for (e.values.items) |v| if (std.mem.eql(u8, v.name, vt.text)) return p.fail(vt.line, "duplicate enum value name '{s}'", .{vt.text});
            }
            for (values.items) |v| if (v.number == number) return p.fail(num.line, "duplicate enum value number {d} in enum '{s}'", .{ number, path });
            try values.append(.{ .name = vt.text, .number = number, .doc = vt.doc, .json_option = json, .err = err });
        }
        if (p.b.enums.items[idx].values.items.len == 0) return p.fail(kw.line, "enum '{s}' has no values", .{path});
    }

    fn parseService(p: *Parser) Error!void {
        const kw = p.next();
        try p.needPackage(kw);
        const name = try p.expectIdent();
        if (p.b.service) |old| return p.fail(kw.line, "second service '{s}' (the first is '{s}')", .{ name.text, old.name });
        var sv = ServiceB{ .name = name.text, .doc = kw.doc, .file = p.path, .line = kw.line, .rpcs = std.ArrayList(RpcB).init(p.b.arena) };
        try p.expectSym("{");
        while (true) {
            const t = p.peek();
            if (t.kind == .sym and t.text[0] == '}') {
                _ = p.next();
                break;
            }
            if (t.kind == .sym and t.text[0] == ';') {
                _ = p.next();
                continue;
            }
            if (p.isIdent("option")) {
                _ = p.next();
                const o = try p.optionName();
                try p.expectSym("=");
                const v = try p.value();
                try p.expectSym(";");
                if (!std.mem.eql(u8, o.name, "(api)")) return p.fail(o.line, "unknown option '{s}'", .{o.name});
                if (sv.api != null) return p.fail(o.line, "option '(api)' is set twice", .{});
                sv.api = try p.convertTop(ApiOpt, "(api)", v, o.line);
            } else if (p.isIdent("rpc")) {
                try p.parseRpc(&sv);
            } else return p.unexpected(t);
        }
        p.b.service = sv;
    }

    fn parseRpc(p: *Parser, sv: *ServiceB) Error!void {
        const kw = p.next();
        const name = try p.expectIdent();
        for (sv.rpcs.items) |r| if (std.mem.eql(u8, r.name, name.text)) return p.fail(name.line, "duplicate rpc '{s}'", .{name.text});
        var rpc = RpcB{ .name = name.text, .doc = kw.doc, .line = kw.line, .input = undefined, .output = undefined };
        try p.expectSym("(");
        if (p.isIdent("stream")) return p.fail(p.peek().line, "streaming rpcs are not supported", .{});
        const in_line = p.peek().line;
        rpc.input = .{ .name = try p.dotted(), .line = in_line };
        try p.expectSym(")");
        const ret = try p.expectIdent();
        if (!std.mem.eql(u8, ret.text, "returns")) return p.fail(ret.line, "expected 'returns' but found '{s}'", .{ret.text});
        try p.expectSym("(");
        if (p.isIdent("stream")) return p.fail(p.peek().line, "streaming rpcs are not supported", .{});
        const out_line = p.peek().line;
        rpc.output = .{ .name = try p.dotted(), .line = out_line };
        try p.expectSym(")");
        if (p.isSym('{')) {
            _ = p.next();
            while (true) {
                if (p.isSym('}')) {
                    _ = p.next();
                    break;
                }
                if (p.isSym(';')) {
                    _ = p.next();
                    continue;
                }
                const t = p.peek();
                if (!p.isIdent("option")) return p.unexpected(t);
                _ = p.next();
                const o = try p.optionName();
                try p.expectSym("=");
                const v = try p.value();
                try p.expectSym(";");
                if (std.mem.eql(u8, o.name, "(google.api.http)")) {
                    if (rpc.method != null) return p.fail(o.line, "option '(google.api.http)' is set twice", .{});
                    const h = try p.convertTop(HttpOpt, "(google.api.http)", v, o.line);
                    const set = [_]struct { ?[]const u8, model.Method }{ .{ h.get, .GET }, .{ h.put, .PUT }, .{ h.post, .POST }, .{ h.delete, .DELETE }, .{ h.patch, .PATCH } };
                    var count: usize = 0;
                    for (set) |s| if (s[0]) |path| {
                        count += 1;
                        rpc.method = s[1];
                        rpc.path = path;
                    };
                    if (count != 1) return p.fail(o.line, "rpc '{s}': google.api.http needs exactly one of get, put, post, delete, patch", .{name.text});
                    rpc.body = h.body;
                } else if (std.mem.eql(u8, o.name, "(operation)")) {
                    if (rpc.has_op) return p.fail(o.line, "option '(operation)' is set twice", .{});
                    rpc.op = try p.convertTop(OperationOpt, "(operation)", v, o.line);
                    rpc.has_op = true;
                } else return p.fail(o.line, "unknown option '{s}'", .{o.name});
            }
        } else try p.expectSym(";");
        if (rpc.method == null) return p.fail(kw.line, "rpc '{s}' has no option (google.api.http)", .{name.text});
        try sv.rpcs.append(rpc);
    }
};

// ------------------------------------------------------------------------------------------------------------- tests

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
