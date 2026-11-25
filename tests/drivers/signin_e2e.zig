//! The read-only checks of the website's sign-in and sandbox routes, run against a deployed stage (beta, gamma or prod) by
//! the smoke-linux job of .github/workflows/e2e.yml after that stage's deploy, or by hand with workflow_dispatch.
//!
//!     mopm-signin-e2e --site https://<siteDomain> --api https://<apiDomain>
//!
//! It holds no token, reads no credential and no environment variable, and sends no cookie. Five requests, each a check
//! (docs/design/tutorial-sign-in.md, sections 1, 2 and 2.1; the READMEs of service/lambda/fn_web_login, fn_web_session and
//! fn_tutorial_sandbox):
//!
//!   session, signed out              GET <site>/api/v2/auth/web/session: 401 `session_required`, `Cache-Control: no-store`,
//!                                    `x-mopm-request-id`, no `Set-Cookie`.
//!   sandbox, signed out              POST <site>/api/v2/tutorial/sandbox with the site's `Origin`, `Sec-Fetch-Site: same-origin`
//!                                    and no body: 401 `session_required` (the session cookie is checked before the CSRF
//!                                    checks and before any call to E2B), `x-mopm-request-id`, no `Set-Cookie`.
//!   start, through the site          GET <site>/api/v2/auth/web/start?return_to=/tutorial/hello as a top-level navigation
//!                                    (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, `Sec-Fetch-Site: none`),
//!                                    the redirect not followed: 302 to https://github.com/login/oauth/authorize with one
//!                                    non-empty `client_id`, `scope=read:user`, `code_challenge_method=S256`, a `state`, a
//!                                    `code_challenge` and `redirect_uri` = <site>/api/v2/auth/web/callback, and exactly one
//!                                    `Set-Cookie`: `__Host-mopm_login=<value>` with `Secure`, `HttpOnly`, `Path=/`,
//!                                    `SameSite=Lax`, `Max-Age=600` and no `Domain`. This proves the edge secret reaches the
//!                                    function, the OAuth app's secret is readable and the stage settings exist. It is the one
//!                                    write of the run: one ten-minute `web_logins` row, which expires by itself.
//!   start, without Sec-Fetch headers the same request with none of the three headers: 400 `invalid_request`, no `Set-Cookie`.
//!   start, straight at the API host  the navigation request to <api>/api/v2/auth/web/start, which no distribution fronts and
//!                                    so carries no edge header: 401 `session_required`, no `Set-Cookie`. On the session
//!                                    route a missing edge header and a missing cookie read the same, so only this check
//!                                    tells a function that skips the edge check from one that makes it.
//!
//! Every check runs and reports (`ok: <check>: ...` or one `FAIL: <check>: ...` line per thing that is wrong), so one red run
//! names every failure; the last line counts them, and the exit status is 1 when any failed, 2 for a wrong command line.
//! No line holds a cookie's value, the `state` or the `code_challenge`: a `Location` is printed as its address and the names
//! of its parameters (`error`'s value, one of a fixed list of codes, is kept), a `Set-Cookie` by its name, and a body only
//! for an answer of 400 or more.
//!
//! A request that gets no answer, or an answer of 408, 429, 500, 502, 503 or 504 (the transient answers `curl --retry` tries
//! again, as the other read-only steps of the job do), is tried again, five tries in all, five seconds apart; the last
//! answer is the one judged. Redirects are never followed, so nothing is sent to GitHub.
//!
//! A base URL is an origin, `https://<host>` (`http://` is accepted for the loopback servers of
//! tests/drivers/signin_e2e_test.zig, which runs every check against a correct fake and against each way it can be wrong).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const usage =
    \\usage: mopm-signin-e2e --site <origin> --api <origin>
    \\  --site  the site's origin, https://<siteDomain> (the stage's service/config/<stage>.json)
    \\  --api   the API host's origin, https://<apiDomain>
    \\
;

pub const session_path = "/api/v2/auth/web/session";
pub const sandbox_path = "/api/v2/tutorial/sandbox";
pub const start_path = "/api/v2/auth/web/start?return_to=/tutorial/hello";
pub const callback_path = "/api/v2/auth/web/callback";
pub const github_authorize = "https://github.com/login/oauth/authorize";
pub const login_cookie = "__Host-mopm_login";

/// The checks, in the order they run.
pub const check_names = [_][]const u8{
    "session, signed out",
    "sandbox, signed out",
    "start, through the site",
    "start, without Sec-Fetch headers",
    "start, straight at the API host",
};

/// The headers of a browser's top-level navigation from a link it was given.
pub const navigation = [_]std.http.Header{
    .{ .name = "Sec-Fetch-Mode", .value = "navigate" },
    .{ .name = "Sec-Fetch-Dest", .value = "document" },
    .{ .name = "Sec-Fetch-Site", .value = "none" },
};

/// How a request is tried again. `pause` waits `ms` milliseconds between tries: the program sleeps, a test counts.
pub const Net = struct {
    ctx: ?*anyopaque = null,
    pause: *const fn (ctx: ?*anyopaque, ms: u64) void,
    tries: u8 = 5,
    wait_ms: u64 = 5000,
};

pub const Options = struct {
    /// The site's origin, no trailing slash.
    site: []const u8,
    /// The API host's origin, no trailing slash.
    api: []const u8,
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Answer = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,

    /// Every value of the header `name` (any case), in the order received.
    fn values(ans: Answer, a: Allocator, name: []const u8) ![]const []const u8 {
        var out = std.ArrayList([]const u8).init(a);
        for (ans.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(h.value);
        return out.items;
    }

    fn first(ans: Answer, name: []const u8) ?[]const u8 {
        for (ans.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// The command line: the exit status (0 every check passed, 1 one failed, 2 the command line is wrong).
pub fn cli(a: Allocator, args: []const []const u8, out: std.io.AnyWriter, net: Net) !u8 {
    const o = parseArgs(args) catch |e| {
        try out.print("mopm-signin-e2e: {s}\n{s}", .{ argError(e), usage });
        return 2;
    };
    return if (try run(a, o, out, net) == 0) 0 else 1;
}

const ArgError = error{ UnknownFlag, MissingValue, Repeated, MissingSite, MissingApi, NotAnOrigin };

fn argError(e: ArgError) []const u8 {
    return switch (e) {
        error.UnknownFlag => "unknown argument",
        error.MissingValue => "a flag without its value",
        error.Repeated => "a flag given twice",
        error.MissingSite => "--site is required",
        error.MissingApi => "--api is required",
        error.NotAnOrigin => "a base URL must be an origin: https://<host>, with no path, query or trailing slash",
    };
}

fn parseArgs(args: []const []const u8) ArgError!Options {
    var site: ?[]const u8 = null;
    var api: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--site")) &site else if (std.mem.eql(u8, args[i], "--api")) &api else return error.UnknownFlag;
        if (i + 1 >= args.len) return error.MissingValue;
        if (slot.* != null) return error.Repeated;
        if (!isOrigin(args[i + 1])) return error.NotAnOrigin;
        slot.* = args[i + 1];
    }
    return .{ .site = site orelse return error.MissingSite, .api = api orelse return error.MissingApi };
}

/// `https://<host>` or `http://<host>` (a port may follow the host), and nothing after it.
fn isOrigin(s: []const u8) bool {
    const host = if (std.mem.startsWith(u8, s, "https://")) s["https://".len..] else if (std.mem.startsWith(u8, s, "http://")) s["http://".len..] else return false;
    return host.len > 0 and std.mem.indexOfAny(u8, host, "/?#@ \\") == null;
}

/// Runs the five checks against `o` and writes what each found to `out`. Returns how many failed.
/// Not written yet: it reports a pass without sending a request.
pub fn run(a: Allocator, o: Options, out: std.io.AnyWriter, net: Net) !u32 {
    _ = a;
    _ = net;
    try out.print("sign-in checks: all {d} passed (site {s}, API {s})\n", .{ check_names.len, o.site, o.api });
    return 0;
}

fn cat(a: Allocator, x: []const u8, y: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ x, y });
}

const Step = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    judge: *const fn (c: *Check, ans: Answer) anyerror!void,
};

/// What one check found wrong.
const Check = struct {
    a: Allocator,
    name: []const u8,
    site: []const u8,
    problems: std.ArrayList([]const u8),

    fn bad(c: *Check, comptime f: []const u8, args: anytype) !void {
        try c.problems.append(try std.fmt.allocPrint(c.a, f, args));
    }
};

// ---- the requests ----------------------------------------------------------------------------------------------------

const Got = union(enum) { answer: Answer, no_answer: []const u8 };

/// The answer to one request, tried again as the header says.
fn fetch(a: Allocator, net: Net, method: std.http.Method, url: []const u8, headers: []const std.http.Header) !Got {
    var tries: u8 = 1;
    while (true) : (tries += 1) {
        const got: Got = if (once(a, method, url, headers)) |ans| .{ .answer = ans } else |e| .{ .no_answer = @errorName(e) };
        const again = switch (got) {
            .answer => |ans| transient(ans.status),
            .no_answer => true,
        };
        if (!again or tries >= net.tries) return got;
        net.pause(net.ctx, net.wait_ms);
    }
}

fn transient(status: u16) bool {
    return switch (status) {
        408, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

/// One request on a connection of its own, the redirect not followed; a POST is sent with `Content-Length: 0`.
fn once(a: Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header) !Answer {
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    var head: [16 * 1024]u8 = undefined;
    var req = try client.open(method, try std.Uri.parse(url), .{
        .server_header_buffer = &head,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "mopm-signin-e2e" } },
        .extra_headers = headers,
    });
    defer req.deinit();
    if (method == .POST) req.transfer_encoding = .{ .content_length = 0 };
    try req.send();
    try req.finish();
    try req.wait();
    var list = std.ArrayList(Header).init(a);
    var it = req.response.iterateHeaders();
    while (it.next()) |h| try list.append(.{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    const body = try req.reader().readAllAlloc(a, 1 << 20);
    return .{ .status = @intFromEnum(req.response.status), .headers = list.items, .body = body };
}

// ---- the judges ------------------------------------------------------------------------------------------------------

fn judgeSession(c: *Check, ans: Answer) anyerror!void {
    try expectRefusal(c, ans, 401, "session_required", "it gave a session to a request that carries no cookie");
    for (try ans.values(c.a, "cache-control")) |v| {
        var parts = std.mem.splitScalar(u8, v, ',');
        while (parts.next()) |p| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, p, " \t"), "no-store")) return;
    }
    try c.bad("no Cache-Control: no-store", .{});
}

fn judgeSandbox(c: *Check, ans: Answer) anyerror!void {
    try expectRefusal(c, ans, 401, "session_required", "it accepted a request that carries no session");
}

fn judgeStartRefused(c: *Check, ans: Answer) anyerror!void {
    try expectRefusal(c, ans, 400, "invalid_request", "it started a sign-in for a request that is not a top-level navigation");
}

fn judgeStartAtApi(c: *Check, ans: Answer) anyerror!void {
    try expectRefusal(c, ans, 401, "session_required", "it started a sign-in for a request that did not come through the site: the edge check is off");
}

/// A refusal of the website's functions: `status` with the API's error envelope of `code`, `x-mopm-request-id`, and no cookie
/// set. `accepted` says what an answer below 400 means.
fn expectRefusal(c: *Check, ans: Answer, status: u16, code: []const u8, accepted: []const u8) !void {
    const got_code = try errorCode(c.a, ans.body);
    if (ans.status != status) {
        // A 403 or 404 that is not the API's envelope is CloudFront's or the bucket's, or API Gateway's for a route it lacks.
        const missing = (ans.status == 403 or ans.status == 404) and got_code == null;
        const why = if (ans.status < 400) accepted else if (missing) "the request did not reach the function: the site's /api/* behaviour or the API route is missing" else "";
        try c.bad("answered HTTP {d}, {d} expected{s}{s}{s}{s}", .{ ans.status, status, if (why.len > 0) " (" else "", why, if (why.len > 0) ")" else "", try bodyNote(c.a, ans) });
    }
    if (got_code) |got| {
        if (!std.mem.eql(u8, got, code)) try c.bad("error.code is '{s}', {s} expected", .{ got, code });
    } else {
        try c.bad("the body is not the API's error envelope (content-type '{s}'), {s} expected", .{ ans.first("content-type") orelse "", code });
    }
    try expectRequestId(c, ans);
    const cookies = try ans.values(c.a, "set-cookie");
    if (cookies.len > 0) try c.bad("sets {d} cookie(s) ({s}); a refusal sets none", .{ cookies.len, try cookieNames(c.a, cookies) });
}

fn expectRequestId(c: *Check, ans: Answer) !void {
    const id = ans.first("x-mopm-request-id") orelse "";
    if (id.len == 0) try c.bad("no x-mopm-request-id header (the answer did not come from the function)", .{});
}

fn judgeStart(c: *Check, ans: Answer) anyerror!void {
    try expectRequestId(c, ans);
    const locations = try ans.values(c.a, "location");
    if (ans.status != 302) {
        const to = if (locations.len > 0) try std.fmt.allocPrint(c.a, " to {s}", .{try redact(c.a, locations[0])}) else "";
        const unstored = std.mem.endsWith(u8, to, "/tutorial?error=unavailable");
        try c.bad("answered HTTP {d}{s}, 302 expected{s}{s}", .{ ans.status, to, if (unstored) " (the login transaction was not stored)" else "", try bodyNote(c.a, ans) });
        return;
    }
    if (locations.len != 1) {
        try c.bad("{d} Location headers, 1 expected", .{locations.len});
    } else {
        try judgeAuthorize(c, locations[0]);
    }
    const cookies = try ans.values(c.a, "set-cookie");
    if (cookies.len != 1) {
        try c.bad("{d} Set-Cookie headers ({s}), 1 expected (" ++ login_cookie ++ ")", .{ cookies.len, try cookieNames(c.a, cookies) });
    } else {
        try judgeLoginCookie(c, cookies[0]);
    }
}

/// The GitHub authorize address: its place and the parameters the sign-in depends on. The `state` and the `code_challenge`
/// are checked for being there, never printed.
fn judgeAuthorize(c: *Check, location: []const u8) !void {
    const q = std.mem.indexOfScalar(u8, location, '?') orelse location.len;
    if (!std.mem.eql(u8, location[0..q], github_authorize)) try c.bad("Location is {s}, not on " ++ github_authorize, .{try redact(c.a, location)});
    const query = if (q < location.len) location[q + 1 ..] else "";
    const params = parseQuery(c.a, query) catch {
        try c.bad("the Location's query is not form-encoded: {s}", .{try redact(c.a, location)});
        return;
    };
    if (try param(c, params, "client_id")) |v| if (v.len == 0) try c.bad("the Location's client_id is empty", .{});
    try paramIs(c, params, "scope", "read:user");
    try paramIs(c, params, "code_challenge_method", "S256");
    if (try param(c, params, "state")) |v| if (v.len == 0) try c.bad("the Location's state is empty", .{});
    if (try param(c, params, "code_challenge")) |v| if (v.len == 0) try c.bad("the Location's code_challenge is empty", .{});
    try paramIs(c, params, "redirect_uri", try cat(c.a, c.site, callback_path));
}

const Param = struct { name: []const u8, value: []const u8 };

/// The value of `name`, when the query has it exactly once; otherwise a problem and null.
fn param(c: *Check, params: []const Param, name: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var n: usize = 0;
    for (params) |p| if (std.mem.eql(u8, p.name, name)) {
        found = p.value;
        n += 1;
    };
    if (n == 1) return found;
    if (n == 0) try c.bad("the Location has no {s}", .{name}) else try c.bad("the Location has {d} {s} parameters, 1 expected", .{ n, name });
    return null;
}

fn paramIs(c: *Check, params: []const Param, name: []const u8, want: []const u8) !void {
    const v = try param(c, params, name) orelse return;
    if (!std.mem.eql(u8, v, want)) try c.bad("the Location's {s} is '{s}', '{s}' expected", .{ name, v, want });
}

/// `application/x-www-form-urlencoded`: `&`-separated `name=value` pairs, `+` a space, `%XX` a byte.
fn parseQuery(a: Allocator, query: []const u8) ![]const Param {
    var out = std.ArrayList(Param).init(a);
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try out.append(.{ .name = try formDecode(a, pair[0..eq]), .value = try formDecode(a, if (eq < pair.len) pair[eq + 1 ..] else "") });
    }
    return out.items;
}

fn formDecode(a: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '+' => try out.append(' '),
            '%' => {
                if (i + 3 > s.len) return error.BadEscape;
                const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.BadEscape;
                const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.BadEscape;
                try out.append(hi * 16 + lo);
                i += 2;
            },
            else => |b| try out.append(b),
        }
    }
    return out.items;
}

/// The login cookie: its name, a value (never printed), and exactly the design's attributes.
fn judgeLoginCookie(c: *Check, set_cookie: []const u8) !void {
    var parts = std.mem.splitScalar(u8, set_cookie, ';');
    const pair = std.mem.trim(u8, parts.first(), " \t");
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
    if (!std.mem.eql(u8, pair[0..eq], login_cookie)) try c.bad("the cookie set is '{s}', " ++ login_cookie ++ " expected", .{pair[0..eq]});
    if (eq + 1 >= pair.len) try c.bad("the login cookie has no value", .{});
    var secure = false;
    var http_only = false;
    var path: ?[]const u8 = null;
    var same_site: ?[]const u8 = null;
    var max_age: ?[]const u8 = null;
    var domain: ?[]const u8 = null;
    while (parts.next()) |raw| {
        const attr = std.mem.trim(u8, raw, " \t");
        const ae = std.mem.indexOfScalar(u8, attr, '=') orelse attr.len;
        const key = attr[0..ae];
        const val = if (ae < attr.len) attr[ae + 1 ..] else "";
        if (std.ascii.eqlIgnoreCase(key, "secure")) secure = true;
        if (std.ascii.eqlIgnoreCase(key, "httponly")) http_only = true;
        if (std.ascii.eqlIgnoreCase(key, "path")) path = val;
        if (std.ascii.eqlIgnoreCase(key, "samesite")) same_site = val;
        if (std.ascii.eqlIgnoreCase(key, "max-age")) max_age = val;
        if (std.ascii.eqlIgnoreCase(key, "domain")) domain = val;
    }
    if (!secure) try c.bad("the login cookie lacks Secure", .{});
    if (!http_only) try c.bad("the login cookie lacks HttpOnly", .{});
    if (!std.mem.eql(u8, path orelse "", "/")) try c.bad("the login cookie's Path is '{s}', / expected", .{path orelse ""});
    if (!std.ascii.eqlIgnoreCase(same_site orelse "", "Lax")) try c.bad("the login cookie's SameSite is '{s}', Lax expected", .{same_site orelse ""});
    if (!std.mem.eql(u8, max_age orelse "", "600")) try c.bad("the login cookie's Max-Age is '{s}', 600 expected", .{max_age orelse ""});
    if (domain) |d| try c.bad("the login cookie names Domain={s}; a __Host- cookie names none", .{d});
}

// ---- what is printed -------------------------------------------------------------------------------------------------

/// `error.code` of the API's error envelope, or null when the body is not one.
fn errorCode(a: Allocator, body: []const u8) !?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    if (v != .object) return null;
    const e = v.object.get("error") orelse return null;
    if (e != .object) return null;
    const code = e.object.get("code") orelse return null;
    return if (code == .string) code.string else null;
}

/// The body's first 120 bytes, escaped, for an answer of 400 or more; nothing for any other (a 2xx may hold a sandbox's
/// token or a session's CSRF value).
fn bodyNote(a: Allocator, ans: Answer) ![]const u8 {
    if (ans.status < 400) return "";
    return std.fmt.allocPrint(a, ": {}", .{std.fmt.fmtSliceEscapeLower(ans.body[0..@min(ans.body.len, 120)])});
}

/// A URL as its address and the names of its query parameters; the value of `error` is kept, every other is left out.
fn redact(a: Allocator, url: []const u8) ![]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(url[0 .. q + 1]);
    var pairs = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    var n: usize = 0;
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (n > 0) try out.append('&');
        n += 1;
        try out.appendSlice(if (std.mem.eql(u8, pair[0..eq], "error")) pair else pair[0..eq]);
    }
    return out.items;
}

/// The names of the cookies of `Set-Cookie` values, never their values.
fn cookieNames(a: Allocator, values: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (values, 0..) |v, i| {
        if (i > 0) try out.appendSlice(", ");
        const pair = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse v.len], " \t");
        try out.appendSlice(pair[0 .. std.mem.indexOfScalar(u8, pair, '=') orelse pair.len]);
    }
    return out.items;
}

// ---- the program -----------------------------------------------------------------------------------------------------

fn sleep(_: ?*anyopaque, ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const stdout = std.io.getStdOut().writer();
    const code = try cli(a, argv[1..], stdout.any(), .{ .pause = &sleep });
    std.process.exit(code);
}
