//! //:signin_e2e: tests/drivers/signin_e2e.zig, the read-only checks of the website's sign-in and sandbox routes that the
//! smoke-linux job of .github/workflows/e2e.yml runs after each deploy, against two servers this file starts on loopback
//! ports: a site host (the site distribution's `/api/*`: the session, sandbox and start routes) and an API host (the start
//! route without the edge header). The farm has no network, so no stage is reachable from here.
//!
//! The servers answer as docs/design/tutorial-sign-in.md and the functions' READMEs say (the default), or wrong in one of the
//! ways of `Defect`. One test runs the check against the correct servers and asserts its whole output, and the requests it
//! sent: five, no cookie and no `Authorization` in any, the navigation headers on two, the site's `Origin` on the sandbox
//! request, and nothing sent to GitHub. One test takes each defect in turn and asserts the whole output: the check that owns
//! the defect fails with the exact lines that name it, the other four pass, and no line holds the `state`, the
//! `code_challenge` or a cookie's or token's value. The others cover a run with a defect in every check, the tries after no
//! answer or a transient answer (the pause between tries is counted, never slept), a host that is down, the command line,
//! and the built program (SIGNIN_E2E) as a process.

const std = @import("std");
const h = @import("harness.zig");
const s = @import("signin_e2e.zig");
const Allocator = std.mem.Allocator;

// The values the check must never print.
const state = "STATE+e2e+never+printed";
const challenge = "CHALLENGE-e2e-never-printed";
const txn = "TXN-e2e-never-printed";
const session_value = "mopm_sessione2eneverprinted";
const sandbox_token = "SANDBOX-TOKEN-e2e-never-printed";
const secrets = [_][]const u8{ state, "STATE e2e never printed", challenge, txn, session_value, sandbox_token };

const client_id = "Iv1.e2eclient0001";

/// The ways the servers can be wrong. The default is right.
const Defect = enum {
    session_200,
    session_404_page,
    session_cacheable,
    session_no_request_id,
    session_wrong_code,
    session_error_not_object,
    sandbox_csrf_first,
    sandbox_201,
    start_store_failed,
    start_error_not_a_code,
    start_no_request_id,
    start_no_location,
    start_two_locations,
    start_wrong_place,
    start_scope,
    start_plain,
    start_no_state,
    start_empty_state,
    start_no_challenge,
    start_empty_client_id,
    start_two_client_ids,
    start_redirect_path,
    start_bad_escape,
    start_short_escape,
    cookie_strict,
    cookie_no_secure,
    cookie_no_httponly,
    cookie_path,
    cookie_max_age,
    cookie_domain,
    cookie_name,
    cookie_empty,
    cookie_none,
    cookie_two,
    cookie_no_pair,
    refused_start_redirects,
    refused_start_sets_cookie,
    refused_start_html,
    api_start_redirects,
    api_start_sets_cookie,
};
const Defects = std.EnumSet(Defect);

const Role = enum { site, api };

const Seen = struct { method: []const u8, target: []const u8, headers: []const s.Header };

fn header(headers: []const s.Header, name: []const u8) ?[]const u8 {
    for (headers) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
    return null;
}

const Resp = struct { status: u16, headers: []const [2][]const u8 = &.{}, body: []const u8 = "" };

const json = [2][]const u8{ "content-type", "application/json" };
const html = [2][]const u8{ "content-type", "text/html" };
const no_store = [2][]const u8{ "cache-control", "no-store" };

fn envelope(code: []const u8) []const u8 {
    return if (std.mem.eql(u8, code, "session_required"))
        "{\"error\":{\"code\":\"session_required\",\"message\":\"m\",\"hint\":\"h\"}}"
    else if (std.mem.eql(u8, code, "invalid_request"))
        "{\"error\":{\"code\":\"invalid_request\",\"message\":\"m\",\"hint\":\"h\"}}"
    else
        "{\"error\":{\"code\":\"csrf_failed\",\"message\":\"m\",\"hint\":\"h\"}}";
}

/// A loopback server playing the site host or the API host.
const Fake = struct {
    role: Role,
    defects: Defects,
    /// The site's origin, for the redirect_uri and the failure redirect (the site fake's own base).
    site: []const u8 = "",
    /// The target whose first request is closed with no answer.
    drop_first: ?[]const u8 = null,
    /// Every request is closed with no answer.
    drop_all: bool = false,
    /// The target answered 503 for its first `busy_times` requests.
    busy: ?[]const u8 = null,
    busy_times: u32 = 0,
    listener: std.net.Server,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    arena: std.heap.ArenaAllocator,
    seen: std.ArrayList(Seen),

    fn start(a: Allocator, role: Role, defects: Defects) !*Fake {
        const f = try a.create(Fake);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        f.* = .{
            .role = role,
            .defects = defects,
            .listener = try addr.listen(.{ .reuse_address = true }),
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .seen = std.ArrayList(Seen).init(std.heap.page_allocator),
        };
        if (role == .site) f.site = try f.base(a);
        f.thread = try std.Thread.spawn(.{}, loop, .{f});
        return f;
    }

    fn base(f: *Fake, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.listen_address.getPort()});
    }

    fn stop(f: *Fake) void {
        if (f.stopping.swap(true, .acq_rel)) return;
        if (std.net.tcpConnectToAddress(f.listener.listen_address)) |c| c.close() else |_| {}
        f.thread.join();
        f.listener.deinit();
    }

    fn deinit(f: *Fake) void {
        f.stop();
        f.seen.deinit();
        f.arena.deinit();
    }

    fn has(f: *Fake, d: Defect) bool {
        return f.defects.contains(d);
    }

    fn requests(f: *Fake) []const Seen {
        f.mutex.lock();
        defer f.mutex.unlock();
        return f.seen.items;
    }

    fn count(f: *Fake, target: []const u8) usize {
        var n: usize = 0;
        for (f.requests()) |r| if (std.mem.eql(u8, r.target, target)) {
            n += 1;
        };
        return n;
    }

    fn loop(f: *Fake) void {
        while (true) {
            const conn = f.listener.accept() catch return;
            if (f.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            f.handle(conn.stream) catch {};
            conn.stream.close();
        }
    }

    fn handle(f: *Fake, stream: std.net.Stream) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [16 * 1024]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            if (n == buf.len) return;
            const k = try stream.read(buf[n..]);
            if (k == 0) return;
            n += k;
        }
        const head = buf[0 .. std.mem.indexOf(u8, buf[0..n], "\r\n\r\n").?];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        var first = std.mem.splitScalar(u8, lines.first(), ' ');
        const method = first.next() orelse return;
        const target = first.next() orelse return;
        const keep = f.arena.allocator();
        var headers = std.ArrayList(s.Header).init(keep);
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try headers.append(.{ .name = try keep.dupe(u8, line[0..colon]), .value = try keep.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t")) });
        }
        const seen = Seen{ .method = try keep.dupe(u8, method), .target = try keep.dupe(u8, target), .headers = headers.items };
        const nth = blk: {
            f.mutex.lock();
            defer f.mutex.unlock();
            try f.seen.append(seen);
            var k: usize = 0;
            for (f.seen.items) |r| if (std.mem.eql(u8, r.target, target)) {
                k += 1;
            };
            break :blk k;
        };
        if (f.drop_all) return;
        if (f.drop_first) |t| if (std.mem.eql(u8, t, target) and nth == 1) return;
        if (f.busy) |t| if (std.mem.eql(u8, t, target) and nth <= f.busy_times) return send(stream, .{ .status = 503, .headers = &.{html}, .body = "<html>busy</html>" });
        return send(stream, try f.answer(a, seen));
    }

    fn answer(f: *Fake, a: Allocator, r: Seen) !Resp {
        const get = std.mem.eql(u8, r.method, "GET");
        const post = std.mem.eql(u8, r.method, "POST");
        const is_start = get and std.mem.eql(u8, r.target, s.start_path);
        if (f.role == .api) {
            if (!is_start) return notFound();
            if (f.has(.api_start_redirects)) return f.redirect(a, "req-api-start", false);
            var hs = std.ArrayList([2][]const u8).init(a);
            try hs.appendSlice(&.{ json, .{ "x-mopm-request-id", "req-api-start" }, no_store });
            if (f.has(.api_start_sets_cookie)) try hs.append(.{ "set-cookie", s.login_cookie ++ "=" ++ txn ++ "; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600" });
            return .{ .status = 401, .headers = hs.items, .body = envelope("session_required") };
        }
        if (get and std.mem.eql(u8, r.target, s.session_path)) return f.session();
        if (post and std.mem.eql(u8, r.target, s.sandbox_path)) return f.sandbox();
        if (!is_start) return notFound();
        if (navigation(r.headers)) {
            if (f.has(.start_store_failed) or f.has(.start_error_not_a_code)) {
                var hs = std.ArrayList([2][]const u8).init(a);
                try hs.append(.{ "location", try std.fmt.allocPrint(a, "{s}/tutorial?error={s}", .{ f.site, if (f.has(.start_error_not_a_code)) state else "unavailable" }) });
                try hs.appendSlice(&.{ .{ "x-mopm-request-id", "req-start" }, no_store });
                return .{ .status = 303, .headers = hs.items };
            }
            return f.redirect(a, "req-start", f.has(.start_no_request_id));
        }
        if (f.has(.refused_start_redirects)) return f.redirect(a, "req-start-refused", false);
        if (f.has(.refused_start_html)) return .{ .status = 400, .headers = &.{html}, .body = "<p>bad request</p>" };
        var hs = std.ArrayList([2][]const u8).init(a);
        try hs.appendSlice(&.{ json, .{ "x-mopm-request-id", "req-start-refused" }, no_store });
        if (f.has(.refused_start_sets_cookie)) try hs.append(.{ "set-cookie", s.login_cookie ++ "=" ++ txn ++ "; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600" });
        return .{ .status = 400, .headers = hs.items, .body = envelope("invalid_request") };
    }

    fn notFound() Resp {
        return .{ .status = 404, .headers = &.{html}, .body = "<!doctype html><title>Not found</title>" };
    }

    fn session(f: *Fake) Resp {
        if (f.has(.session_404_page)) return notFound();
        if (f.has(.session_200)) return .{ .status = 200, .headers = &.{ json, .{ "x-mopm-request-id", "req-session" }, no_store }, .body = "{\"csrf\":\"" ++ session_value ++ "\",\"expires_at\":\"x\",\"login\":\"someone\"}" };
        const body = if (f.has(.session_wrong_code)) envelope("csrf_failed") else if (f.has(.session_error_not_object)) "{\"error\":\"session_required\"}" else envelope("session_required");
        if (f.has(.session_cacheable)) return .{ .status = 401, .headers = &.{ json, .{ "x-mopm-request-id", "req-session" }, .{ "cache-control", "max-age=60" } }, .body = body };
        if (f.has(.session_no_request_id)) return .{ .status = 401, .headers = &.{ json, no_store }, .body = body };
        return .{ .status = 401, .headers = &.{ json, .{ "x-mopm-request-id", "req-session" }, .{ "cache-control", "private, no-store" } }, .body = body };
    }

    fn sandbox(f: *Fake) Resp {
        if (f.has(.sandbox_csrf_first)) return .{ .status = 403, .headers = &.{ json, .{ "x-mopm-request-id", "req-sandbox" }, no_store }, .body = envelope("csrf_failed") };
        if (f.has(.sandbox_201)) return .{ .status = 201, .headers = &.{ json, .{ "x-mopm-request-id", "req-sandbox" }, no_store }, .body = "{\"access_token\":\"" ++ sandbox_token ++ "\"}" };
        return .{ .status = 401, .headers = &.{ json, .{ "x-mopm-request-id", "req-sandbox" }, no_store }, .body = envelope("session_required") };
    }

    /// The start route's redirect to GitHub with the login cookie, as the function makes it, but for the defects.
    fn redirect(f: *Fake, a: Allocator, id: []const u8, no_id: bool) !Resp {
        var hs = std.ArrayList([2][]const u8).init(a);
        if (!no_id) try hs.append(.{ "x-mopm-request-id", id });
        try hs.append(no_store);
        const loc = try f.location(a);
        if (!f.has(.start_no_location)) try hs.append(.{ "location", loc });
        if (f.has(.start_two_locations)) try hs.append(.{ "location", loc });
        if (!f.has(.cookie_none)) try hs.append(.{ "set-cookie", try f.cookie(a) });
        if (f.has(.cookie_two)) try hs.append(.{ "set-cookie", "__Host-mopm_session=" ++ session_value ++ "; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800" });
        return .{ .status = 302, .headers = hs.items };
    }

    fn location(f: *Fake, a: Allocator) ![]const u8 {
        var q = std.ArrayList(u8).init(a);
        const w = q.writer();
        try w.writeAll(if (f.has(.start_wrong_place)) "https://github.com/login/oauth/authorise?" else s.github_authorize ++ "?");
        try w.print("client_id={s}", .{if (f.has(.start_empty_client_id)) "" else client_id});
        if (f.has(.start_two_client_ids)) try w.print("&client_id={s}", .{client_id});
        const redirect_uri = try std.fmt.allocPrint(a, "{s}{s}", .{ f.site, if (f.has(.start_redirect_path)) "/api/v2/auth/web/cb" else s.callback_path });
        try w.writeAll("&redirect_uri=");
        try formEncode(w, redirect_uri);
        try w.writeAll(if (f.has(.start_scope)) "&scope=user" else "&scope=read%3Auser");
        if (!f.has(.start_no_state)) try w.print("&state={s}", .{if (f.has(.start_empty_state)) "" else state});
        if (!f.has(.start_no_challenge)) try w.print("&code_challenge={s}", .{challenge});
        try w.writeAll(if (f.has(.start_plain)) "&code_challenge_method=plain" else "&code_challenge_method=S256");
        try w.writeAll("&prompt=select_account");
        if (f.has(.start_bad_escape)) try w.writeAll("&x=%zz");
        if (f.has(.start_short_escape)) try w.writeAll("&x=%4");
        return q.items;
    }

    fn cookie(f: *Fake, a: Allocator) ![]const u8 {
        var c = std.ArrayList(u8).init(a);
        const w = c.writer();
        if (f.has(.cookie_no_pair)) try w.writeAll(txn) else try w.print("{s}={s}", .{ if (f.has(.cookie_name)) "mopm_login" else s.login_cookie, if (f.has(.cookie_empty)) "" else txn });
        if (!f.has(.cookie_no_secure)) try w.writeAll("; Secure");
        if (!f.has(.cookie_no_httponly)) try w.writeAll("; HttpOnly");
        try w.writeAll(if (f.has(.cookie_path)) "; Path=/api" else "; Path=/");
        try w.writeAll(if (f.has(.cookie_strict)) "; SameSite=Strict" else "; SameSite=Lax");
        try w.writeAll(if (f.has(.cookie_max_age)) "; Max-Age=3600" else "; Max-Age=600");
        if (f.has(.cookie_domain)) try w.writeAll("; Domain=mopm.dev");
        return c.items;
    }
};

fn navigation(headers: []const s.Header) bool {
    for (s.navigation) |want| {
        const got = header(headers, want.name) orelse return false;
        if (!std.mem.eql(u8, got, want.value)) return false;
    }
    return true;
}

/// application/x-www-form-urlencoded, as the function's `form_urlencoded` writes a value.
fn formEncode(w: anytype, v: []const u8) !void {
    for (v) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '*') try w.writeByte(b) else try w.print("%{X:0>2}", .{b});
    }
}

fn send(stream: std.net.Stream, r: Resp) !void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.print("HTTP/1.1 {d} X\r\n", .{r.status});
    for (r.headers) |x| try w.print("{s}: {s}\r\n", .{ x[0], x[1] });
    try w.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{r.body.len});
    try stream.writeAll(fbs.getWritten());
    try stream.writeAll(r.body);
}

// ---- running the check -----------------------------------------------------------------------------------------------

const Pauses = struct { n: u32 = 0, ms: u64 = 0 };

fn countPause(ctx: ?*anyopaque, ms: u64) void {
    const p: *Pauses = @ptrCast(@alignCast(ctx.?));
    p.n += 1;
    p.ms = ms;
}

const Rig = struct {
    a: Allocator,
    site: *Fake,
    api: *Fake,
    site_base: []const u8,
    api_base: []const u8,
    pauses: Pauses = .{},

    fn init(a: Allocator, defects: []const Defect) !Rig {
        const set = Defects.initMany(defects);
        const site = try Fake.start(a, .site, set);
        const api = try Fake.start(a, .api, set);
        return .{ .a = a, .site = site, .api = api, .site_base = site.site, .api_base = try api.base(a) };
    }

    fn deinit(r: *Rig) void {
        r.site.deinit();
        r.api.deinit();
    }

    /// The check's output and its exit status.
    fn check(r: *Rig) !struct { code: u8, out: []const u8 } {
        var out = std.ArrayList(u8).init(r.a);
        const w = out.writer();
        const code = try s.cli(r.a, &.{ "--site", r.site_base, "--api", r.api_base }, w.any(), .{ .ctx = &r.pauses, .pause = &countPause });
        for (secrets) |x| if (h.contains(out.items, x)) {
            std.debug.print("the output holds {s}:\n{s}\n", .{ x, out.items });
            return error.SecretPrinted;
        };
        return .{ .code = code, .out = out.items };
    }

    /// The whole output of a run in which the checks of `fails` fail with exactly those lines and the others pass.
    /// `{site}` and `{api}` in a line are the servers' origins.
    fn expected(r: *Rig, fails: []const Fail) ![]const u8 {
        var out = std.ArrayList(u8).init(r.a);
        var failed: u32 = 0;
        for (s.check_names, ok_lines, 0..) |name, ok, i| {
            var any = false;
            for (fails) |f| if (f.check == i) {
                any = true;
                const line = try std.mem.replaceOwned(u8, r.a, try std.mem.replaceOwned(u8, r.a, f.line, "{site}", r.site_base), "{api}", r.api_base);
                try out.writer().print("FAIL: {s}: {s}\n", .{ name, line });
            };
            if (any) failed += 1 else try out.writer().print("{s}\n", .{ok});
        }
        if (failed == 0) {
            try out.writer().print("sign-in checks: all 5 passed (site {s}, API {s})\n", .{ r.site_base, r.api_base });
        } else {
            try out.writer().print("sign-in checks: {d} of 5 failed (site {s}, API {s})\n", .{ failed, r.site_base, r.api_base });
        }
        return out.items;
    }
};

const ok_lines = [_][]const u8{
    "ok: session, signed out: HTTP 401, request id req-session",
    "ok: sandbox, signed out: HTTP 401, request id req-sandbox",
    "ok: start, through the site: HTTP 302, request id req-start",
    "ok: start, without Sec-Fetch headers: HTTP 400, request id req-start-refused",
    "ok: start, straight at the API host: HTTP 401, request id req-api-start",
};

const Fail = struct { check: usize, line: []const u8 };

fn expectOutput(want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("--- expected\n{s}--- got\n{s}---\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

fn newArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

test "a correct site and API host pass all five checks, with five requests that carry no cookie and reach no one else" {
    var ar = newArena();
    defer ar.deinit();
    var r = try Rig.init(ar.allocator(), &.{});
    defer r.deinit();
    const got = try r.check();
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try expectOutput(try r.expected(&.{}), got.out);
    try std.testing.expectEqual(@as(u32, 0), r.pauses.n);

    const site = r.site.requests();
    const api = r.api.requests();
    try std.testing.expectEqual(@as(usize, 4), site.len);
    try std.testing.expectEqual(@as(usize, 1), api.len);
    const want = [_]struct { m: []const u8, t: []const u8 }{
        .{ .m = "GET", .t = s.session_path },
        .{ .m = "POST", .t = s.sandbox_path },
        .{ .m = "GET", .t = s.start_path },
        .{ .m = "GET", .t = s.start_path },
    };
    for (want, site) |w, seen| {
        try std.testing.expectEqualStrings(w.m, seen.method);
        try std.testing.expectEqualStrings(w.t, seen.target);
    }
    try std.testing.expectEqualStrings("GET", api[0].method);
    try std.testing.expectEqualStrings(s.start_path, api[0].target);
    for ([_][]const Seen{ site, api }) |list| for (list) |seen| {
        try std.testing.expect(header(seen.headers, "cookie") == null);
        try std.testing.expect(header(seen.headers, "authorization") == null);
    };
    // The sandbox request: the site's Origin, same-origin, and no body.
    try std.testing.expectEqualStrings(r.site_base, header(site[1].headers, "origin").?);
    try std.testing.expectEqualStrings("same-origin", header(site[1].headers, "sec-fetch-site").?);
    try std.testing.expectEqualStrings("0", header(site[1].headers, "content-length").?);
    // The navigations carry the three headers; the refused start carries none of them.
    try std.testing.expect(navigation(site[2].headers));
    try std.testing.expect(navigation(api[0].headers));
    for ([_][]const u8{ "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-site" }) |n| try std.testing.expect(header(site[3].headers, n) == null);
    try std.testing.expect(header(site[0].headers, "origin") == null);
}

const Case = struct { defect: Defect, fails: []const Fail };

const not_envelope_html_session = "the body is not the API's error envelope (content-type 'text/html'), session_required expected";
const no_request_id = "no x-mopm-request-id header (the answer did not come from the function)";
const redacted_authorize = "?client_id&redirect_uri&scope&state&code_challenge&code_challenge_method&prompt";

const cases = [_]Case{
    .{ .defect = .session_200, .fails = &.{
        .{ .check = 0, .line = "answered HTTP 200, 401 expected (it gave a session to a request that carries no cookie)" },
        .{ .check = 0, .line = "the body is not the API's error envelope (content-type 'application/json'), session_required expected" },
    } },
    .{ .defect = .session_404_page, .fails = &.{
        .{ .check = 0, .line = "answered HTTP 404, 401 expected (the request did not reach the function: the site's /api/* behaviour or the API route is missing): <!doctype html><title>Not found</title>" },
        .{ .check = 0, .line = not_envelope_html_session },
        .{ .check = 0, .line = no_request_id },
        .{ .check = 0, .line = "no Cache-Control: no-store" },
    } },
    .{ .defect = .session_cacheable, .fails = &.{.{ .check = 0, .line = "no Cache-Control: no-store" }} },
    .{ .defect = .session_no_request_id, .fails = &.{.{ .check = 0, .line = no_request_id }} },
    .{ .defect = .session_wrong_code, .fails = &.{.{ .check = 0, .line = "error.code is 'csrf_failed', session_required expected" }} },
    .{ .defect = .session_error_not_object, .fails = &.{.{ .check = 0, .line = "the body is not the API's error envelope (content-type 'application/json'), session_required expected" }} },
    .{ .defect = .sandbox_csrf_first, .fails = &.{
        .{ .check = 1, .line = "answered HTTP 403, 401 expected: {\"error\":{\"code\":\"csrf_failed\",\"message\":\"m\",\"hint\":\"h\"}}" },
        .{ .check = 1, .line = "error.code is 'csrf_failed', session_required expected" },
    } },
    .{ .defect = .sandbox_201, .fails = &.{
        .{ .check = 1, .line = "answered HTTP 201, 401 expected (it accepted a request that carries no session)" },
        .{ .check = 1, .line = "the body is not the API's error envelope (content-type 'application/json'), session_required expected" },
    } },
    .{ .defect = .start_store_failed, .fails = &.{.{ .check = 2, .line = "answered HTTP 303 to {site}/tutorial?error=unavailable, 302 expected (the login transaction was not stored)" }} },
    .{ .defect = .start_error_not_a_code, .fails = &.{.{ .check = 2, .line = "answered HTTP 303 to {site}/tutorial?error, 302 expected" }} },
    .{ .defect = .start_no_request_id, .fails = &.{.{ .check = 2, .line = no_request_id }} },
    .{ .defect = .start_no_location, .fails = &.{.{ .check = 2, .line = "0 Location headers, 1 expected" }} },
    .{ .defect = .start_two_locations, .fails = &.{.{ .check = 2, .line = "2 Location headers, 1 expected" }} },
    .{ .defect = .start_wrong_place, .fails = &.{.{ .check = 2, .line = "Location is https://github.com/login/oauth/authorise" ++ redacted_authorize ++ ", not on https://github.com/login/oauth/authorize" }} },
    .{ .defect = .start_scope, .fails = &.{.{ .check = 2, .line = "the Location's scope is 'user', 'read:user' expected" }} },
    .{ .defect = .start_plain, .fails = &.{.{ .check = 2, .line = "the Location's code_challenge_method is 'plain', 'S256' expected" }} },
    .{ .defect = .start_no_state, .fails = &.{.{ .check = 2, .line = "the Location has no state" }} },
    .{ .defect = .start_empty_state, .fails = &.{.{ .check = 2, .line = "the Location's state is empty" }} },
    .{ .defect = .start_no_challenge, .fails = &.{.{ .check = 2, .line = "the Location has no code_challenge" }} },
    .{ .defect = .start_empty_client_id, .fails = &.{.{ .check = 2, .line = "the Location's client_id is empty" }} },
    .{ .defect = .start_two_client_ids, .fails = &.{.{ .check = 2, .line = "the Location has 2 client_id parameters, 1 expected" }} },
    .{ .defect = .start_redirect_path, .fails = &.{.{ .check = 2, .line = "the Location's redirect_uri is '{site}/api/v2/auth/web/cb', '{site}/api/v2/auth/web/callback' expected" }} },
    .{ .defect = .start_bad_escape, .fails = &.{.{ .check = 2, .line = "the Location's query is not form-encoded: https://github.com/login/oauth/authorize" ++ redacted_authorize ++ "&x" }} },
    .{ .defect = .start_short_escape, .fails = &.{.{ .check = 2, .line = "the Location's query is not form-encoded: https://github.com/login/oauth/authorize" ++ redacted_authorize ++ "&x" }} },
    .{ .defect = .cookie_strict, .fails = &.{.{ .check = 2, .line = "the login cookie's SameSite is 'Strict', Lax expected" }} },
    .{ .defect = .cookie_no_secure, .fails = &.{.{ .check = 2, .line = "the login cookie lacks Secure" }} },
    .{ .defect = .cookie_no_httponly, .fails = &.{.{ .check = 2, .line = "the login cookie lacks HttpOnly" }} },
    .{ .defect = .cookie_path, .fails = &.{.{ .check = 2, .line = "the login cookie's Path is '/api', / expected" }} },
    .{ .defect = .cookie_max_age, .fails = &.{.{ .check = 2, .line = "the login cookie's Max-Age is '3600', 600 expected" }} },
    .{ .defect = .cookie_domain, .fails = &.{.{ .check = 2, .line = "the login cookie names Domain=mopm.dev; a __Host- cookie names none" }} },
    .{ .defect = .cookie_name, .fails = &.{.{ .check = 2, .line = "the cookie set is 'mopm_login', __Host-mopm_login expected" }} },
    .{ .defect = .cookie_empty, .fails = &.{.{ .check = 2, .line = "the login cookie has no value" }} },
    .{ .defect = .cookie_none, .fails = &.{.{ .check = 2, .line = "0 Set-Cookie headers (), 1 expected (__Host-mopm_login)" }} },
    .{ .defect = .cookie_two, .fails = &.{.{ .check = 2, .line = "2 Set-Cookie headers (__Host-mopm_login, __Host-mopm_session), 1 expected (__Host-mopm_login)" }} },
    .{ .defect = .cookie_no_pair, .fails = &.{.{ .check = 2, .line = "the cookie set is '', __Host-mopm_login expected" }} },
    .{ .defect = .refused_start_redirects, .fails = &.{
        .{ .check = 3, .line = "answered HTTP 302, 400 expected (it started a sign-in for a request that is not a top-level navigation)" },
        .{ .check = 3, .line = "the body is not the API's error envelope (content-type ''), invalid_request expected" },
        .{ .check = 3, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" },
    } },
    .{ .defect = .refused_start_sets_cookie, .fails = &.{.{ .check = 3, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" }} },
    .{ .defect = .refused_start_html, .fails = &.{
        .{ .check = 3, .line = "the body is not the API's error envelope (content-type 'text/html'), invalid_request expected" },
        .{ .check = 3, .line = no_request_id },
    } },
    .{ .defect = .api_start_redirects, .fails = &.{
        .{ .check = 4, .line = "answered HTTP 302, 401 expected (it started a sign-in for a request that did not come through the site: the edge check is off)" },
        .{ .check = 4, .line = "the body is not the API's error envelope (content-type ''), session_required expected" },
        .{ .check = 4, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" },
    } },
    .{ .defect = .api_start_sets_cookie, .fails = &.{.{ .check = 4, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" }} },
};

test "each wrong answer fails the one check that owns it, with lines that name it and print no secret" {
    // Every defect has a case.
    try std.testing.expectEqual(@typeInfo(Defect).Enum.fields.len, cases.len);
    for (cases) |cs| {
        var ar = newArena();
        defer ar.deinit();
        var r = try Rig.init(ar.allocator(), &.{cs.defect});
        defer r.deinit();
        const got = try r.check();
        expectOutput(try r.expected(cs.fails), got.out) catch |e| {
            std.debug.print("case {s}\n", .{@tagName(cs.defect)});
            return e;
        };
        try std.testing.expectEqual(@as(u8, 1), got.code);
        try std.testing.expectEqual(@as(u32, 0), r.pauses.n);
    }
}

test "one run with a defect in every check names all five" {
    var ar = newArena();
    defer ar.deinit();
    var r = try Rig.init(ar.allocator(), &.{ .session_cacheable, .sandbox_csrf_first, .cookie_strict, .refused_start_sets_cookie, .api_start_redirects });
    defer r.deinit();
    const got = try r.check();
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try expectOutput(try r.expected(&.{
        .{ .check = 0, .line = "no Cache-Control: no-store" },
        .{ .check = 1, .line = "answered HTTP 403, 401 expected: {\"error\":{\"code\":\"csrf_failed\",\"message\":\"m\",\"hint\":\"h\"}}" },
        .{ .check = 1, .line = "error.code is 'csrf_failed', session_required expected" },
        .{ .check = 2, .line = "the login cookie's SameSite is 'Strict', Lax expected" },
        .{ .check = 3, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" },
        .{ .check = 4, .line = "answered HTTP 302, 401 expected (it started a sign-in for a request that did not come through the site: the edge check is off)" },
        .{ .check = 4, .line = "the body is not the API's error envelope (content-type ''), session_required expected" },
        .{ .check = 4, .line = "sets 1 cookie(s) (__Host-mopm_login); a refusal sets none" },
    }), got.out);
}

test "a dropped connection and a 503 are tried again after a pause, and the run passes" {
    var ar = newArena();
    defer ar.deinit();
    var r = try Rig.init(ar.allocator(), &.{});
    defer r.deinit();
    r.site.drop_first = s.session_path;
    r.site.busy = s.sandbox_path;
    r.site.busy_times = 1;
    const got = try r.check();
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try expectOutput(try r.expected(&.{}), got.out);
    try std.testing.expectEqual(@as(usize, 2), r.site.count(s.session_path));
    try std.testing.expectEqual(@as(usize, 2), r.site.count(s.sandbox_path));
    try std.testing.expectEqual(@as(usize, 2), r.site.count(s.start_path));
    try std.testing.expectEqual(@as(u32, 2), r.pauses.n);
    try std.testing.expectEqual(@as(u64, 5000), r.pauses.ms);
}

test "a transient answer that never clears is judged after five tries" {
    var ar = newArena();
    defer ar.deinit();
    var r = try Rig.init(ar.allocator(), &.{});
    defer r.deinit();
    r.site.busy = s.sandbox_path;
    r.site.busy_times = 1000;
    const got = try r.check();
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try expectOutput(try r.expected(&.{
        .{ .check = 1, .line = "answered HTTP 503, 401 expected: <html>busy</html>" },
        .{ .check = 1, .line = not_envelope_html_session },
        .{ .check = 1, .line = no_request_id },
    }), got.out);
    try std.testing.expectEqual(@as(usize, 5), r.site.count(s.sandbox_path));
    try std.testing.expectEqual(@as(u32, 4), r.pauses.n);
}

test "a host that does not answer fails its checks by name after five tries" {
    var ar = newArena();
    defer ar.deinit();
    var r = try Rig.init(ar.allocator(), &.{});
    defer r.deinit();
    r.api.drop_all = true;
    const got = try r.check();
    try std.testing.expectEqual(@as(u8, 1), got.code);
    // The error's name is the HTTP client's; everything around it is fixed.
    const want = try r.expected(&.{.{ .check = 4, .line = "GET {api}" ++ s.start_path ++ ": no answer after 5 tries (@)" }});
    const at = std.mem.indexOfScalar(u8, want, '@').?;
    const tail = want[at + 1 ..];
    try std.testing.expect(std.mem.startsWith(u8, got.out, want[0..at]) and std.mem.endsWith(u8, got.out, tail));
    const name = got.out[at .. got.out.len - tail.len];
    try std.testing.expect(name.len > 0 and std.mem.indexOfAny(u8, name, " \n()") == null);
    try std.testing.expectEqual(@as(usize, 5), r.api.count(s.start_path));
    try std.testing.expectEqual(@as(u32, 4), r.pauses.n);
}

test "the command line takes both origins, once each, and nothing else" {
    var ar = newArena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = "https://beta.mopm.dev";
    const Bad = struct { args: []const []const u8, why: []const u8 };
    const bad = [_]Bad{
        .{ .args = &.{}, .why = "--site is required" },
        .{ .args = &.{ "--api", o }, .why = "--site is required" },
        .{ .args = &.{ "--site", o }, .why = "--api is required" },
        .{ .args = &.{"--site"}, .why = "a flag without its value" },
        .{ .args = &.{ "--sites", o }, .why = "unknown argument" },
        .{ .args = &.{ "--site", o, "--api", o, "extra" }, .why = "unknown argument" },
        .{ .args = &.{ "--site", o, "--site", o }, .why = "a flag given twice" },
        .{ .args = &.{ "--site", o ++ "/" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--site", o ++ "/tutorial" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--api", "https://" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--api", "ftp://api.beta.mopm.dev" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--api", "beta.mopm.dev" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--api", "https://u@beta.mopm.dev" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
        .{ .args = &.{ "--api", "http://beta.mopm.dev?x" }, .why = "a base URL must be an origin: https://<host>, with no path, query or trailing slash" },
    };
    var pauses = Pauses{};
    for (bad) |b| {
        var out = std.ArrayList(u8).init(a);
        const w = out.writer();
        const code = try s.cli(a, b.args, w.any(), .{ .ctx = &pauses, .pause = &countPause });
        try std.testing.expectEqual(@as(u8, 2), code);
        try expectOutput(try std.fmt.allocPrint(a, "mopm-signin-e2e: {s}\n{s}", .{ b.why, s.usage }), out.items);
    }
}

test "the built program passes against a correct fake, exits 1 against a wrong one and 2 for a wrong command line" {
    var ar = newArena();
    defer ar.deinit();
    const a = ar.allocator();
    const exe = try h.toolPath(a, "SIGNIN_E2E");
    var env = try h.environ(a);
    {
        var r = try Rig.init(a, &.{});
        defer r.deinit();
        const ran = try h.run(a, &.{ exe, "--site", r.site_base, "--api", r.api_base }, &env, .{ .capture = .stdout });
        try std.testing.expectEqual(@as(u8, 0), ran.code);
        try expectOutput(try r.expected(&.{}), ran.text);
    }
    {
        var r = try Rig.init(a, &.{.cookie_strict});
        defer r.deinit();
        const ran = try h.run(a, &.{ exe, "--site", r.site_base, "--api", r.api_base }, &env, .{ .capture = .stdout });
        try std.testing.expectEqual(@as(u8, 1), ran.code);
        try expectOutput(try r.expected(&.{.{ .check = 2, .line = "the login cookie's SameSite is 'Strict', Lax expected" }}), ran.text);
    }
    const ran = try h.run(a, &.{exe}, &env, .{ .capture = .stdout });
    try std.testing.expectEqual(@as(u8, 2), ran.code);
    try expectOutput("mopm-signin-e2e: --site is required\n" ++ s.usage, ran.text);
}
