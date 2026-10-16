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
"""

def _lambda_zip_impl(ctx):
    exe = ctx.attrs.bootstrap[DefaultInfo].default_outputs[0]
    # The package is not built unless every test passed: their markers are inputs.
    markers = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.welded_tests]
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
