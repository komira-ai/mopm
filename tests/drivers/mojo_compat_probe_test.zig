//! Probe: how Mojo's compiled packages (`.mojoc`) behave across compiler
//! versions. Two compilers run side by side, komira's pinned Mojo 1.0.0 and a
//! Mojo 1.1.0 pinned in this repository's BUCK; both reach the driver as
//! exec_tools (MOJO_TOOLCHAIN_10, MOJO_TOOLCHAIN_11); the C compiler is the one of
//! mojo_env.zig.
//!
//! Fixtures (tests/compat): `probe_neutral` (two ordinary definitions, valid
//! in both), `probe_new` (syntax of 1.1 only), `probe_old` (uses the `fn` and
//! `alias` keywords, which 1.1 removed) and `consumer.mojo`, which imports
//! `probe_neutral`.
//!
//!   a. precompile `probe_neutral` with each compiler; read the header of
//!      each `.mojoc` (magic, format byte, the 64 hex characters of the
//!      fingerprint) and count where that fingerprint occurs: in each
//!      compiler's binary and in each compiler's shipped std.mojoc;
//!   b. cross-load: build the consumer with one compiler against the other's
//!      `.mojoc`, both directions;
//!   c. source compatibility: `probe_old` and `probe_new` with each compiler;
//!      then what the compiler checks: copies of each `.mojoc` with the
//!      version bytes (8..10, read as major.minor.patch) or the fingerprint
//!      replaced by the other compiler's, consumed by each compiler;
//!   d. control: the consumer built by 1.0 against the 1.0 `.mojoc` succeeds
//!      and runs. Without that the cross-load results would mean nothing.
//!
//! What this asserts: the control, and that every header parses (magic
//! `MPKG`, a NUL after 64 lowercase hex characters). Everything else is an
//! observation: an `OBS` line on standard output and a line of the results
//! file ($KOMIRA_TEST_WORK/mojo_compat_results.txt), not a pass or fail.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

/// The header of a `.mojoc`, as observed on 1.0.0 and 1.1.0: the magic, a
/// format byte, 13 bytes this probe does not interpret (printed raw), the
/// fingerprint as 64 lowercase hex characters, and a NUL.
const fp_offset = 18;
const fp_len = 64;
const Header = struct {
    format: u8,
    raw_5_18: [13]u8,
    fp: [fp_len]u8,
};

fn parseHeader(bytes: []const u8) !Header {
    if (bytes.len < fp_offset + fp_len + 1) return error.ShortHeader;
    if (!std.mem.eql(u8, bytes[0..4], "MPKG")) return error.BadMagic;
    for (bytes[fp_offset .. fp_offset + fp_len]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.FingerprintNotHex;
    }
    if (bytes[fp_offset + fp_len] != 0) return error.NoNulAfterFingerprint;
    var hd: Header = undefined;
    hd.format = bytes[4];
    @memcpy(&hd.raw_5_18, bytes[5..fp_offset]);
    @memcpy(&hd.fp, bytes[fp_offset .. fp_offset + fp_len]);
    return hd;
}

/// How often `needle` occurs in the file at `path` (read in chunks: the
/// compilers are over 100 MB).
fn countIn(a: Allocator, path: []const u8, needle: []const u8) !usize {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const chunk = 1 << 20;
    const buf = try a.alloc(u8, chunk + needle.len);
    defer a.free(buf);
    var count: usize = 0;
    var carry: usize = 0;
    while (true) {
        const n = try f.read(buf[carry..][0..chunk]);
        if (n == 0) break;
        const have = carry + n;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, buf[0..have], at, needle)) |i| {
            count += 1;
            at = i + needle.len;
        }
        // Keep the tail that could start a match across the chunk boundary.
        carry = @min(needle.len - 1, have);
        std.mem.copyForwards(u8, buf[0..carry], buf[have - carry .. have]);
    }
    return count;
}

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    work: []const u8,
    results: std.ArrayList(u8),

    /// One observation: stdout and the results file.
    fn obs(c: *Cx, comptime f: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(c.a, f, args);
        std.debug.print("OBS {s}\n", .{line});
        try c.results.appendSlice(line);
        try c.results.append('\n');
    }

    /// An observation of a program's exit and output.
    fn obsRan(c: *Cx, name: []const u8, r: h.Ran) !void {
        const text = if (r.text.len > 4000) r.text[0..4000] else r.text;
        try c.obs("{s}: exit {d}{s}; output {d} bytes:\n{s}\n-- end {s}", .{
            name, r.code, if (r.signaled) " (signal)" else "", r.text.len, text, name,
        });
    }
};

const Comp = struct {
    tag: []const u8, // "1.0" or "1.1"
    m: mojo_env.Mojo,
    prefix: []const u8,

    fn init(a: Allocator, tag: []const u8, var_name: []const u8, work: []const u8) !Comp {
        var m = try mojo_env.Mojo.initFor(a, var_name);
        // Each compiler its own HOME and caches.
        const scratch = try h.join(a, &.{ work, "scratch", tag });
        try std.fs.cwd().makePath(scratch);
        try m.base.put("HOME", scratch);
        try m.base.put("TMPDIR", scratch);
        try m.base.put("XDG_CACHE_HOME", scratch);
        try m.base.put("MODULAR_CACHE_DIR", scratch);
        const prefix = try h.join(a, &.{ work, "prefix", tag });
        try m.prefix(prefix, true);
        return .{ .tag = tag, .m = m, .prefix = prefix };
    }

    fn mojo(self: *const Comp, args: []const []const u8) !h.Ran {
        return self.m.run(self.prefix, args, null);
    }

    fn precompile(self: *const Comp, src: []const u8, out: []const u8) !h.Ran {
        return self.mojo(&.{ "precompile", src, "-o", out });
    }

    fn std_mojoc(self: *const Comp, a: Allocator) ![]const u8 {
        return h.join(a, &.{ self.m.tc, "lib/mojo/std.mojoc" });
    }

    fn binary(self: *const Comp, a: Allocator) ![]const u8 {
        return h.join(a, &.{ self.m.tc, "bin/mojo" });
    }
};

fn ok(r: h.Ran) bool {
    return !r.signaled and r.code == 0;
}

test "mojo compat: compiled packages across Mojo 1.0.0 and 1.1.0" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    try h.watchdog(1500);
    var rep = h.Report{};
    const work = try h.toolPathAbs(a, "KOMIRA_TEST_WORK");
    var c = Cx{ .a = a, .rep = &rep, .work = work, .results = std.ArrayList(u8).init(a) };
    run(&c) catch |e| {
        std.debug.print("FAIL driver stopped: {s}\n", .{@errorName(e)});
        rep.failures += 1;
    };
    // The results file and the whole text again, so the end of the log has it.
    h.writeFile(try h.join(a, &.{ work, "mojo_compat_results.txt" }), c.results.items) catch {};
    std.debug.print("==== mojo_compat results ====\n{s}==== end ====\n", .{c.results.items});
    try rep.finish();
}

fn run(c: *Cx) !void {
    const a = c.a;
    const work = c.work;
    const c10 = try Comp.init(a, "1.0", "MOJO_TOOLCHAIN_10", work);
    const c11 = try Comp.init(a, "1.1", "MOJO_TOOLCHAIN_11", work);
    const comps = [_]*const Comp{ &c10, &c11 };

    for (comps) |k| {
        const v = try k.mojo(&.{"--version"});
        try c.obsRan(try h.fmt(a, "{s}: mojo --version", .{k.tag}), v);
    }
    // The 1.0 and 1.1 toolchains are what their names say.
    {
        const v10 = try c10.mojo(&.{"--version"});
        const v11 = try c11.mojo(&.{"--version"});
        c.rep.check("MOJO_TOOLCHAIN_10 is Mojo 1.0.0", ok(v10) and h.contains(v10.text, "1.0.0"), "wrong compiler");
        c.rep.check("MOJO_TOOLCHAIN_11 is Mojo 1.1.0", ok(v11) and h.contains(v11.text, "1.1.0"), "wrong compiler");
    }

    const fx = try h.join(a, &.{ work, "tests/compat" });
    const out_dirs = [_][]const u8{ try h.join(a, &.{ work, "out/1.0" }), try h.join(a, &.{ work, "out/1.1" }) };
    for (out_dirs) |d| try std.fs.cwd().makePath(d);

    // ---- a. headers and fingerprints
    var neutral: [2][]const u8 = undefined;
    var hdrs: [2]?Header = .{ null, null };
    for (comps, 0..) |k, i| {
        neutral[i] = try h.join(a, &.{ out_dirs[i], "probe_neutral.mojoc" });
        const r = try k.precompile(try h.join(a, &.{ fx, "fixtures/probe_neutral" }), neutral[i]);
        try c.obsRan(try h.fmt(a, "a. {s}: precompile probe_neutral", .{k.tag}), r);
        c.rep.check(try h.fmt(a, "a. {s} precompiles probe_neutral", .{k.tag}), ok(r), "precompile failed");
        if (!ok(r)) continue;
        const bytes = try h.readFile(a, neutral[i]);
        const hd = parseHeader(bytes) catch |e| {
            c.rep.check(try h.fmt(a, "a. {s} header parses", .{k.tag}), false, @errorName(e));
            continue;
        };
        c.rep.check(try h.fmt(a, "a. {s} header parses", .{k.tag}), true, "");
        hdrs[i] = hd;
        try c.obs("a. {s} probe_neutral.mojoc: {d} bytes, magic MPKG, format byte {d}, bytes 5..18 hex {s}, fingerprint {s}", .{
            k.tag, bytes.len, hd.format, std.fmt.fmtSliceHexLower(&hd.raw_5_18), hd.fp,
        });
    }
    // The shipped std.mojoc of each compiler: its header too.
    var std_hdrs: [2]?Header = .{ null, null };
    for (comps, 0..) |k, i| {
        const bytes = try h.readFile(a, try k.std_mojoc(a));
        const hd = parseHeader(bytes) catch |e| {
            c.rep.check(try h.fmt(a, "a. {s} std.mojoc header parses", .{k.tag}), false, @errorName(e));
            continue;
        };
        c.rep.check(try h.fmt(a, "a. {s} std.mojoc header parses", .{k.tag}), true, "");
        std_hdrs[i] = hd;
        try c.obs("a. {s} shipped std.mojoc: {d} bytes, format byte {d}, bytes 5..18 hex {s}, fingerprint {s}", .{
            k.tag, bytes.len, hd.format, std.fmt.fmtSliceHexLower(&hd.raw_5_18), hd.fp,
        });
    }
    // Where does each fingerprint occur? Rows: the fingerprints; columns:
    // the files searched.
    for (comps, 0..) |k, i| {
        const files = [_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "mojo 1.0 binary", .path = try c10.binary(a) },
            .{ .name = "mojo 1.1 binary", .path = try c11.binary(a) },
            .{ .name = "std.mojoc 1.0", .path = try c10.std_mojoc(a) },
            .{ .name = "std.mojoc 1.1", .path = try c11.std_mojoc(a) },
            .{ .name = "probe_neutral 1.0", .path = neutral[0] },
            .{ .name = "probe_neutral 1.1", .path = neutral[1] },
        };
        const rows = [_]struct { name: []const u8, hd: ?Header }{
            .{ .name = "probe_neutral", .hd = hdrs[i] },
            .{ .name = "std.mojoc", .hd = std_hdrs[i] },
        };
        for (rows) |row| {
            const hd = row.hd orelse continue;
            for (files) |f| {
                const n = try countIn(a, f.path, &hd.fp);
                try c.obs("a. fingerprint of {s} built by {s} occurs {d} time(s) in {s}", .{ row.name, k.tag, n, f.name });
            }
        }
    }
    if (hdrs[0]) |x| if (hdrs[1]) |y| {
        try c.obs("a. the two probe_neutral fingerprints are {s}", .{if (std.mem.eql(u8, &x.fp, &y.fp)) "EQUAL" else "different"});
    };
    if (hdrs[0]) |x| if (std_hdrs[0]) |y| {
        try c.obs("a. 1.0: probe_neutral fingerprint {s} the std.mojoc fingerprint", .{if (std.mem.eql(u8, &x.fp, &y.fp)) "equals" else "differs from"});
    };
    if (hdrs[1]) |x| if (std_hdrs[1]) |y| {
        try c.obs("a. 1.1: probe_neutral fingerprint {s} the std.mojoc fingerprint", .{if (std.mem.eql(u8, &x.fp, &y.fp)) "equals" else "differs from"});
    };

    // ---- d. control, then b. cross-load
    const consumer = try h.join(a, &.{ fx, "consumer.mojo" });
    var control_ok = false;
    for (comps, 0..) |k, i| {
        for (comps, 0..) |other, j| {
            const exe = try h.join(a, &.{ work, try h.fmt(a, "out/consumer_{s}_on_{s}", .{ k.tag, other.tag }) });
            const r = try k.mojo(&.{ "build", "-I", out_dirs[j], consumer, "-o", exe });
            const what = if (i == j) "d. control" else "b. cross-load";
            try c.obsRan(try h.fmt(a, "{s}: mojo {s} builds the consumer against the {s} .mojoc", .{ what, k.tag, other.tag }), r);
            if (ok(r)) {
                var empty = std.process.EnvMap.init(a);
                const run_r = try h.run(a, &.{exe}, &empty, .{});
                try c.obsRan(try h.fmt(a, "{s}: the {s}-on-{s} consumer runs", .{ what, k.tag, other.tag }), run_r);
                if (i == 0 and j == 0) control_ok = ok(run_r) and h.contains(run_r.text, "probe ok 5 5");
            }
        }
    }
    c.rep.check("d. control: 1.0 builds and runs the consumer against its own .mojoc", control_ok, "the control failed; the cross-load results mean nothing");

    // ---- b2. what is checked: header fields replaced by the other build's
    if (hdrs[0] != null and hdrs[1] != null) {
        const files = [2][]const u8{ try h.readFile(a, neutral[0]), try h.readFile(a, neutral[1]) };
        try c.obs("b2. header bytes 8..10 read as version: 1.0 file {d}.{d}.{d}, 1.1 file {d}.{d}.{d}", .{
            files[0][8], files[0][9], files[0][10], files[1][8], files[1][9], files[1][10],
        });
        const Case = struct { name: []const u8, file: usize, what: enum { version, fp }, consumer: usize };
        const cases = [_]Case{
            .{ .name = "1.0 file, fingerprint of 1.1", .file = 0, .what = .fp, .consumer = 0 },
            .{ .name = "1.0 file, fingerprint of 1.1", .file = 0, .what = .fp, .consumer = 1 },
            .{ .name = "1.0 file, version bytes of 1.1", .file = 0, .what = .version, .consumer = 1 },
            .{ .name = "1.1 file, fingerprint of 1.0", .file = 1, .what = .fp, .consumer = 1 },
            .{ .name = "1.1 file, fingerprint of 1.0", .file = 1, .what = .fp, .consumer = 0 },
            .{ .name = "1.1 file, version bytes of 1.0", .file = 1, .what = .version, .consumer = 0 },
        };
        for (cases, 0..) |cs, n| {
            const bytes = try a.dupe(u8, files[cs.file]);
            const other = files[1 - cs.file];
            switch (cs.what) {
                .fp => @memcpy(bytes[fp_offset .. fp_offset + fp_len], other[fp_offset .. fp_offset + fp_len]),
                .version => @memcpy(bytes[8..11], other[8..11]),
            }
            const d = try h.join(a, &.{ work, try h.fmt(a, "out/patched_{d}", .{n}) });
            try h.writeFile(try h.join(a, &.{ d, "probe_neutral.mojoc" }), bytes);
            const k = comps[cs.consumer];
            const exe = try h.join(a, &.{ d, "consumer" });
            const r = try k.mojo(&.{ "build", "-I", d, consumer, "-o", exe });
            try c.obsRan(try h.fmt(a, "b2. {s} consumed by mojo {s}", .{ cs.name, k.tag }), r);
        }
    }

    // ---- c. source compatibility
    const names = [_][]const u8{ "probe_neutral", "probe_old", "probe_fn", "probe_new" };
    for (names) |n| {
        for (comps) |k| {
            const out = try h.join(a, &.{ work, try h.fmt(a, "out/src_{s}_{s}.mojoc", .{ n, k.tag }) });
            const r = try k.precompile(try h.join(a, &.{ fx, "fixtures", n }), out);
            try c.obsRan(try h.fmt(a, "c. mojo {s} precompiles {s}", .{ k.tag, n }), r);
        }
    }
}

// ------------------------------------------------------ the parser's own tests

test "header parser: layout of an observed header" {
    var b: [fp_offset + fp_len + 1]u8 = undefined;
    @memcpy(b[0..4], "MPKG");
    b[4] = 2;
    @memset(b[5..fp_offset], 0);
    @memset(b[fp_offset .. fp_offset + fp_len], 'a');
    b[fp_offset + fp_len] = 0;
    const hd = try parseHeader(&b);
    try std.testing.expectEqual(@as(u8, 2), hd.format);
    try std.testing.expectEqualStrings("a" ** fp_len, &hd.fp);
    b[fp_offset + 3] = 'G';
    try std.testing.expectError(error.FingerprintNotHex, parseHeader(&b));
}
