"""mopm's checks on the farm's macOS arm64 workers (platforms/BUCK registers their execution platform, `:macos_aarch64`).

buildrules' `zig_test` compiles and runs a test in one action through its launcher, and the launcher is built for linux x86_64, so a
`zig_test` cannot run on a Mac worker. A macOS test is therefore two targets here:

  zig_test_bin   on linux x86_64: the compile of an existing `zig_test` (the same root, modules, imports and zig, from its `ZigTestInfo`)
                 for another target with `--test-no-exec`: the test executable, built and not run. buildrules' launcher runs the compile,
                 as it does for the `zig_test` itself.
  host_run       on the execution platform the call names (`exec_compatible_with`): buildrules' `check marker`, in the build for the host
                 that runs it (`check_for_host`), starts a program with its arguments in a private scratch directory and writes the
                 marker only when the program exited 0. Each `env_tools` entry is in the environment as the absolute path of the tool.

`macos_gate()` is the `target_compatible_with` of every macOS target: while `[buildrules_re] macos_aarch64_properties` is unset no macOS
execution platform is registered, and the targets are incompatible (platforms/BUCK, `waiting_on_macos_workers`).
"""

load("@buildrules//rules:platforms.bzl", "exec_platform_ready")
load("@buildrules//rules/zig:zig.bzl", "ZigTestInfo")

def macos_gate():
    """`target_compatible_with` of a macOS target: nothing while a macOS execution platform is registered, else the constraint no platform has."""
    if exec_platform_ready("macos-aarch64"):
        return []
    return ["//platforms:waiting_on_macos_workers"]

def _zig_test_bin_impl(ctx):
    info = ctx.attrs.test[ZigTestInfo]
    exe = ctx.actions.declare_output(ctx.label.name)
    built = ctx.actions.declare_output(ctx.label.name + ".built")

    # The command of `zig_test` (buildrules rules/zig/zig.bzl) with another `-target` and `--test-no-exec`: zig writes the test
    # executable (`-femit-bin`) and runs nothing. The tests are built `Debug`, zig's default, as every `zig_test` here is.
    cmd = cmd_args(
        ctx.attrs._launcher[RunInfo],
        "test",
        "--busybox",
        info.busybox,
        "--zig",
        info.zig,
        "--out",
        built.as_output(),
        "--stamp",
        "built\n",
        "--",
        "test",
        "-target",
        ctx.attrs.target,
        "--test-no-exec",
        info.root,
        cmd_args(exe.as_output(), format = "-femit-bin={}"),
        hidden = info.hidden,
    )
    ctx.actions.run(cmd, category = "zig_test_bin")
    return [DefaultInfo(default_output = exe, other_outputs = [built]), RunInfo(args = cmd_args(exe))]

zig_test_bin = rule(
    impl = _zig_test_bin_impl,
    attrs = {
        # zig's -target of the test executable.
        "target": attrs.string(),
        # The `zig_test` whose compile this is.
        "test": attrs.dep(providers = [ZigTestInfo]),
        "_launcher": attrs.exec_dep(default = "buildrules//rules/zig:zig_launch", providers = [RunInfo]),
    },
)

def _host_run_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    cmd = cmd_args(ctx.attrs._check[RunInfo], "marker", "--out", out.as_output(), "--stamp", "passed", "--private-scratch")
    for name, tool in sorted(ctx.attrs.env_tools.items()):
        cmd.add("--env", cmd_args(name, tool[DefaultInfo].default_outputs[0], delimiter = "="), "--abs", name)
    cmd.add("--", ctx.attrs.exe[RunInfo], ctx.attrs.args)
    ctx.actions.run(cmd_args(cmd, hidden = ctx.attrs.data), category = "host_run")
    return [DefaultInfo(default_output = out)]

host_run = rule(
    impl = _host_run_impl,
    attrs = {
        "args": attrs.list(attrs.arg(), default = []),
        # Files the program reads at their paths from the repository root (the working directory of the action).
        "data": attrs.list(attrs.source(), default = []),
        # name -> a built program the run hands the test, in the environment as its absolute path.
        "env_tools": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "exe": attrs.dep(providers = [RunInfo]),
        # What a workflow selects the target by (`attrfilter(labels, macos-farm, //...)` in farm-macos.yml).
        "labels": attrs.list(attrs.string(), default = []),
        # `check` built for the host of the execution platform this target runs on (buildrules rules/check/BUCK).
        "_check": attrs.exec_dep(default = "buildrules//rules/check:check_for_host", providers = [RunInfo]),
    },
)
