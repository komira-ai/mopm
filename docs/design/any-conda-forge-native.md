# Any conda-forge package under `[native-dependencies]`

Status: proposal, for the CEO's review before any implementation. No code changes in this PR.

mopm is an extensible package manager: any conda-forge package works under `[native-dependencies]`, and every check
below informs rather than gates. The only errors are integrity errors (a sha256 mismatch, a corrupt archive), which
are not policy. The fixed list goes away: `NATIVE_DEP_CURRENT` and `NATIVE_DEP_LEGACY` in
`service/api/src/validate/native-deps.ts` are removed. Written against `main` at the merge of #276; #277 is open.

## What exists today

- `mopm pack` maps a native name to a conda package (`condaPackageFor`, `src/core/conda.zig`) and writes it into
  `depends`. The registry (`checkDepends`, `metadata.ts`) accepts a `depends` name only if it is `mojo-*` or in the
  list. That check is pure and offline.
- `mopm lock` writes the lock's `system_libs` (`src/core/system_libs.zig`) from a catalog pinned in the mopm release
  (`toolchain/natives.txt`, `natives.pixi.lock`, `src/core/toolchain/natives-*.json`, `native_catalog.zig`). There is
  no solver. The weekly `toolchain` job re-solves the catalog with pixi on a runner (CI only).
- buildrules downloads each `system_libs` entry (url and sha256 pinned), unpacks its `lib/` with
  `conda_unpack --all-libs`, and puts the directories on a test's library path. `--all-libs` fails on a package with
  no shared library: the xz lesson of #276 (the `xz` metapackage holds none; the catalog had to list `liblzma`).

## 1. Registry checks at publish: all accept, some warn

| check | on failure | cost | where |
|---|---|---|---|
| a. Syntax: a valid conda name (`[a-z0-9._-]`), not `mojo-*`, a spec that parses | error: malformed text must never reach a lock or url (safety, not policy) | none | publish |
| b. The name exists on conda-forge | accept, warn naming the package (typo hint) | a lookup | publish, from a mirror |
| c. The version requirement is satisfiable per declared platform | accept, warn | a solve | `mopm lock` |
| d. The package holds a runtime library | accept, warn "holds no library; skipped in tests" | file listing | `mopm lock` |
| e. A pre-link or post-link script is present | accept, warn | file listing | `mopm lock` |

Data for b. Full conda-forge `repodata.json` is hundreds of MB per platform and cannot fit the API Lambda (25 s after
#278). A per-package lookup depends on a third party's latency. Chosen: our own mirror, a scheduled job writing a
small "name -> platforms, versions" index to S3 (a few MB, **estimate**), read once per Lambda container. The CEO
approved a list up to a day old. Past a day the publish still passes and the warning says the list is stale, so a
conda-forge outage never blocks anything. An unknown name warns (b) and is accepted: it may be new since the mirror ran.

Checks c to e need versions, files and the closure, so they run at `mopm lock` (section 2), which prints each warning
naming the package. The registry may repeat d and e for the top-level name in an asynchronous worker (never the API
Lambda), cached by sha256: a follow-up, not day one.

## 2. One lock, solved by mopm itself

There is one lock system: `mopm.lock`. The native closure lives in it (the existing `system_libs` section: name,
version, build, url, sha256, size, deps), plus a per-entry `has_library` flag. `mopm lock` writes it; `mopm sync`
and buildrules fetch exactly those entries and never solve. A user never installs, runs or sees pixi, a second lock
file, or a second solver. `mopm lock --locked` fails when the pins would change. If conda-forge removes a pinned file,
the fetch fails naming it.

**Solver: mopm's own resolver, in Zig, inside mopm.** Not a helper. Reasons: one code path and one lock; hermetic;
nothing else for a user to trust or update. pixi/rattler is Rust and cannot link into mopm, so using it means a second
binary. A helper is dropped, not deferred: if the Zig resolver proves too hard, the fallback is to embed a solver as
part of mopm's own release artifact (pinned and verified by mopm, invisible to the user), which is a new design
note, not a first step. mopm already resolves Mojo packages, so the Zig resolver extends an existing component.

What conda-forge solving needs from the resolver:

- **Repodata size and fetch.** Per platform (`linux-64`, `osx-arm64`, ...) plus `noarch`, the full `repodata.json` is
  hundreds of MB raw (tens of MB zstd). Sharded repodata (CEP 16: an index of per-package-name shards, each fetched
  by content hash) is the intended path: mopm reads the shard index, then only the shards of names in the closure,
  kilobytes each. Whether the conda-forge host serves shards is **unverified**; PR 1 measures it. If not, the fallback
  is `repodata.json.zst` with a conditional request, parsed streaming into a name-keyed index, never held whole.
- **Incremental fetch and cache.** A user cache keyed by url and hash: shards are immutable by hash, so they are never
  refetched; the index and any full file use ETag/If-None-Match (and the `jlap` patch stream if present). The solve
  works offline from a warm cache.
- **Constraints honoured.** `run_exports` are applied by conda-build when a package is built: they are already
  merged into that package's `depends` in repodata, so the resolver reads `depends` (match specs: name, version
  range, build-string glob, `|` and `,`), `constrains` (conditional upper bounds, applied only if the named package
  is in the closure), `track_features` (prefer packages without), and virtual packages (`__glibc`, `__osx`) from the
  target platform. Subset: exact, range and glob specs and `noarch`; a spec outside it is a lock error naming the
  package and spec (a solver limit, not a policy refusal), and the work item is to extend the subset.
- **Choice.** Highest version satisfying all constraints, then highest build number; a pure backtracking resolver over
  the sharded subset (closure sizes are tens of packages). A wrong solve is the main risk: PR 3 tests are goldens
  against pixi's solution for the examples, run in CI only.
- **Untrusted input.** Length limits on every field; no field reaches a shell.

Metapackages and lib-less packages (the xz lesson). The lock records the whole closure with `has_library`, read from
the file listing mopm takes at lock time (so buildrules opens no file to decide). A lib-less entry, whether a run dep
or the named root, is accepted with a warning naming it (for `xz`: "xz holds no library; a library may be named
liblzma"). buildrules' test unpack skips a lib-less entry with a note and does not fail (its own PR). No name is
silently remapped by this rule.

Platforms. The solve runs for each declared platform. A name missing on one platform is a lock warning naming the
subdir; that platform's entries are then absent, and a build for it fails at fetch time, not silently.

## 3. Install scripts: accepted, warned, not run

A closure entry with `pre-link` or `post-link` is accepted with a warning naming the package and script. `mopm sync`
does not run it. Why: mopm unpacks packages as files; running arbitrary scripts at sync would execute code before
the user chose to, and would differ per platform. Many scripts only set up activation or caches and the library still
loads. When a package does need its script, the warning is the signal, and extensibility comes through an explicit
opt-in later (a `[native-dependencies]` per-package key, e.g. `run-link-scripts = true`, a separate design) rather
than a default. Default: warn, skip.

## 4. The name mapping stays

`condaPackageFor` stays as shorthand (lz4 to lz4-c, z and zlib to libzlib, bz2 to bzip2, lzma and xz to liblzma, ...).
A name with no row is used as is. `spec/mopm-toml.md` says "shorthand, not a limit". A near-name (one edit from a
popular package, such as `libpgn`) is accepted with a warning naming both. `mopm pack` still errors on one conda
package named twice (a malformed manifest).

## 5. Migration

- Published packages naming `xz` keep validating. A consumer's `mopm lock` maps `xz` to `liblzma` through a small
  legacy-name table (one row today) with a note; a root `xz` with no mapping is the lib-less warning above.
- Old locks stay valid while their urls fetch and are not rewritten until `mopm lock` runs (`spec/lock.md`). The
  only format change is the optional `has_library` flag; readers that do not know it ignore it, as the spec says.

## 6. #277, `natives.txt`, the weekly job, `native_catalog.zig`

- **#277** (`mopm-closure --natives-libs`): merge as is. Its `listEntries` (fetch a `.conda`, check sha256, list
  libraries under `lib/`) is the listing the lock needs; PR 5 moves it into code `system_libs.zig` shares.
- **`natives.txt`, `natives.pixi.lock`, `natives-*.json`, the weekly job:** kept, narrowed to what our own CI loads;
  no longer a gate. Its pixi use is CI-only, never user-visible.
- **`native_catalog.zig`:** stays as the offline fallback until a release has run on the resolver; deleting it is a
  later decision.

## 7. Safety and integrity (these stay errors)

- **sha256 mismatch** on any download (mopm, buildrules): an error. This is integrity, not policy: the bytes are not
  the ones the lock named. A **corrupt or truncated archive** is the same class.
- Malformed names or specs (check a) and unparsable repodata are errors.
- Trust: conda-forge is the source; sha256 pins guard against change after the lock, not a bad first version.
  Everything else (typo, near-name, no library, scripts) warns.
- Channel: conda-forge by default; another channel is a later extension (a manifest key), not refused as policy.

## 8. PR sequence after approval

Owner: the mira lane. S under 200 lines, M under 600, L more.

1. **Measure** (S, mopm): shard availability, repodata sizes, lookup latency, on the farm. Gate for 2 and 3.
2. **Registry: remove the list** (M): delete `native-deps.ts`; `checkDepends` does a (error) and b (warn) from the
   mirror; add the mirror job and the stale-warning. Tests: valid, unknown and stale cases accepted with the right
   warning; a bad name and a `mojo-` impostor fail; `xz` passes.
3. **Lock: repodata fetch and cache** (M): shard/zstd reader, name-keyed index, ETag cache, offline solve from cache.
4. **Lock: the Zig solve** (L): resolver, `has_library`, warnings c to e, `--locked`; spec updates (`lock.md`,
   `mopm-toml.md`). Needs 1, 3 and PR 6.
5. **buildrules: skip lib-less entries with a note** (S): own PR; fixture in `ci/mojo_syslibs` (a lib-less root and
   run dep unpack without failure). Can start at once.
6. **#277 merged, then listing shared with the lock** (S).
7. **Publish-side async check and near-name warning** (M).
8. **Catalog narrowing** (S): `natives.txt` documented as CI-only.

Order: 1, 5 and 6 start at once; 2 needs 1; 3 needs 1; 4 needs 3 and 6; 7 and 8 last. PR 2 is the only step a
published package can observe; restoring the list reverses it.

## Questions for the CEO

1. Is a conda-forge channel only (extensible by a later manifest key) right for day one?
2. Warn-and-skip as the default for install scripts, with an explicit per-package opt-in as a later design?
