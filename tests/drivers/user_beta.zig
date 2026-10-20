//! The user-level beta of a mopm release: the CANDIDATE binary used as a customer uses it, every verb,
//! end to end, against a fake registry this driver starts. Run by release-beta-user.yml on linux x86_64,
//! linux arm64 and macOS 14 (GitHub-hosted runners) with the binary the release build produced, and by
//! Buck2 (//:user_beta, tests/drivers/user_beta_test.zig) on the farm in a reduced form (no pixi, no
//! installer: see below). No shell: every step is a program started here, its exit status and output asserted.
//!
//!     user_beta <mopm> <work dir> --version <v> --fake-registry <exe> --mojo-env <prefix>
//!               [--tarball <mopm-v-target.tar.gz> --install-sh <install.sh>] [--pixi <exe>]
//!
//!   <mopm>            the candidate binary
//!   --version         the version it must report (1.2.3: `mopm --version` prints `mopm 1.2.3`)
//!   --fake-registry   registry/fake, built from the same commit (the test registry; started here)
//!   --mojo-env        a Mojo environment prefix (bin/mojo, lib/mojo): tests/e2e/pixi.toml's, as ci.yml makes it
//!   --pixi            enables `mopm sync` (it installs a published package through pixi); without it the
//!                     dependency is locked but not installed, and the steps that need it are reported SKIP
//!   --tarball, --install-sh
//!                     enable the install path: site/static/install.sh pointed at a directory laid out like
//!                     a GitHub release that holds the candidate tarball
//!
//! The walk, by what a customer does (each line is checked, and a red line names the step):
//!
//!   1  create     `new --lib`, `new --bin`, `init`, `metadata`; a second `new` is refused
//!   2  test       `test --list`, `test` (the scaffold's own test passes), a planted failing test turns it red
//!   3  account    `login` (device flow, approved on the fake), `whoami`, an API token for publishing
//!   4  publish    `pack`, `publish --dry-run`, `publish` to the test registry; the registry serves the version,
//!                 the index and the channel with the packed sha256; publishing the same version again is refused
//!   5  depend     `add`, `tree`, `lock`, `update` against that registry, `sync` (download, sha256 check, pixi)
//!   6  build      `build` and `run` a program (and the one that imports the published dependency), `test` again
//!   7  remove     `remove`, `logout`
//!   8  install    install.sh with MOPM_RELEASES_URL at the candidate files: it installs, the installed file is
//!                 the candidate byte for byte, `mopm --version` equals the candidate version; a SHA256SUMS that
//!                 lies is refused and installs nothing
//!
//! Verbs the walk does not run: `repl` (tests/drivers/test_autolink_test.zig and tests/e2e/run.sh run it against
//! the real mojo, and the macOS 14 debugger needs a workaround that belongs there), `link-plan`, `plan` and `unit`
//! (offline planners with their own golden tests).

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    mopm: []const u8,
    work: []const u8,
    version: []const u8,
    fake_registry: []const u8,
    mojo_env: []const u8,
    tarball: ?[]const u8 = null,
    install_sh: ?[]const u8 = null,
    pixi: ?[]const u8 = null,
    /// The environment every child gets (default: this process's).
    env: ?*const std.process.EnvMap = null,
};

const Out = struct { code: u8, stdout: []u8, stderr: []u8 };

const Ctx = struct {
    a: Allocator,
    rep: *h.Report,
    o: Opts,
    env: std.process.EnvMap,
    ws: []const u8,
    fake: h.Fake,
    api: []const u8,
    conf: []const u8,
    skipped: usize = 0,

    fn run(c: *Ctx, exe: []const u8, dir: []const u8, args: []const []const u8, extra: []const [2][]const u8) !Out {
        const argv = try c.a.alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        var env = try h.cloneEnv(c.a, &c.env);
        for (extra) |kv| try env.put(kv[0], kv[1]);
        const r = try std.process.Child.run(.{ .allocator = c.a, .argv = argv, .cwd = dir, .env_map = &env, .max_output_bytes = 1 << 24 });
        return .{ .code = switch (r.term) {
            .Exited => |code| code,
            else => 255,
        }, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// `mopm <args>` in `dir`.
    fn mopm(c: *Ctx, dir: []const u8, args: []const []const u8) !Out {
        h.stage = args[0];
        return c.run(c.o.mopm, dir, args, &.{});
    }

    fn detail(c: *Ctx, r: Out) []const u8 {
        return std.fmt.allocPrint(c.a, "exit {d}\n--- stdout\n{s}--- stderr\n{s}---", .{ r.code, r.stdout, r.stderr }) catch "(out of memory)";
    }

    fn check(c: *Ctx, name: []const u8, ok: bool, r: Out) void {
        c.rep.check(name, ok, c.detail(r));
    }

    fn skip(c: *Ctx, name: []const u8, why: []const u8) void {
        c.skipped += 1;
        std.debug.print("SKIP {s}: {s}\n", .{ name, why });
    }

    fn path(c: *Ctx, parts: []const []const u8) []const u8 {
        return std.fs.path.join(c.a, parts) catch @panic("oom");
    }

    fn exists(p: []const u8) bool {
        return if (std.fs.cwd().access(p, .{})) true else |_| false;
    }

    fn read(c: *Ctx, p: []const u8) []const u8 {
        return h.readFile(c.a, p) catch "";
    }

    fn mojoEnv(c: *Ctx) []const [2][]const u8 {
        const home = std.fmt.allocPrint(c.a, "{s}/share/max", .{c.o.mojo_env}) catch @panic("oom");
        const pair = c.a.alloc([2][]const u8, 1) catch @panic("oom");
        pair[0] = .{ "MODULAR_HOME", home };
        return pair;
    }
};

fn sha256File(a: Allocator, p: []const u8) ![]const u8 {
    const bytes = try h.readFile(a, p);
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

fn isSha(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

/// The path and sha256 of `packed <path>\n  sha256 <hex>\n  size <n>\n  manifest_sha256 <hex>`.
fn parsePacked(text: []const u8) ?struct { path: []const u8, sha: []const u8 } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l0| {
        if (!std.mem.startsWith(u8, l0, "packed ")) continue;
        const l1 = lines.next() orelse return null;
        if (!std.mem.startsWith(u8, l1, "  sha256 ")) return null;
        const sha = l1["  sha256 ".len..];
        if (!isSha(sha)) return null;
        return .{ .path = l0["packed ".len..], .sha = sha };
    }
    return null;
}

/// The code after "enter the code " in `line`, or null.
fn codeIn(line: []const u8) ?[]const u8 {
    const marker = "enter the code ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
    return rest[0..end];
}

// ---------------------------------------------------------------------------- the walk

pub fn run(a: Allocator, rep: *h.Report, o: Opts) !void {
    try std.fs.cwd().makePath(o.work);
    var base_env = if (o.env) |e| try h.cloneEnv(a, e) else try h.environ(a);
    base_env.remove("MOPM_TOKEN");
    base_env.remove("CONDA_PREFIX");
    base_env.remove("MODULAR_HOME");
    const ws = try h.join(a, &.{ o.work, "ws" });
    try std.fs.cwd().makePath(ws);

    h.stage = "starting the fake registry";
    var fake = try h.Fake.start(a, o.fake_registry, try h.join(a, &.{ o.work, "registry" }));
    defer fake.close();

    var c = Ctx{ .a = a, .rep = rep, .o = o, .env = base_env, .ws = ws, .fake = fake, .api = try fake.api(a), .conf = try h.join(a, &.{ o.work, "conf" }) };

    try create(&c);
    try testing(&c);
    const token = try account(&c);
    try publish(&c, token);
    try depend(&c);
    try build(&c);
    try finish(&c);
    try install(&c);
    if (c.skipped != 0) std.debug.print("{d} step(s) skipped: see the SKIP lines\n", .{c.skipped});
}

/// 1: create a package.
fn create(c: *Ctx) !void {
    const a = c.a;
    var r = try c.mopm(c.ws, &.{"--version"});
    c.check("candidate: mopm --version is exactly the candidate's version", r.code == 0 and std.mem.eql(u8, r.stdout, try h.fmt(a, "mopm {s}\n", .{c.o.version})), r);

    r = try c.mopm(c.ws, &.{ "new", "beta_lib", "--lib" });
    const lib_files = [_][]const u8{ "mopm.toml", "src/beta_lib/__init__.mojo", "tests/test_beta_lib.mojo", "README.md", ".gitignore" };
    var all = true;
    for (lib_files) |f| all = all and Ctx.exists(c.path(&.{ c.ws, "beta_lib", f }));
    c.check("new --lib creates the library package and its files", r.code == 0 and all and std.mem.eql(u8, r.stdout, "created library package 'beta_lib' in beta_lib/\n"), r);

    r = try c.mopm(c.ws, &.{ "new", "beta_app", "--bin" });
    c.check("new --bin creates the binary package with src/main.mojo", r.code == 0 and Ctx.exists(c.path(&.{ c.ws, "beta_app", "src/main.mojo" })) and
        std.mem.eql(u8, r.stdout, "created binary package 'beta_app' in beta_app/\n"), r);

    r = try c.mopm(c.ws, &.{ "new", "beta_lib" });
    c.check("new refuses a directory that exists", r.code == 1 and h.contains(r.stderr, "'beta_lib' already exists"), r);

    const here = c.path(&.{ c.ws, "init_here" });
    try std.fs.cwd().makePath(here);
    r = try c.mopm(here, &.{ "init", "--lib", "--name", "beta_init" });
    c.check("init writes the package into this directory", r.code == 0 and Ctx.exists(c.path(&.{ here, "mopm.toml" })) and std.mem.eql(u8, r.stdout, "created library package 'beta_init'\n"), r);
    r = try c.mopm(here, &.{ "init", "--lib", "--name", "beta_init" });
    c.check("init refuses to overwrite", r.code == 1 and h.contains(r.stderr, "already exists; nothing was written"), r);

    r = try c.mopm(c.ws, &.{ "metadata", "beta_lib/mopm.toml" });
    c.check("metadata prints the manifest as JSON", r.code == 0 and h.contains(r.stdout, "beta_lib") and h.contains(r.stdout, "0.1.0"), r);
}

/// 2: test.
fn testing(c: *Ctx) !void {
    const a = c.a;
    const lib = c.path(&.{ c.ws, "beta_lib" });
    var r = try c.mopm(lib, &.{ "test", "--list" });
    c.check("test --list names the scaffold's test", r.code == 0 and std.mem.eql(u8, r.stdout, "tests/test_beta_lib.mojo::test_greet\n"), r);

    r = try c.mopm(lib, &.{ "test", "--prefix", c.o.mojo_env });
    c.check("test runs the scaffold's test and it passes", r.code == 0 and h.contains(r.stdout, "PASS") and h.contains(r.stdout, "1 tests: 1 passed, 0 failed"), r);

    // A test that fails must turn the verb red (a test verb that cannot fail proves nothing).
    const planted = c.path(&.{ lib, "tests/test_planted.mojo" });
    try h.writeFile(planted, "from std.testing import assert_equal\n\n\ndef test_planted() raises:\n    assert_equal(1, 2)\n");
    r = try c.mopm(lib, &.{ "test", "--prefix", c.o.mojo_env });
    c.check("a planted failing test makes test exit 1 and name the failure", r.code == 1 and h.contains(r.stdout, "FAIL") and h.contains(r.stdout, "test_planted") and h.contains(r.stdout, "1 failed"), r);
    try std.fs.cwd().deleteFile(planted);
    r = try c.mopm(lib, &.{ "test", "--prefix", c.o.mojo_env });
    c.check("control: with the planted test removed it is green again", r.code == 0 and h.contains(r.stdout, "1 tests: 1 passed, 0 failed"), r);
    _ = a;
}

/// 3: an account on the test registry. Returns the API token that may publish beta_lib.
fn account(c: *Ctx) ![]const u8 {
    const a = c.a;
    var r = try c.mopm(c.ws, &.{ "whoami", "--registry", c.fake.base, "--config-dir", c.conf });
    c.check("whoami before login says to log in", r.code == 1 and h.contains(r.stderr, "not logged in to beta; run 'mopm login'"), r);

    // The device login: mopm prints a code, the person approves it on the registry, mopm stores the token.
    {
        const argv = try a.dupe([]const u8, &.{ c.o.mopm, "login", "--registry", c.fake.base, "--config-dir", c.conf });
        var child = std.process.Child.init(argv, a);
        child.env_map = &c.env;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        h.stage = "login";
        try child.spawn();
        const first = try h.readLine(a, child.stdout.?);
        const code = codeIn(first);
        if (code) |cd| {
            _ = try c.fake.control(a, "/device", try h.fmt(a, "{{\"user_code\":\"{s}\",\"decision\":\"approve\",\"handle\":\"beta-user\"}}", .{cd}));
        }
        const out = try child.stdout.?.reader().readAllAlloc(a, 1 << 20);
        const err = try child.stderr.?.reader().readAllAlloc(a, 1 << 20);
        const term = try child.wait();
        const ok = term == .Exited and term.Exited == 0 and code != null and h.contains(out, "Logged in to beta as beta-user.");
        c.rep.check("login: a device login approved on the registry stores the account", ok, try h.fmt(a, "first line: {s}\n{s}\n{s}", .{ first, out, err }));
    }
    r = try c.mopm(c.ws, &.{ "whoami", "--registry", c.fake.base, "--config-dir", c.conf });
    c.check("whoami names the account", r.code == 0 and h.contains(r.stdout, "beta-user (GitHub id ") and h.contains(r.stdout, ") on beta"), r);

    // What the person does next, on the registry's API: claim the name and make a token that may publish it.
    const creds = h.parseJson(a, c.read(c.path(&.{ c.conf, "credentials.json" }))) catch std.json.Value{ .null = {} };
    var session: []const u8 = "";
    if (creds == .object) {
        if (creds.object.get(c.api)) |entry| session = h.jsonString(entry, "token") orelse "";
    }
    c.rep.check("login stored a session token", session.len != 0, "no token in credentials.json");
    var resp = try h.request(a, "POST", c.fake.base, "/api/v1/packages/beta_lib/claim", "{}", session);
    c.rep.check("the account claims the package name", resp.status == 201, resp.body);
    resp = try h.request(a, "POST", c.fake.base, "/api/v1/me/tokens", "{\"name\":\"user-beta\",\"scopes\":[\"publish\"],\"packages\":[\"beta_lib\"],\"expires_in_days\":1}", session);
    const token = if (resp.status == 201) (h.jsonString(try h.parseJson(a, resp.body), "token") orelse "") else "";
    c.rep.check("the account makes an API token that may publish it", token.len != 0, resp.body);
    return token;
}

/// 4: pack and publish to the test registry.
fn publish(c: *Ctx, token: []const u8) !void {
    const a = c.a;
    const lib = c.path(&.{ c.ws, "beta_lib" });
    const mojoc = c.path(&.{ c.o.work, "beta_lib.mojoc" });
    h.stage = "mojo precompile";
    var r = try c.run(c.path(&.{ c.o.mojo_env, "bin/mojo" }), lib, &.{ "precompile", "src/beta_lib", "-o", mojoc }, c.mojoEnv());
    c.check("the package is precompiled with the toolchain (mojo precompile)", r.code == 0 and Ctx.exists(mojoc), r);

    const dist = c.path(&.{ c.o.work, "dist" });
    r = try c.mopm(lib, &.{ "pack", "--compiler", "1.0.0", "--mojoc", mojoc, "-o", dist });
    const pk = parsePacked(r.stdout);
    const conda = "mojo-beta_lib-0.1.0-mojo1.0.0_0.conda";
    c.check("pack writes noarch/<file>.conda and prints its sha256", r.code == 0 and pk != null and std.mem.endsWith(u8, pk.?.path, "/noarch/" ++ conda) and Ctx.exists(pk.?.path), r);
    const packed_sha = if (pk) |p| p.sha else "";

    const flags = [_][]const u8{ "--registry", c.fake.base, "--config-dir", c.conf };
    const pub_args = [_][]const u8{ "publish", "--compiler", "1.0.0", "--mojoc", mojoc };
    r = try c.mopm(lib, &(pub_args ++ flags ++ [_][]const u8{"--dry-run"}));
    c.check("publish --dry-run says what it would send and sends nothing", r.code == 0 and h.contains(r.stdout, "would upload noarch/" ++ conda) and
        h.contains(r.stdout, try h.fmt(a, "sha256 {s}", .{packed_sha})) and h.contains(r.stdout, "dry run: nothing was sent"), r);
    var resp = try h.request(a, "GET", c.fake.base, "/api/v1/packages/beta_lib/0.1.0", null, null);
    c.rep.check("after the dry run the registry has no such version", resp.status == 404, resp.body);

    h.stage = "publish";
    r = try c.run(c.o.mopm, lib, &(pub_args ++ flags), &.{.{ "MOPM_TOKEN", token }});
    c.check("publish uploads, commits and ends 'published'", r.code == 0 and h.contains(r.stdout, "uploaded " ++ conda) and h.contains(r.stdout, "published mojo-beta_lib 0.1.0"), r);
    resp = try h.request(a, "GET", c.fake.base, "/api/v1/packages/beta_lib/0.1.0", null, null);
    c.rep.check("the registry serves the version", resp.status == 200 and std.mem.eql(u8, h.jsonString(try h.parseJson(a, resp.body), "version") orelse "", "0.1.0"), resp.body);
    resp = try h.request(a, "GET", c.fake.base, "/index/be/ta/beta_lib", null, null);
    c.rep.check("the sparse index lists the version with the packed sha256", resp.status == 200 and h.contains(resp.body, "\"version\":\"0.1.0\"") and packed_sha.len != 0 and h.contains(resp.body, packed_sha), resp.body);
    resp = try h.request(a, "GET", c.fake.base, "/channel/noarch/" ++ conda, null, null);
    c.rep.check("the channel serves the file", resp.status == 200 and resp.body.len != 0, "status or empty body");
    if (resp.status == 200) {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(resp.body, &d, .{});
        c.rep.check("the file the channel serves is the packed file, byte for byte", std.mem.eql(u8, &std.fmt.bytesToHex(d, .lower), packed_sha), "sha256 differs from what pack printed");
    }

    r = try c.run(c.o.mopm, lib, &(pub_args ++ flags), &.{.{ "MOPM_TOKEN", token }});
    c.check("publishing the same version again is refused", r.code == 1 and h.contains(r.stderr, "already exists") and h.contains(r.stderr, "versions are immutable"), r);
    r = try c.mopm(lib, &(pub_args ++ flags));
    c.check("publishing without a login token is refused, naming the fix", r.code == 1 and (h.contains(r.stderr, "does not have the 'publish' scope") or h.contains(r.stderr, "not logged in")), r);
}

/// 5: add and pull the published package as a dependency of another package.
fn depend(c: *Ctx) !void {
    const a = c.a;
    const app = c.path(&.{ c.ws, "beta_app" });
    const reg = [_][]const u8{ "--registry", c.fake.base };
    var r = try c.mopm(app, try cat(a, &.{ &[_][]const u8{ "add", "beta_lib" }, &reg }));
    const manifest = c.read(c.path(&.{ app, "mopm.toml" }));
    const lock = c.read(c.path(&.{ app, "mopm.lock" }));
    c.check("add resolves the package from the registry and writes mopm.toml and mopm.lock", r.code == 0 and h.contains(manifest, "beta_lib = \"^0.1.0\"") and h.contains(lock, "beta_lib") and h.contains(lock, "0.1.0"), r);

    r = try c.mopm(app, &.{"tree"});
    c.check("tree draws the locked graph", r.code == 0 and h.contains(r.stdout, "beta_lib"), r);

    r = try c.mopm(app, try cat(a, &.{ &[_][]const u8{"lock"}, &reg }));
    c.check("lock keeps the locked version and leaves mopm.lock as it was", r.code == 0 and std.mem.eql(u8, lock, c.read(c.path(&.{ app, "mopm.lock" }))), r);
    r = try c.mopm(app, try cat(a, &.{ &[_][]const u8{"update"}, &reg }));
    c.check("update succeeds with nothing newer to move to", r.code == 0 and h.contains(c.read(c.path(&.{ app, "mopm.lock" })), "0.1.0"), r);

    r = try c.mopm(app, try cat(a, &.{ &[_][]const u8{ "add", "no_such_package_beta" }, &reg }));
    c.check("add of a package the registry does not have is refused and writes nothing", r.code != 0 and !h.contains(c.read(c.path(&.{ app, "mopm.toml" })), "no_such_package_beta"), r);

    if (c.o.pixi) |pixi| {
        h.stage = "sync";
        r = try c.run(c.o.mopm, app, try cat(a, &.{ &[_][]const u8{ "sync", "--pixi", pixi }, &reg }), &.{});
        const env = c.path(&.{ app, ".mopm/.pixi/envs/default" });
        const found = try h.findFiles(a, c.path(&.{ env, "lib" }), "beta_lib.mojoc");
        c.check("sync downloads the published package, checks its sha256 against the lock and installs it", r.code == 0 and h.contains(r.stdout, "installed 1 packages for ") and found.len >= 1, r);
        r = try c.mopm(app, &.{ "sync", "--locked", "--pixi", pixi });
        c.check("sync --locked installs the same lock again", r.code == 0, r);
    } else {
        c.skip("sync", "no --pixi: the dependency is locked but not installed");
    }
}

/// 6: build, run and test.
fn build(c: *Ctx) !void {
    const app = c.path(&.{ c.ws, "beta_app" });
    // The program `mopm new --bin` wrote, exactly as it was written (it imports its own package).
    const scaffolded = c.path(&.{ c.o.work, "scaffolded_bin" });
    var r = try c.mopm(app, &.{ "build", "src/main.mojo", "-o", scaffolded, "--prefix", c.o.mojo_env });
    c.check("build compiles the program mopm new wrote, which imports its own package", r.code == 0 and Ctx.exists(scaffolded), r);
    if (r.code == 0) {
        const ran = try c.run(scaffolded, app, &.{}, &.{});
        c.check("and it prints the scaffold's greeting", ran.code == 0 and std.mem.eql(u8, ran.stdout, "Hello, world!\n"), ran);
    }
    // A program of its own, built against the Mojo environment.
    try h.writeFile(c.path(&.{ app, "src/hello.mojo" }), "def main():\n    print(\"hello from the user beta\")\n");
    const hello = c.path(&.{ c.o.work, "hello_bin" });
    r = try c.mopm(app, &.{ "build", "src/hello.mojo", "-o", hello, "--prefix", c.o.mojo_env });
    c.check("build compiles a program with the toolchain", r.code == 0 and Ctx.exists(hello), r);
    if (r.code == 0) {
        const ran = try c.run(hello, app, &.{}, &.{});
        c.check("the built program runs and prints", ran.code == 0 and std.mem.eql(u8, ran.stdout, "hello from the user beta\n"), ran);
    }
    r = try c.mopm(app, &.{ "run", "src/hello.mojo", "--prefix", c.o.mojo_env });
    c.check("run compiles and runs a program", r.code == 0 and h.contains(r.stdout, "hello from the user beta"), r);
    r = try c.mopm(app, &.{ "build", "src/does_not_exist.mojo", "--prefix", c.o.mojo_env });
    c.check("build of a file that is not there fails", r.code != 0, r);

    // The program that uses the dependency pulled from the registry.
    if (c.o.pixi != null) {
        const env = ".mopm/.pixi/envs/default";
        try h.writeFile(c.path(&.{ app, "src/main.mojo" }), "from beta_lib import greet\n\n\ndef main():\n    print(greet(\"beta\"))\n");
        const bin = c.path(&.{ c.o.work, "app_bin" });
        r = try c.mopm(app, &.{ "build", "src/main.mojo", "-o", bin, "--prefix", env });
        c.check("build links the program against the dependency the registry gave", r.code == 0 and Ctx.exists(bin), r);
        if (r.code == 0) {
            const ran = try c.run(bin, app, &.{}, &.{});
            c.check("the program prints what the published package computes", ran.code == 0 and std.mem.eql(u8, ran.stdout, "Hello, beta!\n"), ran);
        }
        r = try c.mopm(app, &.{ "run", "src/main.mojo", "--prefix", env });
        c.check("run does the same", r.code == 0 and h.contains(r.stdout, "Hello, beta!"), r);
        r = try c.mopm(app, &.{ "test", "--prefix", env });
        c.check("test in the package that depends on the registry's package passes", r.code == 0 and h.contains(r.stdout, "passed, 0 failed"), r);
    } else {
        c.skip("build and run against the dependency", "no --pixi: the dependency is not installed");
        r = try c.mopm(app, &.{ "test", "--prefix", c.o.mojo_env });
        c.check("test in the second package passes", r.code == 0 and h.contains(r.stdout, "passed, 0 failed"), r);
    }
}

/// 7: remove the dependency, log out.
fn finish(c: *Ctx) !void {
    const app = c.path(&.{ c.ws, "beta_app" });
    var r = try c.mopm(app, &.{ "remove", "beta_lib", "--registry", c.fake.base });
    c.check("remove takes the dependency out of mopm.toml and mopm.lock", r.code == 0 and !h.contains(c.read(c.path(&.{ app, "mopm.toml" })), "beta_lib =") and !h.contains(c.read(c.path(&.{ app, "mopm.lock" })), "\"beta_lib\""), r);
    r = try c.mopm(c.ws, &.{ "logout", "--registry", c.fake.base, "--config-dir", c.conf });
    c.check("logout removes the stored token", r.code == 0 and h.contains(r.stdout, "Logged out of beta."), r);
    r = try c.mopm(c.ws, &.{ "whoami", "--registry", c.fake.base, "--config-dir", c.conf });
    c.check("whoami after logout says to log in", r.code == 1 and h.contains(r.stderr, "not logged in"), r);
}

/// 8: the documented install path, at the candidate files.
fn install(c: *Ctx) !void {
    const a = c.a;
    const tarball = c.o.tarball orelse {
        c.skip("install", "no --tarball");
        return;
    };
    const installer = c.o.install_sh orelse {
        c.skip("install", "no --install-sh");
        return;
    };
    // A directory laid out like <releases>/download/v<version>/{<tarball>,SHA256SUMS}, as GitHub serves a release.
    const rel = c.path(&.{ c.o.work, "releases" });
    const dl = c.path(&.{ rel, "download", try h.fmt(a, "v{s}", .{c.o.version}) });
    try std.fs.cwd().makePath(dl);
    const asset = std.fs.path.basename(tarball);
    try std.fs.cwd().copyFile(tarball, std.fs.cwd(), c.path(&.{ dl, asset }), .{});
    const sum = try sha256File(a, tarball);
    try h.writeFile(c.path(&.{ dl, "SHA256SUMS" }), try h.fmt(a, "{s}  {s}\n", .{ sum, asset }));

    const home = c.path(&.{ c.o.work, "mopm-home" });
    const url = try h.fmt(a, "file://{s}", .{rel});
    const env = [_][2][]const u8{ .{ "MOPM_RELEASES_URL", url }, .{ "MOPM_VERSION", c.o.version }, .{ "MOPM_HOME", home }, .{ "HOME", c.path(&.{ c.o.work, "home" }) } };
    h.stage = "install.sh";
    var r = try c.run("sh", c.o.work, &.{installer}, &env);
    const installed = c.path(&.{ home, "bin/mopm" });
    c.check("install.sh installs the candidate from the release files", r.code == 0 and Ctx.exists(installed) and h.contains(r.stdout, "Installed "), r);
    if (Ctx.exists(installed)) {
        r = try c.run(installed, c.o.work, &.{"--version"}, &.{});
        c.check("the installed mopm --version equals the candidate version", r.code == 0 and std.mem.eql(u8, r.stdout, try h.fmt(a, "mopm {s}\n", .{c.o.version})), r);
        c.rep.check("the installed file is the candidate binary, byte for byte", std.mem.eql(u8, try sha256File(a, installed), try sha256File(a, c.o.mopm)), "the installed binary differs from the candidate");
        r = try c.run(installed, c.path(&.{ c.o.work, "ws" }), &.{ "new", "installed_check", "--lib" }, &.{});
        c.check("the installed mopm works (new)", r.code == 0 and Ctx.exists(c.path(&.{ c.ws, "installed_check/mopm.toml" })), r);
    }

    // Control: a SHA256SUMS that does not match the tarball must install nothing.
    try h.writeFile(c.path(&.{ dl, "SHA256SUMS" }), try h.fmt(a, "{s}  {s}\n", .{ "0" ** 64, asset }));
    const home2 = c.path(&.{ c.o.work, "mopm-home-bad" });
    const env2 = [_][2][]const u8{ .{ "MOPM_RELEASES_URL", url }, .{ "MOPM_VERSION", c.o.version }, .{ "MOPM_HOME", home2 }, .{ "HOME", c.path(&.{ c.o.work, "home" }) } };
    r = try c.run("sh", c.o.work, &.{installer}, &env2);
    c.check("install.sh refuses a tarball that SHA256SUMS does not vouch for, and installs nothing", r.code != 0 and h.contains(r.stderr, "sha256 mismatch") and !Ctx.exists(c.path(&.{ home2, "bin/mopm" })), r);
}

// ---------------------------------------------------------------------------- main

fn usageDie() noreturn {
    std.debug.print("usage: user_beta <mopm> <work dir> --version <v> --fake-registry <exe> --mojo-env <prefix> [--tarball <file> --install-sh <file>] [--pixi <exe>]\n", .{});
    std.process.exit(2);
}

fn absolute(a: Allocator, p: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(a, p);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 3) usageDie();
    var version: ?[]const u8 = null;
    var fake: ?[]const u8 = null;
    var mojo: ?[]const u8 = null;
    var tarball: ?[]const u8 = null;
    var installer: ?[]const u8 = null;
    var pixi: ?[]const u8 = null;
    var i: usize = 3;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageDie();
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--version")) {
            version = v;
        } else if (std.mem.eql(u8, argv[i], "--fake-registry")) {
            fake = v;
        } else if (std.mem.eql(u8, argv[i], "--mojo-env")) {
            mojo = v;
        } else if (std.mem.eql(u8, argv[i], "--tarball")) {
            tarball = v;
        } else if (std.mem.eql(u8, argv[i], "--install-sh")) {
            installer = v;
        } else if (std.mem.eql(u8, argv[i], "--pixi")) {
            pixi = v;
        } else usageDie();
    }
    if (version == null or fake == null or mojo == null) usageDie();
    if ((tarball == null) != (installer == null)) usageDie();
    try std.fs.cwd().makePath(argv[2]);
    // pixi is found on PATH by mopm; the child needs a name it can run, not an absolute path.
    var rep = h.Report{};
    try h.watchdog(3300);
    try run(a, &rep, .{
        .mopm = try absolute(a, argv[1]),
        .work = try absolute(a, argv[2]),
        .version = version.?,
        .fake_registry = try absolute(a, fake.?),
        .mojo_env = try absolute(a, mojo.?),
        .tarball = if (tarball) |t| try absolute(a, t) else null,
        .install_sh = if (installer) |s| try absolute(a, s) else null,
        .pixi = pixi,
    });
    try rep.finish();
}

/// The arguments `parts` make, one after the other.
fn cat(a: Allocator, parts: []const []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (parts) |p| try out.appendSlice(p);
    return out.items;
}
