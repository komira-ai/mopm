"""lambda_zip: the deployment package of a custom-runtime Lambda function."""

def _lambda_zip_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".zip")
    exe = ctx.attrs.bootstrap[DefaultInfo].default_outputs[0]
    # The package is not built unless every test passed: their markers are inputs.
    markers = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.welded_tests]
    ctx.actions.run(
        cmd_args(
            ctx.attrs.tool[RunInfo],
            out.as_output(),
            cmd_args("bootstrap=", exe, ":755", delimiter = ""),
            hidden = markers,
        ),
        category = "lambda_zip",
    )
    return [DefaultInfo(default_output = out, sub_targets = {"tests": [DefaultInfo(default_outputs = markers)]})]

lambda_zip = rule(
    impl = _lambda_zip_impl,
    attrs = {
        # The executable, stored as `bootstrap` (the name the provided runtimes run).
        "bootstrap": attrs.dep(),
        # Tests (zig_test, rust_test) that must pass before the package exists.
        "welded_tests": attrs.list(attrs.dep(), default = []),
        "tool": attrs.exec_dep(default = "mopm//tools/lambda:zip_pack"),
    },
)
