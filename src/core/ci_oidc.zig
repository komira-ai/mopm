//! `mopm publish --oidc`: a registry token from the CI job's own identity, with no stored secret.
//!
//! Inside a GitHub Actions job that has `permissions: id-token: write`, the runner sets
//! `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN`. The run:
//!   1. `GET <ACTIONS_ID_TOKEN_REQUEST_URL>&audience=<audience>` with the request token as a bearer token
//!      answers `{"value": "<jwt>"}`, a short-lived identity token for this job. The audience names the registry:
//!      `mopm.dev` for prod and `<stage>.mopm.dev` for any other stage (`beta.mopm.dev` for beta).
//!   2. `POST <api>/auth/oidc/exchange` with `{"jwt", "name", "version"}` (spec/api/openapi.yaml, `exchangeOidcToken`)
//!      answers `{"token", "token_kind": "publish", "expires_at", "name", "version"}`: a token that may publish that
//!      one package version, if the job's repository, workflow and environment match a trusted publisher of the package.
//!      `mopm publish --oidc` (one package) stays on this form: it is the path of a package's registered trusted publisher.
//!   2'. `mopm publish --staged --oidc` posts `{"jwt", "packages": [{"name", "version"}, ...]}` instead (at most 500
//!      entries, no name twice) and gets `{"token", "token_kind": "publish", "expires_at", "packages"}`: ONE token, good
//!      for ten minutes, for exactly those package versions, which the registry lets create and run a group. An identity
//!      token is single-use, so the whole staged set is covered by one exchange of one identity token.
//!
//! The registry token lives in the memory of the process and nowhere else: it is not put in the environment, and no
//! file is written. The identity token and the request token are never printed, and the request token and URL are taken
//! out of the environment of every program mopm starts (src/core/child_env.zig). Each exchange asks GitHub for a fresh
//! identity token, so a registry that accepts an identity token once is never shown one twice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const registry = @import("registry.zig");

/// The variables GitHub Actions sets for a job that may request an identity token.
pub const url_var = "ACTIONS_ID_TOKEN_REQUEST_URL";
pub const token_var = "ACTIONS_ID_TOKEN_REQUEST_TOKEN";

/// Why `--oidc` stops when the job has no identity to ask for.
pub const outside_actions =
    "--oidc works only inside a GitHub Actions job that may request an identity token: " ++ url_var ++ " and " ++ token_var ++
    " are not both set (the job needs 'permissions: id-token: write'). Outside Actions, use 'mopm login' or MOPM_TOKEN.";

/// Where the job asks for its identity token.
pub const Actions = struct { url: []const u8, token: []const u8 };

/// The result of a step: the value, or the sentence that says why not (never a secret).
pub const Result = union(enum) { ok: []const u8, bad: []const u8 };

/// The identity source named by `url` and `token`, or null when either is missing or blank.
pub fn actionsFrom(url: ?[]const u8, token: ?[]const u8) ?Actions {
    const u = std.mem.trim(u8, url orelse return null, " \t\r\n");
    const t = std.mem.trim(u8, token orelse return null, " \t\r\n");
    if (u.len == 0 or t.len == 0) return null;
    return .{ .url = u, .token = t };
}

/// The identity source of this process's environment, or null outside a job that may request a token.
pub fn actionsFromEnv(arena: Allocator) ?Actions {
    const url = std.process.getEnvVarOwned(arena, url_var) catch null;
    const token = std.process.getEnvVarOwned(arena, token_var) catch null;
    return actionsFrom(url, token);
}

/// The audience of a registry's stage: `mopm.dev` for prod, `<stage>.mopm.dev` for the others.
pub fn audienceFor(arena: Allocator, stage: []const u8) Allocator.Error!Result {
    if (std.mem.eql(u8, stage, "prod")) return .{ .ok = "mopm.dev" };
    var valid = stage.len > 0 and stage.len <= 32;
    for (stage) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) valid = false;
    }
    if (!valid) return .{ .bad = "the registry names a stage that has no identity-token audience" };
    return .{ .ok = try std.fmt.allocPrint(arena, "{s}.mopm.dev", .{stage}) };
}

/// `url` with `audience` added to its query, percent-encoded.
pub fn tokenUrl(arena: Allocator, url: []const u8, audience: []const u8) Allocator.Error![]const u8 {
    var b = std.ArrayList(u8).init(arena);
    const w = b.writer();
    try w.writeAll(url);
    try w.writeByte(if (std.mem.indexOfScalar(u8, url, '?') == null) '?' else '&');
    try w.writeAll("audience=");
    for (audience) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
    return b.items;
}

/// Asks GitHub for an identity token whose audience is `audience`.
pub fn identityToken(arena: Allocator, io: anytype, policy: http.Policy, job: Actions, audience: []const u8) anyerror!Result {
    if (!registry.allowedUrl(job.url)) return .{ .bad = url_var ++ " is not an https URL; the identity token is not requested" };
    const url = try tokenUrl(arena, job.url, audience);
    const answer = http.retrying(arena, io, .GET, url, .{
        .token = job.token,
        .extra_headers = &.{.{ .name = "accept", .value = "application/json; api-version=2.0" }},
    }, policy) catch |e| {
        return .{ .bad = try std.fmt.allocPrint(arena, "the identity token request failed: {s}", .{@errorName(e)}) };
    };
    if (!answer.ok()) {
        return .{ .bad = try std.fmt.allocPrint(arena, "GitHub refused the identity token request (HTTP {d}); does the job have 'permissions: id-token: write'?", .{answer.status}) };
    }
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, answer.body, .{}) catch
        return .{ .bad = "GitHub's answer to the identity token request is not JSON" };
    const jwt = switch (v) {
        .object => |o| switch (o.get("value") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        },
        else => "",
    };
    if (jwt.len == 0) return .{ .bad = "GitHub's answer to the identity token request has no token" };
    return .{ .ok = jwt };
}

/// One package version a token is minted for.
pub const Package = struct { name: []const u8, version: []const u8 };

/// The most packages one exchange may name (the service refuses more). A group is one unit under one token, so a set
/// above this is refused whole, before any request, and never split: a split would be several groups.
pub const max_packages: usize = 500;

/// Trades the identity token `jwt` for a registry token that may publish `name` `version` (the single-package form).
pub fn exchange(arena: Allocator, io: anytype, policy: http.Policy, api_url: []const u8, jwt: []const u8, name: []const u8, version: []const u8) anyerror!Result {
    var body = std.ArrayList(u8).init(arena);
    const w = body.writer();
    try w.writeAll("{\"jwt\":");
    try std.json.encodeJsonString(jwt, .{}, w);
    try w.writeAll(",\"name\":");
    try std.json.encodeJsonString(name, .{}, w);
    try w.writeAll(",\"version\":");
    try std.json.encodeJsonString(version, .{}, w);
    try w.writeByte('}');
    return post(arena, io, policy, api_url, body.items, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, version }));
}

/// Trades the identity token `jwt` for one registry token that may publish exactly `packages` at those versions (the
/// `packages` form: `{"jwt", "packages": [{"name", "version"}, ...]}`).
pub fn exchangePackages(arena: Allocator, io: anytype, policy: http.Policy, api_url: []const u8, jwt: []const u8, packages: []const Package) anyerror!Result {
    var body = std.ArrayList(u8).init(arena);
    const w = body.writer();
    try w.writeAll("{\"jwt\":");
    try std.json.encodeJsonString(jwt, .{}, w);
    try w.writeAll(",\"packages\":[");
    for (packages, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try std.json.encodeJsonString(p.name, .{}, w);
        try w.writeAll(",\"version\":");
        try std.json.encodeJsonString(p.version, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return post(arena, io, policy, api_url, body.items, try std.fmt.allocPrint(arena, "the {d} packages of the set", .{packages.len}));
}

/// Sends an exchange `body` and reads the token out of the answer. `subject` names what the token is for, in a refusal.
fn post(arena: Allocator, io: anytype, policy: http.Policy, api_url: []const u8, body: []const u8, subject: []const u8) anyerror!Result {
    const url = try std.fmt.allocPrint(arena, "{s}/auth/oidc/exchange", .{api_url});
    // A POST is sent once: a rerun of the command is its retry.
    const answer = http.retrying(arena, io, .POST, url, .{ .body = body }, policy) catch |e| {
        return .{ .bad = try std.fmt.allocPrint(arena, "POST /auth/oidc/exchange: {s}", .{@errorName(e)}) };
    };
    if (!answer.ok()) {
        return .{ .bad = try std.fmt.allocPrint(arena, "the registry refused the identity token for {s}: {s}", .{ subject, std.mem.trim(u8, try http.describe(arena, answer), "\n") }) };
    }
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, answer.body, .{}) catch
        return .{ .bad = "the registry's answer to the exchange is not JSON" };
    const obj = switch (v) {
        .object => |o| o,
        else => return .{ .bad = "the registry's answer to the exchange is not a JSON object" },
    };
    const token = switch (obj.get("token") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    if (token.len == 0) return .{ .bad = "the registry's answer to the exchange has no token" };
    if (obj.get("token_kind")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "publish")) return .{ .bad = "the registry's exchange answered a token that is not a publish token" };
    }
    return .{ .ok = token };
}

/// The registry token for `name` `version`: an identity token for the registry's audience, exchanged. `stage` is the
/// registry's own name for itself (`beta`), which names the audience.
pub fn obtain(arena: Allocator, io: anytype, policy: http.Policy, job: Actions, api_url: []const u8, stage: []const u8, name: []const u8, version: []const u8) anyerror!Result {
    const audience = switch (try audienceFor(arena, stage)) {
        .ok => |a| a,
        .bad => |why| return .{ .bad = why },
    };
    const jwt = switch (try identityToken(arena, io, policy, job, audience)) {
        .ok => |t| t,
        .bad => |why| return .{ .bad = why },
    };
    return exchange(arena, io, policy, api_url, jwt, name, version);
}

/// The one registry token for a set of package versions: one identity token for the registry's audience, one exchange
/// of the `packages` form. The set is checked first, so that a set the service would refuse asks GitHub for nothing
/// (an identity token is single-use and a request for one is a request the job should not waste).
pub fn obtainPackages(arena: Allocator, io: anytype, policy: http.Policy, job: Actions, api_url: []const u8, stage: []const u8, packages: []const Package) anyerror!Result {
    if (packages.len == 0) return .{ .bad = "--oidc: the set names no package; nothing was sent" };
    if (packages.len > max_packages) {
        return .{ .bad = try std.fmt.allocPrint(arena, "--oidc: one identity token covers at most {d} packages and this set uploads {d}; a group is published as one unit, so it cannot be split; nothing was sent", .{ max_packages, packages.len }) };
    }
    for (packages, 0..) |p, i| {
        for (packages[0..i]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) return .{ .bad = try std.fmt.allocPrint(arena, "--oidc: the set names {s} twice, and an identity token covers one version of a package; nothing was sent", .{p.name}) };
        }
    }
    const audience = switch (try audienceFor(arena, stage)) {
        .ok => |a| a,
        .bad => |why| return .{ .bad = why },
    };
    const jwt = switch (try identityToken(arena, io, policy, job, audience)) {
        .ok => |t| t,
        .bad => |why| return .{ .bad = why },
    };
    return exchangePackages(arena, io, policy, api_url, jwt, packages);
}

// ---------------------------------------------------------------------- tests

/// An `io` for `http.retrying` that answers by the URL it is asked for, and keeps what it was sent.
const Scripted = struct {
    identity: anyerror!http.Answer,
    exchange: anyerror!http.Answer,
    identity_calls: usize = 0,
    exchange_calls: usize = 0,
    identity_url: []const u8 = "",
    identity_bearer: []const u8 = "",
    identity_accept: []const u8 = "",
    exchange_body: []const u8 = "",
    exchange_bearer: ?[]const u8 = null,

    pub fn once(s: *Scripted, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        if (std.mem.indexOf(u8, url, "/auth/oidc/exchange") != null) {
            try std.testing.expectEqual(std.http.Method.POST, method);
            s.exchange_calls += 1;
            s.exchange_body = try arena.dupe(u8, options.body orelse "");
            s.exchange_bearer = options.token;
            return s.exchange;
        }
        try std.testing.expectEqual(std.http.Method.GET, method);
        s.identity_calls += 1;
        s.identity_url = try arena.dupe(u8, url);
        s.identity_bearer = try arena.dupe(u8, options.token orelse "");
        s.identity_accept = if (options.extra_headers.len == 1) options.extra_headers[0].value else "";
        return s.identity;
    }

    pub fn pause(_: *Scripted, _: u64) void {}
};

fn reply(status: u16, body: []const u8) http.Answer {
    return .{ .status = status, .body = body };
}

const secret_request_token = "request-token-secret";
const secret_jwt = "header.payload.signature";
const actions = Actions{ .url = "https://pipelines.example/idtoken?api-version=2.0", .token = secret_request_token };
const good_identity = "{\"value\":\"" ++ secret_jwt ++ "\"}";
const good_exchange = "{\"token\":\"mopm_registry_secret\",\"token_kind\":\"publish\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"name\":\"left_pad\",\"version\":\"1.2.3\"}";

fn expectNoSecret(text: []const u8) !void {
    for ([_][]const u8{ secret_request_token, secret_jwt, "mopm_registry_secret" }) |s| {
        try std.testing.expect(std.mem.indexOf(u8, text, s) == null);
    }
}

test "the audience of a stage: mopm.dev for prod, <stage>.mopm.dev for the others, and none for a stage that is not a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("mopm.dev", (try audienceFor(a, "prod")).ok);
    try std.testing.expectEqualStrings("beta.mopm.dev", (try audienceFor(a, "beta")).ok);
    try std.testing.expectEqualStrings("gamma.mopm.dev", (try audienceFor(a, "gamma")).ok);
    for ([_][]const u8{ "", "Beta", "be ta", "beta.evil.example/", "a&audience=mopm.dev", "x" ** 33 }) |bad| {
        try std.testing.expect((try audienceFor(a, bad)) == .bad);
    }
}

test "the identity source needs both variables, not blank" {
    try std.testing.expect(actionsFrom(null, null) == null);
    try std.testing.expect(actionsFrom("https://x/", null) == null);
    try std.testing.expect(actionsFrom(null, "t") == null);
    try std.testing.expect(actionsFrom("", "t") == null);
    try std.testing.expect(actionsFrom("https://x/", " \n") == null);
    const got = actionsFrom(" https://x/ \n", "t\n").?;
    try std.testing.expectEqualStrings("https://x/", got.url);
    try std.testing.expectEqualStrings("t", got.token);
}

test "the identity source of the environment is the one its two variables name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Whatever job runs the test (inside Actions or not), the answer is what the two variables say.
    const want = actionsFrom(std.process.getEnvVarOwned(a, url_var) catch null, std.process.getEnvVarOwned(a, token_var) catch null);
    const got = actionsFromEnv(a);
    try std.testing.expectEqual(want == null, got == null);
    if (want) |w| {
        try std.testing.expectEqualStrings(w.url, got.?.url);
        try std.testing.expectEqualStrings(w.token, got.?.token);
    }
}

test "the audience joins the query that GitHub's URL already has, or starts one, percent-encoded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("https://h/t?api-version=2.0&audience=beta.mopm.dev", try tokenUrl(a, "https://h/t?api-version=2.0", "beta.mopm.dev"));
    try std.testing.expectEqualStrings("https://h/t?audience=beta.mopm.dev", try tokenUrl(a, "https://h/t", "beta.mopm.dev"));
    try std.testing.expectEqualStrings("https://h/t?audience=a%26b%3Dc%20d%2Fe", try tokenUrl(a, "https://h/t", "a&b=c d/e"));
}

test "obtain asks GitHub for the registry's audience, then exchanges that token for this package version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_exchange) };
    const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expectEqualStrings("mopm_registry_secret", got.ok);
    try std.testing.expectEqualStrings("https://pipelines.example/idtoken?api-version=2.0&audience=beta.mopm.dev", io.identity_url);
    try std.testing.expectEqualStrings(secret_request_token, io.identity_bearer);
    try std.testing.expectEqualStrings("application/json; api-version=2.0", io.identity_accept);
    try std.testing.expectEqualStrings("{\"jwt\":\"" ++ secret_jwt ++ "\",\"name\":\"left_pad\",\"version\":\"1.2.3\"}", io.exchange_body);
    // The exchange is the one request that carries no bearer token: the identity token is its credential.
    try std.testing.expect(io.exchange_bearer == null);
    try std.testing.expectEqual(@as(usize, 1), io.identity_calls);
    try std.testing.expectEqual(@as(usize, 1), io.exchange_calls);
}

test "the prod audience is mopm.dev" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_exchange) };
    _ = try obtain(a, &io, .{}, actions, "https://api.mopm.dev/api/v1", "prod", "left_pad", "1.2.3");
    try std.testing.expectEqualStrings("https://pipelines.example/idtoken?api-version=2.0&audience=mopm.dev", io.identity_url);
}

test "a refused identity request stops before the exchange and says nothing secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(403, "{\"message\":\"no\"}"), .exchange = reply(200, good_exchange) };
    const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expect(std.mem.indexOf(u8, got.bad, "HTTP 403") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.bad, "id-token: write") != null);
    try std.testing.expectEqual(@as(usize, 0), io.exchange_calls);
    try expectNoSecret(got.bad);
}

test "an identity answer that is not a token is refused, before the exchange" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bodies = [_][]const u8{ "not json", "[]", "{}", "{\"value\":\"\"}", "{\"value\":7}" };
    for (bodies) |body| {
        var io = Scripted{ .identity = reply(200, body), .exchange = reply(200, good_exchange) };
        const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
        try std.testing.expect(got == .bad);
        try std.testing.expectEqual(@as(usize, 0), io.exchange_calls);
    }
}

test "a connection that fails is reported by name, for either request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = error.ConnectionRefused, .exchange = reply(200, good_exchange) };
    const first = try obtain(a, &io, .{ .retries = 0 }, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expect(std.mem.indexOf(u8, first.bad, "ConnectionRefused") != null);
    io = Scripted{ .identity = reply(200, good_identity), .exchange = error.ConnectionRefused };
    const second = try obtain(a, &io, .{ .retries = 0 }, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expect(std.mem.indexOf(u8, second.bad, "ConnectionRefused") != null);
    try expectNoSecret(second.bad);
}

test "an identity URL that is not https is never sent the request token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_exchange) };
    const plain = Actions{ .url = "http://pipelines.example/idtoken", .token = secret_request_token };
    const got = try obtain(a, &io, .{}, plain, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expect(got == .bad);
    try std.testing.expectEqual(@as(usize, 0), io.identity_calls);
    try expectNoSecret(got.bad);
    // Loopback http is allowed, as it is for a registry: a local stand-in for GitHub.
    const local = Actions{ .url = "http://127.0.0.1:9/idtoken", .token = secret_request_token };
    const ok = try obtain(a, &io, .{}, local, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
    try std.testing.expect(ok == .ok);
}

test "a refused exchange carries the registry's message and hint, and no secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const refusals = [_]struct { status: u16, body: []const u8, text: []const u8 }{
        .{ .status = 403, .body = "{\"error\":{\"code\":\"oidc_not_trusted\",\"message\":\"No trusted publisher of 'left_pad' matches this CI identity.\",\"hint\":\"Register the repository.\"}}", .text = "No trusted publisher of 'left_pad' matches this CI identity." },
        .{ .status = 401, .body = "{\"error\":{\"code\":\"oidc_token_invalid\",\"message\":\"The CI identity token was rejected: wrong audience.\",\"hint\":\"Check the audience.\"}}", .text = "wrong audience" },
        .{ .status = 502, .body = "<html>bad gateway</html>", .text = "HTTP 502" },
    };
    for (refusals) |r| {
        var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(r.status, r.body) };
        const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
        try std.testing.expect(std.mem.indexOf(u8, got.bad, "refused the identity token for left_pad 1.2.3") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.bad, r.text) != null);
        try expectNoSecret(got.bad);
        // A 502 is not retried for a POST: the exchange is sent once.
        try std.testing.expectEqual(@as(usize, 1), io.exchange_calls);
    }
}

test "an exchange answer without a publish token is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bodies = [_][]const u8{ "not json", "[]", "{}", "{\"token\":\"\"}", "{\"token\":\"t\",\"token_kind\":\"session\"}", "{\"token\":\"t\",\"token_kind\":3}" };
    for (bodies) |body| {
        var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, body) };
        const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", "left_pad", "1.2.3");
        try std.testing.expect(got == .bad);
    }
}

test "a stage that cannot name an audience asks GitHub for nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_exchange) };
    const got = try obtain(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "Be Ta", "left_pad", "1.2.3");
    try std.testing.expect(got == .bad);
    try std.testing.expectEqual(@as(usize, 0), io.identity_calls);
}

const three = [_]Package{ .{ .name = "a", .version = "1.0.0" }, .{ .name = "b", .version = "2.1.0" }, .{ .name = "c", .version = "0.0.3" } };
const good_packages_exchange = "{\"token\":\"mopm_registry_secret\",\"token_kind\":\"publish\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"packages\":[]}";

test "a set is covered by one identity request and one exchange that lists every member at its version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_packages_exchange) };
    const got = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", &three);
    try std.testing.expectEqualStrings("mopm_registry_secret", got.ok);
    try std.testing.expectEqual(@as(usize, 1), io.identity_calls);
    try std.testing.expectEqual(@as(usize, 1), io.exchange_calls);
    try std.testing.expectEqualStrings("https://pipelines.example/idtoken?api-version=2.0&audience=beta.mopm.dev", io.identity_url);
    try std.testing.expectEqualStrings(
        "{\"jwt\":\"" ++ secret_jwt ++ "\",\"packages\":[{\"name\":\"a\",\"version\":\"1.0.0\"},{\"name\":\"b\",\"version\":\"2.1.0\"},{\"name\":\"c\",\"version\":\"0.0.3\"}]}",
        io.exchange_body,
    );
    try std.testing.expect(io.exchange_bearer == null);
}

test "a refused set exchange carries the registry's message and no secret, and is sent once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const refusals = [_]struct { status: u16, body: []const u8, text: []const u8 }{
        .{ .status = 403, .body = "{\"error\":{\"code\":\"not_owner\",\"message\":\"You are not an owner of 'b'.\",\"hint\":\"Ask an owner.\"}}", .text = "You are not an owner of 'b'." },
        .{ .status = 403, .body = "{\"error\":{\"code\":\"oidc_not_trusted\",\"message\":\"No trusted publisher of 'a' matches this CI identity.\",\"hint\":\"Register it.\"}}", .text = "No trusted publisher of 'a' matches this CI identity." },
    };
    for (refusals) |r| {
        var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(r.status, r.body) };
        const got = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", &three);
        try std.testing.expect(std.mem.indexOf(u8, got.bad, "refused the identity token for the 3 packages of the set") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.bad, r.text) != null);
        try expectNoSecret(got.bad);
        try std.testing.expectEqual(@as(usize, 1), io.exchange_calls);
    }
}

test "a set the service would refuse asks GitHub and the registry for nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_packages_exchange) };

    // Exactly the limit is covered; one more is refused whole, with the numbers in the message.
    var many = std.ArrayList(Package).init(a);
    for (0..max_packages) |i| try many.append(.{ .name = try std.fmt.allocPrint(a, "pkg{d}", .{i}), .version = "1.0.0" });
    const full = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", many.items);
    try std.testing.expectEqualStrings("mopm_registry_secret", full.ok);
    try std.testing.expectEqual(@as(usize, 1), io.exchange_calls);

    io = Scripted{ .identity = reply(200, good_identity), .exchange = reply(200, good_packages_exchange) };
    try many.append(.{ .name = "one-too-many", .version = "1.0.0" });
    const over = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", many.items);
    try std.testing.expect(std.mem.indexOf(u8, over.bad, "at most 500 packages") != null);
    try std.testing.expect(std.mem.indexOf(u8, over.bad, "uploads 501") != null);
    try std.testing.expect(std.mem.indexOf(u8, over.bad, "cannot be split") != null);

    const twice = [_]Package{ .{ .name = "a", .version = "1.0.0" }, .{ .name = "a", .version = "1.0.1" } };
    const dup = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", &twice);
    try std.testing.expect(std.mem.indexOf(u8, dup.bad, "names a twice") != null);
    const none = try obtainPackages(a, &io, .{}, actions, "https://api.beta.mopm.dev/api/v1", "beta", &.{});
    try std.testing.expect(none == .bad);
    try std.testing.expectEqual(@as(usize, 0), io.identity_calls);
    try std.testing.expectEqual(@as(usize, 0), io.exchange_calls);
}
