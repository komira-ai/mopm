//! The structural checks of spec/api/openapi.yaml that stand in for
//! openapi-spec-validator, which validate.py ran and the build cannot (it is
//! Python, and it checks the document against the whole OpenAPI 3.1 meta
//! schema). What this file checks:
//!
//!   - `openapi` is 3.1.x; `info` has a title and a version; `paths` is a
//!     non-empty object of "/..." paths
//!   - every path item has only the keys OpenAPI allows (get, put, post,
//!     delete, patch, options, head, trace, parameters, summary, description,
//!     servers, $ref, x-*), every operation only the operation keys, and an
//!     `operationId` that is a string and unique, and a non-empty `responses`
//!   - every response key is a status code (200), a range (4XX) or `default`,
//!     and every response (after $ref) has a `description`
//!   - every parameter (after $ref) has a `name`, an `in` of path / query /
//!     header / cookie, a `schema` or `content`; a path parameter is
//!     `required: true`; no (name, in) twice in one operation
//!   - the `{name}`s of a path template and its path parameters are the same
//!     set, so no placeholder is unbound and no parameter dangles
//!   - a request body has a `content` object
//!   - every `$ref` anywhere in the document is a local "#/..." pointer that
//!     resolves
//!   - security schemes have a known `type` (and `scheme` for http, `name`
//!     and `in` for apiKey), and every security requirement, global or per
//!     operation, names a scheme that exists
//!   - the variables of a server URL are declared with a default
//!   - EVERY schema the document holds (components.schemas, and the schema
//!     of every parameter, header and media type) passes
//!     jsonschema.checkSchema: only implemented keywords, well-formed values
//!
//! Not checked, because only the full meta schema does: the shape of keys this
//! file has no reason to look at (the contents of `info.license`, `externalDocs`,
//! `callbacks`, `links`, `examples`, `webhooks`), string formats (a URL that is
//! a URL), and the rule that a media type's `example` fits its schema.

const std = @import("std");
const c = @import("contract.zig");
const js = @import("jsonschema.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Problems = c.Problems;

const item_keys = [_][]const u8{ "get", "put", "post", "delete", "patch", "options", "head", "trace", "parameters", "summary", "description", "servers", "$ref" };
const op_keys = [_][]const u8{ "tags", "summary", "description", "externalDocs", "operationId", "parameters", "requestBody", "responses", "callbacks", "deprecated", "security", "servers" };
const scheme_types = [_][]const u8{ "apiKey", "http", "oauth2", "openIdConnect", "mutualTLS" };
const http_methods = [_][]const u8{ "get", "put", "post", "delete", "patch", "options", "head", "trace" };

fn oneOf(set: []const []const u8, key: []const u8) bool {
    for (set) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn isExtension(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "x-");
}

fn validStatusKey(k: []const u8) bool {
    if (std.mem.eql(u8, k, "default")) return true;
    if (k.len != 3 or k[0] < '1' or k[0] > '5') return false;
    if (std.mem.eql(u8, k[1..], "XX")) return true;
    return std.ascii.isDigit(k[1]) and std.ascii.isDigit(k[2]);
}

/// Resolves a "#/..." pointer in `spec`, or null.
fn resolve(spec: Value, ref: []const u8) ?Value {
    if (!std.mem.startsWith(u8, ref, "#/")) return null;
    var cur = spec;
    var parts = std.mem.splitScalar(u8, ref[2..], '/');
    while (parts.next()) |part| cur = c.get(cur, part) orelse return null;
    return cur;
}

const Ctx = struct {
    a: Allocator,
    spec: Value,
    out: *Problems,

    fn bad(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try c.problem(self.a, self.out, fmt, args);
    }

    /// `v` after following `$ref`s; null (and a problem) if one does not resolve.
    fn follow(self: *Ctx, v: Value, where: []const u8) !?Value {
        return c.deref(self.spec, v) catch {
            try self.bad("{s}: a $ref does not resolve", .{where});
            return null;
        };
    }

    fn schemaOf(self: *Ctx, schema: Value, where: []const u8) !void {
        js.checkSchema(self.a, schema, where) catch |err| switch (err) {
            error.UnsupportedKeyword, error.UnsupportedPattern, error.BadSchema => try self.bad("{s}: the schema is refused ({s}, see the message above)", .{ where, @errorName(err) }),
            else => return err,
        };
    }

    fn content(self: *Ctx, node: Value, where: []const u8) !void {
        if (node != .object or node.object.count() == 0) return self.bad("{s}: content is a non-empty object", .{where});
        var it = node.object.iterator();
        while (it.next()) |e| {
            const w = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ where, e.key_ptr.* });
            if (c.get(e.value_ptr.*, "schema")) |s| try self.schemaOf(s, w);
        }
    }

    fn header(self: *Ctx, raw: Value, where: []const u8) !void {
        const h = (try self.follow(raw, where)) orelse return;
        const w = try std.fmt.allocPrint(self.a, "{s}/schema", .{where});
        if (c.get(h, "schema")) |s| {
            try self.schemaOf(s, w);
        } else if (c.get(h, "content") == null) {
            try self.bad("{s}: a header has a schema or content", .{where});
        }
    }

    fn response(self: *Ctx, raw: Value, where: []const u8) !void {
        const r = (try self.follow(raw, where)) orelse return;
        if (c.getStr(r, "description") == null) try self.bad("{s}: a response has a description", .{where});
        if (c.get(r, "content")) |ct| try self.content(ct, try std.fmt.allocPrint(self.a, "{s}/content", .{where}));
        if (c.get(r, "headers")) |hs| {
            if (hs == .object) {
                var it = hs.object.iterator();
                while (it.next()) |e| try self.header(e.value_ptr.*, try std.fmt.allocPrint(self.a, "{s}/headers/{s}", .{ where, e.key_ptr.* }));
            }
        }
    }

    /// A parameter after $ref: its `in`, its name; null if unusable.
    fn parameter(self: *Ctx, raw: Value, where: []const u8) !?Value {
        const p = (try self.follow(raw, where)) orelse return null;
        const name = c.getStr(p, "name") orelse {
            try self.bad("{s}: a parameter has a name", .{where});
            return null;
        };
        const in = c.getStr(p, "in") orelse "";
        if (!oneOf(&.{ "path", "query", "header", "cookie" }, in)) {
            try self.bad("{s}: parameter {s} has 'in' = '{s}'", .{ where, name, in });
            return null;
        }
        if (std.mem.eql(u8, in, "path") and !c.truthy(c.get(p, "required"))) {
            try self.bad("{s}: path parameter {s} must be required: true", .{ where, name });
        }
        if (c.get(p, "schema")) |s| {
            try self.schemaOf(s, try std.fmt.allocPrint(self.a, "{s}/schema", .{where}));
        } else if (c.get(p, "content")) |ct| {
            try self.content(ct, try std.fmt.allocPrint(self.a, "{s}/content", .{where}));
        } else {
            try self.bad("{s}: parameter {s} has a schema or content", .{ where, name });
        }
        return p;
    }

    fn security(self: *Ctx, node: Value, where: []const u8) !void {
        if (node != .array) return self.bad("{s}: security is an array", .{where});
        const schemes = c.get(c.get(self.spec, "components") orelse .null, "securitySchemes") orelse .null;
        for (node.array.items) |req| {
            if (req != .object) {
                try self.bad("{s}: a security requirement is an object", .{where});
                continue;
            }
            var it = req.object.iterator();
            while (it.next()) |e| {
                if (c.get(schemes, e.key_ptr.*) == null) try self.bad("{s}: security scheme {s} is not defined", .{ where, e.key_ptr.* });
            }
        }
    }

    fn refs(self: *Ctx, node: Value, where: []const u8) !void {
        switch (node) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    const w = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ where, e.key_ptr.* });
                    if (std.mem.eql(u8, e.key_ptr.*, "$ref") and e.value_ptr.* == .string) {
                        if (resolve(self.spec, e.value_ptr.*.string) == null) {
                            try self.bad("{s}: $ref {s} does not resolve (only local \"#/...\" pointers are read)", .{ where, e.value_ptr.*.string });
                        }
                    } else {
                        try self.refs(e.value_ptr.*, w);
                    }
                }
            },
            .array => |arr| for (arr.items, 0..) |x, i| try self.refs(x, try std.fmt.allocPrint(self.a, "{s}/{d}", .{ where, i })),
            else => {},
        }
    }
};

/// Adds a problem to `out` for each structural defect of `spec`.
pub fn check(a: Allocator, spec: Value, out: *Problems) !void {
    var cx = Ctx{ .a = a, .spec = spec, .out = out };
    const ver = c.getStr(spec, "openapi") orelse "";
    if (!std.mem.startsWith(u8, ver, "3.1")) try cx.bad("openapi is '{s}', not 3.1.x", .{ver});
    const info = c.get(spec, "info") orelse .null;
    if (c.getStr(info, "title") == null or c.getStr(info, "version") == null) try cx.bad("info needs a title and a version", .{});

    try cx.refs(spec, "#");

    if (c.get(spec, "servers")) |servers| {
        for (servers.array.items) |s| {
            const url = c.getStr(s, "url") orelse {
                try cx.bad("a server has a url", .{});
                continue;
            };
            var rest: []const u8 = url;
            while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
                const v = rest[open + 1 .. close];
                const declared = c.get(c.get(s, "variables") orelse .null, v) orelse .null;
                if (c.getStr(declared, "default") == null) try cx.bad("server variable {s} has no default", .{v});
                rest = rest[close + 1 ..];
            }
        }
    }
    if (c.get(spec, "security")) |sec| try cx.security(sec, "#/security");

    const components = c.get(spec, "components") orelse .null;
    if (c.get(components, "securitySchemes")) |schemes| {
        var it = schemes.object.iterator();
        while (it.next()) |e| {
            const t = c.getStr(e.value_ptr.*, "type") orelse "";
            if (!oneOf(&scheme_types, t)) try cx.bad("security scheme {s} has type '{s}'", .{ e.key_ptr.*, t });
            if (std.mem.eql(u8, t, "http") and c.getStr(e.value_ptr.*, "scheme") == null) try cx.bad("http security scheme {s} has a scheme", .{e.key_ptr.*});
            if (std.mem.eql(u8, t, "apiKey") and (c.getStr(e.value_ptr.*, "name") == null or c.getStr(e.value_ptr.*, "in") == null)) {
                try cx.bad("apiKey security scheme {s} has a name and an in", .{e.key_ptr.*});
            }
        }
    }
    if (c.get(components, "schemas")) |schemas| {
        var it = schemas.object.iterator();
        while (it.next()) |e| try cx.schemaOf(e.value_ptr.*, try std.fmt.allocPrint(a, "components.schemas.{s}", .{e.key_ptr.*}));
    }
    if (c.get(components, "parameters")) |ps| {
        var it = ps.object.iterator();
        while (it.next()) |e| _ = try cx.parameter(e.value_ptr.*, try std.fmt.allocPrint(a, "components.parameters.{s}", .{e.key_ptr.*}));
    }
    if (c.get(components, "headers")) |hs| {
        var it = hs.object.iterator();
        while (it.next()) |e| try cx.header(e.value_ptr.*, try std.fmt.allocPrint(a, "components.headers.{s}", .{e.key_ptr.*}));
    }
    if (c.get(components, "responses")) |rs| {
        var it = rs.object.iterator();
        while (it.next()) |e| try cx.response(e.value_ptr.*, try std.fmt.allocPrint(a, "components.responses.{s}", .{e.key_ptr.*}));
    }

    const paths = c.get(spec, "paths") orelse .null;
    if (paths != .object or paths.object.count() == 0) {
        try cx.bad("paths is a non-empty object", .{});
        return;
    }
    var pit = paths.object.iterator();
    while (pit.next()) |pe| {
        const path = pe.key_ptr.*;
        const where = try std.fmt.allocPrint(a, "paths.{s}", .{path});
        if (!std.mem.startsWith(u8, path, "/")) try cx.bad("{s}: a path starts with '/'", .{where});
        const item = pe.value_ptr.*;
        if (item != .object) {
            try cx.bad("{s}: a path item is an object", .{where});
            continue;
        }
        var kit = item.object.iterator();
        while (kit.next()) |ke| {
            if (!oneOf(&item_keys, ke.key_ptr.*) and !isExtension(ke.key_ptr.*)) try cx.bad("{s}: unknown key '{s}'", .{ where, ke.key_ptr.* });
        }
        // the path-level parameters
        var item_params = std.ArrayList(Value).init(a);
        for (c.getArr(item, "parameters")) |raw| {
            if (try cx.parameter(raw, where)) |p| try item_params.append(p);
        }
        for (http_methods) |m| {
            const op = c.get(item, m) orelse continue;
            const ow = try std.fmt.allocPrint(a, "{s}.{s}", .{ where, m });
            if (op != .object) {
                try cx.bad("{s}: an operation is an object", .{ow});
                continue;
            }
            var oit = op.object.iterator();
            while (oit.next()) |oe| {
                if (!oneOf(&op_keys, oe.key_ptr.*) and !isExtension(oe.key_ptr.*)) try cx.bad("{s}: unknown key '{s}'", .{ ow, oe.key_ptr.* });
            }
            if (c.getStr(op, "operationId") == null) try cx.bad("{s}: an operation has an operationId", .{ow});
            // parameters: the operation's override the path's of the same name and place
            var seen = std.StringHashMap(void).init(a);
            var path_params = std.StringHashMap(void).init(a);
            for (c.getArr(op, "parameters")) |raw| {
                const p = (try cx.parameter(raw, ow)) orelse continue;
                const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ c.getStr(p, "in").?, c.getStr(p, "name").? });
                if (seen.contains(key)) try cx.bad("{s}: parameter {s} is listed twice", .{ ow, key });
                try seen.put(key, {});
                if (std.mem.eql(u8, c.getStr(p, "in").?, "path")) try path_params.put(c.getStr(p, "name").?, {});
            }
            for (item_params.items) |p| {
                const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ c.getStr(p, "in").?, c.getStr(p, "name").? });
                if (seen.contains(key)) continue;
                if (std.mem.eql(u8, c.getStr(p, "in").?, "path")) try path_params.put(c.getStr(p, "name").?, {});
            }
            // template <-> path parameters
            var template = std.StringHashMap(void).init(a);
            var rest: []const u8 = path;
            while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
                try template.put(rest[open + 1 .. close], {});
                rest = rest[close + 1 ..];
            }
            var tit = template.iterator();
            while (tit.next()) |te| {
                if (!path_params.contains(te.key_ptr.*)) try cx.bad("{s}: {{{s}}} in the path has no path parameter", .{ ow, te.key_ptr.* });
            }
            var ppit = path_params.iterator();
            while (ppit.next()) |pp| {
                if (!template.contains(pp.key_ptr.*)) try cx.bad("{s}: path parameter {s} is not in the path template", .{ ow, pp.key_ptr.* });
            }
            if (c.get(op, "requestBody")) |rb_raw| {
                if (try cx.follow(rb_raw, ow)) |rb| {
                    if (c.get(rb, "content")) |ct| {
                        try cx.content(ct, try std.fmt.allocPrint(a, "{s}.requestBody.content", .{ow}));
                    } else {
                        try cx.bad("{s}: a request body has content", .{ow});
                    }
                }
            }
            const responses = c.get(op, "responses") orelse .null;
            if (responses != .object or responses.object.count() == 0) {
                try cx.bad("{s}: responses is a non-empty object", .{ow});
            } else {
                var rit = responses.object.iterator();
                while (rit.next()) |re| {
                    if (!validStatusKey(re.key_ptr.*)) try cx.bad("{s}: '{s}' is not a status code, a range like 4XX, or default", .{ ow, re.key_ptr.* });
                    try cx.response(re.value_ptr.*, try std.fmt.allocPrint(a, "{s}.responses.{s}", .{ ow, re.key_ptr.* }));
                }
            }
            if (c.get(op, "security")) |sec| try cx.security(sec, ow);
        }
    }
}
