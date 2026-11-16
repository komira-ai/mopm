//! The OpenAPI writer of tools/api_gen.zig: `write` turns the model of the registry protos (model.zig) into the text of
//! spec/api/openapi-v2.yaml.
//!
//! The text is in the subset of YAML that tests/drivers/yaml.zig reads: block mappings and sequences indented by two
//! spaces; every string a double-quoted scalar with JSON escapes (`"..."`), except a string that holds a newline, which is
//! a literal block `|` (read back as the text and one `\n`); integers and booleans plain; `[]` and `{}` for an empty list
//! and map. A key is plain when it is made of `A-Za-z0-9_$/{}.-` (not starting with a digit, `-`, `{`, `}` or `.`), else
//! double-quoted (`"200"`).
//!
//! Refusals: `write` returns `.bad` with one message (the first problem found, naming where it is) when the model cannot be
//! written as the contract, for instance a parameter used by two rpcs with different definitions, a description whose first
//! line starts with a space (a literal block cannot hold it), or a keyword that does not apply to the field's type.

const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Result = union(enum) {
    /// The whole YAML text.
    ok: []const u8,
    /// Why the model cannot be written.
    bad: []const u8,
};

pub fn write(arena: Allocator, api: model.Api) Allocator.Error!Result {
    var w = Writer{ .arena = arena, .api = api };
    const text = w.document() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .bad = w.msg },
    };
    return .{ .ok = text };
}

const Err = error{ Invalid, OutOfMemory };

const Entry = struct { key: []const u8, value: Node };
/// The entries of one mapping of the output (test access).
pub const Entries = std.ArrayList(Entry);

/// A YAML value before it is rendered.
const Node = union(enum) {
    /// Written as is: an integer or a boolean.
    raw: []const u8,
    /// A string: quoted, or a literal block when it holds a newline.
    str: []const u8,
    map: []const Entry,
    seq: []const Node,
    /// A mapping of scalars written on one line, `{ status: 400, message: "...", hint: "..." }` (an `x-mopm-errors` entry),
    /// its strings always quoted.
    flow: []const Entry,
};

const max_depth = 16;

const ParamDef = struct { name: []const u8, node: Node, text: []const u8, rpc: []const u8 };

/// The writer's state; public for the tests of its helpers.
pub const Writer = struct {
    arena: Allocator,
    api: model.Api,
    msg: []const u8 = "",
    where: []const u8 = "",
    /// Messages that are the input of an rpc: not schemas of the document.
    is_input: []bool = &.{},
    params: std.ArrayList(ParamDef) = undefined,

    fn fail(self: *Writer, comptime fmt: []const u8, args: anytype) Err {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        self.msg = if (self.where.len > 0) try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ self.where, text }) else text;
        return error.Invalid;
    }

    // ---- building the tree ----------------------------------------------------------------------------------------

    fn str(s: []const u8) Node {
        return .{ .str = s };
    }

    fn boolean(b: bool) Node {
        return .{ .raw = if (b) "true" else "false" };
    }

    fn int(self: *Writer, n: anytype) Err!Node {
        return .{ .raw = try std.fmt.allocPrint(self.arena, "{d}", .{n}) };
    }

    fn strings(self: *Writer, items: []const []const u8) Err!Node {
        const out = try self.arena.alloc(Node, items.len);
        for (items, out) |s, *o| o.* = str(s);
        return .{ .seq = out };
    }

    fn mapNode(list: Entries) Node {
        return .{ .map = list.items };
    }

    fn nodeOf(entries: []const Entry) Node {
        return .{ .map = entries };
    }

    pub fn add(list: *Entries, key: []const u8, value: Node) Err!void {
        try list.append(.{ .key = key, .value = value });
    }

    /// Sets `key`, replacing an earlier entry of that name (a mapping may not repeat a key).
    fn put(list: *Entries, key: []const u8, value: Node) Err!void {
        for (list.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        try list.append(.{ .key = key, .value = value });
    }

    fn find(list: Entries, key: []const u8) ?usize {
        for (list.items, 0..) |e, i| if (std.mem.eql(u8, e.key, key)) return i;
        return null;
    }

    fn refNode(self: *Writer, kind: []const u8, name: []const u8) Err!Node {
        var e = Entries.init(self.arena);
        try add(&e, "$ref", str(try std.fmt.allocPrint(self.arena, "#/components/{s}/{s}", .{ kind, name })));
        return mapNode(e);
    }

    /// The description: `doc` replaces the entry `description` or is put first; an empty `doc` leaves the entries alone.
    pub fn describe(self: *Writer, list: *Entries, doc: []const u8) Err!void {
        if (doc.len == 0) return;
        if (find(list.*, "description")) |i| {
            list.items[i].value = str(doc);
            return;
        }
        var out = Entries.init(self.arena);
        try add(&out, "description", str(doc));
        try out.appendSlice(list.items);
        list.* = out;
    }

    fn undescribe(list: *Entries) void {
        if (find(list.*, "description")) |i| _ = list.orderedRemove(i);
    }

    // ---- the document ---------------------------------------------------------------------------------------------

    fn document(self: *Writer) Err![]const u8 {
        const api = self.api;
        self.is_input = try self.arena.alloc(bool, api.messages.len);
        @memset(self.is_input, false);
        for (api.rpcs) |rpc| switch (rpc.input) {
            .message => |i| self.is_input[i] = true,
            else => {},
        };
        self.params = std.ArrayList(ParamDef).init(self.arena);

        var root = Entries.init(self.arena);
        try add(&root, "openapi", str("3.1.0"));
        try add(&root, "info", try self.info());
        if (api.servers.len > 0) try add(&root, "servers", try self.servers());
        try add(&root, "tags", try self.tags());
        try add(&root, "security", .{ .seq = &.{} });
        const path_node = try self.paths();
        try add(&root, "paths", path_node);
        try add(&root, "components", try self.components());
        const errors = try self.errorCatalogue();
        try add(&root, "x-mopm-errors", errors.codes);
        try add(&root, "x-mopm-error-reasons", errors.reasons);

        var out = std.ArrayList(u8).init(self.arena);
        try out.writer().print(
            "# Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto (sources sha256 {s}); do not edit, run 'zig build gen-api'.\n",
            .{api.sources_sha256},
        );
        try self.renderMap(&out, root.items, 0, false);
        return out.items;
    }

    fn info(self: *Writer) Err!Node {
        const api = self.api;
        var e = Entries.init(self.arena);
        try add(&e, "title", str(api.title));
        try add(&e, "version", str(api.version));
        if (api.summary.len > 0) try add(&e, "summary", str(api.summary));
        if (api.doc.len > 0) try add(&e, "description", str(api.doc));
        var lic = Entries.init(self.arena);
        try add(&lic, "name", str(api.license_name));
        try add(&lic, "identifier", str(api.license_identifier));
        try add(&e, "license", mapNode(lic));
        return mapNode(e);
    }

    fn servers(self: *Writer) Err!Node {
        var items = std.ArrayList(Node).init(self.arena);
        for (self.api.servers) |s| {
            var e = Entries.init(self.arena);
            try add(&e, "url", str(s.url));
            if (s.description.len > 0) try add(&e, "description", str(s.description));
            if (s.variable.len > 0) {
                var v = Entries.init(self.arena);
                try add(&v, "default", str(s.default));
                try add(&v, "enum", try self.strings(s.values));
                var vars = Entries.init(self.arena);
                try add(&vars, s.variable, mapNode(v));
                try add(&e, "variables", mapNode(vars));
            }
            try items.append(mapNode(e));
        }
        return .{ .seq = items.items };
    }

    fn tags(self: *Writer) Err!Node {
        var items = std.ArrayList(Node).init(self.arena);
        for (self.api.tags) |t| {
            var e = Entries.init(self.arena);
            try add(&e, "name", str(t));
            try items.append(mapNode(e));
        }
        return .{ .seq = items.items };
    }

    // ---- paths ----------------------------------------------------------------------------------------------------

    const Group = struct { path: []const u8, ops: Entries };

    fn paths(self: *Writer) Err!Node {
        const api = self.api;
        var groups = std.ArrayList(Group).init(self.arena);
        var ids = std.StringHashMap(void).init(self.arena);
        for (api.rpcs) |rpc| {
            self.where = try std.fmt.allocPrint(self.arena, "rpc {s}", .{rpc.name});
            if (!std.mem.startsWith(u8, rpc.path, api.base_path) or rpc.path.len == api.base_path.len or rpc.path[api.base_path.len] != '/') {
                return self.fail("the path '{s}' does not start with the base path '{s}/'", .{ rpc.path, api.base_path });
            }
            const rel = model.relativePath(api, rpc);
            const id = try model.operationId(self.arena, rpc.name);
            if (ids.contains(id)) return self.fail("the operationId '{s}' is used twice", .{id});
            try ids.put(id, {});
            var group: ?*Group = null;
            for (groups.items) |*g| {
                if (std.mem.eql(u8, g.path, rel)) group = g;
            }
            if (group == null) {
                try groups.append(.{ .path = rel, .ops = Entries.init(self.arena) });
                group = &groups.items[groups.items.len - 1];
            }
            const method = try std.ascii.allocLowerString(self.arena, @tagName(rpc.method));
            if (find(group.?.ops, method) != null) return self.fail("the path '{s}' has two {s} operations", .{ rel, method });
            try add(&group.?.ops, method, try self.operation(rpc, id));
        }
        self.where = "";
        var e = Entries.init(self.arena);
        for (groups.items) |g| try add(&e, g.path, mapNode(g.ops));
        return mapNode(e);
    }

    fn knownTag(self: *Writer, tag: []const u8) bool {
        for (self.api.tags) |t| if (std.mem.eql(u8, t, tag)) return true;
        return false;
    }

    fn knownScheme(self: *Writer, name: []const u8) bool {
        for (self.api.security_schemes) |s| if (std.mem.eql(u8, s.name, name)) return true;
        return false;
    }

    fn operation(self: *Writer, rpc: model.Rpc, id: []const u8) Err!Node {
        const api = self.api;
        var e = Entries.init(self.arena);
        try add(&e, "operationId", str(id));
        for (rpc.tags) |t| if (!self.knownTag(t)) return self.fail("the tag '{s}' is not one of the API's tags", .{t});
        try add(&e, "tags", try self.strings(rpc.tags));
        try add(&e, "summary", str(rpc.summary));
        if (rpc.doc.len > 0) try add(&e, "description", str(rpc.doc));

        var sec = std.ArrayList(Node).init(self.arena);
        for (rpc.security) |s| {
            if (!self.knownScheme(s)) return self.fail("the security scheme '{s}' is not declared", .{s});
            var one = Entries.init(self.arena);
            try add(&one, s, .{ .seq = &.{} });
            try sec.append(mapNode(one));
        }
        try add(&e, "security", .{ .seq = sec.items });

        const path_params = try model.pathParams(self.arena, api, rpc);
        const query_params = try model.queryParams(self.arena, api, rpc);
        if (std.mem.count(u8, rpc.path, "{") != path_params.len) return self.fail("a path parameter of '{s}' is not a field of the input", .{rpc.path});
        if (path_params.len + query_params.len > 0) {
            var refs = std.ArrayList(Node).init(self.arena);
            for (path_params) |f| try refs.append(try self.paramRef(rpc, f, "path"));
            for (query_params) |f| try refs.append(try self.paramRef(rpc, f, "query"));
            try add(&e, "parameters", .{ .seq = refs.items });
        }

        if (rpc.body) |b| {
            const input = switch (rpc.input) {
                .message => |i| api.messages[i],
                else => return self.fail("the body '{s}' is a field of no input", .{b}),
            };
            const f = input.field(b) orelse return self.fail("the body '{s}' is not a field of {s}", .{ b, input.name });
            self.where = try std.fmt.allocPrint(self.arena, "rpc {s} body", .{rpc.name});
            const schema = try self.fieldSchema(f, false, 0);
            self.where = try std.fmt.allocPrint(self.arena, "rpc {s}", .{rpc.name});
            var schema_e = Entries.init(self.arena);
            try add(&schema_e, "schema", nodeOf(schema));
            var content = Entries.init(self.arena);
            try add(&content, "application/json", mapNode(schema_e));
            var rb = Entries.init(self.arena);
            try add(&rb, "required", boolean(true));
            try add(&rb, "content", mapNode(content));
            try add(&e, "requestBody", mapNode(rb));
        }

        var responses = Entries.init(self.arena);
        for (rpc.responses) |r| {
            var re = Entries.init(self.arena);
            try add(&re, "description", str(r.description));
            var headers = Entries.init(self.arena);
            for (api.headers) |h| if (h.on_success) try add(&headers, h.wire, try self.refNode("headers", h.name));
            if (headers.items.len > 0) try add(&re, "headers", mapNode(headers));
            const schema_name: ?[]const u8 = if (r.is_error) try self.errorSchemaName() else switch (rpc.output) {
                .empty => null,
                .message => |i| blk: {
                    if (!api.messages[i].topLevel()) return self.fail("the response is the nested message {s}", .{api.messages[i].path});
                    if (self.is_input[i]) return self.fail("the response {s} is also the input of an rpc", .{api.messages[i].name});
                    break :blk api.messages[i].name;
                },
                else => return self.fail("the response is not a message", .{}),
            };
            if (schema_name) |n| {
                var s = Entries.init(self.arena);
                try add(&s, "schema", try self.refNode("schemas", n));
                var c = Entries.init(self.arena);
                try add(&c, "application/json", mapNode(s));
                try add(&re, "content", mapNode(c));
            }
            try add(&responses, try std.fmt.allocPrint(self.arena, "{d}", .{r.status}), mapNode(re));
        }
        try add(&responses, "default", try self.refNode("responses", "Error"));
        try add(&e, "responses", mapNode(responses));
        return mapNode(e);
    }

    fn errorSchemaName(self: *Writer) Err![]const u8 {
        const i = self.api.messageByPath("Error") orelse return self.fail("an rpc answers with an Error but there is no message named Error", .{});
        return self.api.messages[i].name;
    }

    /// The `$ref` to the entry of `components/parameters` of the field `f` of rpc's input; makes the entry on first use.
    fn paramRef(self: *Writer, rpc: model.Rpc, f: model.Field, in: []const u8) Err!Node {
        const name = f.rules.param orelse return self.fail("the {s} parameter '{s}' has no param option", .{ in, f.name });
        self.where = try std.fmt.allocPrint(self.arena, "rpc {s} parameter {s}", .{ rpc.name, f.name });
        var e = Entries.init(self.arena);
        try add(&e, "name", str(f.name));
        try add(&e, "in", str(in));
        try add(&e, "required", boolean(std.mem.eql(u8, in, "path")));
        if (f.doc.len > 0) try add(&e, "description", str(f.doc));
        try add(&e, "schema", nodeOf(try self.fieldSchema(f, false, 0)));
        const text = try self.nodeText(mapNode(e));
        for (self.params.items) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            if (!std.mem.eql(u8, p.text, text)) return self.fail("the parameter '{s}' is defined differently by rpc {s}", .{ name, p.rpc });
            break;
        } else try self.params.append(.{ .name = name, .node = mapNode(e), .text = text, .rpc = rpc.name });
        self.where = try std.fmt.allocPrint(self.arena, "rpc {s}", .{rpc.name});
        return self.refNode("parameters", name);
    }

    fn nodeText(self: *Writer, node: Node) Err![]const u8 {
        var out = std.ArrayList(u8).init(self.arena);
        try self.renderMap(&out, node.map, 0, false);
        return out.items;
    }

    // ---- components -----------------------------------------------------------------------------------------------

    fn components(self: *Writer) Err!Node {
        const api = self.api;
        var c = Entries.init(self.arena);

        var schemes = Entries.init(self.arena);
        for (api.security_schemes) |s| {
            var e = Entries.init(self.arena);
            try add(&e, "type", str("http"));
            try add(&e, "scheme", str("bearer"));
            try add(&e, "bearerFormat", str(s.bearer_format));
            if (s.description.len > 0) try add(&e, "description", str(s.description));
            try add(&schemes, s.name, mapNode(e));
        }
        try add(&c, "securitySchemes", mapNode(schemes));

        var headers = Entries.init(self.arena);
        for (api.headers) |h| {
            var e = Entries.init(self.arena);
            if (h.description.len > 0) try add(&e, "description", str(h.description));
            if (h.required) try add(&e, "required", boolean(true));
            var s = Entries.init(self.arena);
            try add(&s, "type", str(h.type));
            if (h.min_length) |n| try add(&s, "minLength", try self.int(n));
            if (h.minimum) |n| try add(&s, "minimum", try self.int(n));
            try add(&e, "schema", mapNode(s));
            try add(&headers, h.name, mapNode(e));
        }
        try add(&c, "headers", mapNode(headers));

        var responses = Entries.init(self.arena);
        {
            var e = Entries.init(self.arena);
            try add(&e, "description", str(api.error_response));
            var hs = Entries.init(self.arena);
            for (api.headers) |h| try add(&hs, h.wire, try self.refNode("headers", h.name));
            if (hs.items.len > 0) try add(&e, "headers", mapNode(hs));
            var s = Entries.init(self.arena);
            try add(&s, "schema", try self.refNode("schemas", try self.errorSchemaName()));
            var content = Entries.init(self.arena);
            try add(&content, "application/json", mapNode(s));
            try add(&e, "content", mapNode(content));
            try add(&responses, "Error", mapNode(e));
        }
        try add(&c, "responses", mapNode(responses));

        var params = Entries.init(self.arena);
        for (self.params.items) |p| try add(&params, p.name, p.node);
        try add(&c, "parameters", mapNode(params));

        var schemas = Entries.init(self.arena);
        for (api.order) |d| switch (d) {
            .message => |i| {
                if (self.is_input[i]) continue;
                self.where = api.messages[i].path;
                try add(&schemas, api.messages[i].name, nodeOf(try self.messageSchema(i, 0)));
            },
            .enumeration => |i| {
                self.where = api.enums[i].path;
                try add(&schemas, api.enums[i].name, nodeOf(try self.enumSchema(i)));
            },
        };
        self.where = "";
        try add(&c, "schemas", mapNode(schemas));
        return mapNode(c);
    }

    const Catalogue = struct { codes: Node, reasons: Node };

    fn errorCatalogue(self: *Writer) Err!Catalogue {
        const ec = self.api.errorCodes() orelse return self.fail("there is no enum named ErrorCode", .{});
        var codes = Entries.init(self.arena);
        var reasons = Entries.init(self.arena);
        for (ec.values) |v| {
            const j = (try model.jsonValue(self.arena, ec, v)) orelse continue;
            const err = v.err orelse return self.fail("the ErrorCode value {s} has no error option", .{v.name});
            var e = Entries.init(self.arena);
            try add(&e, "status", try self.int(err.status));
            try add(&e, "message", str(err.message));
            try add(&e, "hint", str(err.hint));
            try add(&codes, j, .{ .flow = e.items });
            if (err.reasons.len > 0) try add(&reasons, j, try self.strings(err.reasons));
        }
        return .{ .codes = mapNode(codes), .reasons = mapNode(reasons) };
    }

    // ---- schemas --------------------------------------------------------------------------------------------------

    fn enumSchema(self: *Writer, i: usize) Err![]Entry {
        const e = self.api.enums[i];
        var out = Entries.init(self.arena);
        if (e.doc.len > 0) try add(&out, "description", str(e.doc));
        try add(&out, "type", str("string"));
        try add(&out, "enum", try self.strings(try model.jsonValues(self.arena, e)));
        return out.items;
    }

    fn messageSchema(self: *Writer, i: usize, depth: u32) Err![]Entry {
        const m = self.api.messages[i];
        const saved = self.where;
        defer self.where = saved;
        self.where = m.path;
        if (depth > max_depth) return self.fail("nested messages refer to each other without end", .{});
        if (m.wrapper and m.is_union) return self.fail("a message cannot be both a wrapper and a union", .{});
        if (m.wrapper) {
            if (m.fields.len != 1 or !std.mem.eql(u8, m.fields[0].name, "value")) return self.fail("a wrapper has exactly one field, named value", .{});
            var e = Entries.fromOwnedSlice(self.arena, try self.fieldSchema(m.fields[0], true, depth));
            try self.describe(&e, m.doc);
            return e.items;
        }
        var out = Entries.init(self.arena);
        if (m.doc.len > 0) try add(&out, "description", str(m.doc));
        if (m.is_union) {
            var alts = std.ArrayList(Node).init(self.arena);
            for (m.fields) |f| {
                self.where = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ m.path, f.name });
                try alts.append(.{ .map = try self.fieldSchema(f, true, depth) });
            }
            try add(&out, "oneOf", .{ .seq = alts.items });
            return out.items;
        }
        try add(&out, "type", str("object"));
        var required = std.ArrayList([]const u8).init(self.arena);
        for (m.fields) |f| if (f.rules.required) try required.append(f.name);
        if (required.items.len > 0) try add(&out, "required", try self.strings(required.items));
        if (m.one_of.len > 0) {
            var alts = std.ArrayList(Node).init(self.arena);
            for (m.one_of) |set| {
                try self.checkFields(m, set.required);
                var one = Entries.init(self.arena);
                try add(&one, "required", try self.strings(set.required));
                try alts.append(mapNode(one));
            }
            try add(&out, "oneOf", .{ .seq = alts.items });
        }
        var props = Entries.init(self.arena);
        for (m.fields) |f| {
            self.where = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ m.path, f.name });
            try add(&props, f.name, .{ .map = try self.fieldSchema(f, true, depth) });
        }
        self.where = m.path;
        try add(&out, "properties", mapNode(props));
        if (m.when) |w| {
            try self.checkFields(m, &.{w.field});
            try self.checkFields(m, w.required);
            const f = m.field(w.field).?;
            var cond = Entries.init(self.arena);
            try add(&cond, "const", try self.typed(f.type, w.equals));
            var prop = Entries.init(self.arena);
            try add(&prop, w.field, mapNode(cond));
            var props_e = Entries.init(self.arena);
            try add(&props_e, "properties", mapNode(prop));
            try add(&out, "if", mapNode(props_e));
            var then = Entries.init(self.arena);
            try add(&then, "required", try self.strings(w.required));
            try add(&out, "then", mapNode(then));
        }
        return out.items;
    }

    fn checkFields(self: *Writer, m: model.Message, names: []const []const u8) Err!void {
        for (names) |n| if (m.field(n) == null) return self.fail("'{s}' is not a field", .{n});
    }

    /// The text `text` as the YAML value of a field of type `t`: an integer, a boolean, or else a string.
    fn typed(self: *Writer, t: model.Type, text: []const u8) Err!Node {
        switch (t) {
            .scalar => |s| {
                if (s.isInteger()) {
                    const n = std.fmt.parseInt(i64, text, 10) catch return self.fail("'{s}' is not an integer", .{text});
                    return self.int(n);
                }
                if (s == .bool) {
                    if (std.mem.eql(u8, text, "true")) return boolean(true);
                    if (std.mem.eql(u8, text, "false")) return boolean(false);
                    return self.fail("'{s}' is not true or false", .{text});
                }
                return str(text);
            },
            else => return str(text),
        }
    }

    fn hasScalarKeywords(r: model.Rules) bool {
        return r.pattern != null or r.min_length != null or r.max_length != null or r.minimum != null or r.maximum != null or
            r.format != null or r.default != null or r.@"const" != null;
    }

    fn hasArrayKeywords(r: model.Rules) bool {
        return r.min_items != null or r.max_items != null or r.unique_items or r.items != null;
    }

    /// The schema of a field: its type and keywords, as a property or a parameter's `schema`. `with_desc`: the field's doc
    /// is the `description` (else the nested type's own, if it has one, is dropped as well).
    fn fieldSchema(self: *Writer, f: model.Field, with_desc: bool, depth: u32) Err![]Entry {
        const r = f.rules;
        var e: Entries = undefined;
        if (f.map) {
            if (hasScalarKeywords(r) or hasArrayKeywords(model.Rules{ .min_items = r.min_items, .max_items = r.max_items, .unique_items = r.unique_items })) {
                return self.fail("a map has no keywords of its own; those of its values are in items", .{});
            }
            e = Entries.init(self.arena);
            try add(&e, "type", str("object"));
            const values = try self.valueSchema(f.type, (r.items orelse &model.Rules{}).*, depth);
            try add(&e, "additionalProperties", .{ .map = values });
            if (r.nullable) try self.makeNullable(&e);
        } else if (f.label == .repeated) {
            if (hasScalarKeywords(r)) return self.fail("a repeated field has no string or number keywords of its own; those of its items are in items", .{});
            e = Entries.init(self.arena);
            try add(&e, "type", str("array"));
            if (r.min_items) |n| try add(&e, "minItems", try self.int(n));
            if (r.max_items) |n| try add(&e, "maxItems", try self.int(n));
            if (r.unique_items) try add(&e, "uniqueItems", boolean(true));
            try add(&e, "items", .{ .map = try self.valueSchema(f.type, (r.items orelse &model.Rules{}).*, depth) });
            if (r.nullable) try self.makeNullable(&e);
        } else {
            if (hasArrayKeywords(r)) return self.fail("a field that is not repeated has no min_items, max_items, unique_items or items", .{});
            e = Entries.fromOwnedSlice(self.arena, try self.valueSchema(f.type, r, depth));
        }
        if (with_desc) try self.describe(&e, f.doc) else undescribe(&e);
        return e.items;
    }

    /// A type with the keywords `r` (and `nullable`), for a field, an item or a map value.
    fn valueSchema(self: *Writer, t: model.Type, r: model.Rules, depth: u32) Err![]Entry {
        if (hasArrayKeywords(r)) return self.fail("min_items, max_items, unique_items and items apply to a repeated field only", .{});
        var e = Entries.fromOwnedSlice(self.arena, try self.typeSchema(t, depth));
        if (r.format) |v| try put(&e, "format", str(v));
        if (r.pattern) |v| try put(&e, "pattern", str(v));
        if (r.min_length) |v| try put(&e, "minLength", try self.int(v));
        if (r.max_length) |v| try put(&e, "maxLength", try self.int(v));
        if (r.minimum) |v| try put(&e, "minimum", try self.int(v));
        if (r.maximum) |v| try put(&e, "maximum", try self.int(v));
        if (r.default) |v| try put(&e, "default", try self.typed(t, v));
        if (r.@"const") |v| try put(&e, "const", try self.typed(t, v));
        if (r.nullable) try self.makeNullable(&e);
        return e.items;
    }

    /// `$ref` becomes `oneOf: [{$ref}, {type: "null"}]`, `type: X` becomes `type: [X, "null"]`, `oneOf` gets a `null` alternative.
    pub fn makeNullable(self: *Writer, e: *Entries) Err!void {
        var null_alt = Entries.init(self.arena);
        try add(&null_alt, "type", str("null"));
        if (find(e.*, "$ref")) |i| {
            var one = Entries.init(self.arena);
            try add(&one, "$ref", str(e.items[i].value.str));
            const alts = try self.arena.alloc(Node, 2);
            alts[0] = mapNode(one);
            alts[1] = mapNode(null_alt);
            e.items[i] = .{ .key = "oneOf", .value = .{ .seq = alts } };
        } else if (find(e.*, "type")) |i| {
            switch (e.items[i].value) {
                .str => |s| {
                    const both = try self.arena.alloc(Node, 2);
                    both[0] = str(s);
                    both[1] = str("null");
                    e.items[i].value = .{ .seq = both };
                },
                else => {},
            }
        } else if (find(e.*, "oneOf")) |i| {
            const old = e.items[i].value.seq;
            const alts = try self.arena.alloc(Node, old.len + 1);
            @memcpy(alts[0..old.len], old);
            alts[old.len] = mapNode(null_alt);
            e.items[i].value = .{ .seq = alts };
        } else return self.fail("a nullable field has no type", .{});
    }

    /// The type alone: a scalar's `type`, a top-level message or enum as `$ref`, a nested one in full.
    fn typeSchema(self: *Writer, t: model.Type, depth: u32) Err![]Entry {
        var e = Entries.init(self.arena);
        switch (t) {
            .scalar => |s| {
                const name: []const u8 = if (s == .string) "string" else if (s == .bool) "boolean" else "integer";
                try add(&e, "type", str(name));
            },
            .message => |i| {
                const m = self.api.messages[i];
                if (!m.topLevel()) return self.messageSchema(i, depth + 1);
                if (self.is_input[i]) return self.fail("{s} is the input of an rpc, not a schema", .{m.name});
                try add(&e, "$ref", str(try std.fmt.allocPrint(self.arena, "#/components/schemas/{s}", .{m.name})));
            },
            .enumeration => |i| {
                const en = self.api.enums[i];
                if (!en.topLevel()) return self.enumSchema(i);
                try add(&e, "$ref", str(try std.fmt.allocPrint(self.arena, "#/components/schemas/{s}", .{en.name})));
            },
            .empty => return self.fail("google.protobuf.Empty is not the type of a field", .{}),
        }
        return e.items;
    }

    // ---- rendering ------------------------------------------------------------------------------------------------

    fn pad(out: *std.ArrayList(u8), n: usize) Err!void {
        try out.appendNTimes(' ', n);
    }

    pub fn plainKey(key: []const u8) bool {
        if (key.len == 0) return false;
        const first = key[0];
        if (!(std.ascii.isAlphabetic(first) or first == '_' or first == '$' or first == '/')) return false;
        for (key[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '/' or c == '{' or c == '}' or c == '.' or c == '-')) return false;
        }
        return true;
    }

    /// Whether `s` reads back as the same string when written plain: a word of letters, digits, `_`, `.` and `-` that starts
    /// with a letter or `_` and is not a word YAML or a reader of it may take for a null or a boolean.
    pub fn plainScalar(s: []const u8) bool {
        if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
        for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
        for ([_][]const u8{ "null", "true", "false", "yes", "no", "on", "off", "y", "n" }) |w| {
            if (std.ascii.eqlIgnoreCase(s, w)) return false;
        }
        return true;
    }

    /// `s` plain when `plainScalar` says it may be, else quoted.
    fn scalar(out: *std.ArrayList(u8), s: []const u8) Err!void {
        if (plainScalar(s)) try out.appendSlice(s) else try quote(out, s);
    }

    pub fn quote(out: *std.ArrayList(u8), s: []const u8) Err!void {
        try out.append('"');
        for (s) |c| switch (c) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => if (c < 0x20 or c == 0x7f) try out.writer().print("\\u{x:0>4}", .{c}) else try out.append(c),
        };
        try out.append('"');
    }

    fn preview(self: *Writer, s: []const u8) Err![]const u8 {
        const first = if (std.mem.indexOfScalar(u8, s, '\n')) |n| s[0..n] else s;
        const cut = if (first.len > 40) first[0..40] else first;
        return std.fmt.allocPrint(self.arena, "\"{s}\"", .{cut});
    }

    /// A string with a newline is written as a literal block; refuse the ones a block would not read back.
    fn checkBlock(self: *Writer, s: []const u8) Err!void {
        const why: []const u8 = blk: {
            if (s[0] == ' ') break :blk "its first line starts with a space";
            if (s[0] == '\n') break :blk "its first line is empty";
            if (s[s.len - 1] == '\n') break :blk "it ends with a newline";
            if (std.mem.indexOfAny(u8, s, "\r\t") != null) break :blk "it holds a tab or a carriage return";
            var it = std.mem.splitScalar(u8, s, '\n');
            while (it.next()) |line| {
                if (line.len > 0 and std.mem.trim(u8, line, " ").len == 0) break :blk "a line of it is only spaces";
            }
            return;
        };
        return self.fail("the text {s} cannot be written as a literal block: {s}", .{ try self.preview(s), why });
    }

    fn renderMap(self: *Writer, out: *std.ArrayList(u8), entries: []const Entry, indent: usize, inline_first: bool) Err!void {
        for (entries, 0..) |e, i| {
            if (!(inline_first and i == 0)) try pad(out, indent);
            if (plainKey(e.key)) try out.appendSlice(e.key) else try quote(out, e.key);
            try out.append(':');
            switch (e.value) {
                .raw => |r| {
                    try out.append(' ');
                    try out.appendSlice(r);
                    try out.append('\n');
                },
                .str => |s| {
                    try out.append(' ');
                    if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                        try self.checkBlock(s);
                        try out.appendSlice("|\n");
                        var it = std.mem.splitScalar(u8, s, '\n');
                        while (it.next()) |line| {
                            if (line.len > 0) {
                                try pad(out, indent + 2);
                                try out.appendSlice(line);
                            }
                            try out.append('\n');
                        }
                    } else {
                        try scalar(out, s);
                        try out.append('\n');
                    }
                },
                .flow => |f| {
                    try out.appendSlice(" { ");
                    for (f, 0..) |fe, k| {
                        if (k > 0) try out.appendSlice(", ");
                        try out.appendSlice(fe.key);
                        try out.appendSlice(": ");
                        switch (fe.value) {
                            .raw => |r| try out.appendSlice(r),
                            .str => |fs| try quote(out, fs),
                            else => return self.fail("a flow mapping holds only scalars", .{}),
                        }
                    }
                    try out.appendSlice(" }\n");
                },
                .map => |m| if (m.len == 0) {
                    try out.appendSlice(" {}\n");
                } else {
                    try out.append('\n');
                    try self.renderMap(out, m, indent + 2, false);
                },
                .seq => |q| if (q.len == 0) {
                    try out.appendSlice(" []\n");
                } else {
                    try out.append('\n');
                    try self.renderSeq(out, q, indent + 2);
                },
            }
        }
    }

    pub fn renderSeq(self: *Writer, out: *std.ArrayList(u8), items: []const Node, indent: usize) Err!void {
        for (items) |item| {
            try pad(out, indent);
            try out.appendSlice("- ");
            switch (item) {
                .raw => |r| try out.appendSlice(r),
                .str => |s| {
                    if (std.mem.indexOfScalar(u8, s, '\n') != null) return self.fail("the text {s} is in a list and has several lines", .{try self.preview(s)});
                    try scalar(out, s);
                },
                .map => |m| if (m.len == 0) {
                    try out.appendSlice("{}");
                } else {
                    try self.renderMap(out, m, indent + 2, true);
                    continue;
                },
                .seq => return self.fail("a list inside a list", .{}),
                .flow => return self.fail("a flow mapping in a list", .{}),
            }
            try out.append('\n');
        }
    }
};
