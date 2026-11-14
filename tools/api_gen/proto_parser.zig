//! The recursive-descent half of proto.zig: `parseFile` reads the tokens of one file into the builder (`Builder`), checking
//! the grammar of the subset of proto3 the registry protos use. Split from proto.zig to keep both files under 1000 lines.

const std = @import("std");
const model = @import("model.zig");
const P = @import("proto.zig");
const Allocator = std.mem.Allocator;
const Source = P.Source;
const Error = P.Error;
const Builder = P.Builder;
const Token = P.Token;
const Value = P.Value;
const Entry = P.Entry;
const SchemaOpt = P.SchemaOpt;
const OperationOpt = P.OperationOpt;
const ApiOpt = P.ApiOpt;
const HttpOpt = P.HttpOpt;
const MsgB = P.MsgB;
const EnumB = P.EnumB;
const RpcB = P.RpcB;
const ServiceB = P.ServiceB;
const Ref = P.Ref;
const TypeRef = P.TypeRef;
const pkg_prefix = P.pkg_prefix;
const tokenize = P.tokenize;
const blank = P.blank;
const isRepeated = P.isRepeated;

/// Reads one file into `b`; a refusal is `error.Bad` with `b.bad` set.
pub fn parseFile(b: *Builder, s: Source) Error!void {
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
