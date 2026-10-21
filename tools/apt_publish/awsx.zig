//! Reading what the `aws` command line says: which failure it was, and the ETag of an object.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Failure = enum {
    /// The object is not there (NoSuchKey).
    not_found,
    /// S3 answers AccessDenied for a key that does not exist when the caller may not list the bucket, as the publish role may not.
    denied,
    /// A conditional write lost: the version it named is not the current one (412), or another write to the same key is in flight (409).
    precondition,
    other,
};

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

/// What an `aws` call that exited non-zero was, from its standard error.
pub fn classify(stderr: []const u8) Failure {
    if (has(stderr, "PreconditionFailed") or has(stderr, "ConditionalRequestConflict") or has(stderr, "(412)")) return .precondition;
    if (has(stderr, "NoSuchKey") or has(stderr, "(404)") or has(stderr, "Not Found")) return .not_found;
    if (has(stderr, "AccessDenied") or has(stderr, "(403)") or has(stderr, "Forbidden")) return .denied;
    return .other;
}

/// The `ETag` of the JSON that `aws s3api get-object` or `put-object` prints.
pub fn etagOf(a: Allocator, json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadJson;
    if (parsed.value != .object) return error.BadJson;
    const v = parsed.value.object.get("ETag") orelse return error.NoEtag;
    if (v != .string or v.string.len == 0) return error.NoEtag;
    if (std.mem.indexOfAny(u8, v.string, "\t\r\n ") != null) return error.NoEtag;
    return try a.dupe(u8, v.string);
}

/// The credentials of `aws sts assume-role-with-web-identity --query Credentials`.
pub const Credentials = struct { access_key_id: []const u8, secret_access_key: []const u8, session_token: []const u8 };

pub fn credentialsOf(a: Allocator, json: []const u8) !Credentials {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadJson;
    if (parsed.value != .object) return error.BadJson;
    return .{
        .access_key_id = try field(a, parsed.value, "AccessKeyId"),
        .secret_access_key = try field(a, parsed.value, "SecretAccessKey"),
        .session_token = try field(a, parsed.value, "SessionToken"),
    };
}

/// The string `key` of a JSON object (a one-line value: it goes to a line of $GITHUB_ENV).
pub fn field(a: Allocator, v: std.json.Value, key: []const u8) ![]const u8 {
    if (v != .object) return error.BadJson;
    const f = v.object.get(key) orelse return error.MissingField;
    if (f != .string or f.string.len == 0 or std.mem.indexOfAny(u8, f.string, "\r\n") != null) return error.MissingField;
    return try a.dupe(u8, f.string);
}

/// The `.value` of the answer of the token endpoint of the runner.
pub fn tokenOf(a: Allocator, json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadJson;
    return field(a, parsed.value, "value");
}

const t = std.testing;

test "classify: the lost race first, then the missing object, then the denied one" {
    try t.expectEqual(Failure.precondition, classify("An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold"));
    try t.expectEqual(Failure.precondition, classify("An error occurred (ConditionalRequestConflict) when calling the PutObject operation"));
    try t.expectEqual(Failure.precondition, classify("... (412) ..."));
    try t.expectEqual(Failure.not_found, classify("An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."));
    try t.expectEqual(Failure.not_found, classify("An error occurred (404) when calling the HeadObject operation: Not Found"));
    try t.expectEqual(Failure.denied, classify("An error occurred (AccessDenied) when calling the GetObject operation: Access Denied"));
    try t.expectEqual(Failure.denied, classify("An error occurred (403) when calling"));
    try t.expectEqual(Failure.other, classify("Could not connect to the endpoint URL"));
    try t.expectEqual(Failure.other, classify(""));
}

test "etagOf reads the ETag with its quotes, and refuses an answer without one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("\"abc123\"", try etagOf(a, "{\"AcceptRanges\": \"bytes\", \"ETag\": \"\\\"abc123\\\"\"}"));
    try t.expectError(error.NoEtag, etagOf(a, "{\"ETag\": \"\"}"));
    try t.expectError(error.NoEtag, etagOf(a, "{\"ETag\": 5}"));
    try t.expectError(error.NoEtag, etagOf(a, "{\"ETag\": \"a b\"}"));
    try t.expectError(error.NoEtag, etagOf(a, "{}"));
    try t.expectError(error.BadJson, etagOf(a, "not json"));
    try t.expectError(error.BadJson, etagOf(a, "[1]"));
}

test "credentialsOf and tokenOf want every field, on one line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try credentialsOf(a, "{\"AccessKeyId\":\"AK\",\"SecretAccessKey\":\"SK\",\"SessionToken\":\"ST\",\"Expiration\":\"x\"}");
    try t.expectEqualStrings("AK", c.access_key_id);
    try t.expectEqualStrings("SK", c.secret_access_key);
    try t.expectEqualStrings("ST", c.session_token);
    try t.expectError(error.MissingField, credentialsOf(a, "{\"AccessKeyId\":\"AK\",\"SecretAccessKey\":\"SK\"}"));
    try t.expectError(error.MissingField, credentialsOf(a, "{\"AccessKeyId\":\"A\\nK\",\"SecretAccessKey\":\"SK\",\"SessionToken\":\"ST\"}"));
    try t.expectError(error.BadJson, credentialsOf(a, "nope"));
    try t.expectError(error.BadJson, credentialsOf(a, "3"));
    try t.expectEqualStrings("jwt.x.y", try tokenOf(a, "{\"count\":1,\"value\":\"jwt.x.y\"}"));
    try t.expectError(error.MissingField, tokenOf(a, "{\"value\":\"\"}"));
    try t.expectError(error.BadJson, tokenOf(a, "{"));
}
