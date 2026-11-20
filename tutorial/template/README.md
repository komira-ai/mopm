# The tutorial's sandbox template

The interactive tutorial runs each lesson in an [E2B](https://e2b.dev) sandbox with the internet turned off, so the
sandbox has to hold everything a run needs. This package defines that sandbox's E2B template, and has the command an
operator runs to build it. The design is `docs/design/tutorial-sign-in.md`, section 4, "The template".

The template holds:

- mopm, the release named below: its `linux-x86_64` file downloaded from the GitHub release, checked against the
  sha256 the release's `SHA256SUMS` lists for it (read when the build runs, and written into the step), and its
  binary installed at `/usr/local/bin/mopm`;
- `/etc/profile.d/mopm-tutorial.sh`, which sets `MODULAR_TELEMETRY_ENABLED=false` for every command run in the
  sandbox (E2B runs them as `bash -l`). The sandbox has no internet, so the Mojo toolchain's telemetry can never be
  sent, and with it on, every `mopm run` waited about 20 s after the program's output for the export to give up;
- every lesson under `tutorial/lessons/<id>/`: its `project/` copied to `/home/user/lessons/<id>/`, that directory
  and `/home/user/lessons` given to `user` (E2B's copy creates them as root), and `mopm sync --locked` run there as
  `user`, so the lesson's pinned Mojo toolchain and locked packages are already installed;
- `user` (E2B's default sandbox user) and `/home/user` as the sandbox's user and working directory.

The definition is `src/definition.ts`, written with the `Template()` builder of the `e2b` package (pinned exactly in
`package.json`; E2B, "Template quickstart"). It reads `tutorial/lessons/*/` when it runs, so adding a lesson needs no
edit here. A lesson is refused, not skipped, when its id is not lower-case words joined by hyphens or its `project/`
has no `mopm.toml` or `mopm.lock`. A lesson's `.mopm/` (what `mopm sync` writes on your machine) is never uploaded:
the template syncs its own.

**Which mopm.** The release is of the base in the repository's `VERSION` (`MAJOR.MINOR`; RELEASING.md, "How the
version is computed"): by default the latest release, looked up on GitHub when the build runs, and refused if it is
of another base (for example just after `VERSION` was raised, before the first release of the new base). Pass
`--mopm-version X.Y.Z` to name one; it too must be a release of that base.

## Building it (operator step, never in CI)

Building needs the stage's E2B team key. Nothing in CI or on the farm runs this command; the tests use fakes.

You need Node.js 22.19 or later (what `e2b` requires; the repository pins 24.21.0 in `tools/node/pins.toml`) and a
checkout of the commit whose lessons the template should hold.

```sh
cd tutorial/template
npm ci --ignore-scripts --no-audit --no-fund

# 1. The dry run (the default): prints the stage, name, mopm release, lessons and every step. It makes no network
#    call and needs no key, so the release's sha256 is shown as a placeholder.
npm run template -- --stage beta --name mopm-tutorial-beta

# 2. The build. The key is read from E2B_API_KEY, E2B's own variable, and only with --build. It is passed to E2B
#    as the API key and printed nowhere: build logs and errors show it as <redacted>.
read -rs E2B_API_KEY && export E2B_API_KEY
npm run template -- --stage beta --name mopm-tutorial-beta --build
unset E2B_API_KEY
```

With `--build` it first reads the latest release (unless `--mopm-version` names one) and the release's
`SHA256SUMS` from GitHub, and stops if the file is not listed exactly once with a sha256. The build prints
`template id: <id>` and `build id: <id>`. Set the template id as the stage's tutorial template in
the stage's settings; the sandbox route creates sandboxes from it.

Flags:

| flag | meaning |
|---|---|
| `--stage beta\|gamma\|prod` | required; the stage the template is for (any other value is refused) |
| `--name <name>` | required; the E2B template name: lower-case letters, digits, `-` and `_` |
| `--mopm-version X.Y.Z` | optional; the mopm release to install, which must be a release of `VERSION`'s base |
| `--build` | build on E2B; without it the command is a dry run |

Exit codes: 0 done, 1 failed (nothing built, or E2B's error printed), 2 usage.

## Tests

`//tutorial/template:test` and `:typecheck` (`npm test`, `npm run typecheck`), with the coverage floor
`:coverage_floor` (`coverage_floor.txt`). The tests build the definition from small repositories made under
`build/test-scratch` and from this repository's own `VERSION` and `tutorial/lessons`, and run the command with a fake
`fetch` and a fake E2B build: no network, no key. One test runs E2B's own file selection (`test/upload-hashes.ts`,
in a child Node process, because it needs a dynamic import Jest cannot run) to check that a lesson's `.mopm/` is
not uploaded.
