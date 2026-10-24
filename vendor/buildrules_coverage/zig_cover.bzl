# Vendored from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/zig_cover.bzl.
# Changed from it, and only in these ways: ZigTestInfo comes from the vendored zig_test.bzl; the tools are the targets of tools.bzl in
# the root package (mopm//:cov_*); the floor's `--label` is the target's name (the root package has no name of its own); no `visibility` on the floor.
# A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (README.md in this directory).

"""The coverage of Zig test targets, and the floor a package's coverage is held to (README.md, "Zig coverage").

`zig_coverage(name = "coverage", test_targets = [...], expect = [...])` runs each `zig_test` named in `test_targets` again, as the same compile and the same
environment (its root, target, data and tools), but built with block counters and under kcov (tools/zig_cover.zig, one action per test), and
folds the reports of all of them into `coverage.txt`: lines hit and recorded per file, then the same for blocks, and the totals over `expect`, the
package's own sources. `<name>_floor` holds that text to the package's `coverage_floor.txt` (tools/cov_floor.zig), as a minimum: a fall fails, and a figure above the floor
passes with a hint that the floor may be raised.

Block counters need the zig 0.15 of `rules/pins:zig_next` (0.12 has no `-ffuzz`); a package whose tests are built by 0.12 sets `blocks = False` and has lines
only. linux x86_64 only.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load(":zig_test.bzl", "ZigTestInfo")

def _file(dep):
    return dep[DefaultInfo].default_outputs[0]

def _impl(ctx):
    reports = []
    blocks = []
    stamps = []
    if not ctx.attrs.test_targets:
        fail("{}: test_targets is empty: a package with no test has no coverage to measure".format(ctx.label.raw_target()))
    for test in ctx.attrs.test_targets:
        info = test[ZigTestInfo]
        name = test.label.name
        lines = ctx.actions.declare_output(name + ".cobertura.xml")
        blk = ctx.actions.declare_output(name + ".blocks") if ctx.attrs.blocks else None
        # zig_launch's own stamp: written when the tool succeeded, a file nothing reads.
        stamp = ctx.actions.declare_output(name + ".cover_ok")
        cmd = cmd_args(
            ctx.attrs._launcher[RunInfo],
            "run",
            "--busybox",
            info.busybox,
            "--exec",
            _file(ctx.attrs._cover),
            "--out",
            stamp.as_output(),
            "--stamp",
            "ok\n",
        )
        if info.data_manifest != None:
            cmd.add("--data", info.data_manifest, "--tools", info.tools_manifest)
        cmd.add(
            "--",
            "--zig",
            info.zig,
            "--target",
            info.target,
            "--root",
            info.root,
            "--kcov",
            _file(ctx.attrs._kcov),
            "--normalize",
            ctx.attrs._normalize[RunInfo],
            "--out-lines",
            lines.as_output(),
            "--must-contain",
            info.src,
        )
        if ctx.attrs.blocks:
            cmd.add("--runner", ctx.attrs._runner, "--out-blocks", blk.as_output())
        else:
            cmd.add("--no-blocks")
        for s in info.sources:
            cmd.add("--include", s)
        ctx.actions.run(cmd_args(cmd, hidden = info.hidden), category = "zig_cover", identifier = name, env = info.env)
        reports.append(lines)
        if blk != None:
            blocks.append(blk)
        stamps.append(stamp)
    out = ctx.actions.declare_output("coverage.txt")
    cmd = cmd_args(ctx.attrs._summary[RunInfo], "--out", out.as_output())
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    for b in blocks:
        cmd.add("--blocks", b)
    for r in reports:
        cmd.add(r)
    ctx.actions.run(cmd, category = "zig_cov_summary", identifier = ctx.label.name)
    # `:coverage[reports]`: each test's reports, to read when the summary is refused.
    return [DefaultInfo(default_output = out, other_outputs = stamps + reports + blocks, sub_targets = {"reports": [DefaultInfo(default_outputs = reports + blocks)]})]

zig_coverage_rule = rule(
    impl = _impl,
    doc = "`coverage.txt` of the zig_test targets in `test_targets`, each run under kcov and with block counters; `expect` are the package's own sources, the files the totals count.",
    attrs = {
        # Build with block counters (zig 0.15) and report them; false for tests built by the 0.12 zig, which has none: their report is lines only.
        "blocks": attrs.bool(default = True),
        "expect": attrs.list(attrs.string()),
        "test_targets": attrs.list(attrs.dep(providers = [ZigTestInfo])),
        "_cover": attrs.exec_dep(default = "mopm//:cov_zig_cover", providers = [RunInfo]),
        "_kcov": attrs.exec_dep(default = "buildrules//rules/coverage:kcov"),
        "_launcher": attrs.exec_dep(default = "mopm//:cov_launch", providers = [RunInfo]),
        "_normalize": attrs.exec_dep(default = "buildrules//rules/coverage:cov_normalize", providers = [RunInfo]),
        "_runner": attrs.source(default = "mopm//:cov_zig_cov_runner.zig"),
        "_summary": attrs.exec_dep(default = "mopm//:cov_summary", providers = [RunInfo]),
    },
)

def _floor_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "--coverage",
            _file(ctx.attrs.coverage),
            "--floor",
            ctx.attrs.floor,
            "--label",
            ctx.label.name,
            "--out",
            out.as_output(),
        ),
        category = "zig_cov_floor",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

zig_coverage_floor_rule = rule(
    impl = _floor_impl,
    doc = "Green only if the coverage in `coverage` is its floor in `floor`: lower fails, and so does higher until the floor is raised to it. The output lists the figures and what the 99% target still needs.",
    attrs = {
        "coverage": attrs.dep(),
        "floor": attrs.source(),
        "_tool": attrs.exec_dep(default = "mopm//:cov_floor", providers = [RunInfo]),
    },
)

def zig_coverage(test_targets, expect, name = "coverage", floor = "coverage_floor.txt", **kwargs):
    """The package's coverage (`<name>`) and its floor check (`<name>_floor`); see the file comment."""
    zig_coverage_rule(
        name = name,
        test_targets = test_targets,
        expect = expect,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )
    zig_coverage_floor_rule(
        name = name + "_floor",
        coverage = ":" + name,
        floor = floor,
        exec_compatible_with = LINUX_X86_64,
    )
