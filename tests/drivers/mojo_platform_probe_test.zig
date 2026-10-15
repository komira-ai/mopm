//! Probe: is a compiled package (`.mojoc`) platform-independent? Run on an
//! x86_64 Linux worker only, with komira's pinned Mojo 1.0.0 and the Mojo
//! 1.1.0 of this repository's BUCK (MOJO_TOOLCHAIN_10, MOJO_TOOLCHAIN_11).
//!
//!   1. the target-related options in `mojo build --help` and `mojo precompile
//!      --help`, and how often target option names occur in the binary;
//!   2. precompile `probe_neutral` once (default target), then build the
//!      consumer from it as an object file (`--emit object`) for the host
//!      and for other triples with `--target-triple`; the object's target is
//!      read from its header (ELF e_machine, Mach-O cputype);
//!   3. precompile with `--target-triple` for each triple: size and sha256
//!      against the default, and the first differing byte;
//!   4. a fixture with comptime platform branches (four spellings are tried,
//!      the first that precompiles is used): which marker strings the `.mojoc`
//!      and each object contain;
//!   5. determinism: the same precompile in separate directories (and, as a
//!      second target with the same source, in a separate action); sha256 of
//!      each is an OBS line, so the two actions can be compared in the logs.
//!
//! What this asserts: both toolchains are what they say, the 1.0 precompile
//! yields an MPKG file, and the control (the host build of the consumer to an
//! object) succeeds and has e_machine 62 (x86_64). Everything else is an `OBS`
//! line on standard error and in the results block at the end; read it from
//! the build event log as mojo_compat_probe_test.zig describes.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");
const Allocator = std.mem.Allocator;

const EM_X86_64: u16 = 62;

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
        carry = @min(needle.len - 1, have);
        std.mem.copyForwards(u8, buf[0..carry], buf[have - carry .. have]);
    }
    return count;
}

fn countBytes(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, hay, at, needle)) |i| {
        n += 1;
        at = i + needle.len;
    }
    return n;
}

fn sha(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn elfMachine(bytes: []const u8) ?u16 {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return null;
    const endian: std.builtin.Endian = if (bytes[5] == 2) .big else .little;
    return std.mem.readInt(u16, bytes[18..20], endian);
}

fn kindOf(a: Allocator, bytes: []const u8) ![]const u8 {
    if (elfMachine(bytes)) |m| {
        return h.fmt(a, "ELF class {d} data {d} e_machine {d} (0x{x})", .{ bytes[4], bytes[5], m, m });
    }
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..4], "\xcf\xfa\xed\xfe")) {
        const t = std.mem.readInt(u32, bytes[4..8], .little);
        return h.fmt(a, "Mach-O 64 little-endian cputype 0x{x}", .{t});
    }
    const n = @min(bytes.len, 16);
    return h.fmt(a, "neither ELF nor Mach-O 64; first {d} bytes {s}", .{ n, std.fmt.fmtSliceHexLower(bytes[0..n]) });
}

const markers = [_][]const u8{ "MARK_LINUX", "MARK_MACOS", "MARK_OTHER", "ARCH_X86", "ARCH_ARM", "ARCH_OTHER" };

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    work: []const u8,
    tag_out: []const u8 = "",
    results: std.ArrayList(u8),

    fn obs(c: *Cx, comptime f: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(c.a, f, args);
        std.debug.print("OBS {s}\n", .{line});
        try c.results.appendSlice(line);
        try c.results.append('\n');
    }

    fn obsRan(c: *Cx, name: []const u8, r: h.Ran) !void {
        const text = if (r.text.len > 3000) r.text[0..3000] else r.text;
        try c.obs("{s}: exit {d}{s}; output {d} bytes:\n{s}\n-- end {s}", .{
            name, r.code, if (r.signaled) " (signal)" else "", r.text.len, text, name,
        });
    }

    /// The marker counts of a file's bytes.
    fn obsMarkers(c: *Cx, name: []const u8, bytes: []const u8) !void {
        var line = std.ArrayList(u8).init(c.a);
        for (markers) |m| try line.writer().print(" {s}={d}", .{ m, countBytes(bytes, m) });
        try c.obs("{s}: markers{s}", .{ name, line.items });
    }
};

const Comp = struct {
    tag: []const u8,
    m: mojo_env.Mojo,
    prefix: []const u8,

    fn init(a: Allocator, tag: []const u8, var_name: []const u8, work: []const u8) !Comp {
        var m = try mojo_env.Mojo.initFor(a, var_name);
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

    fn binary(self: *const Comp, a: Allocator) ![]const u8 {
        return h.join(a, &.{ self.m.tc, "bin/mojo" });
    }

    /// `mojo precompile src -o dir/<name>.mojoc [--target-triple t]`.
    fn precompile(self: *const Comp, a: Allocator, src: []const u8, dir: []const u8, name: []const u8, triple: ?[]const u8) !h.Ran {
        try std.fs.cwd().makePath(dir);
        const out = try h.join(a, &.{ dir, try h.fmt(a, "{s}.mojoc", .{name}) });
        var args = std.ArrayList([]const u8).init(a);
        try args.appendSlice(&.{ "precompile", src, "-o", out });
        if (triple) |t| try args.appendSlice(&.{ "--target-triple", t });
        return self.mojo(args.items);
    }

    /// `mojo build -I dir consumer --emit object -o out [--target-triple t]`.
    fn buildObj(self: *const Comp, a: Allocator, dir: []const u8, consumer: []const u8, out: []const u8, triple: ?[]const u8) !h.Ran {
        return self.buildObjCpu(a, dir, consumer, out, triple, null);
    }

    fn buildObjCpu(self: *const Comp, a: Allocator, dir: []const u8, consumer: []const u8, out: []const u8, triple: ?[]const u8, cpu: ?[]const u8) !h.Ran {
        var args = std.ArrayList([]const u8).init(a);
        try args.appendSlice(&.{ "build", "-I", dir, consumer, "--emit", "object", "-o", out });
        if (triple) |t| try args.appendSlice(&.{ "--target-triple", t });
        if (cpu) |u| try args.appendSlice(&.{ "--target-cpu", u });
        return self.mojo(args.items);
    }
};

fn ok(r: h.Ran) bool {
    return !r.signaled and r.code == 0;
}

/// The lines of `text` that mention one of the words, lowercase compare.
fn lines(a: Allocator, text: []const u8, words: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const low = try std.ascii.allocLowerString(a, l);
        for (words) |w| {
            if (std.mem.indexOf(u8, low, w) != null) {
                try out.appendSlice(l);
                try out.append('\n');
                break;
            }
        }
    }
    return out.items;
}

test "mojo platform: is a .mojoc platform-independent" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    try h.watchdog(1700);
    var rep = h.Report{};
    const work = try h.toolPathAbs(a, "KOMIRA_TEST_WORK");
    var c = Cx{ .a = a, .rep = &rep, .work = work, .results = std.ArrayList(u8).init(a) };
    run(&c) catch |e| {
        std.debug.print("FAIL driver stopped: {s}\n", .{@errorName(e)});
        rep.failures += 1;
    };
    h.writeFile(try h.join(a, &.{ work, "mojo_platform_results.txt" }), c.results.items) catch {};
    std.debug.print("==== mojo_platform results ====\n{s}==== end ====\n", .{c.results.items});
    try rep.finish();
}

const triples = [_][]const u8{
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "arm64-apple-darwin",
    "aarch64-apple-darwin",
    "arm64-apple-macosx",
};

fn run(c: *Cx) !void {
    const a = c.a;
    const work = c.work;
    const c10 = try Comp.init(a, "1.0", "MOJO_TOOLCHAIN_10", work);
    const c11 = try Comp.init(a, "1.1", "MOJO_TOOLCHAIN_11", work);
    const comps = [_]*const Comp{ &c10, &c11 };
    {
        const v10 = try c10.mojo(&.{"--version"});
        const v11 = try c11.mojo(&.{"--version"});
        c.rep.check("MOJO_TOOLCHAIN_10 is Mojo 1.0.0", ok(v10) and h.contains(v10.text, "1.0.0"), "wrong compiler");
        c.rep.check("MOJO_TOOLCHAIN_11 is Mojo 1.1.0", ok(v11) and h.contains(v11.text, "1.1.0"), "wrong compiler");
    }
    const fx = try h.join(a, &.{ work, "tests/compat" });
    const consumer = try h.join(a, &.{ fx, "consumer.mojo" });
    const consumer_cond = try h.join(a, &.{ fx, "consumer_cond.mojo" });

    // ---- 1. options
    const words = [_][]const u8{ "target", "emit", "triple", "cpu", "march", "feature", "arch", "sysroot", "accelerator" };
    for (comps) |k| {
        for ([_][]const u8{ "build", "precompile" }) |sub| {
            const r = try k.mojo(&.{ sub, "--help" });
            try c.obs("1. {s}: mojo {s} --help: exit {d}, {d} bytes; lines mentioning target, emit, triple, cpu, march, feature, arch, sysroot, accelerator:\n{s}-- end", .{
                k.tag, sub, r.code, r.text.len, try lines(a, r.text, &words),
            });
        }
        const bin = try k.binary(a);
        for ([_][]const u8{ "--target-triple", "--target-cpu", "--target-features", "--target-accelerator", "--emit", "--march", "--mcpu", "--sysroot" }) |needle| {
            try c.obs("1. {s}: binary contains \"{s}\" {d} time(s)", .{ k.tag, needle, try countIn(a, bin, needle) });
        }
    }

    // ---- 2. one precompile on x86_64, consumers for several targets
    var ctl_machine: ?u16 = null;
    var neutral_default: [2][]const u8 = .{ "", "" };
    var cond_default: [2][]const u8 = .{ "", "" };
    var cond_src: [2][]const u8 = .{ "", "" }; // chosen fixture directory per compiler
    for (comps, 0..) |k, i| {
        const dir = try h.join(a, &.{ work, "out", k.tag, "default" });
        const r = try k.precompile(a, try h.join(a, &.{ fx, "fixtures/probe_neutral" }), dir, "probe_neutral", null);
        try c.obsRan(try h.fmt(a, "2. {s}: precompile probe_neutral, default target", .{k.tag}), r);
        c.rep.check(try h.fmt(a, "2. {s} precompiles probe_neutral", .{k.tag}), ok(r), "precompile failed");
        if (!ok(r)) continue;
        const bytes = try h.readFile(a, try h.join(a, &.{ dir, "probe_neutral.mojoc" }));
        neutral_default[i] = bytes;
        c.rep.check(try h.fmt(a, "2. {s} .mojoc starts with MPKG", .{k.tag}), bytes.len > 4 and std.mem.eql(u8, bytes[0..4], "MPKG"), "not a .mojoc");
        try c.obs("2. {s}: probe_neutral.mojoc {d} bytes sha256 {s}", .{ k.tag, bytes.len, &sha(bytes) });

        // host build (no flag), then each triple
        var cases = std.ArrayList(?[]const u8).init(a);
        try cases.append(null);
        for (triples) |t| try cases.append(t);
        for (cases.items) |tr| {
            const label = tr orelse "(no flag, host)";
            const obj = try h.join(a, &.{ work, "out", k.tag, try h.fmt(a, "consumer_{s}.o", .{tr orelse "host"}) });
            const b = try k.buildObj(a, dir, consumer, obj, tr);
            try c.obsRan(try h.fmt(a, "2. {s}: build consumer to object, target {s}", .{ k.tag, label }), b);
            const ob = h.readFile(a, obj) catch {
                try c.obs("2. {s} target {s}: no object file written", .{ k.tag, label });
                continue;
            };
            try c.obs("2. {s} target {s}: object {d} bytes, {s}", .{ k.tag, label, ob.len, try kindOf(a, ob) });
            if (tr == null and i == 0) ctl_machine = elfMachine(ob);
        }
    }
    c.rep.check("2. control: the 1.0 host object has e_machine 62 (x86_64)", ctl_machine != null and ctl_machine.? == EM_X86_64, "the control object is not x86_64 ELF; every target reading below means nothing");

    // ---- 3. precompile with a target flag
    for (comps, 0..) |k, i| {
        const fixtures = [_]struct { name: []const u8, src: []const u8, imp: []const u8 }{
            .{ .name = "probe_neutral", .src = "fixtures/probe_neutral", .imp = "probe_neutral" },
        };
        for (fixtures) |fxr| {
            const base = neutral_default[i];
            if (base.len == 0) continue;
            for (triples) |t| {
                const dir = try h.join(a, &.{ work, "out", k.tag, try h.fmt(a, "pc_{s}", .{t}) });
                const r = try k.precompile(a, try h.join(a, &.{ fx, fxr.src }), dir, fxr.imp, t);
                try c.obsRan(try h.fmt(a, "3. {s}: precompile {s} --target-triple {s}", .{ k.tag, fxr.name, t }), r);
                const bytes = h.readFile(a, try h.join(a, &.{ dir, try h.fmt(a, "{s}.mojoc", .{fxr.imp}) })) catch {
                    try c.obs("3. {s} {s}: no .mojoc written", .{ k.tag, t });
                    continue;
                };
                const same = std.mem.eql(u8, bytes, base);
                var first: usize = 0;
                const lim = @min(bytes.len, base.len);
                while (first < lim and bytes[first] == base[first]) first += 1;
                var ndiff: usize = 0;
                for (0..lim) |q| {
                    if (bytes[q] != base[q]) ndiff += 1;
                }
                try c.obs("3. {s} {s} {s}: {d} bytes (default {d}) sha256 {s}: {s}; first difference at offset {d}, {d} differing bytes over the common length", .{
                    k.tag, fxr.name, t, bytes.len, base.len, &sha(bytes), if (same) "IDENTICAL to the default" else "DIFFERENT from the default", first, ndiff,
                });
            }
        }
    }

    // ---- 4. comptime platform branches
    const cands = [_][]const u8{ "cond_a", "cond_b", "cond_c", "cond_d" };
    for (comps, 0..) |k, i| {
        for (cands) |cn| {
            const dir = try h.join(a, &.{ work, "out", k.tag, "try", cn });
            const r = try k.precompile(a, try h.join(a, &.{ fx, "fixtures", cn }), dir, "probe_cond", null);
            try c.obsRan(try h.fmt(a, "4. {s}: precompile {s}", .{ k.tag, cn }), r);
            if (ok(r) and cond_src[i].len == 0) {
                cond_src[i] = cn;
                cond_default[i] = try h.readFile(a, try h.join(a, &.{ dir, "probe_cond.mojoc" }));
            }
        }
        if (cond_src[i].len == 0) {
            try c.obs("4. {s}: no spelling of the comptime-conditional fixture compiled", .{k.tag});
            continue;
        }
        try c.obs("4. {s}: using fixture {s}; .mojoc {d} bytes sha256 {s}", .{ k.tag, cond_src[i], cond_default[i].len, &sha(cond_default[i]) });
        try c.obsMarkers(try h.fmt(a, "4. {s} cond .mojoc (default precompile)", .{k.tag}), cond_default[i]);
        const dir = try h.join(a, &.{ work, "out", k.tag, "try", cond_src[i] });
        var cases = std.ArrayList(?[]const u8).init(a);
        try cases.append(null);
        for (triples) |t| try cases.append(t);
        for (cases.items) |tr| {
            const label = tr orelse "(no flag, host)";
            const obj = try h.join(a, &.{ work, "out", k.tag, try h.fmt(a, "cond_{s}.o", .{tr orelse "host"}) });
            const b = try k.buildObj(a, dir, consumer_cond, obj, tr);
            try c.obsRan(try h.fmt(a, "4. {s}: build cond consumer to object, target {s}", .{ k.tag, label }), b);
            const ob = h.readFile(a, obj) catch continue;
            try c.obs("4. {s} target {s}: object {d} bytes, {s}", .{ k.tag, label, ob.len, try kindOf(a, ob) });
            try c.obsMarkers(try h.fmt(a, "4. {s} cond object, target {s}", .{ k.tag, label }), ob);
        }
        // The aarch64 targets again with an explicit CPU: `--target-triple`
        // alone keeps the host CPU's features (has_neon was false above).
        for ([_][2][]const u8{
            .{ "aarch64-unknown-linux-gnu", "neoverse-n1" },
            .{ "arm64-apple-darwin", "apple-m1" },
        }) |tc| {
            const obj = try h.join(a, &.{ work, "out", k.tag, try h.fmt(a, "cond_cpu_{s}.o", .{tc[0]}) });
            const b = try k.buildObjCpu(a, try h.join(a, &.{ work, "out", k.tag, "try", cond_src[i] }), consumer_cond, obj, tc[0], tc[1]);
            try c.obsRan(try h.fmt(a, "4. {s}: build cond consumer for {s} --target-cpu {s}", .{ k.tag, tc[0], tc[1] }), b);
            const ob = h.readFile(a, obj) catch continue;
            try c.obs("4. {s} target {s} cpu {s}: {s}", .{ k.tag, tc[0], tc[1], try kindOf(a, ob) });
            try c.obsMarkers(try h.fmt(a, "4. {s} cond object, target {s} cpu {s}", .{ k.tag, tc[0], tc[1] }), ob);
        }
        // Precompiled for another target, built for the same one.
        for ([_][]const u8{ "aarch64-unknown-linux-gnu", "arm64-apple-darwin" }) |t| {
            const pdir = try h.join(a, &.{ work, "out", k.tag, "condpc", t });
            const r = try k.precompile(a, try h.join(a, &.{ fx, "fixtures", cond_src[i] }), pdir, "probe_cond", t);
            try c.obsRan(try h.fmt(a, "4. {s}: precompile cond --target-triple {s}", .{ k.tag, t }), r);
            const pb = h.readFile(a, try h.join(a, &.{ pdir, "probe_cond.mojoc" })) catch continue;
            try c.obs("4. {s} cond .mojoc for {s}: {d} bytes sha256 {s}; {s} the default", .{ k.tag, t, pb.len, &sha(pb), if (std.mem.eql(u8, pb, cond_default[i])) "IDENTICAL to" else "DIFFERENT from" });
            try c.obsMarkers(try h.fmt(a, "4. {s} cond .mojoc for {s}", .{ k.tag, t }), pb);
            const obj = try h.join(a, &.{ work, "out", k.tag, try h.fmt(a, "condpc_{s}.o", .{t}) });
            const b = try k.buildObj(a, pdir, consumer_cond, obj, t);
            try c.obsRan(try h.fmt(a, "4. {s}: build cond consumer for {s} from the {s}-precompiled .mojoc", .{ k.tag, t, t }), b);
            const ob = h.readFile(a, obj) catch continue;
            try c.obs("4. {s} object from the {s}-precompiled .mojoc: {s}", .{ k.tag, t, try kindOf(a, ob) });
            try c.obsMarkers(try h.fmt(a, "4. {s} cond object (precompiled and built for {s})", .{ k.tag, t }), ob);
        }
    }

    // ---- 5. determinism
    for (comps) |k| {
        for ([_][]const u8{ "run_a", "run_b" }) |tagdir| {
            const dir = try h.join(a, &.{ work, "out", k.tag, "det", tagdir });
            const r = try k.precompile(a, try h.join(a, &.{ fx, "fixtures/probe_neutral" }), dir, "probe_neutral", null);
            if (!ok(r)) {
                try c.obsRan(try h.fmt(a, "5. {s} {s}", .{ k.tag, tagdir }), r);
                continue;
            }
            const bytes = try h.readFile(a, try h.join(a, &.{ dir, "probe_neutral.mojoc" }));
            try c.obs("5. {s} probe_neutral {s}: {d} bytes sha256 {s}", .{ k.tag, tagdir, bytes.len, &sha(bytes) });
        }
    }

    // Same source bytes at two different paths: does the path reach the .mojoc?
    for (comps) |k| {
        for ([_][]const u8{ "x", "a_much_longer_directory_name_for_the_source_copy" }) |sub| {
            const src = try h.join(a, &.{ work, "srccopy", sub, "probe_neutral" });
            try h.copyTree(a, try h.join(a, &.{ fx, "fixtures/probe_neutral" }), src);
            const dir = try h.join(a, &.{ work, "out", k.tag, "det", sub });
            const r = try k.precompile(a, src, dir, "probe_neutral", null);
            if (!ok(r)) {
                try c.obsRan(try h.fmt(a, "5. {s} source at {s}", .{ k.tag, sub }), r);
                continue;
            }
            const bytes = try h.readFile(a, try h.join(a, &.{ dir, "probe_neutral.mojoc" }));
            try c.obs("5. {s} probe_neutral from a copy of the source at srccopy/{s}: {d} bytes sha256 {s}", .{ k.tag, sub, bytes.len, &sha(bytes) });
        }
    }
}
