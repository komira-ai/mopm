//! What tools/api_gen.zig makes of the registry API's protos: the files are read from `spec/api` by following the imports
//! of `mopm/registry/v2/registry.proto` (each file's imports before it, each file once; `google/...` and options.proto are
//! not read: the parser knows their options), parsed into one model, and written as the three outputs. Shared by the tool
//! (tools/api_gen.zig), which writes them, and by the test that the checked-in copies are current (tools/api_gen_test.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");
const openapi = @import("openapi.zig");
const typescript = @import("typescript.zig");
const zig_client = @import("zig_client.zig");

/// The proto root, relative to the repository root; imports are relative to it.
pub const proto_root = "spec/api";
/// The file whose imports name every other one.
pub const entry = "mopm/registry/v2/registry.proto";

/// One generated file: where it goes, relative to the repository root, and its text.
pub const Output = struct { path: []const u8, text: []const u8 };

pub const outputs = [_][]const u8{
    "spec/api/openapi-v2.yaml",
    "service/api/src/gen/registry-v2.ts",
    "src/core/registry_v2.zig",
};

pub const Generated = union(enum) {
    ok: [outputs.len]Output,
    /// What is wrong, naming the file and line.
    bad: []const u8,
};

/// Whether `import` is one of the API's own files, which are read (not google's, not the options).
fn ownImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "mopm/") and !std.mem.endsWith(u8, path, "/options.proto");
}

/// The sources from `entry` in import order, read below `root` (the repository root).
pub fn sources(arena: Allocator, root: std.fs.Dir) !union(enum) { ok: []const proto.Source, bad: []const u8 } {
    var list = std.ArrayList(proto.Source).init(arena);
    var seen = std.StringHashMap(void).init(arena);
    var visiting = std.StringHashMap(void).init(arena);
    const Walk = struct {
        fn visit(a: Allocator, r: std.fs.Dir, path: []const u8, l: *std.ArrayList(proto.Source), done: *std.StringHashMap(void), open: *std.StringHashMap(void)) !?[]const u8 {
            if (done.contains(path)) return null;
            if (open.contains(path)) return try std.fmt.allocPrint(a, "{s}: imports itself, through its imports", .{path});
            try open.put(path, {});
            const full = try std.fs.path.join(a, &.{ proto_root, path });
            const text = r.readFileAlloc(a, full, 1 << 20) catch |e| return try std.fmt.allocPrint(a, "{s}: cannot be read: {s}", .{ full, @errorName(e) });
            for (try proto.imports(a, text)) |imp| {
                if (!ownImport(imp)) continue;
                if (try visit(a, r, imp, l, done, open)) |why| return why;
            }
            _ = open.remove(path);
            try done.put(path, {});
            try l.append(.{ .path = path, .text = text });
            return null;
        }
    };
    if (try Walk.visit(arena, root, entry, &list, &seen, &visiting)) |why| return .{ .bad = why };
    return .{ .ok = try list.toOwnedSlice() };
}

/// The three outputs of the protos below `root`.
pub fn generate(arena: Allocator, root: std.fs.Dir) !Generated {
    const srcs = switch (try sources(arena, root)) {
        .ok => |s| s,
        .bad => |why| return .{ .bad = why },
    };
    const api = switch (try proto.parse(arena, srcs)) {
        .ok => |a| a,
        .bad => |why| return .{ .bad = why },
    };
    const yaml = switch (try openapi.write(arena, api)) {
        .ok => |t| t,
        .bad => |why| return .{ .bad = why },
    };
    const ts = switch (try typescript.generate(arena, api)) {
        .ok => |t| t,
        .bad => |why| return .{ .bad = why },
    };
    var diag: ?[]const u8 = null;
    const zig = zig_client.writeDiag(arena, api, &diag) catch |e| switch (e) {
        error.Invalid => return .{ .bad = diag orelse "the Zig client cannot be written" },
        else => |other| return other,
    };
    return .{ .ok = .{
        .{ .path = outputs[0], .text = yaml },
        .{ .path = outputs[1], .text = ts },
        .{ .path = outputs[2], .text = zig },
    } };
}

/// Null when `have` (the checked-in text of `path`) is `want`; otherwise what differs: the first line that does.
pub fn drift(arena: Allocator, path: []const u8, want: []const u8, have: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, want, have)) return null;
    var w = std.mem.splitScalar(u8, want, '\n');
    var h = std.mem.splitScalar(u8, have, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const wl = w.next();
        const hl = h.next();
        if (wl == null and hl == null) break;
        if (wl == null or hl == null or !std.mem.eql(u8, wl.?, hl.?)) {
            return try std.fmt.allocPrint(arena, "{s}:{d}: is not what tools/api_gen.zig makes of spec/api/mopm/registry/v2/*.proto; run 'zig build gen-api'\n  generated: {s}\n  checked in: {s}", .{
                path,
                line,
                wl orelse "(end of file)",
                hl orelse "(end of file)",
            });
        }
    }
    return try std.fmt.allocPrint(arena, "{s}: is not what tools/api_gen.zig makes of spec/api/mopm/registry/v2/*.proto; run 'zig build gen-api'", .{path});
}
