//! `source_commit` of a commit request (spec/api/openapi.yaml, `SourceCommit`): the git commit the publisher says a version was
//! built from. Optional; exactly 40 or 64 lowercase hex digits; anything else is `invalid_request`. The fake stores it once with
//! the version and serves it from getVersion; like the registry it does not check it against anything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Parsed = union(enum) { absent, ok: []const u8, invalid };

/// The value of `source_commit` in a commit body (a single publish, or one member of a group commit).
pub fn parse(obj: ObjectMap) Parsed {
    const v = obj.get("source_commit") orelse return .absent;
    const text = switch (v) {
        .string => |s| s,
        else => return .invalid,
    };
    if (!isCommitId(text)) return .invalid;
    return .{ .ok = text };
}

pub fn isCommitId(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The `detail` of the invalid_request answer; `whose` is " of 'name'" for a group member, or "".
pub fn refusal(arena: Allocator, whose: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "'source_commit'{s} is a git commit id: 40 or 64 lowercase hex digits", .{whose});
}

/// Whether two values (each possibly absent) are the same.
pub fn same(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "a commit id is 40 or 64 lowercase hex digits" {
    const ok = [_][]const u8{ "a" ** 40, "0123456789abcdef" ** 4 };
    for (ok) |s| try std.testing.expect(isCommitId(s));
    const bad = [_][]const u8{ "", "A" ** 40, "a" ** 39, "a" ** 41, "a" ** 63, "a" ** 65, "g" ** 40, (" " ++ ("a" ** 39)), "a" ** 40 ++ "\n" };
    for (bad) |s| try std.testing.expect(!isCommitId(s));
}

test "parse tells absent from invalid: a value that is not a string, and null, are invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Want = enum { absent, ok, invalid };
    const cases = [_]struct { json: []const u8, want: Want }{
        .{ .json = "{}", .want = .absent },
        .{ .json = "{\"source_commit\":\"" ++ ("a" ** 40) ++ "\"}", .want = .ok },
        .{ .json = "{\"source_commit\":null}", .want = .invalid },
        .{ .json = "{\"source_commit\":7}", .want = .invalid },
        .{ .json = "{\"source_commit\":[\"" ++ ("a" ** 40) ++ "\"]}", .want = .invalid },
        .{ .json = "{\"source_commit\":\"ABC\"}", .want = .invalid },
    };
    for (cases) |c| {
        const v = try std.json.parseFromSliceLeaky(Value, a, c.json, .{});
        const got: Want = switch (parse(v.object)) {
            .absent => .absent,
            .ok => .ok,
            .invalid => .invalid,
        };
        try std.testing.expectEqual(c.want, got);
    }
}
