# Contributing

- Tooling is written in Zig 0.12.0. Run `zig build test` from the repository
  root before opening a pull request; CI runs it on Linux (x86_64, aarch64) on
  every pull request (the unit tier only: the end-to-end, packer-conformance and `install.sh`
  checks and the release run after the merge), and on macOS (arm64) after the merge (push to `main`), nightly,
  on manual dispatch, and on a pull request that carries the label `macos`
  (the macOS queue is slow, so add the label when your change touches
  platform-specific code).
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
  `./buck2 build //:golden` runs the golden files. `ci.yml`
  runs `zig build test` and `zig build`.
- **Buck2** (`./buck2`, a pinned release; the build rules come from the
  `komira` repository, fetched at the commit `.buckconfig` names) is what the
  build farm runs: `./buck2 build //...`. The build has no shell and no Python:
  every test is a Zig test. The unit tests are welded into the executables
  (`//:mopm` is not built unless `//:core_test` and `//:cli_test` passed).
  The Zig drivers in `tests/drivers` run the built programs: `//:golden` (the
  golden files; it replaced `tests/run_golden.sh`), `//:registry_login` and
  `//:registry_publish` (the former `tests/registry_e2e/*.py`), `//:group_publish` (`mopm publish --staged` and `mopm yank --group` against the fake registry), `//:stage` (`mopm stage` against the fake registry, and `publish --staged` on its output), `//:install_e2e`
  (`mopm sync`, the former `tests/install_e2e/run.py`; pixi is
  `tests/drivers/fake_pixi.zig` there), `//:gen_errors_current` (the committed
  `registry/fake/errors.zig` is what `./buck2 run //:gen_errors -- spec/api/openapi.yaml registry/fake/errors.zig`
  makes of the spec; the former `gen_errors.py`), and the
  contract checks: `//:contract` (the OpenAPI
  document, the JSON Schemas, the API cases and the examples),
  `//:contract_replay` (the fake registry against the API
  cases), `//:lock_golden` (the lock goldens; it replaced `tests/resolve/check_golden.py`) and
  `//:resolve_e2e` (it replaced `tests/resolve_e2e/run.py`). The JSON Schema and YAML
  readers they use are in `tests/drivers` and implement only what the specs
  use; they refuse anything else with a message (see the headers of
  `jsonschema.zig` and `yaml.zig`). The Python scripts of the remaining checks
  stay for `ci.yml` until `farm.yml` has matched it, and are deleted
  then.
  The Mojo end-to-end suites run on the farm with no pixi, shell or Python:
  `//:autolink` (`tests/drivers/test_autolink_test.zig`), `//:discovery`,
  `//:supervisor` and `//:flaky` (drivers `tests/drivers/test_*_test.zig`; the
  shell and Python scripts they replaced are deleted). They use the Mojo 1.0.0 compiler komira
  pins (`komira//tools/build/toolchains:mojo_compiler`, handed over as a
  directory), komira's zig as the C compiler (`zig cc`, through
  `tests/drivers/zigcc.zig`: `mojo build` links through `cc` on `PATH`), and
  the built `mopm`; `//:mojo_probe` shows the toolchain works from this cell.
  `//:native_static` (farm only, with `tests/drivers/mojo_compile_shim.zig` as the toolchain's `mojo_compile`) takes a
  static archive in an empty-module package from `mopm pack` and `mopm lock` to a test linked by `mopm unit test`.
  The same drivers run natively on the GitHub runners (Linux x86_64, Linux
  aarch64, macOS arm64) from `ci.yml`: `zig build test-autolink`,
  `test-discovery`, `test-supervisor` and `test-flaky` (`test-e2e` runs all
  four) with `-Dmojo-env=<pixi environment>` (`tests/e2e/pixi.toml`, mojo
  1.0.0) and the system C compiler.
  The pinned compiler closure has no lldb, so `mojo repl` cannot run there and
  the REPL checks print `SKIP` (they run if the toolchain gains
  `bin/mojo-lldb`), so the REPL is not exercised in CI until then.
  The repository's own lints are Zig tests too: `//:hygiene`
  (`tests/drivers/hygiene.zig`, over every file of the repository),
  `//:workflows` (`tests/drivers/workflow_lint.zig`, over the workflows) and
  `//:lint_selftest` (both lints over `tests/lint/fixtures`, against the table in
  `tests/drivers/lint_selftest_test.zig`). Those readers are lenient about YAML, so `//:actionlint` also runs the pinned actionlint (1.7.12, as buildrules pins it) over every workflow, a strict parse (`lint.yml` installs the same release with `tools/install_actionlint.zig`). `farm.yml` runs them with `//...` (and fails a push to
  `main` when the farm is not configured); `lint.yml` runs the same three tests with `zig test` on a
  GitHub-hosted runner for every pull request, forks included, and every push to `main`, with no
  secret and a read-only token (without `BUILDRULES_TEST_WORK` they read the files `git ls-files`
  lists). The
  farm has no bash, so the syntax check of `run:` scripts is not `bash -n`: `tests/drivers/shell_syntax.zig` stands in for
  it (unterminated quotes and expansions, unbalanced `if`/`fi`, `do`/`done`,
  `case`/`esac`, braces and parentheses; not the rest of bash's grammar).
  Without a farm configured (`.buckconfig.local`, gitignored) the actions run on
  your machine.

### The service packages (TypeScript) on the farm

`service/api` and `service/infra/{stacks,dns,access}` have Buck2 targets that run the
commands `service-ci.yml` runs, on the farm, from pinned npm packages instead of
`npm ci` (`service-ci.yml` stays as it is until these match it):

| target | the command it replaces |
|---|---|
| `//service/api:typecheck`, `:test`, `:dist`, `:dist_has_handler` | `tsc --noEmit`, `jest --ci` (2 workers), `npm run build` (esbuild: one self-contained file per handler) and `test -f dist/http/lambda.js` |
| `//service/infra/{stacks,dns,access}:typecheck`, `:test` | `tsc --noEmit` and `jest --ci` |
| `//service/infra/stacks:synth_{beta,gamma,prod}` | `cdk synth` of each stage with a dummy account and zone id; the API bundle is `//service/api:dist` and the site build `//site:dist` (the stack refuses to synthesize without it); the synths, `:typecheck` and `:test` also take `site/src/routes.ts` (the edge router's grammar) and `site/test/fixtures/routes.json` (its vectors) |
| `//service/infra/dns:synth_{beta,gamma,prod,delegation}` | the four `cdk synth` runs with dummy values |
| `//site:typecheck`, `:test`, `:dist`, `:dist_has_pages` | the site job's `npm run typecheck` (both runs), `npm test`, `npm run build` and its `test -f dist/<page>` checks (`site/README.md`) |

The API and the site use buildrules' `npm_package(path = ".")` (`buildrules.lock.bzl` is generated by `buildrules npm sync service/api site` after `npm install`; `buildrules npm check` and the `:check` target fail on a lock changed without it). The infra packages use buildrules' `npm_modules` rule, which lays out each package's `node_modules` from its
`package-lock.json` and one pinned tarball per package (`service/infra/*/pins.lock.bzl`: URL, sha256 and
size, checked against the lockfile's sha512 integrity); no install script runs, there is no network and no
shell or Python. Node.js is pinned in `tools/node/pins.toml`. The tests that read files outside their
package get them as `data` (the specification and contract cases for the API, the access policy template,
the stages' configuration and the API's golden grants for the stacks). The held commands (`bootstrap`, `oauth-secret` and `dns-cli`, TypeScript under `bin/` and `lib/`) are tested by
jest against a fake host, so `:test` covers them.

After `npm install` or `npm update` changes a `package-lock.json`, regenerate its pins (kpin is
buildrules' tool, `./buck2 run buildrules//rules/kpin`), then commit the lock with the lockfile:

```sh
./buck2 run buildrules//rules/kpin -- update --pins service/pins.toml \
    --lock service/infra/stacks/pins.lock.bzl --npm service/infra/stacks/package-lock.json
./buck2 run buildrules//rules/kpin -- check --pins service/pins.toml \
    --lock service/infra/stacks/pins.lock.bzl --npm service/infra/stacks/package-lock.json
```

`update` fetches what the lock lacks; `check` is offline and fails (exit 3 for a changed hash) when the lock
is not what the lockfile says. The build fails, naming the package, when a lockfile package has no
tarball in `pins.lock.bzl`.

`.github/workflows/kpin-update.yml` runs the same two commands every Monday (and on demand) for every lock here
(`tools/node` and the three infra packages under `service/infra`), on a GitHub-hosted runner with no farm, and, when a file changed,
pushes a new branch `kpin/weekly-<run id>` (a plain push, never a force-push) and opens a pull request from it, then
closes the older open `kpin/weekly-*` pull requests (a comment links the new one) and deletes their branches. It uses the default `GITHUB_TOKEN` only. Exit 3
(a changed hash for a version already pinned) fails the job and opens nothing. Two limits: the repository
setting "Allow GitHub Actions to create and approve pull requests" must be on, and a pull request opened with
`GITHUB_TOKEN` starts no other workflow, so push an empty commit to its branch (or close and reopen the pull
request) to run its checks. A new `pins.lock.bzl` needs a line in the workflow's `KPIN_SETS`; `//:hygiene` fails the pull request that adds one without it (the job itself fails until
it has one). kpin's fetcher speaks TLS 1.3 only (buildrules' `rules/kpin/README.md`): `registry.npmjs.org`
answers TLS 1.2 only, so `update` cannot fetch a new npm tarball from a runner or from here today, and the job
fails on a lock that lacks one.

A Dependabot bump of a `package-lock.json` leaves its pin table stale. `autopin-compute.yml` and `autopin-commit.yml` regenerate
the tables of Dependabot's own pull requests with the released `buildrules autopin` and commit them to the pull request's branch
(the design, the trust each workflow holds and what an owner sets up first: `RELEASING.md`, "The Dependabot pin update"; nothing of it runs
before the GitHub App is installed). `pin-verify.yml` is the required check on every pull request that every table it covers (`site/` and `service/api/`) is what its lockfile
calls for, so a hand-made `package-lock.json` change needs the same regenerated table: `./buck2 run buildrules//rules/kpin` for the
infra packages, which the bot does not touch (their lockfiles bundle packages, aws-cdk-lib with transitive bundles, that the tool refuses; `RELEASING.md` says which), `buildrules npm sync <dir>` for `site/` and `service/api/`. A bot-pinned pull request is not a reviewed
dependency: read the lockfile diff. A Dependabot branch gets no farm build (`farm.yml` skips it), and a pull request that touches
`.github/` is never pinned by the bot and is checked by its own copy of `pin-verify.yml`, so read the workflow change. A new package with a
`package-lock.json` needs a `--set` line in `autopin-compute.yml` (and the same in the other three invocations) and a `dependabot.yml` entry, or a place in `autopin_manual` of
`tests/drivers/hygiene.zig` with the reason; `//:hygiene` fails the pull request that adds one without. Changes to the autopin workflows are held by `tests/drivers/autopin_lint.zig`
(`zig test tests/drivers/autopin_lint_test.zig`, also `//:autopin_workflows`): add a planted mutant with any rule you add.

`.github/workflows/advisories.yml` scans every tracked `package-lock.json` and `Cargo.lock` for known
vulnerabilities once a day (and on demand), with a pinned, sha256-verified OSV-Scanner
(`tools/install_osv_scanner.zig`). It only reports: findings go to the job summary and to one issue titled
`Advisories` (opened or updated while there are findings, closed when there are none), and it never runs on a pull
request or a push, so an advisory cannot block a pull request or turn `main` or a release red. The job fails only
when the scan cannot run (the download does not match its sha256, or the scanner exits above 1), on the scheduled run.

A source file you add under `src/core`, `src/cli` or `registry/fake` is picked
up by both (Buck2 takes each directory by glob; it skips dotfiles, so a new
dotfile under `tests/` is named in `BUCK`). A new root source file, executable,
module or `addTest` in `build.zig` needs the matching `zig_exe`, `zig_module`
or `zig_test` in `BUCK`: `//:build_parity` (`zig test tools/build_parity.zig`
from the root) fails when they differ. A call in `BUCK` with no `build.zig`
counterpart (a helper, a driver) says `buck-only` on its first line.

The unit tests read `tests/...` relative to the working directory, the
repository root under `zig build test` and in the Buck2 action; a runner that
starts them elsewhere sets `MOPM_SOURCE_ROOT` (`src/core/testroot.zig`). The
supervisor tests (`src/core/test_proc.zig`) run `/bin/sh -c` scripts, or, when
`MOPM_TEST_CHILD` names `tests/drivers/proc_child.zig`, the same behaviour from
that program.
