//! Replays the API cases of tests/contract/api against the fake registry, for
//! the build farm, which has no Python. (It was tests/contract/replay.py; the
//! Python is deleted and this file is the check.)
//!
//! Replays the API cases of tests/contract/api against the fake registry. For
//! every case marked valid whose operation the fake implements, a recipe
//! (replay_recipes.zig) puts a fresh fake in the state the case describes and
//! sends the request. The live answer must have the case's status and, for an
//! error, its code; and it must pass the same contract checks as the examples
//! (contract.caseProblems: declared status, required headers, body schema, the
//! error catalogue's templates, Retry-After on rate_limited). A valid case of
//! an implemented operation with no recipe fails the run, and so does a recipe
//! whose case no longer exists. After the cases, the files a client reads with
//! no API (index config, index records, takedown log, repodata, the package
//! file) are published and checked (`checkFiles`), and the fake's error codes
//! (registry/fake/errors.zig) must be the spec's.
//!
//! Run by Buck2 (//:contract_replay) from the repository root; MOPM_FAKE_REGISTRY
//! is the built fake.

const std = @import("std");
const h = @import("harness.zig");
const c = @import("contract.zig");
const yaml = @import("yaml.zig");
const r = @import("replay_recipes.zig");
const tbl = @import("replay_table.zig");
const chk = @import("replay_checks.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

fn isImplemented(op: []const u8) bool {
    for (tbl.implemented) |i| {
        if (std.mem.eql(u8, i, op)) return true;
    }
    return false;
}

/// The enum members of `pub const Code = enum {` in errors.zig: the words
/// directly followed by a comma.
fn fakeCodes(a: Allocator, src: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    const marker = "pub const Code = enum {";
    const at = std.mem.indexOf(u8, src, marker) orelse return error.NoCodeEnum;
    const rest = src[at + marker.len ..];
    const end = std.mem.indexOf(u8, rest, "};") orelse rest.len;
    const body = rest[0..end];
    var i: usize = 0;
    while (i < body.len) {
        if (!isWord(body[i])) {
            i += 1;
            continue;
        }
        const begin = i;
        while (i < body.len and isWord(body[i])) i += 1;
        if (i < body.len and body[i] == ',') try set.put(body[begin..i], {});
    }
    return set;
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn catalogueDrift(a: Allocator, t: *c.Tally, spec: Value) !void {
    const src = try c.readFile(a, "registry/fake/errors.zig");
    var fake = try fakeCodes(a, src);
    const schemas = c.get(c.get(spec, "components") orelse .null, "schemas") orelse .null;
    const codes = c.getArr(c.get(schemas, "ErrorCode") orelse .null, "enum");
    var only_spec = std.ArrayList([]const u8).init(a);
    for (codes) |code| {
        if (code != .string) continue;
        if (!fake.remove(code.string)) try only_spec.append(code.string);
    }
    var left = fake.keyIterator();
    while (left.next()) |k| try only_spec.append(k.*);
    if (only_spec.items.len != 0) {
        std.mem.sort([]const u8, only_spec.items, {}, c.lessStr);
        t.fail("registry/fake/errors.zig and the spec's ErrorCode differ ({s}); run registry/fake/gen_errors.py", .{try std.mem.join(a, ", ", only_spec.items)});
    }
}

// ------------------------------------------------------------ the files

fn indexPath(f: *r.F, name: []const u8) ![]u8 {
    var padded: [4]u8 = "____".*;
    for (name[0..@min(name.len, 4)], 0..) |b, i| padded[i] = b;
    return f.fmt("/index/{s}/{s}/{s}", .{ padded[0..2], padded[2..4], name });
}

fn sortedVersions(a: Allocator, repodata: Value, list_key: []const u8, mojo_name: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const pkgs = c.get(repodata, list_key) orelse .null;
    if (pkgs == .object) {
        var it = pkgs.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, c.getStr(e.value_ptr.*, "name") orelse "", mojo_name)) try out.append(c.getStr(e.value_ptr.*, "version") orelse "");
        }
    }
    std.mem.sort([]const u8, out.items, {}, c.lessStr);
    return out.items;
}

fn joinVersions(a: Allocator, v: []const []const u8) ![]u8 {
    return std.mem.join(a, ",", v);
}

/// Publishes, yanks and takes down versions of one package, then checks the
/// files a client reads with no API: the index config, the package's index
/// records, the takedown log, repodata.json and current_repodata.json, and the
/// package file itself. Returns the problems.
fn checkFiles(f: *r.F) !c.Problems {
    const a = f.a;
    var out = c.Problems.init(a);

    const config = try c.parseJson(a, try f.fetch("/index/config.json"));
    const config_schema = try c.loadJson(a, "spec/index-config.schema.json");
    for ((try c.schemaErrors(a, config_schema, config_schema, config)).items) |e| try c.problem(a, &out, "config.json: {s}", .{e});
    for ([_][]const u8{ "linux-64", "linux-aarch64", "osx-arm64", "noarch" }) |subdir| {
        const empty = try c.parseJson(a, try f.fetch(try f.fmt("/channel/{s}/repodata.json", .{subdir})));
        const info = c.get(empty, "info") orelse .null;
        const info_ok = info == .object and info.object.count() == 1 and std.mem.eql(u8, c.getStr(info, "subdir") orelse "", subdir);
        if (!info_ok or c.get(empty, "packages.conda") == null) try c.problem(a, &out, "{s}/repodata.json is not a repodata file", .{subdir});
    }

    const rel = try r.Release.init(f);
    for ([_][]const u8{ "0.3.0", "0.4.0", "0.5.0" }) |version| try rel.publish(version, try f.fmt("bytes of {s}", .{version}));
    _ = try f.req("PUT", try rel.yankPath("0.3.0"), "{\"yanked\":true,\"reason\":\"crashes on empty body\"}", rel.token);
    try rel.publish("0.2.0", "bytes of 0.2.0");
    _ = try f.control("/tombstone", try f.fmt("{{\"name\":\"{s}\",\"version\":\"0.2.0\",\"reason_code\":\"malware\"}}", .{rel.name}));

    // The index records: valid, oldest first, the states the API reports.
    const index_text = try f.fetch(try indexPath(f, rel.name));
    const record_schema = try c.loadJson(a, "spec/index-record.schema.json");
    for ((try c.indexProblems(a, rel.name, index_text, record_schema)).items) |p| try c.problem(a, &out, "index: {s}", .{p});
    var order = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, index_text, '\n');
    var records = std.ArrayList(Value).init(a);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const rec = try c.parseJson(a, line);
        try records.append(rec);
        try order.writer().print("{s}:{s} ", .{ c.getStr(rec, "version") orelse "?", c.getStr(rec, "state") orelse "?" });
    }
    const want_order = "0.2.0:tombstoned 0.3.0:yanked 0.4.0:published 0.5.0:published ";
    if (!std.mem.eql(u8, order.items, want_order)) try c.problem(a, &out, "index records {s}, expected {s}", .{ order.items, want_order });
    for (records.items) |rec| {
        const ver = c.getStr(rec, "version") orelse "";
        const detail = try c.parseJson(a, try f.fetch(try f.fmt("/api/v1/packages/{s}/{s}", .{ rel.name, ver })));
        var same = c.getArr(rec, "files").len == c.getArr(detail, "files").len;
        if (same) {
            for (c.getArr(rec, "files"), c.getArr(detail, "files")) |x, y| {
                if (!std.mem.eql(u8, c.getStr(x, "sha256") orelse "", c.getStr(y, "sha256") orelse "?")) same = false;
            }
        }
        if (!same) try c.problem(a, &out, "index and getVersion disagree on the sha256 of {s}", .{ver});
    }

    // The channel: yanked and taken-down files leave packages.conda for removed.
    const repodata_path = "/channel/linux-64/repodata.json";
    const repodata_bytes = try f.fetch(repodata_path);
    const repodata = try c.parseJson(a, repodata_bytes);
    const mojo_name = try f.fmt("mojo-{s}", .{rel.name});
    const listed = try sortedVersions(a, repodata, "packages.conda", mojo_name);
    if (!std.mem.eql(u8, try joinVersions(a, listed), "0.4.0,0.5.0")) try c.problem(a, &out, "repodata.json lists {s}", .{try joinVersions(a, listed)});
    if (c.get(repodata, "packages.conda")) |pkgs| {
        if (pkgs == .object) {
            var it = pkgs.object.iterator();
            while (it.next()) |e| {
                const v = e.value_ptr.*;
                if (!std.mem.eql(u8, c.getStr(v, "name") orelse "", mojo_name)) continue;
                const deps = c.getArr(v, "depends");
                const deps_ok = deps.len == 1 and deps[0] == .string and std.mem.eql(u8, deps[0].string, "mojo-compiler ==1.0.0");
                if ((c.getInt(v, "build_number") orelse -1) != 0 or !std.mem.eql(u8, c.getStr(v, "subdir") orelse "", "linux-64") or !deps_ok) {
                    try c.problem(a, &out, "repodata entry {s} is wrong", .{c.getStr(v, "version") orelse "?"});
                }
            }
        }
    }
    for ([_][]const u8{ "0.2.0", "0.3.0" }) |version| {
        const fname = try rel.filename(version);
        var found = false;
        for (c.getArr(repodata, "removed")) |x| {
            if (x == .string and std.mem.eql(u8, x.string, fname)) found = true;
        }
        if (!found) try c.problem(a, &out, "{s} is not under removed", .{version});
    }
    // Rewriting the same state gives the same bytes (two rewrites: mode on, off).
    _ = try f.control("/mode", "{\"read_only\":true}");
    _ = try f.control("/mode", "{\"read_only\":false}");
    if (!std.mem.eql(u8, try f.fetch(repodata_path), repodata_bytes)) try out.append("repodata.json is not deterministic");
    const current = try c.parseJson(a, try f.fetch("/channel/linux-64/current_repodata.json"));
    const cur = try joinVersions(a, try sortedVersions(a, current, "packages.conda", mojo_name));
    if (!std.mem.eql(u8, cur, "0.5.0")) try c.problem(a, &out, "current_repodata.json lists {s}, expected only 0.5.0", .{cur});

    // The files: a yanked file still downloads; a taken-down one answers 410.
    if (!std.mem.eql(u8, try f.fetch(try f.fmt("/channel/linux-64/{s}", .{try rel.filename("0.3.0")})), "bytes of 0.3.0")) {
        try out.append("the yanked file does not download");
    }
    if ((try f.statusOf(try f.fmt("/channel/linux-64/{s}", .{try rel.filename("0.2.0")}))) != 410) {
        try out.append("the taken-down file does not answer 410");
    }

    const takedowns = try c.parseJson(a, try f.fetch("/index/takedowns.json"));
    const td_schema = try c.loadJson(a, "spec/takedowns.schema.json");
    for ((try c.schemaErrors(a, td_schema, td_schema, takedowns)).items) |e| try c.problem(a, &out, "takedowns.json: {s}", .{e});
    var listed_td = false;
    for (c.getArr(takedowns, "takedowns")) |td| {
        if (std.mem.eql(u8, c.getStr(td, "name") orelse "", rel.name) and std.mem.eql(u8, c.getStr(td, "version") orelse "", "0.2.0")) listed_td = true;
    }
    if (!listed_td) try out.append("takedowns.json does not list the takedown");
    return out;
}

// ------------------------------------------------------------- the replay

fn emptyObject(a: Allocator) Value {
    return .{ .object = std.json.ObjectMap.init(a) };
}

/// `/a/{name}/{version}` with the path values filled in.
fn fillTemplate(a: Allocator, template: []const u8, path: Value) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return error.BadTemplate;
            const v = c.get(path, template[i + 1 .. close]) orelse return error.PathValueMissing;
            switch (v) {
                .string => |s| try out.appendSlice(s),
                .integer => |n| try out.writer().print("{d}", .{n}),
                else => return error.PathValueType,
            }
            i = close + 1;
        } else {
            try out.append(template[i]);
            i += 1;
        }
    }
    return out.items;
}

fn percent(w: anytype, s: []const u8) !void {
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '_' or b == '.' or b == '-' or b == '~') {
            try w.writeByte(b);
        } else {
            try w.print("%{X:0>2}", .{b});
        }
    }
}

fn queryString(a: Allocator, q: ?Value) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const v = q orelse return out.items;
    if (v != .object) return out.items;
    var it = v.object.iterator();
    var first = true;
    while (it.next()) |e| {
        try out.append(if (first) '?' else '&');
        first = false;
        try percent(out.writer(), e.key_ptr.*);
        try out.append('=');
        switch (e.value_ptr.*) {
            .string => |s| try percent(out.writer(), s),
            .integer => |n| try out.writer().print("{d}", .{n}),
            else => return error.QueryValueType,
        }
    }
    return out.items;
}

test "the fake registry answers the contract's API cases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = c.Tally{};
    try h.watchdog(240);
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");

    const spec = try yaml.parse(a, try c.readFile(a, "spec/api/openapi.yaml"));
    const meta = try c.loadJson(a, "spec/package-metadata.schema.json");
    var dups = c.Problems.init(a);
    const ops = try c.operations(a, spec, &dups);
    for (dups.items) |d| t.fail("{s}", .{d});
    const catalogue = c.get(spec, "x-mopm-errors") orelse return error.NoCatalogue;
    try catalogueDrift(a, &t, spec);

    // The valid cases of the implemented operations, in file order.
    var wanted = std.ArrayList(Value).init(a);
    for (try c.listFiles(a, "tests/contract/api", ".json")) |file| {
        const doc = try c.loadJson(a, try std.fmt.allocPrint(a, "tests/contract/api/{s}", .{file}));
        for (c.getArr(doc, "cases")) |case| {
            const expect = c.getStr(case, "expect") orelse "valid";
            if (std.mem.eql(u8, expect, "valid") and isImplemented(c.getStr(case, "operationId") orelse "")) try wanted.append(case);
        }
    }
    // A recipe whose case has gone, and a case with no recipe.
    for (tbl.table) |e| {
        var has_case = false;
        for (wanted.items) |case| {
            if (std.mem.eql(u8, c.getStr(case, "operationId") orelse "", e.op) and std.mem.eql(u8, c.getStr(case, "name") orelse "", e.name)) has_case = true;
        }
        if (!has_case) t.fail("recipe {s} / '{s}' has no valid case in tests/contract/api", .{ e.op, e.name });
    }

    h.stage = "starting the fake registry";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ try h.tmpPath(a, &tmp), "fake" }));
    defer fake.close();
    var f = r.F.init(a, fake.base);

    for (wanted.items) |case| {
        const op_name = c.getStr(case, "operationId") orelse "";
        const case_name = c.getStr(case, "name") orelse "";
        var entry: ?tbl.Entry = null;
        for (tbl.table) |e| {
            if (std.mem.eql(u8, e.op, op_name) and std.mem.eql(u8, e.name, case_name)) entry = e;
        }
        const ent = entry orelse {
            t.fail("no recipe for {s} / '{s}'", .{ op_name, case_name });
            continue;
        };
        h.stage = case_name;
        const s = try r.build(&f, ent);
        const op = ops.get(s.op) orelse {
            t.fail("{s} / '{s}': the recipe names the unknown operation {s}", .{ op_name, case_name, s.op });
            continue;
        };
        const path_value = s.path orelse emptyObject(a);
        const query_value = s.query orelse emptyObject(a);
        const url: []const u8 = if (s.raw_path) |raw| raw else try std.fmt.allocPrint(a, "/api/v1{s}{s}", .{ try fillTemplate(a, op.path, path_value), try queryString(a, s.query) });
        const method: []const u8 = if (s.raw_path != null) "GET" else try std.ascii.allocUpperString(a, op.method);
        const rsp = try f.req(method, url, if (s.raw_path != null) null else s.body, s.token);

        // The live answer as a case of the contract.
        var req_obj = std.json.ObjectMap.init(a);
        try req_obj.put("path", path_value);
        try req_obj.put("query", query_value);
        if (s.body) |b| try req_obj.put("body", try c.parseJson(a, b));
        if (s.auth) |auth| try req_obj.put("auth", .{ .string = auth });
        var resp_obj = std.json.ObjectMap.init(a);
        try resp_obj.put("status", .{ .integer = rsp.status });
        try resp_obj.put("headers", rsp.headers);
        if (rsp.body) |b| try resp_obj.put("body", b);
        var live = std.json.ObjectMap.init(a);
        try live.put("operationId", .{ .string = s.op });
        try live.put("request", .{ .object = req_obj });
        try live.put("response", .{ .object = resp_obj });
        try live.put("malformed_request", .{ .bool = s.malformed });

        var problems = try c.caseProblems(a, spec, ops, catalogue, meta, .{ .object = live });
        const want_status = c.getInt(c.get(case, "response") orelse .null, "status") orelse 0;
        if (rsp.status != want_status) {
            try c.problem(a, &problems, "status {d}, the case has {d}", .{ rsp.status, want_status });
        } else if (want_status >= 400) {
            const want_body = c.get(c.get(case, "response") orelse .null, "body") orelse .null;
            const want_code = c.getStr(c.get(want_body, "error") orelse .null, "code") orelse "";
            const got_code = c.getStr(c.get(rsp.body orelse .null, "error") orelse .null, "code") orelse "(none)";
            if (!std.mem.eql(u8, got_code, want_code)) try c.problem(a, &problems, "error {s}, the case has {s}", .{ got_code, want_code });
        }
        if (problems.items.len == 0 and s.check != .none) {
            const ok = chk.runCheck(&f, s, rsp.body orelse .null) catch false;
            if (!ok) try c.problem(a, &problems, "the recipe's check {s} failed on {s}", .{ @tagName(s.check), try std.json.stringifyAlloc(a, rsp.body orelse .null, .{}) });
        }
        try chk.runAfter(&f, s.after);
        for (problems.items) |p| t.fail("{s} / '{s}': {s}", .{ op_name, case_name, p });
    }

    h.stage = "checking the index and channel files";
    for ((try checkFiles(&f)).items) |p| t.fail("files: {s}", .{p});

    std.debug.print("replayed {d} cases of {d} operations against the fake\n", .{ wanted.items.len, tbl.implemented.len });
    try t.finish();
    std.debug.print("replay OK\n", .{});
}
