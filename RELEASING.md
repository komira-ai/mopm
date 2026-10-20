# Releasing mopm

Releases are automatic. Nobody tags, approves or runs a release by hand. A pull request that merges to
`main` and changes more than documentation or CI releases itself once every gate is green; a red stage
stops the release, and the next green push to main releases instead.

mopm is a customer-facing tool, so the last gate before anything is tagged is the candidate used the way a
customer uses it, on every platform it ships for (`beta-user`).

## What happens on a push to main

`.github/workflows/release.yml` runs these stages; each needs the ones named:

| stage | needs | what it does |
|---|---|---|
| `beta` | | the whole of `ci.yml` on the pushed commit (unit, golden, contract and end-to-end tests, on Linux and macOS). |
| `lint` | | the whole of `lint.yml` (hygiene, workflow lint, the release lint with its planted mutants). |
| `plan` | `beta`, `lint` | the version this commit's release will have (`cut_release plan --sha`). Writes nothing. Refuses a commit that a newer release supersedes (below) and a `VERSION` base below an existing tag. Gamma and bake time are a slot for later stages between `lint` and `plan`. |
| `build` | `plan` | the four binaries (`linux-x86_64`, `linux-aarch64`, `macos-arm64`, `macos-x86_64`) at that version, each reporting exactly it. **These are the release files.** They are built once, before the tag, from the commit that is tagged later, and are not rebuilt. |
| `beta-user` | `plan`, `build` | the candidate tested as a user (below), on linux x86_64, linux arm64 and macOS 14 (arm64). A red leg on any platform stops the release. |
| `tag` | `plan`, `build`, `beta-user` | creates the annotated tag `v<version>` at the pushed commit. The only write before the files are published. Refuses a superseded commit, and refuses unless the version it would take is the planned one (`--expect-version`), so the tested bytes are the released bytes. |
| `attest` | `tag`, `build` | `SHA256SUMS` for the four tarballs, a keyless cosign signature (Sigstore) of each of the five files, and build provenance (a signed attestation) for all five. |
| `verify` | `tag`, `build`, `attest` | checks the built files before anything is published: exactly the ten files (the five and the `<file>.sigstore.json` bundle of each), `SHA256SUMS` matches, every attestation and every signature accepted and pinned to `release.yml`, the ref and the commit, the tarball layout, the tag on main and at this commit. Uploads the release notes and the pin (the `linux-x86_64` url, sha256 and size) as the artifact `release-notes`. |
| `publish` | `tag`, `verify` | creates the GitHub release for `v<version>` from exactly the verified files (artifacts `verified-assets` and `release-notes`, nothing else). |
| `bump` | `tag`, `publish` | opens the pull request in komira-internal that moves its `mopm` submodule to this release, with auto-merge (below). The last stage, and the only one that writes outside this repository; nothing needs it. |

A push that changes only documentation or CI (`**.md`, `docs/**`, `.github/**`) does not release.
Everything else does, including a change to `VERSION`.

Only `tag` and `publish` may write `contents` here, each under `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` (`bump` runs under the same `if:` and holds `contents: read`);
only `attest` holds `id-token` and `attestations` write. `tests/drivers/release_lint.zig` holds the workflow to
that, to the order of the stages, to the data flow between them (the built and tested version is the planned
version, the tagged version and the released version; `publish` releases the verified files) and to the path filter;
`release_lint_test.zig` plants a defect for each rule and requires it to go red. The same file holds
`release-beta-user.yml`: exactly the three platform legs, none skippable, optional or allowed to fail.

Pushes share the concurrency group `release-push` (one run at a time, none cancelled). GitHub keeps one pending run
per group, so if several pushes land while a release runs, only the newest waits: it releases a commit that
contains the others. A manual run has a group of its own, so it cannot displace the pending push release.

## The komira-internal bump (the last stage)

After `publish`, the `bump` job (push to main only, `permissions: contents: read`) opens a pull request in
komira-ai/komira-internal that moves its `mopm` submodule to the released commit, and turns auto-merge on:
`cut_release bump-internal` (`tools/bump_internal.zig`; `gh` and `git`, no shell). komira-internal merges it on its own
when its `check` and `bump-guard` pass; nobody clicks.

- **The token.** The job builds the tool first, then mints an installation token of the GitHub App `komira-release-bot`
  with `actions/create-github-app-token` (pinned by commit; `vars.RELEASE_BOT_APP_ID`, `secrets.RELEASE_BOT_PRIVATE_KEY`, owner
  `komira-ai`, repository `komira-internal` only), and gives it to the one step that runs the tool as `GH_TOKEN`. The App is
  installed on komira-internal only, so the token reaches nothing else. The tool never puts the token in an argument: `gh`
  reads it from the environment, and `git` gets it as an HTTP header through `GIT_CONFIG_*` in its environment. The release
  lint holds that this job alone names the App token, that it holds no write scope here, and where the token lives.
- **What the pull request is.** What komira-internal's bump guard (`tools/bump_guard/README.md` there) accepts from the bot and
  nothing else: author `komira-release-bot[bot]`; exactly one changed path, the `mopm` gitlink; branch `bump/mopm-v<version>`;
  the new commit descends from the old; the tag `v<version>` of komira-ai/mopm names that commit. The tool sets the gitlink
  with `git update-index --cacheinfo 160000,<sha>,mopm` on a shallow clone (no submodule is checked out), checks that the
  staged change is that one gitlink, commits `chore(mopm): bump to v<version>` (the release url in the body) as the bot user,
  pushes the branch (never forced), runs `gh pr create` and `gh pr merge --auto --merge`, and checks that auto-merge is on. It
  refuses, before writing anything, what the guard would refuse: a tag that names another commit, an old gitlink that is not an
  ancestor of the release commit.
- **Idempotent.** An open or merged bump pull request for this or a newer version means there is nothing to open (an open one
  for this version that lacks auto-merge gets it). An older open bump pull request is closed in favour of the new one. A
  branch an earlier run pushed before it stopped is reused.
- **A failed bump un-releases nothing.** The release is complete when `publish` is green; no job needs `bump`, so a red
  `bump` changes nothing else, it only shows the run as failed. To retry, re-run the `bump` job of that run (Actions, the
  run, "Re-run failed jobs" or the job's own re-run): it is safe to run again, it finds what exists and finishes the rest.
  If a newer release has already bumped, the re-run does nothing.

## The user-level beta

`.github/workflows/release-beta-user.yml` (also run on a pull request that touches the release files, by
`release-check.yml`) uses pinned tools only, and takes the tarball that
`build` produced. On each platform `tests/drivers/user_beta.zig` (Zig, no shell) takes the candidate binary and
walks the verbs against a fake registry (`registry/fake`) that it starts, asserting each step's output and exit
status:

1. create: `new --lib`, `new --bin`, `init`, `metadata`;
2. test: `test --list`, `test`, and a planted failing test that must turn `test` red;
3. account: `login` (device flow approved on the fake), `whoami`;
4. publish to the test registry: `pack`, `publish --dry-run`, `publish`; the registry serves the version, the
   sparse index and the channel with the packed sha256; publishing the same version again is refused;
5. dependencies: `add`, `tree`, `lock`, `update`, `sync` (download, sha256 check, pixi installs the published package);
6. `build` and `run` a program and the one that imports the package just published; `test` again;
7. `remove`, `logout`;
8. the documented install path: `site/static/install.sh` with `MOPM_RELEASES_URL` at a directory laid out like a
   GitHub release holding the candidate, then the installed `mopm --version` must equal the candidate version and
   the installed file must be the candidate byte for byte; a `SHA256SUMS` that lies installs nothing.

The Mojo toolchain is the pinned pixi environment of `tests/e2e/pixi.toml`, as in `ci.yml`. Not walked: `repl`
(`tests/e2e/run.sh` and `//:autolink` run it against the real mojo), `link-plan`, `plan` and `unit` (offline planners
with golden tests). The `macos-x86_64` tarball is built (under Rosetta) and its `--version` is checked at build time,
but no runner executes the user walk for it.

On the build farm `//:user_beta` runs the same driver without pixi and without the installer (the farm has neither);
those steps print `SKIP`, they are never counted as passed.

## A superseded commit (the re-run hazard)

Re-running an old run after a newer release exists must not tag the old commit with the next number: `install.sh`
installs the latest release, so users would be moved back to older code. `cut_release plan --sha` and `tag` find the
highest tag `v<base>.N` and require its commit to be the pushed commit or an ancestor of it (GitHub's compare says
`identical` or `ahead`); otherwise they stop with `superseded`, before anything is built or written. `publish` also
refuses to create release `v<base>.M` when a higher `v<base>.N` exists. The exact tip of main is deliberately not
required: pushes land while a run waits for the macOS runners, and that would starve releases. The base
(`MAJOR.MINOR` of `VERSION`) may not go backwards: `plan` and `tag` refuse a base below any existing release tag's.

## How the version is computed

The file `VERSION` holds the base, `MAJOR.MINOR`, for example `0.0`. The release run adds the PATCH:

- PATCH is one more than the highest existing tag `v<base>.N` (or release of that tag, draft or published),
  compared as a number: `v0.0.9` and `v0.0.10` give `0.0.11`.
- When none exists, PATCH is `1`: the first green run on base `0.0` releases `0.0.1`.
- Tags of other bases, tags with a suffix and anything that is not a plain number are ignored when counting
  (`v0.0.5` does not count towards base `0.1`), but a tag of a higher base stops the run (above).
- The tag is created by the API, which fails if the tag exists, so two runs never share a number. If that
  happens the run recomputes and tries once more, and `--expect-version` then refuses because the candidate was
  tested as another version; a re-run of a run that already tagged its commit reuses that tag.

The binary's version comes from the build, not from the source: `zig build -Dversion=<version>` (the release
tool passes it) and `mopm --version` prints `mopm <version>`, for example `mopm 0.0.1` (no `v`; the tag and the
release are `v0.0.1`). A build without the option, such as `zig build` or the Buck2 targets, reports the
development version `0.0.1+dev` (`src/cli/build_options.zig` holds it for Buck2; the two defaults must agree,
and the golden test checks `--version`).

## Bumping MAJOR.MINOR

Open an ordinary pull request that changes `VERSION` (for example `0.0` to `0.1`) and merge it. The push
releases `0.1.1`. This is rare; PATCH is never edited by hand, and the base never goes down.

## A dry run

Run the `release` workflow by hand (Actions, `release`, Run workflow) on `main`. It runs `beta`, `lint`, `plan`,
`build` and `beta-user`: the candidate is built and tested on every platform, and `plan` prints the version the
next release would get. It creates no tag and publishes nothing (`tag`, `attest`, `verify`, `publish` and `bump` do not run).

## A re-run and a failure

- A red `beta`, `lint`, `build` or `beta-user` stops everything: nothing is tagged. Fix main; the next push releases.
- If `attest`, `verify` or `publish` fails after the tag exists, the tag stays. Re-running the failed run reuses the
  tag (it is the highest and names this commit; `plan` reports its version). If a newer release exists by then, the
  re-run stops with `superseded` and the old tag stays as a gap.
- Re-run "failed jobs" rather than the whole run when only a late stage failed: it keeps the tested candidate. A job
  that is re-run uploads its artifact again with `overwrite: true` (a plain re-upload of the same name fails with a
  409); a rebuilt `build` always re-runs `beta-user`, because `beta-user` needs it. Re-running a single `build` leg by
  hand after `beta-user` passed would ship bytes that were not tested: do not; re-run the failed run.
- If `publish` fails half-way, re-running creates no second release and replaces no asset: every asset the
  release already holds must match the verified file byte for byte, and only missing ones are added. A
  mismatch fails the run and changes nothing; a draft release of the tag fails it too (delete the draft by hand).
- If `bump` fails, the release stands (it is already published and verified). Re-run the `bump` job; see "The komira-internal
  bump". A bump that cannot succeed because the tag or the old gitlink does not allow it (it refuses with the reason) is
  fixed in komira-internal by hand: move the submodule there with an ordinary pull request.

## Verifying a download

Every release asset is attested and signed by `release.yml` of this repository. `install.sh` checks the sha256 of
the tarball against the release's `SHA256SUMS`. A customer who wants more, for a file `F` of release `v1.2.3`:

    gh attestation verify F -R komira-ai/mopm --signer-workflow komira-ai/mopm/.github/workflows/release.yml
    cosign verify-blob --bundle F.sigstore.json \
      --certificate-identity https://github.com/komira-ai/mopm/.github/workflows/release.yml@refs/heads/main \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com F

The signature is keyless (Sigstore): there is no key to leak or rotate; the certificate names the workflow, the ref
and the commit, and the signing is recorded in the Sigstore transparency log. The release notes repeat these lines.

Maintainers can repeat all the checks against GitHub with the read-only `verify <version> <empty dir>` of
`tools/cut_release.zig` (needs `gh` and `cosign`):

    zig build-exe tools/cut_release.zig -femit-bin=<path>
    <path> verify 0.0.1 <empty dir>

It prints the pin for the `linux-x86_64` tarball. It changes nothing.

## What the CEO has to do before the first release

The bump stage needs, once: the GitHub App `komira-release-bot` installed on komira-internal only; the variable
`RELEASE_BOT_APP_ID` and the secret `RELEASE_BOT_PRIVATE_KEY` in this repository; auto-merge allowed in komira-internal, with
its ruleset requiring `check` and `bump-guard`. (Done.) Without them `bump` fails and nothing else does.

These are settings only an owner can change; the automation neither makes nor assumes them:

1. **A tag ruleset for `v*`** (Settings, Rules, Rulesets, target: tags, pattern `v*`): restrict updates and deletions,
   so a released tag can never be moved. The workflow creates tags with the default token, so the ruleset must not
   block creation by GitHub Actions.
2. **Immutable releases** (Settings, General, Releases): enable, so a published release's assets cannot be replaced.
3. **Apple Developer ID**: macOS binaries are not code-signed or notarized yet, because that needs an Apple Developer
   ID certificate (a paid Apple Developer Program membership) and an app-specific password or API key for
   `notarytool`, stored as repository secrets. Until then a downloaded macOS binary is not trusted by Gatekeeper when
   it is opened from a browser (`install.sh` uses `curl`, which does not set the quarantine flag, so the installer path
   works). The release pipeline does not pretend otherwise: the signatures and attestations above prove who built the
   file, not that Apple has seen it. Adding `codesign` and notarization is a stage between `build` and `attest` once
   the certificate exists.
4. **The mopm.dev deploy stays held.** The site serves `site/static/install.sh` as it is; the installer reads the latest
   release at run time, so a release changes nothing on the site and needs no new site artifact (there is no version or
   download section whose text a release would have to change). The production site artifact is the installer file,
   deployed by the site's own deploy.
