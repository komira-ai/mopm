//! The link planner: from the metadata of every installed package in a
//! closure, compute the arguments that make native libraries link and load.
//!
//! Facts it encodes (each one was observed on a real Mojo toolchain):
//!   * `mojo build` links a shared object with `-L<dir> -l<name>`; a static
//!     archive is passed by path.
//!   * `mojo run` takes one `-Xlinker <shared object>` per library; a static
//!     archive has no effect there, so a static-only library cannot be run.
//!   * The REPL needs the shared objects in the preload set of the JIT
//!     process; static archives cannot be preloaded.
//!   * Every transitive native library must be present in the set: a missing
//!     one kills the process. Their order does not matter on Linux.
//!   * One owner per native library: two packages shipping one soname are
//!     refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const metadata = @import("metadata.zig");

const List = std.ArrayList([]const u8);

/// One installed package: the directory its metadata file lives in (native
/// file paths are relative to it) and the parsed metadata.
pub const Input = struct {
    dir: []const u8,
    meta: metadata.Metadata,
};

pub const Code = enum {
    duplicate_package,
    duplicate_owner,
    missing_package,
    missing_library,
    not_in_preload_set,
    static_only,
};

/// Which command a diagnostic blocks.
pub const Command = enum { all, run, repl };

pub const Diagnostic = struct {
    code: Code,
    command: Command,
    message: []const u8,
};

pub const Plan = struct {
    /// Complete arguments for `mojo build`.
    build: []const []const u8,
    /// Shared objects; each becomes `-Xlinker <path>` for `mojo run`.
    run: []const []const u8,
    /// Shared objects for the REPL's preload variable.
    preload: []const []const u8,
    diagnostics: []const Diagnostic,

    pub fn ok(self: Plan) bool {
        return self.diagnostics.len == 0;
    }
};

fn join(arena: Allocator, dir: []const u8, file: []const u8) Allocator.Error![]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return file;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, file });
}

/// A library a closure can put in the preload set: link mode, shared flavour.
fn preloadable(n: metadata.Native) bool {
    return n.mode == .link and n.kind != .static;
}

pub fn plan(arena: Allocator, inputs: []const Input) Allocator.Error!Plan {
    var diags = std.ArrayList(Diagnostic).init(arena);
    var build_args = List.init(arena);
    var run_paths = List.init(arena);
    var preload = List.init(arena);

    var pkgs = std.StringHashMap(void).init(arena);
    var owners = std.StringHashMap([]const u8).init(arena); // soname -> package
    var provides = std.StringHashMap(bool).init(arena); // soname -> preloadable
    var seen_dirs = std.StringHashMap(void).init(arena);
    var emitted = std.StringHashMap(void).init(arena);

    // Pass 1: package names are unique.
    for (inputs) |inp| {
        const r = try pkgs.getOrPut(inp.meta.name);
        if (r.found_existing) {
            try diags.append(.{
                .code = .duplicate_package,
                .command = .all,
                .message = try std.fmt.allocPrint(arena, "package {s} appears more than once", .{inp.meta.name}),
            });
        }
    }

    // Pass 2: one owner per soname.
    for (inputs) |inp| {
        for (inp.meta.native) |n| {
            const r = try owners.getOrPut(n.soname);
            if (!r.found_existing) {
                r.value_ptr.* = inp.meta.name;
                try provides.put(n.soname, preloadable(n));
            } else if (!std.mem.eql(u8, r.value_ptr.*, inp.meta.name)) {
                try diags.append(.{
                    .code = .duplicate_owner,
                    .command = .all,
                    .message = try std.fmt.allocPrint(
                        arena,
                        "{s} is provided by both {s} and {s}; one owner per native library",
                        .{ n.soname, r.value_ptr.*, inp.meta.name },
                    ),
                });
            }
        }
    }

    // Pass 3: every dependency and every needed library is in the closure.
    for (inputs) |inp| {
        for (inp.meta.deps) |d| {
            if (!pkgs.contains(d.name)) {
                try diags.append(.{
                    .code = .missing_package,
                    .command = .all,
                    .message = try std.fmt.allocPrint(
                        arena,
                        "{s} depends on {s}, which is not in the closure",
                        .{ inp.meta.name, d.name },
                    ),
                });
            }
        }
        for (inp.meta.native) |n| {
            if (n.mode != .link) continue; // a load-mode library resolves its own needs
            for (n.needs) |need| {
                if (provides.get(need)) |can_preload| {
                    if (!can_preload) {
                        try diags.append(.{
                            .code = .not_in_preload_set,
                            .command = .all,
                            .message = try std.fmt.allocPrint(
                                arena,
                                "{s} (native {s}) needs {s}, which its owner does not ship as a linked shared library",
                                .{ inp.meta.name, n.id, need },
                            ),
                        });
                    }
                } else {
                    try diags.append(.{
                        .code = .missing_library,
                        .command = .all,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "{s} (native {s}) needs {s}, which no package in the closure provides",
                            .{ inp.meta.name, n.id, need },
                        ),
                    });
                }
            }
        }
    }

    // Pass 4: the flags, in input order. Only the first owner of a soname
    // contributes.
    for (inputs) |inp| {
        for (inp.meta.native) |n| {
            if (n.mode == .load) continue;
            const owner = owners.get(n.soname) orelse continue;
            if (!std.mem.eql(u8, owner, inp.meta.name)) continue;
            const e = try emitted.getOrPut(n.soname);
            if (e.found_existing) continue;

            if (n.kind != .static) {
                // Parsed metadata always has a valid soname; skip otherwise.
                const lib = metadata.linkName(n.soname) orelse continue;
                const path = try join(arena, inp.dir, n.file);
                const d = try seen_dirs.getOrPut(std.fs.path.dirname(path) orelse ".");
                if (!d.found_existing) {
                    try build_args.append(try std.fmt.allocPrint(arena, "-L{s}", .{d.key_ptr.*}));
                }
                try build_args.append(try std.fmt.allocPrint(arena, "-l{s}", .{lib}));
                try run_paths.append(path);
                try preload.append(path);
            } else {
                try build_args.append(try join(arena, inp.dir, n.static_file));
                inline for (.{ Command.run, Command.repl }) |cmd| {
                    try diags.append(.{
                        .code = .static_only,
                        .command = cmd,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "{s} ships only {s} (native {s}); mojo {s} cannot load an archive: use mopm build or ask for a shared flavour",
                            .{ inp.meta.name, std.fs.path.basename(n.static_file), n.id, @tagName(cmd) },
                        ),
                    });
                }
            }
        }
    }

    return .{
        .build = try build_args.toOwnedSlice(),
        .run = try run_paths.toOwnedSlice(),
        .preload = try preload.toOwnedSlice(),
        .diagnostics = try diags.toOwnedSlice(),
    };
}

/// Text form used by `mopm link-plan` and by the golden files.
pub fn render(p: Plan, w: anytype) !void {
    try w.writeAll("build:\n");
    for (p.build) |a| try w.print("  {s}\n", .{a});
    try w.writeAll("run:\n");
    for (p.run) |a| try w.print("  -Xlinker {s}\n", .{a});
    try w.writeAll("repl-preload:\n");
    for (p.preload) |a| try w.print("  {s}\n", .{a});
    try w.writeAll("diagnostics:\n");
    for (p.diagnostics) |d| try w.print("  [{s}] {s}: {s}\n", .{ @tagName(d.command), @tagName(d.code), d.message });
}

/// Read and parse a `<name>.mopm.json`; its directory anchors the native paths.
pub fn loadInput(arena: Allocator, path: []const u8) !Input {
    const text = try std.fs.cwd().readFileAlloc(arena, path, 1 << 20);
    const meta = try metadata.parse(arena, text);
    return .{ .dir = std.fs.path.dirname(path) orelse ".", .meta = meta };
}

// ---------------------------------------------------------------- tests

fn mk(a: Allocator, dir: []const u8, json: []const u8) !Input {
    return .{ .dir = dir, .meta = try metadata.parse(a, json) };
}

fn has(p: Plan, code: Code, cmd: Command) bool {
    for (p.diagnostics) |d| {
        if (d.code == code and d.command == cmd) return true;
    }
    return false;
}

fn expectList(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

const pkg_shared =
    \\{"schema": 1, "name": "app", "native": [
    \\  {"id": "x", "soname": "libx.so.1", "file": "lib/libx.so.1"}]}
;

test "shared library: -L/-l for build, -Xlinker path for run, preload for the REPL" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk", pkg_shared)});
    try expectList(&.{ "-Lpk/lib", "-lx" }, p.build);
    try expectList(&.{"pk/lib/libx.so.1"}, p.run);
    try expectList(&.{"pk/lib/libx.so.1"}, p.preload);
    try std.testing.expect(p.ok());
}

test "static-only library: archive by path for build, an error for run and repl" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "s", "native": [
        \\  {"id": "x", "soname": "libx.a", "kind": "static", "static_file": "lib/libx.a"}]}
    )});
    try expectList(&.{"pk/lib/libx.a"}, p.build);
    try std.testing.expectEqual(@as(usize, 0), p.run.len);
    try std.testing.expectEqual(@as(usize, 0), p.preload.len);
    try std.testing.expect(has(p, .static_only, .run));
    try std.testing.expect(has(p, .static_only, .repl));
    try std.testing.expect(!has(p, .static_only, .all));
}

test "kind both: the shared object is used, not the archive" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "x", "soname": "libx.so.1", "kind": "both",
        \\   "file": "lib/libx.so.1", "static_file": "lib/libx.a"}]}
    )});
    try expectList(&.{ "-Lpk/lib", "-lx" }, p.build);
    try expectList(&.{"pk/lib/libx.so.1"}, p.run);
    try std.testing.expect(p.ok());
}

test "load mode contributes no flags" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "pk",
        \\{"schema": 1, "name": "l", "native": [
        \\  {"id": "x", "soname": "libx.so.1", "mode": "load", "file": "lib/libx.so.1"}]}
    )});
    try std.testing.expectEqual(@as(usize, 0), p.build.len);
    try std.testing.expectEqual(@as(usize, 0), p.run.len);
    try std.testing.expectEqual(@as(usize, 0), p.preload.len);
    try std.testing.expect(p.ok());
}

const needs_b =
    \\{"schema": 1, "name": "a", "deps": [{"name": "b"}], "native": [
    \\  {"id": "a", "soname": "liba.so.1", "file": "lib/liba.so.1", "needs": ["libb.so.1"]}]}
;
const provides_b =
    \\{"schema": 1, "name": "b", "native": [
    \\  {"id": "b", "soname": "libb.so.1", "file": "lib/libb.so.1"}]}
;

test "a transitive library must be present" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, "d", needs_b)});
    try std.testing.expect(has(p, .missing_library, .all));
    try std.testing.expect(has(p, .missing_package, .all));
}

test "with the transitive library present, both are in the preload set" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", needs_b), try mk(a, "d", provides_b) });
    try std.testing.expect(p.ok());
    try expectList(&.{ "d/lib/liba.so.1", "d/lib/libb.so.1" }, p.preload);
    try expectList(&.{ "d/lib/liba.so.1", "d/lib/libb.so.1" }, p.run);
    try expectList(&.{ "-Ld/lib", "-la", "-lb" }, p.build);
}

test "order does not matter, presence does" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", provides_b), try mk(a, "d", needs_b) });
    try std.testing.expect(p.ok());
    try expectList(&.{ "d/lib/libb.so.1", "d/lib/liba.so.1" }, p.preload);
}

test "a needed library that is only static or load-mode is not in the preload set" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", needs_b), try mk(a, "d",
        \\{"schema": 1, "name": "b", "native": [
        \\  {"id": "b", "soname": "libb.so.1", "mode": "load", "file": "lib/libb.so.1"}]}
    ) });
    try std.testing.expect(has(p, .not_in_preload_set, .all));
    try std.testing.expect(!has(p, .missing_library, .all));
}

test "two packages owning one native library are refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d1", provides_b), try mk(a, "d2",
        \\{"schema": 1, "name": "other", "native": [
        \\  {"id": "b2", "soname": "libb.so.1", "file": "lib/libb.so.1"}]}
    ) });
    try std.testing.expect(has(p, .duplicate_owner, .all));
    // only the first owner contributes flags
    try expectList(&.{"d1/lib/libb.so.1"}, p.preload);
}

test "the same package twice is refused" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{ try mk(a, "d", provides_b), try mk(a, "d", provides_b) });
    try std.testing.expect(has(p, .duplicate_package, .all));
    try std.testing.expect(!has(p, .duplicate_owner, .all));
    try expectList(&.{"d/lib/libb.so.1"}, p.preload);
}

test "a package with no natives plans nothing" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, ".", "{\"schema\": 1, \"name\": \"pure\"}")});
    try std.testing.expect(p.ok());
    try std.testing.expectEqual(@as(usize, 0), p.build.len);
}

test "a dot directory does not prefix paths" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const p = try plan(a, &.{try mk(a, ".", pkg_shared)});
    try expectList(&.{ "-Llib", "-lx" }, p.build);
    try expectList(&.{"lib/libx.so.1"}, p.run);
}

// Golden tests: read tests/fixtures and tests/golden relative to the working
// directory, so run `zig build test` from the repository root.
fn golden(name: []const u8, files: []const []const u8) !void {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    var inputs = std.ArrayList(Input).init(a);
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "tests/fixtures/{s}/{s}.mopm.json", .{ name, f });
        try inputs.append(try loadInput(a, path));
    }
    const p = try plan(a, inputs.items);
    var out = std.ArrayList(u8).init(a);
    try render(p, out.writer());
    const want = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "tests/golden/{s}.txt", .{name}), 1 << 20);
    try std.testing.expectEqualStrings(want, out.items);
}

test "golden: chain (a shared library needing a both-flavour library)" {
    try golden("chain", &.{ "http_client", "crypto" });
}

test "golden: missing transitive library" {
    try golden("missing", &.{"http_client"});
}

test "golden: duplicate owner" {
    try golden("dup", &.{ "pkg_a", "pkg_b" });
}

test "golden: static only" {
    try golden("static", &.{"staticpkg"});
}
