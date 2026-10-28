# Per-ISA native variants that load the best build at runtime

Status: proposal, for the CEO's review before any implementation. No code changes in this PR.

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

## 1. Building the variants with Buck2

Levels: x86-64 `v1` (baseline), `v2`, `v3`, `v4` (AVX-512); aarch64 baseline (armv8-a) plus, if measured to matter,
armv8.2-a and armv9-a with SVE2; macOS arm64 one build (`apple-m1`, today's `target_cpu`).

| Option | How | Pros | Cons |
|---|---|---|---|
| A. A platform per level | a row per level in the platform table (`tools/build/platforms/table.bzl`) | reuses `target_cpu` as is | the table is "what a host is"; levels multiply rows, pools and golden hashes |
| B. An `isa` constraint plus a transition on the native-library rule | one constraint setting (values `v1..v4`, `armv8`, ...); the rule builds the library under each value; `cxx.bzl` takes `-mcpu` from the value instead of the row | one row per host, N configurations of one target; the level is in the action key | a new constraint and transition in the toolchain; every dependent must not accidentally inherit it |
| C. N copies of the target | the BUCK file lists each level by hand | no toolchain change | drift between copies, the rot the build rules avoid |

Lean: B. The variant set per library is a list in its BUCK target (snappy: v1, v2, v3, v4; others as measured). Cost:
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
treatment, they are already built). Each library is **measured against conda-forge's build on the farm** by
support's method (one process, same host, three runs) and the pair of numbers is published with the PR. Ours ships
whatever the result: a library that measures slower is reported, with the numbers and the compiler and flags, and
becomes a work item, not a reason to drop it. conda-forge remains the source for every other mopm user's natives
through `any-conda-forge-native.md`, unchanged.

## Keeping source pins current

Placeholder. Another lane is researching release detection and automatic PRs for the pins above; this section
will state the mechanism (what watches upstream, what opens the PR, what proves a bump) when that lands.

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
2. **komira: the `isa` constraint and transition; snappy 1.3.1 at v1 to v4** (M, support, with mira for the rule):
   bump the pin, byte-identical across two builds, list the full in-scope set from a grep of dlopen and link sites.
3. **mopm: channel `natives` and the `channel` key** (M, mira): spec (`mopm-toml.md`, `lock.md`), solver reads it,
   the registry serves it; a fixture first.
4. **mopm: ISA package layout, `isa.json` check, `has_library` for hwcaps files** (S, mira).
5. **komira: publish the snappy package; `komira_compression` moves to it** (S, support). Ends the hold.
6. **Benchmark proof** (M, support): records, failure rule, planted-host test.
7. **Benchmark-path libraries: zstd, lz4, zlib** (M each, support): pin, build per level, farm measurement against
   conda-forge, publish; komira's `komira_zlib`, `komira_lz4`, `komira_orc` move to them.
8. **The rest: bzip2, brotli, liblzma, sqlite; aws-lc and s2n-tls variants** (S to M each, support).
9. **aarch64 and macOS baseline packages, in-library dispatch where measured** (M, support).
10. **Pin freshness** (size set by the research lane's result).

Order: 1 starts at once; 2 and 3 in parallel; 4 after 3; 5 after 2 and 4; 6 after 5; 7 after 6; 8 and 9 after 7;
10 when the research lands. Reversible: dropping the `channel` key from a manifest returns that dependency to conda-forge.

## Questions for the CEO

1. Is our own `natives` channel in the mopm registry right, with a per-dependency `channel` key (lean), or should
   mopm prefer our channel for every name it holds?
2. Is aarch64 baseline plus in-library dispatch right for now, as glibc has no aarch64 hwcaps names we can rely on
   (lean), or do you want per-level aarch64 builds anyway, loaded by a mopm-side selector?
3. Publish a level only when its tests ran on a host of that level (lean), or publish all four x86-64 levels from
   the v3 farm and trust the build? Do you want AVX-512 and SVE2 hosts added to the farm to test v4 and v9?
4. A library that measures slower than conda-forge's still ships and is fixed (the direction as written). Should a
   regression of more than a set margin block the publish instead?
5. Patches against upstream: allowed when needed and carried in-tree (lean), or none, and a needed fix goes upstream first?
