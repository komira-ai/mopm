//! Tests of mopm.lock (lock.zig, spec/lock.md): the contract examples, each refusal, the layout of what is written.
//! mopm_core.zig runs them with the rest.

const std = @import("std");
const testroot = @import("testroot.zig");
const lock = @import("lock.zig");
const metadata = @import("metadata.zig");

const Lock = lock.Lock;
const parse = lock.parse;
const render = lock.render;

test "each valid example lock is read and written back byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        seen += 1;
        const text = try dir.readFileAlloc(a, entry.name, 1 << 20);
        var why: []const u8 = "";
        const l = parse(a, text, &why) catch |e| {
            std.debug.print("{s}: refused: {s}\n", .{ entry.name, why });
            return e;
        };
        try std.testing.expect(l.mojos.len > 0);
        std.testing.expectEqualStrings(text, try render(a, l)) catch |e| {
            std.debug.print("{s}: written differently\n", .{entry.name});
            return e;
        };
    }
    try std.testing.expect(seen >= 5);
}

test "each invalid example lock is refused, for the reason its name gives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "bad_sha256.json", "sha256 is not 64 lowercase hex digits" },
        .{ "bare_name.json", "http_core is not a full name (<namespace>/<name>)" },
        .{ "channel_not_listed.json", "komira-ai/http_core: channel https://conda.beta.mopm.dev/komira-ai/ is not a channel of the lock followed by komira-ai/" },
        .{ "channel_without_namespace.json", "komira-ai/http_core: channel https://conda.mopm.dev/ is not a channel of the lock followed by komira-ai/" },
        .{ "dep_not_in_lock.json", "is not in packages" },
        .{ "duplicate_entry.json", "not sorted by name, version and subdir with no repeats" },
        .{ "future_lock_version.json", "Update mopm." },
        .{ "http_non_loopback_channel.json", "channel http://conda.mopm.dev/channel/ is refused" },
        .{ "import_name_twice.json", "komira-ai/http_core and other-org/http_core have the same import name http_core; a closure holds one package per import name" },
        .{ "missing_build.json", "has no build" },
        .{ "loads_not_pinned.json", "which system_libs does not pin for linux-64" },
        .{ "mojo_mismatch.json", "an artifact for mojo 1.1.0, which the lock does not list in mojo" },
        .{ "name_from_two_channels.json", "comes from two channels" },
        .{ "native_bad_kind.json", "has kind weird; a kind is shared, static or both" },
        .{ "native_link_twice.json", "native library crypto_sys: link: 'm' is named twice" },
        .{ "native_link_unknown.json", "native library crypto_sys: link: '-lcurl' is not a system library a native may link" },
        .{ "native_need_not_string.json", "has a need that is not a string" },
        .{ "soname_clash.json", "is shipped by both" },
        .{ "stale_lock_version_2.json", "mopm.lock predates namespaces (lock_version 2); run 'mopm lock'" },
        .{ "system_lib_bad_sha256.json", "sha256 is not 64 lowercase hex digits" },
        .{ "system_libs_unsorted.json", "system_libs of linux-64 is not sorted by name with no repeats (at libsqlite)" },
        .{ "unsorted.json", "not sorted by name, version and subdir" },
        .{ "url_mismatch.json", "url is " },
        .{ "url_old_file_name.json", "komira-ai/http_core: url is https://conda.mopm.dev/komira-ai/linux-64/mojo-http_core-1.2.5-mojo1.0.0_0.conda, not https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_core-1.2.5-mojo1.0.0_0.conda" },
    };
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/invalid"), .{ .iterate = true });
    defer dir.close();
    var files: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |_| files += 1;
    // A new invalid example needs a case here.
    try std.testing.expectEqual(cases.len, files);
    for (cases) |case| {
        const text = try dir.readFileAlloc(a, case[0], 1 << 20);
        var why: []const u8 = "";
        if (parse(a, text, &why)) |_| {
            std.debug.print("{s}: accepted\n", .{case[0]});
            return error.TestUnexpectedResult;
        } else |e| {
            const want: anyerror = if (std.mem.eql(u8, case[0], "stale_lock_version_2.json")) error.Stale else error.Invalid;
            if (e != want) return e;
        }
        if (std.mem.indexOf(u8, why, case[1]) == null) {
            std.debug.print("{s}: refused with '{s}', want '{s}'\n", .{ case[0], why, case[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "a lock of version 1 or 2 is stale, whatever else is in it; a version above 3 asks to update mopm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    try std.testing.expectError(error.Stale, parse(a, "{\"lock_version\": 1}", &why));
    try std.testing.expectEqualStrings("mopm.lock predates namespaces (lock_version 1); run 'mopm lock'", why);
    try std.testing.expectError(error.Stale, parse(a, "{\"lock_version\": 2, \"packages\": 7}", &why));
    try std.testing.expectEqualStrings("mopm.lock predates namespaces (lock_version 2); run 'mopm lock'", why);
    try std.testing.expectEqualStrings(why, try lock.staleMessage(a, 2));
    try std.testing.expectError(error.Invalid, parse(a, "{\"lock_version\": 4}", &why));
    try std.testing.expectEqualStrings("lock_version is 4; this mopm reads 3. Update mopm.", why);
    try std.testing.expectError(error.Invalid, parse(a, "{\"lock_version\": 0}", &why));
    try std.testing.expectEqualStrings("lock_version 0 is not one mopm writes", why);
}

const sha_a = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

const one_package_template =
    \\{
    \\  "lock_version": 3,
    \\  "mojo": [
    \\    "1.0.0"
    \\  ],
    \\  "toolchain": {},
    \\  "channels": [
    \\    "@C@"
    \\  ],
    \\  "packages": [
    \\    {
    \\      "name": "komira-ai/tls",
    \\      "version": "1.1.0",
    \\      "subdir": "linux-64",
    \\      "channel": "@C@komira-ai/",
    \\      "artifacts": {
    \\        "1.0.0": {
    \\          "build": "mojo1.0.0_0",
    \\          "url": "@C@komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda",
    \\          "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    \\          "size": 1000
    \\        }
    \\      }
    \\    }
    \\  ]
    \\}
    \\
;

test "a channel may carry a path; its scheme is https, or http only to a loopback host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const accepted = [_][]const u8{
        "https://conda.mopm.dev/",
        "https://mopm.dev/channel/",
        "http://127.0.0.1:5000/channel/",
        "http://[::1]:8080/a/b/",
        "http://localhost:1/channel/",
    };
    for (accepted) |c| {
        const text = try std.mem.replaceOwned(u8, a, one_package_template, "@C@", c);
        var why: []const u8 = "";
        const l = parse(a, text, &why) catch |e| {
            std.debug.print("{s}: refused: {s}\n", .{ c, why });
            return e;
        };
        try std.testing.expectEqualStrings(text, try render(a, l));
    }
    const refused = [_][]const u8{
        "http://example.com/channel/",
        "http://conda.mopm.dev/",
        "http://127.0.0.2:80/channel/",
        "http://127.0.0.1/channel/",
        "http://localhost.evil:80/",
        "ftp://127.0.0.1:21/",
        "https:///",
        "https://mopm.dev/channel",
    };
    for (refused) |c| {
        const text = try std.mem.replaceOwned(u8, a, one_package_template, "@C@", c);
        var why: []const u8 = "";
        if (parse(a, text, &why)) |_| {
            std.debug.print("{s}: accepted\n", .{c});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        try std.testing.expect(std.mem.indexOf(u8, why, lock.channel_rule) != null);
    }
}

test "an entry's channel is a listed root followed by its namespace; the url names the conda package mojo-<namespace>.<name>" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try std.mem.replaceOwned(u8, a, one_package_template, "@C@", "https://conda.mopm.dev/");
    var why: []const u8 = "";
    _ = try parse(a, root, &why);
    const Case = struct { []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        // the root alone
        .{ "\"channel\": \"https://conda.mopm.dev/komira-ai/\"", "\"channel\": \"https://conda.mopm.dev/\"", "komira-ai/tls: channel https://conda.mopm.dev/ is not a channel of the lock followed by komira-ai/" },
        // another namespace's directory
        .{ "\"channel\": \"https://conda.mopm.dev/komira-ai/\"", "\"channel\": \"https://conda.mopm.dev/other-org/\"", "komira-ai/tls: channel https://conda.mopm.dev/other-org/ is not a channel of the lock followed by komira-ai/" },
        // a root the lock does not list
        .{ "\"channel\": \"https://conda.mopm.dev/komira-ai/\"", "\"channel\": \"https://conda.beta.mopm.dev/komira-ai/\"", "komira-ai/tls: channel https://conda.beta.mopm.dev/komira-ai/ is not a channel of the lock followed by komira-ai/" },
        // the file named by the import name alone
        .{ "mojo-komira-ai.tls-", "mojo-tls-", "komira-ai/tls: url is https://conda.mopm.dev/komira-ai/linux-64/mojo-tls-1.1.0-mojo1.0.0_0.conda, not https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda" },
        // the file in the root's directory, not the namespace's
        .{ "https://conda.mopm.dev/komira-ai/linux-64/mojo", "https://conda.mopm.dev/linux-64/mojo", "komira-ai/tls: url is https://conda.mopm.dev/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda, not https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda" },
    };
    for (cases) |case| {
        const bad = try std.mem.replaceOwned(u8, a, root, case[0], case[1]);
        try std.testing.expect(!std.mem.eql(u8, bad, root));
        try std.testing.expectError(error.Invalid, parse(a, bad, &why));
        try std.testing.expectEqualStrings(case[2], why);
    }
    try std.testing.expectEqualStrings(
        "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda",
        try lock.fileUrl(a, "https://conda.mopm.dev/komira-ai/", "linux-64", "komira-ai/tls", "1.1.0", "mojo1.0.0_0"),
    );
}

test "every name in a lock is a full name; two entries with one import name are refused, one name from two versions is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const text = try std.mem.replaceOwned(u8, a, one_package_template, "@C@", "https://conda.mopm.dev/");
    // A bare dependency name.
    const bare_dep = try std.mem.replaceOwned(u8, a, text, "\"channel\": \"https://conda.mopm.dev/komira-ai/\",\n", "\"channel\": \"https://conda.mopm.dev/komira-ai/\",\n      \"deps\": [\"tls\"],\n");
    try std.testing.expect(!std.mem.eql(u8, bare_dep, text));
    try std.testing.expectError(error.Invalid, parse(a, bare_dep, &why));
    try std.testing.expectEqualStrings("komira-ai/tls: dependency tls is not a full name (<namespace>/<name>)", why);
    // A namespace over 39 characters, an uppercase name, a name with two slashes.
    const bad_names = [_][]const u8{ "a" ** 40 ++ "/tls", "komira-ai/TLS", "komira-ai/tls/x", "-komira/tls", "komira-ai/t" };
    for (bad_names) |n| {
        const renamed = try std.mem.replaceOwned(u8, a, text, "\"name\": \"komira-ai/tls\"", try std.fmt.allocPrint(a, "\"name\": \"{s}\"", .{n}));
        try std.testing.expectError(error.Invalid, parse(a, renamed, &why));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} is not a full name (<namespace>/<name>)", .{n}), why);
    }
    // A path dependency's name is a full name too.
    const path_text =
        \\{
        \\  "lock_version": 3,
        \\  "mojo": [
        \\    "1.0.0"
        \\  ],
        \\  "toolchain": {},
        \\  "channels": [
        \\    "https://conda.mopm.dev/"
        \\  ],
        \\  "packages": [
        \\    {
        \\      "name": "local",
        \\      "version": "0.3.0",
        \\      "source": "path",
        \\      "path": "../local"
        \\    }
        \\  ]
        \\}
        \\
    ;
    try std.testing.expectError(error.Invalid, parse(a, path_text, &why));
    try std.testing.expectEqualStrings("local is not a full name (<namespace>/<name>)", why);

    // One import name under two namespaces, as entries of an in-memory lock.
    const arts_a = [_]lock.Artifact{.{ .mojo = "1.0.0", .build = "b", .url = "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.json-1.0.0-b.conda", .sha256 = sha_a, .size = 1 }};
    const arts_b = [_]lock.Artifact{.{ .mojo = "1.0.0", .build = "b", .url = "https://conda.mopm.dev/other-org/linux-64/mojo-other-org.json-1.0.0-b.conda", .sha256 = sha_a, .size = 1 }};
    var pa = lock.Package{ .name = "komira-ai/json", .version = "1.0.0", .subdir = "linux-64", .channel = "https://conda.mopm.dev/komira-ai/", .artifacts = &arts_a };
    const pb = lock.Package{ .name = "other-org/json", .version = "1.0.0", .subdir = "linux-64", .channel = "https://conda.mopm.dev/other-org/", .artifacts = &arts_b };
    const channels = [_][]const u8{"https://conda.mopm.dev/"};
    const mojos = [_][]const u8{"1.0.0"};
    var l = Lock{ .mojo = "1.0.0", .channels = &channels, .packages = &.{ pa, pb }, .mojos = &mojos };
    try std.testing.expectEqualStrings(
        "komira-ai/json and other-org/json have the same import name json; a closure holds one package per import name",
        (try lock.check(a, l)).?,
    );
    // Two versions of one full name (and two subdirs) are not a clash.
    var pc = pa;
    pc.version = "1.1.0";
    pc.artifacts = &[_]lock.Artifact{.{ .mojo = "1.0.0", .build = "b", .url = "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.json-1.1.0-b.conda", .sha256 = sha_a, .size = 1 }};
    l.packages = &.{ pa, pc };
    try std.testing.expect((try lock.check(a, l)) == null);
    // A path entry and a registry entry with one import name clash too.
    pa.source = .path;
    pa.path = "json";
    pa.artifacts = &.{};
    l.packages = &.{ pa, pb };
    try std.testing.expect((try lock.check(a, l)) != null);
}

test "a path dependency is locked with source path, its version and path, and no file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\{
        \\  "lock_version": 3,
        \\  "mojo": [
        \\    "1.0.0"
        \\  ],
        \\  "toolchain": {},
        \\  "channels": [
        \\    "https://conda.mopm.dev/"
        \\  ],
        \\  "packages": [
        \\    {
        \\      "name": "komira-ai/local",
        \\      "version": "0.3.0",
        \\      "source": "path",
        \\      "path": "../local",
        \\      "deps": [
        \\        "komira-ai/tls"
        \\      ]
        \\    },
        \\    {
        \\      "name": "komira-ai/tls",
        \\      "version": "1.1.0",
        \\      "subdir": "linux-64",
        \\      "channel": "https://conda.mopm.dev/komira-ai/",
        \\      "artifacts": {
        \\        "1.0.0": {
        \\          "build": "mojo1.0.0_0",
        \\          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda",
        \\          "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        \\          "size": 1000
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
        \\
    ;
    var why: []const u8 = "";
    const l = parse(a, text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(lock.Source.path, l.packages[0].source);
    try std.testing.expectEqualStrings("../local", l.packages[0].path);
    try std.testing.expectEqualStrings("", l.packages[0].sha256);
    try std.testing.expectEqual(lock.Source.registry, l.packages[1].source);
    try std.testing.expectEqualStrings(text, try render(a, l));

    const Case = struct { []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        .{ "\"path\": \"../local\",", "\"path\": \"../local\",\n      \"sha256\": \"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\",", "is a path dependency, which has no sha256" },
        .{ "\"source\": \"path\",", "\"source\": \"git\",", "source is git" },
        .{ "\"source\": \"path\",", "", "has a path but no \"source\": \"path\"" },
        .{ "\"path\": \"../local\",", "", "has no path" },
        .{ "\"path\": \"../local\",", "\"path\": \"\",", "a path dependency with an empty path" },
    };
    for (cases) |case| {
        if (std.mem.indexOf(u8, text, case[0]) == null) return error.TestUnexpectedResult;
        const bad = try std.mem.replaceOwned(u8, a, text, case[0], case[1]);
        why = "";
        if (parse(a, bad, &why)) |_| {
            std.debug.print("accepted, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        if (std.mem.indexOf(u8, why, case[2]) == null) {
            std.debug.print("refused with '{s}', want '{s}'\n", .{ why, case[2] });
            return error.TestUnexpectedResult;
        }
    }
    // The registry entry renamed to komira-ai/local (and the path entry's dependency with it): one name, locked
    // both as a path and from a channel.
    const twice = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, text, "\"name\": \"komira-ai/tls\",", "\"name\": \"komira-ai/local\","), "        \"komira-ai/tls\"\n", "        \"komira-ai/local\"\n");
    why = "";
    try std.testing.expectError(error.Invalid, parse(a, twice, &why));
    try std.testing.expectEqualStrings("komira-ai/local is locked as a path dependency and has another entry", why);
}

const lock_text =
    \\{
    \\  "lock_version": 3,
    \\  "mojo": [
    \\    "1.0.0",
    \\    "1.1.0"
    \\  ],
    \\  "toolchain": {
    \\    "1.0.0": {
    \\      "linux-64": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    \\    },
    \\    "1.1.0": {
    \\      "linux-64": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    \\    }
    \\  },
    \\  "channels": [
    \\    "https://conda.mopm.dev/"
    \\  ],
    \\  "packages": [
    \\    {
    \\      "name": "komira-ai/http_core",
    \\      "version": "1.2.5",
    \\      "subdir": "linux-64",
    \\      "channel": "https://conda.mopm.dev/komira-ai/",
    \\      "artifacts": {
    \\        "1.0.0": {
    \\          "build": "mojo1.0.0_0",
    \\          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_core-1.2.5-mojo1.0.0_0.conda",
    \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\          "size": 1000
    \\        },
    \\        "1.1.0": {
    \\          "build": "mojo1.1.0_0",
    \\          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_core-1.2.5-mojo1.1.0_0.conda",
    \\          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    \\          "size": 1100
    \\        }
    \\      },
    \\      "native": [
    \\        {
    \\          "id": "z",
    \\          "soname": "libz_native.so.1",
    \\          "sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "name": "komira-ai/http_server",
    \\      "version": "0.2.0",
    \\      "subdir": "linux-64",
    \\      "channel": "https://conda.mopm.dev/komira-ai/",
    \\      "artifacts": {
    \\        "1.1.0": {
    \\          "build": "mojo1.1.0_0",
    \\          "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_server-0.2.0-mojo1.1.0_0.conda",
    \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\          "size": 2000
    \\        }
    \\      },
    \\      "deps": [
    \\        "komira-ai/http_core"
    \\      ]
    \\    },
    \\    {
    \\      "name": "komira-ai/util",
    \\      "version": "0.3.0",
    \\      "source": "path",
    \\      "path": "util"
    \\    }
    \\  ]
    \\}
    \\
;

test "a lock is read and written back byte for byte; forMojo gives the lock of one Mojo version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: []const u8 = "";
    const l = parse(a, lock_text, &why) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
    try std.testing.expectEqual(@as(usize, 2), l.mojos.len);
    try std.testing.expectEqualStrings("1.0.0", l.mojo);
    try std.testing.expectEqual(@as(usize, 2), l.closures.len);
    try std.testing.expectEqual(@as(usize, 2), l.packages[0].artifacts.len);
    try std.testing.expectEqualStrings(lock_text, try render(a, l));

    // One Mojo version: the packages that have a build for it, flat.
    const v10 = try lock.forMojo(a, l, "1.0.0");
    try std.testing.expectEqual(@as(usize, 2), v10.packages.len); // http_core and util; http_server has no 1.0.0 build
    try std.testing.expectEqualStrings("mojo1.0.0_0", v10.packages[0].build);
    try std.testing.expectEqualStrings("a" ** 64, v10.packages[0].sha256);
    const v11 = try lock.forMojo(a, l, "1.1.0");
    try std.testing.expectEqual(@as(usize, 3), v11.packages.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", v11.packages[0].build);
    try std.testing.expectEqual(@as(u64, 1100), v11.packages[0].size);
    try std.testing.expectEqualStrings("1.1.0", v11.packages[0].mojo);

    // artifactFor and what the error words.
    try std.testing.expect(lock.artifactFor(l.packages[1], "1.0.0") == null);
    try std.testing.expect(lock.artifactFor(l.packages[2], "1.0.0") == null); // a path dependency has no build
    const published = try lock.publishedFor(a, l.packages[1]);
    try std.testing.expectEqualStrings(
        "komira-ai/http_server 0.2.0 has no .mojoc for Mojo 1.0.0 (published for: 1.1.0). Build with mojo 1.1.0, ask the publisher for a 1.0.0 build, or pin a version that has one.",
        try lock.noMojocMessage(a, "komira-ai/http_server", "0.2.0", "1.0.0", published),
    );
}

test "a lock built in memory with one Mojo version and flat entries is written in the layout of a lock with mojo and artifacts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const channels = [_][]const u8{"https://conda.mopm.dev/"};
    const pk = [_]lock.Package{.{
        .name = "komira-ai/tls",
        .version = "1.1.0",
        .build = "mojo1.0.0_0",
        .subdir = "linux-64",
        .channel = "https://conda.mopm.dev/komira-ai/",
        .url = "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.tls-1.1.0-mojo1.0.0_0.conda",
        .sha256 = sha_a,
        .size = 1000,
        .mojo = "1.0.0",
    }};
    const l = Lock{ .mojo = "1.0.0", .channels = &channels, .packages = &pk };
    try std.testing.expect((try lock.check(a, l)) == null);
    const text = try render(a, l);
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, one_package_template, "@C@", "https://conda.mopm.dev/"), text);
    var why: []const u8 = "";
    const back = try parse(a, text, &why);
    try std.testing.expectEqual(@as(usize, 1), back.mojos.len);
    try std.testing.expectEqualStrings("1.0.0", back.packages[0].artifacts[0].mojo);
    try std.testing.expectEqualStrings(text, try render(a, back));
    // The flat entry still has to be built with the lock's Mojo, and is checked against the flat url.
    var wrong = pk[0];
    wrong.mojo = "1.1.0";
    var l2 = l;
    l2.packages = &.{wrong};
    try std.testing.expectEqualStrings("komira-ai/tls: built with mojo 1.1.0, but the toolchain is mojo 1.0.0", (try lock.check(a, l2)).?);
}

test "a lock that breaks its rules is refused, saying which" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8, []const u8 };
    const url_10 = "mojo-komira-ai.http_core-1.2.5-mojo1.0.0_0.conda";
    const cases = [_]Case{
        // a build for a Mojo version the lock does not list
        .{ "\"1.0.0\": {\n          \"build\": \"mojo1.0.0_0\"", "\"1.2.0\": {\n          \"build\": \"mojo1.0.0_0\"", "komira-ai/http_core: an artifact for mojo 1.2.0, which the lock does not list in mojo" },
        // a toolchain closure for a Mojo version the lock does not list
        .{ "\"mojo\": [\n    \"1.0.0\",\n    \"1.1.0\"\n  ]", "\"mojo\": [\n    \"1.1.0\"\n  ]", "toolchain names mojo 1.0.0, which the lock does not list in mojo" },
        // mojo out of order
        .{ "\"mojo\": [\n    \"1.0.0\",\n    \"1.1.0\"\n  ]", "\"mojo\": [\n    \"1.1.0\",\n    \"1.0.0\"\n  ]", "mojo is not sorted with no repeats (at 1.0.0)" },
        // a url that is not the build's
        .{ url_10, "mojo-komira-ai.http_core-1.2.5-mojo9.9.9_0.conda", "komira-ai/http_core: url is https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_core-1.2.5-mojo9.9.9_0.conda, not https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_core-1.2.5-mojo1.0.0_0.conda" },
        // a flat key in an entry
        .{ "\"subdir\": \"linux-64\",\n      \"channel\": \"https://conda.mopm.dev/komira-ai/\",\n      \"artifacts\": {\n        \"1.0.0\"", "\"subdir\": \"linux-64\",\n      \"mojo\": \"1.0.0\",\n      \"channel\": \"https://conda.mopm.dev/komira-ai/\",\n      \"artifacts\": {\n        \"1.0.0\"", "packages[0] has mojo; it belongs under artifacts" },
        // no artifacts
        .{ "\"artifacts\": {\n        \"1.1.0\": {\n          \"build\": \"mojo1.1.0_0\",\n          \"url\": \"https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.http_server-0.2.0-mojo1.1.0_0.conda\",\n          \"sha256\": \"" ++ "a" ** 64 ++ "\",\n          \"size\": 2000\n        }\n      },", "", "packages[1] has no artifacts" },
        // the dependency of an entry that is not a full name
        .{ "\"komira-ai/http_core\"\n      ]", "\"http_core\"\n      ]", "komira-ai/http_server: dependency http_core is not a full name (<namespace>/<name>)" },
    };
    for (cases) |case| {
        if (std.mem.indexOf(u8, lock_text, case[0]) == null) {
            std.debug.print("the case's text is not in the lock: {s}\n", .{case[0]});
            return error.TestUnexpectedResult;
        }
        const bad_text = try std.mem.replaceOwned(u8, a, lock_text, case[0], case[1]);
        var why: []const u8 = "";
        if (parse(a, bad_text, &why)) |_| {
            std.debug.print("accepted, want: {s}\n", .{case[2]});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.Invalid) return e;
        try std.testing.expectEqualStrings(case[2], why);
    }
    // A Mojo version that mopm pins no toolchain for needs no closure: take the 1.1.0 closure out.
    const gone = try std.mem.replaceOwned(u8, a, lock_text, ",\n    \"1.1.0\": {\n      \"linux-64\": \"" ++ "d" ** 64 ++ "\"\n    }", "");
    try std.testing.expect(!std.mem.eql(u8, gone, lock_text));
    var why: []const u8 = "";
    const l = try parse(a, gone, &why);
    try std.testing.expectEqual(@as(usize, 1), l.closures.len);
    try std.testing.expectEqualStrings(gone, try render(a, l));
}

test "a native library keeps its kind, needs and exclusive group through a read and a write; a shared one with none of them writes none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{});
    defer dir.close();
    const text = try dir.readFileAlloc(a, "static_natives.json", 1 << 20);
    var why: []const u8 = "";
    const l = try parse(a, text, &why);
    try std.testing.expectEqual(@as(usize, 2), l.packages.len);
    const crypto = l.packages[0].native[0];
    try std.testing.expectEqual(metadata.Kind.static, crypto.kind);
    try std.testing.expectEqualStrings("libcrypto", crypto.exclusive);
    try std.testing.expectEqual(@as(usize, 0), crypto.needs.len);
    try std.testing.expectEqualStrings("5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9", crypto.sha256.?);
    const tls = l.packages[1].native[0];
    try std.testing.expectEqual(metadata.Kind.static, tls.kind);
    try std.testing.expectEqual(@as(usize, 1), tls.needs.len);
    try std.testing.expectEqualStrings("libcrypto_sys.a", tls.needs[0]);
    try std.testing.expectEqualStrings("", tls.exclusive);

    // A native with only an id and a soname reads as a shared library, and writes back with no new key.
    const plain = try std.mem.replaceOwned(u8, a, text, ",\n          \"kind\": \"static\",\n          \"exclusive\": \"libcrypto\"", "");
    const p = try parse(a, plain, &why);
    try std.testing.expectEqual(metadata.Kind.shared, p.packages[0].native[0].kind);
    const written = try render(a, p);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"exclusive\"") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\"kind\""));
}

test "a native library that needs its own soname is refused when the lock is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{});
    defer dir.close();
    const text = try dir.readFileAlloc(a, "static_natives.json", 1 << 20);
    const selfish = try std.mem.replaceOwned(u8, a, text, "\"libcrypto_sys.a\"\n          ]", "\"libtls_sys.a\"\n          ]");
    try std.testing.expect(!std.mem.eql(u8, text, selfish));
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, parse(a, selfish, &why));
    try std.testing.expectEqualStrings("komira-ai/tls_sys: native library tls_sys needs itself (libtls_sys.a)", why);
}

// Defects it catches: the system libraries of a package dropped on reading a lock (a unit graph made from it then links
// a C++ archive without libc++), or written back differently; a library that is not static carrying them.
test "a lock keeps the link names of a native through a read and a write, and a native without them writes none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.fs.cwd().openDir(try testroot.path(a, "tests/contract/examples/lock/valid"), .{});
    defer dir.close();
    const text = try dir.readFileAlloc(a, "static_link.json", 1 << 20);
    var why: []const u8 = "";
    const l = try parse(a, text, &why);
    const crypto = l.packages[0].native[0];
    try std.testing.expectEqual(@as(usize, 1), crypto.link.len);
    try std.testing.expectEqualStrings("c++", crypto.link[0]);
    const tls = l.packages[1].native[0];
    try std.testing.expectEqual(@as(usize, 2), tls.link.len);
    try std.testing.expectEqualStrings("c++", tls.link[0]);
    try std.testing.expectEqualStrings("m", tls.link[1]);
    try std.testing.expectEqualStrings(text, try render(a, l));

    const plain = try dir.readFileAlloc(a, "static_natives.json", 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, try render(a, try parse(a, plain, &why)), "\"link\"") == null);

    // A link on a library that is not static is refused.
    const shared = try std.mem.replaceOwned(u8, a, text, "\"kind\": \"static\",\n          \"exclusive\"", "\"exclusive\"");
    try std.testing.expectError(error.Invalid, parse(a, shared, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "has a link but is not static") != null);
}
