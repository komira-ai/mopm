# Why mopm, and how it is built

This is part one of the mopm documentation: the reasons and the design. Part two, [getting-started.md](getting-started.md),
is the practical guide. Anything not built today is marked **planned**. The reference documents this paper
leans on live in the repository: `spec/` (the contracts), [mopm-test.md](mopm-test.md) (the test runner) and
[RELEASING.md](../RELEASING.md) (the release pipeline).

## 1. Why Mojo needs a package manager

A language gets a real ecosystem when sharing code costs less than rewriting it. Rust has cargo and
crates.io; Python has pip and PyPI. Mojo has a compiler, a standard library and a way to compile a
package into one file (`mojo precompile` produces a `.mojoc`), but no single agreed way to name, version,
publish, find and install packages. Three properties of Mojo make that gap harder than it looks.

1. **A `.mojoc` is tied to one compiler version.** mopm treats a `.mojoc` as usable only with the exact
   Mojo it was built by (`spec/mopm-toml.md`). A registry that stores "version 1.2.0 of a package" is not
   enough: it must store which compiler each build is for, and a resolver must never hand a project a
   build its compiler cannot read.
2. **Mojo packages ship native code.** A package may wrap a C library or carry its own shared library.
   A package that depends on it must link and load that library, and without help every author works out
   the linker flags by hand.
3. **Tests and builds need to be trustworthy and cacheable.** A Mojo test that crashes the process, hangs,
   or eats all memory should be reported as such and not take the rest of the run with it. And a build
   system such as Buck2 should be able to build Mojo as cached, remote actions without re-deriving what
   "build a Mojo package" means.

mopm is "cargo for Mojo": one command line (written in Zig, shipped as a single static binary) and one
registry (mopm.dev) that handle these three things. It does not replace the Mojo compiler. `mopm build`,
`run` and `repl` run the stock `mojo` of your environment, and the exit status is mojo's.

Status: early. Version 0.0.x. The tool works end to end against a registry, but the registry is new, the
catalogue is empty today, and several things in section 10 are not built.

## 2. The shape of the system

```text
 author                                   consumer
   |  mopm publish                           |  mopm add / sync
   v                                         v
 API  /api/v1  --(commit)-->  conda channel  <--(install, verify sha256)
 (OpenAPI)                    conda.mopm.dev                ^
        |                                                   |
        +--(regenerates)--> sparse index --(resolve)--------+
                            api.mopm.dev/index        |
                                                      v
                                                  mopm.lock
```

- The **CLI** (`src/cli`, `src/core`) reads a package's `mopm.toml`, resolves dependencies, writes
  `mopm.lock`, installs, builds, tests, packs and publishes.
- The **registry** is an HTTP API (OpenAPI 3.1, `spec/api/openapi.yaml`) that accepts publishes and
  regenerates two read-only views: a **conda channel** (what pixi and other conda tools read) and a
  **sparse index** (what mopm reads). Both are static files, so reading needs no account and no running
  service.
- The **contract** between the two is the `spec/` directory. The CLI is tested against a local fake
  registry that implements the contract; the hosted registry is tested against the same contract
  documents (`//:contract`). Nothing in `spec/` describes the registry's internals.

## 3. The registry design

**Packages are conda packages.** A published version is a `.conda` archive named
`mojo-<name>-<version>-<build>.conda`, holding `lib/mojo/<name>.mojoc`, an embedded metadata file
`lib/mojo/<name>.mopm.json`, and any native libraries the package declares under `lib/`. The conda
format was chosen for three reasons: the Mojo toolchain itself is distributed as conda packages, so
an environment with `mojo` in it already has an installer for them; pixi installs them with no mopm
involved (`pixi add mojo-<name>`); and the format has hashes, sizes and subdirs for the four
platforms (`noarch`, `linux-64`, `linux-aarch64`, `osx-arm64`) built in. The registry accepts only the
allowed paths: no `bin/`, no link or activate scripts, no symlinks or hardlinks, no executable code
outside declared native libraries. A client that unpacks a package applies the same rules.

**The build string carries the compiler.** It is `mojo<compiler>_<n>`, for example `mojo1.0.0_0`, so two
builds of one package version for two compilers are two files under one version, and pixi's solver
cannot mix them either (the package depends on `mojo-compiler ==<exact>`).

**Immutability.** A published file never changes; a version number is never reused. Instead of deletion
there are two states. *Yank* hides a version from new resolution but leaves the file downloadable, so an
existing lock keeps working. *Takedown* (an administrator action, for malware, legal or abuse reasons)
removes the bytes, answers 410, and leaves a public log entry; the sha256 stays in the index so a lock
can explain what it was asking for. A tombstoned version never changes again.

**The sparse index.** `/index/<aa>/<bb>/<name>` is one newline-delimited JSON file per package, one line
per version, with state, the compiler requirement (`requires_mojo`), dependencies with their cargo-style
ranges, native library facts, file urls, sizes and sha256 values. It exists because conda repodata is
shaped for conda solvers and carries no yank reasons, tombstones or provenance. mopm resolves from the
index and never reads the conda `depends` strings, so there is no second dependency syntax to keep in
agreement. Records are versioned (`v`, `index_version`); a reader that meets a version it does not know
refuses with "update mopm" instead of skipping a line.

**Names and versions.** Names match `^[a-z][a-z0-9_]{1,63}$`. A name in an API path must be
normalised (lowercase, each run of `-`, `.` and `_` folded to one `_`); the API answers any other
spelling with `invalid_name` and does not redirect (the website's edge router does). Versions are exactly `MAJOR.MINOR.PATCH`, no
pre-release suffixes, no short forms, so a version has one spelling and equality is string equality.
Requirements follow cargo: a bare `1.2` is a caret range (`>=1.2.0, <2.0.0`), and `~`, `=`, `>=`, `<`
and comma-joined ranges work.

**Additive-only evolution.** The API, the index, the lock and the metadata each carry a version number.
New optional fields and endpoints may appear at any time; nothing is removed or retyped without a new
number (`/api/v2` would be served beside `/api/v1`).

**Where it runs.** The service in `service/` is TypeScript Lambda functions with a CDK stack set per
stage (beta, gamma, prod). Merges to `main` that touch the service promote beta, then gamma, then prod,
gated by end-to-end suites against each stage. The access model for that pipeline is described in
`docs/security/public-deploy.md`.

## 4. The lock and the resolution

`mopm.lock` is JSON written by mopm and committed, never edited by hand. It records, for every package in
the closure and every platform: the name, version, build, url, sha256, size, the compiler it was built
with, its direct dependencies, and the native libraries it carries. The rules a reader enforces
include: entries sorted and unique; every entry's channel is one the root project listed (a dependency
cannot add a channel); the url is exactly `<channel><subdir>/mojo-<name>-<version>-<build>.conda`;
every dependency named is itself locked; a package name comes from at most one channel (the shape of a
dependency-confusion attack is a hard error); and no two packages declare the same native `soname`.

**Resolution** (`src/core/resolve.zig`) picks one version of every package in the closure of the root
requirements. A candidate must be published (not yanked, not taken down) and built for exactly the
project's Mojo. Candidates are tried newest first, after the version an existing lock already pins; a
dead end backtracks to the latest choice. A failure names the requirements and where each came from.
There is no pre-release logic because there are no pre-releases. `mopm lock` keeps versions that still
fit; `mopm update` drops the pins of the named packages (all, with none named).

**Installing from a lock.** `mopm sync` downloads each locked file for the host's platform, refuses any
whose size or sha256 differs from the lock, builds a local channel of exactly those files under `.mopm/`,
and has `pixi install` create the environment from that local channel (pixi runs only as an installer;
the choice of what to install was made by mopm). Afterwards mopm checks the result against the lock:
each package's recorded sha256, its metadata file, every native library's hash, and that no
`lib/mojo/*.mopm.json` is installed that the lock does not name. `mopm sync --locked` never changes the
lock and never reads the index; CI should use it. A locked version that was yanked still installs, with
a warning that gives the reason; a locked version that was taken down fails, and the error shows the
public reason.

**One lock for several Mojo versions.** A package may list `[package] mojo = ["1.0.0", "1.1.0"]`. Its
lock is then `lock_version` 2: one entry per package version per platform with an `artifacts` map from
each Mojo version to that build's url, sha256 and size. `mopm lock` resolves once per listed Mojo
version and picks for each dependency the newest version in range that has a build for that Mojo; if none
does, it stops with a message that names the version, the Mojo versions it was published for, and the
three ways out. Nothing falls back to another Mojo. `mopm sync` installs the builds for the first
Mojo version the lock lists.

## 5. Packaging: conda and `.mojoc`

`mopm pack` writes one `.conda` per platform directory from a `.mojoc` you built with the compiler you
name (`--compiler`), plus the manifest-derived metadata. `mopm publish` packs and then follows the
registry's three steps: begin an upload for each file and PUT the bytes to the storage url the registry
names, commit the uploads, and poll until the publish is `published` or `rejected`. The token goes only
to the API, as a bearer token; the storage PUT carries none. The registry validates the archive (layout,
limits, manifest, filename, sha256) and generates the repodata entry itself from the validated manifest;
it never copies metadata out of the uploaded archive.

Today the `.mojoc` is an input: you run `mojo precompile` (or a build system does) and pass the result
with `--mojoc`. The spec describes `publish` building one `.mojoc` per listed Mojo version itself; that
is **planned** in the CLI. A buildrules integration (section 8) builds the `.mojoc` files as cached
actions.

## 6. Natives and autolink

A Mojo package can ship native shared libraries (`[native.<id>]` in `mopm.toml`: `kind` shared, static
or both; `mode` link or load). The published metadata lists each library's id, soname and the
sonames it needs from other packages. Consumers should not have to know any of this.

For `mopm build`, `run` and `repl`, mopm reads the `<name>.mopm.json` of every package installed in
the environment, plans the closure, and computes:

- `mojo build`: `-Xlinker -L` and `-l` flags (on Linux with `--no-as-needed`) and a run path to the
  environment's `lib` directory;
- `mojo run`: one `-Xlinker <shared object>` per library;
- `mojo repl`: a preload list (`LD_PRELOAD` on Linux, `DYLD_INSERT_LIBRARIES` on macOS) handed to the JIT.

The plan **refuses** a closure with a missing transitive library, two owners of one soname, a
static-only library under `run` or `repl`, or a library file absent from the environment, and says why.
`mopm link-plan` prints the plan from metadata files alone, and `--print-cmd` prints the mojo command
instead of running it. `mode = "load"` libraries, which the package opens itself, are the job of a small
Mojo runtime package (`mojo/mopm_rt`), which is a **placeholder** today.

## 7. The test runner

`mopm test` finds tests (`tests/**/test_*.mojo`, `src/**/tests/test_*.mojo`), builds each file once
through a generated harness, and runs **every test in its own process** under a supervisor. Reference:
`docs/mopm-test.md`. The design choices:

- **One process per test.** A crash ends only its own process, so it never loses another test's result.
  The cost is process start-up per test; running tests in parallel (`--jobs`) is **planned**.
- **A supervisor, not a shell.** Each test is the leader of a new process group, polled every 20 ms. At
  the deadline (default 60 s) the whole group is killed; the verdict is TIMEOUT, qualified `hung` (under
  5% of one CPU in the last window), `slow` (still computing) or `unknown`. A sampled resident-size cap
  (default the smaller of 4096 MiB and physical memory) gives OOM; it is a sampled cap, not a kernel
  limit, and measures only the test process. After every test, for any reason, the group is killed again
  and checked empty; a leftover process makes the run exit 5.
- **Verdicts that cannot lie.** A test that exits 0 without printing the TestSuite `PASS` line has not
  passed (FAIL). A crash reports the signal. A file that does not build marks all its tests
  COMPILE-ERROR. The discovery scan is compared with the binary's own `--skip-all` listing so a test
  that is silently not registered is an error.
- **Flaky handling that names the problem.** `--retries <n>` reruns a test that did not pass, with the
  same binary (its sha256 is recorded), argv, environment and directory. A test that failed and then
  passed is FLAKY and never PASS. A FLAKY test does not fail the run unless `--deny-flaky` is given,
  which CI should use so a retry never turns a failure into a silent green. Every attempt is kept in the
  JSON, in JUnit (Surefire-style flaky/rerun elements) and in its own output files. There is no flake
  history across runs yet.
- **Ignored tests carry a reason and an issue.** `# mopm: ignore "reason" #123` is required to say why
  and where it is tracked; a bare ignore is a discovery error.
- **Machine-readable output.** `--format json` (schema 1, never changed in meaning without a new
  number) and `--junit <file>`; exit codes 0, 1, 2 and 5 distinguish test failure, usage or discovery
  error, and toolchain problems.

Coverage (`mopm cov`) is **planned**; it is not in the command line today.

## 8. The unit graph and build systems

mopm owns what "build Mojo" means; a build system should only schedule and cache. `mopm plan
--unit-graph --locked [--mojo <version>]` prints, offline and deterministically, every unit of the
project: libraries, test files, binaries, and registry dependencies as `prebuilt` units (a `.conda` fetched
by url and checked by sha256, never compiled). Each unit has an id that includes its Mojo version
(`http_client@0.4.0#mojo1.0.0/lib`), the sha256 of each source, its dependencies in order, its native
libraries, its profile, its outputs, and a **key**: a hash that changes exactly when the unit's result
can change (including through its dependencies' keys and the toolchain closure hash). Editing one
package re-runs it and its dependents; unchanged `.mojoc` bytes stop the cascade.

`mopm unit build` and `mopm unit test` are what a build action executes for one unit: they verify every
declared input against the graph, run a pinned hermetic compiler wrapper with an empty environment, and
require non-empty outputs. The toolchain is mopm's own pin (a closure of conda packages plus a pinned Zig
as C compiler and linker), recorded in the lock as a hash, so a different mopm cannot silently build with
different bytes; `plan` refuses a lock whose recorded hash is not the one this mopm computes. Only Mojo
1.0.0 is pinned today.

The Buck2 integration is in the separate buildrules project, which reads the unit graph (its mopm
rules pin a mopm release). Its Mojo support is version 0 and runs on Linux x86_64 only; the mopm
repository's own `rules/buck2` and `rules/bazel` directories are placeholders. Not done in the unit commands: the test supervisor (`unit
test` runs the binary directly), coverage, CPU levels in the graph (given as `--target-cpu`, x86 levels
only), and native libraries that a workspace member builds itself.

## 9. Security

- **Publishing identity.** Interactive login is the device flow through GitHub; the token is stored in
  `credentials.json` (mode 0600) and never printed. For CI the API has an OIDC exchange
  (`/auth/oidc/exchange`): a CI identity token is exchanged for a publish token that is valid for 15
  minutes and for exactly one package and one version, and only if the identity matches a trusted
  publisher registered for the package. Versions record provenance (`none` or `oidc`, with repository and
  workflow). The CLI does not call the exchange itself yet; a CI job would exchange and pass the result in
  `MOPM_TOKEN`. How a trusted publisher is registered is not in the public API today.
- **What the consumer verifies.** Every download is checked against the lock's sha256 and size; the
  index's values are compared with the lock's, naming both on a mismatch; the repodata, the index and
  the API's version detail must agree. Plain-http registries are refused except loopback with a port.
  There are no package signatures in v1: integrity rests on TLS, create-once storage and the pinned
  hashes. A signed snapshot is a later design.
- **What the registry refuses.** Archives with absolute or traversing paths, links, special files, a
  `bin/` directory, link scripts, undeclared native code, case-fold collisions, or sizes over the
  limits (a package file of at most 100 MB, any one unpacked file of at most 128 MiB, today). Display fields (readme, description) are stored verbatim and are
  untrusted input; consumers must sanitize.
- **Release integrity.** Releases are produced by one automatic workflow. Each of the three binaries
  (Linux x86_64 and aarch64, macOS arm64) is built once, tested as a user would use it on
  those three platforms, then given a `SHA256SUMS` entry, a keyless cosign (Sigstore) signature and a GitHub
  build-provenance attestation. The workflow verifies all of it before any tag exists, then tags (through
  a dedicated GitHub App, since a repository ruleset allows only that App to create `v*` tags) and
  publishes exactly the verified files. A defect in this chain is meant to make the release red; the
  workflow's own lint plants a defect for each rule to show that. macOS binaries are **not** code-signed
  or notarized by Apple yet.
- **CI deployment.** The registry is deployed from a public repository by short-lived OIDC credentials
  that only workflows on `main` can assume, with per-workflow trust. `docs/security/public-deploy.md` lists
  what the repository enforces and what only its owner can set.
- **Untrusted input everywhere.** mopm refuses unknown manifest keys (a typo is an error), reads a strict
  TOML subset, and treats everything a registry returns as data to validate.

## 10. Trade-offs and what is not done

Trade-offs accepted on purpose:

- *Exact compiler match.* A package is usable only with the compiler it was built for. This is the
  truth about `.mojoc`, but it multiplies builds; publishing for several compilers is what `[package] mojo`
  lists are for.
- *conda as the carrier.* It gets pixi compatibility and hashing for free, and costs a dependency on
  pixi for `mopm sync` today (installing without pixi is **planned**).
- *Registry-computed metadata.* The registry writes repodata and index entries from the validated
  manifest and never trusts the archive's own, at the cost of a validator that must be kept right.
- *One process per test.* Strong isolation, slower on large suites.

Not built today (all **planned** unless stated):

- Commands: `cov`, `check`, `export`, `launch`. There is no `mopm search`, `info`, `doc` or `mcp`.
- A search, package pages, API reference pages and agent-facing endpoints on mopm.dev are designed
  (`docs/design/mopm-dev.md`) and not shipped.
- `publish` building the `.mojoc` per Mojo version; the CLI exchanging an OIDC token.
- Name normalisation beyond the current pattern; download counts.
- Sharded repodata; signed package snapshots; Apple signing and notarization.
- Test parallelism, flake history, `--failed`, `--shuffle`, result cache.
- Homebrew and apt packages (only the install script and the GitHub release exist).
- Mojo versions other than 1.0.0 in the pinned toolchain; Windows.
