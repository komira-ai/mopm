# Vendored from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, files rules/coverage/jest_cover.bzl
# (`jest_coverage_floor`; `--label` is the package's path and the target's name, `_tool` is mopm//:cov_floor, no `visibility`) and rules/node/modules.bzl
# (`jest_test(coverage = True)`, here `jest_test` below: the same arguments over buildrules' public `node_tree_build`, so it needs nothing of that pull request).
# A stopgap: delete this file and use `jest_test(coverage = True)` and `jest_coverage_floor` of buildrules when the pin in .buckconfig has the change.

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//rules/node:modules.bzl", "node_tree_build")

def jest_test(name, modules, srcs, data = {}, config = "jest.config.js", max_workers = 2, **kwargs):
    """`jest --ci --coverage`: the target is the `coverage` directory the run writes (a text table on the log, `coverage-summary.json` in the directory),
    which exists only if the tests passed. The config's `collectCoverageFrom` names the package's own code."""
    if max_workers < 1:
        fail("jest_test {}: max_workers must be at least 1".format(name))
    args = ["--ci", "--maxWorkers={}".format(max_workers), "--cacheDirectory=.jest-cache", "--watchman=false", "--config", config]
    args += ["--coverage", "--coverageDirectory=coverage", "--coverageReporters=json-summary", "--coverageReporters=text"]
    node_tree_build(name, program = "node_modules/.bin/jest", modules = modules, srcs = srcs, data = data, args = args, out_dir = "coverage", **kwargs)

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    summary = cmd_args(ctx.attrs.coverage[DefaultInfo].default_outputs[0], "/coverage-summary.json", delimiter = "")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "--jest-summary",
            summary,
            "--floor",
            ctx.attrs.floor,
            "--label",
            ctx.label.package + ":" + ctx.label.name,
            "--out",
            out.as_output(),
        ),
        category = "jest_cov_floor",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

_jest_coverage_floor = rule(
    impl = _impl,
    doc = "Green only if the lines and branches of the jest run `coverage` are the floor in `floor`: lower fails, and so does higher until the floor is raised to it.",
    attrs = {
        "coverage": attrs.dep(),
        "floor": attrs.source(),
        "_tool": attrs.exec_dep(default = "mopm//:cov_floor", providers = [RunInfo]),
    },
)

def jest_coverage_floor(name = "coverage_floor", coverage = ":test", floor = "coverage_floor.txt", **kwargs):
    _jest_coverage_floor(
        name = name,
        coverage = coverage,
        floor = floor,
        visibility = ["PUBLIC"],
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )
