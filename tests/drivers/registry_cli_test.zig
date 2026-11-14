//! //:registry_cli: the registry commands of the built `mopm`, generated from the v2 protos
//! (src/cli/registry_commands.zig), run as commands.
//!
//! What it proves:
//!   - `mopm <command> --help` prints, byte for byte, the help golden of tests/golden/registry for every command, and
//!     exits 0; `mopm --help` lists the commands as tests/golden/registry/commands.txt;
//!   - a usage error (a missing argument, a command group named alone) exits 2 and prints the usage, without a request;
//!   - against the fake registry: `health` prints its answer as text and as JSON, a refusal prints the message, the
//!     `code:` line and the hint and exits 1, and `whoami` without a login says so and exits 1.
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

test "mopm <command> --help prints the help golden of every generated command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var rep = h.Report{};
    const m = Mopm{ .a = a, .exe = try h.toolPath(a, "MOPM"), .env = try h.environ(a) };

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
    const m = Mopm{ .a = a, .exe = try h.toolPath(a, "MOPM"), .env = try h.environ(a) };

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
    const m = Mopm{ .a = a, .exe = mopm_exe, .env = try h.environ(a) };

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
