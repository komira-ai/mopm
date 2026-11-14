//! The registry commands generated from the API's protos: `mopm <words>` makes one call of one operation of the
//! generated client (core.registry_v2) and prints the answer. The table of commands, with their flags and help texts, is
//! `registry_commands.zig` (written by tools/api_gen.zig); this file runs a command of it.
//!
//! A command takes its positional arguments in the table's order, its flags as `--flag value` or `--flag=value`, and
//! `--registry`, `--config-dir` and `--json` (the answer as JSON instead of text); `--help` prints its help. A mistake in
//! the arguments is `mopm <name>: <what>` and the usage line on standard error, exit 2, and no request is made.
//! A command that needs a token takes `$MOPM_TOKEN` when it is set, else the one `mopm login` stored. A refusal of the
//! registry is printed with its code and its hint (the body's, else the catalogue's); the exit status is 1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const credentials = core.credentials;
const v2 = core.registry_v2;
const gp = @import("group_publish.zig");
const registry_cmd = @import("registry_cmd.zig");
const render = @import("api_render.zig");
const spec = @import("api_spec.zig");
const registry_commands = @import("registry_commands.zig");

/// What the outside world gives a command, so a test needs no socket, no HOME and no environment variable.
pub const Env = struct {
    ctx: *anyopaque,
    /// Resolves `--registry` and `--config-dir` to a session, or says why not (on its own) and returns null.
    open_fn: *const fn (ctx: *anyopaque, arena: Allocator, flags: registry_cmd.Flags, cli_version: []const u8) ?registry_cmd.Session,
    /// `$MOPM_TOKEN`: the token, trimmed, or null when it is not set or empty.
    token_fn: *const fn (ctx: *anyopaque, arena: Allocator) ?[]const u8,
    /// All of standard input.
    stdin_fn: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const u8,
    cli_version: []const u8,
};

var real_marker: u8 = 0;

/// The environment of the real command line.
pub fn realEnv(cli_version: []const u8) Env {
    return .{ .ctx = &real_marker, .open_fn = realOpen, .token_fn = realToken, .stdin_fn = realStdin, .cli_version = cli_version };
}

fn realOpen(_: *anyopaque, arena: Allocator, flags: registry_cmd.Flags, cli_version: []const u8) ?registry_cmd.Session {
    return registry_cmd.open(arena, flags, cli_version);
}

fn realToken(_: *anyopaque, arena: Allocator) ?[]const u8 {
    const raw = std.process.getEnvVarOwned(arena, "MOPM_TOKEN") catch return null;
    const token = std.mem.trim(u8, raw, " \t\r\n");
    return if (token.len == 0) null else token;
}

fn realStdin(_: *anyopaque, arena: Allocator) anyerror![]const u8 {
    return std.io.getStdIn().readToEndAlloc(arena, max_body_bytes);
}

const max_body_bytes: usize = 64 << 20;

/// The number of words of `name` when `args` begins with them, else null.
pub fn wordsMatch(name: []const u8, args: []const []const u8) ?usize {
    var it = std.mem.splitScalar(u8, name, ' ');
    var n: usize = 0;
    while (it.next()) |word| : (n += 1) {
        if (n >= args.len or !std.mem.eql(u8, word, args[n])) return null;
    }
    return n;
}

/// Runs the generated command `args` names (the arguments after `mopm`): the one with the most words that `args` begins
/// with. Null when no generated command has that name.
pub fn run(arena: Allocator, args: []const []const u8, cli_version: []const u8) ?u8 {
    var best: ?usize = null;
    var best_words: usize = 0;
    inline for (registry_commands.commands, 0..) |c, i| {
        if (wordsMatch(c.name, args)) |n| {
            if (n > best_words) {
                best = i;
                best_words = n;
            }
        }
    }
    const index = best orelse return null;
    inline for (registry_commands.commands, 0..) |c, i| {
        if (i == index) return runReal(c, arena, args[best_words..], cli_version);
    }
    return null;
}

fn runReal(comptime c: spec.Command, arena: Allocator, args: []const []const u8, cli_version: []const u8) u8 {
    var con = gp.Console.init(arena, null);
    const code = execute(c, arena, gp.realNet(), &con, realEnv(cli_version), args) catch |e| blk: {
        con.err.writer().print("mopm {s}: {s}\n", .{ c.name, @errorName(e) }) catch {};
        break :blk 1;
    };
    gp.Console.stdStreams(con.out.items, con.err.items);
    return code;
}

/// The lines of the list of commands for the commands whose name starts with the word `word` (`token`), under a line
/// saying that the command is incomplete; null when there is none.
pub fn groupUsage(arena: Allocator, word: []const u8) ?[]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var any = false;
    var lines = std.mem.splitScalar(u8, registry_commands.list, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        const rest = line[2..];
        if (!std.mem.startsWith(u8, rest, word) or rest.len <= word.len or rest[word.len] != ' ') continue;
        if (!any) out.writer().print("mopm {s}: which command?\n", .{word}) catch return null;
        any = true;
        out.writer().print("{s}\n", .{line}) catch return null;
    }
    if (!any) return null;
    return out.items;
}

/// What the arguments of a command came to.
const Parsed = struct {
    flags: registry_cmd.Flags = .{},
    as_json: bool = false,
    body_arg: ?[]const u8 = null,
    positionals: std.ArrayList([]const u8),
    /// The texts given for each flag of the command, in the order of its `flags`.
    given: []std.ArrayListUnmanaged([]const u8),
};

fn usageError(con: *gp.Console, name: []const u8, usage: []const u8, what: []const u8) anyerror!u8 {
    const w = con.err.writer();
    try w.print("mopm {s}: {s}\n", .{ name, what });
    try w.writeAll(usage);
    return 2;
}

/// The value after the flag at `args[i.*]`: the text after `=`, else the next argument (which then is consumed).
fn takeValue(args: []const []const u8, i: *usize, inline_value: ?[]const u8) ?[]const u8 {
    if (inline_value) |v| return v;
    if (i.* + 1 >= args.len) return null;
    const next = args[i.* + 1];
    if (std.mem.startsWith(u8, next, "--")) return null;
    i.* += 1;
    return next;
}

/// Reads the arguments; the message of a usage error, or null.
fn parse(arena: Allocator, flags: []const spec.Flag, takes_body: bool, args: []const []const u8, p: *Parsed) Allocator.Error!?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-") or arg.len == 1) {
            try p.positionals.append(arg);
            continue;
        }
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            inline_value = arg[eq + 1 ..];
        }
        if (std.mem.eql(u8, name, "--json")) {
            if (inline_value != null) return try std.fmt.allocPrint(arena, "--json takes no value", .{});
            p.as_json = true;
            continue;
        }
        const is_registry = std.mem.eql(u8, name, "--registry");
        const is_config_dir = std.mem.eql(u8, name, "--config-dir");
        const is_body = takes_body and std.mem.eql(u8, name, "--body");
        if (is_registry or is_config_dir or is_body) {
            const v = takeValue(args, &i, inline_value) orelse return try std.fmt.allocPrint(arena, "{s} needs a value", .{name});
            if (is_registry) {
                p.flags.registry = v;
            } else if (is_config_dir) {
                p.flags.config_dir = v;
            } else {
                p.body_arg = v;
            }
            continue;
        }
        var found = false;
        for (flags, 0..) |f, fi| {
            if (!std.mem.eql(u8, f.flag, name)) continue;
            found = true;
            if (!f.repeated and p.given[fi].items.len > 0) return try std.fmt.allocPrint(arena, "{s} is given twice", .{name});
            if (f.kind == .boolean) {
                if (inline_value != null) return try std.fmt.allocPrint(arena, "{s} takes no value", .{name});
                try p.given[fi].append(arena, "true");
            } else {
                const v = takeValue(args, &i, inline_value) orelse return try std.fmt.allocPrint(arena, "{s} needs a value", .{name});
                try p.given[fi].append(arena, v);
            }
            break;
        }
        if (!found) return try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg});
    }
    return null;
}

/// `ns/name` as its two parts; null unless it holds exactly one `/` with text on both sides.
fn splitFullName(text: []const u8) ?struct { namespace: []const u8, name: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    if (std.mem.indexOfScalarPos(u8, text, slash + 1, '/') != null) return null;
    if (slash == 0 or slash + 1 == text.len) return null;
    return .{ .namespace = text[0..slash], .name = text[slash + 1 ..] };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// What is wrong with the positional arguments and the flags given; null when nothing is.
fn validate(arena: Allocator, arg_spec: []const spec.Arg, flags: []const spec.Flag, p: *const Parsed) Allocator.Error!?[]const u8 {
    for (arg_spec, 0..) |a, i| {
        if (i >= p.positionals.items.len) {
            if (!a.optional) return try std.fmt.allocPrint(arena, "missing argument {s}", .{a.meta});
            continue;
        }
        const text = p.positionals.items[i];
        if (a.full_name and splitFullName(text) == null) {
            return try std.fmt.allocPrint(arena, "'{s}' is not a full name <namespace>/<name>", .{text});
        }
    }
    if (p.positionals.items.len > arg_spec.len) {
        return try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{p.positionals.items[arg_spec.len]});
    }
    for (flags, 0..) |f, fi| {
        const given = p.given[fi].items;
        if (given.len == 0) {
            if (f.required and f.default == null) return try std.fmt.allocPrint(arena, "missing required option {s} {s}", .{ f.flag, f.meta });
            continue;
        }
        for (given) |v| {
            switch (f.kind) {
                .enumeration => if (!contains(f.values, v)) {
                    const allowed = try std.mem.join(arena, ", ", f.values);
                    return try std.fmt.allocPrint(arena, "{s}: '{s}' is not one of {s}", .{ f.flag, v, allowed });
                },
                .integer => {
                    _ = std.fmt.parseInt(i64, v, 10) catch {
                        return try std.fmt.allocPrint(arena, "{s}: '{s}' is not a whole number", .{ f.flag, v });
                    };
                },
                else => {},
            }
        }
        if (f.kind == .names_or_const and given.len > 1 and contains(given, f.const_value)) {
            return try std.fmt.allocPrint(arena, "{s}: '{s}' cannot be given with names", .{ f.flag, f.const_value });
        }
    }
    return null;
}

fn putIn(root: *std.json.ObjectMap, body: *std.json.ObjectMap, in: spec.In, key: []const u8, v: std.json.Value) Allocator.Error!void {
    switch (in) {
        .params => try root.put(key, v),
        .body => try body.put(key, v),
    }
}

fn scalarValue(kind: spec.Kind, text: []const u8) !std.json.Value {
    return switch (kind) {
        .integer => .{ .integer = try std.fmt.parseInt(i64, text, 10) },
        .boolean => .{ .bool = true },
        .string, .enumeration, .names_or_const => .{ .string = text },
    };
}

/// The request as the JSON object `std.json.parseFromValueLeaky` reads into `Op.Params`: path and query parameters at the
/// top, the body (when it is made of flags) under "body". The arguments are valid (`validate`).
fn buildRoot(arena: Allocator, arg_spec: []const spec.Arg, flags: []const spec.Flag, sets: []const spec.Set, flat_body: bool, cli_version: []const u8, p: *const Parsed) !std.json.ObjectMap {
    var root = std.json.ObjectMap.init(arena);
    var body = std.json.ObjectMap.init(arena);
    for (arg_spec, 0..) |a, i| {
        if (i >= p.positionals.items.len) continue;
        const text = p.positionals.items[i];
        if (a.full_name) {
            const parts = splitFullName(text).?;
            try putIn(&root, &body, a.in, "namespace", .{ .string = parts.namespace });
            try putIn(&root, &body, a.in, "name", .{ .string = parts.name });
        } else {
            try putIn(&root, &body, a.in, a.key, .{ .string = text });
        }
    }
    for (flags, 0..) |f, fi| {
        const given = p.given[fi].items;
        if (given.len == 0) {
            if (f.default) |text| {
                try putIn(&root, &body, f.in, f.key, try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}));
            }
            continue;
        }
        if (f.kind == .names_or_const and given.len == 1 and std.mem.eql(u8, given[0], f.const_value)) {
            try putIn(&root, &body, f.in, f.key, .{ .string = f.const_value });
        } else if (f.repeated) {
            var list = std.json.Array.init(arena);
            for (given) |text| try list.append(try scalarValue(f.kind, text));
            try putIn(&root, &body, f.in, f.key, .{ .array = list });
        } else {
            try putIn(&root, &body, f.in, f.key, try scalarValue(f.kind, given[0]));
        }
    }
    for (sets) |s| {
        const text = try std.mem.replaceOwned(u8, arena, s.json, "{cli_version}", cli_version);
        try body.put(s.key, try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}));
    }
    if (flat_body) try root.put("body", .{ .object = body });
    return root;
}

fn bodyFileError(con: *gp.Console, name: []const u8, path: []const u8, e: anyerror) anyerror!u8 {
    try con.err.writer().print("mopm {s}: --body {s}: {s}\n", .{ name, path, @errorName(e) });
    return 2;
}

/// Prints a refusal: the registry's message, its code and hint, and when to retry and what to report.
fn reportRefusal(arena: Allocator, con: *gp.Console, answer: core.http.Answer) anyerror!void {
    const w = con.err.writer();
    const known = blk: {
        const decoded = v2.decodeError(arena, answer.body) orelse break :blk null;
        if (decoded.@"error".code == .unknown) break :blk null;
        break :blk decoded.@"error";
    };
    if (known) |e| {
        try w.print("mopm: {s}\n", .{e.message});
        try w.print("  code: {s}\n", .{@tagName(e.code)});
        var hint = e.hint;
        if (hint.len == 0) {
            if (v2.ErrorCode.entry(e.code)) |entry| hint = entry.hint;
        }
        if (hint.len > 0) try w.print("  hint: {s}\n", .{hint});
    } else {
        try w.print("mopm: the registry answered HTTP {d}\n", .{answer.status});
    }
    if (answer.retry_after) |s| try w.print("  retry after: {d} seconds\n", .{s});
    if (answer.request_id.len > 0) try w.print("  request id: {s}\n", .{answer.request_id});
}

/// Runs the command `c` with `args` (the arguments after its name): everything it says goes to `con`, the requests to
/// `net`, and what it needs of the world to `env`. The exit status.
pub fn execute(comptime c: spec.Command, arena: Allocator, net: gp.Net, con: *gp.Console, env: Env, args: []const []const u8) anyerror!u8 {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try con.out.writer().writeAll(c.help);
            return 0;
        }
    }

    var p = Parsed{
        .positionals = std.ArrayList([]const u8).init(arena),
        .given = try arena.alloc(std.ArrayListUnmanaged([]const u8), c.flags.len),
    };
    for (p.given) |*g| g.* = .{};
    if (try parse(arena, c.flags, c.body == .file, args, &p)) |what| return usageError(con, c.name, c.usage, what);
    if (try validate(arena, c.args, c.flags, &p)) |what| return usageError(con, c.name, c.usage, what);
    if (c.body == .file and p.body_arg == null) return usageError(con, c.name, c.usage, "missing required option --body <file>");

    var root = try buildRoot(arena, c.args, c.flags, c.set, c.body == .flags, env.cli_version, &p);
    if (c.body == .file) {
        const path = p.body_arg.?;
        const text = (if (std.mem.eql(u8, path, "-"))
            env.stdin_fn(env.ctx, arena)
        else
            std.fs.cwd().readFileAlloc(arena, path, max_body_bytes)) catch |e| return bodyFileError(con, c.name, path, e);
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| return bodyFileError(con, c.name, path, e);
        try root.put("body", value);
    }
    const params = std.json.parseFromValueLeaky(c.Op.Params, arena, .{ .object = root }, .{}) catch |e| {
        if (c.body == .file) return bodyFileError(con, c.name, p.body_arg.?, e);
        const what = try std.fmt.allocPrint(arena, "the request is not valid: {s}", .{@errorName(e)});
        return usageError(con, c.name, c.usage, what);
    };

    const session = env.open_fn(env.ctx, arena, p.flags, env.cli_version) orelse return 1;
    const err = con.err.writer();
    if (session.config.api_v2_url.len == 0) {
        try err.print("mopm: {s} serves no API version 2\n", .{session.config.stage});
        return 1;
    }
    var token: ?[]const u8 = null;
    if (c.token) {
        token = env.token_fn(env.ctx, arena);
        if (token == null) {
            const stored = credentials.load(arena, session.config_dir, session.config.api_url) catch null;
            if (stored) |entry| token = entry.token;
        }
        if (token == null) {
            try err.print("mopm: not logged in to {s}; run 'mopm login'\n", .{session.config.stage});
            return 1;
        }
    }

    const api_root = session.config.api_v2_url;
    const url = try v2.url(c.Op, arena, api_root, params);
    const answer = v2.send(c.Op, arena, net, net.policy, api_root, token, params) catch |e| {
        try err.print("mopm: {s} {s}: {s}\n", .{ @tagName(c.Op.method), url, @errorName(e) });
        return 1;
    };
    if (!answer.ok()) {
        try reportRefusal(arena, con, answer);
        return 1;
    }
    const response = v2.decode(c.Op, arena, answer.body) catch |e| {
        try err.print("mopm: the registry's answer to {s} is not one this mopm reads: {s}\n", .{ c.name, @errorName(e) });
        return 1;
    };

    const out = con.out.writer();
    if (comptime c.Op.Response == void) {
        if (!p.as_json) try out.writeAll("Done.\n");
        return 0;
    } else {
        const json_text = try std.json.stringifyAlloc(arena, response, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
        if (p.as_json) {
            try out.writeAll(json_text);
            try out.writeAll("\n");
            return 0;
        }
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
        try out.writeAll(try render.render(arena, tree));
        return 0;
    }
}
