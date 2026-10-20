# Contributing

- Tooling is written in Zig 0.12.0. Run `zig build test` from the repository
  root before opening a pull request; CI runs it on Linux (x86_64, aarch64) on
  every pull request, and on macOS (arm64) after the merge (push to `main`), nightly,
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
  `//:registry_publish` (the checks of `tests/registry_e2e/*.py`), and the
  contract checks: `//:contract` (`tests/contract/validate.py`: the OpenAPI
  document, the JSON Schemas, the API cases and the examples),
  `//:contract_replay` (`replay.py`: the fake registry against the API
  cases), `//:lock_golden` (the lock goldens; it replaced `tests/resolve/check_golden.py`) and
  `//:resolve_e2e` (it replaced `tests/resolve_e2e/run.py`). The JSON Schema and YAML
  readers they use are in `tests/drivers` and implement only what the specs
  use; they refuse anything else with a message (see the headers of
  `jsonschema.zig` and `yaml.zig`). The Python scripts of the remaining checks
  stay for `ci.yml` until `farm.yml` has matched it, and are deleted
  then.
  The Mojo end-to-end suites run on the farm with no pixi, shell or Python:
  `//:autolink` (`tests/e2e/run.sh`), `//:discovery` (`test_discovery.sh`),
  `//:supervisor` (`test_supervisor.sh`, `check_supervisor.py`) and `//:flaky`
  (`test_flaky.sh`, `check_flaky.py`). They use the Mojo 1.0.0 compiler komira
  pins (`komira//tools/build/toolchains:mojo_compiler`, handed over as a
  directory), komira's zig as the C compiler (`zig cc`, through
  `tests/drivers/zigcc.zig`: `mojo build` links through `cc` on `PATH`), and
  the built `mopm`; `//:mojo_probe` shows the toolchain works from this cell.
  The pinned compiler closure has no lldb, so `mojo repl` cannot run there and
  the REPL checks print `SKIP` (they run if the toolchain gains
  `bin/mojo-lldb`); `ci.yml` still runs them against the pixi environment.
  The repository's own lints are Zig tests too, with no Ruby: `//:hygiene`
  (`.github/scripts/hygiene.rb`, over every file of the repository),
  `//:workflows` (`.github/scripts/workflow_lint.rb`, over the workflows) and
  `//:lint_selftest` (`tests/lint/run.rb`: both lints over `tests/lint/fixtures`,
  against the table in `run.rb` itself, which it refuses to differ from). The
  Ruby scripts stay for `ci.yml` until `farm.yml` has matched it; change a rule in
  both. One rule is not the same: `workflow_lint.rb` runs `bash -n` on each `run:`
  script and the farm has no bash, so `tests/drivers/shell_syntax.zig` stands in for
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
| `//site:typecheck`, `:typecheck_browser`, `:test`, `:dist`, `:dist_has_pages` | the site job's `npm run typecheck` (two runs), `npm test`, `npm run build` and its `test -f dist/<page>` checks (`site/README.md`) |

komira's `npm_modules` rule lays out each package's `node_modules` from its
`package-lock.json` and one pinned tarball per package (`service/*/pins.lock.bzl`: URL, sha256 and
size, checked against the lockfile's sha512 integrity); no install script runs, there is no network and no
shell or Python. Node.js is pinned in `tools/node/pins.toml`. The tests that read files outside their
package get them as `data` (the specification and contract cases for the API, the access policy template,
the stages' configuration and the API's golden grants for the stacks). The bash tests of `dns.sh`,
`bootstrap.sh` and `oauth-secret.sh` stay in `service-ci.yml`.

After `npm install` or `npm update` changes a `package-lock.json`, regenerate its pins (kpin is
komira's tool, `./buck2 run komira//tools/build/kpin`), then commit the lock with the lockfile:

```sh
./buck2 run komira//tools/build/kpin -- update --pins service/pins.toml \
    --lock service/api/pins.lock.bzl --npm service/api/package-lock.json
./buck2 run komira//tools/build/kpin -- check --pins service/pins.toml \
    --lock service/api/pins.lock.bzl --npm service/api/package-lock.json
```

`update` fetches what the lock lacks; `check` is offline and fails (exit 3 for a changed hash) when the lock
is not what the lockfile says. The build fails, naming the package, when a lockfile package has no
tarball in `pins.lock.bzl`.

`.github/workflows/kpin-update.yml` runs the same two commands every Monday (and on demand) for every lock here
(`tools/node` and the four service packages), on a GitHub-hosted runner with no farm, and, when a file changed,
pushes a new branch `kpin/weekly-<run id>` (a plain push, never a force-push) and opens a pull request from it, then
closes the older open `kpin/weekly-*` pull requests (a comment links the new one) and deletes their branches. It uses the default `GITHUB_TOKEN` only. Exit 3
(a changed hash for a version already pinned) fails the job and opens nothing. Two limits: the repository
setting "Allow GitHub Actions to create and approve pull requests" must be on, and a pull request opened with
`GITHUB_TOKEN` starts no other workflow, so push an empty commit to its branch (or close and reopen the pull
request) to run its checks. A new `pins.lock.bzl` needs a line in the workflow's `KPIN_SETS`; the job fails until
it has one. kpin's fetcher speaks TLS 1.3 only (komira's `tools/build/kpin/README.md`): `registry.npmjs.org`
answers TLS 1.2 only, so `update` cannot fetch a new npm tarball from a runner or from here today, and the job
fails on a lock that lacks one.

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
