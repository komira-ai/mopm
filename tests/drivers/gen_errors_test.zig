//! The check that registry/fake/errors.zig is current: what the generator
//! (errors_gen.zig, the Zig port of registry/fake/gen_errors.py) makes of
//! spec/api/openapi.yaml must be the committed file, byte for byte. Without
//! it, a catalogue change that nobody regenerated would leave the fake
//! registry sending the old status, message or hint.
//!
//! What can go red: a changed status, message or hint in x-mopm-errors; a code
//! added to or removed from ErrorCode or x-mopm-errors; a hand edit of
//! errors.zig; a generator that writes something else. The generator's own
//! refusals (the two code lists differ, a status it has no name for, a missing
//! field) are tested on small specs below.

const std = @import("std");
const gen = @import("errors_gen.zig");
const h = @import("harness.zig");

fn firstDifference(want: []const u8, got: []const u8) usize {
    var i: usize = 0;
    while (i < want.len and i < got.len and want[i] == got[i]) i += 1;
    return i;
}

fn lineAt(text: []const u8, at: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..@min(at, text.len)], '\n')) |n| n + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, @min(at, text.len), '\n') orelse text.len;
    return text[start..end];
}

test "registry/fake/errors.zig is what the generator makes of spec/api/openapi.yaml" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
    const spec = try h.readFile(a, try h.join(a, &.{ work, "spec/api/openapi.yaml" }));
    const committed = try h.readFile(a, try h.join(a, &.{ work, "registry/fake/errors.zig" }));
    var why: []const u8 = "";
    const made = try gen.generate(a, spec, &why);
    if (!std.mem.eql(u8, made, committed)) {
        const at = firstDifference(made, committed);
        std.debug.print("FAIL registry/fake/errors.zig is not current; regenerate it with\n  ./buck2 run //:gen_errors -- spec/api/openapi.yaml registry/fake/errors.zig\nfirst difference, generated: {s}\nfirst difference, committed: {s}\n", .{ lineAt(made, at), lineAt(committed, at) });
        return error.ErrorsZigIsStale;
    }
    std.debug.print("ok   registry/fake/errors.zig is current\n", .{});
}

const spec_head =
    \\components:
    \\  schemas:
    \\    ErrorCode:
    \\      enum: [a_code, b_code]
    \\x-mopm-errors:
    \\
;

test "the generator refuses a catalogue whose codes differ from ErrorCode" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const spec = spec_head ++
        \\  a_code: { status: 404, message: "m", hint: "h" }
        \\  c_code: { status: 404, message: "m", hint: "h" }
        \\
    ;
    try std.testing.expectError(error.CodesDiffer, gen.generate(a, spec, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "b_code") != null and std.mem.indexOf(u8, why, "c_code") != null);
}

test "the generator refuses a status it has no name for, and a missing field" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const teapot = spec_head ++
        \\  a_code: { status: 418, message: "m", hint: "h" }
        \\  b_code: { status: 404, message: "m", hint: "h" }
        \\
    ;
    try std.testing.expectError(error.UnknownStatus, gen.generate(a, teapot, &why));
    const no_hint = spec_head ++
        \\  a_code: { status: 404, message: "m" }
        \\  b_code: { status: 404, message: "m", hint: "h" }
        \\
    ;
    try std.testing.expectError(error.BadCatalogue, gen.generate(a, no_hint, &why));
}

test "the generator escapes quotes and backslashes in templates" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const spec = spec_head ++
        \\  a_code: { status: 404, message: 'say "hi" \ there', hint: "h" }
        \\  b_code: { status: 429, message: "m", hint: "h" }
        \\
    ;
    const made = try gen.generate(a, spec, null);
    try std.testing.expect(std.mem.indexOf(u8, made, ".message = \"say \\\"hi\\\" \\\\ there\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, made, ".b_code => .{ .status = .too_many_requests") != null);
}

test "the generator writes an enum of the reasons a code lists, named after the code, and a spec without the table gets none" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const base = spec_head ++
        \\  a_code: { status: 404, message: "m", hint: "h" }
        \\  b_code: { status: 409, message: "m", hint: "h" }
        \\
    ;
    const none = try gen.generate(a, base, null);
    try std.testing.expect(std.mem.indexOf(u8, none, "Reason") == null);
    const made = try gen.generate(a, base ++
        \\x-mopm-error-reasons:
        \\  b_code: [first_cause, second_cause]
        \\
    , null);
    try std.testing.expect(std.mem.indexOf(u8, made, "pub const BCodeReason = enum {\n    first_cause,\n    second_cause,\n};\n") != null);
}

test "the generator refuses reasons for a code that is not in the catalogue, an empty list, and a list that is not strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const base = spec_head ++
        \\  a_code: { status: 404, message: "m", hint: "h" }
        \\  b_code: { status: 409, message: "m", hint: "h" }
        \\
    ;
    try std.testing.expectError(error.BadCatalogue, gen.generate(a, base ++
        \\x-mopm-error-reasons:
        \\  c_code: [x]
        \\
    , &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "c_code") != null);
    try std.testing.expectError(error.BadCatalogue, gen.generate(a, base ++
        \\x-mopm-error-reasons:
        \\  b_code: []
        \\
    , &why));
    try std.testing.expectError(error.BadCatalogue, gen.generate(a, base ++
        \\x-mopm-error-reasons:
        \\  b_code: [1, 2]
        \\
    , &why));
}
