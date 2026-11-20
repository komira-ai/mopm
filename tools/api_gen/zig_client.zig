//! The Zig client writer of tools/api_gen.zig: `write` turns the model of the registry API (model.zig) into the text of
//! `src/core/registry_v2.zig`, the types, the per-operation request builders and the decoding the command line uses. The
//! command line keeps its own transport (`http.once` / `http.request`); it asks an operation for `target` (the path with
//! its query), `body` (the JSON text, or null) and `decode` (the answer's JSON). A browser operation (model.Rpc.browser) is
//! left out: the website calls it, the command line never does.
//!
//! The generated file imports `std` and the command line's `http.zig` (the types of `send`, `sendOnce` and `call`).
//! Names are those of the TypeScript writer: a nested message or enum is its path without dots (`MeV2.Entry` is `MeV2Entry`), and every declaration is at the top of the file. A name that is not a plain
//! Zig identifier is written `@"..."`.
//!
//! A refusal (two declarations of one name, a name the file's own code uses, a query parameter that is not a scalar, ...)
//! is `error.Invalid`; `writeDiag` also says what is wrong.

const std = @import("std");
const model = @import("model.zig");
/// The part of the generated file that does not depend on the API, written verbatim.
const tail = @import("zig_client_tail.zig").text;
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Invalid};

/// The text of `src/core/registry_v2.zig`; `error.Invalid` for a model it cannot write.
pub fn write(arena: Allocator, api: model.Api) Error![]const u8 {
    var diag: ?[]const u8 = null;
    return writeDiag(arena, api, &diag);
}

/// As `write`; `diag` is set to the reason when the result is `error.Invalid`.
pub fn writeDiag(arena: Allocator, api: model.Api, diag: *?[]const u8) Error![]const u8 {
    var g = Gen{ .arena = arena, .api = api, .out = std.ArrayList(u8).init(arena), .diag = diag };
    try g.run();
    return g.out.items;
}

/// The names the generated file itself declares; a declaration of the API may not take one.
const reserved_names = [_][]const u8{ "std", "Allocator", "sources_sha256", "base_path", "operations", "url", "decode", "decodeError", "isSuccess", "percentEncode", "http", "Result", "send", "sendOnce", "call" };

const Gen = struct {
    arena: Allocator,
    api: model.Api,
    out: std.ArrayList(u8),
    diag: *?[]const u8,

    fn fail(g: *Gen, comptime fmt: []const u8, args: anytype) Error {
        g.diag.* = try std.fmt.allocPrint(g.arena, fmt, args);
        return error.Invalid;
    }

    /// The test of the catalogue: `entry` gives each code its status, message and hint (and none for `unknown`), and
    /// `decodeError` reads each code's error body back, and nothing from a text that is not one.
    fn codesTest(g: *Gen, e: model.Enum, name: []const u8) !void {
        try g.print("test \"{s}.entry is the catalogue, and decodeError reads each code back\" {{\n", .{name});
        try g.print("    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);\n    defer arena_state.deinit();\n    const a = arena_state.allocator();\n", .{});
        for (e.values) |v| {
            const j = (try model.jsonValue(g.arena, e, v)) orelse continue;
            const x = v.err orelse continue;
            const id = std.zig.fmtId(j);
            try g.print("    {{\n        const got = {s}.entry(.{}).?;\n", .{ name, id });
            try g.print("        try std.testing.expectEqual(@as(u16, {d}), got.status);\n", .{x.status});
            try g.print("        try std.testing.expectEqualStrings({s}, got.message);\n", .{try literal(g.arena, x.message)});
            try g.print("        try std.testing.expectEqualStrings({s}, got.hint);\n", .{try literal(g.arena, x.hint)});
            const body = try std.json.stringifyAlloc(g.arena, .{ .@"error" = .{ .code = j, .message = x.message, .hint = x.hint } }, .{});
            try g.print("        const read = decodeError(a, {s}).?.@\"error\";\n", .{try literal(g.arena, body)});
            try g.print("        try std.testing.expectEqual({s}.{}, read.code);\n", .{ name, id });
            try g.print("        try std.testing.expectEqualStrings(got.message, read.message);\n        try std.testing.expectEqualStrings(got.hint, read.hint);\n    }}\n", .{});
        }
        try g.print("    try std.testing.expect({s}.entry(.unknown) == null);\n", .{name});
        const unknown_code = try literal(g.arena, "{\"error\":{\"code\":\"not_a_code\",\"message\":\"m\",\"hint\":\"\"}}");
        try g.print("    try std.testing.expectEqual({s}.unknown, decodeError(a, {s}).?.@\"error\".code);\n", .{ name, unknown_code });
        try g.print("    try std.testing.expect(decodeError(a, \"not json\") == null);\n", .{});
        const no_code = try literal(g.arena, "{\"error\":{\"message\":\"no code\",\"hint\":\"\"}}");
        try g.print("    try std.testing.expect(decodeError(a, {s}) == null);\n", .{no_code});
        try g.print("}}\n\n", .{});
    }

    fn print(g: *Gen, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try g.out.writer().print(fmt, args);
    }

    fn run(g: *Gen) Error!void {
        try g.checkNames();
        try g.print("//! Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto; do not edit, run 'zig build gen-api'.\n\n", .{});
        try g.print("const std = @import(\"std\");\nconst Allocator = std.mem.Allocator;\nconst http = @import(\"http.zig\");\n\n", .{});
        try g.print("pub const sources_sha256 = {s};\n\n", .{try literal(g.arena, g.api.sources_sha256)});
        try g.print("pub const base_path = {s};\n\n", .{try literal(g.arena, g.api.base_path)});
        for (g.api.order) |d| switch (d) {
            .message => |i| try g.writeMessageTree(i),
            .enumeration => |i| try g.writeEnum(i),
        };
        var n_ops: usize = 0;
        for (g.api.rpcs) |rpc| if (!rpc.browser) {
            try g.writeOperation(rpc);
            n_ops += 1;
        };
        try g.print("pub const operations = [_]type{{", .{});
        const pad: []const u8 = if (n_ops > 1) " " else "";
        try g.print("{s}", .{pad});
        var first = true;
        for (g.api.rpcs) |rpc| if (!rpc.browser) {
            try g.print("{s}{s}", .{ if (first) "" else ", ", rpc.name });
            first = false;
        };
        try g.print("{s}}};\n\n", .{pad});
        try g.out.appendSlice(tail);
    }

    /// Every flattened name once, none of them a name of the generated file, and the `Error` message `decodeError` reads.
    fn checkNames(g: *Gen) Error!void {
        var seen = std.StringHashMap(void).init(g.arena);
        for (reserved_names) |n| try seen.put(n, {});
        var has_error = false;
        for (g.api.messages) |m| {
            if (m.parent == null and std.mem.eql(u8, m.name, "Error")) has_error = true;
            try g.claim(&seen, try flat(g.arena, m.path), "message");
        }
        for (g.api.enums) |e| try g.claim(&seen, try flat(g.arena, e.path), "enum");
        for (g.api.rpcs) |rpc| if (!rpc.browser) try g.claim(&seen, rpc.name, "rpc");
        if (!has_error) return g.fail("no top-level message 'Error': decodeError reads it", .{});
    }

    fn claim(g: *Gen, seen: *std.StringHashMap(void), name: []const u8, what: []const u8) Error!void {
        const r = try seen.getOrPut(name);
        if (r.found_existing) return g.fail("{s} '{s}' has a name another declaration or the generated file already has", .{ what, name });
    }

    fn doc(g: *Gen, indent: []const u8, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const t = std.mem.trimRight(u8, line, " \t\r");
            if (t.len == 0) {
                try g.print("{s}///\n", .{indent});
            } else {
                try g.print("{s}/// {s}\n", .{ indent, t });
            }
        }
    }

    fn scalarType(s: model.Scalar) []const u8 {
        return switch (s) {
            .string => "[]const u8",
            .bool => "bool",
            else => "i64",
        };
    }

    fn typeName(g: *Gen, t: model.Type) Allocator.Error![]const u8 {
        return switch (t) {
            .scalar => |s| scalarType(s),
            .message => |i| try flat(g.arena, g.api.messages[i].path),
            .enumeration => |i| try flat(g.arena, g.api.enums[i].path),
            .empty => "void",
        };
    }

    fn fieldType(g: *Gen, f: model.Field) Allocator.Error![]const u8 {
        const t = try g.typeName(f.type);
        if (f.map) return std.fmt.allocPrint(g.arena, "std.json.ArrayHashMap({s})", .{t});
        if (f.label == .repeated) return std.fmt.allocPrint(g.arena, "[]const {s}", .{t});
        return t;
    }

    /// Whether `field` of message `idx` is a path parameter or the body of an rpc taking it: always present in the struct.
    fn always(g: *Gen, idx: usize, name: []const u8) Allocator.Error!bool {
        for (g.api.rpcs) |rpc| {
            const i = switch (rpc.input) {
                .message => |i| i,
                else => continue,
            };
            if (i != idx) continue;
            if (rpc.body) |b| if (std.mem.eql(u8, b, name)) return true;
            for (try model.pathParams(g.arena, g.api, rpc)) |p| if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    fn writeMessageTree(g: *Gen, idx: usize) Error!void {
        try g.writeMessage(idx);
        for (g.api.messages, 0..) |m, i| if (m.parent == idx) try g.writeMessageTree(i);
        for (g.api.enums, 0..) |e, i| if (e.parent == idx) try g.writeEnum(i);
    }

    fn writeMessage(g: *Gen, idx: usize) Error!void {
        const m = g.api.messages[idx];
        const name = try flat(g.arena, m.path);
        try g.doc("", m.doc);
        if (m.wrapper) {
            if (m.fields.len != 1) return g.fail("wrapper '{s}' does not have exactly one field", .{m.path});
            try g.print("pub const {s} = {s};\n\n", .{ name, try g.fieldType(m.fields[0]) });
            return;
        }
        if (m.is_union) return g.writeUnion(idx);
        if (m.fields.len == 0) {
            try g.print("pub const {s} = struct {{}};\n\n", .{name});
            return;
        }
        try g.print("pub const {s} = struct {{\n", .{name});
        for (m.fields) |f| {
            try g.doc("    ", f.doc);
            const t = try g.fieldType(f);
            const required = f.rules.required or try g.always(idx, f.name);
            const nullable = f.rules.nullable and !try g.always(idx, f.name);
            if (required and !nullable) {
                try g.print("    {}: {s},\n", .{ std.zig.fmtId(f.name), t });
            } else if (required) {
                try g.print("    {}: ?{s},\n", .{ std.zig.fmtId(f.name), t });
            } else {
                try g.print("    {}: ?{s} = null,\n", .{ std.zig.fmtId(f.name), t });
            }
        }
        try g.print("}};\n\n", .{});
    }

    fn writeEnum(g: *Gen, idx: usize) Error!void {
        const e = g.api.enums[idx];
        const name = try flat(g.arena, e.path);
        const is_codes = e.parent == null and std.mem.eql(u8, e.name, "ErrorCode");
        try g.doc("", e.doc);
        try g.print("pub const {s} = enum {{\n", .{name});
        for (e.values) |v| {
            const j = (try model.jsonValue(g.arena, e, v)) orelse continue;
            if (std.mem.eql(u8, j, "unknown")) return g.fail("enum '{s}' has the JSON value 'unknown', the tag of a value this client does not know", .{e.path});
            try g.doc("    ", v.doc);
            try g.print("    {},\n", .{std.zig.fmtId(j)});
        }
        try g.print("    /// A value this client does not know.\n    unknown,\n\n", .{});
        try g.print(
            \\    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!{[n]s} {{
            \\        const value = try std.json.innerParse(std.json.Value, a, source, options);
            \\        return jsonParseFromValue(a, value, options);
            \\    }}
            \\
            \\    pub fn jsonParseFromValue(_: Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!{[n]s} {{
            \\        switch (value) {{
            \\            .string => |s| return std.meta.stringToEnum({[n]s}, s) orelse .unknown,
            \\            else => return error.UnexpectedToken,
            \\        }}
            \\    }}
            \\
            \\    pub fn jsonStringify(self: {[n]s}, jw: anytype) !void {{
            \\        try jw.write(@tagName(self));
            \\    }}
            \\
        , .{ .n = name });
        if (is_codes) {
            try g.print(
                \\
                \\    pub const Entry = struct {{ status: u16, message: []const u8, hint: []const u8 }};
                \\
                \\    pub fn entry(code: {[n]s}) ?Entry {{
                \\        return switch (code) {{
                \\
            , .{ .n = name });
            for (e.values) |v| {
                const j = (try model.jsonValue(g.arena, e, v)) orelse continue;
                const x = v.err orelse continue;
                try g.print("            .{} => .{{ .status = {d}, .message = {s}, .hint = {s} }},\n", .{ std.zig.fmtId(j), x.status, try literal(g.arena, x.message), try literal(g.arena, x.hint) });
            }
            try g.print("            else => null,\n        }};\n    }}\n", .{});
        }
        try g.print("}};\n\n", .{});
        if (is_codes) try g.codesTest(e, name);
    }

    const Kind = enum { string, array, object, integer, boolean };

    /// The JSON type of the value of a field of a union.
    fn kindOf(g: *Gen, f: model.Field) Error!Kind {
        if (f.map) return .object;
        if (f.label == .repeated) return .array;
        return switch (f.type) {
            .scalar => |s| if (s == .string) Kind.string else if (s == .bool) Kind.boolean else Kind.integer,
            .enumeration => .string,
            .empty => .object,
            .message => |i| blk: {
                const m = g.api.messages[i];
                if (m.wrapper and m.fields.len == 1) break :blk try g.kindOf(m.fields[0]);
                break :blk .object;
            },
        };
    }

    fn writeUnion(g: *Gen, idx: usize) Error!void {
        const m = g.api.messages[idx];
        const name = try flat(g.arena, m.path);
        try g.print("pub const {s} = union(enum) {{\n", .{name});
        for (m.fields) |f| {
            try g.doc("    ", f.doc);
            if (isConst(f)) {
                try g.print("    {},\n", .{std.zig.fmtId(f.name)});
            } else {
                try g.print("    {}: {s},\n", .{ std.zig.fmtId(f.name), try g.fieldType(f) });
            }
        }
        // The member of each JSON type: only one non-const member for a kind, since the type is all that tells them apart.
        var typed = [_]?model.Field{null} ** 5;
        var uses_parse = false;
        for (m.fields) |f| {
            if (isConst(f)) continue;
            const k = @intFromEnum(try g.kindOf(f));
            if (typed[k] != null) return g.fail("union '{s}': two members hold the same JSON type, '{s}' and '{s}'", .{ m.path, typed[k].?.name, f.name });
            typed[k] = f;
            uses_parse = true;
        }
        try g.print(
            \\
            \\    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!{[n]s} {{
            \\        const value = try std.json.innerParse(std.json.Value, a, source, options);
            \\        return jsonParseFromValue(a, value, options);
            \\    }}
            \\
            \\    pub fn jsonParseFromValue({[pa]s}Allocator, value: std.json.Value, {[po]s}std.json.ParseOptions) std.json.ParseFromValueError!{[n]s} {{
            \\        switch (value) {{
            \\
        , .{ .n = name, .pa = if (uses_parse) "a: " else "_: ", .po = if (uses_parse) "options: " else "_: " });
        var any_const = false;
        for (m.fields) |f| if (isConst(f)) {
            any_const = true;
        };
        const kinds = [_]Kind{ .string, .array, .object, .integer, .boolean };
        const arms = [_][]const u8{ "string", "array", "object", "integer", "bool" };
        for (kinds, arms) |k, arm| {
            const member = typed[@intFromEnum(k)];
            if (k == .string and any_const) {
                try g.print("            .string => |s| {{\n", .{});
                for (m.fields) |f| if (isConst(f)) {
                    try g.print("                if (std.mem.eql(u8, s, {s})) return .{};\n", .{ try literal(g.arena, f.rules.@"const".?), std.zig.fmtId(f.name) });
                };
                if (member) |f| {
                    try g.print("                return .{{ .{} = try std.json.innerParseFromValue({s}, a, value, options) }};\n", .{ std.zig.fmtId(f.name), try g.fieldType(f) });
                } else {
                    try g.print("                return error.UnexpectedToken;\n", .{});
                }
                try g.print("            }},\n", .{});
            } else if (member) |f| {
                try g.print("            .{s} => return .{{ .{} = try std.json.innerParseFromValue({s}, a, value, options) }},\n", .{ arm, std.zig.fmtId(f.name), try g.fieldType(f) });
            }
        }
        try g.print(
            \\            else => return error.UnexpectedToken,
            \\        }}
            \\    }}
            \\
            \\    pub fn jsonStringify(self: {[n]s}, jw: anytype) !void {{
            \\        switch (self) {{
            \\
        , .{ .n = name });
        for (m.fields) |f| {
            if (isConst(f)) {
                try g.print("            .{} => try jw.write({s}),\n", .{ std.zig.fmtId(f.name), try literal(g.arena, f.rules.@"const".?) });
            } else {
                try g.print("            .{} => |v| try jw.write(v),\n", .{std.zig.fmtId(f.name)});
            }
        }
        try g.print("        }}\n    }}\n}};\n\n", .{});
    }

    fn successCount(g: *Gen, rpc: model.Rpc) usize {
        _ = g;
        var n: usize = 0;
        for (rpc.responses) |r| {
            if (!r.is_error) n += 1;
        }
        return n;
    }

    fn writeOperation(g: *Gen, rpc: model.Rpc) Error!void {
        const params = try model.pathParams(g.arena, g.api, rpc);
        const query = try model.queryParams(g.arena, g.api, rpc);
        const rel = model.relativePath(g.api, rpc);
        const op_id = try model.operationId(g.arena, rpc.name);
        const params_type: []const u8 = if (rpc.input == .empty) "struct {}" else try g.typeName(rpc.input);
        try g.doc("", rpc.doc);
        try g.print("pub const {s} = struct {{\n", .{rpc.name});
        try g.print("    pub const operation_id = {s};\n", .{try literal(g.arena, op_id)});
        try g.print("    pub const method: std.http.Method = .{s};\n", .{@tagName(rpc.method)});
        try g.print("    pub const path_template = {s};\n", .{try literal(g.arena, rel)});
        try g.print("    pub const success = [_]u16{{{s}", .{if (g.successCount(rpc) > 1) " " else ""});
        var statuses: usize = 0;
        for (rpc.responses) |r| {
            if (r.is_error) continue;
            try g.print("{s}{d}", .{ if (statuses == 0) "" else ", ", r.status });
            statuses += 1;
        }
        try g.print("{s}}};\n", .{if (statuses > 1) " " else ""});
        try g.print("    pub const Params = {s};\n", .{params_type});
        try g.print("    pub const Response = {s};\n\n", .{try g.typeName(rpc.output)});

        const uses_params = params.len > 0 or query.len > 0;
        try g.print("    pub fn target(arena: Allocator, {s}: Params) Allocator.Error![]const u8 {{\n", .{if (uses_params) "p" else "_"});
        try g.print("        var out = std.ArrayList(u8).init(arena);\n        const w = out.writer();\n", .{});
        // The path: its literal text and each `{name}` encoded.
        var rest = rel;
        while (rest.len > 0) {
            const open = std.mem.indexOfScalar(u8, rest, '{') orelse rest.len;
            if (open > 0) try g.print("        try w.writeAll({s});\n", .{try literal(g.arena, rest[0..open])});
            if (open == rest.len) break;
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return g.fail("rpc {s}: path '{s}' has an unclosed '{{'", .{ rpc.name, rel });
            const pname = rest[open + 1 .. close];
            const f = blk: {
                for (params) |p| if (std.mem.eql(u8, p.name, pname)) break :blk p;
                return g.fail("rpc {s}: path parameter '{s}' is not a field of its input", .{ rpc.name, pname });
            };
            const expr = try std.fmt.allocPrint(g.arena, "p.{}", .{std.zig.fmtId(f.name)});
            try g.writeValue("        ", f, expr, rpc.name);
            rest = rest[close + 1 ..];
        }
        if (query.len > 0) try g.print("        var sep: u8 = '?';\n", .{});
        for (query) |f| {
            if (f.map or f.label == .repeated) return g.fail("rpc {s}: query parameter '{s}' is not a scalar", .{ rpc.name, f.name });
            const field = try std.fmt.allocPrint(g.arena, "p.{}", .{std.zig.fmtId(f.name)});
            if (f.rules.required and !f.rules.nullable) {
                try g.print("        {{\n", .{});
                try g.writeQuery(f, field, rpc.name);
            } else {
                try g.print("        if ({s}) |v| {{\n", .{field});
                try g.writeQuery(f, "v", rpc.name);
            }
            try g.print("        }}\n", .{});
        }
        try g.print("        return out.toOwnedSlice();\n    }}\n\n", .{});

        if (rpc.body) |b| {
            try g.print("    pub fn body(arena: Allocator, p: Params) Allocator.Error!?[]const u8 {{\n", .{});
            try g.print("        return try std.json.stringifyAlloc(arena, p.{}, .{{ .emit_null_optional_fields = false }});\n    }}\n", .{std.zig.fmtId(b)});
        } else {
            try g.print("    pub fn body(_: Allocator, _: Params) Allocator.Error!?[]const u8 {{\n        return null;\n    }}\n", .{});
        }
        try g.print("}};\n\n", .{});
    }

    fn writeQuery(g: *Gen, f: model.Field, expr: []const u8, rpc_name: []const u8) Error!void {
        try g.print("            try w.writeByte(sep);\n            sep = '&';\n            try w.writeAll({s});\n", .{try literal(g.arena, try std.fmt.allocPrint(g.arena, "{s}=", .{f.name}))});
        try g.writeValue("            ", f, expr, rpc_name);
    }

    const ValueKind = enum { string, integer, boolean, enumeration };

    fn valueKind(g: *Gen, t: model.Type) ?ValueKind {
        return switch (t) {
            .scalar => |s| if (s == .string) ValueKind.string else if (s == .bool) ValueKind.boolean else ValueKind.integer,
            .enumeration => .enumeration,
            .empty => null,
            .message => |i| blk: {
                const m = g.api.messages[i];
                if (!m.wrapper or m.fields.len != 1 or m.fields[0].label == .repeated or m.fields[0].map) break :blk null;
                break :blk g.valueKind(m.fields[0].type);
            },
        };
    }

    /// The statement that writes the value of `expr`, a path or query parameter, to `w`.
    fn writeValue(g: *Gen, indent: []const u8, f: model.Field, expr: []const u8, rpc_name: []const u8) Error!void {
        const k = (if (f.map or f.label == .repeated) null else g.valueKind(f.type)) orelse
            return g.fail("rpc {s}: parameter '{s}' is not a string, integer, boolean or enum", .{ rpc_name, f.name });
        switch (k) {
            .string => try g.print("{s}try percentEncode(w, {s});\n", .{ indent, expr }),
            .integer => try g.print("{s}try w.print(\"{{d}}\", .{{{s}}});\n", .{ indent, expr }),
            .boolean => try g.print("{s}try w.writeAll(if ({s}) \"true\" else \"false\");\n", .{ indent, expr }),
            .enumeration => try g.print("{s}try percentEncode(w, @tagName({s}));\n", .{ indent, expr }),
        }
    }
};

fn isConst(f: model.Field) bool {
    return f.rules.@"const" != null and f.type == .scalar and f.type.scalar == .string;
}

/// `MeV2Entry` for `MeV2.Entry`.
fn flat(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, std.mem.replacementSize(u8, path, ".", ""));
    _ = std.mem.replace(u8, path, ".", "", out);
    return out;
}

/// A Zig string literal of `text`.
pub fn literal(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try out.append('"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        '\t' => try out.appendSlice("\\t"),
        '\r' => try out.appendSlice("\\r"),
        0...8, 11, 12, 14...31, 127 => try out.writer().print("\\x{x:0>2}", .{c}),
        else => try out.append(c),
    };
    try out.append('"');
    return out.items;
}

// Tests. `test_api` is a small API with one of every shape the writer handles.

const ns_rules = model.Rules{ .required = true, .min_length = 1 };

pub const test_api: model.Api = .{
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
    .messages = &.{
        // 0
        .{ .name = "Namespace", .path = "Namespace", .doc = "A namespace.", .parent = null, .file = "t.proto", .wrapper = true, .fields = &.{
            .{ .name = "value", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .min_length = 1 } },
        } },
        // 1
        .{ .name = "Keywords", .path = "Keywords", .doc = "", .parent = null, .file = "t.proto", .wrapper = true, .fields = &.{
            .{ .name = "value", .number = 1, .doc = "", .label = .repeated, .type = .{ .scalar = .string } },
        } },
        // 2
        .{ .name = "Error", .path = "Error", .doc = "The error body.", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "error", .number = 1, .doc = "", .label = .single, .type = .{ .message = 3 }, .rules = .{ .required = true } },
        } },
        // 3
        .{ .name = "Body", .path = "Error.Body", .doc = "", .parent = 2, .file = "t.proto", .fields = &.{
            .{ .name = "code", .number = 1, .doc = "The code.\n\nSee the catalogue.", .label = .single, .type = .{ .enumeration = 0 }, .rules = .{ .required = true } },
            .{ .name = "message", .number = 2, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .required = true } },
            .{ .name = "reason", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .required = true, .nullable = true } },
            .{ .name = "hint", .number = 4, .doc = "", .label = .single, .type = .{ .scalar = .string } },
        } },
        // 4
        .{ .name = "TokenPackages", .path = "TokenPackages", .doc = "Names or all.", .parent = null, .file = "t.proto", .is_union = true, .fields = &.{
            .{ .name = "names", .number = 1, .doc = "", .label = .single, .type = .{ .message = 5 }, .oneof = "packages" },
            .{ .name = "all_current", .number = 2, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "packages", .rules = .{ .@"const" = "all_current" } },
        } },
        // 5
        .{ .name = "Names", .path = "TokenPackages.Names", .doc = "", .parent = 4, .file = "t.proto", .wrapper = true, .fields = &.{
            .{ .name = "value", .number = 1, .doc = "", .label = .repeated, .type = .{ .message = 0 } },
        } },
        // 6
        .{ .name = "Health", .path = "Health", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "status", .number = 1, .doc = "", .label = .single, .type = .{ .enumeration = 3 }, .rules = .{ .required = true } },
            .{ .name = "count", .number = 2, .doc = "", .label = .single, .type = .{ .scalar = .int64 } },
            .{ .name = "ok", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .bool } },
        } },
        // 7
        .{ .name = "GetThingParams", .path = "GetThingParams", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "", .label = .single, .type = .{ .message = 0 }, .rules = .{ .param = "namespace" } },
            .{ .name = "limit", .number = 2, .doc = "", .label = .single, .type = .{ .scalar = .int64 } },
            .{ .name = "state", .number = 3, .doc = "", .label = .single, .type = .{ .enumeration = 1 } },
            .{ .name = "flag", .number = 4, .doc = "", .label = .single, .type = .{ .scalar = .bool } },
            .{ .name = "subdir", .number = 5, .doc = "", .label = .single, .type = .{ .enumeration = 2 }, .rules = .{ .required = true } },
            .{ .name = "q", .number = 6, .doc = "", .label = .single, .type = .{ .scalar = .string } },
        } },
        // 8
        .{ .name = "PutThingParams", .path = "PutThingParams", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "", .label = .single, .type = .{ .message = 0 } },
            .{ .name = "body", .number = 2, .doc = "", .label = .single, .type = .{ .message = 9 } },
        } },
        // 9
        .{ .name = "Thing", .path = "Thing", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "packages", .number = 1, .doc = "", .label = .single, .type = .{ .message = 4 } },
            .{ .name = "keywords", .number = 2, .doc = "", .label = .single, .type = .{ .message = 1 } },
            .{ .name = "labels", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .string }, .map = true },
            .{ .name = "subdirs", .number = 4, .doc = "", .label = .repeated, .type = .{ .enumeration = 2 } },
        } },
        // 10
        .{ .name = "DeleteThingParams", .path = "DeleteThingParams", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
            .{ .name = "namespace", .number = 1, .doc = "", .label = .single, .type = .{ .message = 0 } },
        } },
        // 11
        .{ .name = "Nothing", .path = "Nothing", .doc = "", .parent = null, .file = "t.proto", .fields = &.{} },
    },
    .enums = &.{
        .{ .name = "ErrorCode", .path = "ErrorCode", .doc = "", .parent = null, .file = "t.proto", .values = &.{
            .{ .name = "ERROR_CODE_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "ERROR_CODE_INVALID_REQUEST", .number = 1, .doc = "", .err = .{ .status = 400, .message = "Bad \"{name}\".\n", .hint = "Fix it." } },
            .{ .name = "ERROR_CODE_NOT_FOUND", .number = 2, .doc = "No such thing.", .err = .{ .status = 404, .message = "Not found.", .hint = "" } },
        } },
        .{ .name = "VersionState", .path = "VersionState", .doc = "", .parent = null, .file = "t.proto", .values = &.{
            .{ .name = "VERSION_STATE_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "VERSION_STATE_PUBLISHED", .number = 1, .doc = "" },
            .{ .name = "VERSION_STATE_YANKED", .number = 2, .doc = "" },
        } },
        .{ .name = "Subdir", .path = "Subdir", .doc = "", .parent = null, .file = "t.proto", .values = &.{
            .{ .name = "SUBDIR_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "SUBDIR_LINUX_64", .number = 1, .doc = "", .json_option = "linux-64" },
            .{ .name = "SUBDIR_NOARCH", .number = 2, .doc = "" },
        } },
        .{ .name = "Status", .path = "Health.Status", .doc = "", .parent = 6, .file = "t.proto", .values = &.{
            .{ .name = "STATUS_UNSPECIFIED", .number = 0, .doc = "" },
            .{ .name = "STATUS_OK", .number = 1, .doc = "" },
            .{ .name = "STATUS_ERROR", .number = 2, .doc = "" },
        } },
    },
    .order = &.{
        .{ .message = 0 },  .{ .message = 1 }, .{ .enumeration = 0 }, .{ .message = 2 }, .{ .enumeration = 1 }, .{ .enumeration = 2 },
        .{ .message = 4 },  .{ .message = 6 }, .{ .message = 7 },     .{ .message = 8 }, .{ .message = 9 },     .{ .message = 10 },
        .{ .message = 11 },
    },
    .rpcs = &.{
        .{ .name = "GetHealth", .doc = "Health.", .input = .empty, .output = .{ .message = 6 }, .method = .GET, .path = "/api/v2/health", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{.{ .status = 200, .description = "" }} },
        .{ .name = "GetThing", .doc = "", .input = .{ .message = 7 }, .output = .{ .message = 9 }, .method = .GET, .path = "/api/v2/things/{namespace}/info", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{ .{ .status = 200, .description = "" }, .{ .status = 404, .description = "", .is_error = true } } },
        .{ .name = "PutThing", .doc = "", .input = .{ .message = 8 }, .output = .{ .message = 9 }, .method = .PUT, .path = "/api/v2/things/{namespace}", .body = "body", .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{ .{ .status = 200, .description = "" }, .{ .status = 201, .description = "" } } },
        .{ .name = "DeleteThing", .doc = "", .input = .{ .message = 10 }, .output = .empty, .method = .DELETE, .path = "/api/v2/things/{namespace}", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{.{ .status = 204, .description = "" }} },
    },
    .sources_sha256 = "0123abcd",
};

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
    .messages = &.{},
    .enums = &.{},
    .order = &.{},
    .rpcs = &.{},
    .sources_sha256 = "feed",
};

const error_message: model.Message = .{ .name = "Error", .path = "Error", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
    .{ .name = "message", .number = 1, .doc = "Why.", .label = .single, .type = .{ .scalar = .string }, .rules = .{ .required = true } },
} };

/// `messages` (Error first) as an API whose `order` lists them all.
fn withMessages(comptime messages: []const model.Message) model.Api {
    const order = blk: {
        var list: [messages.len]model.Decl = undefined;
        for (&list, 0..) |*d, i| d.* = .{ .message = i };
        break :blk list;
    };
    var api = base;
    api.messages = messages;
    api.order = &order;
    return api;
}

fn mustFail(api: model.Api, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: ?[]const u8 = null;
    try std.testing.expectError(error.Invalid, writeDiag(arena_state.allocator(), api, &diag));
    try std.testing.expectEqualStrings(want, diag.?);
    try std.testing.expectError(error.Invalid, write(arena_state.allocator(), api));
}

fn generated(arena: Allocator, api: model.Api) ![]const u8 {
    const text = try write(arena, api);
    try std.testing.expect(std.mem.endsWith(u8, text, tail));
    return text[0 .. text.len - tail.len];
}

pub const tiny_api: model.Api = blk: {
    var api = withMessages(&.{ error_message, .{ .name = "GetModeParams", .path = "GetModeParams", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
        .{ .name = "id", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string } },
        .{ .name = "mode", .number = 2, .doc = "Which.", .label = .single, .type = .{ .enumeration = 0 } },
        .{ .name = "n", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .int64 } },
    } } });
    api.enums = &.{.{ .name = "Mode", .path = "Mode", .doc = "How.", .parent = null, .file = "t.proto", .values = &.{
        .{ .name = "MODE_UNSPECIFIED", .number = 0, .doc = "" },
        .{ .name = "MODE_FAST", .number = 1, .doc = "Quick." },
    } }};
    api.order = &.{ .{ .message = 0 }, .{ .enumeration = 0 }, .{ .message = 1 } };
    api.rpcs = &.{.{ .name = "GetMode", .doc = "Gets.\nTwice.", .input = .{ .message = 1 }, .output = .empty, .method = .GET, .path = "/api/v2/modes/{id}", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{.{ .status = 204, .description = "" }} }};
    break :blk api;
};

test "a small model is written to exactly this Zig" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        \\//! Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto; do not edit, run 'zig build gen-api'.
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const http = @import("http.zig");
        \\
        \\pub const sources_sha256 = "feed";
        \\
        \\pub const base_path = "/api/v2";
        \\
        \\pub const Error = struct {
        \\    /// Why.
        \\    message: []const u8,
        \\};
        \\
        \\/// How.
        \\pub const Mode = enum {
        \\    /// Quick.
        \\    fast,
        \\    /// A value this client does not know.
        \\    unknown,
        \\
        \\    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Mode {
        \\        const value = try std.json.innerParse(std.json.Value, a, source, options);
        \\        return jsonParseFromValue(a, value, options);
        \\    }
        \\
        \\    pub fn jsonParseFromValue(_: Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!Mode {
        \\        switch (value) {
        \\            .string => |s| return std.meta.stringToEnum(Mode, s) orelse .unknown,
        \\            else => return error.UnexpectedToken,
        \\        }
        \\    }
        \\
        \\    pub fn jsonStringify(self: Mode, jw: anytype) !void {
        \\        try jw.write(@tagName(self));
        \\    }
        \\};
        \\
        \\pub const GetModeParams = struct {
        \\    id: []const u8,
        \\    /// Which.
        \\    mode: ?Mode = null,
        \\    n: ?i64 = null,
        \\};
        \\
        \\/// Gets.
        \\/// Twice.
        \\pub const GetMode = struct {
        \\    pub const operation_id = "getMode";
        \\    pub const method: std.http.Method = .GET;
        \\    pub const path_template = "/modes/{id}";
        \\    pub const success = [_]u16{204};
        \\    pub const Params = GetModeParams;
        \\    pub const Response = void;
        \\
        \\    pub fn target(arena: Allocator, p: Params) Allocator.Error![]const u8 {
        \\        var out = std.ArrayList(u8).init(arena);
        \\        const w = out.writer();
        \\        try w.writeAll("/modes/");
        \\        try percentEncode(w, p.id);
        \\        var sep: u8 = '?';
        \\        if (p.mode) |v| {
        \\            try w.writeByte(sep);
        \\            sep = '&';
        \\            try w.writeAll("mode=");
        \\            try percentEncode(w, @tagName(v));
        \\        }
        \\        if (p.n) |v| {
        \\            try w.writeByte(sep);
        \\            sep = '&';
        \\            try w.writeAll("n=");
        \\            try w.print("{d}", .{v});
        \\        }
        \\        return out.toOwnedSlice();
        \\    }
        \\
        \\    pub fn body(_: Allocator, _: Params) Allocator.Error!?[]const u8 {
        \\        return null;
        \\    }
        \\};
        \\
        \\pub const operations = [_]type{GetMode};
        \\
        \\
    , try generated(arena_state.allocator(), tiny_api));
}

test "the writer's output parses as Zig and is what zig fmt writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]model.Api{ tiny_api, test_api, union_api }) |api| {
        const text = try a.dupeZ(u8, try write(a, api));
        const tree = try std.zig.Ast.parse(a, text, .zig);
        try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
        try std.testing.expectEqualStrings(text, try tree.render(a));
    }
}

test "the model of every shape has its enums, unions, structs and operations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try generated(arena_state.allocator(), test_api);
    const wanted = [_][]const u8{
        "pub const Namespace = []const u8;\n",
        "pub const Keywords = []const []const u8;\n",
        "    @\"linux-64\",\n",
        "    .not_found => .{ .status = 404, .message = \"Not found.\", .hint = \"\" },\n",
        "    .invalid_request => .{ .status = 400, .message = \"Bad \\\"{name}\\\".\\n\", .hint = \"Fix it.\" },\n",
        "pub const TokenPackages = union(enum) {\n    names: TokenPackagesNames,\n    all_current,\n",
        "pub const TokenPackagesNames = []const Namespace;\n",
        "    @\"error\": ErrorBody,\n",
        "    reason: ?[]const u8,\n",
        "    hint: ?[]const u8 = null,\n",
        "pub const HealthStatus = enum {\n",
        "    labels: ?std.json.ArrayHashMap([]const u8) = null,\n",
        "    subdirs: ?[]const Subdir = null,\n",
        "pub const Nothing = struct {};\n",
        "    namespace: Namespace,\n    body: Thing,\n",
        "    pub const success = [_]u16{ 200, 201 };\n",
        "    pub const Response = void;\n",
        "        {\n            try w.writeByte(sep);\n            sep = '&';\n            try w.writeAll(\"subdir=\");\n",
        "        return try std.json.stringifyAlloc(arena, p.body, .{ .emit_null_optional_fields = false });\n",
        "pub const operations = [_]type{ GetHealth, GetThing, PutThing, DeleteThing };\n",
        "test \"ErrorCode.entry is the catalogue, and decodeError reads each code back\" {\n",
        "        const got = ErrorCode.entry(.not_found).?;\n        try std.testing.expectEqual(@as(u16, 404), got.status);\n",
        "        try std.testing.expectEqual(ErrorCode.not_found, read.code);\n",
        "    try std.testing.expect(ErrorCode.entry(.unknown) == null);\n",
        "    try std.testing.expect(decodeError(a, \"not json\") == null);\n",
    };
    for (wanted) |w| {
        std.testing.expect(std.mem.indexOf(u8, text, w) != null) catch |e| {
            std.debug.print("missing: {s}\n", .{w});
            return e;
        };
    }
}

const readme_ref: model.Message = .{ .name = "ReadmeRef", .path = "ReadmeRef", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
    .{ .name = "key", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string } },
} };

/// A union of every JSON kind and a const string.
pub const union_api = withMessages(&.{ error_message, readme_ref, .{ .name = "Readme", .path = "Readme", .doc = "", .parent = null, .file = "t.proto", .is_union = true, .fields = &.{
    .{ .name = "text", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "readme" },
    .{ .name = "object", .number = 2, .doc = "", .label = .single, .type = .{ .message = 1 }, .oneof = "readme" },
    .{ .name = "count", .number = 3, .doc = "", .label = .single, .type = .{ .scalar = .int64 }, .oneof = "readme" },
    .{ .name = "flag", .number = 4, .doc = "", .label = .single, .type = .{ .scalar = .bool }, .oneof = "readme" },
    .{ .name = "list", .number = 5, .doc = "", .label = .repeated, .type = .{ .scalar = .string }, .oneof = "readme" },
    .{ .name = "none", .number = 6, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "readme", .rules = .{ .@"const" = "none" } },
} } });

test "a union reads each JSON kind into its member, a const string first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try generated(arena_state.allocator(), union_api);
    const wanted = [_][]const u8{
        "            .string => |s| {\n                if (std.mem.eql(u8, s, \"none\")) return .none;\n" ++
            "                return .{ .text = try std.json.innerParseFromValue([]const u8, a, value, options) };\n            },\n",
        "            .array => return .{ .list = try std.json.innerParseFromValue([]const []const u8, a, value, options) },\n",
        "            .object => return .{ .object = try std.json.innerParseFromValue(ReadmeRef, a, value, options) },\n",
        "            .integer => return .{ .count = try std.json.innerParseFromValue(i64, a, value, options) },\n",
        "            .bool => return .{ .flag = try std.json.innerParseFromValue(bool, a, value, options) },\n",
        "            .none => try jw.write(\"none\"),\n",
        "            .text => |v| try jw.write(v),\n",
    };
    for (wanted) |w| {
        std.testing.expect(std.mem.indexOf(u8, text, w) != null) catch |e| {
            std.debug.print("missing: {s}\n", .{w});
            return e;
        };
    }
}

test "a union of const strings only names no parameters it does not use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const api = comptime withMessages(&.{ error_message, .{ .name = "Only", .path = "Only", .doc = "", .parent = null, .file = "t.proto", .is_union = true, .fields = &.{
        .{ .name = "one", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "o", .rules = .{ .@"const" = "one" } },
    } } });
    const text = try generated(arena_state.allocator(), api);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub fn jsonParseFromValue(_: Allocator, value: std.json.Value, _: std.json.ParseOptions)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "                return error.UnexpectedToken;\n") != null);
}

test "a browser operation is left out of the client: no struct, not in the operation list, and its name is not checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const site: model.Rpc = .{ .name = "Site", .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/site", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{}, .browser = true };
    var api = tiny_api;
    api.rpcs = &.{ tiny_api.rpcs[0], site };
    const text = try generated(arena_state.allocator(), api);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const Site = struct") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const operations = [_]type{GetMode};\n") != null);
    // `Thing` is a message of test_api: as a client operation its name would be taken.
    var clash = test_api;
    var web = site;
    web.name = "Thing";
    clash.rpcs = &.{web};
    const none = try generated(arena_state.allocator(), clash);
    try std.testing.expect(std.mem.indexOf(u8, none, "pub const operations = [_]type{};\n") != null);
}

test "refusals" {
    var named = test_api;
    named.rpcs = &.{.{ .name = "Thing", .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/x", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(named, "rpc 'Thing' has a name another declaration or the generated file already has");
    named.rpcs = &.{.{ .name = "url", .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/x", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(named, "rpc 'url' has a name another declaration or the generated file already has");
    for ([_][]const u8{ "http", "Result", "send", "sendOnce", "call" }) |taken| {
        named.rpcs = &.{.{ .name = taken, .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/x", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var diag: ?[]const u8 = null;
        try std.testing.expectError(error.Invalid, writeDiag(arena_state.allocator(), named, &diag));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena_state.allocator(), "rpc '{s}' has a name another declaration or the generated file already has", .{taken}), diag.?);
    }

    var no_error = test_api;
    no_error.messages = test_api.messages[0..2];
    try mustFail(no_error, "no top-level message 'Error': decodeError reads it");

    var unknown_value = test_api;
    unknown_value.enums = &.{.{ .name = "Mode", .path = "Mode", .doc = "", .parent = null, .file = "t.proto", .values = &.{
        .{ .name = "MODE_UNSPECIFIED", .number = 0, .doc = "" },
        .{ .name = "MODE_UNKNOWN", .number = 1, .doc = "" },
    } }};
    unknown_value.messages = test_api.messages[0..3];
    unknown_value.order = &.{.{ .enumeration = 0 }};
    try mustFail(unknown_value, "enum 'Mode' has the JSON value 'unknown', the tag of a value this client does not know");

    var two_strings = comptime withMessages(&.{ error_message, .{ .name = "U", .path = "U", .doc = "", .parent = null, .file = "t.proto", .is_union = true, .fields = &.{
        .{ .name = "a", .number = 1, .doc = "", .label = .single, .type = .{ .scalar = .string }, .oneof = "o" },
        .{ .name = "b", .number = 2, .doc = "", .label = .single, .type = .{ .enumeration = 0 }, .oneof = "o" },
    } } });
    two_strings.enums = &.{.{ .name = "E", .path = "E", .doc = "", .parent = null, .file = "t.proto", .values = &.{} }};
    try mustFail(two_strings, "union 'U': two members hold the same JSON type, 'a' and 'b'");

    const wrapper = comptime withMessages(&.{ error_message, .{ .name = "W", .path = "W", .doc = "", .parent = null, .file = "t.proto", .wrapper = true, .fields = &.{} } });
    try mustFail(wrapper, "wrapper 'W' does not have exactly one field");

    var rpcs = tiny_api;
    rpcs.rpcs = &.{.{ .name = "Open", .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/x/{a", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(rpcs, "rpc Open: path '/x/{a' has an unclosed '{'");
    rpcs.rpcs = &.{.{ .name = "Open", .doc = "", .input = .empty, .output = .empty, .method = .GET, .path = "/api/v2/x/{nope}", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(rpcs, "rpc Open: path parameter 'nope' is not a field of its input");
    // GetModeParams has a `mode` enum; as a repeated field or a message it is not a query scalar.
    var repeated = comptime withMessages(&.{ error_message, .{ .name = "P", .path = "P", .doc = "", .parent = null, .file = "t.proto", .fields = &.{
        .{ .name = "xs", .number = 1, .doc = "", .label = .repeated, .type = .{ .scalar = .string } },
    } } });
    repeated.rpcs = &.{.{ .name = "Open", .doc = "", .input = .{ .message = 1 }, .output = .empty, .method = .GET, .path = "/api/v2/x", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(repeated, "rpc Open: query parameter 'xs' is not a scalar");
    var nested = test_api;
    nested.rpcs = &.{.{ .name = "Open", .doc = "", .input = .{ .message = 9 }, .output = .empty, .method = .GET, .path = "/api/v2/x", .body = null, .tags = &.{}, .summary = "", .security = &.{}, .responses = &.{} }};
    try mustFail(nested, "rpc Open: parameter 'packages' is not a string, integer, boolean or enum");
}

test "literal escapes quotes, backslashes and control bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\r\\x01\\x7f\xc3\xa9\"", try literal(arena_state.allocator(), "a\"b\\c\n\t\r\x01\x7f\xc3\xa9"));
}

test "a doc keeps empty lines as bare markers and drops trailing blanks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var g = Gen{ .arena = arena_state.allocator(), .api = base, .out = std.ArrayList(u8).init(arena_state.allocator()), .diag = undefined };
    try g.doc("  ", "one  \n\n two");
    try g.doc("", "");
    try std.testing.expectEqualStrings("  /// one\n  ///\n  ///  two\n", g.out.items);
}
