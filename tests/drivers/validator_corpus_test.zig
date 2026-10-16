//! //:validator_corpus: the committed validator corpus (tests/validator_corpus) is exactly what the generator
//! (validator_corpus.zig) makes. A difference fails the test and prints the generator's version of every file
//! that differs, in base64 (`BASE64 <path>` ... `END BASE64 <path>`), so a corpus can be made from a CI log
//! without running the generator on a machine; `zig run tests/drivers/validator_corpus.zig -- tests/validator_corpus`
//! is the other way.
//!
//! The test reads the files at their paths in the repository (the target stages them), and the generator needs
//! no input.

const std = @import("std");
const gen = @import("validator_corpus.zig");
const Allocator = std.mem.Allocator;

const ROOT = "tests/validator_corpus";

fn dump(a: Allocator, path: []const u8, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(buf, bytes);
    std.debug.print("BASE64 {s}\n", .{path});
    var i: usize = 0;
    while (i < buf.len) : (i += 100) std.debug.print("{s}\n", .{buf[i..@min(i + 100, buf.len)]});
    std.debug.print("END BASE64 {s}\n", .{path});
}

/// Whether the committed file at `path` holds exactly `want`; if not, prints the generator's bytes.
fn matches(a: Allocator, path: []const u8, want: []const u8) !bool {
    const have = std.fs.cwd().readFileAlloc(a, path, 256 * 1024 * 1024) catch {
        std.debug.print("MISSING {s}\n", .{path});
        try dump(a, path, want);
        return false;
    };
    if (std.mem.eql(u8, have, want)) return true;
    std.debug.print("DIFFERS {s} (committed {d} bytes, generated {d} bytes)\n", .{ path, have.len, want.len });
    try dump(a, path, want);
    return false;
}

test "the committed corpus is what the generator makes, file for file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const corpus = try gen.build(a);
    try std.testing.expect(corpus.cases.len > 100);

    var bad: usize = 0;
    if (!try matches(a, ROOT ++ "/cases.json", try gen.casesJson(a, corpus))) bad += 1;
    for (corpus.archives) |x| {
        const path = try std.fmt.allocPrint(a, "{s}/archives/{s}", .{ ROOT, x.name });
        if (!try matches(a, path, x.bytes)) bad += 1;
    }

    // No file the generator does not make.
    var dir = std.fs.cwd().openDir(ROOT ++ "/archives", .{ .iterate = true }) catch {
        std.debug.print("MISSING {s}/archives\n", .{ROOT});
        return error.CorpusDiffers;
    };
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        var known = false;
        for (corpus.archives) |x| {
            if (std.mem.eql(u8, x.name, e.name)) known = true;
        }
        if (!known) {
            std.debug.print("STRAY {s}/archives/{s}: the generator does not make it\n", .{ ROOT, e.name });
            bad += 1;
        }
    }

    // Every case names an archive that exists, and every archive is used.
    for (corpus.cases) |k| {
        var found = false;
        for (corpus.archives) |x| {
            if (std.mem.eql(u8, x.name, k.archive)) found = true;
        }
        if (!found) {
            std.debug.print("case {s} names the archive {s}, which does not exist\n", .{ k.id, k.archive });
            bad += 1;
        }
    }
    for (corpus.archives) |x| {
        var used = false;
        for (corpus.cases) |k| {
            if (std.mem.eql(u8, x.name, k.archive)) used = true;
        }
        if (!used) {
            std.debug.print("archive {s} is used by no case\n", .{x.name});
            bad += 1;
        }
    }
    // Case ids are unique.
    for (corpus.cases, 0..) |k, i| {
        for (corpus.cases[0..i]) |j| {
            if (std.mem.eql(u8, j.id, k.id)) {
                std.debug.print("case id {s} appears twice\n", .{k.id});
                bad += 1;
            }
        }
    }
    if (bad != 0) return error.CorpusDiffers;
}
