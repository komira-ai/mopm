//! The lessons of the interactive tutorial against their contract, spec/tutorial-lesson.schema.json, and the rules of
//! it that JSON Schema cannot express. A lesson is a directory tutorial/lessons/<id>/ holding lesson.md, lesson.json and
//! project/ (a mopm project). The site build reads lesson.md and lesson.json; the sandbox template build takes project/.
//!
//! For each lesson, `lessonsProblems` checks:
//!   - the id (the directory's name) is the schema's `$defs/LessonId`;
//!   - lesson.md is a file that is not empty;
//!   - lesson.json is JSON and passes the schema;
//!   - project/mopm.toml is a file, and project/mopm.lock passes spec/lock.schema.json and the lock rules of
//!     spec/lock.md (contract.lockProblems);
//!   - each editable path names a file under project/ (the schema has already refused `..`, absolute paths and
//!     backslashes, so the path names nothing outside project/; a symbolic link in it is followed, as a copy does);
//!   - the order is written as an integer (the schema's `integer` also takes 1.0);
//!   - no two lessons share an order.
//! A file directly under tutorial/lessons is refused, and so is a tree with no lesson.
//!
//! Problems are returned as strings, `<lesson directory>: <what is wrong>`; an empty list is a pass.
//! Run by Buck2 (//:tutorial_lessons, tests/drivers/tutorial_lessons_test.zig) from the repository root.

const std = @import("std");
const c = @import("contract.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// The two schemas a lesson is held to: spec/tutorial-lesson.schema.json and spec/lock.schema.json.
pub const Schemas = struct { lesson: Value, lock: Value };

/// The schemas, read from spec/ under the current directory.
pub fn loadSchemas(a: Allocator) !Schemas {
    return .{
        .lesson = try c.loadJson(a, "spec/tutorial-lesson.schema.json"),
        .lock = try c.loadJson(a, "spec/lock.schema.json"),
    };
}

/// The schema's `$defs/LessonId`, the grammar of a lesson's directory name.
fn lessonIdSchema(schemas: Schemas) Value {
    return c.get(c.get(schemas.lesson, "$defs").?, "LessonId").?;
}

const Order = struct { order: i64, id: []const u8 };

/// Every problem of the lessons under `root` (tutorial/lessons in the repository).
pub fn lessonsProblems(a: Allocator, schemas: Schemas, root: []const u8) !c.Problems {
    var out = c.Problems.init(a);
    var d = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
        try c.problem(a, &out, "{s}: cannot open the lessons directory ({s})", .{ root, @errorName(e) });
        return out;
    };
    defer d.close();

    var ids = std.ArrayList([]const u8).init(a);
    var it = d.iterate();
    while (try it.next()) |e| {
        // openDir follows a symbolic link, as the builds that copy the tree do.
        var sub = d.openDir(e.name, .{}) catch {
            try c.problem(a, &out, "{s}/{s}: not a directory; a lesson is a directory with lesson.md, lesson.json and project/", .{ root, e.name });
            continue;
        };
        sub.close();
        try ids.append(try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, ids.items, {}, c.lessStr);
    if (ids.items.len == 0) try c.problem(a, &out, "{s}: no lessons", .{root});

    var orders = std.ArrayList(Order).init(a);
    for (ids.items) |id| {
        const where = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, id });
        if (try lessonProblems(a, schemas, d, id, where, &out)) |order| {
            for (orders.items) |o| {
                if (o.order == order) try c.problem(a, &out, "{s}: order {d} is also the order of the lesson {s}", .{ where, order, o.id });
            }
            try orders.append(.{ .order = order, .id = id });
        }
    }
    return out;
}

/// Appends the problems of the lesson `id` (in `lessons`) to `out`, each prefixed by `where`; returns its order when
/// its lesson.json passed the schema.
fn lessonProblems(a: Allocator, schemas: Schemas, lessons: std.fs.Dir, id: []const u8, where: []const u8, out: *c.Problems) !?i64 {
    const id_errs = try c.schemaErrors(a, schemas.lesson, lessonIdSchema(schemas), .{ .string = id });
    if (id_errs.items.len != 0) try c.problem(a, out, "{s}: the lesson id \"{s}\" is not a LessonId (lower-case letters and digits, words joined by single hyphens)", .{ where, id });

    var dir = try lessons.openDir(id, .{});
    defer dir.close();

    if (fileSize(dir, "lesson.md")) |size| {
        if (size == 0) try c.problem(a, out, "{s}: lesson.md is empty", .{where});
    } else try c.problem(a, out, "{s}: lesson.md is not a file", .{where});
    if (fileSize(dir, "project/mopm.toml") == null) try c.problem(a, out, "{s}: project/mopm.toml is not a file", .{where});
    if (try readJson(a, dir, "project/mopm.lock", where, out)) |lock| {
        const errs = try c.schemaErrors(a, schemas.lock, schemas.lock, lock);
        for (errs.items) |e| try c.problem(a, out, "{s}: project/mopm.lock: {s}", .{ where, e });
        if (errs.items.len == 0) {
            const rules = try c.lockProblems(a, lock);
            for (rules.items) |e| try c.problem(a, out, "{s}: project/mopm.lock: {s}", .{ where, e });
        }
    }

    const doc = try readJson(a, dir, "lesson.json", where, out) orelse return null;
    const errs = try c.schemaErrors(a, schemas.lesson, schemas.lesson, doc);
    for (errs.items) |e| try c.problem(a, out, "{s}: lesson.json: {s}", .{ where, e });
    if (errs.items.len != 0) return null;

    for (c.getArr(doc, "editable")) |p| {
        const rel = try std.fmt.allocPrint(a, "project/{s}", .{p.string});
        if (fileSize(dir, rel) == null) try c.problem(a, out, "{s}: the editable file {s} is not a file under project/", .{ where, p.string });
    }
    // The schema's integer is any whole number, 1.0 and 1e30 too; the builds read an integer.
    return c.getInt(doc, "order") orelse {
        try c.problem(a, out, "{s}: lesson.json: /order: write the order as an integer, such as 1", .{where});
        return null;
    };
}

/// The size of the file `rel` of `dir` (a link is followed), or null when there is no file there (nothing, a directory,
/// or a path it cannot stat).
fn fileSize(dir: std.fs.Dir, rel: []const u8) ?u64 {
    const st = dir.statFile(rel) catch return null;
    return if (st.kind == .file) st.size else null;
}

/// The JSON of the file `rel` of `dir`, or null (and a problem) when it is missing or not JSON.
fn readJson(a: Allocator, dir: std.fs.Dir, rel: []const u8, where: []const u8, out: *c.Problems) !?Value {
    if (fileSize(dir, rel) == null) {
        try c.problem(a, out, "{s}: {s} is not a file", .{ where, rel });
        return null;
    }
    const bytes = try dir.readFileAlloc(a, rel, 1 << 20);
    return c.parseJson(a, bytes) catch {
        try c.problem(a, out, "{s}: {s} is not JSON", .{ where, rel });
        return null;
    };
}
