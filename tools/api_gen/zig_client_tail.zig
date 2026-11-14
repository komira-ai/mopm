//! The static tail of the generated client (src/core/registry_v2.zig): helpers every operation uses, and the tests of the
//! generated enums, unions and operations, which read the file's own declarations. zig_client.zig appends it as it stands.

pub const text =
    \\/// `api_root` (the registry's `/api/v2` URL) followed by the operation's target.
    \\pub fn url(comptime Op: type, arena: Allocator, api_root: []const u8, p: Op.Params) ![]const u8 {
    \\    return std.mem.concat(arena, u8, &.{ api_root, try Op.target(arena, p) });
    \\}
    \\
    \\/// The answer's JSON as the operation's response; fields this client does not know are ignored.
    \\pub fn decode(comptime Op: type, arena: Allocator, text: []const u8) !Op.Response {
    \\    if (Op.Response == void) {
    \\        return {};
    \\    } else {
    \\        return std.json.parseFromSliceLeaky(Op.Response, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    \\    }
    \\}
    \\
    \\/// The registry's error body, or null when `text` is not one.
    \\pub fn decodeError(arena: Allocator, text: []const u8) ?Error {
    \\    return std.json.parseFromSliceLeaky(Error, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    \\}
    \\
    \\/// Whether `status` is one of the operation's success statuses.
    \\pub fn isSuccess(comptime Op: type, status: u16) bool {
    \\    for (Op.success) |s| if (s == status) return true;
    \\    return false;
    \\}
    \\
    \\/// What a call came to: the operation's response, or the answer of a refusal (not 2xx) for the caller to report.
    \\pub fn Result(comptime Op: type) type {
    \\    return union(enum) { ok: Op.Response, refused: http.Answer };
    \\}
    \\
    \\/// Sends the operation once: its method, `api_root` and its target, its body as JSON, `token` as the bearer token.
    \\/// `io` is anything with `once(arena, method, url, http.Options) !http.Answer` (src/cli/group_io.zig `Net`, http.Real).
    \\pub fn sendOnce(comptime Op: type, arena: Allocator, io: anytype, api_root: []const u8, token: ?[]const u8, p: Op.Params) anyerror!http.Answer {
    \\    return io.once(arena, Op.method, try url(Op, arena, api_root, p), .{ .token = token, .body = try Op.body(arena, p) });
    \\}
    \\
    \\/// `sendOnce`, repeated by `policy` as http.retrying repeats an idempotent request (`io` also has `pause(secs)`).
    \\pub fn send(comptime Op: type, arena: Allocator, io: anytype, policy: http.Policy, api_root: []const u8, token: ?[]const u8, p: Op.Params) anyerror!http.Answer {
    \\    return http.retrying(arena, io, Op.method, try url(Op, arena, api_root, p), .{ .token = token, .body = try Op.body(arena, p) }, policy);
    \\}
    \\
    \\/// `send`, and the answer read: a 2xx as the operation's response, anything else as a refusal.
    \\pub fn call(comptime Op: type, arena: Allocator, io: anytype, policy: http.Policy, api_root: []const u8, token: ?[]const u8, p: Op.Params) anyerror!Result(Op) {
    \\    const answer = try send(Op, arena, io, policy, api_root, token, p);
    \\    if (!answer.ok()) return .{ .refused = answer };
    \\    return .{ .ok = try decode(Op, arena, answer.body) };
    \\}
    \\
    \\/// Writes `s` with every byte but `A-Za-z0-9-._~` as `%XX` (upper case hex).
    \\pub fn percentEncode(w: anytype, s: []const u8) !void {
    \\    const hex = "0123456789ABCDEF";
    \\    for (s) |c| {
    \\        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
    \\            try w.writeByte(c);
    \\        } else {
    \\            try w.writeAll(&[_]u8{ '%', hex[c >> 4], hex[c & 15] });
    \\        }
    \\    }
    \\}
    \\
    \\const TailOp = struct {
    \\    const Params = struct { name: []const u8 };
    \\    const Response = struct { count: i64 };
    \\    const success = [_]u16{ 200, 201 };
    \\    const method: std.http.Method = .GET;
    \\    fn target(arena: Allocator, p: Params) Allocator.Error![]const u8 {
    \\        var out = std.ArrayList(u8).init(arena);
    \\        try out.appendSlice("/x/");
    \\        try percentEncode(out.writer(), p.name);
    \\        return out.toOwnedSlice();
    \\    }
    \\    fn body(_: Allocator, _: Params) Allocator.Error!?[]const u8 {
    \\        return null;
    \\    }
    \\};
    \\
    \\/// An operation that sends a body and is not idempotent.
    \\const TailPostOp = struct {
    \\    const Params = TailOp.Params;
    \\    const Response = TailOp.Response;
    \\    const success = TailOp.success;
    \\    const method: std.http.Method = .POST;
    \\    fn target(arena: Allocator, p: Params) Allocator.Error![]const u8 {
    \\        return TailOp.target(arena, p);
    \\    }
    \\    fn body(arena: Allocator, p: Params) Allocator.Error!?[]const u8 {
    \\        return try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{p.name});
    \\    }
    \\};
    \\
    \\const TailVoidOp = struct {
    \\    const Params = TailOp.Params;
    \\    const Response = void;
    \\    const success = [_]u16{204};
    \\    const method: std.http.Method = .DELETE;
    \\    fn target(arena: Allocator, p: Params) Allocator.Error![]const u8 {
    \\        return TailOp.target(arena, p);
    \\    }
    \\    fn body(_: Allocator, _: Params) Allocator.Error!?[]const u8 {
    \\        return null;
    \\    }
    \\};
    \\
    \\/// An `io` that answers from a list (the last repeats) and records the last request it was sent and how often it was asked.
    \\const TailIo = struct {
    \\    results: []const anyerror!http.Answer,
    \\    calls: usize = 0,
    \\    pauses: usize = 0,
    \\    method: std.http.Method = .GET,
    \\    url: []const u8 = "",
    \\    token: ?[]const u8 = null,
    \\    body: ?[]const u8 = null,
    \\
    \\    fn once(io: *TailIo, _: Allocator, method: std.http.Method, request_url: []const u8, options: http.Options) anyerror!http.Answer {
    \\        io.method = method;
    \\        io.url = request_url;
    \\        io.token = options.token;
    \\        io.body = options.body;
    \\        const result = io.results[@min(io.calls, io.results.len - 1)];
    \\        io.calls += 1;
    \\        return result;
    \\    }
    \\
    \\    fn pause(io: *TailIo, _: u64) void {
    \\        io.pauses += 1;
    \\    }
    \\};
    \\
    \\fn tailAnswer(status: u16, body: []const u8) http.Answer {
    \\    return .{ .status = status, .body = body };
    \\}
    \\
    \\test "percentEncode keeps unreserved bytes and encodes the rest in upper case" {
    \\    var out = std.ArrayList(u8).init(std.testing.allocator);
    \\    defer out.deinit();
    \\    try percentEncode(out.writer(), "aZ09-._~ /?&=\xc3\xa9");
    \\    try std.testing.expectEqualStrings("aZ09-._~%20%2F%3F%26%3D%C3%A9", out.items);
    \\}
    \\
    \\test "url joins the api root and the target" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const got = try url(TailOp, arena_state.allocator(), "http://h/api/v2", .{ .name = "a b" });
    \\    try std.testing.expectEqualStrings("http://h/api/v2/x/a%20b", got);
    \\}
    \\
    \\test "decode ignores unknown fields and a void response has no body" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const got = try decode(TailOp, arena_state.allocator(), "{\"count\":3,\"extra\":{\"a\":[1]}}");
    \\    try std.testing.expectEqual(@as(i64, 3), got.count);
    \\    try decode(TailVoidOp, arena_state.allocator(), "");
    \\    try std.testing.expectError(error.UnexpectedEndOfInput, decode(TailOp, arena_state.allocator(), "{\"count\":"));
    \\}
    \\
    \\test "isSuccess is true for the operation's success statuses only" {
    \\    try std.testing.expect(isSuccess(TailOp, 200));
    \\    try std.testing.expect(isSuccess(TailOp, 201));
    \\    try std.testing.expect(!isSuccess(TailOp, 204));
    \\    try std.testing.expect(!isSuccess(TailOp, 404));
    \\}
    \\
    \\test "sendOnce sends the method, the joined url, the token and the body once" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const a = arena_state.allocator();
    \\    var io = TailIo{ .results = &.{tailAnswer(201, "{}")} };
    \\    const got = try sendOnce(TailPostOp, a, &io, "http://h/api/v2", "tok", .{ .name = "a b" });
    \\    try std.testing.expectEqual(@as(u16, 201), got.status);
    \\    try std.testing.expectEqual(@as(usize, 1), io.calls);
    \\    try std.testing.expectEqual(std.http.Method.POST, io.method);
    \\    try std.testing.expectEqualStrings("http://h/api/v2/x/a%20b", io.url);
    \\    try std.testing.expectEqualStrings("tok", io.token.?);
    \\    try std.testing.expectEqualStrings("{\"name\":\"a b\"}", io.body.?);
    \\
    \\    var plain = TailIo{ .results = &.{tailAnswer(200, "{}")} };
    \\    _ = try sendOnce(TailOp, a, &plain, "http://h/api/v2", null, .{ .name = "n" });
    \\    try std.testing.expectEqual(std.http.Method.GET, plain.method);
    \\    try std.testing.expect(plain.token == null);
    \\    try std.testing.expect(plain.body == null);
    \\}
    \\
    \\test "sendOnce passes a transport error through without trying again" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    var io = TailIo{ .results = &.{error.ConnectionRefused} };
    \\    try std.testing.expectError(error.ConnectionRefused, sendOnce(TailOp, arena_state.allocator(), &io, "http://h/api/v2", null, .{ .name = "n" }));
    \\    try std.testing.expectEqual(@as(usize, 1), io.calls);
    \\    try std.testing.expectEqual(@as(usize, 0), io.pauses);
    \\}
    \\
    \\test "send repeats a 503 of a GET and does not repeat a POST" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const a = arena_state.allocator();
    \\    var get = TailIo{ .results = &.{ tailAnswer(503, ""), tailAnswer(200, "{\"count\":1}") } };
    \\    const got = try send(TailOp, a, &get, .{}, "http://h/api/v2", "tok", .{ .name = "n" });
    \\    try std.testing.expectEqual(@as(u16, 200), got.status);
    \\    try std.testing.expectEqual(@as(usize, 2), get.calls);
    \\    try std.testing.expectEqual(@as(usize, 1), get.pauses);
    \\    try std.testing.expectEqualStrings("http://h/api/v2/x/n", get.url);
    \\    try std.testing.expectEqualStrings("tok", get.token.?);
    \\
    \\    var post = TailIo{ .results = &.{ tailAnswer(503, ""), tailAnswer(200, "{\"count\":1}") } };
    \\    const refused = try send(TailPostOp, a, &post, .{}, "http://h/api/v2", "tok", .{ .name = "n" });
    \\    try std.testing.expectEqual(@as(u16, 503), refused.status);
    \\    try std.testing.expectEqual(@as(usize, 1), post.calls);
    \\    try std.testing.expectEqual(@as(usize, 0), post.pauses);
    \\    try std.testing.expectEqualStrings("{\"name\":\"n\"}", post.body.?);
    \\}
    \\
    \\test "call reads a 2xx as the response, any other status as a refusal, and a void response as done" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const a = arena_state.allocator();
    \\    var ok_io = TailIo{ .results = &.{tailAnswer(200, "{\"count\":7,\"extra\":true}")} };
    \\    switch (try call(TailOp, a, &ok_io, .{}, "http://h/api/v2", null, .{ .name = "n" })) {
    \\        .ok => |r| try std.testing.expectEqual(@as(i64, 7), r.count),
    \\        .refused => return error.TestUnexpectedResult,
    \\    }
    \\
    \\    var no_io = TailIo{ .results = &.{tailAnswer(404, "{\"error\":{}}")} };
    \\    switch (try call(TailOp, a, &no_io, .{}, "http://h/api/v2", null, .{ .name = "n" })) {
    \\        .ok => return error.TestUnexpectedResult,
    \\        .refused => |r| {
    \\            try std.testing.expectEqual(@as(u16, 404), r.status);
    \\            try std.testing.expectEqualStrings("{\"error\":{}}", r.body);
    \\        },
    \\    }
    \\    try std.testing.expectEqual(@as(usize, 1), no_io.calls);
    \\
    \\    var void_io = TailIo{ .results = &.{tailAnswer(204, "")} };
    \\    switch (try call(TailVoidOp, a, &void_io, .{}, "http://h/api/v2", null, .{ .name = "n" })) {
    \\        .ok => {},
    \\        .refused => return error.TestUnexpectedResult,
    \\    }
    \\    try std.testing.expectEqual(std.http.Method.DELETE, void_io.method);
    \\}
    \\
    \\test "call passes a transport error and an unreadable 2xx body through" {
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    const a = arena_state.allocator();
    \\    var down = TailIo{ .results = &.{error.ConnectionRefused} };
    \\    try std.testing.expectError(error.ConnectionRefused, call(TailOp, a, &down, .{ .retries = 0 }, "http://h/api/v2", null, .{ .name = "n" }));
    \\    try std.testing.expectEqual(@as(usize, 1), down.calls);
    \\
    \\    var bad = TailIo{ .results = &.{tailAnswer(200, "{\"count\":")} };
    \\    try std.testing.expectError(error.UnexpectedEndOfInput, call(TailOp, a, &bad, .{}, "http://h/api/v2", null, .{ .name = "n" }));
    \\}
    \\
    \\/// Helpers of the reflection tests below, which read this file's own declarations.
    \\const TailCheck = struct {
    \\    /// A value of `T`: strings "a b/c", numbers 1, bools true, an enum's first tag, a union's first member, slices empty, and
    \\    /// optionals null, except that with `fill` the optionals of a struct (not of its `body`) are set.
    \\    fn sample(comptime T: type, comptime fill: bool) T {
    \\        switch (@typeInfo(T)) {
    \\            .Bool => return true,
    \\            .Int => return 1,
    \\            .Float => return 1.5,
    \\            .Void => return {},
    \\            .Enum => |e| return @enumFromInt(e.fields[0].value),
    \\            .Optional => |o| return if (fill) sample(o.child, false) else null,
    \\            .Pointer => |p| return if (p.child == u8) "a b/c" else &.{},
    \\            .Struct => |s| {
    \\                var v: T = undefined;
    \\                inline for (s.fields) |f| @field(v, f.name) = sample(f.type, fill and !std.mem.eql(u8, f.name, "body"));
    \\                return v;
    \\            },
    \\            .Union => |u| return @unionInit(T, u.fields[0].name, sample(u.fields[0].type, false)),
    \\            else => @compileError("no sample for " ++ @typeName(T)),
    \\        }
    \\    }
    \\
    \\    fn isText(comptime T: type) bool {
    \\        return T == []const u8 or T == ?[]const u8;
    \\    }
    \\
    \\    /// The JSON of the union member `f`: a const string member is its name, any other a sample of its type.
    \\    fn memberJson(comptime f: std.builtin.Type.UnionField, arena: Allocator) ![]const u8 {
    \\        if (f.type == void) return "\"" ++ f.name ++ "\"";
    \\        return std.json.stringifyAlloc(arena, sample(f.type, false), .{});
    \\    }
    \\
    \\    /// Every kind of JSON, to find the ones a union does not take.
    \\    const kinds = [_][]const u8{ "true", "null", "1", "\"zz\"", "[]", "{}" };
    \\
    \\    /// How many of the params that are not the body are optional (`query`: they are query parameters) or text (path parameters).
    \\    fn countFields(comptime P: type, comptime query: bool) usize {
    \\        var n: usize = 0;
    \\        for (@typeInfo(P).Struct.fields) |f| {
    \\            if (std.mem.eql(u8, f.name, "body")) continue;
    \\            if (query and @typeInfo(f.type) == .Optional) n += 1;
    \\            if (!query and @typeInfo(f.type) != .Optional and isText(f.type)) n += 1;
    \\        }
    \\        return n;
    \\    }
    \\
    \\    fn checkEnum(comptime E: type, arena: Allocator) !void {
    \\        inline for (@typeInfo(E).Enum.fields) |f| {
    \\            const tag: E = @field(E, f.name);
    \\            const text = "\"" ++ f.name ++ "\"";
    \\            try std.testing.expectEqual(tag, try std.json.parseFromSliceLeaky(E, arena, text, .{}));
    \\            try std.testing.expectEqual(tag, try E.jsonParseFromValue(arena, .{ .string = f.name }, .{}));
    \\            try std.testing.expectEqualStrings(text, try std.json.stringifyAlloc(arena, tag, .{}));
    \\        }
    \\        if (@hasField(E, "unknown")) {
    \\            try std.testing.expectEqual(E.unknown, try std.json.parseFromSliceLeaky(E, arena, "\"no-such-value\"", .{}));
    \\            try std.testing.expectEqual(E.unknown, try E.jsonParseFromValue(arena, .{ .string = "no-such-value" }, .{}));
    \\        }
    \\        try std.testing.expectError(error.UnexpectedToken, E.jsonParseFromValue(arena, .{ .integer = 1 }, .{}));
    \\        inline for (kinds) |k| {
    \\            if (comptime !std.mem.eql(u8, k, "\"zz\"")) {
    \\                try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(E, arena, k, .{}));
    \\            }
    \\        }
    \\    }
    \\
    \\    fn checkUnion(comptime U: type, arena: Allocator) !void {
    \\        comptime var takes_text = false;
    \\        comptime var takes_array = false;
    \\        comptime var takes_object = false;
    \\        inline for (@typeInfo(U).Union.fields) |f| {
    \\            const text = try memberJson(f, arena);
    \\            const got = try std.json.parseFromSliceLeaky(U, arena, text, .{});
    \\            try std.testing.expectEqual(@field(std.meta.Tag(U), f.name), std.meta.activeTag(got));
    \\            try std.testing.expectEqualStrings(text, try std.json.stringifyAlloc(arena, got, .{}));
    \\            switch (@typeInfo(f.type)) {
    \\                .Pointer => |p| if (p.child == u8) {
    \\                    takes_text = true;
    \\                } else {
    \\                    takes_array = true;
    \\                },
    \\                .Struct => takes_object = true,
    \\                else => {},
    \\            }
    \\        }
    \\        inline for (kinds) |k| {
    \\            const is_string = comptime std.mem.eql(u8, k, "\"zz\"");
    \\            const is_array = comptime std.mem.eql(u8, k, "[]");
    \\            const is_object = comptime std.mem.eql(u8, k, "{}");
    \\            const taken = (is_string and takes_text) or (is_array and takes_array) or (is_object and takes_object);
    \\            if (!taken) try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(U, arena, k, .{}));
    \\        }
    \\    }
    \\
    \\    fn checkOperation(comptime Op: type, arena: Allocator) !void {
    \\        const P = Op.Params;
    \\        const has_body = @hasField(P, "body");
    \\        const texts = comptime countFields(P, false);
    \\        const queries = comptime countFields(P, true);
    \\        const prefix = comptime Op.path_template[0 .. std.mem.indexOfScalar(u8, Op.path_template, '{') orelse Op.path_template.len];
    \\        const suffix = comptime Op.path_template[(std.mem.lastIndexOfScalar(u8, Op.path_template, '}') orelse Op.path_template.len -% 1) +% 1 ..];
    \\
    \\        const bare = try Op.target(arena, sample(P, false));
    \\        try std.testing.expect(std.mem.startsWith(u8, bare, prefix));
    \\        try std.testing.expect(std.mem.endsWith(u8, bare, suffix));
    \\        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, bare, '?'));
    \\        try std.testing.expectEqual(std.mem.count(u8, Op.path_template, "/"), std.mem.count(u8, bare, "/"));
    \\        try std.testing.expectEqual(texts > 0, std.mem.indexOf(u8, bare, "a%20b%2Fc") != null);
    \\
    \\        const full = try Op.target(arena, sample(P, true));
    \\        try std.testing.expect(std.mem.startsWith(u8, full, prefix));
    \\        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfAny(u8, full, " {}"));
    \\        try std.testing.expectEqual(queries > 0, std.mem.indexOfScalar(u8, full, '?') != null);
    \\        const path_end = std.mem.indexOfScalar(u8, full, '?') orelse full.len;
    \\        try std.testing.expectEqual(std.mem.count(u8, Op.path_template, "/"), std.mem.count(u8, full[0..path_end], "/"));
    \\        try std.testing.expectEqual(if (queries > 0) queries - 1 else 0, std.mem.count(u8, full, "&"));
    \\        inline for (@typeInfo(P).Struct.fields) |f| {
    \\            if (comptime !std.mem.eql(u8, f.name, "body") and @typeInfo(f.type) == .Optional) {
    \\                try std.testing.expect(std.mem.indexOf(u8, full, f.name ++ "=") != null);
    \\            }
    \\        }
    \\
    \\        const sent = try Op.body(arena, sample(P, true));
    \\        if (has_body) {
    \\            const text = sent.?;
    \\            _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    \\            const B = @TypeOf(sample(P, true).body);
    \\            const back = try std.json.parseFromSliceLeaky(B, arena, text, .{});
    \\            try std.testing.expectEqualStrings(text, try std.json.stringifyAlloc(arena, back, .{ .emit_null_optional_fields = false }));
    \\        } else {
    \\            try std.testing.expectEqual(@as(?[]const u8, null), sent);
    \\        }
    \\    }
    \\};
    \\
    \\test "every generated enum reads its names, reads any other string as unknown, refuses other JSON and writes its tag" {
    \\    @setEvalBranchQuota(1_000_000);
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    var n: usize = 0;
    \\    inline for (@typeInfo(@This()).Struct.decls) |d| {
    \\        const v = @field(@This(), d.name);
    \\        if (@TypeOf(v) == type and @typeInfo(v) == .Enum) {
    \\            try TailCheck.checkEnum(v, arena_state.allocator());
    \\            n += 1;
    \\        }
    \\    }
    \\    try std.testing.expect(n > 0);
    \\}
    \\
    \\test "every generated union round-trips each member and refuses the JSON no member takes" {
    \\    @setEvalBranchQuota(1_000_000);
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    var n: usize = 0;
    \\    inline for (@typeInfo(@This()).Struct.decls) |d| {
    \\        const v = @field(@This(), d.name);
    \\        if (@TypeOf(v) == type and @typeInfo(v) == .Union) {
    \\            try TailCheck.checkUnion(v, arena_state.allocator());
    \\            n += 1;
    \\        }
    \\    }
    \\    try std.testing.expect(n > 0);
    \\}
    \\
    \\test "every operation encodes its params into a target and writes a body exactly when it has one" {
    \\    @setEvalBranchQuota(1_000_000);
    \\    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_state.deinit();
    \\    inline for (operations) |Op| try TailCheck.checkOperation(Op, arena_state.allocator());
    \\}
    \\
;
