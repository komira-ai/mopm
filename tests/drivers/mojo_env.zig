//! The Mojo toolchain of komira (`komira//tools/build/toolchains:mojo_compiler`,
//! an unpacked, sha256-pinned Mojo 1.0.0) made into an environment prefix as
//! mopm expects one (`bin/mojo`, `lib/`, `lib/mojo/*.mojoc`,
//! `share/max/modular.cfg`), plus the `cc` that `mojo build` links through.
//! Shared by the end-to-end drivers; replaces the pixi environment of
//! tests/e2e/pixi.toml, which the farm cannot create (no network, no pixi).
//!
//! The Buck2 target gives the drivers, as exec_tools (absolute paths):
//!   MOJO_TOOLCHAIN  the unpacked toolchain directory
//!   ZIG_DIR         komira's zig directory (run ZIG_DIR/zig)
//!   CC_SHIM         tests/drivers/zigcc.zig, built (becomes `cc`)
//!   MOPM            the built CLI
//! and BUILDRULES_TEST_WORK, a writable directory.
//!
//! `zig build test-e2e` (build.zig) runs the same drivers natively, on the
//! GitHub runners (Linux x86_64, Linux aarch64, macOS arm64). With no CC_SHIM
//! the driver is native: MOJO_TOOLCHAIN is a pixi environment (mojo 1.0.0,
//! tests/e2e/pixi.toml, `-Dmojo-env=<dir>`), `cc` is the system C compiler, the
//! run keeps the runner's HOME and TMPDIR, and MOPM_E2E_SRC names the
//! repository's tests/e2e, which is copied into the work directory (the
//! drivers edit the fixtures in place).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const is_macos = builtin.os.tag == .macos;

/// The extension of a shared library on the machine the driver runs on.
pub const ext = if (is_macos) "dylib" else "so";

/// `lib<name>.<ext>`.
pub fn libName(a: Allocator, name: []const u8) ![]u8 {
    return h.fmt(a, "lib{s}.{s}", .{ name, ext });
}

/// The `cc` arguments (before `-o <out> <src>`) that make `lib<name>.<ext>`
/// with its soname (macOS: the install name `@rpath/lib<name>.dylib`) and no
/// run path.
pub fn shlibFlags(a: Allocator, name: []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    if (is_macos) {
        out[0] = "-dynamiclib";
        out[1] = "-install_name";
        out[2] = try h.fmt(a, "@rpath/lib{s}.dylib", .{name});
    } else {
        out[0] = "-shared";
        out[1] = "-fPIC";
        out[2] = try h.fmt(a, "-Wl,-soname,lib{s}.so", .{name});
    }
    return out;
}

/// The variable that makes the loader preload libraries.
pub const preload_var = if (is_macos) "DYLD_INSERT_LIBRARIES" else "LD_PRELOAD";

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
        return initAt(a, try h.toolPathAbs(a, "MOJO_TOOLCHAIN"));
    }

    /// As `init`, with the toolchain directory `tc` named by the caller: the unit tier of a driver lays a stand-in
    /// compiler there (tests/drivers/fake_toolchain.zig) and keeps everything else (the `cc`, the environment).
    pub fn initAt(a: Allocator, tc: []const u8) !Mojo {
        const work = try h.toolPathAbs(a, "BUILDRULES_TEST_WORK");
        const shim: ?[]const u8 = std.process.getEnvVarOwned(a, "CC_SHIM") catch null;
        const native = shim == null;
        const cc_dir = try h.join(a, &.{ work, "cc" });
        try fs.cwd().makePath(cc_dir);
        const cc_path = try h.join(a, &.{ cc_dir, "cc" });
        if (shim) |sh| {
            try fs.cwd().copyFile(sh, fs.cwd(), cc_path, .{});
            const f = try fs.cwd().openFile(cc_path, .{});
            defer f.close();
            try f.chmod(0o755);
        } else {
            // Native: the system C compiler, as `cc`, in the directory
            // that comes first on PATH.
            const sys = try findOnPath(a, "cc");
            try fs.cwd().symLink(sys, cc_path, .{});
            if (std.process.getEnvVarOwned(a, "MOPM_E2E_SRC")) |src| {
                try h.copyTree(a, src, try h.join(a, &.{ work, "tests/e2e" }));
            } else |_| {}
        }
        var env = std.process.EnvMap.init(a);
        const scratch = try h.join(a, &.{ work, "scratch" });
        try fs.cwd().makePath(scratch);
        // The action's own PATH (busybox applets) stays last: the fixtures'
        // children (`sleep`) are found there; there is no /bin/sh.
        const outer_path = std.process.getEnvVarOwned(a, "PATH") catch try a.dupe(u8, "");
        try env.put("PATH", try h.fmt(a, "{s}:{s}/bin:{s}", .{ cc_dir, tc, outer_path }));
        if (native) {
            // The runner's own home, temporary directory and developer
            // directory: the compiler and the debugger on macOS need them.
            for ([_][]const u8{ "HOME", "TMPDIR", "USER", "LANG", "DEVELOPER_DIR", "SDKROOT" }) |k| {
                if (std.process.getEnvVarOwned(a, k)) |v| try env.put(k, v) else |_| {}
            }
            try env.put("MODULAR_CRASH_REPORTING_ENABLED", "false");
            // No LLDB_DEBUGSERVER_PATH here: `mopm repl` finds Xcode's debugserver on macOS 14 itself, and a driver that
            // set it for mopm would hide a user's crash. A control that runs the stock `mojo repl` calls `macDebugserver`.
            return .{ .a = a, .tc = tc, .work = work, .cc_dir = cc_dir, .base = env };
        }
        const zig_dir = try h.toolPathAbs(a, "ZIG_DIR");
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

    /// Whether this is the native run (build.zig), not the farm's.
    pub fn isNative(self: *const Mojo) bool {
        return self.base.get("MOPM_ZIG") == null;
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
        if (self.isNative()) {
            // A pixi environment: every package the compiler ships.
            var mdir = try cwd.openDir(try h.join(a, &.{ tc_lib, "mojo" }), .{ .iterate = true });
            defer mdir.close();
            var mit = mdir.iterate();
            while (try mit.next()) |e| {
                if (e.kind == .directory or !std.mem.endsWith(u8, e.name, ".mojoc")) continue;
                try cwd.symLink(try h.join(a, &.{ tc_lib, "mojo", e.name }), try h.join(a, &.{ dest, "lib/mojo", e.name }), .{});
            }
        } else {
            try cwd.symLink(try h.join(a, &.{ self.tc, "lib/mojo/std.mojoc" }), try h.join(a, &.{ dest, "lib/mojo/std.mojoc" }), .{});
        }
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

/// The first executable called `name` on PATH, absolute.
fn findOnPath(a: Allocator, name: []const u8) ![]u8 {
    const path = std.process.getEnvVarOwned(a, "PATH") catch return error.NoCompiler;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |d| {
        const cand = try h.join(a, &.{ d, name });
        fs.cwd().access(cand, .{}) catch continue;
        return cand;
    }
    std.debug.print("no `{s}` on PATH: the native drivers link through the system C compiler\n", .{name});
    return error.NoCompiler;
}

/// macOS 14 (Darwin 23): the debugserver in the mojo 1.0.0 package crashes
/// (SIGSEGV in dyld4::FileRecord::getPath) when the REPL starts, and the REPL
/// then prints "couldn't find a REPL for mojo". Point lldb at Xcode's
/// debugserver there; macOS 15 runs the packaged one. `mopm repl` does this
/// itself (src/core/debugserver.zig), so the drivers do not set it for mopm;
/// a control that runs the stock `mojo repl` itself calls this for its own
/// environment.
pub fn macDebugserver(a: Allocator, env: *std.process.EnvMap) !void {
    const rel = try h.run(a, &.{ "/usr/bin/uname", "-r" }, env, .{ .capture = .stdout });
    const dot = std.mem.indexOfScalar(u8, rel.text, '.') orelse return;
    const major = std.fmt.parseInt(u32, rel.text[0..dot], 10) catch return;
    if (major > 23) return;
    const xs = try h.run(a, &.{ "/usr/bin/xcode-select", "-p" }, env, .{ .capture = .stdout });
    const dev = h.chomp(xs.text);
    const dbg = try h.fmt(a, "{s}/../SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver", .{dev});
    fs.cwd().access(dbg, .{}) catch {
        std.debug.print("macOS 14: no Xcode debugserver at {s}\n", .{dbg});
        return error.NoDebugserver;
    };
    try env.put("LLDB_DEBUGSERVER_PATH", dbg);
    std.debug.print("note: macOS 14, LLDB_DEBUGSERVER_PATH={s}\n", .{dbg});
}

// ------------------------------------------------------------------- ELF

/// `readDynamic` on Linux; on macOS the same facts from `otool`: the
/// basenames of the libraries `otool -L` lists, and whether `otool -l` shows
/// an LC_RPATH.
pub fn dynamic(a: Allocator, path: []const u8) !Dynamic {
    if (!is_macos) return readDynamic(a, path);
    var env = try h.environ(a);
    const libs = try h.run(a, &.{ "/usr/bin/otool", "-L", path }, &env, .{ .capture = .stdout });
    const cmds = try h.run(a, &.{ "/usr/bin/otool", "-l", path }, &env, .{ .capture = .stdout });
    var needed = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, libs.text, '\n');
    _ = lines.next(); // "<path>:"
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        const end = std.mem.indexOf(u8, l, " (") orelse l.len;
        if (end == 0) continue;
        try needed.append(fs.path.basename(l[0..end]));
    }
    const rp = h.contains(cmds.text, "LC_RPATH");
    return .{ .needed = needed.items, .has_run_path = rp, .has_rpath = rp, .has_runpath = false };
}

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
