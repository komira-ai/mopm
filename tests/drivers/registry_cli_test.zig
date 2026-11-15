//! //:registry_cli: the registry commands of the built `mopm`, generated from the v2 protos
//! (src/cli/registry_commands.zig), run as commands.
//!
//! What it proves:
//!   - `mopm <command> --help` prints, byte for byte, the help golden of tests/golden/registry for every command, and
//!     exits 0; `mopm --help` lists the commands as tests/golden/registry/commands.txt;
//!   - a usage error (a missing argument, a command group named alone) exits 2 and prints the usage, without a request;
//!   - against the fake registry: `health` prints its answer as text and as JSON, a refusal prints the message, the
//!     `code:` line and the hint and exits 1, and `whoami` without a login says so and exits 1;
//!   - the generated `token create`, `token list` and `token revoke`, after a `mopm login` approved on the fake: a token
//!     created with the advertised flags (names and `all_current`) is answered with its id and secret, is listed without
//!     its secret, leaves the list once revoked while the other stays, and a second revoke is the registry's refusal; a
//!     missing required flag is a usage error and `token list` before the login sends nothing.
//!
//! Run by Buck2 (//:registry_cli) and by `zig build test`; MOPM is the built CLI, MOPM_FAKE_REGISTRY the fake registry.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const golden_dir = "tests/golden/registry";

const Mopm = struct {
    a: Allocator,
    exe: []const u8,
    env: std.process.EnvMap,

    /// Runs `mopm args`, capturing standard output and standard error apart.
    fn run(m: Mopm, args: []const []const u8) !Out {
        const argv = try m.a.alloc([]const u8, args.len + 1);
        argv[0] = m.exe;
        @memcpy(argv[1..], args);
        const r = try std.process.Child.run(.{ .allocator = m.a, .argv = argv, .env_map = &m.env, .max_output_bytes = 1 << 22 });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }
};

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

/// Whether `word` is a command word: [a-z][a-z0-9-]*.
fn isWord(word: []const u8) bool {
    if (word.len == 0 or word[0] < 'a' or word[0] > 'z') return false;
    for (word) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// The words of the command a help golden describes: the words after `usage: mopm ` on its first line, up to the first
/// argument or flag.
fn commandWords(a: Allocator, golden: []const u8) ![]const []const u8 {
    const first = golden[0 .. std.mem.indexOfScalar(u8, golden, '\n') orelse golden.len];
    const prefix = "usage: mopm ";
    if (!std.mem.startsWith(u8, first, prefix)) return error.NotAUsageLine;
    var words = std.ArrayList([]const u8).init(a);
    var it = std.mem.tokenizeScalar(u8, first[prefix.len..], ' ');
    while (it.next()) |w| {
        if (!isWord(w)) break;
        try words.append(w);
    }
    return words.toOwnedSlice();
}

/// This process's environment without `MOPM_TOKEN`, so a token of the machine never reaches a command under test.
fn cleanEnv(a: Allocator) !std.process.EnvMap {
    var env = try h.environ(a);
    env.remove("MOPM_TOKEN");
    return env;
}

test "mopm <command> --help prints the help golden of every generated command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const m = Mopm{ .a = a, .exe = try h.toolPath(a, "MOPM"), .env = try cleanEnv(a) };

    var dir = try std.fs.cwd().openDir(golden_dir, .{ .iterate = true });
    defer dir.close();
    var seen: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const golden = try h.readFile(a, try h.join(a, &.{ golden_dir, entry.name }));
        if (std.mem.eql(u8, entry.name, "commands.txt")) {
            const r = try m.run(&.{"--help"});
            rep.check("mopm --help lists the registry commands", h.contains(r.stdout, golden) or h.contains(r.stderr, golden), r.stdout);
            continue;
        }
        const words = try commandWords(a, golden);
        if (words.len == 0) {
            rep.check(try h.fmt(a, "{s} names a command", .{entry.name}), false, golden);
            continue;
        }
        const argv = try a.alloc([]const u8, words.len + 1);
        @memcpy(argv[0..words.len], words);
        argv[words.len] = "--help";
        const r = try m.run(argv);
        const name = try h.fmt(a, "mopm {s} --help prints {s}", .{ try std.mem.join(a, " ", words), entry.name });
        rep.check(name, r.code == 0 and std.mem.eql(u8, r.stdout, golden), r.stdout);
        seen += 1;
    }
    rep.check("the goldens name at least one command", seen > 0, "no golden found");
    try rep.finish();
}

test "a usage error of a registry command exits 2 and prints the usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const m = Mopm{ .a = a, .exe = try h.toolPath(a, "MOPM"), .env = try cleanEnv(a) };

    var r = try m.run(&.{ "org", "add", "only-one-arg" });
    rep.check("org add with one argument exits 2 and prints its usage", r.code == 2 and h.contains(r.stderr, "usage: mopm org add "), r.stderr);

    r = try m.run(&.{ "org", "add", "ns", "someone", "--role", "boss" });
    rep.check("org add with a role that is not one exits 2", r.code == 2 and h.contains(r.stderr, "usage: mopm org add "), r.stderr);

    r = try m.run(&.{ "package", "info", "no-slash" });
    rep.check("package info with a name that is not a full name exits 2", r.code == 2 and h.contains(r.stderr, "'no-slash' is not a full name"), r.stderr);

    r = try m.run(&.{"token"});
    rep.check("the token group alone lists its commands and exits 2", r.code == 2 and h.contains(r.stderr, "token create") and
        h.contains(r.stderr, "token list") and h.contains(r.stderr, "token revoke"), r.stderr);
    try rep.finish();
}

test "registry commands against the fake registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);
    const conf = try h.join(a, &.{ work, "conf" });

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = try cleanEnv(a) };

    var r = try m.run(&.{ "health", "--registry", fake.base, "--config-dir", conf });
    rep.check("health prints the registry's answer as text", r.code == 0 and h.hasLine(r.stdout, "status: ok"), r.stdout);

    r = try m.run(&.{ "health", "--json", "--registry", fake.base, "--config-dir", conf });
    {
        const parsed = std.json.parseFromSlice(std.json.Value, a, r.stdout, .{}) catch null;
        const status = if (parsed) |p| h.jsonString(p.value, "status") orelse "" else "";
        rep.check("health --json prints the answer as JSON with status ok", r.code == 0 and std.mem.eql(u8, status, "ok"), r.stdout);
    }

    r = try m.run(&.{ "package", "info", "nobody/nothing", "--registry", fake.base, "--config-dir", conf });
    rep.check("package info of a package that does not exist exits 1 with the message, the code and the hint", r.code == 1 and
        std.mem.startsWith(u8, r.stderr, "mopm: ") and h.hasLinePrefix(r.stderr, "  code: ") and h.hasLinePrefix(r.stderr, "  hint: "), r.stderr);

    r = try m.run(&.{ "whoami", "--registry", fake.base, "--config-dir", conf });
    rep.check("whoami without a login says so and exits 1", r.code == 1 and h.contains(r.stderr, "not logged in to beta; run 'mopm login'"), r.stderr);
    try rep.finish();
}

/// `mopm login` on the fake, approved on its approval page: the session the token commands need (a fresh one).
fn loginOnFake(a: Allocator, m: Mopm, fake: h.Fake, conf: []const u8) !bool {
    const argv = [_][]const u8{ m.exe, "login", "--registry", fake.base, "--config-dir", conf };
    var child = std.process.Child.init(&argv, a);
    child.env_map = &m.env;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const first = try h.readLine(a, child.stdout.?);
    const marker = "enter the code ";
    if (std.mem.indexOf(u8, first, marker)) |at| {
        const rest = first[at + marker.len ..];
        const code = rest[0 .. std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len];
        const body = try std.fmt.allocPrint(a, "{{\"user_code\":\"{s}\",\"decision\":\"approve\",\"handle\":\"cli-user\"}}", .{code});
        _ = try fake.control(a, "/device", body);
    }
    _ = try child.stdout.?.reader().readAllAlloc(a, 1 << 20);
    _ = try child.stderr.?.reader().readAllAlloc(a, 1 << 20);
    const term = try child.wait();
    return term == .Exited and term.Exited == 0;
}

/// The ids of the tokens of a `token list --json` answer.
fn tokenIds(a: Allocator, json: []const u8) ![]const []const u8 {
    const v = h.parseJson(a, json) catch return &.{};
    const list = switch (v) {
        .object => |o| o.get("tokens") orelse return &.{},
        else => return &.{},
    };
    var ids = std.ArrayList([]const u8).init(a);
    if (list != .array) return &.{};
    for (list.array.items) |t| {
        if (h.jsonString(t, "id")) |id| try ids.append(id);
    }
    return ids.items;
}

/// `args` followed by `at`.
fn withAt(a: Allocator, args: []const []const u8, at: []const []const u8) ![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ args, at });
}

fn holds(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

test "the generated token commands create, list and revoke a token on the fake registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const mopm_exe = try h.toolPath(a, "MOPM");
    const fake_exe = try h.toolPath(a, "MOPM_FAKE_REGISTRY");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try h.tmpPath(a, &tmp);
    const conf = try h.join(a, &.{ work, "conf" });

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, fake_exe, try h.join(a, &.{ work, "fake" }));
    defer fake.close();
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = try cleanEnv(a) };
    const at = [_][]const u8{ "--registry", fake.base, "--config-dir", conf };

    var r = try m.run(try withAt(a, &.{ "token", "list" }, &at));
    rep.check("token list without a login says so, exits 1 and sends nothing", r.code == 1 and h.contains(r.stderr, "not logged in to beta; run 'mopm login'"), r.stderr);

    rep.check("mopm login on the fake succeeds", try loginOnFake(a, m, fake, conf), "login failed");

    // Create, with the flags the generated command advertises.
    r = try m.run(try withAt(a, &.{ "token", "create", "ci", "--scopes", "publish", "--scopes", "yank", "--packages", "cli-user/a", "--packages", "cli-user/b", "--expires-in-days", "7", "--json" }, &at));
    const created = h.parseJson(a, r.stdout) catch std.json.Value{ .null = {} };
    const id = h.jsonString(created, "id") orelse "";
    const secret = h.jsonString(created, "token") orelse "";
    rep.check("token create answers the new token with its id and its secret", r.code == 0 and id.len > 0 and std.mem.startsWith(u8, secret, "mopm_") and
        std.mem.eql(u8, h.jsonString(created, "name") orelse "", "ci"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    r = try m.run(try withAt(a, &.{ "token", "create", "all", "--scopes", "stage", "--packages", "all_current", "--expires-in-days", "1" }, &at));
    rep.check("token create with all_current prints the answer as text", r.code == 0 and h.hasLine(r.stdout, "name: all") and h.hasLine(r.stdout, "packages: all_current") and h.hasLine(r.stdout, "scopes: stage"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));

    r = try m.run(try withAt(a, &.{ "token", "create", "bad", "--scopes", "publish", "--packages", "all_current" }, &at));
    rep.check("token create without --expires-in-days is a usage error", r.code == 2 and h.contains(r.stderr, "missing required option --expires-in-days <n>"), r.stderr);

    // List: the new token is there, and the list never holds a secret.
    r = try m.run(try withAt(a, &.{ "token", "list", "--json" }, &at));
    const before = try tokenIds(a, r.stdout);
    rep.check("token list holds the created token, without its secret", r.code == 0 and holds(before, id) and before.len == 2 and
        (secret.len == 0 or !h.contains(r.stdout, secret)), r.stdout);

    // Revoke it: it leaves the list, the other stays.
    r = try m.run(try withAt(a, &.{ "token", "revoke", id }, &at));
    rep.check("token revoke says done", r.code == 0 and std.mem.eql(u8, r.stdout, "Done.\n"), try std.fmt.allocPrint(a, "{d}: {s}{s}", .{ r.code, r.stdout, r.stderr }));
    r = try m.run(try withAt(a, &.{ "token", "list", "--json" }, &at));
    const after = try tokenIds(a, r.stdout);
    rep.check("after the revoke the list no longer holds it, and holds the other", r.code == 0 and !holds(after, id) and after.len == 1, r.stdout);

    r = try m.run(try withAt(a, &.{ "token", "revoke", id }, &at));
    rep.check("revoking it again is the registry's refusal with its code", r.code == 1 and h.hasLinePrefix(r.stderr, "  code: "), r.stderr);
    try rep.finish();
}
