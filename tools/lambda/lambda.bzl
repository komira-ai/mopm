"""lambda_zip: the deployment package of a custom-runtime Lambda function.

    lambda_zip(
        name = "api_zip",
        bootstrap = ":api",              # the executable, stored as `bootstrap`
        welded_tests = [":handler_test"],  # tests that must pass before the package exists
    )

Outputs: the default output is `<name>.zip`; sub-target `[sha256]` is the file of
`sha256sum` lines for the zip and its `bootstrap` (what a deploy compares with the
function's CodeSha256); `[tests]` are the markers of the welded tests.

The package is built by `zip_pack` and read back by `zip_check`, a validation of the
target: a build that holds the zip fails unless its only entry is named exactly
`bootstrap`, stored, mode 0755 with host byte Unix, at the fixed time (tools/lambda/README.md).
Neither tool runs a shell.

lambda_bundle: several of those zips in one directory, for one deploy.

    lambda_bundle(
        name = "function_zips",
        zips = {"web-login": "//service/lambda/fn_web_login:zip"},  # function name -> lambda_zip
    )

The default output is the directory `<name>`: `<function name>.zip` for each entry, byte for byte, and `sums`
(`sha256sum` lines of those zips, sorted by file name), built by `zip_bundle`.
"""

def _lambda_zip_impl(ctx):
    exe = ctx.attrs.bootstrap[DefaultInfo].default_outputs[0]
    # The package is not built unless every test passed: their markers are inputs.
    markers = [m for t in ctx.attrs.welded_tests for m in t[DefaultInfo].default_outputs]
    zip = ctx.actions.declare_output(ctx.label.name + ".zip")
    sums = ctx.actions.declare_output(ctx.label.name + ".sha256")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pack[RunInfo],
            zip.as_output(),
            "--sha256",
            sums.as_output(),
            cmd_args("bootstrap=", exe, ":755", delimiter = ""),
            hidden = markers,
        ),
        category = "lambda_zip",
    )
    stamp = ctx.actions.declare_output(ctx.label.name + ".zip_check")
    ctx.actions.run(
        cmd_args(ctx.attrs._check[RunInfo], zip, exe, stamp.as_output()),
        category = "lambda_zip_check",
    )
    return [
        DefaultInfo(
            default_output = zip,
            sub_targets = {
                "sha256": [DefaultInfo(default_output = sums)],
                "tests": [DefaultInfo(default_outputs = markers)],
            },
        ),
        ValidationInfo(validations = [ValidationSpec(name = "zip_check", validation_result = stamp)]),
    ]

lambda_zip = rule(
    impl = _lambda_zip_impl,
    attrs = {
        # The executable, stored as `bootstrap` (the name the provided runtimes run).
        "bootstrap": attrs.dep(),
        # Tests (zig_test, rust_test) that must pass before the package exists.
        "welded_tests": attrs.list(attrs.dep(), default = []),
        "_check": attrs.exec_dep(default = "mopm//tools/lambda:zip_check"),
        "_pack": attrs.exec_dep(default = "mopm//tools/lambda:zip_pack"),
    },
)

def _lambda_bundle_impl(ctx):
    names = sorted(ctx.attrs.zips.keys())
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bundle[RunInfo],
            out.as_output(),
            [cmd_args(n, "=", ctx.attrs.zips[n][DefaultInfo].default_outputs[0], delimiter = "") for n in names],
        ),
        category = "lambda_bundle",
    )
    return [DefaultInfo(default_output = out)]

lambda_bundle = rule(
    impl = _lambda_bundle_impl,
    attrs = {
        # Function name -> lambda_zip target. The name is the one the stack gives the function (lower-case words joined by `-`).
        "zips": attrs.dict(attrs.string(), attrs.dep()),
        "_bundle": attrs.exec_dep(default = "mopm//tools/lambda:zip_bundle"),
    },
)

def _release_exe_impl(ctx):
    outs = [o for o in ctx.attrs.release[DefaultInfo].default_outputs if o.basename == ctx.attrs.exe]
    if len(outs) != 1:
        fail("{}: the release step {} has {} outputs named `{}`, not one; its outputs are {}".format(
            ctx.label,
            ctx.attrs.release.label,
            len(outs),
            ctx.attrs.exe,
            [o.basename for o in ctx.attrs.release[DefaultInfo].default_outputs],
        ))
    return [DefaultInfo(default_output = outs[0]), RunInfo(args = cmd_args(outs[0]))]

# release_exe: the one executable of a Cargo package's `:release` step, by its file name. A package with a library and a
# binary has both in that step (the `.rlib` first), and `lambda_zip` and a test's `env_tools` take a target's first output,
# so a function with a library names its executable through this:
#
#     release_exe(name = "release_exe", release = ":release", exe = "web_login")
#
# Analysis fails, naming the outputs, unless exactly one output of the step has that name.
release_exe = rule(
    impl = _release_exe_impl,
    attrs = {
        "exe": attrs.string(),
        "release": attrs.dep(),
    },
)
