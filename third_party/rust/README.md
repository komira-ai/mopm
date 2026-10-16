# Rust crates

`crates.bzl` pins every crates.io crate the Rust targets link (one `crates_io_library` each: the sha256 and size
of its `.crate`, its features, cfgs, `CARGO_PKG_*` variables and dependencies). It is **generated** by
[`kpin cargo`](https://github.com/komira-ai/komira/blob/main/tools/build/kpin/README.md) and nobody edits it.

| file | what it is | made by |
|---|---|---|
| `Cargo.toml`, `lib.rs` | the crates mopm links, as a Cargo manifest (`lib.rs` is empty: Cargo needs a target) | a person |
| `Cargo.lock` | what Cargo resolved: the sha256 of every `.crate` | a GitHub runner |
| `cargo/metadata.json` | `cargo metadata` for x86_64 linux, trimmed: the graph, the resolved features, renames | a GitHub runner (`kpin cargo --trim`) |
| `cargo/sizes.txt` | the size of every linked `.crate`, from kpin's own download, checked against `Cargo.lock` | a GitHub runner (`kpin update`) |
| `cargo/overrides.json` | what each build script decides for the pinned compiler | a person |
| `crates.bzl` | the targets | `kpin cargo`, on a runner and in the `:crates_gen` build |

`./buck2 build //third_party/rust:crates_gen` writes `crates.bzl` and fails unless the committed file is exactly
what the inputs generate: a hand edit, a changed hash, a missing override, or a compiler bump that left the
overrides behind is a red build.

## Where Cargo runs

Never in a build action, never on the farm, never on a developer box that is also the build machine. Cargo only
resolves and reads: `.github/workflows/kpin-update.yml` (`KPIN_CARGO_SETS`) runs `cargo update`,
`cargo metadata --locked --filter-platform x86_64-unknown-linux-gnu`, `kpin cargo --trim`, `kpin update --no-pins`
(sizes) and `kpin cargo --previous-lock`, weekly and on `workflow_dispatch` (`cargo_update: false` regenerates from
the committed `Cargo.lock`). A `Cargo.lock` checksum that moved for a locked version is an alarm (exit 3).

To add a crate: a line in `Cargo.toml`, a run of that workflow (or the commands above on a runner), and, when the
new crate has a build script, an entry in `cargo/overrides.json`. The build then names the crate that lacks one.

## The AWS-LC pin

The AWS SDK's HTTPS client and `rustls` reach AWS-LC through `aws-lc-rs` and `aws-lc-sys`. `aws-lc-sys` 0.23.1
bundles AWS-LC 1.39.0, the release komira builds (`komira//third_party/aws-lc`). `aws-lc-rs` 1.11.1 and `rustls`
0.23.20 are the releases that go with it, so `Cargo.toml` holds those three with `=`.

`rust-version = "1.85"` in `Cargo.toml` is **not** the pinned compiler (that is komira's, 1.99.0): it is what the
runner's resolver (`CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback`) takes as the newest compiler the set must
support, which keeps the AWS SDK crates one coherent older stack. A newest-first resolve mixes today's
`aws-smithy-types` with an `aws-runtime` that no longer compiles against it (rustc 1.99.0:
`E0282` in `aws-runtime` `auth/sigv4.rs`). Raising it moves the SDK, and needs the AWS-LC decision first.

`aws-lc-sys` is built from its Rust sources only (class `c` in `overrides.json`):

* its pre-generated bindings call `aws_lc_0_23_1_<name>`; komira's archive defines `komira_awslc_<name>`. The patch
  rewrites the prefix in the bindings (the count of replacements, 2579, is checked);
* its three `ERR_GET_*_RUST` helpers are C in `rust_wrapper.c`; they become the Rust expressions of the `static
  inline` functions they wrap;
* every executable or test that links it names the archive: `native_deps = ["komira//third_party/aws-lc:crypto[static-pic]"]`.

`//tools/lambda:tls_test` (handshakes, TLS 1.2 and 1.3, a wrong name refused, the library reporting AWS-LC 1.39.0) and
`//tools/lambda:sdk_test` (one DynamoDB request signed and read back, and a client of each service crate) are the
evidence that this link works.

## Build scripts

23 of the 216 linked crates have one. Nothing here runs a build script; what it decided for rustc 1.99.0 on
x86_64 linux is written down in `cargo/overrides.json`, with a `why` for each entry. They were derived from the
scripts' own output: `cargo build --locked --target x86_64-unknown-linux-gnu` on a runner under rustc 1.99.0, reading
each `target/**/build/*/output` (the `cargo:rustc-cfg` lines) and each file written to `OUT_DIR`. Classes:

* **a** only emits cfgs: `aws-lc-rs`, `crc32fast`, `generic-array`, `getrandom` (two versions), `httparse`,
  `icu_normalizer_data`, `icu_properties_data`, `libc`, `num-traits`, `paste`, `proc-macro2`, `quote`, `rustls`,
  `serde_json`, `zerocopy`, `zmij`;
* **b** writes a file the crate includes, checked in as a constant: `serde`, `serde_core`, `thiserror`
  (a module named for the version), `rustversion`, `aws-types` (the rustc version);
* **c** builds native code: `aws-lc-sys`.

Some cfgs differ from rustc 1.85.0 (`crc32fast` gains `stable_vpclmulqdq`, `proc-macro2` the two span cfgs,
`zerocopy` and `zmij` none); the compiler is part of the override file (`"rustc"`), and the generator refuses it
when the pinned compiler moves.

## `cargo metadata` and weak features

`cargo metadata` lists an optional dependency that is only named by a weak feature (`ring?/alloc`) as an edge, though
nothing enabled it. `kpin cargo --trim` of komira at the pinned commit drops those edges (komira pull request 1665);
without that the closure would have built `ring`, `defmt`, `schemars` and their build scripts for nothing.
