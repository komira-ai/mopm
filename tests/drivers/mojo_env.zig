//! The Mojo toolchain of komira (`komira//tools/build/toolchains:mojo_compiler`,
//! an unpacked, sha256-pinned Mojo 1.0.0) made into an environment prefix as
//! mopm expects one (`bin/mojo`, `lib/`, `lib/mojo/*.mojoc`,
//! `share/max/modular.cfg`), plus the `cc` that `mojo build` links through.
//! Shared by the end-to-end drivers; replaces the environment `mopm sync`
//! makes in CI (tests/e2e/mopm.toml), which the farm cannot create (no network).
//!
//! The Buck2 target gives the drivers, as exec_tools (absolute paths):
//!   MOJO_TOOLCHAIN  the unpacked toolchain directory
//!   ZIG_DIR         komira's zig directory (run ZIG_DIR/zig)
//!   CC_SHIM         tests/drivers/zigcc.zig, built (becomes `cc`)
//!   MOPM            the built CLI
//! and KOMIRA_TEST_WORK, a writable directory.

const std = @import("std");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const Mojo = struct {
    a: Allocator,
    /// The unpacked toolchain.
    tc: []const u8,
    /// The writable work directory.
    work: []const u8,
    /// A directory holding `cc`.
    cc_dir: []const u8,
    /// The environment of every program the drivers start: PATH = cc_dir and
    /// the toolchain's bin, scratch HOME/TMPDIR, the toolchain's lib on
    /// LD_LIBRARY_PATH, no crash reporter. No MODULAR_HOME, CONDA_PREFIX.
    base: std.process.EnvMap,

    pub fn init(a: Allocator) !Mojo {
        const work = try h.toolPathAbs(a, "KOMIRA_TEST_WORK");
        const tc = try h.toolPathAbs(a, "MOJO_TOOLCHAIN");
        const zig_dir = try h.toolPathAbs(a, "ZIG_DIR");
        const shim = try h.toolPathAbs(a, "CC_SHIM");
        const cc_dir = try h.join(a, &.{ work, "cc" });
        try fs.cwd().makePath(cc_dir);
        const cc_path = try h.join(a, &.{ cc_dir, "cc" });
        try fs.cwd().copyFile(shim, fs.cwd(), cc_path, .{});
        {
            const f = try fs.cwd().openFile(cc_path, .{});
            defer f.close();
            try f.chmod(0o755);
        }
        var env = std.process.EnvMap.init(a);
        const scratch = try h.join(a, &.{ work, "scratch" });
        try fs.cwd().makePath(scratch);
        // The action's own PATH (busybox applets) stays last: the fixtures'
        // children (`sleep`) are found there; there is no /bin/sh.
        const outer_path = std.process.getEnvVarOwned(a, "PATH") catch try a.dupe(u8, "");
        try env.put("PATH", try h.fmt(a, "{s}:{s}/bin:{s}", .{ cc_dir, tc, outer_path }));
        try env.put("HOME", scratch);
        try env.put("TMPDIR", scratch);
        try env.put("XDG_CACHE_HOME", scratch);
        try env.put("MODULAR_CACHE_DIR", scratch);
        try env.put("LD_LIBRARY_PATH", try h.fmt(a, "{s}/lib", .{tc}));
        try env.put("MODULAR_CRASH_REPORTING_ENABLED", "false");
        try env.put("KGEN_CompilerRT_AsyncRT_ParallelismLevel", "1");
        try env.put("MOPM_ZIG", try h.fmt(a, "{s}/zig", .{zig_dir}));
        try env.put("ZIG_GLOBAL_CACHE_DIR", try h.join(a, &.{ scratch, "zig-global" }));
        try env.put("ZIG_LOCAL_CACHE_DIR", try h.join(a, &.{ scratch, "zig-local" }));
        return .{ .a = a, .tc = tc, .work = work, .cc_dir = cc_dir, .base = env };
    }

    pub fn freshEnv(self: *const Mojo) !std.process.EnvMap {
        return h.cloneEnv(self.a, &self.base);
    }

    /// A prefix at `dest` with the toolchain's compiler and libraries linked
    /// in. `rpath_in_prefix`: modular.cfg's `shared_libs` names the prefix's
    /// own lib as run path of every program mojo links (the layout of a pixi
    /// environment, where natives sit beside the compiler's libraries); else
    /// the toolchain's lib (a split prefix, whose natives mopm must name
    /// itself). The import path is `dest/lib/mojo`.
    pub fn prefix(self: *const Mojo, dest: []const u8, rpath_in_prefix: bool) !void {
        const a = self.a;
        const cwd = fs.cwd();
        try cwd.makePath(try h.join(a, &.{ dest, "bin" }));
        try cwd.makePath(try h.join(a, &.{ dest, "lib/mojo" }));
        try cwd.makePath(try h.join(a, &.{ dest, "share/max" }));
        try cwd.symLink(try h.join(a, &.{ self.tc, "bin/mojo" }), try h.join(a, &.{ dest, "bin/mojo" }), .{});
        const tc_lib = try h.join(a, &.{ self.tc, "lib" });
        var dir = try cwd.openDir(tc_lib, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind == .directory) continue; // lib/mojo is linked below
            try cwd.symLink(try h.join(a, &.{ tc_lib, e.name }), try h.join(a, &.{ dest, "lib", e.name }), .{});
        }
        try cwd.symLink(try h.join(a, &.{ self.tc, "lib/mojo/std.mojoc" }), try h.join(a, &.{ dest, "lib/mojo/std.mojoc" }), .{});
        // modular.cfg: the toolchain's, rendered for this toolchain's path,
        // with the import path and (pixi layout) the run path moved.
        const cfg = try h.readFile(a, try h.join(a, &.{ self.tc, "share/max/modular.cfg" }));
        var out = std.ArrayList(u8).init(a);
        var lines = std.mem.splitScalar(u8, cfg, '\n');
        while (lines.next()) |raw| {
            const line = try std.mem.replaceOwned(u8, a, raw, "@@MOJO_TOOLCHAIN_ROOT@@", self.tc);
            if (std.mem.startsWith(u8, line, "import_path = ")) {
                try out.writer().print("import_path = {s}/lib/mojo\n", .{dest});
            } else if (std.mem.startsWith(u8, line, "shared_libs = ") and rpath_in_prefix) {
                try out.writer().print("shared_libs = -Xlinker,-rpath,-Xlinker,{s}/lib;\n", .{dest});
            } else if (raw.len != 0 or lines.peek() != null) {
                try out.writer().print("{s}\n", .{line});
            }
        }
        try h.writeFile(try h.join(a, &.{ dest, "share/max/modular.cfg" }), out.items);
    }

    /// `<prefix>/bin/mojo <args>` with MODULAR_HOME set as mopm sets it.
    pub fn run(self: *const Mojo, prefix_dir: []const u8, args: []const []const u8, cwd: ?[]const u8) !h.Ran {
        var e = try self.freshEnv();
        try e.put("MODULAR_HOME", try h.fmt(self.a, "{s}/share/max", .{prefix_dir}));
        const argv = try self.a.alloc([]const u8, args.len + 1);
        argv[0] = try h.join(self.a, &.{ prefix_dir, "bin/mojo" });
        @memcpy(argv[1..], args);
        return h.run(self.a, argv, &e, .{ .cwd = cwd });
    }

    /// `cc <args>` (zig cc), output returned.
    pub fn cc(self: *const Mojo, args: []const []const u8) !h.Ran {
        var e = try self.freshEnv();
        const argv = try self.a.alloc([]const u8, args.len + 1);
        argv[0] = try h.join(self.a, &.{ self.cc_dir, "cc" });
        @memcpy(argv[1..], args);
        return h.run(self.a, argv, &e, .{});
    }
};

// ------------------------------------------------------------------- ELF

/// What the dynamic section of a 64-bit little-endian ELF file records:
/// the needed sonames and whether it carries a run path (DT_RPATH or
/// DT_RUNPATH). Replaces `readelf -d`, which the farm does not have.
pub const Dynamic = struct {
    needed: []const []const u8,
    has_run_path: bool,
    has_rpath: bool = false,
    has_runpath: bool = false,

    pub fn needs(self: Dynamic, soname: []const u8) bool {
        for (self.needed) |n| if (std.mem.eql(u8, n, soname)) return true;
        return false;
    }
};

pub fn readDynamic(a: Allocator, path: []const u8) !Dynamic {
    const bytes = try h.readFile(a, path);
    const rd = std.mem.readInt;
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return error.NotElf64Le;
    const shoff = rd(u64, bytes[0x28..0x30], .little);
    const shentsize = rd(u16, bytes[0x3A..0x3C], .little);
    const shnum = rd(u16, bytes[0x3C..0x3E], .little);
    var needed = std.ArrayList([]const u8).init(a);
    var run_path = false;
    var rpath = false;
    var runpath = false;
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const sh = bytes[shoff + i * shentsize ..][0..shentsize];
        if (rd(u32, sh[4..8], .little) != 6) continue; // SHT_DYNAMIC
        const off = rd(u64, sh[0x18..0x20], .little);
        const size = rd(u64, sh[0x20..0x28], .little);
        const link = rd(u32, sh[0x28..0x2C], .little);
        const str = bytes[shoff + @as(usize, link) * shentsize ..][0..shentsize];
        const str_off = rd(u64, str[0x18..0x20], .little);
        var p: usize = 0;
        while (p + 16 <= size) : (p += 16) {
            const tag = rd(i64, bytes[off + p ..][0..8], .little);
            const val = rd(u64, bytes[off + p + 8 ..][0..8], .little);
            switch (tag) {
                0 => break,
                1 => {
                    const s = bytes[str_off + val ..];
                    try needed.append(s[0..std.mem.indexOfScalar(u8, s, 0).?]);
                },
                15 => {
                    run_path = true;
                    rpath = true;
                },
                29 => {
                    run_path = true;
                    runpath = true;
                },
                else => {},
            }
        }
    }
    return .{ .needed = needed.items, .has_run_path = run_path, .has_rpath = rpath, .has_runpath = runpath };
}
