# Contributing

- Tooling is written in Zig 0.12.0. Run `zig build test` from the repository
  root before opening a pull request; CI runs it on Linux (x86_64, aarch64) and
  macOS (arm64).
- A bug fix comes with a test that failed before the fix.
- A behaviour change updates the golden files in `tests/golden` in the same
  pull request, and says why.
- Keep files small and the public surface smaller. Document only what the code
  does.
- Open an issue before a large change.
- By contributing you agree your work is licensed under Apache-2.0.

## Building with Buck2, and with `zig build`

Two builds describe the same program, and both stay.

- **`zig build`** is the quick path on your machine: `zig build test` runs the
  unit tests, `zig build` makes `zig-out/bin/mopm`, and
  `tests/run_golden.sh ./zig-out/bin/mopm` runs the golden files. `ci.yml`
  runs exactly these. Nothing about them needs Buck2.
- **Buck2** (`./buck2`, a pinned release; the build rules come from the
  `komira` repository, fetched at the commit `.buckconfig` names) is what the
  build farm runs: `./buck2 build //...`. The unit tests are welded into the
  executables (`//:mopm` is not built unless `//:core_test` and `//:cli_test`
  passed), and the golden and registry end-to-end tests run as build actions
  (`//:golden`, `//tests/registry_e2e:login`, `//tests/registry_e2e:publish`).
  Without a farm configured (`.buckconfig.local`, which is gitignored) the
  actions run on your machine; that works, only slower. `farm.yml` builds
  `//...` on the farm for pull requests from this repository, once the
  repository's farm variables are set.

A source file you add under `src/core`, `src/cli` or `registry/fake` is picked
up by both (Buck2 takes each directory by glob). A new root source file, a new
executable, module or `addTest` in `build.zig` needs the matching `zig_exe`,
`zig_module` or `zig_test` in `BUCK`, and the reverse: `//:build_parity` (or
`tools/build_parity.sh`, which needs only `sh`) fails when the two differ.

The unit tests read `tests/...` relative to the repository root, which is the
working directory under `zig build test`. A runner that starts them elsewhere
sets `MOPM_SOURCE_ROOT` to the root (`src/core/testroot.zig`).
`tests/run_golden.sh` works from any directory and writes only under `$TMPDIR`.
