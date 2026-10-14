# mopm

mopm is "cargo for Mojo": a package manager plus build, test and coverage
tooling for [Mojo](https://www.modular.com/mojo) projects, with a package
registry at [mopm.dev](https://mopm.dev).

**Status: early.** `mopm --version`, `mopm link-plan`, `mopm build`,
`mopm run` and `mopm repl` work today. Everything else below is a plan, and
the design may change.

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

## Command tour (planned)

```text
mopm new my_pkg            # create a package with a mopm.toml
mopm add http_client       # add a dependency
mopm build                 # build, linking native libraries for you
mopm run                   # mojo run with the right -Xlinker list
mopm repl                  # mojo repl with natives preloaded
mopm test                  # run tests
mopm cov                   # run tests with coverage
mopm publish               # publish to a registry and mopm.dev
```

Working today:

```text
mopm --version
mopm link-plan tests/fixtures/chain/http_client.mopm.json tests/fixtures/chain/crypto.mopm.json
mopm build hello.mojo -o hello   # -Xlinker -L/-l plus a run path to <env>/lib
mopm run hello.mojo              # one -Xlinker <shared object> per library
mopm repl                        # LD_PRELOAD (macOS DYLD_INSERT_LIBRARIES) for the JIT
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
| `src/core/` | `metadata.zig` (parse `<name>.mopm.json`), `link_planner.zig` (compute link arguments), `env.zig` (find the environment and its packages), `mojo_cmd.zig` (the `mojo` command lines) |
| `spec/` | draft `mopm.toml` spec and the JSON Schema for `<name>.mopm.json` |
| `tests/` | fixtures (metadata sets, and environment trees under `tests/fixtures/env`) and golden files for `link-plan`, `--print-cmd` and running mojo; `tests/e2e` builds real fixture packages with native libraries and runs `mopm build`, `run` and `repl` against the pinned `mojo` |
| `rules/buck2`, `rules/bazel` | build rules (placeholders) |
| `registry/` | the registry and its index (placeholder) |
| `mojo/mopm_rt` | the Mojo runtime support package (placeholder) |

## Build and test

You need [Zig](https://ziglang.org) 0.12.0 (`tools/install_zig.sh <dir>` installs it, checked against a pinned sha256).

```sh
zig build            # builds zig-out/bin/mopm
zig build test       # unit tests and golden tests; run from the repository root
tests/run_golden.sh  # runs the built CLI against tests/golden
```

CI runs all three on Linux x86_64, Linux aarch64 and macOS arm64, and there
also runs `tests/e2e/run.sh` in a pixi environment with the pinned `mojo`
(`tools/install_pixi.sh`, `tests/e2e/pixi.toml`).

## License

Apache-2.0. See [LICENSE](LICENSE).
