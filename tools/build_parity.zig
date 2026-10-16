//! build.zig and BUCK describe the same build, or this fails.
//!
//! `zig build` (build.zig) is a contributor's quick path; Buck2 (BUCK) is what
//! the farm builds. Both name the same Zig root files, executables, modules and
//! unit tests, and a change to one without the other would let them drift: a
//! test that `zig build test` runs but no Buck2 target does, or the reverse.
//! This file reads both, writes what each one says in one form, and compares.
//! It also checks that every zig_test of BUCK is welded (listed in the
//! `unit_tests` of something, so a failing test blocks a build) and that
//! every root file exists.
//!
//! The canonical lines:
//!   exe <name> <root>        an executable and its root source file
//!   module <name> <root>     a module imported by name, and its root
//!   test <root>              one unit-test binary of that root (repeats count)
//!   import <root> <name>     the file at <root> imports the module <name>
//!
//! What it reads, as the two files are written: build.zig with one
//! `b.addExecutable(.{`, `b.addTest(.{` or `b.createModule(.{` per block, a
//! `.name` and a `.root_source_file = b.path("...")` inside it, and
//! `<var>.root_module.addImport("<name>", <module var>)`; BUCK with one
//! `zig_exe(`, `zig_module(` or `zig_test(` call per block starting a line,
//! `name = "..."`, `src = "..."`, `deps = [...]` and `unit_tests = [...]` each
//! on one line. A call whose first line carries `buck-only` is a target of
//! the Buck2 build with no counterpart in build.zig (a helper program, a test
//! driver that needs the built programs): it is left out of the comparison.
//! A form it does not understand is a finding, not a pass.
//!
//! Run as a zig_test by Buck2 (//:build_parity), with build.zig and BUCK as
//! inputs; `zig test tools/build_parity.zig` from the repository root runs it
//! too. The mutants below show it can go red.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayList([]const u8);

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The first "..." in `s`.
fn firstQuoted(s: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const rest = s[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..close];
}

/// Whether `line` is `<key> = ...` (the key whole, then `=`).
fn isKey(line: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, line, key)) return false;
    const rest = std.mem.trimLeft(u8, line[key.len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

/// Every "..." in `s`, as target names: `":a"` is `a`.
fn quotedNames(a: Allocator, s: []const u8, out: *List) !void {
    var rest = s;
    while (firstQuoted(rest)) |q| {
        const name = if (std.mem.lastIndexOfScalar(u8, q, ':')) |c| q[c + 1 ..] else q;
        if (name.len > 0) try out.append(name);
        const open = std.mem.indexOfScalar(u8, rest, '"').?;
        rest = rest[open + 1 + q.len + 1 ..];
    }
    _ = a;
}

const Kind = enum { exe, test_, module };

fn zigFacts(a: Allocator, text: []const u8, found: *List) !List {
    var out = List.init(a);
    var var_roots = std.StringHashMap([]const u8).init(a);
    var open: ?Kind = null;
    var var_name: []const u8 = "";
    var name: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (open) |kind| {
            if (std.mem.startsWith(u8, line, ".name")) name = firstQuoted(line);
            if (std.mem.startsWith(u8, line, ".root_source_file")) root = firstQuoted(line);
            if (std.mem.eql(u8, line, "});")) {
                open = null;
                const r = root orelse {
                    try found.append(try std.fmt.allocPrint(a, "build.zig:{d}: a block with no .root_source_file = b.path(\"...\")", .{n}));
                    continue;
                };
                try var_roots.put(var_name, r);
                switch (kind) {
                    .exe => {
                        const nm = name orelse {
                            try found.append(try std.fmt.allocPrint(a, "build.zig:{d}: an executable with no .name", .{n}));
                            continue;
                        };
                        try out.append(try std.fmt.allocPrint(a, "exe {s} {s}", .{ nm, r }));
                    },
                    .test_ => try out.append(try std.fmt.allocPrint(a, "test {s}", .{r})),
                    .module => {},
                }
            }
            continue;
        }
        const started: ?Kind = if (contains(line, "b.addExecutable(.{")) .exe else if (contains(line, "b.addTest(.{")) .test_ else if (contains(line, "b.createModule(.{")) .module else null;
        if (started) |k| {
            open = k;
            name = null;
            root = null;
            var_name = try std.fmt.allocPrint(a, "?{d}", .{n});
            if (std.mem.startsWith(u8, line, "const ")) {
                const rest = line["const ".len..];
                const end = std.mem.indexOfAny(u8, rest, " =") orelse rest.len;
                var_name = rest[0..end];
            }
            continue;
        }
        if (std.mem.indexOf(u8, line, ".root_module.addImport(")) |at| {
            const importer = line[0..at];
            const args = line[at + ".root_module.addImport(".len ..];
            const iname = firstQuoted(args) orelse "";
            const comma = std.mem.indexOfScalar(u8, args, ',') orelse args.len;
            const after = std.mem.trim(u8, args[@min(comma + 1, args.len)..], " \t");
            const mvar = after[0 .. std.mem.indexOfScalar(u8, after, ')') orelse after.len];
            const iroot = var_roots.get(importer);
            const mroot = var_roots.get(mvar);
            if (iroot == null or mroot == null) {
                try found.append(try std.fmt.allocPrint(a, "build.zig:{d}: addImport of {s}: {s} or {s} is not a block of this file", .{ n, iname, importer, mvar }));
                continue;
            }
            try out.append(try std.fmt.allocPrint(a, "import {s} {s}", .{ iroot.?, iname }));
            try out.append(try std.fmt.allocPrint(a, "module {s} {s}", .{ iname, mroot.? }));
        }
    }
    if (open != null) try found.append("build.zig: a block never closes");
    return out;
}

fn buckFacts(a: Allocator, text: []const u8, found: *List) !List {
    var out = List.init(a);
    var welded = std.StringHashMap(void).init(a);
    var test_names = List.init(a);
    var in_call = false;
    var kind: Kind = .exe;
    var buck_only = false;
    var name: []const u8 = "";
    var src: []const u8 = "";
    var deps = List.init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!in_call) {
            if (std.mem.startsWith(u8, line, "for ") or std.mem.startsWith(u8, raw, "[")) {
                try found.append(try std.fmt.allocPrint(a, "BUCK:{d}: a loop or comprehension: only plain calls are read", .{n}));
            }
            const started: ?Kind = if (std.mem.startsWith(u8, raw, "zig_exe(")) .exe else if (std.mem.startsWith(u8, raw, "zig_test(")) .test_ else if (std.mem.startsWith(u8, raw, "zig_module(")) .module else null;
            if (started) |k| {
                in_call = true;
                kind = k;
                buck_only = contains(raw, "buck-only");
                name = "";
                src = "";
                deps.clearRetainingCapacity();
            }
            continue;
        }
        if (isKey(line, "name")) name = firstQuoted(line) orelse "";
        if (isKey(line, "src")) src = firstQuoted(line) orelse "";
        if (isKey(line, "deps")) {
            deps.clearRetainingCapacity();
            try quotedNames(a, line, &deps);
        }
        if (isKey(line, "unit_tests")) {
            var names = List.init(a);
            try quotedNames(a, line, &names);
            for (names.items) |w| try welded.put(w, {});
        }
        if (std.mem.startsWith(u8, raw, ")")) {
            in_call = false;
            if (name.len == 0 or src.len == 0) {
                try found.append(try std.fmt.allocPrint(a, "BUCK:{d}: a call with no name or src", .{n}));
                continue;
            }
            if (buck_only) continue;
            switch (kind) {
                .test_ => {
                    try out.append(try std.fmt.allocPrint(a, "test {s}", .{src}));
                    try test_names.append(name);
                },
                .exe => try out.append(try std.fmt.allocPrint(a, "exe {s} {s}", .{ name, src })),
                .module => try out.append(try std.fmt.allocPrint(a, "module {s} {s}", .{ name, src })),
            }
            for (deps.items) |d| try out.append(try std.fmt.allocPrint(a, "import {s} {s}", .{ src, d }));
        }
    }
    if (in_call) try found.append("BUCK: a call never closes");
    for (test_names.items) |t| {
        if (!welded.contains(t)) {
            try found.append(try std.fmt.allocPrint(a, "BUCK: zig_test {s} is in no unit_tests list, so nothing waits for it", .{t}));
        }
    }
    return out;
}

/// Sorted; a line twice is one, except `test` lines (two test binaries of one
/// root are two). A module imported by two files is one `module` line.
fn canon(a: Allocator, facts: List) !List {
    std.mem.sort([]const u8, facts.items, {}, lessStr);
    var out = List.init(a);
    for (facts.items) |f| {
        const dup = out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], f);
        if (dup and !std.mem.startsWith(u8, f, "test ")) continue;
        try out.append(f);
    }
    return out;
}

/// What differs between build.zig and BUCK, one line each; empty when they
/// agree. `files` also checks that the root files exist (relative to the
/// working directory, the repository root).
pub fn findings(a: Allocator, build_zig: []const u8, buck: []const u8, files: bool) !List {
    var out = List.init(a);
    const z = try canon(a, try zigFacts(a, build_zig, &out));
    const b = try canon(a, try buckFacts(a, buck, &out));
    var i: usize = 0;
    var j: usize = 0;
    while (i < z.items.len or j < b.items.len) {
        if (j >= b.items.len or (i < z.items.len and std.mem.lessThan(u8, z.items[i], b.items[j]))) {
            try out.append(try std.fmt.allocPrint(a, "build.zig has `{s}` and BUCK does not", .{z.items[i]}));
            i += 1;
        } else if (i >= z.items.len or std.mem.lessThan(u8, b.items[j], z.items[i])) {
            try out.append(try std.fmt.allocPrint(a, "BUCK has `{s}` and build.zig does not", .{b.items[j]}));
            j += 1;
        } else {
            i += 1;
            j += 1;
        }
    }
    if (files) {
        for (z.items) |f| {
            var it = std.mem.tokenizeScalar(u8, f, ' ');
            const kind = it.next().?;
            const first = it.next().?;
            const path = if (std.mem.eql(u8, kind, "test") or std.mem.eql(u8, kind, "import")) first else it.next().?;
            if (std.fs.cwd().access(path, .{})) |_| {} else |_| {
                try out.append(try std.fmt.allocPrint(a, "{s} is named by build.zig and is not a file", .{path}));
            }
        }
    }
    return out;
}

// ------------------------------------------------------------------- tests

fn report(list: List) void {
    for (list.items) |l| std.debug.print("  {s}\n", .{l});
}

/// Whether some finding contains `needle`.
fn mentions(list: List, needle: []const u8) bool {
    for (list.items) |l| if (contains(l, needle)) return true;
    return false;
}

fn readAll(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

test "the repository's build.zig and BUCK agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try findings(a, try readAll(a, "build.zig"), try readAll(a, "BUCK"), true);
    report(f);
    try std.testing.expectEqual(@as(usize, 0), f.items.len);
}

// The mutants: a copy of the real pair with one defect, which must be found,
// and be found for the reason it was planted.

test "mutant: a test added to build.zig and not to BUCK" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = try readAll(a, "build.zig");
    const end = std.mem.lastIndexOfScalar(u8, zig, '}').?;
    const mutant = try std.mem.concat(a, u8, &.{ zig[0..end],
        \\
        \\    const toml_tests = b.addTest(.{
        \\        .root_source_file = b.path("src/core/toml.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    test_step.dependOn(&b.addRunArtifact(toml_tests).step);
        \\}
        \\
    });
    const f = try findings(a, mutant, try readAll(a, "BUCK"), false);
    try std.testing.expect(mentions(f, "build.zig has `test src/core/toml.zig`"));
}

test "mutant: a zig_test removed from BUCK" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const buck = try readAll(a, "BUCK");
    const at = std.mem.indexOf(u8, buck, "name = \"cli_test\"").?;
    const start = std.mem.lastIndexOf(u8, buck[0..at], "zig_test(").?;
    const stop = at + std.mem.indexOf(u8, buck[at..], "\n)\n").? + 3;
    const mutant = try std.mem.concat(a, u8, &.{ buck[0..start], buck[stop..] });
    const f = try findings(a, try readAll(a, "build.zig"), mutant, false);
    try std.testing.expect(mentions(f, "build.zig has `test src/cli/main.zig`"));
}

test "mutant: a zig_test that no unit_tests list names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mutant = try std.mem.replaceOwned(u8, a, try readAll(a, "BUCK"), "\":fake_test\"", "\":nothing\"");
    const f = try findings(a, try readAll(a, "build.zig"), mutant, false);
    try std.testing.expect(mentions(f, "zig_test fake_test is in no unit_tests list"));
}

test "mutant: an executable renamed in BUCK" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mutant = try std.mem.replaceOwned(u8, a, try readAll(a, "BUCK"), "name = \"mopm-fake-registry\"", "name = \"mopm-fake\"");
    const f = try findings(a, try readAll(a, "build.zig"), mutant, false);
    try std.testing.expect(mentions(f, "build.zig has `exe mopm-fake-registry"));
}

test "mutant: a module root that differs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = try readAll(a, "build.zig");
    const at = std.mem.indexOf(u8, zig, "src/core/mopm_core.zig").?;
    const mutant = try std.mem.concat(a, u8, &.{ zig[0..at], "src/core/toml.zig", zig[at + "src/core/mopm_core.zig".len ..] });
    const f = try findings(a, mutant, try readAll(a, "BUCK"), false);
    try std.testing.expect(mentions(f, "module mopm_core"));
}

test "mutant: a root file that does not exist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = try readAll(a, "build.zig");
    const buck = try readAll(a, "BUCK");
    const f = try findings(a, try std.mem.replaceOwned(u8, a, zig, "registry/fake/main.zig", "registry/fake/gone.zig"), try std.mem.replaceOwned(u8, a, buck, "registry/fake/main.zig", "registry/fake/gone.zig"), true);
    try std.testing.expect(mentions(f, "registry/fake/gone.zig is named by build.zig and is not a file"));
}
