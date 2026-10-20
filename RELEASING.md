# Releasing mopm

Releases are automatic. Nobody tags, approves or runs a release by hand. A pull request that merges to
`main` and changes more than documentation or CI releases itself once every gate is green; a red stage
stops the release, and the next green push to main releases instead.

## What happens on a push to main

`.github/workflows/release.yml` runs these stages in order; each needs the one before:

| stage | what it does |
|---|---|
| `beta` | the whole of `ci.yml` on the pushed commit (unit, golden, contract and end-to-end tests, on Linux and macOS). Gamma and bake time are a slot for later stages between `beta` and `tag`. |
| `tag` | creates the annotated tag `v<version>` at the pushed commit. The only write before the build. |
| `build` | the four binaries (`linux-x86_64`, `linux-aarch64`, `macos-arm64`, `macos-x86_64`), each reporting exactly this version. |
| `attest` | `SHA256SUMS` for the four tarballs, and build provenance (a signed attestation) for all five files. |
| `verify` | checks the built files before anything is published: exactly the five assets, `SHA256SUMS` matches, every attestation accepted and pinned to `release.yml`, the ref and the commit, the tarball layout, the tag on main and at this commit. Uploads the release notes and the pin (the `linux-x86_64` url, sha256 and size) as the artifact `release-notes`. |
| `publish` | creates the GitHub release for `v<version>` from exactly the verified files. |

A push that changes only documentation or CI (`**.md`, `docs/**`, `.github/**`) does not release.
Everything else does, including a change to `VERSION`.

Only `tag` and `publish` may write `contents`, each under `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`;
only `attest` holds `id-token` and `attestations` write. `tests/drivers/release_lint.zig` holds the workflow to
that, to the order of the stages and to the path filter, and `release_lint_test.zig` plants a defect for each rule.

Runs are serialized (`concurrency` group `release`, never cancelled). GitHub keeps one pending run per
group, so if several pushes land while a release runs, only the newest waits: it releases a commit that
contains the others.

## How the version is computed

The file `VERSION` holds the base, `MAJOR.MINOR`, for example `0.0`. The release run adds the PATCH:

- PATCH is one more than the highest existing tag `v<base>.N` (or release of that tag, draft or published),
  compared as a number: `v0.0.9` and `v0.0.10` give `0.0.11`.
- When none exists, PATCH is `1`: the first green run on base `0.0` releases `0.0.1`.
- Tags of other bases (`v0.10.3` against base `0.1`), tags with a suffix and anything that is not a plain
  number are ignored.
- The tag is created by the API, which fails if the tag exists, so two runs never share a number. If that
  happens the run recomputes and tries once more; a re-run of a run that already tagged its commit reuses
  that tag.

The binary's version comes from the build, not from the source: `zig build -Dversion=<version>` (the release
tool passes it) and `mopm --version` prints it. A build without the option, such as `zig build` or the Buck2
targets, reports the development version `0.0.1+dev` (`src/cli/build_options.zig` holds it for Buck2; the two
defaults must agree, and the golden test checks `--version`).

## Bumping MAJOR.MINOR

Open an ordinary pull request that changes `VERSION` (for example `0.0` to `0.1`) and merge it. The push
releases `0.1.1`. This is rare; PATCH is never edited by hand.

## A dry run

Run the `release` workflow by hand (Actions, `release`, Run workflow) on `main`. It runs `beta`, then `plan`,
which prints the version the next release would get. It creates no tag and publishes nothing.

## A re-run and a failure

- A red `beta` stops everything: nothing is tagged. Fix main; the next push releases.
- If `build`, `attest` or `verify` fails after the tag exists, the tag stays with no release. Re-running the
  failed run reuses the tag. If it is not re-run, the next push to main takes the next number, and the
  unreleased tag stays as a gap.
- If `publish` fails half-way, re-running creates no second release and replaces no asset: every asset the
  release already holds must match the verified file byte for byte, and only missing ones are added. A
  mismatch fails the run and changes nothing; a draft release of the tag fails it too (delete the draft by hand).

## Checking a published release

`tools/cut_release.zig` has a read-only `verify <version> <empty dir>`, which downloads a published release and
repeats the checks against GitHub (draft and prerelease flags, the five assets, hashes, attestations, layout):

    zig build-exe tools/cut_release.zig -femit-bin=<path>
    <path> verify 0.0.1 <empty dir>

It prints the pin for the `linux-x86_64` tarball. It changes nothing.
