# Vendored from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/zig/zig.bzl:
# its `zig_test` rule with the `ZigTestInfo` provider that pull request adds, and what that rule needs of the file (`_zig_closure`,
# `_zig_root`, `_zig_sources`, `_zig_optimize`). The rule is otherwise the one the pinned buildrules has: the same command line, so a
# test's action is the one it was, and `zig_exe` / `zig_module` (loaded from buildrules) accept it in `unit_tests` as before.
# A stopgap: delete this file and load `zig_test` from @buildrules//rules/zig:zig.bzl again when the pin in .buckconfig has the change.

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//rules/core:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load("@buildrules//rules/core:test_runtime.bzl", "RUNNER_ENV", "data_map")
load("@buildrules//rules/zig:zig.bzl", "ZigModuleInfo")


# What a `zig_test` runs, for the rule that runs the same test under coverage (rules/coverage/zig_cover.bzl): the same root, zig, target, data and tools.
ZigTestInfo = provider(fields = {
    # The tools, data and env of a driver test; empty for a test without them.
    "data_manifest": provider_field(typing.Any),
    "env": provider_field(dict),
    # The compile's inputs other than the manifests: what the root names.
    "hidden": provider_field(list),
    # The root the compile is given: the source file, or the argument file naming the modules.
    "root": provider_field(typing.Any),
    "busybox": provider_field(typing.Any),
    # The paths, from the repository root, of the test's own source and of every file it is built from (its imports and its modules'), sorted.
    "sources": provider_field(list),
    "src": provider_field(str),
    "target": provider_field(str),
    "tools_manifest": provider_field(typing.Any),
    "zig": provider_field(typing.Any),
})

_ZIG_RESERVED_MODULES = ["root", "std", "builtin"]

def _zig_closure(where, deps):
    """The modules `deps` (ZigModuleInfo of the direct deps, in order) reach,
    each once, direct ones first. Fails when two different targets of one
    import name are reached."""
    out = []
    labels = {}
    for dep in deps:
        for e in [struct(name = dep.name, label = dep.label, root = dep.root, inputs = dep.inputs, deps = dep.deps)] + dep.closure:
            if e.name in labels:
                if labels[e.name] != e.label:
                    fail("{}: two different modules are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(where, e.name, labels[e.name], e.label))
                continue
            labels[e.name] = e.label
            out.append(e)
    return out

def _package_of(label):
    """The package of a target label string (`cell//a/b:name` -> `a/b`)."""
    return label.split("//", 1)[1].split(":", 1)[0]

def _repo_path(package, artifact):
    return (package + "/" if package else "") + artifact.short_path

def _zig_sources(ctx):
    """The repository paths of the source files `ctx`'s zig test is built from: `src`, `imports`, the roots of its modules and the files
    those import. A build output (a module's `.passed`) is not a source."""
    package = ctx.label.package
    paths = [_repo_path(package, ctx.attrs.src)] + [_repo_path(package, i) for i in ctx.attrs.imports]
    for e in _zig_closure(str(ctx.label.raw_target()), [d[ZigModuleInfo] for d in ctx.attrs.deps]):
        owner = _package_of(e.label)
        paths.append(_repo_path(owner, e.root))
        paths += [_repo_path(owner, i) for i in e.inputs if i.is_source]
    return sorted({p: True for p in paths if p.endswith(".zig")}.keys())

def _zig_root(ctx):
    """What the compile is given as its root: `src`; with `deps`, an argument
    file naming `src` as the root module and each module it may import (the
    `deps` and what they import, with the imports of each module declared
    before it; `@file` is zig's own argument file, read in place of the
    argument). Without `deps` the command line is the one it always was, so
    no existing action changes its key. Two deps of one import name (the
    same target twice, or two targets of one name) fail analysis rather
    than zig's compile."""
    if not ctx.attrs.deps:
        return ctx.attrs.src
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    seen = {}
    for d, m in zip(ctx.attrs.deps, mods):
        if m.name in seen:
            fail("{}: two deps are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(ctx.label.raw_target(), m.name, seen[m.name], d.label.raw_target()))
        seen[m.name] = d.label.raw_target()
    closure = _zig_closure(str(ctx.label.raw_target()), mods)
    args = [cmd_args("--dep", m.name) for m in mods]
    args.append(cmd_args(ctx.attrs.src, format = "-Mroot={}"))
    for e in closure:
        args += [cmd_args("--dep", n) for n in e.deps]
        args.append(cmd_args(e.root, format = "-M" + e.name + "={}"))
    argfile, _ = ctx.actions.write(ctx.label.name + ".zig_modules", cmd_args(args), allow_args = True)
    return cmd_args(argfile, format = "@{}", hidden = [ctx.attrs.src] + [e.root for e in closure] + [i for e in closure for i in e.inputs])

# zig's optimization modes, for `optimize`.
ZIG_OPTIMIZE_MODES = ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]

def _zig_optimize(ctx):
    if ctx.attrs.optimize not in ZIG_OPTIMIZE_MODES:
        fail("{}: optimize {} is not a zig optimization mode ({})".format(ctx.label.raw_target(), repr(ctx.attrs.optimize), ", ".join(ZIG_OPTIMIZE_MODES)))
    return ctx.attrs.optimize

# Variables a driver test's action sets itself (tools/mojo/tools/zig_launch.zig).
_ZIG_TEST_OWN_ENV = ["XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "BUILDRULES_TEST_WORK"]

def _zig_test_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    # A test that runs tools (`env_tools`) is also a validation: a target
    # that hands a tool out lists the test that runs it (`kcov_tool`'s
    # `cases`), as the test cannot be an input of the tool it runs. Its
    # result is then a validation result; a test without tools writes
    # `passed`, as it always did.
    validation = bool(ctx.attrs.env_tools or ctx.attrs.exec_tools)
    out = ctx.actions.declare_output(ctx.label.name + (".json" if validation else ".passed"))
    stamp = '{"version": 1, "data": {"status": "success", "message": "zig test passed"}}\n' if validation else "passed\n"
    if not regex_match("^[a-z0-9_.-]+$", ctx.attrs.target):
        fail("{}: target {} is not a zig target triple".format(ctx.label, repr(ctx.attrs.target)))
    # The launcher (tools/zig_launch.zig; no shell) gives the tests the busybox
    # applets as their PATH and a HOME, TMPDIR and caches of their own inside
    # the action's scratch directory, runs `zig test`, and writes the stamp
    # when it passed. `-O<mode>` is left out for `Debug`, zig's own default.
    cmd = cmd_args(
        ctx.attrs._launcher[RunInfo],
        "test",
        "--busybox",
        bb,
        "--zig",
        zig,
        "--out",
        out.as_output(),
        "--stamp",
        stamp,
    )
    # The pinned tools a test runs, as environment variables naming their
    # paths.
    env = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.env_tools.items()}
    env.update(rerun_env(ctx))
    hidden = list(ctx.attrs.imports)
    root = _zig_root(ctx)
    data_manifest = None
    tools_manifest = None
    driver_hidden = []
    if ctx.attrs.exec_tools or ctx.attrs.data:
        # A driver test: built tools by absolute path, fixtures in a writable
        # directory (BUILDRULES_TEST_WORK). Both come from manifests the launcher
        # reads, so a test without them is not a driver.
        where = str(ctx.label.raw_target())
        for name in ctx.attrs.exec_tools:
            if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
                fail("{}: exec_tools name {} is not a shell variable name".format(where, repr(name)))
            if name in RUNNER_ENV or name in _ZIG_TEST_OWN_ENV or name in ctx.attrs.env_tools:
                fail("{}: exec_tools name {} is set by the action or by env_tools".format(where, name))
        srcs = data_map(ctx, where, ctx.attrs.data)
        tools = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.exec_tools.items()}
        data_manifest, _ = ctx.actions.write(ctx.label.name + ".data", [cmd_args(d, a, delimiter = "\t") for d, a in sorted(srcs.items())], allow_args = True)
        tools_manifest, _ = ctx.actions.write(ctx.label.name + ".tools", [cmd_args(n, t, delimiter = "\t") for n, t in sorted(tools.items())], allow_args = True)
        cmd.add("--data", data_manifest, "--tools", tools_manifest)
        driver_hidden = srcs.values() + tools.values()
        hidden += driver_hidden
    cmd.add("--", "test")
    if _zig_optimize(ctx) != "Debug":
        cmd.add("-O" + ctx.attrs.optimize)
    cmd.add("-target", ctx.attrs.target, root)
    ctx.actions.run(
        cmd_args(cmd, hidden = hidden),
        category = "zig_test",
        env = env,
    )
    info = ZigTestInfo(
        busybox = bb,
        data_manifest = data_manifest,
        env = env,
        hidden = hidden,
        root = root,
        sources = _zig_sources(ctx),
        src = _repo_path(ctx.label.package, ctx.attrs.src),
        target = ctx.attrs.target,
        tools_manifest = tools_manifest,
        zig = zig,
    )
    if validation:
        return [
            DefaultInfo(default_output = out),
            ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = out)]),
            rerun_info(ctx),
            info,
        ]
    return [DefaultInfo(default_output = out), rerun_info(ctx), info]

# `zig test` of `src` (and the `test` blocks of the files it imports, the
# `imports`), run as a build action: the target exists only if every test
# passed. A `zig_exe` names it in `unit_tests` to be built behind it. A test
# that runs tools names them in `env_tools`; it is then also a validation,
# which a target that hands a tool out lists (`kcov_tool`'s `cases`), as it
# cannot be an input of the executable it runs. It can still be in the
# `unit_tests` of an executable it does not run (cov_zig's unit tests run a
# stand-in zig and debug_relocate).
zig_test_rule = rule(
    impl = _zig_test_impl,
    attrs = {
        "busybox": attrs.dep(default = "buildrules//rules/pins:busybox"),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        # name -> a tool the tests run (its default output), in the
        # environment as its path. Configured for the execution platform like
        # the target that hands it out, so the same bytes. It may be a
        # directory of executables: the pinned zig
        # (buildrules//rules/pins:zig) is the directory holding `zig`.
        "env_tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        # Files a driver test reads and writes, copied into the writable
        # directory BUILDRULES_TEST_WORK: a list of sources (files or directories,
        # each at its path from the cell root) or {destination: source}.
        "data": attrs.one_of(attrs.list(attrs.source(allow_directory = True)), attrs.dict(attrs.string(), attrs.source(allow_directory = True)), default = []),
        # name -> a built tool the tests run, in the environment as its
        # ABSOLUTE path (env_tools' paths are relative to the action's
        # directory). Like env_tools, it makes the test a validation.
        "exec_tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        "imports": attrs.list(attrs.source(), default = []),
        # zig's -O: the optimization mode the tests are built with. `Debug`
        # is zig's own default (no flag is passed).
        "optimize": attrs.string(default = "Debug"),
        "src": attrs.source(),
        # zig's -target. The tests run as part of the action, so it must be a
        # target the execution platform runs (the default, or another libc
        # of its cpu).
        "target": attrs.string(default = "x86_64-linux-musl"),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
        # The runner of the action (tools/zig_launch.zig), built by the
        # pinned zig directly: no test needs a shell to run.
        "_launcher": attrs.exec_dep(default = "buildrules//rules/zig:zig_launch"),
    } | RERUN_ATTRS,
)

def zig_test(**kwargs):
    """`zig_test_rule`, run on the linux x86_64 execution platform unless the call says otherwise."""
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    return zig_test_rule(**kwargs)
