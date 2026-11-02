# Per-ISA native variants that load the best build at runtime

Status: proposal, CEO decisions folded in (see Decisions); no code changes in this PR.

Direction (CEO): build each native library once per x86-64 and ARM instruction-set level with Buck2 and let the
runtime load the best one, so that a komira package on mopm "just works" and is as fast as the host allows. Extended:
rather than reaching for conda-forge for everything, **every native library komira ships or depends on is recompiled
from pinned upstream source**, which is better for the end user. conda-forge stays available to other mopm users
through the any-conda-forge path; komira's own packages use our builds. This builds on `any-conda-forge-native.md`: one lock
(`mopm.lock`), mopm's own solve, nothing refused, warnings inform, only integrity is an error. Its open question 1
(a channel other than conda-forge) is answered yes, for our own builds, below.

Why. Support measured conda-forge's snappy 1.3.1 (GCC 15.3) decoding at 0.47 to 0.50 times the speed of komira's own
clang builds. The call path, the CPU target (x86-64-v3 against generic differs by 0 to 8 percent), the version and the
flags were each ruled out, so compiler codegen is the leading cause (a cause not yet shown by an experiment on GCC
flags). `komira_compression`'s move to a load-mode system snappy is on hold for this.

## Scope: the libraries, and where their source is pinned

In scope (from komira's `third_party/` and its dlopen and link sites; **recheck with a grep in PR 2, the list may be
incomplete**): snappy (bumped to 1.3.1; `third_party/snappy` pins 1.2.2 today), zstd, lz4, zlib, bzip2, brotli,
liblzma and sqlite, plus aws-lc and s2n-tls, which are already our builds (`third_party/aws-lc`, `third_party/s2n-tls`).
`komira_zlib`, `komira_lz4`, `komira_compression` and `komira_orc` load their codec by `dlopen`; `komira_db_sqlite`
links `-lsqlite3`; `komira_avro` loads codec libraries per OS (not enumerated here).

**Pins.** A source pin is a `pinned_file` in the library's `third_party/<lib>/BUCK`: the upstream release tarball by
`url` and `sha256` (as `snappy-1.2.2.tar.gz` and `aws-lc-1.39.0.tar.gz` are today), unpacked by `archive_files`.
The version appears once, in that file. **Patches**, if a library needs one, are `.patch` files committed next to the
pin, listed in the BUCK file in order and applied by an action, so the patched tree is an input to the cache key;
each carries a header saying why and the upstream issue, and a pin with a patch is listed in the PR that adds it.
No patch is applied that only moves a version. Generated headers (snappy's `config.h`) are committed beside the pin.

## Decisions (CEO)

1. **Channel.** Approved as written: our builds are served from a second, conda-layout channel (`natives`) of the mopm
   registry. It is not pixi and not a git repository. Komira's own packages always name `channel = "natives"`.
2. **aarch64.** Baseline plus in-library dispatch only where measured; no over-engineering of ARM. NEON is baseline,
   so a feature level is added only on a measured win.
3. **Levels published.** A level is published only after its tests ran on a host of that level. Today that is Linux
   x86-64 v1, v2 and v3. v4 waits for AVX-512 (Skylake) hosts to join the farm; none are needed now.
4. **Parity gate against conda-forge.** An integration test per native checks ours against conda-forge's build of the
   same version: the same outputs on a corpus, and ours not slower beyond a 5 percent margin. A regression past the
   margin blocks the publish. Support owns the test and the margin.
5. **Patches** are carried in-tree when needed.
6. **Detection** is by `kpin` resolvers only; no Renovate.
7. **Regression bound** is owned by support; an alert goes to the native's owner.

## 1. Building the variants with Buck2

Levels: x86-64 `v1` (baseline), `v2`, `v3`, `v4` (AVX-512); aarch64 baseline (armv8-a) plus, if measured to matter,
armv8.2-a and armv9-a with SVE2; macOS arm64 one build (`apple-m1`, today's `target_cpu`).

| Option | How | Pros | Cons |
|---|---|---|---|
| A. A platform per level | a row per level in the platform table (`tools/build/platforms/table.bzl`) | reuses `target_cpu` as is | the table is "what a host is"; levels multiply rows, pools and golden hashes |
| B. An `isa` constraint plus a transition on the native-library rule | one constraint setting (values `v1..v4`, `armv8`, ...); the rule builds the library under each value; `cxx.bzl` takes `-mcpu` from the value instead of the row | one row per host, N configurations of one target; the level is in the action key | a new constraint and transition in the toolchain; every dependent must not accidentally inherit it |
| C. N copies of the target | the BUCK file lists each level by hand | no toolchain change | drift between copies, the rot the build rules avoid |

Lean: B. The variant set per library is a list in its BUCK target (snappy: v1, v2, v3 now, v4 when a host exists; others as measured). Cost:
one compile per level; snappy is ten small files, so seconds. Large libraries pay N times, cached per level.
Reproducibility: the compiler, flags and sources are pinned and hermetic (zig, the pinned source archive), so each
level is byte-identical across builds, and a test builds twice and compares, as the bundle test already does for
bundles. Testing: a variant is run only on a host that implements its level. The farm requires x86-64-v3 workers
(`DEVELOPMENT.md`); whether any worker has AVX-512 or SVE2 is **unverified**. Lean: publish a variant only after
its tests ran on a host of that level; a level with no such host is built, not published.

## 2. Runtime selection

**Linux x86-64: glibc-hwcaps.** The loader, on glibc 2.33 and later, searches `glibc-hwcaps/x86-64-v4`, `-v3`,
`-v2` (best first) in each library directory before the directory itself (ld.so(8), "x86 (64-bit only)"; glibc's
`sysdeps/x86_64/dl-hwcaps-subdirs.c` lists exactly `x86-64-v4:x86-64-v3:x86-64-v2`, checked on its mirror). Komira's
floor is glibc 2.34 (`os_floor`, `tools/build/platforms/table.bzl`), so every komira host has hwcaps. Komira already
relies on it for bundles and tests it in `tools/build/tests/functional/bundle.sh` (first try found in
`lib/glibc-hwcaps/x86-64-v3/`, and masked with `GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2`). **On glibc older than 2.33**
the subdirectories are ignored and `lib/libX.so` loads: so `lib/` always holds the baseline (v1) build, and old hosts
are slower, never broken.

**LD_LIBRARY_PATH.** The change that added hwcaps search to `LD_LIBRARY_PATH` directories ("elf: Add glibc-hwcaps
support for LD_LIBRARY_PATH", a libc-alpha patch series that went into 2.33) means each directory on the path is expanded
the same way. ld.so(8) does not state this, so it is **unverified from the manual**; PR 1 proves it with a test that
runs under `LD_LIBRARY_PATH=<stage>/lib` and checks `LD_DEBUG=libs` names the hwcaps path. **Known gap in buildrules today.** `conda_unpack --all-libs` (merged in buildrules #126, per the lane that owns it)
copies `lib/*.so*` flat and leaves subdirectories out, so `lib/glibc-hwcaps/...` is dropped before the loader sees
it. PR 1 must change the unpack to keep the `glibc-hwcaps/<level>/` tree under the staged `lib/`, and must prove
hwcaps loading under the `LD_LIBRARY_PATH` directories the test runner uses. The `--lib-dir` runner puts the
stage on `LD_LIBRARY_PATH` on Linux, so with both fixed, tests need no new mechanism (macOS has no hwcaps and
keeps `DYLD_FALLBACK_LIBRARY_PATH`).

**Linux aarch64: no loader support to rely on.** The aarch64 hwcaps patch in the original series proposed only an
`atomics` directory; glibc master has no `sysdeps/aarch64/dl-hwcaps-subdirs.c` on its GitHub mirror (404; **the
mirror may lag, recheck against the glibc release in use**). So aarch64 gets the baseline in `lib/` and any faster
code is chosen inside the library (below). Lean: do not ship aarch64 level variants until a benchmark shows a gain
that dispatch inside the library cannot give; ship the baseline.

**macOS.** No hwcaps. Lean: one arm64 build (`apple-m1`) per library; Apple silicon has few feature tiers that
matter to codecs, and dispatch inside the library (below) covers the rest.

**Static or link-mode natives, and in-library dispatch.** A hwcaps directory only helps a shared object loaded
by the loader. A static archive is fixed at the consumer's link, so it carries one level or dispatches itself:
function multiversioning (`target_clones`, or an ifunc) for a few hot functions, or a shim that tests CPUID once
and calls the best function. Needs it: any `kind = "static"` native; any library whose hot loop is a handful of
functions (snappy's decompress loop, zstd's Huffman/FSE decoders and xxhash, zlib's crc32 and inflate fast path);
aarch64 and macOS everywhere. Lean: shared libraries use hwcaps on x86-64; static archives ship the v3 build only
when the consumer's platform floor is v3 (komira's own floor is), else the baseline plus dispatch; nothing else
until measured. Mojo `load` mode (the package opens the library itself, `dlopen`) goes through the same loader
search, so hwcaps applies to it; a hard-coded absolute path would defeat it, and the benchmarks check that (section 5).

## 3. How a package carries the variants, and the channel

| Option | Pros | Cons |
|---|---|---|
| One conda package holding every variant in the hwcaps layout | one lock entry per library, which is the one-lock design; one sha256; a host picks at load, so a lock is portable across CPUs | the download is N times larger (snappy: kilobytes; zstd: sub-megabyte); a variant cannot be fetched alone |
| A package per level (`snappy-v3`) | smaller fetch | the lock fixes a level at lock time and breaks on another CPU; mopm would need CPU detection in the solver; N names to keep in step |

Lean: one package per library per subdir. This keeps `system_libs` as it is in `lock.md`: `name`, `version`,
`build`, `url`, `sha256`, `size`, `deps`, and `has_library`. The lock records the one archive, and which variants
it holds is read from the archive, not from the lock; the build string of an ISA-variant package carries a marker
(for example `isa1`) so a reader sees it, and a manifest `isa.json` inside the package lists levels and per-file
sha256, checked by `mopm sync` (an integrity error on mismatch, as in any other file).

**Our own channel.** The mopm registry already serves a channel for `mojo-*` packages; native conda packages built
by komira live in a second channel of the same registry (`natives`), laid out like conda-forge (`<subdir>/*.conda`
and repodata), so mopm's resolver reads it with the code that reads conda-forge. A manifest names it per
dependency: `snappy = { version = ">=1.2", mode = "load", channel = "natives" }` (the `channel` key is new; absent
means conda-forge, as today). The lock's `url` is the channel's URL, so one lock mixes both sources, and the entry
closure follows `deps` as before. This is the "later manifest key" the merged design reserved, not a refusal change.
Lean: a per-dependency `channel` key (explicit, visible in review); not a global priority list (it makes
`snappy` mean different things on different machines, the ambiguity the single lock exists to remove).
Name clash: the package keeps the conda name (`libsnappy`); conda-forge and our channel never both appear in one
lock for one name. mopm picks the declared channel and errors on two different channels for one name in a closure.

## 4. Rollout, and conda-forge as evidence

Every in-scope library is built from source (Scope, above). Order: **snappy** first (1.3.1, from the existing clang
build in `third_party/snappy`); then the **benchmark-path** libraries, those the benchmarks and codec tests exercise
(zstd, lz4, zlib); then the rest (bzip2, brotli, liblzma, sqlite; aws-lc and s2n-tls need only the variant
treatment, they are already built). Each library passes a **parity gate against conda-forge's build of the same version**
(Decision 4), an integration test on the farm:
- *Corpus and harness.* Support builds both: a corpus of pinned public files plus buffers shaped like what komira
  writes (Arrow and Parquet pages, log lines), each fetched as a pinned download (url and sha256) so the farm, which has
  no network, runs it hermetically; and a harness that loads the two libraries by path in one process on one host.
  conda-forge's build is a pinned download of its `.conda` (a lock-style entry), never a live fetch. It runs as a Buck2
  test target in komira, on a host of the level under test.
- *What it requires.* Byte-identical output where the format fixes it (decompress, checksums), a round trip and a
  size within the library's documented tolerance where it does not (compress), and the time of ours at most 5 percent
  above conda-forge's (support's method: three runs, same host, the median; the timing is a check of this one gate,
  not an assertion in a unit test).
- *If conda-forge has no build of our pinned version,* the gate runs at its newest version, and the report says both
  versions.
- *A failure blocks the publish* and the numbers, compiler and flags go in the PR; a native that cannot pass is
  fixed, not published. conda-forge remains the source for every other mopm user's natives
through `any-conda-forge-native.md`, unchanged.

## Keeping source pins current

**Mechanism: extend `kpin`, which belongs to buildrules (`rules/kpin`); build no new bot.** There is to be one
`kpin`. Komira still carries its own copy (`tools/build/kpin`, with `.github/workflows/kpin-update.yml`); that copy is
**retired**, and komira consumes `kpin` from buildrules (as it already consumes buildrules' pinned tools). The source-release
support below lands in buildrules: the GitHub tag and release resolver, the sqlite.org resolver, commit-SHA pins for
tag-only upstreams, and offline signature checks. The older "merge from live" concept (a weekly bot that bumps pins and
merges when green) is **retired by this design**; `kpin-update` replaces it, and nothing merges itself. Its stub
(`.github/ci/merge_from_live.sh` and `.github/workflows/merge_from_live.yml`) was in komira's tree; komira's `main`
no longer has them (a "delete dead shell" change removed them), so the retirement PR only has to confirm that, mark any
remaining reference in the docs, and delete the copies in any tree that still pins an older komira. Detection is by
`kpin` resolvers only (Decision 6); `kpin` stays the one tool that fetches, hashes and verifies.

**What komira's copy does that buildrules' does not yet** (read from both trees' `main`, not from a diff tool):
- Komira's `kpin` has the whole **Cargo** subsystem (`cargo.zig`, `cargo_lock.zig`, `cargo_trim.zig`,
  `cargo_update.zig`, `cargo.bzl`, `cargo_fixture/`) and the flags `--cargo-lock`, `--metadata`, `--sizes`,
  `--target`, `--crates-base`, `--overrides`, `--rustc`, `--cargo-out`, `--stamp`, `--trim`, `--previous-lock`,
  `--check` and `--no-pins`. Buildrules' `main.zig` parses none of them (about half the size). **These move into
  buildrules first**, with their tests, before komira's copy can go.
- Komira's `kpin-update.yml` is a 19 kB workflow: it builds `kpin` through Buck2, runs `kpin update` and `kpin check
  --previous`, refreshes `Cargo.lock` and `cargo metadata` on the runner, the alarm handling (exit 3, no PR), and
  the single weekly PR. Buildrules has **no** `kpin-update.yml` today (mopm has its own copy of the weekly job). The
  workflow must be made one reusable `workflow_call` workflow in buildrules, taking the pin sets and the cargo
  directories as inputs.
- Buildrules' copy is ahead on tests (`fetch_test`, `oom_test`, `valid_test`, larger `refusal_test`), so the move is
  not a straight copy: take buildrules' files and add the Cargo files on top; do not overwrite.

**Where the weekly job then lives.** Buildrules owns the reusable `kpin-update` workflow and runs it over its own pins
(`site/pins.toml`, `infra/site/pins.toml`). Komira keeps a **thin caller** (about 20 lines: the cron, the pin sets
and cargo directories, `uses: komira-ai/buildrules/.github/workflows/kpin-update.yml@<pinned sha>`), which runs the
buildrules `kpin` (a pinned release binary, verified by sha256 and Sigstore as `mopm-pin.yml` does for mopm) over
komira's `pins.toml` files, now including the natives'. mopm's weekly job becomes the same caller. A fix to the weekly
job is then one change, in buildrules.

- **What runs where.** The weekly job (Monday cron plus manual dispatch; the caller in each repo) lists every native in a new `pins.toml`, with
  resolvers for GitHub releases and tags and for the sqlite download page. A resolver that finds nothing or a
  malformed value fails the job (never "no update"); a pin whose upstream was not checked successfully for some weeks
  opens an issue. Pre-release tags are excluded; releases younger than 7 days wait unless flagged security.
- **A release becomes a PR.** `kpin` writes version, url, sha256 and size (and the tag's commit SHA for tag-only
  libraries: snappy, brotli, aws-lc, s2n-tls, fetched by commit, since GitHub tag archives are not byte-stable);
  no change means no PR. The PR check builds every ISA variant of that library on the farm (`local: 0`), runs its
  welded tests on a host of each level, then the benchmark comparison against the previous pin (and, as evidence,
  conda-forge): a comment, red only past a regression bound that needs an owner and a number. A hash change for an
  already-pinned version is an alarm, with no PR. One PR per library, security releases separate and labelled; a
  major or SONAME change is labelled and not grouped (a symbol diff of the built artifact, to be specified).
- **Verification.** Signed upstreams (zstd, zlib, xz, bzip2 if confirmed) are checked against maintainer key
  fingerprints committed in the repo and changed only by a human PR; the signature file and fingerprint go in the PR
  and `kpin check` re-checks them offline; a library that was signed and ships unsigned, or a changed key, is an alarm.
  lz4 and sqlite compare the upstream-published hash to the computed one. The rest are pinned by sha256 and commit
  SHA only; the doc says so per library rather than implying a check.
- **Patches.** A bump re-applies the committed patches in order; a patch that no longer applies fails that
  library's PR with the rejected hunk, and the PR stays red until a human rebases the patch or drops it.
- **Security fast path.** A separate advisory signal (GitHub advisories and OSV for these libraries) opens a
  labelled PR through the same job and skips the cooldown; the PR still builds and tests. Never auto-merged: the CEO
  merges. The bot's PR starts CI through the existing autopin commit step, widened only to `pins.toml` and the
  generated pin table, never workflow files.
- **Regression bound.** The 5 percent bound of Decision 4 applies to a bump too; support owns it and the alert goes to
  the native's owner. Other prerequisites: komira must pin a buildrules release that contains the source-release support (the komira commit a checkout pins may predate `kpin` altogether); and a version bump must rename or
  update derived rows (versions in target names such as `third_party/zlib`) and the ISA variants, or the PR will not build.

## 5. Proof in the benchmarks

A benchmark that cannot show which build it ran is not a measurement of ours. Each benchmark run:

- records the host's active hwcaps levels (`ld.so --list-diagnostics`, field `dl_hwcaps_subdirs_active`, as
  `bundle.sh` already reads it) and the CPU model;
- records the resolved path of each native library it uses, from `/proc/self/maps` (or `dl_iterate_phdr`) after the
  first call, with sha256 of the mapped file;
- computes the best level the package ships that the host supports, and **fails the run** when the mapped path is a
  slower level (including `lib/` baseline when a hwcaps directory exists for the host), or is not in the mopm stage
  at all (a system copy);
- writes all three into the benchmark's output next to the timings, so a published number names its variant.

On macOS and aarch64 the record is the path and the file's sha256, and the failure is "not our build". A test plants
a host with a masked level and expects the failure (the same `GLIBC_TUNABLES` masking `bundle.sh` uses).

## 6. PR sequence

Owner: the mira lane for mopm and buildrules; the support lane for komira packages. S under 200 lines, M under 600, L more.

1. **buildrules: keep `glibc-hwcaps/` in `conda_unpack --all-libs`, and prove hwcaps loading** (M, mira): change the
   flat `lib/*.so*` copy to keep the subdirectory tree; a test loads a two-level fixture under the
   `LD_LIBRARY_PATH` directories the runner uses and reads `LD_DEBUG=libs`. A mutant that flattens must go red.
2. **komira: the `isa` constraint and transition; snappy 1.3.1 at v1 to v3 (v4 built, not published, until a v4 host exists)** (M, support, with mira for the rule):
   bump the pin, byte-identical across two builds, list the full in-scope set from a grep of dlopen and link sites.
3. **mopm: channel `natives` and the `channel` key** (M, mira): spec (`mopm-toml.md`, `lock.md`), solver reads it,
   the registry serves it; a fixture first.
4. **mopm: ISA package layout, `isa.json` check, `has_library` for hwcaps files** (S, mira).
5. **komira: publish the snappy package; `komira_compression` moves to it** (S, support). Ends the hold. Needs PR 6a.
6. **Proof and parity** (support): (a) the conda-forge parity corpus, harness and 5 percent gate, snappy first, run on
   a host of each published level (M); (b) the benchmark records, failure rule and planted-host test (M).
7. **Benchmark-path libraries: zstd, lz4, zlib** (M each, support): pin, build per level (x86-64 v1 to v3), parity gate,
   publish; komira's `komira_zlib`, `komira_lz4`, `komira_orc` move to them.
8. **The rest: bzip2, brotli, liblzma, sqlite; aws-lc and s2n-tls variants** (S to M each, support); each adds its
   corpus entries and passes the parity gate.
9. **aarch64 and macOS baseline packages** (M, support); in-library dispatch or a feature level only on a measured win.
10. **buildrules: source-release support in `rules/kpin`** (L, mira lane), in three steps that may be separate PRs:
    (a) move komira's Cargo subsystem and flags into buildrules `kpin`, with tests (M); (b) the reusable `kpin-update`
    workflow (M); (c) the GitHub tag and release resolver, the sqlite.org resolver, commit-SHA pins, offline
    signature and published-hash checks, the advisory feed (L).
11. **komira: retire its `kpin`** (M, mira lane for the move, support lane reviews): delete `tools/build/kpin` and its
    `kpin-update.yml`, add the thin caller, add the natives' `pins.toml`, confirm that the `merge_from_live` stub and its
    workflow are gone and mark any doc that still names them. Needs 10(a) and 10(b).

Order: 1 starts at once; 2 and 3 in parallel; 4 after 3; 5 after 2, 4 and 6(a); 6(a) after 2; 6(b) after 5; 7 after 6; 8 and 9 after 7;
10(a) and 10(b) start at once, 11 after them, 10(c) before the first pin bump that relies on it (not before PRs 2 to 9).
Reversible: dropping the `channel` key from a manifest returns that dependency to conda-forge.

## Questions for the CEO

None open. When AVX-512 (Skylake) hosts join the farm, v4 is
built, tested and published through the same gate (no new design).
