//! The names of a mopm.toml (src/core/names.zig): a full name split into its namespace and import name, the
//! library directory rule, and the refusal of a dependency without a namespace. The goldens of tests/manifest hold
//! each message; these hold what the goldens cannot (the parsed fields, many paths, and the escapes of the message).

const std = @import("std");
const testing = std.testing;
const manifest = @import("manifest.zig");

test "a full name is split into its namespace and its import name, for the package and each dependency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: manifest.Diagnostic = .{};
    const src =
        \\[package]
        \\name = "komira-ai/parquet"
        \\version = "0.2.0"
        \\
        \\[dependencies]
        \\"komira-ai/json" = "0.1"
        \\"alice/zstd" = { version = "1.4" }
        \\
        \\[dev-dependencies]
        \\"komira-ai/testkit" = { path = "../testkit" }
        \\
    ;
    const m = try manifest.parse(a, src, &diag);
    try testing.expectEqualStrings("komira-ai/parquet", m.package.full_name);
    try testing.expectEqualStrings("komira-ai", m.package.namespace);
    try testing.expectEqualStrings("parquet", m.package.name);
    const want = [_][3][]const u8{ .{ "komira-ai/json", "komira-ai", "json" }, .{ "alice/zstd", "alice", "zstd" }, .{ "komira-ai/testkit", "komira-ai", "testkit" } };
    const got = [_]manifest.Dep{ m.dependencies[0], m.dependencies[1], m.dev_dependencies[0] };
    for (want, got) |w, d| {
        try testing.expectEqualStrings(w[0], d.full_name);
        try testing.expectEqualStrings(w[1], d.namespace);
        try testing.expectEqualStrings(w[2], d.name);
    }
}

test "the library directory is the import name: a trailing '/' is the same directory, '.' or another name is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: manifest.Diagnostic = .{};
    const head = "[package]\nname = \"example/json\"\nversion = \"0.1.0\"\n\n[targets]\n";
    for ([_][]const u8{ "src/json", "src/json/", "json", "lib/mojo/json" }) |p| {
        const text = try std.fmt.allocPrint(a, "{s}lib = {{ path = \"{s}\" }}\n", .{ head, p });
        const m = manifest.parse(a, text, &diag) catch |e| {
            std.debug.print("refused {s}: {s}\n", .{ p, diag.message });
            return e;
        };
        try testing.expectEqualStrings(p, m.targets.lib.?);
    }
    for ([_][]const u8{ ".", "src", "src/json/x", "src/JSON", "src/json_" }) |p| {
        const text = try std.fmt.allocPrint(a, "{s}lib = {{ path = \"{s}\" }}\n", .{ head, p });
        try testing.expectError(error.Invalid, manifest.parse(a, text, &diag));
        const want = try std.fmt.allocPrint(a, "'lib' in [targets]: the path '{s}' ends in '{s}', not in the import name 'json'", .{ p, std.fs.path.basenamePosix(p) });
        try testing.expect(std.mem.startsWith(u8, diag.message, want));
    }
}

test "a dependency without a namespace is refused with its entry written in full, its strings escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "[package]\nname = \"example/app\"\nversion = \"0.1.0\"\n\n[dependencies]\n";
    const cases = [_][2][]const u8{
        // A value that is neither a string nor a table, and a table whose keys are not strings or not known.
        .{ "json = 1\n", "dependency 'json' has no namespace: write it \"<namespace>/json\" = ..." },
        .{ "json = { version = 1, path = \"../j\" }\n", "dependency 'json' has no namespace: write it \"<namespace>/json\" = { path = \"../j\" }" },
        .{ "json = { git = \"x\" }\n", "dependency 'json' has no namespace: write it \"<namespace>/json\" = {  }" },
        .{ "json = { path = 'a\"b\\c' }\n", "dependency 'json' has no namespace: write it \"<namespace>/json\" = { path = \"a\\\"b\\\\c\" }" },
    };
    for (cases) |cs| {
        var diag: manifest.Diagnostic = .{};
        try testing.expectError(error.Invalid, manifest.parse(a, try std.fmt.allocPrint(a, "{s}{s}", .{ head, cs[0] }), &diag));
        try testing.expectEqualStrings(cs[1], diag.message);
    }
}
