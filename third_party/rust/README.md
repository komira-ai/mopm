# Rust crates

`crates.bzl` pins every crates.io crate the Rust targets link (182 of them today: the Lambda runtime,
the AWS SDK for Rust with its HTTPS client on rustls over AWS-LC, and the TLS test) as one `cargo_crate`
each: the sha256 and size of its `.crate`, its features, its cfgs and its dependencies. `crates.bzl` is
**generated**; nobody edits it.

```
workspace/Cargo.toml, lambda/, sdk/, tls/    the dependency set (what Cargo is asked to resolve)
workspace/Cargo.lock                          what it resolved (the sha256 of every .crate)
workspace/metadata.json, tree.txt             cargo metadata and cargo tree of that, for x86_64 linux
workspace/sizes.txt                           size of every .crate
gen/overrides.json                            what no tool can know: the build scripts' outcomes
gen/cargo_to_buck.zig                         the generator (a Zig tool, built and run by Buck2)
crates.bzl                                    its output
```

`:gen` writes `crates.bzl`; `:drift` fails unless the committed file is exactly that, so a hand edit, a
stale file or a changed input shows up in the build (`./buck2 build //third_party/rust/gen:drift`).

## Updating the pins

The inputs are made with Cargo on a developer's machine (Cargo only resolves and downloads here; it never
builds). Rust 1.85.0 is the pinned compiler, so the resolver must not pick a crate newer than it supports:

```sh
export CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback   # honour rust-version = "1.85" in the manifests
cd third_party/rust/workspace && cargo update
cargo metadata --format-version 1 --filter-platform x86_64-unknown-linux-gnu --locked   # -> metadata.json (trimmed to name, version, id, edition, targets, deps)
cargo tree --workspace -e normal --target x86_64-unknown-linux-gnu --prefix none -f '{p}|{f}'   # -> tree.txt
ls -l ~/.cargo/registry/cache/*/                                                       # -> sizes.txt
./buck2 build //third_party/rust/gen:gen --show-output     # then copy the output to third_party/rust/crates.bzl
```

A crate with a build script and no entry in `gen/overrides.json` stops the generator: a build script is
never skipped silently.

## What the rules add to komira's

`tools/cargo/cargo.bzl` reuses komira's toolchain (`toolchains//:rust`), its providers (`RustCrateInfo`,
`RustTestInfo`) and its pinned download and unpack rules, so a crate pinned by komira's `crates_io_library`
and one pinned here link into one binary (`//spike/xcell` does exactly that). komira's rules could not build
these crates, for five reasons, each of them one attribute away in komira's `rust_library`/`rust_binary`/`rust_test`:

| gap | where it bites | here |
|---|---|---|
| no `env` | `env!("CARGO_PKG_VERSION")` and friends: 11 of the 182 crates | `cargo_crate` sets `CARGO_PKG_NAME`, `_VERSION`, `_VERSION_MAJOR/MINOR/PATCH/PRE` and `CARGO_CRATE_NAME` from the pin; `env` adds more |
| no generated or edited sources | `include!(concat!(env!("OUT_DIR"), ..))`, and bindings that must change | `patch` (`tools/cargo/crate_patch.zig`): copy, exact text substitution (the count is checked), add files |
| no renamed dependencies | `package = "http"` under another name: 21 edges (`http_02x`, `http_1x`, `pki_types`, ..) | `renamed_deps` |
| no way to link a native archive into an executable | AWS-LC | `native_deps` on `cargo_bin` and `cargo_test` (`-Clink-arg=<archive>`) |
| no `--extern proc_macro` | every proc-macro crate (12 here) | added to the rustc line of a proc-macro |

## Build scripts

182 crates, 21 with a build script. Cargo runs each of them to learn something about the compiler and the
target; here the answer for rustc 1.85.0 on x86_64 linux is written down. Classes:

* **a** only emits cfgs (or `cargo:` metadata nobody here reads): it can be precomputed. 16 crates.
* **b** generates code that the crate includes: it needs a file written, or, where the answer is a constant,
  the file checked in. 4 crates (`serde`, `serde_core`, `rustversion`, `aws-types`); all four write a
  function of the Cargo version or of `rustc --version`.
* **c** builds native code: replaced by a komira target. 1 crate (`aws-lc-sys`).

| crate | class | cfgs | generated / edited | why |
|---|---|---|---|---|
| `aws-lc-rs 1.11.1` | a | none | none | build.rs only re-exports the DEP_AWS_LC_* variables of aws-lc-sys to dependents; nothing the crate itself compiles reads them. |
| `aws-lc-sys 0.23.1` | c | `x86_64_unknown_linux_gnu` | 4 text edit(s) | build.rs compiles the bundled AWS-LC with CMake and emits cfg x86_64_unknown_linux_gnu (selects the pre-generated bindings). Replaced by komira//third_party/aws-lc:crypto, linked into each executable (native_deps). That AWS-LC is the same release (1.39.0) but its symbols are komira_awslc_X, where the bindings say aws_lc_0_23_1_X, so the bindings are rewritten; the three ERR_GET_*_RUST C wrappers (rust_wrapper.c) become Rust. |
| `aws-types 1.3.10` | b | none | adds `src/build_env.rs`; 1 text edit(s) | build.rs writes build_env.rs, const RUST_VERSION = the rustc version. The pinned rustc is 1.85.0. |
| `crc32fast 1.5.2` | a | `stable_arm_crc32_intrinsics` | none | rustc minor 85: stable_arm_crc32_intrinsics (>= 80); not stable_vpclmulqdq (>= 89). |
| `generic-array 0.14.7` | a | `relaxed_coherence` | none | version_check says rustc >= 1.41. |
| `getrandom 0.3.4` | a | none | none | emits cfgs only for msan and windows; none on linux. |
| `httparse 1.10.1` | a | `httparse_simd_neon_intrinsics`, `httparse_simd` | none | rustc >= 1.59 and std: SIMD cfgs. No sse4.2/avx2 target feature at baseline x86-64, so runtime detection only. |
| `icu_normalizer_data 2.1.1` | a | none | none | emits a cfg only when ICU4X_DATA_DIR is set. |
| `icu_properties_data 2.1.2` | a | none | none | emits a cfg only when ICU4X_DATA_DIR is set. |
| `libc 0.2.190` | a | `linux_time_bits64` | none | x86_64 linux gnu: linux_time_bits64 (target_os linux, 64-bit pointers). |
| `num-traits 0.2.19` | a | `has_total_cmp` | none | autocfg probe `1f64.total_cmp(&2f64)` compiles on 1.85. |
| `paste 1.0.15` | a | none | none | no_literal_fromstr only below rustc 1.54. |
| `proc-macro2 1.0.107` | a | `wrap_proc_macro` | none | stable rustc, no span-locations: wrap_proc_macro. The unstable probes fail on stable. |
| `quote 1.0.47` | a | none | none | no_diagnostic_namespace only below rustc 1.78. |
| `rustls 0.23.20` | a | none | none | read_buf is for nightly only. |
| `rustversion 1.0.23` | b | none | adds `src/version.expr`; 1 text edit(s) | build/build.rs asks rustc --version and writes version.expr, a struct literal that src/lib.rs includes. Written for 1.85.0 stable. |
| `serde 1.0.229` | b | `if_docsrs_then_no_serde_core` | adds `src/out_private.rs`, `src/core/out_private.rs`; 2 text edit(s) | build.rs writes private.rs (a module named for the patch version) and emits if_docsrs_then_no_serde_core; all minor-version cfgs are off at 1.85. The file is placed beside each include! (lib.rs and core/crate_root.rs). |
| `serde_core 1.0.229` | b | none | adds `src/out_private.rs`; 1 text edit(s) | build.rs writes private.rs (module named for the patch version); every no_* cfg is off at rustc 1.85. |
| `serde_json 1.0.154` | a | `fast_arithmetic="64"` | none | x86_64: 64-bit limbs. |
| `zerocopy 0.8.63` | a | `no_zerocopy_simd_x86_avx12_1_89_0`, `no_zerocopy_aarch64_simd_be_1_87_0` | none | the cfgs for features newer than the pinned rustc, from [package.metadata.build-rs] in Cargo.toml: those above 1.85 are 1.87 and 1.89. |
| `zmij 1.0.23` | a | `zmij_no_select_unpredictable` | none | rustc < 1.88: zmij_no_select_unpredictable. |

Everything else in `crates.bzl` is derived from Cargo's own output: name, version, sha256 (Cargo.lock),
size, edition, library name and root, proc-macro or not, resolved features (`cargo tree`), the dependency
edges and the names a crate gives them (`cargo metadata`), and two versions of one crate told apart
(`http-0.2.12`, `http-1.5.0`).

## AWS-LC

The AWS SDK's HTTPS client and `rustls` both reach AWS-LC through `aws-lc-rs` and `aws-lc-sys`.
`aws-lc-sys` 0.23.1 bundles AWS-LC 1.39.0, the release komira builds
(`komira//third_party/aws-lc`), so the pins hold `aws-lc-rs` at 1.11.1 (the last release that takes
`aws-lc-sys` 0.23; the tls manifest says `=1.11.1`) and `rustls` at 0.23.20, which the Rust 1.85 resolution
picks for it. `aws-lc-sys` is built from its Rust sources only:

* its pre-generated bindings call `aws_lc_0_23_1_<name>`; komira's archive defines `komira_awslc_<name>`
  (every symbol is renamed so that AWS-LC can share a process with another libcrypto). The patch rewrites
  the prefix in the bindings file (the count of replacements, 2579, is checked);
* its three `ERR_GET_*_RUST` helpers are C in `rust_wrapper.c`; they become the Rust expressions of the
  `static inline` functions they wrap (`err.h` in the same AWS-LC release);
* every executable or test that links it names the archive:
  `native_deps = ["komira//third_party/aws-lc:crypto[static-pic]"]`. It is the archive komira builds and
  checks (`crypto_symbols`), so these targets share its remote cache entries.
