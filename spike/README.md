# Rust Lambda spike

A feasibility spike: can mopm's API Lambdas be Rust, built by Buck2 on the farm with komira's Rust rules?
No API code is ported. What is here is the smallest program of each kind the port will need, and the
build that holds them.

| target | what it proves |
|---|---|
| `//spike/xcell:xcell` | a mopm `rust_binary` links crates pinned by komira (`komira//third_party/rust`) and by mopm (`//third_party/rust`); `[run_check]` runs it |
| `//spike/rust_lambda:bootstrap_bin` | the `lambda_runtime` + `lambda_http` closure (93 crates) builds and links; the binary needs glibc 2.34 or older, nothing else |
| `//spike/rust_lambda:e2e_test` | the binary, run against a fake Lambda runtime API on loopback, answers one API Gateway v2 event with exactly the expected JSON |
| `//spike/rust_lambda:lambda_zip` | the deployment package (`bootstrap`, stored in a zip, mode 0755); it cannot be built unless `:e2e_test` passed on the binary it holds |
| `//spike/rust_lambda:*_small_*` | the same, built for size (`opt-level=s`, fat LTO, panic=abort, stripped) |
| `//spike/tls:tls_test` | rustls on `aws-lc-rs`, over komira's AWS-LC: a TLS 1.2 and a TLS 1.3 handshake and exchange over loopback; a wrong server name is refused; the library reports itself as AWS-LC 1.39.0 |
| `//spike/sdk_probe:probe_test` | the AWS SDK for Rust (DynamoDB) does one GetItem against a fake endpoint on loopback: serialization, SigV4 signing, response and error deserialization |
| `//spike/sdk_probe:sdk_probe` | `aws-config` + `aws-sdk-dynamodb` + `aws-sdk-s3` with the default HTTPS client (rustls, AWS-LC), linked and gated by `:probe_test` |
| `//third_party/rust/gen:drift` | `third_party/rust/crates.bzl` is exactly what the generator writes from Cargo's output |
| `//tools/cargo:crate_patch`, `//tools/lambda:zip_pack` | the two Zig tools (with unit tests) the rules above run; no build or test action uses a shell of its own |

The crates and how each was pinned: [`third_party/rust/README.md`](../third_party/rust/README.md).

## Numbers (x86_64, rustc 1.85.0, one farm)

| | opt-level 3 | size build (`s`, LTO, abort, stripped) |
|---|---|---|
| Lambda `bootstrap` | 3,592,192 bytes | 2,230,464 bytes |
| Lambda zip (entries stored) | 3,592,308 bytes | 2,230,580 bytes |
| same binary through `gzip -9` (what a deflating zip would hold) | 1,488,004 bytes | 1,078,036 bytes |
| `sdk_probe` | 12,628,304 bytes | 8,379,872 bytes |

Cold builds (every rustc action re-keyed with `-c mopm.rust_cache_nonce=...`; the downloads and the Zig tools
were warm, which that setting does not touch): `:lambda_zip` 100 actions, 2 min 22 s; `:sdk_probe` 166
actions, 4 min 19 s; the five targets `:lambda_zip :lambda_small_zip :tls_test :sdk_probe :sdk_probe_small`
together 188 actions, 6 min 9 s. Every build reported `local: 0`.

## arm64 (Graviton)

Not done here. What it takes, from reading komira's rule code:

* komira declares `linux-arm64` and reserves it (`tools/build/platforms/table.bzl`: no platform target, no
  execution platform). A target platform for it and its constraint row, plus a `komira-limit:` marker for each
  rule that stays x86_64-only.
* The Rust toolchain is x86_64 only (`komira_rust_toolchains`, `target_compatible_with` x86_64 and
  `rust-toolchain-x86-64`). Cross-compiling needs the `rust-std-1.85.0-aarch64-unknown-linux-gnu` tarball pinned and
  unpacked beside the host one (`lib/rustlib/aarch64-unknown-linux-gnu`), a second `rust_toolchain` whose `cc_target`
  is `aarch64-linux-gnu.2.34` (the wrapper takes the zig target as an argument, so the linker shim already follows it),
  and `--target=aarch64-unknown-linux-gnu` on the rustc line.
* komira's rules assume the execution and the target platform are one (a proc-macro "is compiled once"). Cross
  needs proc-macros and build tools compiled for the host and everything else for the target, which is a
  configuration transition (`exec_dep` for proc-macro crates) in `rust_library`.
* AWS-LC: `third_party/aws-lc/BUCK` is `target_compatible_with` x86_64 and `srcs.bzl` lists the aarch64 assembly
  as "not built yet". The bindings file for arm64 (`aarch64_unknown_linux_gnu_crypto.rs`) uses the same prefix
  and the same patch.
* Per-crate cfgs: the overrides are for x86_64 (for instance `httparse_simd`, `zerocopy`, `libc`'s time bits); the
  generator would key them by target.
* zig itself links glibc 2.34 for aarch64 (`zig cc -target aarch64-linux-gnu.2.34`); nothing in the wrapper
  prevents it. That part is untested here: there is no aarch64 rust-std pin to test it with.
