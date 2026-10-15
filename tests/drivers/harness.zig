//! Shared by the Zig test drivers beside it (golden_test.zig, login_test.zig,
//! publish_test.zig): run a program and capture its output, talk HTTP to a
//! loopback server, start the fake registry, report `ok` / `FAIL` per check.
//! Standard library only. The drivers are run by Buck2 as zig_tests that get
//! the built programs as environment variables (BUCK); they replace the shell
//! and Python scripts of the same names for the farm, which has neither.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// `ok   <name>` / `FAIL <name>: <detail>` lines, and the number of failures.
pub const Report = struct {
    failures: usize = 0,

    pub fn check(self: *Report, name: []const u8, ok: bool, detail: []const u8) void {
        stage = name;
        if (ok) {
            std.debug.print("ok   {s}\n", .{name});
        } else {
            std.debug.print("FAIL {s}: {s}\n", .{ name, detail });
            self.failures += 1;
        }
    }

    /// `want` and `got` are the same bytes; a difference prints both.
    pub fn same(self: *Report, name: []const u8, want: []const u8, got: []const u8) void {
        if (std.mem.eql(u8, want, got)) {
            std.debug.print("ok   {s}\n", .{name});
        } else {
            std.debug.print("FAIL {s}: output differs\n--- want\n{s}--- got\n{s}---\n", .{ name, want, got });
            self.failures += 1;
        }
    }

    pub fn finish(self: *Report) !void {
        if (self.failures != 0) {
            std.debug.print("{d} failure(s)\n", .{self.failures});
            return error.ChecksFailed;
        }
    }
};

pub const Capture = enum { both, stdout, stderr };

pub const Ran = struct {
    /// The exit status, or the signal number when `signaled`.
    code: u8,
    signaled: bool,
    text: []u8,
};

pub const Options = struct {
    stdin_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    capture: Capture = .both,
};

/// The environment of this process.
pub fn environ(a: Allocator) !std.process.EnvMap {
    return std.process.getEnvMap(a);
}

/// An environment variable the BUCK target sets (a built program's path),
/// made absolute so a child with another working directory can use it.
pub fn toolPath(a: Allocator, name: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the environment variable {s} is not set (BUCK gives it with env_tools)\n", .{name});
        return error.MissingTool;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs `argv` (argv[0] is a path) with exactly `env`, the working directory
/// and standard input of `opt`, and returns what it wrote to the captured
/// stream(s); `.both` is one pipe for both, in the order written, as `2>&1`.
pub fn run(a: Allocator, argv: []const []const u8, env: *const std.process.EnvMap, opt: Options) !Ran {
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |s, i| argv_z[i] = (try a.dupeZ(u8, s)).ptr;
    const envp = try a.allocSentinel(?[*:0]u8, env.count(), null);
    {
        var it = env.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            envp[i] = (try std.fmt.allocPrintZ(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* })).ptr;
        }
    }
    const stdin_z: ?[:0]const u8 = if (opt.stdin_path) |p| try a.dupeZ(u8, p) else null;
    const cwd_z: ?[:0]const u8 = if (opt.cwd) |p| try a.dupeZ(u8, p) else null;
    const fds = try posix.pipe();
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(fds[0]);
        const devnull = posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(127);
        const in_fd = if (stdin_z) |p| (posix.openZ(p, .{ .ACCMODE = .RDONLY }, 0) catch posix.exit(127)) else devnull;
        posix.dup2(in_fd, 0) catch posix.exit(127);
        const out_fd = if (opt.capture == .stderr) devnull else fds[1];
        const err_fd = if (opt.capture == .stdout) devnull else fds[1];
        posix.dup2(out_fd, 1) catch posix.exit(127);
        posix.dup2(err_fd, 2) catch posix.exit(127);
        if (cwd_z) |p| posix.chdirZ(p) catch posix.exit(127);
        const exec_err = posix.execvpeZ(argv_z[0].?, argv_z.ptr, envp.ptr);
        std.debug.print("exec {s}: {s}\n", .{ argv[0], @errorName(exec_err) });
        posix.exit(127);
    }
    posix.close(fds[1]);
    var text = std.ArrayList(u8).init(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fds[0], &buf);
        if (n == 0) break;
        try text.appendSlice(buf[0..n]);
    }
    posix.close(fds[0]);
    const w = posix.waitpid(pid, 0);
    if (posix.W.IFEXITED(w.status)) {
        return .{ .code = posix.W.EXITSTATUS(w.status), .signaled = false, .text = text.items };
    }
    return .{ .code = @truncate(posix.W.TERMSIG(w.status)), .signaled = true, .text = text.items };
}

pub fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 64 << 20);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().writeFile(path, bytes);
}

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `s` without trailing newlines, as a shell's $(...) gives it.
pub fn chomp(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n");
}

// ------------------------------------------------------------------ HTTP

pub const Response = struct { status: u16, body: []u8 };

/// A response with its head (the status line and the header lines, without
/// the blank line that ends them).
pub const Full = struct { status: u16, head: []u8, body: []u8 };

pub const Header = struct { name: []const u8, value: []const u8 };

/// One request to `http://host:port<path>` (`base` is `http://host:port`),
/// `Connection: close`, the answer read to the end. A body is JSON.
pub fn request(a: Allocator, method: []const u8, base: []const u8, path: []const u8, body: ?[]const u8, token: ?[]const u8) !Response {
    const r = try requestFull(a, method, base, path, body, token, "application/json", &.{});
    return .{ .status = r.status, .body = r.body };
}

/// `request` with the content type of the body, more request headers (a
/// Content-Length, Host, Connection or Content-Type among them is ignored:
/// this function sets them), and the head of the answer.
pub fn requestFull(a: Allocator, method: []const u8, base: []const u8, path: []const u8, body: ?[]const u8, token: ?[]const u8, content_type: []const u8, extra: []const Header) !Full {
    const hostport = base["http://".len..];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':').?;
    const port = try std.fmt.parseInt(u16, hostport[colon + 1 ..], 10);
    const addr = try std.net.Address.parseIp(hostport[0..colon], port);
    stage = "http: connecting";
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    var req = std.ArrayList(u8).init(a);
    const w = req.writer();
    try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, hostport });
    if (body) |b| try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ content_type, b.len });
    if (token) |t| try w.print("Authorization: Bearer {s}\r\n", .{t});
    for (extra) |hd| {
        if (std.ascii.eqlIgnoreCase(hd.name, "content-length") or std.ascii.eqlIgnoreCase(hd.name, "host") or
            std.ascii.eqlIgnoreCase(hd.name, "connection") or std.ascii.eqlIgnoreCase(hd.name, "content-type")) continue;
        try w.print("{s}: {s}\r\n", .{ hd.name, hd.value });
    }
    try w.writeAll("\r\n");
    if (body) |b| try w.writeAll(b);
    stage = "http: writing the request";
    try stream.writeAll(req.items);
    stage = "http: reading the answer";
    // The server may keep the connection open: read the head, then exactly
    // Content-Length bytes (to the end of the stream if it names none).
    var raw = std.ArrayList(u8).init(a);
    var buf: [4096]u8 = undefined;
    var head_end: usize = 0;
    var want: ?usize = null;
    while (true) {
        if (head_end == 0) {
            if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |at| {
                head_end = at + 4;
                want = contentLength(raw.items[0..at]);
            }
        }
        if (head_end != 0 and want != null and raw.items.len >= head_end + want.?) break;
        const n = try stream.read(&buf);
        if (n == 0) break;
        try raw.appendSlice(buf[0..n]);
    }
    if (head_end == 0) return error.BadResponse;
    const eol = std.mem.indexOf(u8, raw.items, "\r\n").?;
    var parts = std.mem.splitScalar(u8, raw.items[0..eol], ' ');
    _ = parts.next();
    const status = try std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10);
    return .{ .status = status, .head = raw.items[0 .. head_end - 4], .body = raw.items[head_end..] };
}

pub fn parseJson(a: Allocator, bytes: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value;
}

/// The string at `key` of a JSON object, or null.
pub fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

// ------------------------------------------------------- the fake registry

pub const Fake = struct {
    child: std.process.Child,
    base: []u8,

    pub fn start(a: Allocator, exe: []const u8, dir: []const u8) !Fake {
        const argv = try a.dupe([]const u8, &.{ exe, "--dir", dir, "--port", "0", "--poll-interval", "1" });
        var child = std.process.Child.init(argv, a);
        child.stdout_behavior = .Pipe;
        try child.spawn();
        const line = try readLine(a, child.stdout.?);
        const marker = "listening on ";
        const at = std.mem.indexOf(u8, line, marker) orelse {
            std.debug.print("the fake registry did not start: {s}\n", .{line});
            return error.FakeDidNotStart;
        };
        return .{ .child = child, .base = try a.dupe(u8, std.mem.trim(u8, line[at + marker.len ..], " \r")) };
    }

    pub fn api(self: Fake, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/api/v1", .{self.base});
    }

    /// POST /_fake<path> with a JSON body, the JSON answer.
    pub fn control(self: Fake, a: Allocator, path: []const u8, body: []const u8) !std.json.Value {
        const full = try std.fmt.allocPrint(a, "/_fake{s}", .{path});
        const r = try request(a, "POST", self.base, full, body, null);
        return parseJson(a, r.body);
    }

    pub fn close(self: *Fake) void {
        _ = self.child.kill() catch {};
    }
};

pub fn readLine(a: Allocator, file: std.fs.File) ![]u8 {
    var line = std.ArrayList(u8).init(a);
    while (true) {
        var b: [1]u8 = undefined;
        const n = try file.read(&b);
        if (n == 0 or b[0] == '\n') break;
        try line.append(b[0]);
    }
    return line.items;
}

/// The directory `tmp` as an absolute path.
pub fn tmpPath(a: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(a, ".");
}

pub fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

pub fn fmt(a: Allocator, comptime f: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(a, f, args);
}

/// A copy of an environment (this zig's EnvMap has no clone).
pub fn cloneEnv(a: Allocator, src: *const std.process.EnvMap) !std.process.EnvMap {
    var out = std.process.EnvMap.init(a);
    var it = src.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// What the test was last doing, for the watchdog's message.
pub var stage: []const u8 = "starting";

/// Ends the process with a message after `seconds`: a driver that waits on a
/// child or a server must fail with a reason, not hang until the action's own
/// deadline.
pub fn watchdog(seconds: u64) !void {
    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: u64) void {
            std.time.sleep(s * std.time.ns_per_s);
            std.debug.print("FAIL watchdog: no progress in {d} s; last step: {s}\n", .{ s, stage });
            std.process.exit(3);
        }
    }.run, .{seconds});
    t.detach();
}

/// The Content-Length of a response head, if it names one.
fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(l[0..colon], "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, l[colon + 1 ..], " "), 10) catch null;
    }
    return null;
}
