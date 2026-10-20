# mopm

mopm is "cargo for Mojo": a package manager plus build, test and coverage
tooling for [Mojo](https://www.modular.com/mojo) projects, with a package
registry at [mopm.dev](https://mopm.dev).

**Status: early.** `mopm --version`, `mopm link-plan`, `mopm metadata`,
`mopm new`, `mopm init`, `mopm build`, `mopm run`, `mopm repl`, `mopm test`, `mopm login`, `mopm logout`,
`mopm whoami`, `mopm pack`, `mopm publish`, `mopm lock`, `mopm update`, `mopm tree`, `mopm sync`, `mopm add`,
`mopm remove`, `mopm plan` and `mopm unit` work today.
Everything else below is a plan, and the design may change. The documentation is on
[mopm.dev/docs](https://mopm.dev/docs/): [why mopm and how it is built](docs/why-and-design.md) and
[getting started](docs/getting-started.md).

## Install

```sh
curl -fsSL https://mopm.dev/install.sh | sh
```

The installer needs only `curl`, `tar`, `awk` and `sha256sum` (or `shasum`). It downloads the release for
your machine (Linux or macOS, x86_64 or arm64) from
[GitHub releases](https://github.com/komira-ai/mopm/releases), checks its sha256 against the
release's `SHA256SUMS`, and installs `~/.mopm/bin/mopm`. It needs no root and edits no shell startup
file: it prints the `PATH` line to add. `MOPM_VERSION=1.2.3` picks a version and `MOPM_HOME=<dir>`
a different install directory. The script is [`site/static/install.sh`](site/static/install.sh);
read it before you run it.

Or download by hand. Each release lists `mopm-<version>-<target>.tar.gz` for `linux-x86_64`,
`linux-aarch64`, `macos-arm64` and `macos-x86_64`, and a `SHA256SUMS` file:

```sh
v=1.2.3 t=linux-x86_64     # your version and target
curl -fsSLO "https://github.com/komira-ai/mopm/releases/download/v$v/mopm-$v-$t.tar.gz"
curl -fsSLO "https://github.com/komira-ai/mopm/releases/download/v$v/SHA256SUMS"
grep " mopm-$v-$t.tar.gz\$" SHA256SUMS | sha256sum -c -     # macOS: shasum -a 256 -c -
tar -xzf "mopm-$v-$t.tar.gz"                              # mopm-$v-$t/mopm
```

Releases carry GitHub build-provenance attestations: `gh attestation verify
mopm-<version>-<target>.tar.gz --repo komira-ai/mopm` checks that a tarball was built by this
repository's release workflow.

## Goals

1. **Coverage for any Mojo package.** `mopm cov` builds and tests a package and
   reports line (and later branch) coverage, without the package adopting any
   particular build system.
2. **Automatic native linking for downstream consumers.** A Mojo package can
   ship native shared libraries. A package that depends on it should not need
   to know the linker flags: mopm reads the metadata of every installed
   package in the closure and computes the `mojo build` flags, the
   `mojo run -Xlinker` list and the REPL preload list itself, and refuses a
   closure with a missing transitive library or two owners of one library.

## Command tour

```text
mopm new my_pkg            # create a package with a mopm.toml
mopm add http_client       # add a dependency
mopm build                 # build, linking native libraries for you
mopm run                   # mojo run with the right -Xlinker list
mopm repl                  # mojo repl with natives preloaded
mopm test                  # run tests
mopm publish               # publish to a registry and mopm.dev
mopm cov                   # planned: run tests with coverage
```

Working today:

```text
mopm --version
mopm link-plan tests/fixtures/chain/http_client.mopm.json tests/fixtures/chain/crypto.mopm.json
mopm metadata tests/manifest/valid/full.toml
mopm new my_package --lib      # or --bin; `mopm init` makes one in the current directory
mopm build hello.mojo -o hello   # -Xlinker -L/-l (Linux: --no-as-needed) plus a run path to <env>/lib
mopm run hello.mojo              # one -Xlinker <shared object> per library
mopm repl                        # LD_PRELOAD (macOS DYLD_INSERT_LIBRARIES) for the JIT
mopm test                        # tests/**/test_*.mojo, one process per test (docs/mopm-test.md)
```

Each runs `<env>/bin/mojo` in place of mopm (with `MODULAR_HOME` set to
`<env>/share/max`), so stdin, signals and the exit status are mojo's.
`--print-cmd` prints the command instead.

The environment is `--prefix <dir>`, else `CONDA_PREFIX`, else `MODULAR_HOME`
without its `/share/max`. Every `<env>/lib/mojo/<name>.mopm.json` is read;
a missing transitive library, two owners of one library, a static-only
library under `run` or `repl`, or a library file absent from `<env>/lib` is
refused with a message. With `--print-cmd`, `--os linux|macos` picks the
spelling to print.

## Layout

| path | what |
|---|---|
| `src/cli/` | the `mopm` command line (Zig) |
| `src/core/` | `metadata.zig` (parse `<name>.mopm.json`), `link_planner.zig` (compute link arguments), `toml.zig` (the strict TOML subset), `manifest.zig` (check `mopm.toml`), `scaffold.zig` (`mopm new` and `mopm init`), `env.zig` (find the environment and its packages), `mojo_cmd.zig` (the `mojo` command lines) |
| `spec/` | draft `mopm.toml` spec and the JSON Schema for `<name>.mopm.json` |
| `tests/` | fixtures (metadata sets, and environment trees under `tests/fixtures/env`) and golden files for `link-plan`, `--print-cmd` and running mojo; `tests/manifest/{valid,invalid}` for `mopm.toml`; `tests/new/{lib,bin}` for `mopm new`; `tests/e2e` builds real fixture packages with native libraries and runs `mopm build`, `run` and `repl` against the pinned `mojo` |
| `rules/buck2`, `rules/bazel` | build rules (placeholders) |
| `registry/` | the registry and its index (placeholder) |
| `mojo/mopm_rt` | the Mojo runtime support package (placeholder) |

## Build from source

You need [Zig](https://ziglang.org) 0.12.0 (`tools/install_zig.sh <dir>` installs it, checked against a pinned sha256).

```sh
zig build            # builds zig-out/bin/mopm
zig build test       # unit tests and golden tests; run from the repository root
./buck2 build //:golden  # runs the built CLI against tests/golden (on the build farm)
```

CI runs `zig build` and `zig build test` on Linux x86_64, Linux aarch64 and macOS arm64, and
there also runs the Mojo end-to-end drivers (`tests/drivers/test_*_test.zig`) natively, in a
pixi environment with the pinned `mojo` (`tools/install_pixi.sh`, `tests/e2e/pixi.toml`):

```sh
zig build test-e2e -Dmojo-env=<pixi environment>   # or test-autolink, test-discovery, test-supervisor, test-flaky
```

The REPL checks run where the environment has `bin/mojo-lldb`. The build farm (`farm.yml`) runs
the same drivers (`//:autolink`, `//:discovery`, `//:supervisor`, `//:flaky`) on Linux x86_64
against komira's pinned Mojo compiler.

## License

Apache-2.0. See [LICENSE](LICENSE).
