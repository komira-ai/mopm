//! The command-line writer of tools/api_gen.zig: `write` turns the `commands` of every operation (model.Rpc.commands, the
//! `commands` entries of options.proto's `(operation)` option) into the command table `src/cli/registry_commands.zig`
//! (the types are src/cli/api_spec.zig) and the help goldens `tests/golden/registry/*.txt`: the list of commands,
//! `commands.txt`, and the text of `mopm <name> --help`, `<name with '-' for ' '>.txt`.
//!
//! A command's arguments and flags come from the operation's request message: its path and query parameters and, when every
//! field of the body message can be a flag, the fields of the body. A body with a field that cannot be a flag (a message, a
//! repeated message, a map) is sent as `--body <file>` and the command has no body flags. A field can be a flag when it is a
//! string, an integer, a boolean or an enum, a wrapper message of one, a repeated one of these (the flag may be given more
//! than once), or a union of a wrapper of repeated strings and a constant string (`names_or_const`).
//!
//! A refusal (an operation without commands, a command name that is not unique or not made of words of `[a-z][a-z0-9-]*`,
//! an argument, `set` or `defaults` entry that does not fit the request, ...) is `bad`, with the reason naming the rpc.

const std = @import("std");
const model = @import("model.zig");
const literal = @import("zig_client.zig").literal;
const Allocator = std.mem.Allocator;

/// Where the help goldens are, relative to the repository root.
pub const golden_dir = "tests/golden/registry";
/// The generated command table.
pub const table_path = "src/cli/registry_commands.zig";
/// The golden of the list of commands.
pub const list_path = golden_dir ++ "/commands.txt";

/// One generated file: where it goes, relative to the repository root, and its text.
pub const File = struct { path: []const u8, text: []const u8 };

pub const Written = union(enum) {
    /// The table, `commands.txt`, then one golden per command sorted by command name.
    ok: []const File,
    /// What is wrong, naming the rpc.
    bad: []const u8,
};

const Error = Allocator.Error || error{Invalid};

/// The files of the commands of `api`.
pub fn write(arena: Allocator, api: model.Api) Allocator.Error!Written {
    var g = Gen{ .arena = arena, .api = api };
    const files = g.run() catch |e| switch (e) {
        error.Invalid => return .{ .bad = g.diag.? },
        else => |other| return other,
    };
    return .{ .ok = files };
}

/// The name of the golden file of a command: `tests/golden/registry/org-add.txt` for `org add`.
pub fn goldenPath(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const dashed = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, dashed, ' ', '-');
    return std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ golden_dir, dashed });
}

const Kind = enum { string, integer, boolean, enumeration, names_or_const };

const Info = struct {
    kind: Kind,
    values: []const []const u8 = &.{},
    repeated: bool = false,
    const_value: []const u8 = "",
};

const Place = enum { params, body };

const Arg = struct {
    meta: []const u8,
    key: []const u8,
    place: Place,
    full_name: bool,
    optional: bool,
    doc: []const u8,
};

const Flag = struct {
    flag: []const u8,
    meta: []const u8,
    key: []const u8,
    place: Place,
    info: Info,
    required: bool,
    /// The value as the proto writes it, and as JSON.
    default_text: ?[]const u8,
    default_json: ?[]const u8,
    doc: []const u8,
};

const SetValue = struct { key: []const u8, json: []const u8 };

const Mode = enum { none, flags, file };

const Cmd = struct {
    rpc: model.Rpc,
    name: []const u8,
    summary: []const u8,
    mode: Mode,
    args: []const Arg,
    flags: []const Flag,
    sets: []const SetValue,
    usage: []const u8,
    help: []const u8,
};

const Placed = struct { field: model.Field, place: Place, is_path: bool };

const Lookup = union(enum) {
    none,
    found: Placed,
    /// A field of a body that is sent as `--body <file>`.
    file_body,
};

/// What a command is resolved against: the request message and how its body is sent.
const Ctx = struct {
    input: ?model.Message,
    path_params: []const model.Field,
    query_params: []const model.Field,
    body_msg: ?model.Message,
    mode: Mode,
    /// Why the body is a file.
    file_why: []const u8,
    body_type: []const u8,
};

const global_usage = " [--registry <prod|gamma|beta|url>] [--config-dir <dir>] [--json]\n";
const global_options =
    \\  --registry <prod|gamma|beta|url>
    \\      the registry (default prod)
    \\  --config-dir <dir>
    \\      where 'mopm login' keeps credentials.json (default ~/.config/mopm)
    \\  --json
    \\      print the registry's answer as JSON instead of text
    \\
;
const global_flags = [_][]const u8{ "--registry", "--config-dir", "--json", "--body", "--help" };

const list_heading = "registry commands (one call of the registry API each; mopm <command> --help):\n";

const Gen = struct {
    arena: Allocator,
    api: model.Api,
    diag: ?[]const u8 = null,

    fn fail(g: *Gen, comptime fmt: []const u8, args: anytype) Error {
        g.diag = try std.fmt.allocPrint(g.arena, fmt, args);
        return error.Invalid;
    }

    fn failCmd(g: *Gen, rpc: model.Rpc, name: []const u8, comptime fmt: []const u8, args: anytype) Error {
        const why = try std.fmt.allocPrint(g.arena, fmt, args);
        g.diag = try std.fmt.allocPrint(g.arena, "rpc {s}: command '{s}': {s}", .{ rpc.name, name, why });
        return error.Invalid;
    }

    fn run(g: *Gen) Error![]const File {
        try g.checkNames();
        var cmds = std.ArrayList(Cmd).init(g.arena);
        for (g.api.rpcs) |rpc| {
            for (rpc.commands) |c| try cmds.append(try g.resolve(rpc, c));
        }
        var files = std.ArrayList(File).init(g.arena);
        const list = try g.listText(cmds.items);
        try files.append(.{ .path = table_path, .text = try g.tableText(cmds.items, list) });
        try files.append(.{ .path = list_path, .text = list });
        const order = try g.arena.alloc(usize, cmds.items.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, @as([]const Cmd, cmds.items), nameLess);
        for (order) |i| {
            try files.append(.{ .path = try goldenPath(g.arena, cmds.items[i].name), .text = cmds.items[i].help });
        }
        return files.items;
    }

    fn nameLess(cmds: []const Cmd, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, cmds[a].name, cmds[b].name);
    }

    // ---- names ---------------------------------------------------------------------------------------------------

    /// Every operation has commands, every name is words of `[a-z][a-z0-9-]*`, no name is another's or another's first words.
    fn checkNames(g: *Gen) Error!void {
        for (g.api.rpcs) |rpc| {
            if (rpc.commands.len == 0) return g.fail("rpc {s}: has no `commands` in its (operation) option", .{rpc.name});
            for (rpc.commands) |c| {
                var words = std.mem.splitScalar(u8, c.name, ' ');
                while (words.next()) |w| {
                    if (!isWord(w)) return g.fail("rpc {s}: command name '{s}': '{s}' is not a word of [a-z][a-z0-9-]*", .{ rpc.name, c.name, w });
                }
                if (c.summary.len == 0) return g.failCmd(rpc, c.name, "has no summary", .{});
            }
        }
        for (g.api.rpcs, 0..) |ra, ia| {
            for (ra.commands, 0..) |a, ca| {
                for (g.api.rpcs, 0..) |rb, ib| {
                    for (rb.commands, 0..) |b, cb| {
                        if (ia == ib and ca == cb) continue;
                        if (ia > ib or (ia == ib and ca > cb)) continue;
                        if (std.mem.eql(u8, a.name, b.name)) {
                            return g.fail("rpc {s}: command '{s}' is also a command of rpc {s}", .{ ra.name, a.name, rb.name });
                        }
                        if (firstWords(a.name, b.name)) return g.fail("rpc {s}: command '{s}' is the first word(s) of command '{s}' of rpc {s}; a name cannot be both", .{ ra.name, a.name, b.name, rb.name });
                        if (firstWords(b.name, a.name)) return g.fail("rpc {s}: command '{s}' is the first word(s) of command '{s}' of rpc {s}; a name cannot be both", .{ rb.name, b.name, a.name, ra.name });
                        const ga = try goldenPath(g.arena, a.name);
                        const gb = try goldenPath(g.arena, b.name);
                        if (std.mem.eql(u8, ga, gb)) return g.fail("rpc {s}: command '{s}' has the golden file {s} of command '{s}' of rpc {s}", .{ ra.name, a.name, ga, b.name, rb.name });
                    }
                }
            }
        }
    }

    // ---- fields as flags -----------------------------------------------------------------------------------------

    /// What a flag of `f` is, or null when the field cannot be a flag.
    fn flagKind(g: *Gen, f: model.Field) Allocator.Error!?Info {
        if (f.map) return null;
        if (f.label == .repeated) {
            const inner = (try g.typeKind(f.type)) orelse return null;
            if (inner.repeated or inner.kind == .boolean or inner.kind == .names_or_const) return null;
            var out = inner;
            out.repeated = true;
            return out;
        }
        return try g.typeKind(f.type);
    }

    fn typeKind(g: *Gen, t: model.Type) Allocator.Error!?Info {
        switch (t) {
            .scalar => |s| return switch (s) {
                .string => Info{ .kind = .string },
                .bool => Info{ .kind = .boolean },
                else => Info{ .kind = .integer },
            },
            .enumeration => |i| return Info{ .kind = .enumeration, .values = try model.jsonValues(g.arena, g.api.enums[i]) },
            .empty => return null,
            .message => |i| {
                const m = g.api.messages[i];
                if (m.wrapper) {
                    if (m.fields.len != 1) return null;
                    return try g.flagKind(m.fields[0]);
                }
                if (m.is_union) return try g.unionKind(m);
                return null;
            },
        }
    }

    /// A union of a wrapper of repeated strings and a string with a `const`.
    fn unionKind(g: *Gen, m: model.Message) Allocator.Error!?Info {
        if (m.fields.len != 2) return null;
        var const_value: ?[]const u8 = null;
        var names = false;
        for (m.fields) |f| {
            if (isConst(f)) {
                const_value = f.rules.@"const";
            } else if (try g.flagKind(f)) |info| {
                if (info.kind == .string and info.repeated) names = true;
            }
        }
        if (const_value == null or !names) return null;
        return Info{ .kind = .names_or_const, .repeated = true, .const_value = const_value.? };
    }

    fn metaOf(g: *Gen, f: model.Field, info: Info) Allocator.Error![]const u8 {
        var base: []const u8 = switch (info.kind) {
            .string => try std.fmt.allocPrint(g.arena, "<{s}>", .{f.name}),
            .integer => "<n>",
            .boolean => "",
            .enumeration => try std.fmt.allocPrint(g.arena, "<{s}>", .{try std.mem.join(g.arena, "|", info.values)}),
            .names_or_const => return std.fmt.allocPrint(g.arena, "<full name>...|{s}", .{info.const_value}),
        };
        if (info.repeated) base = try std.fmt.allocPrint(g.arena, "{s}...", .{base});
        return base;
    }

    /// The JSON text of `value` for a field of `info`, or null when the field's type does not read it.
    fn valueJson(g: *Gen, info: Info, value: []const u8) Allocator.Error!?[]const u8 {
        switch (info.kind) {
            .string => return try std.json.stringifyAlloc(g.arena, value, .{}),
            .integer => {
                const n = std.fmt.parseInt(i64, value, 10) catch return null;
                return try std.fmt.allocPrint(g.arena, "{d}", .{n});
            },
            .boolean => {
                if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return value;
                return null;
            },
            .enumeration => {
                for (info.values) |v| if (std.mem.eql(u8, v, value)) return try std.json.stringifyAlloc(g.arena, value, .{});
                return null;
            },
            .names_or_const => return null,
        }
    }

    fn valueWhat(g: *Gen, info: Info) Allocator.Error![]const u8 {
        return switch (info.kind) {
            .integer => "an integer",
            .boolean => "true or false",
            .enumeration => try std.fmt.allocPrint(g.arena, "one of {s}", .{try std.mem.join(g.arena, "|", info.values)}),
            else => "a value",
        };
    }

    // ---- one command ---------------------------------------------------------------------------------------------

    fn context(g: *Gen, rpc: model.Rpc) Allocator.Error!Ctx {
        var ctx = Ctx{
            .input = switch (rpc.input) {
                .message => |i| g.api.messages[i],
                else => null,
            },
            .path_params = try model.pathParams(g.arena, g.api, rpc),
            .query_params = try model.queryParams(g.arena, g.api, rpc),
            .body_msg = null,
            .mode = .none,
            .file_why = "",
            .body_type = "",
        };
        const input = ctx.input orelse return ctx;
        const name = rpc.body orelse return ctx;
        const field = input.field(name) orelse return ctx;
        ctx.mode = .file;
        ctx.body_type = switch (field.type) {
            .message => |i| g.api.messages[i].name,
            .scalar => |s| @tagName(s),
            .enumeration => |i| g.api.enums[i].name,
            .empty => "Empty",
        };
        const msg = switch (field.type) {
            .message => |i| g.api.messages[i],
            else => {
                ctx.file_why = "it is not an object of fields";
                return ctx;
            },
        };
        ctx.body_msg = msg;
        if (field.label == .repeated or field.map or msg.wrapper or msg.is_union) {
            ctx.file_why = "it is not an object of fields";
            return ctx;
        }
        for (msg.fields) |f| {
            if ((try g.flagKind(f)) == null) {
                ctx.file_why = try std.fmt.allocPrint(g.arena, "its field '{s}' cannot be a flag", .{f.name});
                return ctx;
            }
        }
        ctx.mode = .flags;
        return ctx;
    }

    fn locate(ctx: Ctx, name: []const u8) Lookup {
        for (ctx.path_params) |f| if (std.mem.eql(u8, f.name, name)) return .{ .found = .{ .field = f, .place = .params, .is_path = true } };
        for (ctx.query_params) |f| if (std.mem.eql(u8, f.name, name)) return .{ .found = .{ .field = f, .place = .params, .is_path = false } };
        if (ctx.body_msg) |bm| {
            if (bm.field(name)) |f| {
                if (ctx.mode == .flags) return .{ .found = .{ .field = f, .place = .body, .is_path = false } };
                return .file_body;
            }
        }
        return .none;
    }

    fn pathParam(ctx: Ctx, name: []const u8) ?model.Field {
        for (ctx.path_params) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    fn isString(g: *Gen, f: model.Field) Allocator.Error!bool {
        const info = (try g.flagKind(f)) orelse return false;
        return info.kind == .string and !info.repeated;
    }

    fn contains(list: []const SetValue, key: []const u8) bool {
        for (list) |s| if (std.mem.eql(u8, s.key, key)) return true;
        return false;
    }

    fn resolve(g: *Gen, rpc: model.Rpc, c: model.Command) Error!Cmd {
        const ctx = try g.context(rpc);
        var args = std.ArrayList(Arg).init(g.arena);
        var arg_names = std.StringHashMap(void).init(g.arena);
        for (c.args) |a| {
            if (arg_names.contains(a)) return g.failCmd(rpc, c.name, "argument '{s}' is named twice", .{a});
            if (std.mem.eql(u8, a, "namespace/name")) {
                const ns = pathParam(ctx, "namespace");
                const nm = pathParam(ctx, "name");
                if (ns == null or nm == null) return g.failCmd(rpc, c.name, "argument 'namespace/name' needs the path parameters 'namespace' and 'name'", .{});
                if (arg_names.contains("namespace") or arg_names.contains("name")) return g.failCmd(rpc, c.name, "argument 'namespace/name' repeats the argument 'namespace' or 'name'", .{});
                if (!try g.isString(ns.?) or !try g.isString(nm.?)) return g.failCmd(rpc, c.name, "argument 'namespace/name' is not made of string fields", .{});
                try arg_names.put("namespace", {});
                try arg_names.put("name", {});
                try arg_names.put(a, {});
                const doc = if (ns.?.doc.len > 0 and nm.?.doc.len > 0)
                    try std.fmt.allocPrint(g.arena, "{s}\n{s}", .{ ns.?.doc, nm.?.doc })
                else if (ns.?.doc.len > 0) ns.?.doc else nm.?.doc;
                try args.append(.{ .meta = "<namespace>/<name>", .key = a, .place = .params, .full_name = true, .optional = false, .doc = doc });
                continue;
            }
            switch (locate(ctx, a)) {
                .none => return g.failCmd(rpc, c.name, "argument '{s}' is not a field of the request (a path parameter, a query parameter or a field of its body)", .{a}),
                .file_body => return g.failCmd(rpc, c.name, "argument '{s}' is a field of the body, which is sent as --body <file> because {s}", .{ a, ctx.file_why }),
                .found => |l| {
                    if (!try g.isString(l.field)) return g.failCmd(rpc, c.name, "argument '{s}' is not a string field", .{a});
                    try arg_names.put(a, {});
                    try args.append(.{
                        .meta = try std.fmt.allocPrint(g.arena, "<{s}>", .{a}),
                        .key = a,
                        .place = l.place,
                        .full_name = false,
                        .optional = !(l.is_path or l.field.rules.required),
                        .doc = l.field.doc,
                    });
                },
            }
        }

        var sets = std.ArrayList(SetValue).init(g.arena);
        for (c.set) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return g.failCmd(rpc, c.name, "'set' entry '{s}' is not field=value", .{entry});
            const field = entry[0..eq];
            const value = entry[eq + 1 ..];
            switch (locate(ctx, field)) {
                .none => return g.failCmd(rpc, c.name, "'set' entry '{s}' is not a field of the body", .{field}),
                .file_body => return g.failCmd(rpc, c.name, "'set' entry '{s}' is a field of the body, which is sent as --body <file> because {s}", .{ field, ctx.file_why }),
                .found => |l| {
                    if (l.place != .body) return g.failCmd(rpc, c.name, "'set' entry '{s}' is not a field of the body", .{field});
                    if (arg_names.contains(field)) return g.failCmd(rpc, c.name, "field '{s}' is both an argument and set", .{field});
                    if (contains(sets.items, field)) return g.failCmd(rpc, c.name, "field '{s}' is set twice", .{field});
                    const info = (try g.flagKind(l.field)).?;
                    if (info.repeated) return g.failCmd(rpc, c.name, "'set' entry '{s}': a repeated flag cannot be set or given a default", .{field});
                    const json = (try g.valueJson(info, value)) orelse return g.failCmd(rpc, c.name, "'set' entry '{s}': '{s}' is not {s}", .{ field, value, try g.valueWhat(info) });
                    try sets.append(.{ .key = field, .json = json });
                },
            }
        }

        var defaults = std.StringHashMap([]const u8).init(g.arena);
        var default_json = std.StringHashMap([]const u8).init(g.arena);
        for (c.defaults) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return g.failCmd(rpc, c.name, "'defaults' entry '{s}' is not field=value", .{entry});
            const field = entry[0..eq];
            const value = entry[eq + 1 ..];
            if (contains(sets.items, field)) return g.failCmd(rpc, c.name, "field '{s}' is both set and given a default", .{field});
            if (defaults.contains(field)) return g.failCmd(rpc, c.name, "field '{s}' is given a default twice", .{field});
            switch (locate(ctx, field)) {
                .none => return g.failCmd(rpc, c.name, "'defaults' entry '{s}' is not a flag of this command", .{field}),
                .file_body => return g.failCmd(rpc, c.name, "'defaults' entry '{s}' is a field of the body, which is sent as --body <file> because {s}", .{ field, ctx.file_why }),
                .found => |l| {
                    if (arg_names.contains(field)) return g.failCmd(rpc, c.name, "'defaults' entry '{s}' is not a flag of this command", .{field});
                    const info = (try g.flagKind(l.field)) orelse return g.failCmd(rpc, c.name, "'defaults' entry '{s}' is not a flag of this command", .{field});
                    if (info.repeated) return g.failCmd(rpc, c.name, "'defaults' entry '{s}': a repeated flag cannot be set or given a default", .{field});
                    const json = (try g.valueJson(info, value)) orelse return g.failCmd(rpc, c.name, "'defaults' entry '{s}': '{s}' is not {s}", .{ field, value, try g.valueWhat(info) });
                    try defaults.put(field, value);
                    try default_json.put(field, json);
                },
            }
        }

        var flags = std.ArrayList(Flag).init(g.arena);
        if (ctx.input) |input| {
            for (input.fields) |f| {
                if (rpc.body) |b| if (std.mem.eql(u8, b, f.name)) continue;
                if (arg_names.contains(f.name)) continue;
                const is_path = pathParam(ctx, f.name) != null;
                const info = (try g.flagKind(f)) orelse return g.failCmd(rpc, c.name, "parameter '{s}' cannot be a flag", .{f.name});
                try flags.append(try g.makeFlag(f, info, .params, is_path, defaults, default_json));
            }
        }
        if (ctx.mode == .flags) {
            for (ctx.body_msg.?.fields) |f| {
                if (arg_names.contains(f.name) or contains(sets.items, f.name)) continue;
                try flags.append(try g.makeFlag(f, (try g.flagKind(f)).?, .body, false, defaults, default_json));
            }
        }
        for (flags.items, 0..) |f, i| {
            for (global_flags) |gf| {
                if (std.mem.eql(u8, f.flag, gf)) return g.failCmd(rpc, c.name, "flag '{s}' is a global option of the command line", .{f.flag});
            }
            for (flags.items[0..i]) |before| {
                if (std.mem.eql(u8, f.flag, before.flag)) return g.failCmd(rpc, c.name, "flag '{s}' is given by two fields", .{f.flag});
            }
        }

        var cmd = Cmd{
            .rpc = rpc,
            .name = c.name,
            .summary = c.summary,
            .mode = ctx.mode,
            .args = args.items,
            .flags = flags.items,
            .sets = sets.items,
            .usage = "",
            .help = "",
        };
        cmd.usage = try g.usageText(cmd);
        cmd.help = try g.helpText(cmd, ctx);
        return cmd;
    }

    fn makeFlag(g: *Gen, f: model.Field, info: Info, place: Place, is_path: bool, defaults: std.StringHashMap([]const u8), default_json: std.StringHashMap([]const u8)) Allocator.Error!Flag {
        const name = try g.arena.dupe(u8, f.name);
        std.mem.replaceScalar(u8, name, '_', '-');
        const default_text = defaults.get(f.name);
        return .{
            .flag = try std.fmt.allocPrint(g.arena, "--{s}", .{name}),
            .meta = try g.metaOf(f, info),
            .key = f.name,
            .place = place,
            .info = info,
            .required = (f.rules.required or is_path) and default_text == null,
            .default_text = default_text,
            .default_json = default_json.get(f.name),
            .doc = f.doc,
        };
    }

    // ---- help ----------------------------------------------------------------------------------------------------

    fn usageText(g: *Gen, cmd: Cmd) Allocator.Error![]const u8 {
        var out = std.ArrayList(u8).init(g.arena);
        const w = out.writer();
        try w.print("usage: mopm {s}", .{cmd.name});
        for (cmd.args) |a| {
            if (a.optional) {
                try w.print(" [{s}]", .{a.meta});
            } else {
                try w.print(" {s}", .{a.meta});
            }
        }
        for (cmd.flags) |f| {
            const core = if (f.meta.len > 0) try std.fmt.allocPrint(g.arena, "{s} {s}", .{ f.flag, f.meta }) else f.flag;
            if (f.required) {
                try w.print(" {s}", .{core});
            } else {
                try w.print(" [{s}]", .{core});
            }
        }
        if (cmd.mode == .file) try w.writeAll(" --body <file>");
        try w.writeAll(global_usage);
        return out.items;
    }

    /// `doc` as lines indented by six spaces, the first after `lead`; no line when both are empty.
    fn docLines(w: anytype, lead: []const u8, doc: []const u8) !void {
        var it = std.mem.splitScalar(u8, doc, '\n');
        var first = true;
        while (it.next()) |line| {
            const text = std.mem.trimRight(u8, line, " \t\r");
            const before = if (first) lead else "";
            first = false;
            if (text.len > 0) {
                try w.print("      {s}{s}\n", .{ before, text });
            } else if (std.mem.trimRight(u8, before, " ").len > 0) {
                try w.print("      {s}\n", .{std.mem.trimRight(u8, before, " ")});
            } else if (doc.len > 0) {
                try w.writeAll("\n");
            }
        }
    }

    fn helpText(g: *Gen, cmd: Cmd, ctx: Ctx) Allocator.Error![]const u8 {
        var out = std.ArrayList(u8).init(g.arena);
        const w = out.writer();
        try w.print("{s}\n{s}\n\n", .{ cmd.usage, cmd.summary });
        if (cmd.rpc.doc.len > 0) try w.print("{s}\n\n", .{cmd.rpc.doc});
        if (cmd.args.len > 0) {
            try w.writeAll("arguments:\n");
            for (cmd.args) |a| {
                try w.print("  {s}\n", .{a.meta});
                try docLines(w, "", a.doc);
            }
        }
        try w.writeAll("options:\n");
        for (cmd.flags) |f| {
            if (f.meta.len > 0) {
                try w.print("  {s} {s}\n", .{ f.flag, f.meta });
            } else {
                try w.print("  {s}\n", .{f.flag});
            }
            var lead = std.ArrayList(u8).init(g.arena);
            if (f.required) try lead.appendSlice("required. ");
            if (f.default_text) |d| try lead.writer().print("default: {s}. ", .{d});
            try docLines(w, lead.items, f.doc);
        }
        if (cmd.mode == .file) {
            try w.print("  --body <file>\n      the request body, JSON (`-`: standard input), as `{s}` of spec/api/openapi-v2.yaml\n", .{ctx.body_type});
        }
        try w.writeAll(global_options);
        const id = try model.operationId(g.arena, cmd.rpc.name);
        try w.print("\nSends {s} {s} ({s})", .{ @tagName(cmd.rpc.method), cmd.rpc.path, id });
        if (cmd.rpc.security.len > 0) try w.writeAll(" with the token 'mopm login' stored, or $MOPM_TOKEN");
        try w.writeAll(".\n");
        return out.items;
    }

    fn listText(g: *Gen, cmds: []const Cmd) Allocator.Error![]const u8 {
        var width: usize = 0;
        for (cmds) |c| width = @max(width, c.name.len);
        var out = std.ArrayList(u8).init(g.arena);
        const w = out.writer();
        try w.writeAll(list_heading);
        for (cmds) |c| {
            try w.print("  {s}", .{c.name});
            for (0..width - c.name.len + 2) |_| try w.writeByte(' ');
            try w.print("{s}\n", .{c.summary});
        }
        return out.items;
    }

    // ---- the table -----------------------------------------------------------------------------------------------

    fn tableText(g: *Gen, cmds: []const Cmd, list: []const u8) Allocator.Error![]const u8 {
        var out = std.ArrayList(u8).init(g.arena);
        const w = out.writer();
        try w.writeAll(
            \\//! Generated by tools/api_gen.zig from spec/api/mopm/registry/v2/*.proto (`zig build gen-api`); do not edit.
            \\//! The registry commands of the command line: one entry per `commands` of an operation's `(operation)` option, run by
            \\//! src/cli/api_cmd.zig.
            \\
            \\const v2 = @import("mopm_core").registry_v2;
            \\const spec = @import("api_spec.zig");
            \\
            \\pub const commands = [_]spec.Command{
            \\
        );
        for (cmds) |c| try g.writeEntry(w, c);
        try w.writeAll("};\n\n");
        try w.print("/// The list of commands `mopm --help` prints, equal to {s}.\n", .{list_path});
        try w.print("pub const list = {s};\n", .{try literal(g.arena, list)});
        return out.items;
    }

    fn writeEntry(g: *Gen, w: anytype, c: Cmd) Allocator.Error!void {
        try w.writeAll("    .{\n");
        try w.print("        .name = {s},\n", .{try literal(g.arena, c.name)});
        try w.print("        .Op = v2.{s},\n", .{c.rpc.name});
        try w.print("        .summary = {s},\n", .{try literal(g.arena, c.summary)});
        try w.print("        .usage = {s},\n", .{try literal(g.arena, c.usage)});
        try w.print("        .help = {s},\n", .{try literal(g.arena, c.help)});
        try w.print("        .token = {s},\n", .{if (c.rpc.security.len > 0) "true" else "false"});
        try w.print("        .body = .{s},\n", .{@tagName(c.mode)});
        if (c.args.len > 0) {
            try w.writeAll("        .args = &.{\n");
            for (c.args) |a| {
                try w.print("            .{{ .meta = {s}, .key = {s}", .{ try literal(g.arena, a.meta), try literal(g.arena, a.key) });
                if (a.place == .body) try w.writeAll(", .in = .body");
                if (a.full_name) try w.writeAll(", .full_name = true");
                if (a.optional) try w.writeAll(", .optional = true");
                try w.writeAll(" },\n");
            }
            try w.writeAll("        },\n");
        }
        if (c.flags.len > 0) {
            try w.writeAll("        .flags = &.{\n");
            for (c.flags) |f| {
                try w.print("            .{{ .flag = {s}, .meta = {s}, .key = {s}, .in = .{s}, .kind = .{s}", .{
                    try literal(g.arena, f.flag),
                    try literal(g.arena, f.meta),
                    try literal(g.arena, f.key),
                    @tagName(f.place),
                    @tagName(f.info.kind),
                });
                if (f.info.values.len > 0) {
                    try w.writeAll(", .values = &.{ ");
                    for (f.info.values, 0..) |v, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(try literal(g.arena, v));
                    }
                    try w.writeAll(" }");
                }
                if (f.required) try w.writeAll(", .required = true");
                if (f.info.repeated) try w.writeAll(", .repeated = true");
                if (f.default_json) |d| try w.print(", .default = {s}", .{try literal(g.arena, d)});
                if (f.info.const_value.len > 0) try w.print(", .const_value = {s}", .{try literal(g.arena, f.info.const_value)});
                try w.writeAll(" },\n");
            }
            try w.writeAll("        },\n");
        }
        if (c.sets.len > 0) {
            try w.writeAll("        .set = &.{\n");
            for (c.sets) |s| try w.print("            .{{ .key = {s}, .json = {s} }},\n", .{ try literal(g.arena, s.key), try literal(g.arena, s.json) });
            try w.writeAll("        },\n");
        }
        try w.writeAll("    },\n");
    }
};

fn isWord(w: []const u8) bool {
    if (w.len == 0 or !std.ascii.isLower(w[0])) return false;
    for (w) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// Whether `prefix` is the first word(s) of `name`, and not all of it.
fn firstWords(prefix: []const u8, name: []const u8) bool {
    return name.len > prefix.len and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == ' ';
}

fn isConst(f: model.Field) bool {
    return f.rules.@"const" != null and f.type == .scalar and f.type.scalar == .string;
}
