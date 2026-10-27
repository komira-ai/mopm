//! The registry contract checks, in Zig, shared by the drivers that need
//! them (contract_test.zig, replay_test.zig, lock_golden_test.zig,
//! resolve_e2e_test.zig). The library half of
//! the contract checks: what an API case must satisfy (`caseProblems`),
//! the rules of a lock that JSON Schema cannot express (`lockProblems`), the
//! rules of an index file (`indexProblems`). The schema checks themselves are
//! jsonschema.zig's.
//!
//! Problems are returned as strings, one per defect; an empty list is a pass.

const std = @import("std");
const js = @import("jsonschema.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Problems = std.ArrayList([]const u8);

pub fn problem(a: Allocator, list: *Problems, comptime fmt: []const u8, args: anytype) !void {
    try list.append(try std.fmt.allocPrint(a, fmt, args));
}

// ------------------------------------------------------------ JSON access

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    const f = get(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

pub fn getArr(v: Value, key: []const u8) []const Value {
    const f = get(v, key) orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

pub fn truthy(v: ?Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| s.len != 0,
        .array => |arr| arr.items.len != 0,
        .object => |o| o.count() != 0,
        .number_string => true,
    };
}

pub fn parseJson(a: Allocator, bytes: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, bytes, .{})).value;
}

pub fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 64 << 20);
}

pub fn loadJson(a: Allocator, path: []const u8) !Value {
    const bytes = try readFile(a, path);
    return parseJson(a, bytes) catch |err| {
        std.debug.print("{s}: not JSON: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// The names of the files in `dir` ending in `suffix`, sorted.
pub fn listFiles(a: Allocator, dir: []const u8, suffix: []const u8) ![]const []const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
    defer d.close();
    var names = std.ArrayList([]const u8).init(a);
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, suffix)) try names.append(try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);
    return names.items;
}

/// The paths of every file below `dir` whose name ends in `suffix`, sorted.
pub fn walkFiles(a: Allocator, dir: []const u8, suffix: []const u8) ![]const []const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
    defer d.close();
    var walker = try d.walk(a);
    defer walker.deinit();
    var paths = std.ArrayList([]const u8).init(a);
    while (try walker.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.path, suffix)) {
            try paths.append(try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, e.path }));
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessStr);
    return paths.items;
}

pub fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn lessThan3(x: [3][]const u8, y: [3][]const u8) std.math.Order {
    for (x, y) |p, q| {
        const o = std.mem.order(u8, p, q);
        if (o != .eq) return o;
    }
    return .eq;
}

/// A deep copy, so a variant can be changed without touching the original.
pub fn clone(a: Allocator, v: Value) anyerror!Value {
    switch (v) {
        .array => |arr| {
            var out = std.json.Array.init(a);
            for (arr.items) |x| try out.append(try clone(a, x));
            return .{ .array = out };
        },
        .object => |obj| {
            var out = std.json.ObjectMap.init(a);
            var it = obj.iterator();
            while (it.next()) |e| try out.put(e.key_ptr.*, try clone(a, e.value_ptr.*));
            return .{ .object = out };
        },
        else => return v,
    }
}

fn short(s: []const u8) []const u8 {
    return if (s.len > 200) s[0..200] else s;
}

// ----------------------------------------------------------- schema checks

/// Every way `inst` violates `schema`; `$ref`s are relative to `root`.
pub fn schemaErrors(a: Allocator, root: Value, schema: Value, inst: Value) !js.Errors {
    const v = js.Validator{ .a = a, .root = root };
    return v.errors(schema, inst);
}

/// Appends the errors of `inst` against `schema`, each prefixed by `prefix`.
fn addSchemaProblems(a: Allocator, list: *Problems, root: Value, schema: Value, inst: Value, comptime fmt: []const u8, args: anytype) !void {
    const errs = try schemaErrors(a, root, schema, inst);
    for (errs.items) |e| {
        const head = try std.fmt.allocPrint(a, fmt, args);
        try list.append(try std.fmt.allocPrint(a, "{s}{s}", .{ head, short(e) }));
    }
}

// ------------------------------------------------------------ the lock rules

/// The rules of spec/lock.md that the schema cannot express. `doc` has
/// passed the schema.
pub fn lockProblems(a: Allocator, doc: Value) !Problems {
    var out = Problems.init(a);
    const pk = getArr(doc, "packages");
    // Strictly sorted by (name, version, subdir): that is, sorted and unique.
    var k: usize = 1;
    while (k < pk.len) : (k += 1) {
        const prev = [3][]const u8{ getStr(pk[k - 1], "name") orelse "", getStr(pk[k - 1], "version") orelse "", getStr(pk[k - 1], "subdir") orelse "" };
        const cur = [3][]const u8{ getStr(pk[k], "name") orelse "", getStr(pk[k], "version") orelse "", getStr(pk[k], "subdir") orelse "" };
        if (lessThan3(prev, cur) != .lt) {
            try out.append("packages are not strictly sorted by (name, version, subdir)");
            break;
        }
    }
    var channels = std.StringHashMap(void).init(a);
    for (getArr(doc, "channels")) |c| if (c == .string) try channels.put(c.string, {});
    var names = std.StringHashMap(void).init(a);
    for (pk) |p| try names.put(getStr(p, "name") orelse "", {});
    const toolchain_mojo = getStr(get(doc, "toolchain") orelse .null, "mojo") orelse "";
    var chans_of = std.StringHashMap(std.StringHashMap(void)).init(a);
    var soname_owner = std.StringHashMap([]const u8).init(a);
    for (pk) |p| {
        const name = getStr(p, "name") orelse "";
        const channel = getStr(p, "channel") orelse "";
        if (!channels.contains(channel)) try problem(a, &out, "{s}: channel {s} is not in channels", .{ name, channel });
        const want = try std.fmt.allocPrint(a, "{s}{s}/mojo-{s}-{s}-{s}.conda", .{
            channel, getStr(p, "subdir") orelse "", name, getStr(p, "version") orelse "", getStr(p, "build") orelse "",
        });
        if (!std.mem.eql(u8, getStr(p, "url") orelse "", want)) try problem(a, &out, "{s}: url is not {s}", .{ name, want });
        const built = getStr(p, "mojo") orelse "";
        if (!std.mem.eql(u8, built, toolchain_mojo)) {
            try problem(a, &out, "{s}: built with mojo {s}, toolchain is {s}", .{ name, built, toolchain_mojo });
        }
        for (getArr(p, "deps")) |d| {
            if (d != .string or !names.contains(d.string)) try problem(a, &out, "{s}: dep {s} is not in packages", .{ name, if (d == .string) d.string else "?" });
        }
        const gop = try chans_of.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(a);
        try gop.value_ptr.put(channel, {});
        for (getArr(p, "native")) |n| {
            const soname = getStr(n, "soname") orelse continue;
            const owner = try soname_owner.getOrPut(soname);
            if (!owner.found_existing) owner.value_ptr.* = name;
            if (!std.mem.eql(u8, owner.value_ptr.*, name)) {
                try problem(a, &out, "soname {s} is shipped by {s} and {s}", .{ soname, owner.value_ptr.*, name });
            }
        }
    }
    var it = chans_of.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.count() > 1) try problem(a, &out, "{s} comes from more than one channel", .{e.key_ptr.*});
    }
    return out;
}

// -------------------------------------------------------- the index rules

/// An index package file: newline-delimited records. `stem` is the file name
/// without its extension.
pub fn indexProblems(a: Allocator, stem: []const u8, text: []const u8, schema: Value) !Problems {
    var out = Problems.init(a);
    if (!std.mem.endsWith(u8, text, "\n")) try out.append("file does not end with a newline (truncated?)");
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(l);
    if (std.mem.endsWith(u8, text, "\n")) _ = lines.pop();
    var versions = std.StringHashMap(void).init(a);
    for (lines.items, 1..) |line, n| {
        if (line.len == 0) {
            try problem(a, &out, "line {d} is blank", .{n});
            continue;
        }
        const rec = parseJson(a, line) catch |err| {
            try problem(a, &out, "line {d} is not JSON: {s}", .{ n, @errorName(err) });
            continue;
        };
        try addSchemaProblems(a, &out, schema, schema, rec, "line {d}: ", .{n});
        const name = getStr(rec, "name");
        if (name == null or !std.mem.eql(u8, name.?, stem)) {
            try problem(a, &out, "line {d}: name {s} differs from the file name {s}", .{ n, name orelse "(none)", stem });
        }
        if (getStr(rec, "version")) |ver| {
            if (versions.contains(ver)) try problem(a, &out, "line {d}: version {s} repeats", .{ n, ver });
            try versions.put(ver, {});
        }
    }
    if (lines.items.len == 0) try out.append("file is empty");
    return out;
}

// ------------------------------------------------------------ API cases

pub const Op = struct { path: []const u8, method: []const u8, op: Value, item: Value };
pub const Ops = std.StringArrayHashMap(Op);

const methods = [_][]const u8{ "get", "put", "post", "delete", "patch" };

/// The operations of `spec` by operationId; a repeated id is added to `dups`.
pub fn operations(a: Allocator, spec: Value, dups: *Problems) !Ops {
    var ops = Ops.init(a);
    const paths = get(spec, "paths") orelse return ops;
    if (paths != .object) return ops;
    var it = paths.object.iterator();
    while (it.next()) |e| {
        for (methods) |m| {
            const op = get(e.value_ptr.*, m) orelse continue;
            const id = getStr(op, "operationId") orelse {
                try problem(a, dups, "{s} {s} has no operationId", .{ m, e.key_ptr.* });
                continue;
            };
            if (ops.contains(id)) {
                try problem(a, dups, "duplicate operationId {s}", .{id});
                continue;
            }
            try ops.put(id, .{ .path = e.key_ptr.*, .method = m, .op = op, .item = e.value_ptr.* });
        }
    }
    return ops;
}

/// Follows local `$ref` chains of a non-schema object.
pub fn deref(spec: Value, node0: Value) !Value {
    var node = node0;
    var seen: usize = 0;
    while (getStr(node, "$ref")) |ref| {
        if (!std.mem.startsWith(u8, ref, "#/")) return error.NonLocalRef;
        var cur = spec;
        var parts = std.mem.splitScalar(u8, ref[2..], '/');
        while (parts.next()) |part| cur = get(cur, part) orelse return error.UnresolvedRef;
        node = cur;
        seen += 1;
        if (seen > 20) return error.RefLoop;
    }
    return node;
}

/// Whether `s` follows `template`, whose `{name}` placeholders each stand for
/// one or more characters (the catalogue's message and hint templates).
pub fn followsTemplate(a: Allocator, template: []const u8, s: []const u8) !bool {
    var parts = std.ArrayList([]const u8).init(a);
    var text = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                const inner = template[i + 1 .. close];
                var ok = inner.len > 0;
                for (inner) |c| {
                    if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) ok = false;
                }
                if (ok) {
                    try parts.append(try a.dupe(u8, text.items));
                    text.clearRetainingCapacity();
                    i = close + 1;
                    continue;
                }
            }
        }
        try text.append(template[i]);
        i += 1;
    }
    try parts.append(text.items);
    return matchParts(parts.items, s);
}

fn matchParts(parts: []const []const u8, s: []const u8) bool {
    if (parts.len == 1) return std.mem.eql(u8, parts[0], s);
    if (!std.mem.startsWith(u8, s, parts[0])) return false;
    const rest = s[parts[0].len..];
    var take: usize = 1;
    while (take <= rest.len) : (take += 1) {
        if (std.mem.indexOfScalar(u8, rest[0..take], '\n') != null) return false;
        if (matchParts(parts[1..], rest[take..])) return true;
    }
    return false;
}

const Param = struct { name: []const u8, p: Value };

/// What an API case violates. `spec` is the parsed openapi.yaml, `catalogue`
/// its x-mopm-errors.
pub fn caseProblems(a: Allocator, spec: Value, ops: Ops, catalogue: Value, case: Value) !Problems {
    var out = Problems.init(a);
    const opid = getStr(case, "operationId") orelse "";
    const entry = ops.get(opid) orelse {
        try problem(a, &out, "unknown operationId '{s}'", .{opid});
        return out;
    };
    const op = entry.op;
    const request: Value = get(case, "request") orelse .{ .object = std.json.ObjectMap.init(a) };
    const response = get(case, "response") orelse .null;
    const check_request = !truthy(get(case, "malformed_request"));

    // parameters
    var params = std.ArrayList(Value).init(a);
    for (getArr(entry.item, "parameters")) |p| try params.append(try deref(spec, p));
    for (getArr(op, "parameters")) |p| try params.append(try deref(spec, p));
    for ([_][]const u8{ "path", "query" }) |where| {
        const given = get(request, where) orelse .null;
        if (given == .object) {
            var git = given.object.iterator();
            while (git.next()) |ge| {
                var declared_here = false;
                for (params.items) |p| {
                    if (std.mem.eql(u8, getStr(p, "in") orelse "", where) and std.mem.eql(u8, getStr(p, "name") orelse "", ge.key_ptr.*)) declared_here = true;
                }
                if (!declared_here) try problem(a, &out, "undeclared {s} parameter {s}", .{ where, ge.key_ptr.* });
            }
        }
        for (params.items) |p| {
            if (!std.mem.eql(u8, getStr(p, "in") orelse "", where)) continue;
            const name = getStr(p, "name") orelse "";
            if (get(given, name)) |value| {
                if (check_request) {
                    try addSchemaProblems(a, &out, spec, get(p, "schema") orelse .null, value, "{s} parameter {s}: ", .{ where, name });
                }
            } else if (truthy(get(p, "required"))) {
                try problem(a, &out, "missing {s} parameter {s}", .{ where, name });
            }
        }
    }
    // The path template's names are exactly the path parameters given.
    {
        var template_names = std.StringHashMap(void).init(a);
        var rest: []const u8 = entry.path;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
            const inner = rest[open + 1 .. close];
            var ok = inner.len > 0;
            for (inner) |c| {
                if (!((c >= 'a' and c <= 'z') or c == '_')) ok = false;
            }
            if (ok) try template_names.put(inner, {});
            rest = rest[close + 1 ..];
        }
        const given = get(request, "path") orelse .null;
        var same = given == .null or given == .object;
        const given_count: usize = if (given == .object) given.object.count() else 0;
        if (given_count != template_names.count()) same = false;
        if (given == .object) {
            var git = given.object.iterator();
            while (git.next()) |ge| {
                if (!template_names.contains(ge.key_ptr.*)) same = false;
            }
        }
        if (!same) try problem(a, &out, "path parameters do not match template {s}", .{entry.path});
    }

    // request body
    const rb: ?Value = if (get(op, "requestBody")) |r| try deref(spec, r) else null;
    if (get(request, "body")) |body| {
        if (rb == null) {
            try out.append("request has a body but the operation takes none");
        } else if (check_request) {
            const schema = get(get(get(rb.?, "content") orelse .null, "application/json") orelse .null, "schema") orelse .null;
            try addSchemaProblems(a, &out, spec, schema, body, "request body: ", .{});
        }
    } else if (rb != null and truthy(get(rb.?, "required"))) {
        try out.append("request body is required");
    }

    // authentication
    var allowed = std.StringHashMap(void).init(a);
    const security = get(op, "security") orelse (get(spec, "security") orelse .null);
    if (security == .array) {
        for (security.array.items) |req| {
            if (req == .object) {
                var rit = req.object.iterator();
                while (rit.next()) |re| try allowed.put(re.key_ptr.*, {});
            }
        }
    }
    const auth = getStr(request, "auth");
    const status: i64 = getInt(response, "status") orelse 0;
    const schemes = get(get(spec, "components") orelse .null, "securitySchemes") orelse .null;
    if (auth) |s| {
        if (get(schemes, s) == null) {
            try problem(a, &out, "unknown security scheme {s}", .{s});
        } else if (!allowed.contains(s)) {
            try problem(a, &out, "operation does not accept scheme {s}", .{s});
        }
    }
    if (allowed.count() > 0 and auth == null and status != 401) {
        try out.append("operation needs auth but the case sends none and does not expect 401");
    }
    if (allowed.count() == 0 and auth != null) {
        try problem(a, &out, "operation takes no auth but the case sends {s}", .{auth.?});
    }

    // response
    const responses = get(op, "responses") orelse .null;
    const status_key = try std.fmt.allocPrint(a, "{d}", .{status});
    const declared = get(responses, status_key) != null;
    const resp_raw = get(responses, status_key) orelse (get(responses, "default") orelse {
        try problem(a, &out, "status {d} is not declared", .{status});
        return out;
    });
    const resp = try deref(spec, resp_raw);
    if (!declared and status < 400) try problem(a, &out, "success status {d} is not declared by the operation", .{status});
    var given_headers = std.StringHashMap(void).init(a);
    if (get(response, "headers")) |hs| {
        if (hs == .object) {
            var hit = hs.object.iterator();
            while (hit.next()) |he| try given_headers.put(try std.ascii.allocLowerString(a, he.key_ptr.*), {});
        }
    }
    if (get(resp, "headers")) |hs| {
        if (hs == .object) {
            var hit = hs.object.iterator();
            while (hit.next()) |he| {
                const h = try deref(spec, he.value_ptr.*);
                if (truthy(get(h, "required")) and !given_headers.contains(try std.ascii.allocLowerString(a, he.key_ptr.*))) {
                    try problem(a, &out, "response lacks required header {s}", .{he.key_ptr.*});
                }
            }
        }
    }
    const content = get(resp, "content");
    if (truthy(content)) {
        if (get(response, "body") == null) {
            try out.append("response needs a body");
        } else {
            const schema = get(get(content.?, "application/json") orelse .null, "schema") orelse .null;
            try addSchemaProblems(a, &out, spec, schema, get(response, "body").?, "response body: ", .{});
        }
    } else if (get(response, "body") != null) {
        try out.append("response must have no body");
    }

    // error catalogue
    const body = get(response, "body");
    if (status >= 400 and body != null and body.? == .object) {
        const err = get(body.?, "error") orelse .null;
        const code = getStr(err, "code");
        const cat = if (code) |c| get(catalogue, c) else null;
        if (cat == null) {
            try problem(a, &out, "error code '{s}' is not in the catalogue", .{code orelse "(none)"});
        } else {
            const e = cat.?;
            const want_status = getInt(e, "status") orelse 0;
            if (want_status != status) try problem(a, &out, "code {s} is catalogued with status {d}, not {d}", .{ code.?, want_status, status });
            const msg = getStr(err, "message") orelse "";
            if (!try followsTemplate(a, getStr(e, "message") orelse "", msg)) {
                try problem(a, &out, "message '{s}' does not follow the template of {s}", .{ msg, code.? });
            }
            const hint = getStr(err, "hint") orelse "";
            if (!try followsTemplate(a, getStr(e, "hint") orelse "", hint)) {
                try problem(a, &out, "hint '{s}' does not follow the template of {s}", .{ hint, code.? });
            }
            if (getStr(err, "reason")) |reason| {
                var listed = false;
                for (getArr(get(spec, "x-mopm-error-reasons") orelse .null, code.?)) |r| {
                    if (r == .string and std.mem.eql(u8, r.string, reason)) listed = true;
                }
                if (!listed) try problem(a, &out, "reason '{s}' is not one that {s} lists in x-mopm-error-reasons", .{ reason, code.? });
            }
            if (std.mem.eql(u8, code.?, "rate_limited") and !given_headers.contains("retry-after")) {
                try out.append("rate_limited must carry Retry-After");
            }
        }
    }

    return out;
}

/// Counts the failures of a driver; each is printed as it happens.
pub const Tally = struct {
    failures: usize = 0,

    pub fn fail(self: *Tally, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("FAIL: " ++ fmt ++ "\n", args);
        self.failures += 1;
    }

    pub fn finish(self: *Tally) !void {
        if (self.failures != 0) {
            std.debug.print("{d} failure(s)\n", .{self.failures});
            return error.ChecksFailed;
        }
    }
};

test "contract: message and hint templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try followsTemplate(a, "'{name}' is not a valid package name.", "'Http-Client' is not a valid package name."));
    try std.testing.expect(!try followsTemplate(a, "'{name}' is not a valid package name.", "'' is not a valid package name."));
    try std.testing.expect(!try followsTemplate(a, "'{name}' is not a valid package name.", "'x' is not a valid version."));
    try std.testing.expect(try followsTemplate(a, "No placeholder.", "No placeholder."));
    try std.testing.expect(!try followsTemplate(a, "No placeholder.", "No placeholder!"));
    try std.testing.expect(try followsTemplate(a, "a {x} b {y} c", "a 1 b 2 c"));
    try std.testing.expect(try followsTemplate(a, "{ not a placeholder }", "{ not a placeholder }"));
}
