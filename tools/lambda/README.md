# Lambda packaging and the canary

The deployment package of a custom-runtime Lambda function is a zip with one executable named `bootstrap`. Both
tools are Zig, so no build or test action runs a shell of its own.

| target | what it is |
|---|---|
| `:zip_pack` | `zip_pack <out.zip> [--sha256 <file>] bootstrap=<file>:755`: a deterministic zip. Entries stored, in the order given, the DOS time 1980-01-01 00:00, version-made-by host Unix, mode in the high 16 bits of the external attributes. Names Lambda would not find (`./x`, `/x`, `x/`, `..`, empty, backslash, NUL) and a name twice are refused. `--sha256` writes `sha256sum` lines for the zip and each entry. |
| `:zip_check` | reads the package back (end record, central directory, local header) and fails unless: exactly one entry named exactly `bootstrap`, stored, fixed time and date, host byte Unix, regular file mode 0755, no extra field or comment, no bytes outside, data equal to the executable, CRC-32 right. It shares no code with the writer. (The standard library's `std.zip` arrived after the pinned Zig, and does not return the host byte or the attributes.) |
| `lambda_zip` (`lambda.bzl`) | a rule: `<name>.zip` from an executable, `[sha256]` the sums file, `[tests]` the welded test markers. The package is not built unless every `welded_tests` target passed, and `zip_check` is a validation of the target, so a build that holds the zip fails when it is wrong. |

The sums file is what a deploy compares with the function's `CodeSha256` (base64 of the zip's sha256), so the
same bytes go through every stage.

## The canary

A function built from the pinned crates (`Cargo.toml`, `Cargo.lock`, `third_party/buildrules`) with buildrules' Rust rules to
hold the foundation. Nothing deploys it. This directory is the Cargo package `mopm_canary` (`cargo_package` in `BUCK`), so
its targets are `:release` (the executable), `:test` (one marker per test binary), `:lint`.

| target | what it proves |
|---|---|
| `:test` (the unit tests of `canary/main.rs`), `:release` | the API Gateway v2 handler on `lambda_runtime` and `aws_lambda_events`, in process; `:canary_zip` is not built unless `:test` passed |
| `:canary_e2e_test` | the built binary, run against a fake Lambda runtime API on loopback, answers one event with exactly the expected response bytes |
| `:canary_zip` | the package; not built unless `:canary_e2e_test` passed on that binary |
| `:test` (`canary/tls_test.rs`, `canary/sdk_test.rs`) | rustls and the AWS SDK over buildrules' AWS-LC: `aws-lc-sys` is not built from its C sources, `third_party/buildrules/overrides.json` links `buildrules//third_party/aws-lc:crypto[static-pic]` into each test and executable (the symbol prefix in its bindings is rewritten by a counted patch) |
