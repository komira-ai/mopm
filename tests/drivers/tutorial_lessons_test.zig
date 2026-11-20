//! //:tutorial_lessons: the lessons under tutorial/lessons pass their contract (spec/tutorial-lesson.schema.json and
//! tests/drivers/tutorial_lessons.zig), the schema refuses what it must, the checker refuses a broken lesson, and the
//! committed mopm.lock of each lesson is what `mopm lock` writes.
//!
//! Run by Buck2 from the repository root; MOPM is the built CLI (only the last test needs it). Every broken lesson is
//! a copy in a test's own temporary directory, so the committed files are never written to.

const std = @import("std");
const c = @import("contract.zig");
const h = @import("harness.zig");
const tl = @import("tutorial_lessons.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const hello_json = "tutorial/lessons/hello/lesson.json";

// ------------------------------------------------------------------ the schema

/// The schema's errors for `doc`.
fn lessonErrors(a: Allocator, schemas: tl.Schemas, doc: Value) ![]const []const u8 {
    return (try c.schemaErrors(a, schemas.lesson, schemas.lesson, doc)).items;
}

/// hello's lesson.json with `key` (a top-level key, or `actions.<name>`) set to the JSON `value`, or removed when
/// `value` is null.
fn helloWith(a: Allocator, key: []const u8, value: ?[]const u8) !Value {
    var doc = try c.clone(a, try c.loadJson(a, hello_json));
    var obj = &doc.object;
    var name = key;
    if (std.mem.startsWith(u8, key, "actions.")) {
        obj = &obj.getPtr("actions").?.object;
        name = key["actions.".len..];
    }
    if (value) |v| try obj.put(name, try c.parseJson(a, v)) else _ = obj.orderedRemove(name);
    return doc;
}

/// The schema refuses hello's lesson.json with `key` set to `value`, and the first error is at the instance path
/// `at`.
fn expectRefused(a: Allocator, schemas: tl.Schemas, key: []const u8, value: ?[]const u8, at: []const u8) !void {
    const errs = try lessonErrors(a, schemas, try helloWith(a, key, value));
    if (errs.len == 0) {
        std.debug.print("FAIL: the schema accepts lesson.json with {s} = {?s}\n", .{ key, value });
        return error.NotRefused;
    }
    const head = try std.fmt.allocPrint(a, "{s}: ", .{at});
    if (!std.mem.startsWith(u8, errs[0], head)) {
        std.debug.print("FAIL: {s} = {?s} is refused at the wrong place: {s}\n", .{ key, value, errs[0] });
        return error.RefusedElsewhere;
    }
}

fn expectAccepted(a: Allocator, schemas: tl.Schemas, key: []const u8, value: ?[]const u8) !void {
    const errs = try lessonErrors(a, schemas, try helloWith(a, key, value));
    for (errs) |e| std.debug.print("FAIL: {s} = {?s}: {s}\n", .{ key, value, e });
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "the schema accepts the hello lesson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    try std.testing.expectEqual(@as(usize, 0), (try lessonErrors(a, schemas, try c.loadJson(a, hello_json))).len);
}

test "the schema accepts a test action, arguments, and nested and dot-file editable paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    try expectAccepted(a, schemas, "actions.test", "\"mopm test\"");
    try expectAccepted(a, schemas, "actions.test", "\"mopm test --list tests/test_hello.mojo\"");
    try expectAccepted(a, schemas, "actions.run", "\"mopm run --bin tutorial/hello:hello\"");
    try expectAccepted(a, schemas, "editable", "[\"src/main.mojo\", \"tests/test_hello.mojo\", \"mopm.toml\", \".config/x.y\"]");
}

test "the schema refuses an editable path ../x" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefused(a, try tl.loadSchemas(a), "editable", "[\"../x\"]", "/editable/0");
}

test "the schema refuses an editable path /etc/passwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefused(a, try tl.loadSchemas(a), "editable", "[\"/etc/passwd\"]", "/editable/0");
}

test "the schema refuses an editable path with a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefused(a, try tl.loadSchemas(a), "editable", "[\"src\\\\main.mojo\"]", "/editable/0");
}

test "the schema refuses every other way out of project/ or to no file: inner .., ., empty and trailing segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    const paths = [_][]const u8{ "src/../../x", "src/..", "..", "./src/main.mojo", "src/./main.mojo", ".", "", "src//main.mojo", "src/", "C:/x", "~/x", "src/main mojo" };
    for (paths) |p| {
        try expectRefused(a, schemas, "editable", try std.fmt.allocPrint(a, "[\"{s}\"]", .{p}), "/editable/0");
    }
}

test "the schema refuses a lesson without a run action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    try expectRefused(a, schemas, "actions.run", null, "/actions");
    // A test action does not stand in for the run action.
    var doc = try helloWith(a, "actions", "{\"test\": \"mopm test\"}");
    try std.testing.expect((try lessonErrors(a, schemas, doc)).len != 0);
    doc = try helloWith(a, "actions", null);
    try std.testing.expect((try lessonErrors(a, schemas, doc)).len != 0);
}

test "the schema refuses an action that is not its mopm command (bare mopm run names no program), or holds what a shell would read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    const runs = [_][]const u8{ "mopm run", "mopm publish", "mopm test", "mopm", "mopm run ", "mopm  run", "mopm run; rm x", "mopm run $(id)", "mopm run | cat", "mopm run \\\"x\\\"", "/bin/mopm run", "" };
    for (runs) |r| {
        try expectRefused(a, schemas, "actions.run", try std.fmt.allocPrint(a, "\"{s}\"", .{r}), "/actions/run");
    }
    try expectRefused(a, schemas, "actions.test", "\"mopm run src/main.mojo\"", "/actions/test");
    try expectRefused(a, schemas, "actions.run", "[\"mopm\", \"run\"]", "/actions/run");
    try expectRefused(a, schemas, "actions.build", "\"mopm run src/main.mojo\"", "/actions");
}

test "the schema refuses an unknown top-level key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefused(a, try tl.loadSchemas(a), "id", "\"hello\"", "");
}

test "the schema refuses a missing or out-of-range field: title, summary, order, editable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    for ([_][]const u8{ "title", "summary", "order", "editable", "actions" }) |k| try expectRefused(a, schemas, k, null, "");
    try expectRefused(a, schemas, "title", "\"\"", "/title");
    try expectRefused(a, schemas, "summary", "\"\"", "/summary");
    try expectRefused(a, schemas, "order", "0", "/order");
    try expectRefused(a, schemas, "order", "\"1\"", "/order");
    try expectRefused(a, schemas, "order", "1.5", "/order");
    try expectRefused(a, schemas, "editable", "[]", "/editable");
    try expectRefused(a, schemas, "editable", "[\"src/main.mojo\", \"src/main.mojo\"]", "/editable");
}

test "the lesson id grammar: hello and hello-2 are ids, Hello_1 and the near misses are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try tl.loadSchemas(a);
    const id_schema = c.get(c.get(schemas.lesson, "$defs").?, "LessonId").?;
    for ([_][]const u8{ "hello", "hello-2", "2" }) |id| {
        try std.testing.expectEqual(@as(usize, 0), (try c.schemaErrors(a, schemas.lesson, id_schema, .{ .string = id })).items.len);
    }
    for ([_][]const u8{ "Hello_1", "Hello", "hello_1", "hello--2", "-hello", "hello-", "", "hello.x", "a" ** 65 }) |id| {
        const errs = try c.schemaErrors(a, schemas.lesson, id_schema, .{ .string = id });
        if (errs.items.len == 0) std.debug.print("FAIL: the id \"{s}\" is accepted\n", .{id});
        try std.testing.expect(errs.items.len != 0);
    }
}

// ------------------------------------------------------------------ the checker

test "the lessons under tutorial/lessons pass the checker, and hello is one of them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try tl.lessonsProblems(a, try tl.loadSchemas(a), "tutorial/lessons");
    for (found.items) |p| std.debug.print("FAIL: {s}\n", .{p});
    try std.testing.expectEqual(@as(usize, 0), found.items.len);
    var hello = try std.fs.cwd().openDir("tutorial/lessons/hello", .{});
    hello.close();
}

/// A temporary lessons directory holding copies of hello under the given ids.
const Tree = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(a: Allocator, ids: []const []const u8) !Tree {
        var tmp = std.testing.tmpDir(.{});
        const root = try h.join(a, &.{ try h.tmpPath(a, &tmp), "lessons" });
        try std.fs.cwd().makePath(root);
        for (ids) |id| try h.copyTree(a, "tutorial/lessons/hello", try h.join(a, &.{ root, id }));
        return .{ .tmp = tmp, .root = root };
    }

    fn path(t: Tree, a: Allocator, rel: []const u8) ![]const u8 {
        return h.join(a, &.{ t.root, rel });
    }

    fn remove(t: Tree, a: Allocator, rel: []const u8) !void {
        try std.fs.cwd().deleteFile(try t.path(a, rel));
    }

    /// Writes `bytes` as the file `rel` (relative to the lessons directory), replacing what is there.
    fn put(t: Tree, a: Allocator, rel: []const u8, bytes: []const u8) !void {
        const p = try t.path(a, rel);
        std.fs.cwd().deleteFile(p) catch {};
        try h.writeFile(p, bytes);
    }

    /// hello's lesson.json with one key changed, as lesson `id`'s.
    fn putLesson(t: Tree, a: Allocator, id: []const u8, key: []const u8, value: ?[]const u8) !void {
        const doc = try helloWith(a, key, value);
        try t.put(a, try h.join(a, &.{ id, "lesson.json" }), try std.json.stringifyAlloc(a, doc, .{}));
    }

    /// The checker finds exactly `want` (each a format with `{r}` for the lessons directory), in order.
    fn expectProblems(t: Tree, a: Allocator, want: []const []const u8) !void {
        const found = try tl.lessonsProblems(a, try tl.loadSchemas(a), t.root);
        var got = std.ArrayList(u8).init(a);
        for (found.items) |p| try got.writer().print("{s}\n", .{p});
        var exp = std.ArrayList(u8).init(a);
        for (want) |w| try exp.writer().print("{s}\n", .{try std.mem.replaceOwned(u8, a, w, "{r}", t.root)});
        try std.testing.expectEqualStrings(exp.items, got.items);
    }

    fn deinit(t: *Tree) void {
        t.tmp.cleanup();
    }
};

test "the checker refuses a lesson whose editable file is missing from project/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"hello"});
    defer t.deinit();
    try t.expectProblems(a, &.{});
    try t.remove(a, "hello/project/src/main.mojo");
    try t.expectProblems(a, &.{"{r}/hello: the editable file src/main.mojo is not a file under project/"});
}

test "the checker refuses an editable path that names a directory, or a file outside project/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"hello"});
    defer t.deinit();
    try t.putLesson(a, "hello", "editable", "[\"src\"]");
    try t.expectProblems(a, &.{"{r}/hello: the editable file src is not a file under project/"});
    // lesson.md is in the lesson's directory, not under project/.
    try t.putLesson(a, "hello", "editable", "[\"src/main.mojo\", \"lesson.md\"]");
    try t.expectProblems(a, &.{"{r}/hello: the editable file lesson.md is not a file under project/"});
}

test "the checker refuses a lesson directory named Hello_1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"Hello_1"});
    defer t.deinit();
    try t.expectProblems(a, &.{"{r}/Hello_1: the lesson id \"Hello_1\" is not a LessonId (lower-case letters and digits, words joined by single hyphens)"});
}

test "the checker refuses a missing or empty lesson.md and a missing mopm.toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{ "one", "two" });
    defer t.deinit();
    try t.putLesson(a, "two", "order", "2");
    try t.remove(a, "one/lesson.md");
    try t.put(a, "two/lesson.md", "");
    try t.remove(a, "two/project/mopm.toml");
    try t.expectProblems(a, &.{
        "{r}/one: lesson.md is not a file",
        "{r}/two: lesson.md is empty",
        "{r}/two: project/mopm.toml is not a file",
    });
}

test "the checker refuses a missing lock, a lock that is not JSON, and a lock the lock contract refuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"hello"});
    defer t.deinit();
    try t.remove(a, "hello/project/mopm.lock");
    try t.expectProblems(a, &.{"{r}/hello: project/mopm.lock is not a file"});
    try t.put(a, "hello/project/mopm.lock", "{");
    try t.expectProblems(a, &.{"{r}/hello: project/mopm.lock is not JSON"});
    // The schema: a lock written before namespaces.
    const lock = try h.readFile(a, "tutorial/lessons/hello/project/mopm.lock");
    try t.put(a, "hello/project/mopm.lock", try std.mem.replaceOwned(u8, a, lock, "\"lock_version\": 3", "\"lock_version\": 2"));
    try t.expectProblems(a, &.{"{r}/hello: project/mopm.lock: /lock_version: 3 was expected"});
    // The rules of spec/lock.md beyond the schema: the locked Mojo versions are sorted.
    try t.put(a, "hello/project/mopm.lock", try std.mem.replaceOwned(u8, a, lock, "\"1.0.0\"\n  ]", "\"1.0.0\", \"0.9.0\"\n  ]"));
    try t.expectProblems(a, &.{"{r}/hello: project/mopm.lock: mojo is not sorted with no repeats"});
}

test "the checker refuses a lesson.json that is missing, not JSON, or refused by the schema (and checks no editable file then)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"hello"});
    defer t.deinit();
    try t.remove(a, "hello/lesson.json");
    try t.expectProblems(a, &.{"{r}/hello: lesson.json is not a file"});
    try t.put(a, "hello/lesson.json", "{\"title\": ");
    try t.expectProblems(a, &.{"{r}/hello: lesson.json is not JSON"});
    try t.putLesson(a, "hello", "editable", "[\"../x\"]");
    const found = try tl.lessonsProblems(a, try tl.loadSchemas(a), t.root);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.startsWith(u8, found.items[0], try std.fmt.allocPrint(a, "{s}/hello: lesson.json: /editable/0: ", .{t.root})));
}

test "the checker refuses an order the schema takes but that is not written as an integer: 1.0, 1e30" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{"hello"});
    defer t.deinit();
    for ([_][]const u8{ "1.0", "1e30" }) |order| {
        const json = try h.readFile(a, hello_json);
        try t.put(a, "hello/lesson.json", try std.mem.replaceOwned(u8, a, json, "\"order\": 1,", try std.fmt.allocPrint(a, "\"order\": {s},", .{order})));
        try t.expectProblems(a, &.{"{r}/hello: lesson.json: /order: write the order as an integer, such as 1"});
    }
}

test "the checker refuses two lessons of one order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{ "one", "two", "three" });
    defer t.deinit();
    try t.putLesson(a, "two", "order", "2");
    try t.expectProblems(a, &.{"{r}/three: order 1 is also the order of the lesson one"});
}

test "the checker refuses a file among the lessons, a tree with no lesson, and a lessons directory that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tree.init(a, &.{});
    defer t.deinit();
    try t.expectProblems(a, &.{"{r}: no lessons"});
    try t.put(a, "README.md", "x");
    try t.expectProblems(a, &.{
        "{r}/README.md: not a directory; a lesson is a directory with lesson.md, lesson.json and project/",
        "{r}: no lessons",
    });
    const gone = try h.join(a, &.{ t.root, "gone" });
    const found = try tl.lessonsProblems(a, try tl.loadSchemas(a), gone);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}: cannot open the lessons directory (FileNotFound)", .{gone}), found.items[0]);
}

// ------------------------------------------------------------------ the lock is mopm's

/// A loopback registry on port 0 that answers nothing: it counts the connections it is offered and closes each.
const DeadRegistry = struct {
    server: std.net.Server,
    thread: std.Thread,
    offered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(self: *DeadRegistry) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{});
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    fn loop(self: *DeadRegistry) void {
        while (true) {
            const conn = self.server.accept() catch return;
            conn.stream.close();
            _ = self.offered.fetchAdd(1, .seq_cst);
            if (self.stopping.load(.seq_cst)) return;
        }
    }

    fn port(self: *DeadRegistry) u16 {
        return self.server.listen_address.getPort();
    }

    /// Stops the loop (with one last connection of its own, not counted) and returns how many it was offered.
    fn stop(self: *DeadRegistry) !usize {
        self.stopping.store(true, .seq_cst);
        const s = try std.net.tcpConnectToAddress(self.server.listen_address);
        s.close();
        self.thread.join();
        self.server.deinit();
        // Every connection is counted, the last one (stop's own) too.
        return self.offered.load(.seq_cst) - 1;
    }
};

test "each lesson's committed mopm.lock is what mopm lock writes, offline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mopm = try h.toolPath(a, "MOPM");
    var t = try Tree.init(a, &.{});
    defer t.deinit();
    var reg = DeadRegistry{ .server = undefined, .thread = undefined };
    try reg.start();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{reg.port()});

    var d = try std.fs.cwd().openDir("tutorial/lessons", .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var n: usize = 0;
    var rep = h.Report{};
    while (try it.next()) |e| {
        const project = try h.join(a, &.{ t.root, e.name });
        try h.copyTree(a, try h.join(a, &.{ "tutorial/lessons", e.name, "project" }), project);
        const lock = try h.join(a, &.{ project, "mopm.lock" });
        try std.fs.cwd().deleteFile(lock);
        const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ mopm, "lock", "--registry", url }, .cwd = project });
        const exited_0 = switch (r.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        rep.check(try h.fmt(a, "{s}: mopm lock exits 0", .{e.name}), exited_0, try h.fmt(a, "{any}: {s}{s}", .{ r.term, r.stdout, r.stderr }));
        const committed = try h.readFile(a, try h.join(a, &.{ "tutorial/lessons", e.name, "project/mopm.lock" }));
        rep.same(try h.fmt(a, "{s}: the lock written is the committed mopm.lock", .{e.name}), committed, h.readFile(a, lock) catch "");
        n += 1;
    }
    const offered = try reg.stop();
    rep.check("no lesson's lock asked the registry", offered == 0, try h.fmt(a, "{d} connection(s)", .{offered}));
    rep.check("there is a lesson to lock", n != 0, "tutorial/lessons is empty");
    try rep.finish();
}
