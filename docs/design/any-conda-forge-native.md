# Any conda-forge library under `[native-dependencies]`

Status: proposal, for the CEO's ruling before any implementation. No code changes in this PR.

The ruling (2026-10-28): "Allow any conda-forge library. It's better long-term." The fixed list goes away:
`NATIVE_DEP_CURRENT` and `NATIVE_DEP_LEGACY` in `service/api/src/validate/native-deps.ts` are removed, and a package
may name any conda-forge package under `[native-dependencies]`. This note says what replaces the list, in the registry
and in the lock. Written against `main` at the merge of #276; #277 is open.

## What exists today

- `mopm pack` maps a native name to a conda package (`condaPackageFor`, `src/core/conda.zig`) and writes it into
  `depends`. The registry (`checkDepends`, `metadata.ts`) accepts a `depends` name only if it is `mojo-*` or in the
  list. That check is pure and offline; it reads no network.
- `mopm lock` writes the lock's `system_libs` (`src/core/system_libs.zig`) from a catalog pinned in the mopm release
  (`toolchain/natives.txt`, `natives.pixi.lock`, `src/core/toolchain/natives-*.json`, `native_catalog.zig`). There is
  no solver: a library outside the catalog is refused. The weekly `toolchain` job (`kpin-update.yml`) re-solves the
  catalog with pixi on a runner.
- buildrules downloads each `system_libs` entry (url and sha256 pinned), unpacks its `lib/` with
  `conda_unpack --all-libs`, and puts the directories on the library path of a test. `--all-libs` refuses a package
  with no shared library and a link that dangles. That is the xz lesson of #276: the `xz` metapackage holds no
  library, so the catalog must list `liblzma`.

The list was the only thing tying the registry to the catalog. Without it, the catalog can no longer be the source
of the pins.

## 1. What the registry checks at publish

| check | what it proves | cost | lean |
|---|---|---|---|
| a. Syntax: a valid conda name (lower case, `[a-z0-9._-]`), not `mojo-*`, a spec that parses | no odd text reaches a lock or a url | none, offline | at publish |
| b. The name resolves on conda-forge | rejects typos and invented names | a lookup per name | at publish, soft (below) |
| c. The version requirement is satisfiable on each declared platform | a package nobody can lock | a lookup per name and platform | lock time; at publish only as a warning from the mirror |
| d. The package holds a runtime library | rejects the metapackage (xz) case | download, 1 to 50 MB | lock time; later, off the request path |
| e. No pre-link or post-link script in the closure | no code runs at install | needs the whole closure | lock time |

Where the data for b comes from. Full conda-forge `repodata.json` is hundreds of MB per platform: far beyond the API
Lambda (10 s timeout, raised to 25 s in #278 after the group-create incident). Options:

1. Full repodata per publish: refused, it cannot fit the budget.
2. A per-package lookup (the anaconda.org API, or sharded repodata if conda-forge serves it; **unverified**, PR 1
   measures it): kilobytes per name, cached in the Lambda container. Pro: fresh. Con: a third party's latency and
   outages inside our budget.
3. Our own mirror: a scheduled job writes a small "name -> platforms, versions" index to S3 (a few MB, **estimate**);
   the Lambda reads it once per container. Pro: bounded, local, no outage dependency. Con: up to a day old.

Lean: 3. A name missing from a fresh mirror fails the publish; with a mirror older than a day it passes with a recorded
warning, so a conda-forge outage never blocks a publish. Check b guards typos, not safety (section 6).

Checks c, d and e need versions, package files and the transitive closure. That is a solve, and it runs earlier, where
the data already is: at `mopm lock` on the publisher's machine or CI, before `mopm publish`. The solve (section 2)
yields the closure, mopm lists each package's files (d) and looks for `pre-link`/`post-link` scripts (e), and a
failure names the package. mopm unpacks packages itself and never runs a script, so a package needing one cannot work:
refuse it. The registry re-checks d and e for the top-level name in an asynchronous worker (never the API Lambda),
cached by sha256: a follow-up (PR 6), not a day-one gate.

## 2. What replaces the pinned catalog for arbitrary natives

- A. **A per-package lock of the native closure, solved by `mopm lock`.** The lock already carries `system_libs`
  (name, version, build, url, sha256, size, deps); only the source of the entries changes, from our catalog to a solve.
- B. **Keep the catalog and refuse other names at lock time.** Does not meet the ruling: a package naming `libpng`
  could be published but never tested. The catalog stays only for our own CI (section 5).

Lean: A. The solver:

1. **pixi/rattler as a subprocess** (a helper binary mopm downloads sha256-pinned, like the Mojo toolchain, so a user
   installs nothing). Pro: a maintained, correct solver; the weekly job already uses it. Con: a second tool and
   network at lock time.
2. **rattler as a library**: it is Rust and cannot link into the Zig `mopm`; in practice this is option 1.
3. **Our own resolver in Zig.** Pro: hermetic, one code path. Con: the match-spec language is large, weeks of work,
   and a wrong solve is a wrong binary. We would support exact and range versions and build-string globs and refuse
   the rest.

Lean: 1 first; 3 only if the helper's size or lock-time network proves a problem. A wrong solve is the main risk, and
a maintained solver removes it.

Reproducibility. The lock is the reproducible object: every entry has url and sha256, and `mopm sync` and buildrules
fetch exactly those, never solving. Only `mopm lock` solves; re-running it may move versions, and `mopm lock --locked`
fails when the pins would change. If conda-forge removes a pinned file, the fetch fails naming the file.

Metapackages and lib-less run deps (the xz lesson). A solved closure holds packages with no shared library
(metapackages, `python_abi`-like). Options:

- i. The lock records only packages that hold a library. Buildrules is unchanged. Con: a wrong listing silently drops a
  real dependency, and the lock no longer shows what was solved.
- ii. The lock records the whole closure with a per-entry flag saying whether it holds a library; buildrules skips a
  flagged lib-less run dep and refuses a lib-less root (the package the user named: the xz case, with the message
  "xz holds no library; use liblzma").

Lean: ii. Complete evidence, a small explicit skip rule in buildrules, and the xz mistake still gets a clear error.
The flag comes from the listing mopm reads at lock time, so buildrules does not open files to decide.

Platforms. The solve runs for each platform the package declares; a name missing on one is a lock-time error naming
the subdir, never a partial lock. The registry mirror warns of the same at publish (check c).

## 3. The name mapping stays

`condaPackageFor` stays as shorthand (lz4 to lz4-c, z and zlib to libzlib, bz2 to bzip2, lzma and xz to liblzma, sqlite
and sqlite3 to libsqlite, brotlidec to libbrotlidec, and so on). A name with no row is used as is. `spec/mopm-toml.md`
says "shorthand, not a limit". `mopm pack` already refuses one conda package named twice.

## 4. Migration

- Published packages naming `xz` keep validating: with no list, `xz` is a conda-forge name that resolves. Nothing is
  unpublished, and `mopm pack` already writes `liblzma` for new ones.
- A consumer's `mopm lock` meets `xz` in an old package's `depends` and maps it to `liblzma` through a small
  legacy-name table (one row today), so old publishes do not block consumers. A *root* `xz` in a manifest is refused
  by the lib-less root rule with the message above.
- Locks pinning xz-era catalogs stay valid while their urls fetch; they are not rewritten until `mopm lock` runs
  (`spec/lock.md` already says so). The lock format does not change except the optional per-entry flag, which readers
  that do not know it ignore, as the spec says of unknown keys.

## 5. #277, `natives.txt`, the weekly job, `native_catalog.zig`

- **#277** (`mopm-closure --natives-libs`): repurpose. Its core is "fetch a `.conda`, check the sha256, list the shared
  libraries and links under `lib/`" (`listEntries`), which is exactly the listing the lock needs for the flag and for
  check d. Merge it as it is (READY, and it stops the weekly job's red test), then PR 5 moves the listing into code
  `system_libs.zig` shares. Retiring it would throw that code away.
- **`natives.txt`, `natives.pixi.lock`, `natives-*.json`, `natives.libs` and the weekly catalog job:** kept, narrowed to
  "what our own CI loads" (examples, mopm and buildrules tests). They are no longer a gate for users. The job's alarm
  rule (a pinned file returning other bytes) stays.
- **`native_catalog.zig`:** stays as the offline fallback (`--offline`, and our CI) behind the solver; the refusal "a
  library mopm has no pin for" goes. Deleting the fallback is a later ruling, after a release on the solver.

## 6. Security

- **Arbitrary binaries.** The catalog was a closed set we chose. Now a closure is whatever conda-forge serves and it is
  `dlopen`ed in the user's test process, so a bad package runs code. Trust model: conda-forge is the trusted source
  (packages built in its CI from reviewed feedstocks); we do not review each package.
- **sha256 pinning** protects against change after the lock (a replaced file, a hijacked mirror), not against a bad
  first version. buildrules and mopm check every download against the lock.
- **Typosquats.** Check b proves only that a name exists. Mitigations, cheapest first: `mopm lock` prints each solved
  name, version and feedstock for a human to see `libpgn`; a publish warning for a name one edit away from a known
  popular one; later, an optional per-package sha256 in `[native-dependencies]`. Lean: the first two now.
- **Install scripts** are refused (check e); mopm never runs them.
- **The solve reads untrusted repodata:** parse with length limits, never pass a field to a shell.
- **Channel:** conda-forge only; another channel is refused for now.

## 7. PR sequence after approval

Owner: the mira lane (mopm and buildrules). Sizes: S under 200 lines, M under 600, L more.

1. **Measure** (S, mopm): size and latency of the lookups in section 1, on the farm. Gate for 2.
2. **Registry: remove the list** (M): delete `native-deps.ts` and the allow-list option; `checkDepends` does a and b
   from the mirror; add the mirror job. Tests: a valid name passes; an invalid name and a `mojo-` impostor fail;
   `xz` still passes.
3. **Lock: the solve** (L): pinned pixi helper, per-subdir closure, the lib flag, checks d and e, `--locked`; spec
   updates (`lock.md`, `mopm-toml.md`).
4. **buildrules: lib-less run deps** (S): skip a flagged one, refuse a lib-less root; fixture in `ci/mojo_syslibs`.
5. **#277 merged, then repurposed** (S): share the listing with PR 3.
6. **Publish-side native check** (M): the asynchronous worker for d and e, the typosquat warning.
7. **Catalog narrowing** (S): `natives.txt` documented as CI-only.

Order: 1, 4 and 5 can start at once; 2 needs 1; 3 needs 5; 6 and 7 last. PR 2 is the only step a published package can
observe, and restoring the list reverses it.

## Questions for the CEO

1. A mirror up to a day old for check b (lean: yes, with a warning when stale)?
2. A pinned pixi helper first, a Zig resolver only if needed (lean), or the Zig resolver from the start?
3. A lib-less root is an error with a message (lean: yes), not silently mapped?
