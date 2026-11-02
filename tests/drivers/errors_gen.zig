//! Regenerates registry/fake/errors.zig from the error catalogue of
//! spec/api/openapi.yaml (the `ErrorCode` enum and `x-mopm-errors`): the Zig
//! port of registry/fake/gen_errors.py. `generate` is shared by the tool
//! (gen_errors.zig) and by the test that the committed file is current
//! (gen_errors_test.zig).

const std = @import("std");
const yaml = @import("yaml.zig");
const Allocator = std.mem.Allocator;

/// HTTP status number -> the name std.http.Status gives it.
fn statusName(n: i64) ?[]const u8 {
    return switch (n) {
        400 => "bad_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        409 => "conflict",
        410 => "gone",
        413 => "payload_too_large",
        429 => "too_many_requests",
        500 => "internal_server_error",
        503 => "service_unavailable",
        else => null,
    };
}

/// The rest of errors.zig after the generated table: fill() and its test.
const tail =
    \\/// A template parameter: `{name}` in a message or hint.
    \\pub const Param = struct { []const u8, []const u8 };
    \\
    \\/// `template` with each `{key}` replaced by its value from `params`; a key
    \\/// with no value is left as written.
    \\pub fn fill(arena: Allocator, template: []const u8, params: []const Param) Allocator.Error![]const u8 {
    \\    var out = std.ArrayList(u8).init(arena);
    \\    var i: usize = 0;
    \\    while (i < template.len) {
    \\        if (template[i] == '{') {
    \\            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
    \\                const key = template[i + 1 .. end];
    \\                for (params) |p| {
    \\                    if (std.mem.eql(u8, p[0], key)) {
    \\                        try out.appendSlice(p[1]);
    \\                        break;
    \\                    }
    \\                } else try out.appendSlice(template[i .. end + 1]);
    \\                i = end + 1;
    \\                continue;
    \\            }
    \\        }
    \\        try out.append(template[i]);
    \\        i += 1;
    \\    }
    \\    return try out.toOwnedSlice();
    \\}
    \\
    \\test "templates take their parameters" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const a = arena_state.allocator();
    \\    const e = entry(.version_not_found);
    \\    try std.testing.expectEqual(std.http.Status.not_found, e.status);
    \\    try std.testing.expectEqualStrings("'json' has no version '1.0'.", try fill(a, e.message, &.{ .{ "name", "json" }, .{ "version", "1.0" } }));
    \\    try std.testing.expectEqualStrings("List the versions with 'mopm info {name}'.", try fill(a, e.hint, &.{}));
    \\}
    ;

fn zigString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

pub const Error = error{
    /// ErrorCode and x-mopm-errors name different codes.
    CodesDiffer,
    /// The spec lacks a part of the catalogue, or an entry lacks a field.
    BadCatalogue,
    /// A status the table of statusName does not know.
    UnknownStatus,
} || Allocator.Error || error{YamlUnsupported};

/// The text of errors.zig for the spec in `spec_text`. `why` (if given) gets
/// a one-line reason when this returns an error.
pub fn generate(a: Allocator, spec_text: []const u8, why: ?*[]const u8) anyerror![]u8 {
    const spec = try yaml.parse(a, spec_text);
    const catalogue = field(spec, "x-mopm-errors") orelse return fail(a, why, "the spec has no x-mopm-errors", error.BadCatalogue);
    const schemas = field(field(spec, "components") orelse .null, "schemas") orelse .null;
    const code_enum = field(field(schemas, "ErrorCode") orelse .null, "enum") orelse
        return fail(a, why, "the spec has no components.schemas.ErrorCode.enum", error.BadCatalogue);
    if (catalogue != .object or code_enum != .array) return fail(a, why, "x-mopm-errors is not a mapping or ErrorCode.enum is not a list", error.BadCatalogue);

    // set(codes) != set(catalogue) is an error, as in gen_errors.py.
    var differ = std.ArrayList(u8).init(a);
    for (code_enum.array.items) |c| {
        if (c != .string or !catalogue.object.contains(c.string)) try differ.writer().print(" {s}", .{if (c == .string) c.string else "?"});
    }
    var it = catalogue.object.iterator();
    while (it.next()) |e| {
        var found = false;
        for (code_enum.array.items) |c| found = found or (c == .string and std.mem.eql(u8, c.string, e.key_ptr.*));
        if (!found) try differ.writer().print(" {s}", .{e.key_ptr.*});
    }
    if (differ.items.len != 0) {
        return fail(a, why, try std.fmt.allocPrint(a, "ErrorCode and x-mopm-errors differ:{s}", .{differ.items}), error.CodesDiffer);
    }

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll(
        \\//! The error catalogue of spec/api/openapi.yaml (`x-mopm-errors`): each code's
        \\//! HTTP status, message template and hint template. Generated by
        \\//! tests/drivers/gen_errors.zig (//:gen_errors); do not edit by hand.
        \\//! tests/contract/replay.py checks every error the fake sends against the
        \\//! catalogue, and //:gen_errors_current checks that this file is what the
        \\//! generator makes of the spec.
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\
        \\pub const Code = enum {
        \\
    );
    for (code_enum.array.items) |c| try w.print("    {s},\n", .{c.string});
    try w.writeAll("};\n\n");
    try writeReasons(a, w, spec, code_enum.array.items, why);
    try w.writeAll(
        \\pub const Entry = struct { status: std.http.Status, message: []const u8, hint: []const u8 };
        \\
        \\pub fn entry(code: Code) Entry {
        \\    return switch (code) {
        \\
    );
    for (code_enum.array.items) |c| {
        const e = catalogue.object.get(c.string).?;
        const status = field(e, "status") orelse return fail(a, why, try std.fmt.allocPrint(a, "{s} has no status", .{c.string}), error.BadCatalogue);
        const message = field(e, "message") orelse return fail(a, why, try std.fmt.allocPrint(a, "{s} has no message", .{c.string}), error.BadCatalogue);
        const hint = field(e, "hint") orelse return fail(a, why, try std.fmt.allocPrint(a, "{s} has no hint", .{c.string}), error.BadCatalogue);
        if (status != .integer or message != .string or hint != .string) {
            return fail(a, why, try std.fmt.allocPrint(a, "{s}: status must be a number, message and hint strings", .{c.string}), error.BadCatalogue);
        }
        const name = statusName(status.integer) orelse return fail(a, why, try std.fmt.allocPrint(a, "{s}: no name for HTTP status {d}", .{ c.string, status.integer }), error.UnknownStatus);
        try w.print("        .{s} => .{{ .status = .{s}, .message = ", .{ c.string, name });
        try zigString(w, message.string);
        try w.writeAll(", .hint = ");
        try zigString(w, hint.string);
        try w.writeAll(" },\n");
    }
    try w.writeAll("    };\n}\n\n");
    try w.writeAll(tail);
    try w.writeByte('\n');
    return out.items;
}

/// One enum for each code of `x-mopm-error-reasons` (the values of `error.reason`), named after the code: `group_conflict` gives
/// `GroupConflictReason`. A spec without the table gets none.
fn writeReasons(a: Allocator, w: anytype, spec: std.json.Value, codes: []const std.json.Value, why: ?*[]const u8) !void {
    const reasons = field(spec, "x-mopm-error-reasons") orelse return;
    if (reasons != .object) return fail(a, why, "x-mopm-error-reasons is not a mapping", error.BadCatalogue);
    var it = reasons.object.iterator();
    while (it.next()) |e| {
        var known = false;
        for (codes) |c| known = known or (c == .string and std.mem.eql(u8, c.string, e.key_ptr.*));
        if (!known or e.value_ptr.* != .array or e.value_ptr.array.items.len == 0) {
            return fail(a, why, try std.fmt.allocPrint(a, "x-mopm-error-reasons: {s} is not a code with a list of reasons", .{e.key_ptr.*}), error.BadCatalogue);
        }
        try w.print("/// The `error.reason` values of `{s}` (`x-mopm-error-reasons`).\npub const ", .{e.key_ptr.*});
        var upper = true;
        for (e.key_ptr.*) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            try w.writeByte(if (upper) std.ascii.toUpper(ch) else ch);
            upper = false;
        }
        try w.writeAll("Reason = enum {\n");
        for (e.value_ptr.array.items) |r| {
            if (r != .string) return fail(a, why, "x-mopm-error-reasons: a reason is not a string", error.BadCatalogue);
            try w.print("    {s},\n", .{r.string});
        }
        try w.writeAll("};\n\n");
    }
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn fail(a: Allocator, why: ?*[]const u8, msg: []const u8, e: Error) Error {
    if (why) |p| p.* = a.dupe(u8, msg) catch msg;
    return e;
}

