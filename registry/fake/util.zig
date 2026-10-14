//! Small helpers: RFC 3339 times, token and id generation, name checks and
//! reading fields of a JSON request body.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `2026-10-13T12:00:00Z` for `secs` seconds after the epoch.
pub fn rfc3339(arena: Allocator, secs: i64) Allocator.Error![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// `2026-10-13` for `secs` seconds after the epoch.
pub fn date(arena: Allocator, secs: i64) Allocator.Error![]const u8 {
    const full = try rfc3339(arena, secs);
    return full[0..10];
}

/// A bearer token: `mopm_` and 32 characters of lowercase base32.
pub fn newToken(alloc: Allocator) Allocator.Error![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var out = try alloc.alloc(u8, 5 + bytes.len);
    @memcpy(out[0..5], "mopm_");
    for (bytes, 0..) |b, i| {
        out[5 + i] = alphabet[b & 31];
    }
    return out;
}

/// `<prefix>-` and 12 random hex digits.
pub fn newId(alloc: Allocator, prefix: []const u8) Allocator.Error![]const u8 {
    var bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ prefix, std.fmt.fmtSliceHexLower(&bytes) });
}

/// Whether `s` is a normalised package name: the `Name` pattern
/// (`^[a-z][a-z0-9_]{1,63}$`) and no run of underscores.
pub fn isName(s: []const u8) bool {
    if (s.len < 2 or s.len > 64 or !std.ascii.isLower(s[0])) return false;
    for (s, 0..) |c, i| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
        if (c == '_' and i > 0 and s[i - 1] == '_') return false;
    }
    return true;
}

/// `s` normalised as the API normalises names: lowercase, and each run of
/// `-`, `.` and `_` one `_`.
pub fn normalise(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (s) |c| {
        if (c == '-' or c == '.' or c == '_') {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '_') try out.append('_');
        } else try out.append(std.ascii.toLower(c));
    }
    return try out.toOwnedSlice();
}

fn number(s: []const u8) bool {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Whether `s` matches the API's `Version` pattern: `MAJOR.MINOR.PATCH`,
/// exactly three numbers without leading zeros, separated by dots.
pub fn isVersion(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) {
        if (!number(part)) return false;
    }
    return parts == 3;
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

test "rfc3339" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", try rfc3339(a, 0));
    try std.testing.expectEqualStrings("2026-10-13T12:05:09Z", try rfc3339(a, 1791893109));
    try std.testing.expectEqualStrings("2024-02-29", try date(a, 1709208000));
}

test "tokens and names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const t = try newToken(arena_state.allocator());
    try std.testing.expect(std.mem.startsWith(u8, t, "mopm_") and t.len == 37);
    for (t[5..]) |c| try std.testing.expect(std.ascii.isLower(c) or (c >= '2' and c <= '7'));
    try std.testing.expect(isName("http_client") and isName("ab"));
    try std.testing.expect(!isName("a") and !isName("Http") and !isName("http__client") and !isName("1http") and !isName("http-client"));
}

test "versions and normalised names" {
    for ([_][]const u8{ "0.0.0", "1.0.0", "0.4.0", "10.20.30", "1.10.100" }) |v| try std.testing.expect(isVersion(v));
    for ([_][]const u8{
        "",        "0",         "1",         "1.0",      "1.2.3.4",   "1.0.0.0", "1.",       ".1",
        "1..0",    "1.0.",      "01.0.0",    "1.00.0",   "1.0.00",    "v1.0.0",  "1.0rc1",   "1.0.0rc1",
        "1.0.0-rc.1", "1.0a1",  "1.0.0b2",   "1.0.0dev", "1.0.0.dev1", "1.0.0.post1", "1.0.0+local", " 1.0.0",
    }) |v| try std.testing.expect(!isVersion(v));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("http_client", try normalise(arena_state.allocator(), "Http-.Client"));
}
