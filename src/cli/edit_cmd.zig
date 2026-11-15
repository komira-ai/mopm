//! `mopm add` and `mopm remove`: change one dependency of mopm.toml through
//! core/toml_edit.zig, then lock again (see install_cmd.zig for the commands'
//! behaviour).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const semver = core.semver;
const resolve = core.resolve;
const toml_edit = core.toml_edit;
const v2 = core.registry_v2;
const ic = @import("install_cmd.zig");
const Net = @import("group_io.zig").Net;

const Args = ic.Args;
const Command = ic.Command;
const err = ic.err;
const manifest_path = ic.manifest_path;
const parseManifest = ic.parseManifest;
const parseManifestFor = ic.parseManifestFor;
const readLockStale = ic.readLockStale;
const projectOf = ic.projectOf;
const resolveProject = ic.resolveProject;
const writeLock = ic.writeLock;

/// `<package>[@<requirement>]`: the name and the requirement, if any.
const Spec = struct { name: []const u8, req: ?[]const u8 };

fn splitSpec(spec: []const u8) Spec {
    const at = std.mem.indexOfScalar(u8, spec, '@') orelse return .{ .name = spec, .req = null };
    return .{ .name = spec[0..at], .req = spec[at + 1 ..] };
}

/// Why `full` cannot name a dependency (`<namespace>/<name>`), or null. A bare name gets the form to write.
fn specProblem(arena: Allocator, full: []const u8) Allocator.Error!?[]const u8 {
    if (core.names.split(full) == null) {
        return try std.fmt.allocPrint(arena, "dependency '{s}' has no namespace: write it as <namespace>/<name>, as in 'mopm add <namespace>/<name>'", .{full});
    }
    return core.names.fullNameProblem(arena, "dependency", full, .allow);
}

/// Packages a refusal of a bare name lists, at most.
const max_suggested = 5;
/// The page size asked of the search (the registry's largest).
const search_limit = 100;

/// `dependency '<bare>' has no namespace` as `specProblem` words it, with nothing about the registry.
fn bareProblem(arena: Allocator, bare: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "dependency '{s}' has no namespace: write it as <namespace>/<name>, as in 'mopm add <namespace>/<name>'", .{bare});
}

/// The refusal of the bare dependency name `bare`. `found` is the full names a search of the registry's `stage` for
/// `bare` returned, or null when the registry or the search could not be read (then the refusal says nothing of the
/// registry). Only the packages whose name part is `bare` are listed, at most `max_suggested`, in the registry's order.
fn bareMessage(arena: Allocator, bare: []const u8, stage: []const u8, found: ?[]const []const u8) Allocator.Error![]const u8 {
    const all = found orelse return bareProblem(arena, bare);
    var kept = std.ArrayList([]const u8).init(arena);
    for (all) |full| {
        if (kept.items.len == max_suggested) break;
        const parts = core.names.split(full) orelse continue;
        if (std.mem.eql(u8, parts.name, bare)) try kept.append(full);
    }
    if (kept.items.len == 0) {
        return std.fmt.allocPrint(arena, "dependency '{s}' has no namespace: write it as <namespace>/{s}; no package on {s} is named {s}", .{ bare, bare, stage, bare });
    }
    const list = try std.mem.join(arena, ", ", kept.items);
    return std.fmt.allocPrint(arena, "dependency '{s}' has no namespace: write it as <namespace>/{s}; packages named {s} on {s}: {s} (as in 'mopm add {s}')", .{ bare, bare, bare, stage, list, kept.items[0] });
}

/// The full names of the first page of `GET <api_v2_url>/packages?q=<bare>` (no token), in the registry's order; null
/// when the request fails, is not answered 2xx or is not a package list.
fn searchNames(arena: Allocator, net: Net, api_v2_url: []const u8, bare: []const u8) Allocator.Error!?[]const []const u8 {
    if (api_v2_url.len == 0) return null;
    const answer = v2.sendOnce(v2.SearchPackages, arena, net, api_v2_url, null, .{ .q = bare, .limit = search_limit }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!answer.ok()) return null;
    const hits = v2.decode(v2.SearchPackages, arena, answer.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var out = std.ArrayList([]const u8).init(arena);
    for (hits.packages) |h| try out.append(h.name);
    return out.items;
}

/// The refusal of the bare dependency name `bare` for the registry `registry_spec` (`--registry`): asks it which
/// packages are named `bare`. Reading the registry never fails the refusal; it only leaves the suggestion out.
fn bareRefusal(arena: Allocator, net: Net, registry_spec: []const u8, cli_version: []const u8, bare: []const u8) Allocator.Error![]const u8 {
    const plain = try bareProblem(arena, bare);
    if (bare.len == 0) return plain;
    const base = switch (core.registry.resolve(registry_spec)) {
        .ok => |b| b,
        .bad => return plain,
    };
    const loaded = core.registry.load(arena, base, cli_version) catch return plain;
    const config = switch (loaded) {
        .ok => |c| c,
        .bad => return plain,
    };
    return bareMessage(arena, bare, config.stage, try searchNames(arena, net, config.api_v2_url, bare));
}

/// `s` as a TOML basic string.
fn tomlString(arena: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    try out.append('"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        0...0x1f, 0x7f => try out.writer().print("\\u{x:0>4}", .{c}),
        else => try out.append(c),
    };
    try out.append('"');
    return out.toOwnedSlice();
}

/// The requirement `add` writes for the version it picked: `^X.Y.Z`.
fn caretOf(arena: Allocator, version: []const u8) ![]const u8 {
    const v = resolve.semverOf(version) orelse return std.fmt.allocPrint(arena, "^{s}", .{version});
    return std.fmt.allocPrint(arena, "^{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

/// The TOML value `add` writes: `{ path = "<dir>" }` for a path dependency,
/// else the requirement as a string.
fn depValue(arena: Allocator, req: []const u8, path: ?[]const u8) ![]const u8 {
    if (path) |p| return std.fmt.allocPrint(arena, "{{ path = {s} }}", .{try tomlString(arena, p)});
    return tomlString(arena, req);
}

const Edited = union(enum) { ok: []const u8, bad: []const u8 };

/// `setKey` for `add`, `removeKey` for `remove` (null: no such entry).
fn applyEdit(arena: Allocator, cmd: Command, src: []const u8, table: []const u8, name: []const u8, value: []const u8) anyerror!?[]const u8 {
    if (cmd == .remove) return toml_edit.removeKey(arena, src, table, name);
    return try toml_edit.setKey(arena, src, table, name, value);
}

/// mopm.toml's text `src` with `name` set to `value` (`add`) or taken out
/// (`remove`, which ignores `value`) in [dependencies], or with `dev` in
/// [dev-dependencies]. Every other byte is kept.
fn editText(arena: Allocator, cmd: Command, src: []const u8, dev: bool, name: []const u8, value: []const u8) !Edited {
    const table = if (dev) "dev-dependencies" else "dependencies";
    const result = applyEdit(arena, cmd, src, table, name, value) catch |e| switch (e) {
        error.UnsupportedEdit => return .{ .bad = try std.fmt.allocPrint(arena, "[{s}] of {s} is written in a form mopm does not edit (a dotted key, an inline table or [[{s}]]); edit it by hand", .{ table, manifest_path, table }) },
        error.InvalidToml => return .{ .bad = try std.fmt.allocPrint(arena, "{s} with {s} = {s} in [{s}] would not be a TOML file mopm reads", .{ manifest_path, name, value, table }) },
        else => return e,
    };
    return .{ .ok = result orelse return .{ .bad = try std.fmt.allocPrint(arena, "{s} is not a dependency: [{s}] of {s} does not name it", .{ name, table, manifest_path }) } };
}

/// `mopm add` and `mopm remove`: edit one entry of mopm.toml, resolve the
/// edited manifest, and only then write mopm.toml and mopm.lock.
pub fn edit(arena: Allocator, cmd: Command, args: Args, cli_version: []const u8) !u8 {
    const spec = splitSpec(args.spec);
    // A bare name is refused; `add` asks the registry only for the names to suggest, and nothing is written. `remove`
    // asks nothing: the refusal below says how to name the entry to remove.
    if (cmd == .add and core.names.split(spec.name) == null) {
        err(cmd, "{s}\n", .{try bareRefusal(arena, @import("group_io.zig").realNet(), args.registry, cli_version, spec.name)});
        return 1;
    }
    if (try specProblem(arena, spec.name)) |why| {
        err(cmd, "{s}\n", .{why});
        return 1;
    }
    if (spec.req) |r| {
        var why: []const u8 = "";
        _ = semver.parseReq(arena, r, &why) catch |e| switch (e) {
            error.Invalid => {
                err(cmd, "{s}@{s}: invalid version requirement: {s}\n", .{ spec.name, r, why });
                return 1;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    const src = std.fs.cwd().readFileAlloc(arena, manifest_path, 1 << 20) catch |e| {
        if (e == error.FileNotFound) {
            err(cmd, "no {s} in this directory\n", .{manifest_path});
            return 1;
        }
        return e;
    };
    _ = (try parseManifestFor(arena, cmd, manifest_path, src, .{ .registry = args.registry, .cli_version = cli_version })) orelse return 1;
    // A lock that predates namespaces is no lock: `add` and `remove` write a new one.
    var stale: ?[]const u8 = null;
    const old = readLockStale(arena, cmd, &stale) catch |e| {
        if (e == error.Invalid) return 1;
        return e;
    };

    // Without a requirement, any version: the resolver picks the newest that
    // fits, and the caret requirement on it is written below.
    const trial_value = try depValue(arena, spec.req orelse "*", args.path);
    const trial = switch (try editText(arena, cmd, src, args.dev, spec.name, trial_value)) {
        .ok => |t| t,
        .bad => |why| {
            err(cmd, "{s}\n", .{why});
            return 1;
        },
    };
    const m = (try parseManifest(arena, cmd, manifest_path, trial)) orelse return 1;
    if (m.mojo.len == 0) {
        err(cmd, "{s} has no [toolchain] mojo; a lock pins the one compiler every package is built with\n", .{manifest_path});
        return 1;
    }
    const project = (try projectOf(arena, cmd, m)) orelse return 1;
    var resolve_args = args;
    resolve_args.packages = if (cmd == .add) try arena.dupe([]const u8, &.{spec.name}) else &.{};
    const r = (try resolveProject(arena, cmd, project, old, resolve_args, cli_version)) orelse return 1;

    var final = trial;
    if (cmd == .add and spec.req == null and args.path == null) {
        const picked = r.lock.versionOf(spec.name) orelse return error.AddedPackageNotLocked;
        final = switch (try editText(arena, cmd, src, args.dev, spec.name, try tomlString(arena, try caretOf(arena, picked)))) {
            .ok => |t| t,
            .bad => |why| {
                err(cmd, "{s}\n", .{why});
                return 1;
            },
        };
    }
    try std.fs.cwd().writeFile(manifest_path, final);
    try writeLock(arena, old, r);
    return 0;
}

test "a package spec, the caret requirement add writes, and TOML values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("tls", splitSpec("tls").name);
    try std.testing.expect(splitSpec("tls").req == null);
    try std.testing.expectEqualStrings("tls", splitSpec("tls@>=1.2, <2").name);
    try std.testing.expectEqualStrings(">=1.2, <2", splitSpec("tls@>=1.2, <2").req.?);
    try std.testing.expectEqualStrings("^0.5.0", try caretOf(a, "0.5.0"));
    try std.testing.expectEqualStrings("^1.0.0", try caretOf(a, "1.0")); // a two-part index version is X.Y.0
    try std.testing.expectEqualStrings("\"^1.2.5\"", try depValue(a, "^1.2.5", null));
    try std.testing.expectEqualStrings("{ path = \"../local\" }", try depValue(a, "*", "../local"));
    try std.testing.expectEqualStrings("{ path = \"a\\\\b \\\"q\\\" \\u0009\" }", try depValue(a, "*", "a\\b \"q\" \t"));
}

// The golden files of the add/remove tests: every byte outside the edited
// entry must survive, so each comparison is of the whole file.
const golden_before =
    \\# The project. Comments, blank lines, order and spacing survive add and remove.
    \\[package]
    \\name    = "example/app"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"   # one compiler
    \\
    \\[dependencies]
    \\# transport
    \\"example/tls"   =   "1"        # the major only
    \\"example/legacy" = "1"
    \\
    \\[dev-dependencies]  # tests only
    \\
    \\# trailing comment
    \\
;

test "a dependency is named by a full name, and a bare one is refused with the form to write" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try specProblem(a, "komira-ai/json")) == null);
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/<name>, as in 'mopm add <namespace>/<name>'",
        (try specProblem(a, "json")).?,
    );
    try std.testing.expectEqualStrings(
        "dependency 'Komira-AI/json' is not in lower case; write 'komira-ai/json'",
        (try specProblem(a, "Komira-AI/json")).?,
    );
    try std.testing.expectEqualStrings(
        "dependency 'komira-ai/fn': the import name 'fn' is a Mojo keyword; choose another name",
        (try specProblem(a, "komira-ai/fn")).?,
    );
    try std.testing.expectEqualStrings("json", core.names.importName("komira-ai/json"));
    try std.testing.expectEqualStrings("komira-ai/json", splitSpec("komira-ai/json@^1.2").name);
    try std.testing.expectEqualStrings("^1.2", splitSpec("komira-ai/json@^1.2").req.?);
}

test "add writes the full name as a quoted key, and remove finds it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const added = (try editText(a, .add, golden_before, false, "komira-ai/json", "\"^0.5.0\"")).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "example/app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\"example/tls"   =   "1"        # the major only
        \\"example/legacy" = "1"
        \\"komira-ai/json" = "^0.5.0"
        \\
        \\[dev-dependencies]  # tests only
        \\
        \\# trailing comment
        \\
    , added);
    const removed = (try editText(a, .remove, added, false, "komira-ai/json", "")).ok;
    try std.testing.expectEqualStrings(golden_before, removed);
    try std.testing.expectEqualStrings("json is not a dependency: [dependencies] of mopm.toml does not name it", (try editText(a, .remove, added, false, "json", "")).bad);
}

test "add keeps every other byte of mopm.toml, in [dependencies] and [dev-dependencies]" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one = (try editText(a, .add, golden_before, false, "example/http_client", try depValue(a, try caretOf(a, "0.5.0"), null))).ok;
    const two = (try editText(a, .add, one, true, "example/http_core", try depValue(a, try caretOf(a, "1.2.5"), null))).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "example/app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\"example/tls"   =   "1"        # the major only
        \\"example/legacy" = "1"
        \\"example/http_client" = "^0.5.0"
        \\
        \\[dev-dependencies]  # tests only
        \\"example/http_core" = "^1.2.5"
        \\
        \\# trailing comment
        \\
    , two);
    const path = (try editText(a, .add, golden_before, false, "example/local", try depValue(a, "*", "local"))).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "example/app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\"example/tls"   =   "1"        # the major only
        \\"example/legacy" = "1"
        \\"example/local" = { path = "local" }
        \\
        \\[dev-dependencies]  # tests only
        \\
        \\# trailing comment
        \\
    , path);
}

test "add of an existing dependency replaces its value in place" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = (try editText(a, .add, golden_before, false, "example/tls", try depValue(a, "~1.1", null))).ok;
    const want = try std.mem.replaceOwned(u8, a, golden_before, "\"example/tls\"   =   \"1\"        #", "\"example/tls\"   =   \"~1.1\"        #");
    try std.testing.expectEqualStrings(want, got);
}

test "remove of a key in the middle of a table takes its line and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const three = (try editText(a, .add, golden_before, false, "example/http_client", "\"^0.5.0\"")).ok;
    const got = (try editText(a, .remove, three, false, "example/legacy", "")).ok;
    try std.testing.expectEqualStrings(
        \\# The project. Comments, blank lines, order and spacing survive add and remove.
        \\[package]
        \\name    = "example/app"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"   # one compiler
        \\
        \\[dependencies]
        \\# transport
        \\"example/tls"   =   "1"        # the major only
        \\"example/http_client" = "^0.5.0"
        \\
        \\[dev-dependencies]  # tests only
        \\
        \\# trailing comment
        \\
    , got);
}

test "remove of an absent dependency is an error, and so is the other table's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("example/nosuch is not a dependency: [dependencies] of mopm.toml does not name it", (try editText(a, .remove, golden_before, false, "example/nosuch", "")).bad);
    // A value that would leave mopm.toml unreadable is refused with the file, the entry and the table named.
    const unreadable = (try editText(a, .add, golden_before, false, "example/tls", "\"1.0\"\nbroken = =")).bad;
    try std.testing.expectEqualStrings("mopm.toml with example/tls = \"1.0\"\nbroken = = in [dependencies] would not be a TOML file mopm reads", unreadable);
    // example/tls is in [dependencies], not [dev-dependencies].
    try std.testing.expectEqualStrings("example/tls is not a dependency: [dev-dependencies] of mopm.toml does not name it", (try editText(a, .remove, golden_before, true, "example/tls", "")).bad);
    // No [dev-dependencies] table at all.
    try std.testing.expect((try editText(a, .remove, "[package]\nname = \"a\"\n", true, "example/tls", "")) == .bad);
    // A table written as dotted keys is not edited.
    try std.testing.expect((try editText(a, .add, "dependencies.tls = \"1\"\n\n[package]\nname = \"a\"\n", false, "x", "\"1\"")) == .bad);
}

/// A registry that answers each request with one canned answer, and keeps what it was asked.
const FakeNet = struct {
    status: u16 = 200,
    body: []const u8 = "",
    /// The request fails as a refused connection does.
    refuse: bool = false,
    method: ?std.http.Method = null,
    url: []const u8 = "",
    token: ?[]const u8 = null,
    asked: usize = 0,
    /// How often the retry policy paused between tries, and the seconds of the last pause.
    paused: usize = 0,
    last_pause: u64 = 0,
    /// What the clock reads.
    clock: i64 = 0,

    fn net(f: *FakeNet) Net {
        return .{ .ptr = f, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: std.http.Method, url: []const u8, options: core.http.Options) anyerror!core.http.Answer {
        const f: *FakeNet = @ptrCast(@alignCast(ptr));
        f.asked += 1;
        f.method = method;
        f.url = url;
        f.token = options.token;
        if (f.refuse) return error.ConnectionRefused;
        return .{ .status = f.status, .body = f.body };
    }

    fn sleep(ptr: *anyopaque, secs: u64) void {
        const f: *FakeNet = @ptrCast(@alignCast(ptr));
        f.paused += 1;
        f.last_pause = secs;
    }

    fn now(ptr: *anyopaque) i64 {
        const f: *FakeNet = @ptrCast(@alignCast(ptr));
        return f.clock;
    }
};

/// A loopback server that answers every GET with `status` and `body`, one connection at a time, until the process ends.
const ConfigServer = struct {
    server: std.net.Server,
    status: std.http.Status,
    body: []const u8,

    fn serve(self: *ConfigServer) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var buf: [8 * 1024]u8 = undefined;
            var http_server = std.http.Server.init(conn, &buf);
            var req = http_server.receiveHead() catch continue;
            req.respond(self.body, .{ .status = self.status, .keep_alive = false }) catch continue;
        }
    }

    /// Starts one on a free loopback port and returns its base URL. The serving thread is detached and outlives the
    /// test, so the server lives in page memory that is never freed (the convention of the stubs in http.zig).
    fn start(arena: Allocator, status: std.http.Status, body: []const u8) ![]const u8 {
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        const srv = try std.heap.page_allocator.create(ConfigServer);
        srv.* = .{ .server = try address.listen(.{ .reuse_address = true }), .status = status, .body = body };
        const t = try std.Thread.spawn(.{}, serve, .{srv});
        t.detach();
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.server.listen_address.getPort()});
    }
};

const beta_config = "{\"index_version\":2,\"stage\":\"beta\",\"api_url\":\"https://api.example.test\",\"api_v2_url\":\"https://api.example.test/api/v2\",\"channel_url\":\"https://conda.example.test/\",\"min_cli_version\":\"0.0.1\"}";
const one_hit = "{\"packages\":[{\"name\":\"alice/json\",\"latest\":null,\"description\":null,\"updated_at\":\"2026-10-01T00:00:00Z\"}],\"next_cursor\":null}";

fn searchOf(comptime l: []const []const u8) ?[]const []const u8 {
    return l;
}

test "a bare name with matching packages is refused with the full names to write, in the registry's order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: komira-ai/json (as in 'mopm add komira-ai/json')",
        try bareMessage(a, "json", "prod", searchOf(&.{"komira-ai/json"})),
    );
    // The same name in another namespace is a match too; the first is the example.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on beta: komira-ai/json, alice/json (as in 'mopm add komira-ai/json')",
        try bareMessage(a, "json", "beta", searchOf(&.{ "komira-ai/json", "alice/json" })),
    );
}

test "a bare name keeps only the packages whose name is exactly it, and at most five" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // json5 and jsonx start with json but are other names; an entry with no namespace is not a full name.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: bob/json (as in 'mopm add bob/json')",
        try bareMessage(a, "json", "prod", searchOf(&.{ "alice/json5", "alice/jsonx", "json", "bob/json", "carol/xjson" })),
    );
    // Prefix matches only: nothing is named json.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; no package on prod is named json",
        try bareMessage(a, "json", "prod", searchOf(&.{ "alice/json5", "alice/jsonx" })),
    );
    // Exactly five are listed, and a sixth is left out.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: a/json, b/json, c/json, d/json, e/json (as in 'mopm add a/json')",
        try bareMessage(a, "json", "prod", searchOf(&.{ "a/json", "b/json", "c/json", "d/json", "e/json" })),
    );
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: a/json, b/json, c/json, d/json, e/json (as in 'mopm add a/json')",
        try bareMessage(a, "json", "prod", searchOf(&.{ "a/json", "b/json", "c/json", "d/json", "e/json", "f/json", "g/json" })),
    );
    // Non-matching results do not use up the five.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: a/json, b/json, c/json, d/json, e/json (as in 'mopm add a/json')",
        try bareMessage(a, "json", "prod", searchOf(&.{ "a/json5", "a/json", "b/json", "c/json", "x/jsonx", "d/json", "e/json", "f/json" })),
    );
}

test "a bare name with no package of that name is refused saying so, and an unreadable registry leaves today's message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; no package on gamma is named json",
        try bareMessage(a, "json", "gamma", searchOf(&.{})),
    );
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/<name>, as in 'mopm add <namespace>/<name>'",
        try bareMessage(a, "json", "prod", null),
    );
    try std.testing.expectEqualStrings(try bareProblem(a, "json"), (try specProblem(a, "json")).?);
}

test "the search asks the v2 registry for the bare name with no token, and reads the full names in its order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fake = FakeNet{ .body = "{\"packages\":[{\"name\":\"alice/json\",\"latest\":\"0.1.0\",\"description\":null,\"updated_at\":\"2026-10-01T00:00:00Z\"},{\"name\":\"bob/json_x\",\"latest\":null,\"description\":null,\"updated_at\":\"2026-10-02T00:00:00Z\"}],\"next_cursor\":null}" };
    const got = (try searchNames(a, fake.net(), "http://127.0.0.1:1/api/v2", "json")).?;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("alice/json", got[0]);
    try std.testing.expectEqualStrings("bob/json_x", got[1]);
    try std.testing.expectEqual(@as(usize, 1), fake.asked);
    try std.testing.expectEqual(std.http.Method.GET, fake.method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/packages?q=json&limit=100", fake.url);
    try std.testing.expect(fake.token == null);
    // The end to end of a search and a refusal.
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: alice/json (as in 'mopm add alice/json')",
        try bareMessage(a, "json", "prod", got),
    );
}

test "a search that cannot be read finds nothing and never fails the refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var refused = FakeNet{ .refuse = true };
    try std.testing.expect((try searchNames(a, refused.net(), "http://127.0.0.1:1/api/v2", "json")) == null);
    var down = FakeNet{ .status = 503, .body = "{\"packages\":[{\"name\":\"alice/json\",\"latest\":null,\"description\":null,\"updated_at\":\"2026-10-01T00:00:00Z\"}],\"next_cursor\":null}" };
    try std.testing.expect((try searchNames(a, down.net(), "http://127.0.0.1:1/api/v2", "json")) == null);
    var garbled = FakeNet{ .body = "not json" };
    try std.testing.expect((try searchNames(a, garbled.net(), "http://127.0.0.1:1/api/v2", "json")) == null);
    var wrong_shape = FakeNet{ .body = "{\"packages\":3}" };
    try std.testing.expect((try searchNames(a, wrong_shape.net(), "http://127.0.0.1:1/api/v2", "json")) == null);
    // A registry with no v2 API is not asked at all.
    var unasked = FakeNet{};
    try std.testing.expect((try searchNames(a, unasked.net(), "", "json")) == null);
    try std.testing.expectEqual(@as(usize, 0), unasked.asked);
    // An empty list is an answer: no package is named so.
    var empty = FakeNet{ .body = "{\"packages\":[],\"next_cursor\":null}" };
    try std.testing.expectEqual(@as(usize, 0), (try searchNames(a, empty.net(), "http://127.0.0.1:1/api/v2", "json")).?.len);
}

test "the bare name is percent-encoded in the search, and an unresolvable registry or an empty name is refused as before" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fake = FakeNet{ .body = "{\"packages\":[],\"next_cursor\":null}" };
    _ = (try searchNames(a, fake.net(), "http://127.0.0.1:1/api/v2", "a&b")).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/packages?q=a%26b&limit=100", fake.url);
    _ = (try searchNames(a, fake.net(), "http://127.0.0.1:1/api/v2", "json-x_1.2~")).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/packages?q=json-x_1.2~&limit=100", fake.url);
    _ = (try searchNames(a, fake.net(), "http://127.0.0.1:1/api/v2", "a&b=c d/")).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/packages?q=a%26b%3Dc%20d%2F&limit=100", fake.url);
    // Neither case reaches the network: the registry is not a registry, and there is no name to search for.
    var never = FakeNet{};
    try std.testing.expectEqualStrings(try bareProblem(a, "json"), try bareRefusal(a, never.net(), "nonsense", "0.0.1", "json"));
    try std.testing.expectEqualStrings(try bareProblem(a, ""), try bareRefusal(a, never.net(), "prod", "0.0.1", ""));
    try std.testing.expectEqual(@as(usize, 0), never.asked);
}

test "the fake registry's pause and clock are what the retry policy and a caller read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A 503 to an idempotent GET is repeated after a pause, and the last answer is the 503.
    var down = FakeNet{ .status = 503 };
    const answer = try down.net().request(a, .GET, "http://127.0.0.1:1/api/v2/packages", .{});
    try std.testing.expectEqual(@as(u16, 503), answer.status);
    try std.testing.expectEqual(@as(usize, core.http.default_retries) + 1, down.asked);
    try std.testing.expectEqual(@as(usize, core.http.default_retries), down.paused);
    var clocked = FakeNet{ .clock = 42 };
    try std.testing.expectEqual(@as(i64, 42), clocked.net().now());
    clocked.net().sleep(7);
    try std.testing.expectEqual(@as(u64, 7), clocked.last_pause);
}

test "a search that runs out of memory fails with OutOfMemory at every allocation, and otherwise reads the names" {
    var fake = FakeNet{ .body = one_hit };
    var index: usize = 0;
    var failures: usize = 0;
    while (true) : (index += 1) {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var failing = std.testing.FailingAllocator.init(arena_state.allocator(), .{ .fail_index = index });
        const got = searchNames(failing.allocator(), fake.net(), "http://127.0.0.1:1/api/v2", "json") catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            failures += 1;
            continue;
        };
        try std.testing.expectEqual(@as(usize, 1), got.?.len);
        try std.testing.expectEqualStrings("alice/json", got.?[0]);
        break;
    }
    try std.testing.expect(failures > 2);
}

test "a bare name is refused with the names the registry finds, and with today's message when its config is not served" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const served = try ConfigServer.start(a, .ok, beta_config);
    var fake = FakeNet{ .body = one_hit };
    try std.testing.expectEqualStrings(
        "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on beta: alice/json (as in 'mopm add alice/json')",
        try bareRefusal(a, fake.net(), served, "0.0.1", "json"),
    );
    try std.testing.expectEqualStrings("https://api.example.test/api/v2/packages?q=json&limit=100", fake.url);
    // A registry that answers its config with an error leaves the plain message and is not searched.
    const failing = try ConfigServer.start(a, .service_unavailable, "");
    var unasked = FakeNet{ .body = one_hit };
    try std.testing.expectEqualStrings(try bareProblem(a, "json"), try bareRefusal(a, unasked.net(), failing, "0.0.1", "json"));
    try std.testing.expectEqual(@as(usize, 0), unasked.asked);
}

test "a refusal that runs out of memory fails with OutOfMemory, and one that completes is the plain or the full message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const served = try ConfigServer.start(a, .ok, beta_config);
    const full = "dependency 'json' has no namespace: write it as <namespace>/json; packages named json on beta: alice/json (as in 'mopm add alice/json')";
    const plain = try bareProblem(a, "json");
    var fake = FakeNet{ .body = one_hit };
    var index: usize = 0;
    var completed = false;
    while (index < 400 and !completed) : (index += 1) {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        var failing = std.testing.FailingAllocator.init(scratch.allocator(), .{ .fail_index = index });
        const got = bareRefusal(failing.allocator(), fake.net(), served, "0.0.1", "json") catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        if (!failing.has_induced_failure) completed = true;
        try std.testing.expect(std.mem.eql(u8, got, full) or std.mem.eql(u8, got, plain));
    }
    try std.testing.expect(completed);
}
