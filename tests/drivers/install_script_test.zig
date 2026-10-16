//! Runs site/static/install.sh (under /bin/sh: the one shell script in the project, because
//! `curl | sh` needs one) against a fake release served over loopback, on the machine it runs
//! on. It replaces the shell and Python scripts this test would otherwise be.
//!
//! GitHub Actions runs it on Linux and macOS (release-check.yml); it needs a shell, curl and a
//! network stack, which the build farm does not give, so no Buck2 target runs it:
//!
//!     zig test tests/drivers/install_script_test.zig        (from the repository root)
//!
//! It builds its helpers with the Zig it runs under (tools/release.zig to pack the fake release;
//! fake_mopm.zig, the "released" binary; fake_uname.zig, a `uname` that reports a chosen
//! platform).
//!
//! What it proves of the script under test:
//!   - the success path installs a runnable mopm: from an explicit version (with and without v),
//!     from /latest, into MOPM_HOME, and with the script on stdin as in `curl | sh`; it creates
//!     no file but $MOPM_HOME/bin/mopm; it prints the PATH line;
//!   - each uname -s / -m pair the script maps fetches that platform's tarball;
//!   - a tarball whose sha256 is not the one in SHA256SUMS is refused and an existing install
//!     survives; a SHA256SUMS that lacks the tarball, lists it twice, or is missing is refused;
//!   - a binary that does not report the version it was released as is refused;
//!   - an unsupported architecture or OS is refused before any request; no release at all is
//!     refused.
//! Then, as a standing step, it plants defects in copies of the script (a skipped sha check, any
//! platform accepted, a skipped version check, wrong platform mappings, "latest" not resolved)
//! and requires the same checks to go red for every one of them.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };

// ---- a loopback stand-in for GitHub releases ------------------------------------------------

/// GET /latest redirects to /tag/v<newest directory name under root>; GET
/// /download/v<version>/<file> serves root/<version>/<file>; GET /tag/* is an empty 200;
/// anything else is 404. Every request path is logged.
const Server = struct {
    root: []const u8,
    listener: std.net.Server,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    log: std.ArrayList([]const u8),

    fn start(a: Allocator, root: []const u8) !*Server {
        const s = try a.create(Server);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        s.* = .{
            .root = root,
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .log = std.ArrayList([]const u8).init(std.heap.page_allocator),
        };
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
        return s;
    }

    fn base(s: *Server, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{s.listener.listen_address.getPort()});
    }

    fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(s.listener.listen_address)) |c| c.close() else |_| {}
        s.thread.join();
        s.listener.deinit();
        s.log.deinit();
    }

    fn clear(s: *Server) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.log.clearRetainingCapacity();
    }

    fn requested(s: *Server, path: []const u8) bool {
        s.mutex.lock();
        defer s.mutex.unlock();
        for (s.log.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    fn requestCount(s: *Server) usize {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.log.items.len;
    }

    fn loop(s: *Server) void {
        while (true) {
            const conn = s.listener.accept() catch return;
            if (s.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            s.handle(conn.stream) catch {};
            conn.stream.close();
        }
    }

    fn send(stream: std.net.Stream, status: []const u8, extra: []const u8, body: []const u8) !void {
        var buf: [512]u8 = undefined;
        const head = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, extra, body.len });
        try stream.writeAll(head);
        try stream.writeAll(body);
    }

    fn handle(s: *Server, stream: std.net.Stream) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            if (n == buf.len) return;
            const k = try stream.read(buf[n..]);
            if (k == 0) return;
            n += k;
        }
        const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n").?;
        var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
        _ = parts.next();
        const path = parts.next() orelse return;
        {
            s.mutex.lock();
            defer s.mutex.unlock();
            try s.log.append(try std.heap.page_allocator.dupe(u8, path));
        }

        if (std.mem.eql(u8, path, "/latest")) {
            var dir = std.fs.cwd().openDir(s.root, .{ .iterate = true }) catch return send(stream, "404 Not Found", "", "");
            defer dir.close();
            var newest: ?[]const u8 = null;
            var it = dir.iterate();
            while (try it.next()) |e| {
                if (e.kind != .directory) continue;
                if (newest == null or std.mem.lessThan(u8, newest.?, e.name)) newest = try a.dupe(u8, e.name);
            }
            const v = newest orelse return send(stream, "404 Not Found", "", "");
            const loc = try std.fmt.allocPrint(a, "Location: /tag/v{s}\r\n", .{v});
            return send(stream, "302 Found", loc, "");
        }
        if (std.mem.startsWith(u8, path, "/tag/")) return send(stream, "200 OK", "", "");
        var segs = std.mem.splitScalar(u8, path, '/');
        _ = segs.next();
        const dl = segs.next() orelse "";
        const tag = segs.next() orelse "";
        const file = segs.next() orelse "";
        if (std.mem.eql(u8, dl, "download") and tag.len > 1 and tag[0] == 'v' and file.len > 0 and segs.next() == null and
            std.mem.indexOf(u8, tag, "..") == null and std.mem.indexOf(u8, file, "..") == null)
        {
            const p = try std.fs.path.join(a, &.{ s.root, tag[1..], file });
            if (std.fs.cwd().readFileAlloc(a, p, 64 << 20)) |bytes| {
                return send(stream, "200 OK", "", bytes);
            } else |_| {}
        }
        return send(stream, "404 Not Found", "", "");
    }
};

// ---- the helpers, built once ---------------------------------------------------------------

const Tools = struct {
    release: []const u8, // tools/release.zig
    mopm: []const u8, // the fake released binary
    shim_dir: []const u8, // holds a fake `uname`
};

fn buildTool(a: Allocator, src: []const u8, opt: []const u8, out: []const u8) !void {
    h.stage = "building a helper";
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{out});
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ "zig", "build-exe", src, "-O", opt, emit }, .max_output_bytes = 1 << 20 });
    if (r.term != .Exited or r.term.Exited != 0) {
        std.debug.print("zig build-exe {s} failed:\n{s}\n", .{ src, r.stderr });
        return error.BuildFailed;
    }
}

fn buildTools(a: Allocator, work: []const u8) !Tools {
    const shim_dir = try std.fs.path.join(a, &.{ work, "shim" });
    try std.fs.cwd().makePath(shim_dir);
    const t = Tools{
        .release = try std.fs.path.join(a, &.{ work, "release" }),
        .mopm = try std.fs.path.join(a, &.{ work, "fake_mopm" }),
        .shim_dir = shim_dir,
    };
    try buildTool(a, "tools/release.zig", "ReleaseSafe", t.release);
    try buildTool(a, "tests/drivers/fake_mopm.zig", "ReleaseSmall", t.mopm);
    try buildTool(a, "tests/drivers/fake_uname.zig", "ReleaseSmall", try std.fs.path.join(a, &.{ shim_dir, "uname" }));
    return t;
}

// ---- one pass over every case, against one script ------------------------------------------

const Rep = struct {
    verbose: bool,
    failures: usize = 0,

    fn check(self: *Rep, name: []const u8, ok: bool, detail: []const u8) void {
        h.stage = name;
        if (ok) {
            if (self.verbose) std.debug.print("ok   {s}\n", .{name});
        } else {
            self.failures += 1;
            if (self.verbose) std.debug.print("FAIL {s}: {s}\n", .{ name, detail });
        }
    }
};

const Pass = struct {
    a: Allocator,
    tools: Tools,
    script: []const u8, // absolute path of the script under test
    work: []const u8, // this pass's scratch directory
    rep: *Rep,
    seq: usize = 0,

    fn path(p: *Pass, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(p.a, parts);
    }

    /// <rel>/<ver>/ with a tarball per target and SHA256SUMS. `evil`: the tarballs hold a binary
    /// that is not the fake one (its sha256 is then listed honestly; callers swap SHA256SUMS).
    fn makeRelease(p: *Pass, rel: []const u8, ver: []const u8, evil: bool) !void {
        const a = p.a;
        const env = try h.environ(a);
        const out_dir = try p.path(&.{ rel, ver });
        try std.fs.cwd().makePath(out_dir);
        for (targets) |t| {
            p.seq += 1;
            const parent = try p.path(&.{ p.work, "pkg", try std.fmt.allocPrint(a, "{d}", .{p.seq}) });
            const name = try std.fmt.allocPrint(a, "mopm-{s}-{s}", .{ ver, t });
            const pkg = try p.path(&.{ parent, name });
            try std.fs.cwd().makePath(pkg);
            const bin = try p.path(&.{ pkg, "mopm" });
            if (evil) {
                const orig = try h.readFile(a, p.tools.mopm);
                const f = try std.fs.cwd().createFile(bin, .{ .mode = 0o755 });
                defer f.close();
                try f.writeAll(orig);
                try f.writeAll("tampered");
            } else {
                try std.fs.cwd().copyFile(p.tools.mopm, std.fs.cwd(), bin, .{});
            }
            const tgz = try p.path(&.{ out_dir, try std.fmt.allocPrint(a, "{s}.tar.gz", .{name}) });
            const r = try h.run(a, &.{ p.tools.release, "tarball", parent, name, tgz }, &env, .{});
            if (r.code != 0) {
                std.debug.print("release tarball failed: {s}\n", .{r.text});
                return error.ToolFailed;
            }
        }
        const r = try h.run(a, &.{ p.tools.release, "sums", out_dir }, &env, .{});
        if (r.code != 0) {
            std.debug.print("release sums failed: {s}\n", .{r.text});
            return error.ToolFailed;
        }
    }

    const Var = struct { []const u8, []const u8 };

    /// Runs the script in a fresh home: `sh <script>`, or the script on stdin. The result's text
    /// is stdout and stderr together.
    fn install(p: *Pass, base: []const u8, vars: []const Var, shim: bool, stdin: bool, keep_home: bool) !h.Ran {
        const a = p.a;
        const home = try p.path(&.{ p.work, "home" });
        if (!keep_home) {
            try std.fs.cwd().deleteTree(home);
            try std.fs.cwd().makePath(home);
        }
        var env = std.process.EnvMap.init(a);
        const real_path = std.process.getEnvVarOwned(a, "PATH") catch try a.dupe(u8, "/usr/bin:/bin");
        try env.put("PATH", if (shim) try std.fmt.allocPrint(a, "{s}:{s}", .{ p.tools.shim_dir, real_path }) else real_path);
        try env.put("HOME", home);
        try env.put("TMPDIR", p.work);
        try env.put("MOPM_RELEASES_URL", base);
        for (vars) |v| try env.put(v[0], v[1]);
        if (stdin) return h.run(a, &.{"/bin/sh"}, &env, .{ .stdin_path = p.script });
        return h.run(a, &.{ "/bin/sh", p.script }, &env, .{});
    }

    fn homeBin(p: *Pass) ![]u8 {
        return p.path(&.{ p.work, "home", ".mopm", "bin", "mopm" });
    }

    fn exists(path_: []const u8) bool {
        std.fs.cwd().access(path_, .{}) catch return false;
        return true;
    }

    /// What `<binary> --version` prints (FAKE_MOPM_VERSION says what the fake binary reports).
    fn reported(p: *Pass, bin: []const u8) ![]const u8 {
        var env = std.process.EnvMap.init(p.a);
        try env.put("FAKE_MOPM_VERSION", "1.2.3");
        const r = h.run(p.a, &.{ bin, "--version" }, &env, .{}) catch return "";
        return h.chomp(r.text);
    }

    /// The files under the home directory, sorted, one per line.
    fn homeTree(p: *Pass) ![]u8 {
        const a = p.a;
        var dir = try std.fs.cwd().openDir(try p.path(&.{ p.work, "home" }), .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(a);
        defer walker.deinit();
        var names = std.ArrayList([]const u8).init(a);
        while (try walker.next()) |e| try names.append(try a.dupe(u8, e.path));
        h.sortStrings(names.items);
        return std.mem.join(a, "\n", names.items);
    }

    fn run(p: *Pass) !void {
        const a = p.a;
        const rep = p.rep;
        const rel = try p.path(&.{ p.work, "rel" });
        try p.makeRelease(rel, "1.2.3", false);
        try p.makeRelease(rel, "1.0.0", false);
        var srv = try Server.start(a, rel);
        const base = try srv.base(a);

        // 1. Success with an explicit version, with and without the v.
        for ([_][]const u8{ "1.2.3", "v1.2.3" }) |v| {
            const r = try p.install(base, &.{ .{ "MOPM_VERSION", v }, .{ "FAKE_MOPM_VERSION", "1.2.3" } }, false, false, false);
            const bin = try p.homeBin();
            const name = try std.fmt.allocPrint(a, "install MOPM_VERSION={s}", .{v});
            rep.check(name, r.code == 0 and std.mem.eql(u8, try p.reported(bin), "mopm 1.2.3"), r.text);
            rep.check("the PATH line is printed", h.contains(r.text, "export PATH="), r.text);
            const tree = try p.homeTree();
            rep.check("install creates only MOPM_HOME/bin/mopm", std.mem.eql(u8, tree, ".mopm\n.mopm/bin\n.mopm/bin/mopm"), tree);
        }

        // 2. Latest (the newest directory is 1.2.3), into MOPM_HOME.
        {
            const custom = try p.path(&.{ p.work, "custom" });
            try std.fs.cwd().deleteTree(custom);
            const r = try p.install(base, &.{ .{ "MOPM_HOME", custom }, .{ "FAKE_MOPM_VERSION", "1.2.3" } }, false, false, false);
            const bin = try p.path(&.{ custom, "bin", "mopm" });
            rep.check("install latest into MOPM_HOME", r.code == 0 and std.mem.eql(u8, try p.reported(bin), "mopm 1.2.3"), r.text);
        }

        // 3. The script on stdin, as in curl | sh.
        {
            const r = try p.install(base, &.{ .{ "MOPM_VERSION", "1.0.0" }, .{ "FAKE_MOPM_VERSION", "1.0.0" } }, false, true, false);
            rep.check("install with the script on stdin", r.code == 0 and exists(try p.homeBin()), r.text);
        }

        // 4. Each platform fetches its own file.
        const Row = struct { os: []const u8, arch: []const u8, want: []const u8 };
        const rows = [_]Row{
            .{ .os = "Linux", .arch = "x86_64", .want = "linux-x86_64" },
            .{ .os = "Linux", .arch = "amd64", .want = "linux-x86_64" },
            .{ .os = "Linux", .arch = "aarch64", .want = "linux-aarch64" },
            .{ .os = "Linux", .arch = "arm64", .want = "linux-aarch64" },
            .{ .os = "Darwin", .arch = "arm64", .want = "macos-arm64" },
            .{ .os = "Darwin", .arch = "x86_64", .want = "macos-x86_64" },
        };
        for (rows) |row| {
            srv.clear();
            const r = try p.install(base, &.{ .{ "MOPM_VERSION", "1.2.3" }, .{ "FAKE_OS", row.os }, .{ "FAKE_ARCH", row.arch }, .{ "FAKE_MOPM_VERSION", "1.2.3" } }, true, false, false);
            const want = try std.fmt.allocPrint(a, "/download/v1.2.3/mopm-1.2.3-{s}.tar.gz", .{row.want});
            const name = try std.fmt.allocPrint(a, "{s} {s} fetches {s}", .{ row.os, row.arch, row.want });
            rep.check(name, r.code == 0 and srv.requested(want), r.text);
        }

        // 5. Unsupported platforms are refused before any request.
        const bad = [_][2][]const u8{ .{ "Linux", "riscv64" }, .{ "Linux", "i686" }, .{ "Darwin", "ppc64" }, .{ "FreeBSD", "amd64" }, .{ "Linux", "armv7l" } };
        for (bad) |row| {
            srv.clear();
            const r = try p.install(base, &.{ .{ "MOPM_VERSION", "1.2.3" }, .{ "FAKE_OS", row[0] }, .{ "FAKE_ARCH", row[1] } }, true, false, false);
            const name = try std.fmt.allocPrint(a, "{s} {s} is refused", .{ row[0], row[1] });
            rep.check(name, r.code != 0 and h.contains(r.text, "no mopm release for") and srv.requestCount() == 0 and !exists(try p.homeBin()), r.text);
        }
        srv.stop();

        // 6. A tampered tarball (SHA256SUMS is the original's) is refused; an existing install survives.
        {
            const orig = try p.path(&.{ p.work, "orig" });
            const tampered = try p.path(&.{ p.work, "tampered" });
            try p.makeRelease(orig, "1.2.3", false);
            try p.makeRelease(tampered, "1.2.3", true);
            const sums = try h.readFile(a, try p.path(&.{ orig, "1.2.3", "SHA256SUMS" }));
            try h.writeFile(try p.path(&.{ tampered, "1.2.3", "SHA256SUMS" }), sums);
            srv = try Server.start(a, tampered);
            defer srv.stop();
            const home_bin_dir = try p.path(&.{ p.work, "home", ".mopm", "bin" });
            try std.fs.cwd().deleteTree(try p.path(&.{ p.work, "home" }));
            try std.fs.cwd().makePath(home_bin_dir);
            try h.writeFile(try p.homeBin(), "previous\n");
            const r = try p.install(try srv.base(a), &.{ .{ "MOPM_VERSION", "1.2.3" }, .{ "FAKE_MOPM_VERSION", "1.2.3" } }, false, false, true);
            const kept = try h.readFile(a, try p.homeBin());
            rep.check("a tampered tarball is refused and the previous install is kept", r.code != 0 and h.contains(r.text, "sha256 mismatch") and std.mem.eql(u8, kept, "previous\n"), r.text);
        }

        // 7. SHA256SUMS that lacks the tarball, lists it twice, or is missing.
        for ([_][]const u8{ "nolist", "twice", "nosums" }) |kind| {
            const dir = try p.path(&.{ p.work, kind });
            try p.makeRelease(dir, "1.2.3", false);
            const sums_path = try p.path(&.{ dir, "1.2.3", "SHA256SUMS" });
            const sums = try h.readFile(a, sums_path);
            if (std.mem.eql(u8, kind, "nosums")) {
                try std.fs.cwd().deleteFile(sums_path);
            } else if (std.mem.eql(u8, kind, "twice")) {
                try h.writeFile(sums_path, try std.mem.concat(a, u8, &.{ sums, sums }));
            } else {
                try h.writeFile(sums_path, "");
            }
            var s = try Server.start(a, dir);
            defer s.stop();
            const r = try p.install(try s.base(a), &.{ .{ "MOPM_VERSION", "1.2.3" }, .{ "FAKE_MOPM_VERSION", "1.2.3" } }, false, false, false);
            const name = try std.fmt.allocPrint(a, "SHA256SUMS case {s} is refused", .{kind});
            rep.check(name, r.code != 0 and !exists(try p.homeBin()), r.text);
        }

        // 8. A binary that reports another version than the release is refused.
        {
            const dir = try p.path(&.{ p.work, "liar" });
            try p.makeRelease(dir, "1.2.3", false);
            var s = try Server.start(a, dir);
            defer s.stop();
            const r = try p.install(try s.base(a), &.{ .{ "MOPM_VERSION", "1.2.3" }, .{ "FAKE_MOPM_VERSION", "9.9.9" } }, false, false, false);
            rep.check("a binary reporting another version is refused", r.code != 0 and !exists(try p.homeBin()) and h.contains(r.text, "did not report 'mopm 1.2.3'"), r.text);
        }

        // 9. No release at all.
        {
            const dir = try p.path(&.{ p.work, "empty" });
            try std.fs.cwd().makePath(dir);
            var s = try Server.start(a, dir);
            defer s.stop();
            const r = try p.install(try s.base(a), &.{.{ "FAKE_MOPM_VERSION", "1.2.3" }}, false, false, false);
            rep.check("no release at all is refused", r.code != 0 and !exists(try p.homeBin()), r.text);
        }
    }
};

// ---- the planted defects ---------------------------------------------------------------------

const Mutant = struct { name: []const u8, from: []const u8, to: []const u8 };

const mutants = [_]Mutant{
    .{
        .name = "skip-sha-compare",
        .from = "[ \"$got\" = \"$want\" ] || die \"sha256 mismatch for $asset: got $got, SHA256SUMS says $want; nothing was installed\"",
        .to = "true",
    },
    .{
        .name = "any-platform-accepted",
        .from = "    *) die \"no mopm release for $(uname -s) $(uname -m); there are releases for Linux and macOS on x86_64 and arm64\" ;;",
        .to = "    *) target=linux-x86_64 ;;",
    },
    .{
        .name = "skip-binary-version-check",
        .from = "if [ \"$(\"$home/bin/.mopm.new.$$\" --version 2>/dev/null)\" != \"mopm $version\" ]; then",
        .to = "if false; then",
    },
    .{
        .name = "macos-arm-maps-to-intel",
        .from = "Darwin-arm64) target=macos-arm64 ;;",
        .to = "Darwin-arm64) target=macos-x86_64 ;;",
    },
    .{
        .name = "aarch64-maps-to-x86",
        .from = "Linux-aarch64|Linux-arm64) target=linux-aarch64 ;;",
        .to = "Linux-aarch64|Linux-arm64) target=linux-x86_64 ;;",
    },
    .{
        .name = "latest-not-resolved",
        .from = "    tag=${url##*/}",
        .to = "    tag=v1.0.0",
    },
};

test "install.sh against a fake release, and the planted defects are caught" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.watchdog(1500);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try h.tmpPath(a, &tmp);
    const tools = try buildTools(a, try std.fs.path.join(a, &.{ root, "tools" }));
    const script = try std.fs.cwd().realpathAlloc(a, "site/static/install.sh");

    // The script as it is: every check passes.
    var rep = Rep{ .verbose = true };
    var pass = Pass{ .a = a, .tools = tools, .script = script, .work = try std.fs.path.join(a, &.{ root, "clean" }), .rep = &rep };
    try pass.run();
    try std.testing.expectEqual(@as(usize, 0), rep.failures);

    // Each planted defect must turn at least one check red.
    const text = try h.readFile(a, script);
    var survived: usize = 0;
    for (mutants) |m| {
        if (std.mem.indexOf(u8, text, m.from) == null) {
            std.debug.print("MUTANT {s}: the line it replaces is not in install.sh\n", .{m.name});
            survived += 1;
            continue;
        }
        const mutated = try std.mem.replaceOwned(u8, a, text, m.from, m.to);
        const work = try std.fmt.allocPrint(a, "{s}/mutant-{s}", .{ root, m.name });
        const mscript = try std.fs.path.join(a, &.{ root, try std.fmt.allocPrint(a, "install-{s}.sh", .{m.name}) });
        try h.writeFile(mscript, mutated);
        var mrep = Rep{ .verbose = false };
        var mpass = Pass{ .a = a, .tools = tools, .script = mscript, .work = work, .rep = &mrep };
        try mpass.run();
        if (mrep.failures == 0) {
            std.debug.print("MUTANT {s} SURVIVED: every check still passed\n", .{m.name});
            survived += 1;
        } else {
            std.debug.print("mutant {s} killed ({d} failing checks)\n", .{ m.name, mrep.failures });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), survived);
}
