//! mopm command line. `--version`, `link-plan`, `metadata`, `new`, `init`, and
//! `build`/`run`/`repl`, which run the stock `mojo` with the environment's native
//! libraries linked or preloaded (or print that command with `--print-cmd`).

const std = @import("std");
const core = @import("mopm_core");
const mojo_cmd = core.mojo_cmd;
const test_cmd = @import("test_cmd.zig");
const registry_cmd = @import("registry_cmd.zig");
const publish_cmd = @import("publish_cmd.zig");
const install_cmd = @import("install_cmd.zig");
const plan_cmd = @import("plan_cmd.zig");
const unit_cmd = @import("unit_cmd.zig");
const yank_cmd = @import("yank_cmd.zig");
const stage_cmd = @import("stage_cmd.zig");
const build_cmd = @import("build_cmd.zig");
const bin_run = @import("bin_run.zig");

/// The release version, from the build (`zig build -Dversion=`; the dev default in build_options.zig).
pub const version = @import("build_options").version;

const planned = [_][]const u8{
    "cov", "check", "export", "launch",
};

pub fn isPlanned(cmd: []const u8) bool {
    for (planned) |p| {
        if (std.mem.eql(u8, p, cmd)) return true;
    }
    return false;
}

const usage =
    \\usage: mopm <command> [args]
    \\
    \\working today:
    \\  --version               print the version
    \\  link-plan <file>...     print the link plan for installed packages,
    \\                          given their <name>.mopm.json files
    \\  metadata [mopm.toml]    check a package manifest and print it as JSON
    \\  new <name> [--lib|--bin]
    \\                          make a package in a new directory <name>
    \\  init [--lib|--bin] [--name <name>]
    \\                          make a package in this directory
    \\  build <file.mojo> [-o <out>]
    \\  build [--out-dir <dir>] with no program: the [targets] of mopm.toml, the
    \\                          library as <dir>/<name>.mojoc and each program as
    \\                          <dir>/<name> (default dir: target/build)
    \\  run <file.mojo>
    \\  run --bin <package>:<program>   a program an installed package ships
    \\  repl [--debugserver <path>]
    \\                          run the stock mojo of the environment, with its
    \\                          native libraries linked or preloaded; the exit
    \\                          status is mojo's. On macOS 14 and older mopm
    \\                          points lldb at Xcode's debugserver, which works
    \\                          where the one packaged with mojo crashes
    \\  test [<path>...]        run the tests of tests/**/test_*.mojo and
    \\                          src/**/tests/test_*.mojo, one process per test
    \\                          (--timeout <s>, --memory <MiB>, --format json,
    \\                          --junit <file>, --retries <n>, --deny-flaky;
    \\                          select with -- <pattern>..., --skip, --exact,
    \\                          --ignored; see docs/mopm-test.md)
    \\  test --list [<path>...] list them; --check also builds each file and
    \\                          compares the list with the binary's `--skip-all`
    \\                          listing (--strict-discovery, --prefix <dir>)
    \\  login | logout | whoami [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\                          an account on a registry (device login through
    \\                          GitHub; the token is kept in credentials.json,
    \\                          mode 0600, and never printed)
    \\  pack --compiler <mojo version> --mojoc [<subdir>=]<file>... [-o <dir>]
    \\                          write the package as a .conda per subdir
    \\                          (noarch, linux-64, linux-aarch64, osx-arm64) and
    \\                          print its sha256; --manifest <file> names another
    \\                          mopm.toml; --native <id>=<subdir>:<file> gives the
    \\                          static archive of a [native.<id>] for one subdir
    \\  publish [pack options] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\          [--readme <file>] [--dry-run] [--oidc]
    \\                          pack and publish to a registry; the token is
    \\                          $MOPM_TOKEN, else the one 'mopm login' stored,
    \\                          or with --oidc (inside GitHub Actions, with
    \\                          'id-token: write') one from the job's identity;
    \\                          --dry-run packs and prints what would be sent
    \\  publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>]
    \\          [--wait <seconds>] [--dry-run] [--oidc] [--no-commit | --abort]
    \\                          publish a staged set (plan.json and the files it
    \\                          names, spec/staged-set.md) through one group:
    \\                          every member is visible together, or none is.
    \\                          --registry is required; a rerun after a failure
    \\                          resumes the same group (state.json); report.json
    \\                          says what each member came to. --no-commit
    \\                          uploads every file and stops with the group open
    \\                          (exit 0, outcome 'staged', nothing readable); the
    \\                          same command without it resumes that group and
    \\                          commits. With --oidc, --no-commit asks the
    \\                          registry for a stage-only token (it cannot
    \\                          commit); a registry without stage tokens gives a
    \\                          publish token and the run says so. --abort ends
    \\                          the open group state.json names, which frees
    \\                          the actor's place
    \\  stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version>
    \\        --out <dir> --registry <prod|gamma|beta|url>
    \\                          pack the workspace's members (the named ones and
    \\                          what they depend on, or all) in dependency order
    \\                          from <artifacts>/<subdir>/<name>.mojoc, with path
    \\                          dependencies dropped and versions kept; check each
    \\                          version against the registry (yanked, burned or
    \\                          other bytes: refused; same bytes: skipped); write
    \\                          the staged set for 'publish --staged'. Reads no
    \\                          token; --registry is required
    \\  yank --group <id> --registry <prod|gamma|beta|url> --reason <text>
    \\       --group <id> --registry <...> --unyank
    \\                          yank every version a group published, or restore
    \\                          the ones its yank changed
    \\  lock [--registry <prod|gamma|beta|url>] [--overlay <staged set>]
    \\                          resolve mopm.toml's dependencies against the
    \\                          registry's index and write mopm.lock (keeping
    \\                          locked versions that still fit)
    \\                          --overlay <dir> reads a staged set as a local
    \\                          channel ahead of the registry (also for sync and
    \\                          add); it is never written to a lock or manifest
    \\  update [<package>...] [--registry ...]
    \\                          the same, moving the named packages (all, with
    \\                          none named) to the newest versions that fit
    \\  tree                    draw the dependency graph mopm.lock holds
    \\  sync [--locked] [--registry ...] [--overlay <staged set>] [--pixi <path>]
    \\                          install mopm.lock into .mopm/ (locking first
    \\                          when it is missing or out of date with
    \\                          mopm.toml; --locked fails instead). Every
    \\                          download is checked against the lock's sha256
    \\                          and size; build with --prefix .mopm/.pixi/envs/default
    \\  add <package>[@<req>] [--dev] [--path <dir>] [--registry ...] [--overlay <staged set>]
    \\                          add a dependency to mopm.toml ([dev-dependencies]
    \\                          with --dev): <req>, else ^ the newest version
    \\                          that fits, or { path = "<dir>" }; then lock.
    \\                          Comments and layout are kept; nothing is
    \\                          written if it does not resolve
    \\  remove <package> [--dev] [--registry ...]
    \\                          take a dependency out of mopm.toml and lock
    \\  plan --unit-graph --locked [--mojo <version>] [--workspace-root <dir>] [-o <file>]
    \\                          print the unit graph (spec/unit-graph.md) of
    \\                          mopm.lock for one Mojo version; never resolves;
    \\                          --workspace-root: graph paths are relative to
    \\                          <dir>, which holds this directory and every
    \\                          path dependency
    \\  unit build|test --unit <id> --graph <file> --out <dir> --toolchain <dir>
    \\                          build (or build and run) one unit of a graph,
    \\                          offline, from declared inputs only
    \\
    \\  options for build, run and repl:
    \\    --prefix <dir>        the environment (default: CONDA_PREFIX, then
    \\                          MODULAR_HOME without /share/max)
    \\    --print-cmd           print the command instead of running it
    \\    --os <linux|macos>    with --print-cmd: the spelling to print
    \\                          (default: this host)
    \\
    \\planned (not implemented yet):
    \\  cov check export launch
    \\
;

fn linkPlan(arena: std.mem.Allocator, paths: []const []const u8) u8 {
    if (paths.len == 0) {
        std.debug.print("usage: mopm link-plan <file.mopm.json>...\n", .{});
        return 2;
    }
    var inputs = std.ArrayList(core.link_planner.Input).init(arena);
    for (paths) |p| {
        const inp = core.link_planner.loadInput(arena, p) catch |e| {
            std.debug.print("mopm: {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        inputs.append(inp) catch return 1;
    }
    const plan = core.link_planner.plan(arena, inputs.items) catch return 1;
    var buf = std.ArrayList(u8).init(arena);
    core.link_planner.render(plan, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
    return if (plan.ok()) 0 else 1;
}

fn metadataCmd(arena: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len > 1) {
        std.debug.print("usage: mopm metadata [path/to/mopm.toml]\n", .{});
        return 2;
    }
    const path = if (args.len == 1) args[0] else "mopm.toml";
    const src = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |e| {
        std.debug.print("mopm: {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    var diag: core.manifest.Diagnostic = .{};
    const m = core.manifest.parse(arena, src, &diag) catch |e| {
        if (e == error.Invalid) {
            std.debug.print("mopm: {s}:{d}:{d}: {s}\n", .{ path, diag.pos.line, diag.pos.col, diag.message });
        } else {
            std.debug.print("mopm: {s}: {s}\n", .{ path, @errorName(e) });
        }
        return 1;
    };
    var buf = std.ArrayList(u8).init(arena);
    core.manifest.writeJson(m, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
    return 0;
}

const ScaffoldArgs = struct {
    name: ?[]const u8 = null,
    kind: core.scaffold.Kind = .lib,
};

/// `new <name> [--lib|--bin]` or `init [--lib|--bin] [--name <name>]`; null if
/// the arguments are neither.
fn scaffoldArgs(cmd: []const u8, args: []const []const u8) ?ScaffoldArgs {
    const is_new = std.mem.eql(u8, cmd, "new");
    var out = ScaffoldArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--lib")) {
            out.kind = .lib;
        } else if (std.mem.eql(u8, a, "--bin")) {
            out.kind = .bin;
        } else if (!is_new and std.mem.eql(u8, a, "--name") and i + 1 < args.len and out.name == null) {
            i += 1;
            out.name = args[i];
        } else if (is_new and a.len > 0 and a[0] != '-' and out.name == null) {
            out.name = a;
        } else return null;
    }
    if (is_new and out.name == null) return null;
    return out;
}

/// `mopm new` (into a new directory) and `mopm init` (into this one).
fn scaffoldCmd(arena: std.mem.Allocator, cmd: []const u8, args: []const []const u8) u8 {
    const parsed = scaffoldArgs(cmd, args) orelse {
        std.debug.print("usage: mopm new <name> [--lib|--bin]\n       mopm init [--lib|--bin] [--name <name>]\n", .{});
        return 2;
    };
    const is_new = std.mem.eql(u8, cmd, "new");
    var hint: []const u8 = "";
    const name = parsed.name orelse blk: {
        const here = std.fs.cwd().realpathAlloc(arena, ".") catch |e| {
            std.debug.print("mopm init: {s}\n", .{@errorName(e)});
            return 1;
        };
        hint = " (the name comes from this directory; pass --name <name>)";
        break :blk std.fs.path.basename(here);
    };
    const problem = core.manifest.nameProblem(arena, "package name", name) catch return 1;
    if (problem) |message| {
        std.debug.print("mopm {s}: {s}{s}\n", .{ cmd, message, hint });
        return 1;
    }
    const files = core.scaffold.files(arena, name, parsed.kind) catch return 1;

    var dir = std.fs.cwd();
    var opened: ?std.fs.Dir = null;
    defer if (opened) |*d| d.close();
    if (is_new) {
        std.fs.cwd().makeDir(name) catch |e| {
            if (e == error.PathAlreadyExists) {
                std.debug.print("mopm new: '{s}' already exists\n", .{name});
            } else {
                std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            }
            return 1;
        };
        opened = std.fs.cwd().openDir(name, .{}) catch |e| {
            std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        dir = opened.?;
    }
    if (core.scaffold.firstExisting(dir, files)) |path| {
        std.debug.print("mopm {s}: {s} already exists; nothing was written\n", .{ cmd, path });
        return 1;
    }
    core.scaffold.write(dir, files) catch |e| {
        std.debug.print("mopm {s}: {s}\n", .{ cmd, @errorName(e) });
        return 1;
    };
    const what = switch (parsed.kind) {
        .lib => "library",
        .bin => "binary",
    };
    const out = std.io.getStdOut().writer();
    if (is_new) {
        out.print("created {s} package '{s}' in {s}/\n", .{ what, name, name }) catch return 1;
    } else {
        out.print("created {s} package '{s}'\n", .{ what, name }) catch return 1;
    }
    return 0;
}

pub const Opts = struct {
    prefix: ?[]const u8 = null,
    os: mojo_cmd.Os,
    /// Whether `--os` was given; it only applies to `--print-cmd`.
    os_given: bool = false,
    print_cmd: bool = false,
    out: ?[]const u8 = null,
    file: ?[]const u8 = null,
    /// `run --bin <package>:<program>`: a program an installed package ships, in place of a file.
    bin: ?[]const u8 = null,
    /// `build` with no program: where the library and the programs go.
    out_dir: ?[]const u8 = null,
    /// `repl --debugserver <path>`: the debugserver to hand lldb instead of finding one.
    debugserver: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    ok: Opts,
    /// A usage error, already worded.
    usage: []const u8,
};

/// `--name value` or `--name=value`. Returns the value and advances `i`, or
/// null if `arg` is not this option.
fn optValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return "";
        i.* += 1;
        return args[i.*];
    }
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') return arg[name.len + 1 ..];
    return null;
}

/// Whether `arg` is the option `name`, spelled `name` or `name=value`.
fn isOpt(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name) or (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=');
}

pub fn parseOpts(arena: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) std.mem.Allocator.Error!Parsed {
    var o = Opts{ .os = mojo_cmd.Os.host() };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--print-cmd")) {
            o.print_cmd = true;
        } else if (optValue(args, &i, "--prefix")) |v| {
            if (v.len == 0) return .{ .usage = "--prefix needs a directory" };
            o.prefix = v;
        } else if (optValue(args, &i, "--os")) |v| {
            o.os = std.meta.stringToEnum(mojo_cmd.Os, v) orelse
                return .{ .usage = try std.fmt.allocPrint(arena, "--os must be linux or macos, not '{s}'", .{v}) };
            o.os_given = true;
        } else if (tool == .build and std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) return .{ .usage = "-o needs a file name" };
            i += 1;
            o.out = args[i];
        } else if (tool == .build and isOpt(arg, "--out-dir")) {
            const v = optValue(args, &i, "--out-dir").?;
            if (v.len == 0) return .{ .usage = "--out-dir needs a directory" };
            o.out_dir = v;
        } else if (tool == .repl and isOpt(arg, "--debugserver")) {
            const v = optValue(args, &i, "--debugserver").?;
            if (v.len == 0) return .{ .usage = "--debugserver needs the path of a debugserver" };
            o.debugserver = v;
        } else if (tool == .run and isOpt(arg, "--bin")) {
            const v = optValue(args, &i, "--bin").?;
            if (v.len == 0) return .{ .usage = "--bin needs <package>:<program>" };
            o.bin = v;
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg}) };
        } else if (tool == .repl) {
            return .{ .usage = try std.fmt.allocPrint(arena, "repl takes no program, got '{s}'", .{arg}) };
        } else if (o.file != null) {
            return .{ .usage = try std.fmt.allocPrint(arena, "one program only, got '{s}' and '{s}'", .{ o.file.?, arg }) };
        } else {
            o.file = arg;
        }
    }
    if (o.bin != null and o.file != null) return .{ .usage = try std.fmt.allocPrint(arena, "--bin names the program: do not also give the file '{s}'", .{o.file.?}) };
    if (tool != .repl and tool != .build and o.file == null and o.bin == null) return .{ .usage = "a program is required: <file.mojo>" };
    if (tool == .build and o.file == null and o.out != null) return .{ .usage = "-o names the file of one program: name the program, or use --out-dir to say where the targets of mopm.toml go" };
    if (tool == .build and o.file != null and o.out_dir != null) return .{ .usage = "--out-dir applies to a build with no program: with a program, -o names its file" };
    if (o.os_given and !o.print_cmd) return .{ .usage = "--os applies only with --print-cmd: a command that runs uses this host's spelling" };
    return .{ .ok = o };
}

fn getEnv(arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(arena, key) catch null;
}

/// Whether an environment variable's value is absent or empty (the two are the same to mopm).
fn isUnset(value: ?[]const u8) bool {
    return value == null or value.?.len == 0;
}

/// Whether `mopm repl` looks for Xcode's debugserver: only for repl, when no `--debugserver` was given, `--os` did not
/// spell another machine, and `LLDB_DEBUGSERVER_PATH` is unset or empty (an empty one names nothing).
fn searchesDebugserver(tool: mojo_cmd.Tool, given: ?[]const u8, os_given: bool, env_value: ?[]const u8) bool {
    return tool == .repl and given == null and !os_given and isUnset(env_value);
}

/// Replace this process with mojo: `argv`, and the caller's environment with
/// `cmd.env` applied on top. Exec rather than spawn-and-wait: the terminal,
/// stdin (the REPL reads it), signals such as Ctrl-C, and the exit status all
/// belong to mojo with nothing in between. Returns only if the exec failed:
/// 127 when the program does not exist, 126 otherwise (the shell's codes).
fn execMojo(arena: std.mem.Allocator, name: []const u8, cmd: mojo_cmd.Command) u8 {
    const err = std.io.getStdErr().writer();
    var env_map = core.child_env.forChild(arena) catch |e| {
        err.print("mopm {s}: reading the environment: {s}\n", .{ name, @errorName(e) }) catch {};
        return 1;
    };
    mojo_cmd.applyEnv(&env_map, cmd.env) catch return 1;
    const e = std.process.execve(arena, cmd.argv, &env_map);
    err.print("mopm {s}: cannot run {s}: {s}\n", .{ name, cmd.argv[0], @errorName(e) }) catch {};
    return if (e == error.FileNotFound) 127 else 126;
}

/// `mopm build|run|repl`: discover the environment, plan, refuse, then run
/// mojo or print its command. Diagnostics go to stderr; a printed command
/// line to stdout.
fn autolink(arena: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) u8 {
    const name = @tagName(tool);
    const err = std.io.getStdErr().writer();
    const parsed = parseOpts(arena, tool, args) catch return 1;
    const o = switch (parsed) {
        .ok => |v| v,
        .usage => |msg| {
            err.print("mopm {s}: {s}\n\n{s}", .{ name, msg, usage }) catch {};
            return 2;
        },
    };

    const bin_ref: ?bin_run.Ref = if (o.bin) |text| switch (bin_run.parseRef(arena, text) catch return 1) {
        .ok => |r| r,
        .bad => |msg| {
            err.print("mopm run: {s}\n\n{s}", .{ msg, usage }) catch {};
            return 2;
        },
    } else null;

    if (tool == .build and o.file == null) {
        return build_cmd.run(arena, .{
            .prefix = o.prefix,
            .os = o.os,
            .print_cmd = o.print_cmd,
            .out_dir = o.out_dir orelse build_cmd.default_out_dir,
        });
    }
    // A program is built with the path dependencies of the package in this directory importable (mopm.toml, if any).
    const dep_dirs: []const []const u8 = if (tool == .build)
        (build_cmd.importDirsHere(arena) catch return 1) orelse return 1
    else
        &.{};

    const chosen = core.env.choosePrefix(o.prefix, getEnv(arena, "CONDA_PREFIX"), getEnv(arena, "MODULAR_HOME")) catch |e| {
        switch (e) {
            error.NoPrefix => err.print("mopm {s}: no environment: pass --prefix <dir>, or run in an activated environment (CONDA_PREFIX or MODULAR_HOME)\n", .{name}) catch {},
            error.BadModularHome => err.print("mopm {s}: MODULAR_HOME does not end in /share/max, so the environment prefix cannot be derived from it; pass --prefix <dir>\n", .{name}) catch {},
        }
        return 1;
    };
    const prefix = std.fs.cwd().realpathAlloc(arena, chosen.path) catch {
        err.print("mopm {s}: environment {s} (from {s}) does not exist\n", .{ name, chosen.path, chosen.source.describe() }) catch {};
        return 1;
    };

    const paths = core.env.listMetadata(arena, prefix) catch |e| {
        switch (e) {
            error.NotAMojoEnv => err.print("mopm {s}: {s} (from {s}) has no lib/mojo: not a Mojo environment\n", .{ name, prefix, chosen.source.describe() }) catch {},
            else => err.print("mopm {s}: reading {s}/lib/mojo: {s}\n", .{ name, prefix, @errorName(e) }) catch {},
        }
        return 1;
    };
    const loaded = core.env.loadAll(arena, paths) catch return 1;
    const inputs = switch (loaded) {
        .ok => |v| v,
        .failed => |f| {
            err.print("mopm {s}: {s}: {s}\n", .{ name, f.path, @errorName(f.err) }) catch {};
            return 1;
        },
    };

    // `run --bin`: the program is the source file the installed package ships, built and run by this environment's mojo.
    var file = o.file;
    if (bin_ref) |ref| {
        var names = std.ArrayList([]const u8).init(arena);
        for (inputs) |inp| names.append(inp.meta.name) catch return 1;
        switch (bin_run.resolve(arena, prefix, names.items, ref) catch return 1) {
            .ok => |path| file = path,
            .bad => |msg| {
                err.print("mopm run: {s}\n", .{msg}) catch {};
                return 1;
            },
        }
    }

    const plan = core.link_planner.plan(arena, inputs) catch return 1;
    const refused = mojo_cmd.refusals(arena, tool, plan) catch return 1;
    if (refused.len > 0) {
        for (refused) |d| err.print("mopm {s}: refused ({s}): {s}\n", .{ name, @tagName(d.code), d.message }) catch {};
        return 1;
    }
    const missing = core.env.missingFiles(arena, plan) catch return 1;
    if (missing.len > 0) {
        for (missing) |m| err.print("mopm {s}: refused (missing_file): {s} is named by the installed metadata but is not on disk\n", .{ name, m }) catch {};
        return 1;
    }

    // macOS 14 and older: mojo's packaged debugserver crashes, so the REPL is pointed at Xcode's, unless the caller
    // named one (--debugserver, or LLDB_DEBUGSERVER_PATH already in the environment). `--os` spells another
    // machine's command line, which says nothing about this one: no search then.
    var debugserver = o.debugserver;
    if (searchesDebugserver(tool, debugserver, o.os_given, getEnv(arena, mojo_cmd.debugserver_var))) {
        switch (core.debugserver.discover(arena) catch return 1) {
            .not_needed => {},
            .path => |p| debugserver = p,
            .missing => |m| err.print("mopm repl: warning: {s}\n", .{m}) catch {},
        }
    }

    const cmd = mojo_cmd.construct(arena, .{
        .tool = tool,
        .prefix = prefix,
        .os = o.os,
        .file = file orelse "",
        .out = o.out,
        .include_dirs = dep_dirs,
        .debugserver = debugserver,
    }, plan) catch return 1;
    if (!o.print_cmd) return execMojo(arena, name, cmd);
    var buf = std.ArrayList(u8).init(arena);
    mojo_cmd.render(cmd, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
    return 0;
}

fn run(arena: std.mem.Allocator) u8 {
    const args = std.process.argsAlloc(arena) catch return 1;
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.io.getStdOut().writeAll("mopm " ++ version ++ "\n") catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        std.io.getStdOut().writeAll(usage) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cmd, "link-plan")) return linkPlan(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "metadata")) return metadataCmd(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "init")) return scaffoldCmd(arena, cmd, args[2..]);
    if (std.mem.eql(u8, cmd, "test")) return test_cmd.main(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "login") or std.mem.eql(u8, cmd, "logout") or std.mem.eql(u8, cmd, "whoami")) {
        return registry_cmd.main(arena, cmd, args[2..], version);
    }
    if (std.mem.eql(u8, cmd, "pack") or std.mem.eql(u8, cmd, "publish")) {
        return publish_cmd.main(arena, cmd, args[2..], version);
    }
    if (std.mem.eql(u8, cmd, "yank")) return yank_cmd.main(arena, args[2..], version);
    if (std.mem.eql(u8, cmd, "stage")) return stage_cmd.main(arena, args[2..], version);
    if (std.mem.eql(u8, cmd, "lock")) return install_cmd.main(arena, .lock, args[2..], version);
    if (std.mem.eql(u8, cmd, "update")) return install_cmd.main(arena, .update, args[2..], version);
    if (std.mem.eql(u8, cmd, "tree")) return install_cmd.main(arena, .tree, args[2..], version);
    if (std.mem.eql(u8, cmd, "sync")) return install_cmd.main(arena, .sync, args[2..], version);
    if (std.mem.eql(u8, cmd, "add")) return install_cmd.main(arena, .add, args[2..], version);
    if (std.mem.eql(u8, cmd, "remove")) return install_cmd.main(arena, .remove, args[2..], version);
    if (std.mem.eql(u8, cmd, "plan")) return plan_cmd.main(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "unit")) return unit_cmd.main(arena, args[2..]);
    if (std.meta.stringToEnum(mojo_cmd.Tool, cmd)) |tool| return autolink(arena, tool, args[2..]);
    if (isPlanned(cmd)) {
        std.debug.print("mopm {s}: not implemented yet\n", .{cmd});
        return 1;
    }
    std.debug.print("mopm: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    return 2;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const code = run(arena_state.allocator());
    std.process.exit(code);
}

test {
    _ = registry_cmd;
    _ = publish_cmd;
    _ = install_cmd;
    _ = plan_cmd;
    _ = unit_cmd;
    _ = yank_cmd;
    _ = @import("group_plan.zig");
    _ = @import("group_publish.zig");
    _ = @import("group_publish_test.zig");
    _ = @import("group_stage_token.zig");
    _ = stage_cmd;
    _ = @import("stage_test.zig");
    _ = @import("publish_false_test.zig");
    _ = @import("bin_run.zig");
    _ = build_cmd;
}

test "planned commands are recognised, working ones are not planned" {
    try std.testing.expect(isPlanned("cov"));
    try std.testing.expect(isPlanned("check"));
    try std.testing.expect(!isPlanned("publish"));
    try std.testing.expect(!isPlanned("pack"));
    try std.testing.expect(!isPlanned("build"));
    try std.testing.expect(!isPlanned("run"));
    try std.testing.expect(!isPlanned("repl"));
    try std.testing.expect(!isPlanned("link-plan"));
    try std.testing.expect(!isPlanned("metadata"));
    try std.testing.expect(!isPlanned("new"));
    try std.testing.expect(!isPlanned("init"));
    try std.testing.expect(!isPlanned("lock"));
    try std.testing.expect(!isPlanned("tree"));
    try std.testing.expect(!isPlanned("sync"));
    try std.testing.expect(!isPlanned("add"));
    try std.testing.expect(!isPlanned("remove"));
    try std.testing.expect(!isPlanned("--version"));
    try std.testing.expect(!isPlanned("frobnicate"));
}

test "new and init arguments" {
    try std.testing.expectEqualStrings("demo", scaffoldArgs("new", &.{ "demo", "--bin" }).?.name.?);
    try std.testing.expectEqual(core.scaffold.Kind.bin, scaffoldArgs("new", &.{ "--bin", "demo" }).?.kind);
    try std.testing.expectEqual(core.scaffold.Kind.lib, scaffoldArgs("new", &.{"demo"}).?.kind);
    try std.testing.expectEqual(core.scaffold.Kind.lib, scaffoldArgs("new", &.{ "--bin", "--lib", "demo" }).?.kind);
    try std.testing.expect(scaffoldArgs("new", &.{}) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "a", "b" }) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "--name", "a" }) == null);
    try std.testing.expectEqualStrings("x", scaffoldArgs("init", &.{ "--name", "x" }).?.name.?);
    try std.testing.expect(scaffoldArgs("init", &.{}).?.name == null);
    try std.testing.expect(scaffoldArgs("init", &.{"x"}) == null);
    try std.testing.expect(scaffoldArgs("init", &.{"--name"}) == null);
}

fn parseOk(a: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) !Opts {
    return switch (try parseOpts(a, tool, args)) {
        .ok => |o| o,
        .usage => |m| {
            std.debug.print("unexpected usage error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn parseUsage(a: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) !void {
    switch (try parseOpts(a, tool, args)) {
        .ok => return error.TestUnexpectedResult,
        .usage => {},
    }
}

test "options: both spellings, any order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const o = try parseOk(a, .build, &.{ "--print-cmd", "m.mojo", "--prefix=/e", "-o", "out", "--os", "macos" });
    try std.testing.expect(o.print_cmd);
    try std.testing.expectEqualStrings("m.mojo", o.file.?);
    try std.testing.expectEqualStrings("/e", o.prefix.?);
    try std.testing.expectEqualStrings("out", o.out.?);
    try std.testing.expectEqual(mojo_cmd.Os.macos, o.os);
    const r = try parseOk(a, .repl, &.{ "--prefix", "/e", "--os=linux", "--print-cmd" });
    try std.testing.expectEqualStrings("/e", r.prefix.?);
    try std.testing.expectEqual(mojo_cmd.Os.linux, r.os);
    const x = try parseOk(a, .run, &.{ "m.mojo", "--prefix", "/e" });
    try std.testing.expect(!x.print_cmd);
    try std.testing.expect(!x.os_given);
    try std.testing.expectEqual(mojo_cmd.Os.host(), x.os);
}

test "options: build with no program takes --out-dir in both spellings; repl takes --debugserver" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const none = try parseOk(a, .build, &.{"--print-cmd"});
    try std.testing.expect(none.file == null);
    try std.testing.expect(none.out_dir == null);
    const spaced = try parseOk(a, .build, &.{ "--out-dir", "out", "--prefix", "/e" });
    try std.testing.expect(spaced.file == null);
    try std.testing.expectEqualStrings("out", spaced.out_dir.?);
    const joined = try parseOk(a, .build, &.{"--out-dir=dist/x"});
    try std.testing.expectEqualStrings("dist/x", joined.out_dir.?);
    const with_file = try parseOk(a, .build, &.{ "m.mojo", "-o", "m" });
    try std.testing.expectEqualStrings("m.mojo", with_file.file.?);
    const repl = try parseOk(a, .repl, &.{ "--debugserver", "/x/debugserver" });
    try std.testing.expectEqualStrings("/x/debugserver", repl.debugserver.?);
    const repl2 = try parseOk(a, .repl, &.{"--debugserver=/y"});
    try std.testing.expectEqualStrings("/y", repl2.debugserver.?);
}

test "repl searches for a debugserver unless one is named; an empty LLDB_DEBUGSERVER_PATH names none" {
    try std.testing.expect(searchesDebugserver(.repl, null, false, null));
    try std.testing.expect(searchesDebugserver(.repl, null, false, ""));
    try std.testing.expect(!searchesDebugserver(.repl, null, false, "/x/debugserver"));
    try std.testing.expect(!searchesDebugserver(.repl, "/y/debugserver", false, null));
    try std.testing.expect(!searchesDebugserver(.repl, null, true, null));
    try std.testing.expect(!searchesDebugserver(.build, null, false, null));
    try std.testing.expect(!searchesDebugserver(.run, null, false, ""));
}

test "options: usage errors" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try parseUsage(a, .run, &.{"--print-cmd"}); // no program
    try parseUsage(a, .run, &.{ "a.mojo", "b.mojo" }); // two programs
    try parseUsage(a, .build, &.{ "a.mojo", "b.mojo" });
    try parseUsage(a, .build, &.{ "-o", "x" }); // -o names one program's file
    try parseUsage(a, .build, &.{"--out-dir"}); // flag without value
    try parseUsage(a, .build, &.{ "--out-dir=", "--print-cmd" });
    try parseUsage(a, .build, &.{ "a.mojo", "--out-dir", "d" }); // --out-dir is for a build with no program
    try parseUsage(a, .run, &.{ "a.mojo", "--out-dir", "d" }); // build only
    try parseUsage(a, .repl, &.{"--debugserver"});
    try parseUsage(a, .build, &.{ "a.mojo", "--debugserver", "/d" }); // repl only
    try parseUsage(a, .run, &.{ "a.mojo", "--debugserver", "/d" });
    try parseUsage(a, .run, &.{ "a.mojo", "-o", "x" }); // -o is build only
    try parseUsage(a, .repl, &.{"a.mojo"}); // repl takes no program
    try parseUsage(a, .build, &.{ "a.mojo", "--prefix" }); // flag without value
    try parseUsage(a, .build, &.{ "a.mojo", "--os", "windows" });
    try parseUsage(a, .build, &.{ "a.mojo", "--frobnicate" });
    try parseUsage(a, .run, &.{ "a.mojo", "--os", "linux" }); // --os without --print-cmd
    try parseUsage(a, .repl, &.{"--os=macos"});
}

// Defect caught: `--bin` accepted by a command that has no use for it, taken together with a file, or with no value.
test "run --bin: a program of an installed package in place of a file, for run only" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const spaced = try parseOk(a, .run, &.{ "--bin", "benchy:agg_state_bench" });
    try std.testing.expectEqualStrings("benchy:agg_state_bench", spaced.bin.?);
    try std.testing.expect(spaced.file == null);
    const joined = try parseOk(a, .run, &.{ "--prefix", "/env", "--bin=benchy:spsc_ring_bench" });
    try std.testing.expectEqualStrings("benchy:spsc_ring_bench", joined.bin.?);
    try parseUsage(a, .run, &.{"--bin"});
    try parseUsage(a, .run, &.{"--bin="});
    try parseUsage(a, .run, &.{ "--bin", "benchy:x", "m.mojo" });
    try parseUsage(a, .run, &.{ "m.mojo", "--bin", "benchy:x" });
    try parseUsage(a, .build, &.{ "--bin", "benchy:x" });
    try parseUsage(a, .repl, &.{ "--bin", "benchy:x" });
    // A run with a file is what it was.
    try std.testing.expectEqualStrings("m.mojo", (try parseOk(a, .run, &.{"m.mojo"})).file.?);
    try parseUsage(a, .run, &.{});
}
