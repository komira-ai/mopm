# Releasing mopm

Releases are automatic. Nobody tags, approves or runs a release by hand. A pull request that merges to
`main` and changes more than documentation or CI releases itself once every gate is green; a red stage
stops the release, and the next green push to main releases instead.

mopm is a customer-facing tool, so the last gate before anything is tagged is the candidate used the way a
customer uses it, on every platform it ships for (`beta-user`).

## What a pull request runs

A pull request runs build and unit tests only. Nothing of the release runs on it: no release dry run, no packaging, no signing, attesting or
verifying, and no beta. The tiers:

| tier | what | when |
|---|---|---|
| unit (each library) | `ci.yml` `test` (`zig build test`) and `registry-build`; `service-ci.yml` (typecheck and tests of the API, site, stacks, DNS and access packages, and the CDK synth with dummy values); `farm.yml` (on the test farm, the tests are welded into the targets: a pull request builds every target except the beta ones that run against the real Mojo, `//:autolink`, `//:discovery`, `//:flaky`, `//:install_e2e`, `//:mojo_probe`, `//:native_static`, `//:supervisor` and `//:user_beta`; a push to main builds `//...`) | every pull request, and a push to main |
| lint | `lint.yml`: hygiene, workflow lint, lint self-test, **the release lint of `release.yml`** (so a broken `release.yml` still fails a pull request) and actionlint | every pull request, and a push to main |
| pin check | `pin-verify.yml`: every pin table (`buildrules.lock.bzl`, `pins.lock.bzl`) is what its `package-lock.json` calls for; secretless, no condition, so it always reports (`autopin-compute.yml` runs only for Dependabot's own pull requests; see "The Dependabot pin update") | every pull request |
| beta (each component) | `ci.yml` `mojo-e2e`, `pack-conformance` and `installer`; then `release-beta-user.yml`, the candidate used as a user | after the merge only: `release.yml` stage `beta` (the whole of `ci.yml`) and stage `beta-user` |
| gamma (the whole system, real consumers) | `promote.yml` (`deploy.yml`, `e2e.yml`) | after a release, never on a pull request |

No job of this repository measures coverage today, so none is reported. `tests/drivers/hygiene.zig` holds the split: only `ci.yml`, `lint.yml`, `farm.yml`,
`service-ci.yml`, `pin-verify.yml` and `autopin-compute.yml` may run on `pull_request`, and every job of `ci.yml` other than `test` and `registry-build` must carry
`if: github.event_name != 'pull_request'`. The `.deb` checks (dpkg and lintian) run inside `release-build.yml`, in the `build` stage.

## What happens on a push to main

`.github/workflows/release.yml` runs these stages; each needs the ones named:

| stage | needs | what it does |
|---|---|---|
| `beta` | | the whole of `ci.yml` on the pushed commit: the unit tier a pull request runs (unit and golden tests, the CLI and fake registry build), then the beta tier that never runs on a pull request (the CLI against the real Mojo, the packer against the registry validator, `install.sh` against a fake release), on Linux and macOS. |
| `lint` | | the whole of `lint.yml` (hygiene, workflow lint, the release lint with its planted mutants). |
| `plan` | `beta`, `lint` | the version this commit's release will have (`cut_release plan --sha`). Writes nothing. Refuses a commit that a newer release supersedes (below) and a `VERSION` base below an existing tag. Gamma and bake time are a slot for later stages between `lint` and `plan`. |
| `build` | `plan` | the three binaries (`linux-x86_64`, `linux-aarch64`, `macos-arm64`) at that version, each reporting exactly it, and a `.deb` (`amd64`, `arm64`) for each linux binary, packaged by `tools/channels deb-package` from the binary inside the tarball just made (metadata in `packaging/deb/`). **These are the release files.** They are built once, before the tag, from the commit that is tagged later, and are not rebuilt. |
| `beta-user` | `plan`, `build` | the candidate tested as a user (below), on linux x86_64, linux arm64 and macOS 14 (arm64). A red leg on any platform stops the release. |
| `attest` | `plan`, `build`, `beta-user` | refuses unless each tarball is the exact file the user beta passed (`release tested`), also refuses unless each `.deb` is, byte for byte, the one that its tarball's binary makes, then writes `SHA256SUMS` for the three tarballs and the two `.deb`s, a keyless cosign signature (Sigstore) of each of the six files, and build provenance (a signed attestation) for all six. Runs only on `main` (`if: github.ref == 'refs/heads/main'`), so a manual run from another branch signs and attests nothing; `verify` and the rest are skipped with it. Uploads the artifact `signed-assets`. |
| `verify` | `plan`, `build`, `attest` | read-only, before any tag exists: exactly the twelve files (the six and the `<file>.sigstore.json` bundle of each: three tarballs, two `.deb`s, `SHA256SUMS`), `SHA256SUMS` matches, each `.deb` rebuilt from its tarball's binary and equal byte for byte, every attestation and every signature accepted and pinned to `release.yml`, the ref, the commit, the trigger (the event of this run: `push` for a release, `workflow_dispatch` for a dry run) and the repository, the tarball layout, the commit on main. Uploads the release notes and the pin (the `linux-x86_64` url, sha256 and size) as the artifact `notes-pin`. A dry run writes no `verified.sha256`, which `publish` requires. |
| `tag` | `plan`, `build`, `beta-user`, `verify` | creates the annotated tag `v<version>` at the pushed commit, only after the files verified, so a failing attest, signature or verify leaves no orphan tag. The only write before the release. Refuses a superseded commit, and refuses unless the version it would take is the planned one (`--expect-version`), so the tested bytes are the released bytes. The tag ruleset admits only the GitHub App `komira-release-bot` to create `v*` tags, so the job mints that App's token for this repository alone (`repositories: mopm`, `permission-contents: write`, see "The tag token" below) and gives it to the tag step only; the job's own `GITHUB_TOKEN` holds `contents: read`. |
| `publish` | `tag`, `verify` | creates the GitHub release for `v<version>` from exactly the verified files (artifacts `verified-assets` and `notes-pin`, nothing else). Runs only for a push to `main`, never a manual run. It holds `contents: write` for the release, and `gh release create` is always called with `--verify-tag`, so it can never create a tag (the lint pins that in `tools/cut_release.zig`). |
| `tap` | `tag`, `publish`, `verify` | renders `Formula/mopm.rb` from the verified `SHA256SUMS` and opens the pull request in komira-ai/homebrew-tap that adds it, with auto-merge when the tap allows it (below). Writes outside this repository; nothing needs it. |
| `bump` | `tag`, `publish` | opens the pull request in komira-internal that moves its `mopm` submodule to this release, with auto-merge (below). The last stage with `tap`, the two that write outside this repository; nothing needs either. |
| `apt-deploy-read`, `apt-index`, `apt-deploy-write` (up to three attempts) | `publish` | puts the two `.deb`s into the shared apt repository (below). Three jobs per attempt so that no job holds both the signing key and the cloud role. Until the repository owner has made the settings, every one of them ends green with a notice and writes nothing. Nothing needs them: a red apt job goes red alone and un-releases nothing. |

**The retry of `cosign verify-blob`.** `verify` calls `cosign verify-blob` once per file. When cosign cannot fetch the Sigstore trusted root (the
TUF repository), the call is tried up to 3 times, waiting 2 s and then 4 s between the tries. Only the final line of cosign's error output decides:
it must hold `tuf refresh failed`, `Could not fetch trusted_root.json` or `error getting live trusted root`. Any other refusal, a signature or
certificate mismatch above all, is a finding on the first try; so is a mismatch that follows the legacy-bundle `Could not fetch trusted_root.json ... Continuing`
warning. One more shape is retried: cosign v3.0.6 (the version the release installs) ends a failed fetch with `trusted root is required when using new bundle format` (the fetch error is only the warning line before it), and that final line retries only when an earlier line holds one of the three fetch texts; alone it is a finding. An outage longer than about 6 s still fails the release, and the message says it is "a network failure, not a verdict on the signature"; re-run the job.

A push that changes only documentation or CI (`**.md`, `docs/**`, `.github/**`) does not release.
Everything else does, including a change to `VERSION`.

only `publish` holds `contents: write` through the job token here; `tag`, `tap`, `bump` and `publish` run only under `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`
(`tag`, `tap` and `bump` hold `contents: read` and write through App tokens);
only `attest` holds `id-token` and `attestations` write. `tests/drivers/release_lint.zig` holds the workflow to
that, to the order of the stages, to the data flow between them (the built and tested version is the planned
version, the tagged version and the released version; `publish` releases the verified files) and to the path filter;
`release_lint_test.zig` plants a defect for each rule and requires it to go red. The same file holds
`release-beta-user.yml`: exactly the three platform legs, none skippable, optional or allowed to fail.

Pushes share the concurrency group `release-push` (one run at a time, none cancelled). GitHub keeps one pending run
per group, so if several pushes land while a release runs, only the newest waits: it releases a commit that
contains the others. A manual run has a group of its own, so it cannot displace the pending push release.

## The tag token

The `v*` tag ruleset lets only the GitHub App `komira-release-bot` create, update or delete `v*` tags (GitHub refused the
Actions integration as a bypass). So the `tag` job does not use its `GITHUB_TOKEN` (it holds `contents: read`): after it builds the
tool it mints an installation token of that App with `actions/create-github-app-token` (pinned by commit; `vars.RELEASE_BOT_APP_ID`,
`secrets.RELEASE_BOT_PRIVATE_KEY`, owner `komira-ai`, `repositories: mopm`, `permission-contents: write` and no other scope) and gives it
as `GH_TOKEN` to the one step that runs `cut_release tag`. The App must be installed on mopm (Contents read and write, Metadata read) and
the variable and the secret must exist in this repository.

The secret is not a repository secret. `RELEASE_BOT_PRIVATE_KEY` lives in the environment `release` of this repository, which is
restricted to the `main` branch (deployment branches: `main` only), so a workflow run from any other branch cannot read it; the repository-level
copy is removed. `tag`, `tap` and `bump`, the only three jobs that read `RELEASE_BOT_*`, declare `environment: release`, and no other job declares an
environment. The release lint and hygiene hold both: exactly the jobs that read `RELEASE_BOT_*` declare `environment: release`, any other job
with an environment is a finding, and a job reading `RELEASE_BOT_*` without it is a finding. (The CEO's held script creates the environment, moves the
secret into it and deletes the repository-level copy; until it has run, a job declaring `environment: release` still reads the repository-level
secret, because GitHub creates an empty environment on first use, so releases keep working.)

A release run without them fails safely at `tag`: the token step errors, no tag is created, `publish` (which needs `tag`) and `bump` never
run, and nothing is released. Re-run the failed jobs once they exist. The release lint holds that the release workflow has exactly three token
steps (this one, `tap`'s and `bump`'s), that the tag token is for `mopm` with contents write only, the tap token for `homebrew-tap` alone and the bump token for komira-internal alone, that each is
used only in its own job's last step, and (hygiene and the release lint) that `RELEASE_BOT_PRIVATE_KEY` is referenced exactly three times, once in each of `tag`, `tap` and `bump`.

## The komira-internal bump (the last stage)

After `publish`, the `bump` job (push to main only, `permissions: contents: read`) opens a pull request in
komira-ai/komira-internal that moves its `mopm` submodule to the released commit, and turns auto-merge on:
`cut_release bump-internal` (`tools/bump_internal.zig`; `gh` and `git`, no shell). komira-internal merges it on its own
when its `check` and `bump-guard` pass; nobody clicks.

- **The token.** The job builds the tool first, then mints an installation token of the GitHub App `komira-release-bot`
  with `actions/create-github-app-token` (pinned by commit; `vars.RELEASE_BOT_APP_ID`, `secrets.RELEASE_BOT_PRIVATE_KEY`, owner
  `komira-ai`, repository `komira-internal` only), and gives it to the one step that runs the tool as `GH_TOKEN`. The App is
  installed on komira-internal and mopm, and this token is requested for komira-internal alone, so it reaches nothing else. The tool never puts the token in an argument: `gh`
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

## The apt repository

After `publish`, the two `.deb`s of the release (the ones `verify` checked, artifact `verified-assets`) go into the apt repository that the products of this organization share
(`tools/apt_publish.zig` is the command line the jobs run; `tools/channels apt-index` merges and renders the index, as for any apt repository). The repository is one tree: the
`.deb`s of a product below its own pool directory (`pool/mopm/`), and one signed index (`dists/stable/`) that lists the packages of every product. mopm writes its own
packages and keeps the rest of the index as it finds it.

**Three jobs per attempt, and why.** Writing the index needs three things that must not meet in one job: the cloud role (to read and write the repository), the archive signing key
(to sign the merged index), and the merged index itself (which needs the read before it and the signature before the write). So:

| job | environment | holds | does |
|---|---|---|---|
| `apt-deploy-read` | `apt-publish` | the role (OIDC, `id-token: write`), no key | reads the current index and the ETag of every object of it from S3 (never through the CDN, which caches the index and would hand back a stale ETag) and passes it on as an artifact |
| `apt-index` | `apt-signing` | the signing key, no role, no `id-token`, no cloud credential | merges the `.deb`s into the index that was read (`channels apt-index`) and signs `Release` with the signing subkey (with each of two during a key rotation): `InRelease` and `Release.gpg` |
| `apt-deploy-write` | `apt-publish` | the role (OIDC), no key | uploads the `.deb`s with `If-None-Match` (a `.deb` is never replaced), writes the index with `If-Match` on the ETag it was read with (`If-None-Match` for an object that did not exist yet), then invalidates `/apt/dists/*` |

The job that can sign cannot write, and the job that can write cannot sign; the index travels between them as an artifact that only the workflow can create. The release lint holds
that (`tests/drivers/release_lint.zig`): the key (`APT_GPG_*`) is named by the `apt-index` jobs alone, which hold `contents: read` and no `id-token`; the role (`APT_PUBLISH_*` and the
OIDC exchange) by the `apt-deploy` jobs alone; `id-token: write` is held by those and by `attest` and by nothing else; each job declares its environment. The puts themselves are held
by a second lint over `tools/apt_publish.zig` (every `.deb` put carries `If-None-Match`, every index put `If-Match` on the ETag that was read or `If-None-Match` when there was none, the
`.debs` before the index and the invalidation last) and by `tests/drivers/apt_publish_test.zig`, which runs the real tool against a fake `aws` that refuses every call the role may not
make, a fake `gpg` and a fake `curl`.

**The order of the writes.** The pool first (the index must never list a file that is not there); then the by-hash copy of every `Packages` and `Packages.gz`
(`dists/stable/main/binary-<arch>/by-hash/SHA256/<hash>`, `If-None-Match`; the `Release` says `Acquire-By-Hash: yes`); then the plain `Packages` files; then `Release`, `Release.gpg` and
`InRelease` last; then the invalidation. The `If-Match` of `InRelease` is the commit point. A write that stops anywhere (a `412`, a failed put, the last attempt) leaves either the old
`Release` or `InRelease` with the index files it lists, found by their hashes (the old by-hash files are never replaced or removed), or the new one with its by-hash files already there. `tests/drivers/apt_publish_test.zig`
stops the write after every put and checks exactly that. The by-hash files stay (the role cannot delete); a stopped write leaves some unreferenced ones.

**The shared `Release`.** The index is shared with other products, so the `Origin`, `Label` and `Description` of a `Release` that exists stay as they are; the `--origin`, `--label`
and `--description` of `apt_publish index` (the repository owner's name) apply to the first `Release` only.

The OIDC exchange is the one `deploy.yml` makes (the runner's token request, then
`sts assume-role-with-web-identity`, both masked), done by the tool so that no new third-party action is needed and the six jobs that need it do not each carry a copy of it.

**A lost write.** Another product may publish between the read and the write. Every put of the index is conditional on the version that was read, so the loser gets a `412`: it writes
nothing more, says so, and its output `conflict=true` starts the next attempt, which reads again, merges again and signs again. Three attempts at most (`apt-deploy-read-2`,
`-3`, and so on); the write of the last one fails the job instead. A `.deb` that is already in the pool (a `412` on its put) is kept as it is: the release it belongs to was
already published.

**The settings, and what happens until they are made.** The repository owner makes them once:

- the environment `apt-publish` (deployments from `main` only) with the variables `APT_PUBLISH_ROLE_ARN`, `APT_BUCKET`, `APT_DISTRIBUTION_ID` and `APT_HOSTNAME`;
- the environment `apt-signing` (deployments from `main` only) with the secrets `APT_GPG_PRIVATE_KEY` and `APT_GPG_PASSPHRASE`, and `APT_GPG_FINGERPRINT`, the fingerprint of the signing
  subkey (or a comma-separated list of them, while a key rotation signs with the old and the new subkey at once, `APT_GPG_PRIVATE_KEY` then holding both),
  as a secret or as a variable (the jobs take whichever exists).

**Fail-safe.** Every apt job has a step `gate` (`apt_publish gate`) that checks the settings it needs, after only the steps that set up the tools. When one is missing the gate prints a
notice that names it (the names, never a value), and every later step of the job is skipped by `if: steps.gate.outputs.enabled == 'true'`: the job ends green and writes nothing. The
lint holds that every step after the gate carries that condition and that no step before it touches a setting, a secret or the cloud. So a release of mopm that runs before the settings
exist (or with only half of them) releases exactly as before and the apt jobs only leave a notice; a half-made setting (the role without the key, or the key without the role) leaves
the repository unchanged. Once both are made, the next release publishes to the repository without any other change.

The region of the repository is `us-east-1`. The first-publish probe of the repository's own documentation (prove the grants with a throwaway object before the first real write)
is not part of these jobs: the writes are conditional, so a role with the wrong grants fails the first release's apt job loudly and changes nothing.

### Installing from the apt repository

*Available once the repository owner has made the settings above and uploaded the archive keyring; until then use the install script or the `.deb` of a release.*

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.komira.ai/apt/keyring.gpg | sudo tee /etc/apt/keyrings/packages.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.gpg] https://packages.komira.ai/apt stable main" | sudo tee /etc/apt/sources.list.d/packages.list
sudo apt update && sudo apt install mopm
```

The keyring is the public half of the archive signing key (binary format, as `signed-by` expects); its file name is decided when the owner uploads it, and the line above names the file
the repository documents. `apt update` verifies `InRelease` against it before it trusts a `Packages` file.

## The Homebrew tap (the `tap` stage)

After `publish`, the `tap` job (push to main only, `permissions: contents: read`) renders `Formula/mopm.rb` and opens a pull request
with it in komira-ai/homebrew-tap, the repository `brew tap komira-ai/tap` reads. `cut_release tap` (`tools/tap.zig`; `gh` and
`git`, no shell; it shares its plumbing with `bump` in `tools/ghtool.zig`).

- **Where the checksums come from.** The job downloads the artifact `verified-assets` (the files `verify` checked and `publish`
  released) and runs `tools/channels formula` on its `SHA256SUMS`. Nothing is downloaded or hashed anew: the formula can only say what
  the verified `SHA256SUMS` says. The command is fixed by the release lint (`render_run` in `tests/drivers/release_lint.zig`):
  no `version` line (`--no-explicit-version`; `brew audit --strict` refuses it as redundant with the release url), the urls of this repository's release, and the three targets `macos-arm64`, `linux-aarch64`, `linux-x86_64`.
- **Why those flags.** The tap admits a pull request only through its path guard (`.github/guard/guard.js` there), which accepts
  the bot's pull request when: the branch is `bump/mopm-v<version>`; exactly one file changed, `Formula/mopm.rb`; the file is the
  renderer's output line for line (an exact allow-list, not deny rules); the version is above the formula on `main`; the tag
  `v<version>` exists. `tests/drivers/channels_cli_test.zig` reads the render command out of `release.yml`, runs it, and requires the
  tap's own fixture (`tests/channels/tap_guard/mopm.rb`, a copy that names the tap commit it came from) byte for byte. When the guard's
  template changes, that fixture, `tools/channels/formula.zig` and the render command change together.
- **The token.** Same shape as `bump`: after both tools are built, `actions/create-github-app-token` (pinned by commit; owner
  `komira-ai`, `repositories: homebrew-tap`, `permission-contents: write`, `permission-pull-requests: write`, environment `release`) gives
  the installation token of `komira-release-bot` to the one step that runs the tool, as `GH_TOKEN`; it is never an argument. The job
  holds only that token, as its last step.
- **What the tool does.** It checks that the file is the formula of this version and that the tag exists; reads `Formula/mopm.rb` on the
  tap's `main` and **refuses (red) when its version is above this release's** (a tap never moves down; the same version means it is
  already there: nothing to open); reads the tap's pull requests; clones shallowly, writes only `Formula/mopm.rb`, checks that the
  staged change is that one path, commits `mopm <version>` as the bot, pushes `bump/mopm-v<version>` (never forced), opens the pull
  request, and asks for `gh pr merge --auto --squash`.
- **Idempotent.** An open or merged pull request for this or a newer version means there is nothing to open (an open one for this
  version that lacks auto-merge gets it asked for). A branch an earlier run pushed before it stopped is reused when it holds these
  bytes. An older open `bump/mopm-v*` pull request is closed in favour of the new one (with its branch); nothing is ever force-pushed.
- **When the tap has no required checks.** GitHub can refuse to enable auto-merge on a pull request that has no required checks to wait for (the error
  reads "Pull request is in clean status"), which is the case for every pull request of a tap whose ruleset is not active. That is not a failure: the job stays
  green, prints a notice (`The tap pull request is open without auto-merge`), and leaves the pull request open for the tap's owner to
  squash-merge. Once the tap's ruleset requires `guard` and `check`, the next release's run (or a re-run of the job) asks again and the
  pull request merges itself.
- **A failed tap un-releases nothing.** No job needs `tap`; re-run the `tap` job of that run, it finds what exists and finishes the rest.

## The user-level beta

`.github/workflows/release-beta-user.yml` (run only by `release.yml`, after the merge, never on a pull request) uses pinned tools only, and takes the tarball that
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
with golden tests).

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

A dry run is never made by a pull request (it used to be: `release-check.yml` is gone). Run the `release` workflow by hand (Actions, `release`, Run workflow) on `main`. It runs `beta`, `lint`, `plan`,
`build`, `beta-user`, `attest` and `verify`: the candidate is built and tested on every platform, and `plan` prints the version the
next release would get. It creates no tag and publishes nothing (`tag`, `publish` and `bump` do not run; `attest` and `verify` do, as a rehearsal of the signing, whose signatures carry the trigger `workflow_dispatch` and are verified as such). From any other branch the run stops after `beta-user`: `attest` runs only on `main`, so an unmerged commit is never signed.

## A re-run and a failure

- A red `beta`, `lint`, `build` or `beta-user` stops everything: nothing is tagged. Fix main; the next push releases.
- A red `attest` or `verify` leaves no tag (the tag job comes after verify). If `publish` fails after the tag exists, the tag stays. Re-running the failed run reuses the
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

## The Dependabot pin update (`autopin-compute.yml`, `autopin-commit.yml`, `pin-verify.yml`)

A Dependabot bump of a `package-lock.json` leaves its pin table (`buildrules.lock.bzl` in `site/` and `service/api/`,
`pins.lock.bzl` in `service/infra/*`) stale, and the table needs a sha256 and a size that only the tarball gives. Two
workflows make the pull request green without a person, and a third checks the result. None of them merges or approves
anything; the pull request still needs a person to read the lockfile diff.

| workflow | trigger | holds | does |
|---|---|---|---|
| `autopin-compute.yml` | `pull_request` of Dependabot's own pull request, run for Dependabot, from a branch of this repository (job-level `if:`) | a read-only token; no secret, environment, id-token or cache | runs the released `buildrules autopin compute` over the checkout of the pull request's head and uploads the regenerated tables as the artifact `autopin-<run id>-<attempt>` (never overwritten) |
| `autopin-commit.yml` | `workflow_run` of the compute run completing (this file on the default branch is the one that runs) | environment `autopin` (the App's id and key), entered only after the job-level `if:` passed; read access until it mints | `autopin commit-check` reads the artifact as untrusted bytes and the pull request and its lockfile from the API and writes the tables it will vouch for; only then is the App token minted (contents write, this repository only) and `autopin commit-push` makes one commit on the pull request's branch with the Git Data API, moving the branch with `force: false` |
| `pin-verify.yml` | every pull request | a read-only token and nothing else | the required check `pin-verify`: runs the same tool and fails if any table would change |

The App's own push has the pull request's author but not its actor, so the compute job skips it: that is what stops the loop.
The commit carries `[dependabot skip]`, so Dependabot keeps managing the pull request and a later Dependabot update replaces it.
Anything but lockfile, `package.json` and table changes in the pull request (a `.github/` file, a build file, a script) is
left for a person, and a pull request that touches `.github/` is checked by its own copy of `pin-verify.yml`, so a person must read it.

What the tool trusts is the Dependabot bump itself: a newly published malicious version pins consistently. What stops it is
Dependabot's 7-day `cooldown` and the person who reads the lockfile diff.

The tool is the released `buildrules`, fetched by tag and checked with `sha256sum -c` against a sha256 written in each of the three
files (`BUILDRULES_VERSION` and `BUILDRULES_SHA256`), never built from a pull request. To move it, bump all three in one pull request to
main; `tests/drivers/autopin_lint.zig` fails when they differ. The directories the tool may write are the `--set` arguments, the same
in all four invocations; `//:hygiene` fails a package with a `package-lock.json` that has no `--set`.
`tests/drivers/autopin_lint.zig` (`//:autopin_workflows`, run by `lint.yml`) holds the gates, the scope of every token, the order of
the steps in `autopin-commit.yml` and the artifact's name, with a planted mutant per rule, and for every workflow: `workflow_run`
in `autopin-commit.yml` alone, `push` only for `main` or tags, what a pull request can reach (no environment, no secret, one
farm id-token that skips a Dependabot branch), the files the lints can read, and that no workflow merges or approves a Dependabot pull request.

**Nothing of this runs live until an owner has done the following** (the workflows do nothing and fail closed until the
environment exists):

1. Rulesets on the default branch (a pull request and one approval, the required checks including `pin-verify`
   pinned to the GitHub Actions integration (id 15368), no force push, no deletion, no bypass for the autopin App) and on tags
   (`~ALL`, only the release bot may create), applied before the App's key exists in GitHub.
2. The GitHub App `komira-autopin` (Contents write and Metadata read, nothing else), installed on this repository, on no bypass list.
3. The environment `autopin` (deployment branches: `main` only), then the variable `AUTOPIN_APP_ID` and the secret
   `AUTOPIN_APP_PRIVATE_KEY` in it. Never a repository or Dependabot secret.
4. The farm's workload-identity trust refusing a `dependabot/*` `head_ref` (a setting outside this repository; `farm.yml` already skips such a branch).
5. Four probes settle behaviours the GitHub documentation leaves open, before the first live run: T1 the `workflow_run` payload
   (which actor fields a re-run and an `@dependabot` command set, the artifact download's redirect host) and whether a Dependabot-actor
   run can read an environment secret; T2 that `[dependabot skip]` makes Dependabot keep the pull request; T3 whether a run started by the App's push waits for
   approval; T4 what a Git Data API commit by the App shows (verification, `author.login`, the exact non-fast-forward error).

## What the CEO has to do before the first release

The bump and tag stages need, once: the GitHub App `komira-release-bot` installed on komira-internal and on mopm; the variable
`RELEASE_BOT_APP_ID` in this repository and the secret `RELEASE_BOT_PRIVATE_KEY` in the environment `release` (restricted to main, not a repository secret); auto-merge allowed in komira-internal, with
its ruleset requiring `check` and `bump-guard`; and the `v*` tag ruleset allowing only that App to create, update and delete tags.
Without the App's variable and secret `tag` fails (no tag, no release); without the bump setup only `bump` fails. The tap stage needs the App installed on homebrew-tap too (Contents and Pull requests read and write; the App is installed on every repository of the organisation today), the tap's repository variable `TAP_BOT_LOGIN` (`komira-release-bot[bot]`), and auto-merge allowed there; without them only `tap` fails or leaves its pull request for a hand merge.

These are settings only an owner can change; the automation neither makes nor assumes them:

1. **A tag ruleset for `v*`** (Settings, Rules, Rulesets, target: tags, pattern `v*`): restrict updates and deletions,
   so a released tag can never be moved. The only bypass actor is the GitHub App `komira-release-bot`, which the `tag`
   job uses to create tags (GitHub does not accept the Actions integration as a bypass).
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
