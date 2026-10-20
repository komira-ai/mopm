//! The contract checks of the registry API, index and lock, for the build farm,
//! which has no Python. (They were tests/contract/validate.py; the Python is
//! deleted and this file is the check.)
//!
//! Run by Buck2 (//:contract): the working directory is the repository root
//! with spec/, tests/contract and tests/fixtures present. It checks
//!
//!  1. spec/api/openapi.yaml is read (tests/drivers/yaml.zig) and passes the
//!     structural checks of openapi_check.zig
//!  2. every spec/*.schema.json passes jsonschema.checkSchema, which REFUSES
//!     a keyword it does not implement; the package metadata fixtures under
//!     tests/fixtures validate against package-metadata.schema.json
//!  3. the error catalogue (x-mopm-errors) and the ErrorCode enum agree
//!  4. every case of tests/contract/api/*.json: "valid" ones have no problem,
//!     "invalid" ones (counter-examples with one defect each) are REJECTED;
//!     every operation has a passing success case, every error code and every
//!     rejection code a case
//!  5. the examples under tests/contract/examples/<kind>/valid pass and those
//!     under <kind>/invalid fail, with the lock rules JSON Schema cannot say
//!
//! Each failure prints one `FAIL:` line; the test fails if any did.

const std = @import("std");
const c = @import("contract.zig");
const js = @import("jsonschema.zig");
const yaml = @import("yaml.zig");
const oa = @import("openapi_check.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

test {
    _ = @import("regex.zig");
    _ = @import("jsonschema.zig");
    _ = @import("yaml.zig");
    _ = @import("contract.zig");
}

const Counts = struct { api_cases: usize = 0, rejected: usize = 0, examples: usize = 0, schemas: usize = 0, fixtures: usize = 0 };

fn checkSchemas(a: Allocator, t: *c.Tally, counts: *Counts, meta: Value) !void {
    for (try c.listFiles(a, "spec", ".schema.json")) |name| {
        const path = try std.fmt.allocPrint(a, "spec/{s}", .{name});
        // An unsupported keyword or a malformed schema stops the run here, loudly.
        try js.checkSchema(a, try c.loadJson(a, path), path);
        counts.schemas += 1;
    }
    for (try c.walkFiles(a, "tests/fixtures", ".mopm.json")) |path| {
        counts.fixtures += 1;
        const errs = try c.schemaErrors(a, meta, meta, try c.loadJson(a, path));
        for (errs.items) |e| t.fail("{s}: {s}", .{ path, e });
    }
}

fn stringSet(a: Allocator, items: []const Value) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    for (items) |v| if (v == .string) try set.put(v.string, {});
    return set;
}

fn checkApi(a: Allocator, t: *c.Tally, counts: *Counts, spec: Value, meta: Value) !void {
    var dups = c.Problems.init(a);
    const ops = try c.operations(a, spec, &dups);
    for (dups.items) |d| t.fail("{s}", .{d});
    const catalogue = c.get(spec, "x-mopm-errors") orelse .null;
    if (catalogue != .object) {
        t.fail("openapi.yaml has no x-mopm-errors", .{});
        return;
    }
    const schemas = c.get(c.get(spec, "components") orelse .null, "schemas") orelse .null;
    const codes = try stringSet(a, c.getArr(c.get(schemas, "ErrorCode") orelse .null, "enum"));
    var cat_it = catalogue.object.iterator();
    while (cat_it.next()) |e| {
        if (!codes.contains(e.key_ptr.*)) t.fail("ErrorCode enum and x-mopm-errors differ: {s} is only in the catalogue", .{e.key_ptr.*});
        const status = c.getInt(e.value_ptr.*, "status");
        if (status == null or status.? < 400 or status.? > 599) t.fail("catalogue {s} has no HTTP error status", .{e.key_ptr.*});
        const msg = c.getStr(e.value_ptr.*, "message");
        if (msg == null or msg.?.len == 0 or c.getStr(e.value_ptr.*, "hint") == null) t.fail("catalogue {s} needs a message and a hint string", .{e.key_ptr.*});
    }
    var code_it = codes.iterator();
    while (code_it.next()) |e| {
        if (catalogue.object.get(e.key_ptr.*) == null) t.fail("ErrorCode enum and x-mopm-errors differ: {s} is only in the enum", .{e.key_ptr.*});
    }

    var seen_ok = std.StringHashMap(void).init(a);
    var seen_codes = std.StringHashMap(void).init(a);
    var seen_rejections = std.StringHashMap(void).init(a);
    const files = try c.listFiles(a, "tests/contract/api", ".json");
    if (files.len == 0) t.fail("no files in tests/contract/api", .{});
    for (files) |file| {
        const doc = try c.loadJson(a, try std.fmt.allocPrint(a, "tests/contract/api/{s}", .{file}));
        for (c.getArr(doc, "cases"), 0..) |case, i| {
            const name = try std.fmt.allocPrint(a, "{s}[{d}] {s}", .{ file, i, c.getStr(case, "name") orelse "" });
            counts.api_cases += 1;
            const problems = try c.caseProblems(a, spec, ops, catalogue, meta, case);
            const expect = c.getStr(case, "expect") orelse "valid";
            if (std.mem.eql(u8, expect, "valid")) {
                for (problems.items) |p| t.fail("{s}: {s}", .{ name, p });
                if (problems.items.len == 0) {
                    const response = c.get(case, "response") orelse .null;
                    const status = c.getInt(response, "status") orelse 0;
                    if (status < 300) try seen_ok.put(c.getStr(case, "operationId") orelse "", {});
                    const body = c.get(response, "body");
                    if (status >= 400 and body != null and body.? == .object) {
                        if (c.getStr(c.get(body.?, "error") orelse .null, "code")) |code| try seen_codes.put(code, {});
                    }
                    if (body != null and body.? == .object) {
                        if (c.getStr(body.?, "rejection_code")) |code| try seen_rejections.put(code, {});
                    }
                }
            } else if (std.mem.eql(u8, expect, "invalid")) {
                if (problems.items.len == 0) {
                    t.fail("{s}: marked invalid but the contract accepts it", .{name});
                } else counts.rejected += 1;
            } else {
                t.fail("{s}: expect must be valid or invalid", .{name});
            }
        }
    }
    var op_it = ops.iterator();
    while (op_it.next()) |e| {
        if (!seen_ok.contains(e.key_ptr.*)) t.fail("operation {s} has no passing success case", .{e.key_ptr.*});
    }
    code_it = codes.iterator();
    while (code_it.next()) |e| {
        if (!seen_codes.contains(e.key_ptr.*)) t.fail("error code {s} has no case", .{e.key_ptr.*});
    }
    const rejection_enum = c.getArr(c.get(schemas, "RejectionCode") orelse .null, "enum");
    if (rejection_enum.len == 0) t.fail("components.schemas.RejectionCode has no enum", .{});
    for (rejection_enum) |code| {
        if (code == .string and !seen_rejections.contains(code.string)) t.fail("rejection code {s} has no case", .{code.string});
    }
}

const Kind = struct { name: []const u8, schema: []const u8, suffix: []const u8 };
const kinds = [_]Kind{
    .{ .name = "index-record", .schema = "index-record.schema.json", .suffix = ".ndjson" },
    .{ .name = "index-config", .schema = "index-config.schema.json", .suffix = ".json" },
    .{ .name = "takedowns", .schema = "takedowns.schema.json", .suffix = ".json" },
    .{ .name = "lock", .schema = "lock.schema.json", .suffix = ".json" },
};

fn exampleProblems(a: Allocator, kind: Kind, schema: Value, path: []const u8, file: []const u8) !c.Problems {
    const bytes = try c.readFile(a, path);
    if (std.mem.eql(u8, kind.name, "index-record")) {
        const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;
        return c.indexProblems(a, file[0..dot], bytes, schema);
    }
    var out = c.Problems.init(a);
    const doc = c.parseJson(a, bytes) catch |err| {
        try c.problem(a, &out, "not JSON: {s}", .{@errorName(err)});
        return out;
    };
    const errs = try c.schemaErrors(a, schema, schema, doc);
    for (errs.items) |e| try out.append(e);
    if (std.mem.eql(u8, kind.name, "lock") and out.items.len == 0) {
        const rules = try c.lockProblems(a, doc);
        for (rules.items) |e| try out.append(e);
    }
    return out;
}

fn checkExamples(a: Allocator, t: *c.Tally, counts: *Counts) !void {
    for (kinds) |kind| {
        const schema = try c.loadJson(a, try std.fmt.allocPrint(a, "spec/{s}", .{kind.schema}));
        for ([_][]const u8{ "valid", "invalid" }) |verdict| {
            const dir = try std.fmt.allocPrint(a, "tests/contract/examples/{s}/{s}", .{ kind.name, verdict });
            const files = try c.listFiles(a, dir, kind.suffix);
            if (files.len == 0) t.fail("no {s} examples for {s}", .{ verdict, kind.name });
            for (files) |file| {
                counts.examples += 1;
                const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, file });
                const problems = try exampleProblems(a, kind, schema, path, file);
                if (std.mem.eql(u8, verdict, "valid")) {
                    for (problems.items) |p| t.fail("{s}: {s}", .{ path, p });
                } else if (problems.items.len == 0) {
                    t.fail("{s}: is under invalid/ but passes", .{path});
                }
            }
        }
    }
}

test "the registry contract: spec, API cases and examples" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = c.Tally{};
    var counts = Counts{};

    const spec = try yaml.parse(a, try c.readFile(a, "spec/api/openapi.yaml"));
    var structural = c.Problems.init(a);
    try oa.check(a, spec, &structural);
    for (structural.items) |p| t.fail("openapi.yaml is not a valid OpenAPI document: {s}", .{p});
    if (structural.items.len != 0) return t.finish();

    const meta = try c.loadJson(a, "spec/package-metadata.schema.json");
    try checkSchemas(a, &t, &counts, meta);
    try checkApi(a, &t, &counts, spec, meta);
    try checkExamples(a, &t, &counts);

    std.debug.print("checked: api cases {d}, invalid cases rejected {d}, examples {d}, schemas {d}, metadata fixtures {d}\n", .{ counts.api_cases, counts.rejected, counts.examples, counts.schemas, counts.fixtures });
    try t.finish();
    std.debug.print("contract OK\n", .{});
}
