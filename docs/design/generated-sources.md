# A library built from a generator's output that is not committed

Status: proposed. The decision it carries out was made on 2026-11-28: generated code is not checked in.

Facts below are at mopm `f562584`, buildrules `777bb5f` and komira `824f7d2` (each repository's main when this was
written); komira's counts were checked again at `c39b5f2` and have not changed. komira pins an older buildrules
(`.buckconfig`, `commit_hash`), which reads the same graph format.

Scope: generated Mojo library sources. Other generated files that komira commits stay committed: the check-set root
files under `ci/roots/` and `ci/test_roots/` (written by `tools/build/ci/targets.bxl`) and each package's
`buildrules.mojo.lock.bzl` (written by `buildrules mojo sync`), and so do the generator's own expected-output
goldens (section 3).

## The decision and why

komira commits the output of its code generators: 57 directories named `generated`, 692 files, 11,436,299 bytes
(`git ls-tree -r -l` at komira `824f7d2`). Its design `docs/design/generated_sources.md` chose to commit them (with a
gate that fails when the commit is not what the generator writes) for four reasons: mopm's unit graph lists a
library's sources by hashing the files in the tree, offline, without running a program, so a source that is not a
committed file cannot be in it; a reviewer sees the output in the diff; no format had to change; and a test cannot
pass on a stale file, because the freshness gate fails first. This design answers the first and third with a new
source kind, keeps the fourth (the compile is the check), and gives up the second by the owner's decision. Python in the same repository already works the other way: `python/BUCK` generates
`plan_pb2` and `plan_vocabulary_pb2` at build time and commits neither.

Committing has a cost that is now measured. komira-ai/komira#2509 found that six open pull requests, each adding a
member to the plan vocabulary, conflict with one another in every pair, in the generated files (105 conflicted files
over 15 pairs) and in the lock. The owner decided that generated code is not checked in.

So mopm gains a second kind of library source: **a generated source**. The package declares which of its files a
generator reads and where its output goes; a lock file records the sha256 of every output file; the unit graph
lists the outputs with those hashes, as it lists any source; the build system runs the generator, and mopm refuses
to compile from output whose bytes are not the recorded ones. A lock still names every byte a build compiles, `plan`
still runs no program, and the generation becomes an ordinary build action.

This is the option komira's design called "a generated-source input in the package graph" and said needed its own
design first. Generating only when a package set is staged stays rejected, for komira's reason: a dependent's lock
could not name a hash that does not exist yet.

## What changes, and what does not

- **A package without generated sources:** nothing. Its manifest, lock, unit graph (byte for byte, still format 6),
  keys and builds are what they are today.
- **A package with them:** its manifest has a `[generated.<id>]` table, a new file `mopm-generated.lock` beside
  `mopm.toml` records the output, and the generated directory is no longer in the tree. Its graph, and the graph of
  every package that has it as a path dependency, is format 7.
- **An installer:** nothing (section 4). A published package holds the compiled `.mojoc`, never library sources.
- **A person without Buck2:** `mopm build` and `mopm test` take the generator's output by hand
  (`--generated`, section 1) and check it against the record.
- **A person changing a `.proto`:** the diff is the `.proto` and the changed hashes in the two lock files (with the
  second way of section 5, in one). The lock
  is remade by `buildrules mojo sync`, which builds the generator and records its output. The build fails with that
  command when the record is stale, as komira's freshness gate does today.

## 1. mopm: the manifest, the record and the graph

### The manifest

```toml
[targets]
lib = { path = "generated/plan_proto" }

[generated.plan_proto]
generator = "protoc-gen-mojo 2"
inputs = ["*.proto"]
out = "generated/plan_proto"
```

(The values are an example: `src/plan_proto` holds four `.proto` files, and the version text is whatever the
generator's own version is.)

- `<id>` names the generated source within the package (the same rules as a native's id).
- `generator`, required: the generator's name and version, as text. mopm compares it and records it; it never runs
  or fetches it. Changing it makes the record stale, so a generator's version bump forces a new record.
- `inputs`, required: the package's own files the generator reads, as globs with the rules of a native's `srcs`
  (relative, no `..`, no symbolic links, a pattern that matches nothing is refused). They let `plan` see, offline,
  that the record was made from other inputs than the tree holds now.
- `out`, required: the directory the generator's output becomes, relative to the package. It must be the library
  directory (`[targets] lib`, else `src/<import name>`) or below it, because `mopm unit build` stages a library from
  below its root. Two tables may not have overlapping `out`, and an input may not lie under any `out`.

The generator's arguments, and inputs from outside the package (komira's AWS clients read a pinned botocore
archive), stay in the build system's rule: mopm never runs the generator, so it has nothing to pass them to. Their
effect reaches mopm as output bytes, which the record holds and the build checks.

The manifest refuses unknown tables (`src/core/manifest.zig:226`), so a mopm older than this one refuses a manifest
with `[generated]` in every command: `unknown key 'generated' in mopm.toml`. That is the old reader's refusal, and
it is the right one: an older mopm would otherwise plan the library without its generated sources.

### The record: `mopm-generated.lock`

```json
{
  "generated_lock": 1,
  "generated": [
    {
      "id": "plan_proto",
      "generator": "protoc-gen-mojo 2",
      "out": "generated/plan_proto",
      "inputs": [{"path": "bound_source.proto", "sha256": "..."}, ...],
      "outputs": [{"path": "generated/plan_proto/__init__.mojo", "sha256": "..."}, ...]
    }
  ]
}
```

Paths are relative to the package directory and sorted; entries are sorted by `id`; the text has one fixed layout.
It is a file of its own, beside the manifest that declares the tables, and not a key of `mopm.lock`, because:

- a package's generated output is a fact about that package, and every project that has it as a path dependency
  reads the same record (in komira, `calendar` and `calendar_ics` plan `calendar_proto`; writing the hashes into
  each dependent's `mopm.lock` would copy them, and every conflict with them);
- `mopm.lock` is the resolution of the root project and is rewritten by `mopm lock`, `add` and `remove`, which an
  older mopm does without the keys it does not know (`src/core/lock.zig`, `write`).

`lock_version` stays 3 and `mopm.lock` does not change. An older mopm never reads the new file.

The record is written by a new command, offline, that reads files and runs nothing:

    mopm record-generated <id>=<dir>...

run in the package directory, where `<dir>` holds the generator's output for `<id>`. It hashes the declared inputs
and every file of `<dir>`, and rewrites the entries it was given (an entry whose table is gone is dropped). It refuses
a symbolic link, anything that is not a regular file or a directory, a name starting with `.`, a file that is not
`.mojo` (a library source is Mojo, and `plan` lists only `.mojo` files of a library), a name that `plan` would take
for a test file and leave out of a library (`test_harness.isTestPath`, `src/core/test_harness.zig:49`: on the path
from the package directory, a `test_*.mojo` whose first directory is `tests`, or whose first directory is `src` and
whose direct parent is `tests`), an empty directory, and an id the manifest does not declare. An output's recorded path is `out` followed by its path
inside `<dir>`.

### `plan`: offline, running nothing

`mopm plan --unit-graph --locked` reads each member's `mopm-generated.lock` as it reads its manifest. Before it
prints a graph:

- **stale** (exit 3, like a stale lock): a table without a record, a record without a table, or a record whose
  `generator`, `out` or inputs (the set of paths, or a sha256) are not what the manifest and the tree give now:
  `mopm-generated.lock is out of date with mopm.toml: plan.proto has sha256 <now>, the record was made from
  <then>; build the generator and run 'mopm record-generated'`;
- **refused** (exit 4): a file in the tree below an `out`: `generated/plan_proto/plan.mojo is in the tree, but
  generated/plan_proto is the output of [generated.plan_proto]; generated sources are not committed: delete it`. A
  committed copy and a generated one can never both be a source.

A library's sources are then the `.mojo` files of its directory, walked as today (`libSrcs`,
`src/core/unit_graph.zig:452`) but not below an `out`, plus the recorded outputs. The library directory may be
missing when an `out` covers it. Today a missing default library directory means the root package has no library
(`defaultLib`, `src/core/unit_graph.zig:479-485`, adds no `lib` unit) and is an error for a path dependency
(`src/core/unit_graph.zig:602`, `has no library directory`); in both places a directory an `out` covers counts as
present.

### The graph: format 7

Each table is a unit of kind `generate`, `generate:<full name>/<id>` (like a native unit, it has no
`#mojo<version>`: generating does not depend on the Mojo version):

```json
{
  "id": "generate:komira-ai/plan_proto/plan_proto",
  "package": "komira-ai/plan_proto",
  "import": "plan_proto",
  "version": "0.1.0",
  "kind": "generate",
  "generator": "protoc-gen-mojo 2",
  "out": "src/plan_proto/generated/plan_proto",
  "srcs": [{"path": "src/plan_proto/plan.proto", "sha256": "..."}, ...],
  "deps": [],
  "natives": [],
  "key": "..."
}
```

`srcs` are its inputs. The library unit lists each output among its `srcs` with the recorded sha256 and the id of
the unit that writes it:

```json
{"path": "src/plan_proto/generated/plan_proto/plan.mojo", "sha256": "...", "generated": "generate:komira-ai/plan_proto/plan_proto"}
```

The key rule does not change. A library's key hashes its rendering, which holds every output's path and sha256, so
it moves when an output's bytes do; it does not hash the `generate` unit's key, so an input edit that leaves the
output unchanged rebuilds nothing. The `generate` unit's key covers its declaration and inputs, for a build system
that caches by key.

`unit_graph` is 7 for a graph that has a `generate` unit, and 6, byte for byte as today, for every other graph. This
is how formats 3, 4 and 5 were added (`CHANGELOG.md`, `tests/compat/v0.0.108/core/unit_graph.zig:25-47`): a reader
that does not know the new field would build without it, so a graph that has one says so in its number. Since
format 6 the current code writes one number always (`src/core/unit_graph.zig:35`); format 7 brings back a number
that depends on what the graph holds. mopm's reader today accepts exactly 6 (`src/cli/unit_cmd.zig:120`), and
buildrules' accepts 1 to 6 (`cli/src/mojo_lock.zig:325`, `rules/mojo/system_libs.bzl:33`), so each refuses a format 7 graph with the message it has: `<file> is unit graph
format 7; this mopm reads 6`, and buildrules' `a newer format needs a newer buildrules: update buildrules`.

### Where generation runs: the build, checked by `mopm unit build`

    mopm unit build --unit <id> --graph <file> ... --generated <generate id>=<dir>
    mopm unit test  (the same options)

A `lib` unit with generated sources takes one `--generated` for each `generate` unit its `srcs` name; `<dir>` is
that generator's output, as the build system made it in this build. Only a `lib` unit has generated sources: a
`test` or `bin` unit's `srcs` are its own file, and it imports the library's `.mojoc`, so `unit test` and the build
of a `test` or `bin` unit refuse `--generated` as an option no source names. Before anything runs (`verify`,
`src/core/unit_run.zig:67`), mopm checks every generated source in `<dir>` against the graph's sha256, and refuses a
file of `<dir>` the graph does not list, a missing `--generated`, and a `--generated` no source names:

    error: src/plan_proto/generated/plan_proto/plan.mojo, written by generate:komira-ai/plan_proto/plan_proto, has sha256 <got>, but
    the graph declares <want>: the generator's output is not what mopm-generated.lock records; build the generator,
    run 'mopm record-generated' and plan again

Then it stages the outputs under the library root with the other sources (`stage`, `src/core/unit_run.zig:246`).
This is the freshness proof: the compile of the library is the check, so no `.mojoc` exists while the generator's
output differs from the record, which is what komira's `<name>_fresh` gate gives today. A `generate` unit given to
`mopm unit build` is refused, as a native unit is: the build system runs the generator.

### The other mopm commands

- `source_sha256` (`src/core/source_digest.zig`) is computed by `mopm stage` (`src/cli/stage_cmd.zig:493`) and by
  `mopm publish` and `pack` (`src/cli/publish_cmd.zig:289`, in `prepare`, which both use) from the package directory in the tree. For the generated files it
  takes the record: the line of each output is `<recorded sha256> <path>`, the line a file on disk with those bytes
  would give, so the digest is computed offline and equals the digest of the same bytes in the tree. A file in the
  tree below an `out` is refused, as `plan` refuses it. The manifest is hashed as today, so adding the table changes
  a package's digest once, like any edit of its sources. In komira the published versions' digest comes from the
  release's `mopm stage` job, which reads the tree; buildrules' `mojo_conda` stages no library directory
  (`rules/mojo/pack.bzl:37-87`, `workspace_tree`: "Nothing else of the package is staged"), so the packages it packs
  carry no digest today (`source_digest.zig:96-110`), and this does not change that.
- The commands that compile from the tree themselves, `mopm build` and `mopm test` and also `mopm run`, `mopm repl`
  and `mopm build <file>` (which put each path dependency's directory on the import path,
  `build_cmd.importDirsHere`), take `--generated <full name>/<id>=<dir>` for each table of the package and of its
  path dependencies, check every file
  of `<dir>` against the record as `mopm unit build` does (the same refusals), copy the library with the outputs at
  their recorded paths into a scratch tree under `.mopm/`, and compile that. Without the option they refuse such a
  package, naming the table and the option. A person without a build system runs the generator by hand and mopm
  checks the bytes; mopm still runs no generator.
- `mopm lock`, `update`, `sync`, `add`, `remove`, `tree` and `metadata` parse the table (the manifest must parse),
  ignore it, and do not touch the record; `pack` reads it only for the digest (above). `link-plan` reads installed
  packages' `.mopm.json` and no manifest.

### Every reader of the graph format, and what each must learn

| reader | code | what it learns |
|---|---|---|
| mopm, writer | `src/core/unit_graph.zig` (`build`, `render`, `libSrcs`, `defaultLib`, the path-dependency branch at :602), `src/cli/plan_cmd.zig` | read the records; print `generate` units, `generated` on sources, format 7; exit 3 and 4 above |
| mopm, `unit build` / `unit test` | `src/cli/unit_cmd.zig` (`formatProblem` :120), `src/core/unit_run.zig` (`verify`, `stage`) | read 6 and 7; `--generated`; refuse a `generate` unit |
| mopm tests and goldens | `src/core/unit_graph_*_test.zig`, the in-source graph texts of `unit_graph.zig`, `tests/drivers/{resolve_e2e,examples,native_static,native_workspace}_test.zig` | unchanged for format 6; new cases for 7 |
| mopm site | `site/test/docs-values.test.ts:172` pins the library-directory expression of `unit_graph.zig` | keeps passing if that expression stays |
| buildrules, the table | `cli/src/mojo_lock.zig` (`parseGraph`, `newest_format`), `cli/src/mojo_cmd.zig` (`sync`, `check`), `cli/src/mojo_plan.zig`, `cli/src/mojo_versions.zig` | read 7; `generate` units; `generated` sources (section 2) |
| buildrules, committed form | `rules/mojo/tools/graph_norm.zig` (`identityOnly`, which edits mopm's text by its line layout) | drop the `srcs` and `key` of a path dependency's `generate` unit, as it drops them from that dependency's `lib` unit, and keep the unit, which the dependent's `generated` check needs |
| buildrules, checks | `rules/mojo/tools/table_check.zig` (`:table`), `rules/mojo/tools/files_check.zig` (`:check`), `ci/lock_hashes_check.zig` | the record is one of the hashed manifest files; a generated source is not a file of the tree |
| buildrules, rules | `rules/mojo/defs.bzl` (`mojo_package` :414, `unit_slice` :158), `unit.bzl`, `system_libs.bzl` (`NEWEST_FORMAT`, `compile_format`), `link.bzl`, `names.bzl`, `subdirs.bzl`, `versions.bzl`, `check.bzl` | format 7; the `generated` attribute (section 2) |
| buildrules, its own checks | `ci/native_library.bzl`, `ci/negative.bzl`, `ci/subdirs.bzl`, `ci/system_libs.bzl`, `ci/mojo_versions.bzl` | unchanged for their format 6 graphs |
| komira | every `src/<package>/buildrules.mojo.lock.bzl` (written by `buildrules mojo sync`, loaded by its `buildrules.mojo.bzl` for buildrules' rules) | nothing in komira's own code parses them |
| komira | `release/mopm_native_ids.bzl` (loads each `GRAPH`; reads `units`, `id`, `package`, and `kind == "native"` at :90) | nothing: a `generate` unit fails the kind test |
| komira | `tools/build/ci/lock_graphs.zig`, run by `tools/build/ci/lock_graphs.bxl` | nothing: it reads `mopm.lock` and which graphs a table holds, not their units |
| komira | `tools/build/mopm_migrate` (`plan.zig:632` writes `GRAPH` load lines) | nothing: it writes loads and parses no graph |

Nothing else reads the graph: `mopm build` and `mopm test` compile the tree themselves (`src/core/mojo_cmd.zig`),
and mopm's `rules/buck2` and `rules/bazel` are placeholders.

### Older and newer readers

| reader | data | result |
|---|---|---|
| this mopm and buildrules | a package without generated sources | the same graph and table, byte for byte |
| an older mopm | a manifest with `[generated]` | refused: `unknown key 'generated' in mopm.toml` |
| an older mopm | a format 7 graph | refused by `mopm unit` with its format message |
| an older buildrules | a format 7 graph | refused by `sync`, `check` and the rules: update buildrules |
| this mopm | a format 6 graph, or a lock from an older mopm | read as today |

The test that runs the previous release on new data is new, `//:compat_generated`: it vendors the `src/core`
readers of the release before this change under `tests/compat/v0.0.<n>/`, as `tests/compat/v0.0.108/` is vendored
(its README: the core only, since `src/cli` imports the core as `mopm_core`), and asserts the second row with the old
manifest reader, that the old `unit_graph.parse` reads a format 7 graph only as far as its number (the third row's
refusal text is in `src/cli/unit_cmd.zig`, held by that file's own test of format 7), and the last row with these
readers on the previous release's data. The fourth row is buildrules' own: its existing test that a format above
`newest_format` is refused holds it today, and brief 4 keeps that test for format 8.

## 2. buildrules

**A target's output as a source.** `mojo_package` takes `generated = {"<generate unit id>": "<target>"}`, the
target whose default output is the directory the generator writes, as it takes `natives` for a provided native
today. The key is the unit's full id, so two packages that use one table name never collide in a dependent. Each
`generate` unit of the package's graph, its own and its path dependencies', must have an entry and each entry a
unit; a dependent names the declaring package's alias. Unlike `check_provided_native` (`rules/mojo/defs.bzl:379`),
which fails when the package loads, this check is a validation of the build (with `:check`), so that a package whose
table does not yet have the unit still loads (the first conversion, below). It declares `generated_<id>`, an alias
of the target, for each entry the package's own tables name, and `generated`, a directory of every such output, both
from the attribute alone and not from the graph, which `sync` builds. The library's compile, `:lib_ungated`, the one
`mopm unit build` of the library unit (`rules/mojo/defs.bzl:798`; `:lib` is the same `.mojoc` held until the tests
pass, `defs.bzl:10`), will take the directories as inputs and pass
`--generated <generate id>=<dir>`. The test, coverage, profile and bitcode builds (`defs.bzl:831`, `:870`,
`unit.bzl:537`) are builds of test units, which import the library's `.mojoc` and take no `--generated`. The coverage
tree, which stages the library's sources at the names its line tables use (`_coverage_tree`, `unit.bzl:438`), will
take the generated files among its inputs. The generated sources will not be in the unit's `srcs`: the check at
`unit.bzl:112` (`the graph names the source ... but the target's srcs do not include it`) will skip a source with
`generated`.

**The first conversion of a package.** One pull request adds the table and the `generated` entry and deletes the
directory; `buildrules mojo sync`, run before the pull request is pushed, then builds `generated` (declared from the
attribute, so it exists although the committed table has no `generate` unit), records, and plans, and the new table
has the unit. For that build the package must load while its old table still names the deleted files. Today
`mojo_package` passes each source of the graph to the unit as a path string (`defs.bzl:613`), and a path that names
no file can stop the package from loading; buildrules' pull request makes `mojo_package` take a unit's sources
through a `glob` of the graph's paths, so a missing file is refused when the unit is built, by the check at
`unit.bzl:112` (`the graph names the source ... but the target's srcs do not include it`), and the package loads.
That is the message a build gives between the deletion and the sync, beside the validation's, which names the sync.
Adding, renaming or removing a table later is the same order.

**One execution platform.** The generate action runs on Linux x86_64 whatever the target platform. komira's
generator actions name no execution platform today (only `attrs.exec_dep`, so Buck2 picks one, and the farm has Mac
workers); komira's first pull request pins them (section 3, step 1), as buildrules' `TOOL_EXEC` does for `:check` and
`:table`, which is Linux x86_64 on a farm and the Mac only in local mode (`rules/core/platform.bzl:107`). One output
serves the Linux and macOS builds of a library, and the record is the same for every platform's graph. A macOS
compile checks that output's bytes like any other, so a generator that wrote other bytes on another host would be
refused, not compiled.

**The sync hashes an output it must first build.** `buildrules mojo sync` already builds a program before it plans:
the pinned mopm, with `buck2 build <label> --show-full-output` (`cli/src/mojo_cmd.zig:543-549`). It builds every
package's `generated` target the same way, in one `buck2 build`, runs `mopm record-generated <id>=<dir>...` in each
package that has generated sources, and then plans as today. So a sync of komira runs its generators on the farm,
with no local-execution flag; the pull request that runs such a sync quotes the build's summary line, which says
`local: 0`.
The sync as a build action (`rules/mojo/sync.bzl`) takes the same targets as inputs, writes the record among its
outputs and lists it in `committed`, so `:sync_check` compares it; the record it replaces is not one of its inputs,
as a stale table is not.

**The freshness proof** is the compile of the library (section 1): the build recomputes every output's sha256 and
refuses a mismatch, naming `buildrules mojo sync` through mopm's message. The offline checks that run where nothing
is built keep what they can see: `buildrules mojo check` verifies the inputs' hashes and that no file lies below an
`out`, and skips the generated sources instead of calling them gone (`cli/src/mojo_cmd.zig:921`); `//ci:lock_hashes`
counts a `generated` entry apart from a file entry instead of failing with `the lock names a file that is not there`
(`ci/lock_hashes_check.zig:77`). The record will be one of the files of `MANIFEST_SHA256` and of the `:workspace`
that `:table` plans from, for the package and for each path dependency that has one. buildrules' own coverage rule
already leaves out a source whose first line is `# @generated` (`rules/coverage/README.md`), so generated sources stay
unmeasured there too.

**Cache and farm.** The generator is an action like any other: cached by its inputs, run on the farm, and its
output directory is an input of the library's compile, so an unchanged output is a cache hit for everything after
it. komira already runs every generator in every build of a generated library, for its `<name>_fresh` gate, so the
farm does the same generating and one comparison fewer. The repository loses the committed bytes, and a clone and a
checkout with it.

## 3. komira

**What is committed today.** 42 `generated` directories under `src/` (469 files) and 15 under `tools/build/` (223
files); every file is Mojo except one hand-written fixture. Only nine are libraries of mopm packages, the `[targets]
lib` of `broker_proto`, `calendar_proto`, `chat_proto`, `contacts_proto`, `crm_proto`, `job_report_proto`,
`managed_mail_proto`, `plan_proto` and `supervisor_proto` (57 files). The other 33 under `src/` (17 AWS clients, 13
Google Cloud clients, `db_sqlite`, and the test protos of `proto_codec` and `wkt`) and the 14 generated ones under
`tools/build/` are built by komira's own `mojo_library`, which can already compile a generator's output: every one
of its four generating macros keeps the branch that builds from the generator for a library of the transition
ledger (`tools/build/cloud/aws.bzl:680`, `gcp.bzl:346`, `tools/build/mojo/proto.bzl:510` and `:638`). Those need no
change in mopm or buildrules. That branch has no green user on main: the ledger holds only two negative tests
(`tools/build/gen/transition.bzl`), so komira's first pull request is its first real use, for 47 libraries at once;
each `<name>_fresh` already runs the generator in every build, so the generator action is exercised, and the
compile from its output is what is new.

Kept on purpose: the 18 `.mojo` files under `tools/build/tests/functional/aws_codegen/golden/` (`git ls-tree` at
`c39b5f2`), the generator's expected output, which its golden test compares byte for byte, header included
(`golden/logs_pure_probe.mojo` begins `# @generated by aws-client-gen`), and the 38 `.golden` files of
`tools/build/tests/functional/proto_codegen/golden/` and `tools/build/proto-codegen/routes/golden/`, the same for
the proto generators. They are test data, not library sources, and stay committed with their header. The coverage
gate reads only `.mojo` files, so its rule below names the `aws_codegen` directory as its one exemption.

**The order.**

1. The libraries komira builds itself stop being committed, at once: the four macros build from `<name>_gen`, and
   the 33 directories under `src/` and the 14 under `tools/build/` are deleted with their `<name>_fresh`. The
   `generated` lines of their `coverage_census.tsv` (in `aws_secretsmanager` and `gcp_secretmanager`) go with them.
   The generator actions of the four macros name no execution platform today (only `attrs.exec_dep`, as in
   `tools/build/mojo/proto.bzl:124-150` and `tools/build/cloud/aws.bzl:610-611`); this step pins them to Linux x86_64
   (section 2). The macros keep building the nine mopm packages from their committed directory, by a list of the
   nine that is temporary: it shrinks by one package in step 4 and is removed in step 5. The header is not changed
   here, so what this step compares is exact (section 4); until step 2 the 47 libraries' outputs, which are build
   outputs now, still carry the clause that names `regen`, which does not apply to them for that window.
2. The generated header's regeneration clause is deleted, in its own pull request, so that the records of steps 4
   and 5 are made once from the final header. The clause is spelled in three emitters,
   `tools/build/proto-codegen/src/header.rs:25`, `tools/build/cloud/aws_act.zig:39` and
   `tools/build/mojo/tools/proto_gen.zig:39`. The line stays and loses only the clause, which reads, backticks
   included, ``Regenerate with `./buck2 run komira//tools/build/gen:regen -- <library target>`.``; what is left,
   `DO NOT EDIT. Generated by ...`, is true of a committed file and of a build output alike, and no line of any
   generated file moves.
   The generator versions are bumped, as `header.rs` asks when the text emitted for the same inputs changes:
   `PLUGIN_GENERATOR_VERSION` 1 to 2, `emit_aws::AWS_GENERATOR_VERSION` 15 to 16
   (`tools/build/proto-codegen/src/emit_aws/mod.rs:121`), and the `version 1` of the two Zig emitters to 2, in both
   texts each writes, `init_text` and `parts_init_text` (`aws_act.zig:38` and `:44`, `proto_gen.zig:38` and `:44`); the tables of steps 4 and 5 then say `protoc-gen-mojo 2`. `tools/build/gen:command_agreement` keeps
   holding the command where it is still spelled (`tools/build/gen/defs.bzl`, `regen.zig`) and no longer the
   emitters, and `tools/build/gen/README.md:71-73`, which says the header of every generated file spells the command
   and that `:command_agreement` holds four spellings, changes in this pull request to say the same (it is the one
   README that names `:command_agreement`). What the pull request updates, each the way it is updated today:
   - the nine committed directories, with `regen`, which acts on the `<name>_fresh` libraries only;
   - the 18 goldens of `tools/build/tests/functional/aws_codegen/golden/`, by building each test's `[gen]` output
     and copying it over the golden (`tools/build/tests/functional/aws_codegen/defs.bzl:12-13`);
   - the 38 `.golden` files of `tools/build/tests/functional/proto_codegen/golden/` and
     `tools/build/proto-codegen/routes/golden/`, the same way (`tools/build/proto-codegen/routes/BUCK:11`);
   - the tests that hold the header text: `generated_header_tests.rs`, `routes/tests.rs`,
     `main_aws_conformance_gen_test.rs`, `emit_aws/endpoint.rs`, `emit_dbstorable.rs` (under
     `tools/build/proto-codegen/src/`), `tools/build/cloud/aws_act_test.zig`,
     `tools/build/mojo/tools/proto_gen_test.zig`, `tools/build/tests/functional/aws_act/driver_test.zig`,
     `tools/build/gen/command_agreement_test.zig`, `tools/build/gen/fresh_test.zig` and
     `tools/build/tests/functional/gen_tools/fresh_driver_test.zig` (by `git grep` for `gen:regen`).
   It also runs `buildrules mojo sync` for the nine packages and commits their `buildrules.mojo.lock.bzl`, so it is
   green by itself: `:check`, `:table` and `<name>_fresh` of the nine pass on it. The three packages that plan one of
   them (below) list no source of it, because `graph_norm` drops a path dependency's sources, and their tables do
   not change.
3. When mopm and buildrules have released the generated source: komira pins them.
4. `plan_proto` first: its `[generated.plan_proto]`, its `mopm-generated.lock`, `mojo_package(generated = ...)`, its
   adopted library's `srcs` from the generator's output instead of `glob(["generated/plan_proto/**/*.mojo"])`,
   `mojo_conda`'s `dir` the package directory, `src/plan_proto` (buildrules resolves `members` such as
   `../proto_codec` against `dir`, `rules/mojo/pack.bzl:58-62`, so the empty default would fail with "leaves the
   repository"), `plan_proto` out of the macros' list, and the directory deleted, in the order of "The first
   conversion" (section 2).
5. The other eight proto packages the same way. The three packages that plan one of them as a path dependency
   (`calendar` and `calendar_ics` plan `calendar_proto`, `supervisor_proto` plans `broker_proto`) gain the
   `generated` entry for it in their `mojo_package` and are synced in the same pull request; no mopm package plans
   `plan_proto`. The macros' list goes.
6. What served committed sources is deleted: `tools/build/gen:regen`, `fresh.zig`, the `gen_fresh` rule,
   `transition.bzl` and its lint, `:command_agreement`, `tools/build/gen/*_test.zig`, the whole of
   `tools/build/tests/functional/gen_tools` (`fresh_driver_test.zig`, `regen_driver_test.zig`,
   `committed_data_test.zig`, `fake_buck2.zig`, its `BUCK` and its hand-written fixture),
   `tools/build/tests/negative/gen_commit`, and the uses in `tools/build/mojo/defs.bzl:395-399` (`fresh_gate`) and
   `tools/build/tests/functional/mojo_gcp_client/defs.bzl`. (`tools/build/mojo/readme.bzl:205`, the README examples'
   `_fresh.passed`, is another thing and stays.) The two negative tests of the ledger
   (`tests//negative/mojo_gcp_client:rest_reaches_plugin`, `tests//negative/proto:tasks_db_wrong_outs`) build from
   their generator, now the only way, and stay red as before. `tools/build/mopm_migrate` refuses a package with a
   `generated/` directory (`plan.zig:359`); with none left, the refusal and its case (`mopm_migrate_test.zig:857`)
   become a package whose manifest has `[generated]`. The code that built from a committed directory goes with it:
   the committed branch of each macro (`_committed_client` in `tools/build/cloud/aws.bzl`, the branch at
   `gcp.bzl:346`, `_committed_proto_library` and the branches at `tools/build/mojo/proto.bzl:510` and `:638`), and the
   helpers of `tools/build/gen/defs.bzl` (`generated_state`, `committed_sources`, `committed_data`, `declare_fresh`,
   `declare_unmigrated`, `declare_uncommitted`, `_in_transition`), so each macro has one path, from `<name>_gen`.

**What replaces the freshness gate and `regen`.** For the libraries komira builds itself, nothing is needed: the
library is compiled from the generator's output, so there is nothing to be stale. For the nine mopm packages, the
compile of the library (section 1), and `buildrules mojo sync` in place of `regen`.

**Coverage.** A generated source that is not a committed file is not staged for the coverage gate
(`tools/build/coverage/README.md`, "Generated sources"), and generated files are not measured today, so no floor
moves. Once no committed library source is generated, the rule that sets aside a committed file whose line 1 is
`# @generated` only lets a hand-written file leave measurement by gaining the header; the last komira pull request
makes the gate refuse such a file instead, except below `tools/build/tests/functional/aws_codegen/golden/`, the one
directory named as exempt (the goldens above; a test holds the list to that one entry), and removes
`generated_paths` and the census's `generated` lines. komira's coverage reader of `mopm.toml`
(`tools/build/coverage/covcheck/manifest.mojo`) parses the manifest strictly and accepts a dotted table name such
as `generated.plan_proto` (line 263), so the new table needs no change there.

**`generated_sources.md`.** Step 1 changes its status to "decided: a generated-source input in the package graph
(2026-11-28), because generated code is not checked in", and opens its body with a paragraph saying that the
sections below describe how the nine mopm packages are still built, committed, with their gate and `regen`, until
steps 4 and 5, so that the status and the body agree in that window. Step 6, when the machinery is gone, changes its
sections so:

- the line limit: a generated file is no longer a file of the repository, but Mojo still hangs on very large files,
  so the generator keeps splitting a large module into `_parts/`;
- coverage: as above;
- third-party text: neither the botocore and googleapis inputs nor the text derived from them is committed; the
  `NOTICE` entry stays, because the build still compiles code derived from them;
- the transition ledger, the single-path rule and the size projection: removed, with the machinery they describe.

The other documents that describe committed generated sources (by `git grep` for `gen:regen`) change with the step
that makes them false: the READMEs of `wkt` (`src/wkt/README.md:160-163`) and `proto_codec`
(`src/proto_codec/README.md:169-170`), whose test protos step 1 stops committing; the README of each of the nine
proto packages, and the comment in its `BUCK` that names `gen:regen` (all nine have one), with the step that
converts it (4 or 5); `tools/build/gen/README.md:71-73` with step 2 (above); and `tools/build/README.md:20`, the rest
of `tools/build/gen/README.md`, `tools/build/mojo/README.md` ("Committed generated sources") and
`tools/build/ns_rename/README.md`, with step 6.

**The root files of the check set.** Every pull request that adds or deletes a target (steps 1, 4 and 5: the
`<name>_fresh` targets, the generator aliases) rewrites `ci/roots/` and `ci/test_roots/` with the command in
`tools/build/ci/README.md` (`tools/build/ci/targets.bxl:generate`), which the guard names when they are out of date.

**Repositories that use komira as a cell.** A mopm pin bump edits komira's own `BUCK` files where they name the
mopm (each `mojo_conda(mopm = ...)`, brief 5), but not the toolchains cell's `tools/build/cells/toolchains/BUCK`:
that file reads the version from buildrules' table (`rules/mopm/pins.bzl`, which buildrules' pull request extends)
and from `mojo_pins.bzl` and `mopm_pins.bzl` beside it, which `buildrules mojo sync` writes. A repository that copies
that `BUCK` (its header asks a repository using komira as a cell to copy it) keeps the two `.bzl` files beside its
copy and needs no edit to the copy itself; after step 3 it moves its pointer to komira and its buildrules pin, and
syncs, as a step of its own.

## 4. Package publication

A published package holds no library source today, and this changes nothing in it:

- `mopm pack` writes exactly `lib/mojo/<import>.mojoc`, `lib/mojo/<import>.mopm.json`, one `lib/<soname>` per native
  archive and `lib/mojo/<import>.bins/<name>.mojo` per program (`src/core/conda.zig:543-546`). The library's `.mojo`
  files are never packed.
- `mojo_conda_holds(sole = True)` (buildrules `rules/mojo/pack.bzl`, `rules/mojo/tools/prebuilt_unpack.zig`) refuses
  a package with anything under `lib/mojo/` but its own `.mojoc`, `.mopm.json` and programs; every komira package
  with generated sources sets it on its `conda_holds` target (39 of the 41 `mojo_conda_holds` calls in
  `src/*/BUCK` set it, by `git grep`; the two that do not, `awslc` and `libc`, have no generated sources).
- Of komira's 66 published packages (`release/readme_e2e/packages.bzl`), only `bench` has a program
  (`bins/run_spsc_ring.mojo`, hand-written). Eleven published packages have a `generated` directory: the nine above,
  which ship the `.mojoc` compiled from it, and `proto_codec` and `wkt`, whose `generated` holds test protos outside
  their library. The AWS and Google Cloud clients and `db_sqlite` are not mopm packages.
- The release also builds a second set of packages with komira's `conda_package` (`release/artifacts.textproto`,
  `tools/build/package/release_set.txt`). It holds three Google Cloud clients that step 1 converts,
  `gcp_cloudresourcemanager`, `gcp_iam` and `gcp_run`, and eight of the nine proto packages (not `crm_proto`). That
  packer also writes only the `.mojoc`, native archives, `LICENSE` and `README` (`tools/build/package/conda.bzl:380-416`;
  it passes the sources only to its load check), but no `sole` check guards it.

**What a conversion compares, and why it is exact.** Steps 1, 4 and 5 change where a library's sources come from and
not their bytes: the header is changed in step 2, on its own, before the nine are converted, and step 1 converts
under the header it found. Each conversion pull request shows:

- the generator's output equal, file for file and byte for byte, to the directory it deletes (what `<name>_fresh`
  held on main); for the nine, the record's output hashes equal to the source hashes of the table it replaces;
- the `.conda` files of the converted packages that a release builds (both sets), compared with the ones main
  builds: the same members and `info/index.json`, and the `.mojoc` bytes. The `.mojoc` is expected to be equal,
  since the compiler gets the same source bytes in the same package layout; a difference is shown in the pull
  request with its cause before it merges, not taken as given.

Step 2 changes the bytes of every generated file and so of every `.mojoc` built from one; that pull request claims
no equality. A dependent's lock pins the `.conda` by sha256 and never needs the sources.

## 5. What the committed lock records: an open question

Not committing the generated files removes their 105 conflicts, but what the lock files record decides what still
conflicts. Sections 1 to 4, 6 and 7 are written for the first way. The owner is choosing; if he takes the second way,
the table at the end of this section is the edit, row by row, and this section then shrinks to the decision and the
second way's costs.
The design of komira-ai/komira#2509 expects a member pull request to change only the `.proto` and its claim; under
either way that holds for the files a person edits, not for the lock lines.

**First way (written above): the record holds every output's sha256.**
- Conflicts: two pull requests that change one `.proto` conflict in `mopm-generated.lock` (its input line and the
  changed outputs' lines) and in `buildrules.mojo.lock.bzl` (the same lines and the `generate` unit's `key` line,
  once per platform), as that file already
  conflicts for any hand-written source two pull requests both edit. The second pull request takes main's files and
  runs `buildrules mojo sync` on the farm.
- A generator change: komira's generators are built from its own Rust source, so an edit of a generator that changes
  its output makes every record of that generator stale, up to all nine, and the pull request that edits the
  generator syncs them all on the farm and commits the nine record and table pairs (as step 2 of section 3 does).
- Reproducibility: the lock names every byte a build compiles; a generator that changes without a version bump, or
  writes other bytes on another host, is refused by the compile.
- The digest: `source_sha256` pins the generated bytes, so a build added later to a published version for another
  Mojo compiler is accepted only if it compiles the same generated code.
- mopm without a build system: `mopm build --generated` checks the bytes a person generated.
- The machinery it needs: `mopm record-generated`, the record file, a generator build in every sync, and the order
  of "The first conversion".

**Second way: the lock records nothing about the outputs.** A generated source is named by its generator's name and
version (in the manifest) and its inputs, which `plan` hashes offline from the tree; the build makes the bytes.
- Conflicts: in `buildrules.mojo.lock.bzl`, once per platform, the input's line in the `generate` unit and that
  unit's `key` line still conflict when two pull requests change one `.proto` (the unit imports nothing, so
  `graph_norm` keeps its key, and the key covers the inputs; inferred from `graph_norm.zig`, since no committed lock
  has a `generate` unit yet). The first way has these two lines too and adds, in the same file, the changed outputs'
  lines, and in `mopm-generated.lock` the input's line and the outputs' lines once more.
- A generator change: nothing to sync; the build regenerates and recompiles.
- Reproducibility: the lock no longer names the bytes compiled. A generator that changes without a version bump
  gives other bytes under the same graph and key; the build system's own keys still rebuild what changed, but mopm's
  key does not move, and a generator that writes other bytes on another host goes unnoticed.
- The digest: `source_sha256` pins the generator's name and version and the inputs, not the generated bytes; when the
  generator changes without a version bump, a build added later for another Mojo compiler carries the same digest
  over other generated code.
- mopm without a build system: `mopm build --generated` accepts whatever a person generated.
- What it saves: no `mopm record-generated` and no record file; `buildrules mojo sync` builds no generator; the
  first-conversion order goes, since the table changes by a plain sync.

**The edit for the second way.** Each row names the text as it stands and what it becomes. Every use of
`mopm-generated.lock`, `record-generated`, "record" and "stale" in sections 1 to 4, 6 and 7 is in a row, or holds in
both ways, as the last rows say. If the owner takes the first way instead, the only edit is this section: it shrinks
to the decision and the first way's costs.

| where | the text now | becomes |
|---|---|---|
| "The decision and why", first paragraph | "keeps the fourth (the compile is the check)" | "keeps the fourth (a library is compiled from the generator's output of the same build, so nothing compiled is stale)" |
| "The decision and why", third paragraph | "a lock file records the sha256 of every output file; the unit graph lists the outputs with those hashes, as it lists any source; the build system runs the generator, and mopm refuses to compile from output whose bytes are not the recorded ones. A lock still names every byte a build compiles, `plan` still runs no program" | "the unit graph names each generator by its name, version and the sha256 of its inputs; the build system runs the generator and compiles what it writes. The lock names the generator and its inputs, not the output bytes; `plan` still runs no program" |
| "What changes", "A package with them" | "a new file `mopm-generated.lock` beside `mopm.toml` records the output, and" | "and" |
| "What changes", "A person without Buck2" | "and check it against the record" | "and mopm compiles it" |
| "What changes", "A person changing a `.proto`" | "the changed hashes in the two lock files (with the second way of section 5, in one). The lock is remade by `buildrules mojo sync`, which builds the generator and records its output. The build fails with that command when the record is stale, as komira's freshness gate does today." | "the changed input hash in `buildrules.mojo.lock.bzl`, remade by `buildrules mojo sync`, which `buildrules mojo check` asks for when the input hash is stale." |
| section 1, title | "the manifest, the record and the graph" | "the manifest and the graph" |
| section 1, "The manifest", `generator` | "mopm compares it and records it; it never runs or fetches it. Changing it makes the record stale, so a generator's version bump forces a new record." | "mopm puts it in the graph, where it moves the key of the `generate` unit and of the library; it never runs or fetches it." |
| section 1, "The manifest", `inputs` | "They let `plan` see, offline, that the record was made from other inputs than the tree holds now." | "`plan` hashes them into the `generate` unit, so an input edit moves the library's key." |
| section 1, "The manifest", the paragraph after the bullets | "which the record holds and the build checks" | "which the build makes" |
| section 1, "The record: `mopm-generated.lock`" | the whole subsection, with `mopm record-generated` | deleted |
| section 1, "`plan`" | "reads each member's `mopm-generated.lock` as it reads its manifest. Before it prints a graph:" and the **stale** bullet | "Before it prints a graph:", with the **refused** bullet only (inputs are hashed from the tree at every plan) |
| section 1, "`plan`", the paragraph after the bullets | "but not below an `out`, plus the recorded outputs" | "but not below an `out`; the outputs are not listed" |
| section 1, "The graph: format 7" | the library unit lists each output in `srcs` with `generated`, and "The key rule does not change ..." | the library unit has `"generated": ["generate:<full name>/<id>", ...]` and no output in `srcs`; its key hashes the key of each unit it names, as it hashes a built native's |
| section 1, "Where generation runs" | "mopm checks every generated source in `<dir>` against the graph's sha256, and refuses a file of `<dir>` the graph does not list", the error text, and "This is the freshness proof: ... `<name>_fresh` gate gives today." | "mopm stages every `.mojo` file of `<dir>` under the library root, refusing a symbolic link, a name starting with `.`, and a missing or unused `--generated`. No hash is checked." |
| section 1, "The other mopm commands", digest bullet | "For the generated files it takes the record: the line of each output is `<recorded sha256> <path>`, ... equals the digest of the same bytes in the tree." | "For each table it takes a line of the generator's text and the inputs' lines; the generated bytes are not in the digest." |
| section 1, "The other mopm commands", `mopm build` bullet | "check every file of `<dir>` against the record as `mopm unit build` does (the same refusals), copy the library with the outputs at their recorded paths" and "mopm checks the bytes" | "copy the library with the `.mojo` files of `<dir>` below its `out`" and "mopm compiles them" |
| section 1, "The other mopm commands", last bullet | "ignore it, and do not touch the record; `pack` reads it only for the digest (above)" | "ignore it; `pack` reads it for the digest (above)" |
| section 1, readers table | "read the records" (mopm, writer); "the record is one of the hashed manifest files" (buildrules, checks) | "hash the inputs"; "a generated source is not a file of the tree" |
| section 2, "A target's output as a source" | "(the first conversion, below)" and ", which `sync` builds" | deleted |
| section 2, "The first conversion of a package" | the whole paragraph | "A package's first conversion adds the table and the `generated` entry, deletes the directory and runs `buildrules mojo sync`; a unit's sources are taken through a `glob` of the graph's paths, so the package loads while its old table names the deleted files." |
| section 2, "One execution platform" | "and the record is the same for every platform's graph. A macOS compile checks that output's bytes like any other, so a generator that wrote other bytes on another host would be refused, not compiled." | "A macOS compile uses that output; nothing compares it with another host's." |
| section 2, "The sync hashes an output it must first build" | the whole paragraph | "`buildrules mojo sync` plans as today and builds no generator." |
| section 2, "The freshness proof" | the whole paragraph up to "buildrules' own coverage rule" | "There is no freshness proof: the library is compiled from the generator's output of the same build. `buildrules mojo check` verifies the inputs' hashes and that no file lies below an `out`; the graph names no output, so `//ci:lock_hashes` reads nothing new." |
| section 3, step 2 | "so that the records of steps 4 and 5 are made once from the final header" and "the tables of steps 4 and 5 then say `protoc-gen-mojo 2`" | "so that steps 4 and 5 convert under the final header" and "the manifests of steps 4 and 5 then say `protoc-gen-mojo 2`" |
| section 3, step 4 | "its `mopm-generated.lock`," | deleted |
| section 3, "What replaces the freshness gate" | "For the nine mopm packages, the compile of the library (section 1), and `buildrules mojo sync` in place of `regen`." | "For the nine mopm packages, nothing either; `buildrules mojo sync` remakes the table when an input changes." |
| section 4, "What a conversion compares" | "for the nine, the record's output hashes equal to the source hashes of the table it replaces;" | deleted |
| section 6, pull request 1 | "`mopm-generated.lock`, `mopm record-generated`,", "the digest from the record" and "can plan and check a library" | deleted; "the digest from the generator and its inputs"; "can plan and build a library" |
| section 6, pull request 4 | "the sync step," | deleted |
| section 7, brief 1 | "the `mopm-generated.lock` format ...; `mopm record-generated <id>=<dir>...`;", "read each member's record, exit 3 when it is stale and", "`source_sha256` from the record", "`spec/lock.md` (a pointer)", and the tests of the stale cases, the record command, a changed byte and an extra file | deleted, but "`source_sha256` from the generator and its inputs" |
| section 7, brief 1, tests | "`mopm build` and `test` with the same cases and without the option" and "the digest equal to that of the same files on disk" | "`mopm build` and `test` with a missing and an unused `--generated`, and without the option" and "the digest equal to one made from the generator's text and the inputs' lines, whatever the generated bytes" |
| section 7, brief 4 | "stage the record for `:check` and `:table` ...", "build the `generated` targets and run `mopm record-generated` ... not an input);", "teach ... `//ci:lock_hashes` the generated entry", and the tests of a stale record, a changed output and `lock_hashes` | deleted |
| section 7, briefs 6 and 7 | "its record against the old table," and "and the build with the sync command" | deleted |
| holds in both ways | section 3, step 2's sync of the nine packages and brief 3's: until they are converted, the nine directories are committed sources, hashed in their tables like any other, so the header change needs that sync in either way; "stale" in the first paragraph's reasons and in "nothing to be stale" (section 3) | unchanged |

## 6. The pull requests, in order

Each lands alone. Pull requests 1 and 2 can start at once, in parallel.

1. **mopm: the generated source.** The manifest table, `mopm-generated.lock`, `mopm record-generated`, format 7,
   `--generated` for `unit build`, `build` and `test`, the digest from the record, the specs, and
   `//:compat_generated`. After it: mopm can plan and check a library built from uncommitted generator output;
   every other project is unchanged. Its merge releases mopm by itself (`RELEASING.md`: releases are automatic from
   main once every stage is green); nobody cuts it. Pull request 4 waits for that release's tag, and a red beta stage
   delays it until the next green push to main releases.
2. **komira: komira's own generated libraries are not committed** (section 3, step 1). After it: 47 of the 57
   directories are gone; the nine proto packages are still committed and gated.
3. **komira: the generated header's regeneration clause reworded** (step 2). After 2. After it: the nine committed
   directories, their tables and the goldens carry the final header.
4. **buildrules: build a package with generated sources.** After mopm's release. Format 7, `generated` in
   `mojo_package`, the sync step, the checks, the new mopm pin, and `examples/mojo/generated` converted. After it:
   buildrules builds such a package; every other package is unchanged.
5. **komira: pin that mopm and buildrules** (step 3). After 4. After it: no behaviour changes; the tables name the
   new mopm.
6. **komira: `plan_proto` is not committed** (step 4). After 3 and 5. After it: a plan vocabulary pull request
   changes the `.proto` and lock lines only.
7. **komira: the other eight proto packages are not committed** (step 5). After 6. After it: no library source is
   committed.
8. **komira: remove the committed-source machinery** (step 6). After 7. After it: one way to build a generated
   library, and the coverage gate refuses a committed generated file outside the goldens' directory.

## 7. Briefs

**1. mopm (komira-ai/mopm): a library source generated by the build.** Add `[generated.<id>]` (`generator`, `inputs`,
`out`) to the manifest with the rules of section 1; the `mopm-generated.lock` format (`spec/`, with a JSON schema);
`mopm record-generated <id>=<dir>...`; in `plan`, read each member's record, exit 3 when it is stale and 4 when a
file lies below an `out`, and print `generate` units, `generated` sources and format 7 only when there is one;
`mopm unit build` and `unit test` read formats 6 and 7, and `unit build` of a `lib` unit takes `--generated`;
`source_sha256` from the record in `stage`, `publish` and `pack`; `mopm build`, `test`, `run` and `repl` take
`--generated` and refuse such a package, or a path dependency with a table, without it. Update `spec/unit-graph.md`, `spec/mopm-toml.md`, `spec/lock.md` (a pointer) and
the changelog. Tests: graph goldens for a package with a generated source alone, below hand-written files, and as a
path dependency; each stale case and the committed-copy refusal with its exact message; the record command's
refusals (symbolic link, a file that is not `.mojo`, a test-file name, empty directory, unknown id); `unit build`
with a changed byte, an extra file, a missing and an unused `--generated`, and `--generated` on a `test` unit;
`mopm build` and `test` with the same cases and without the option; `mopm run` and `mopm build <file>` with a path
dependency that has a table, with and without the option; a path dependency whose library directory is an
`out`; a format 6 graph read unchanged; the digest equal to that of the same files on disk; `//:compat_generated`
(the previous release's core readers on new data, and these readers on the previous release's); `unit_cmd`'s
format test for 7 and 8.

**2. komira (komira-ai/komira): stop committing the generated libraries komira builds itself.** Make the four
generating macros build from `<name>_gen` when a library is not one of the nine mopm packages (a list of the nine,
temporary: briefs 6 and 7 shrink and remove it), with `exec_compatible_with` Linux x86_64 on their generator
actions, which name no execution platform today; delete the 33 directories under `src/` and the 14 generated ones
under `tools/build/` (not the hand-written fixture of `tools/build/tests/functional/gen_tools`, nor the 18 goldens
of `aws_codegen`), their `<name>_fresh` targets and their census `generated` lines; leave the header as it is;
rewrite the root files of the check set (`tools/build/ci/targets.bxl:generate`); change the status of
`docs/design/generated_sources.md` and the READMEs of `wkt` and `proto_codec` as section 3 says. Tests: each library's existing tests, now on the generator's
output; the build of every deleted library's dependents; the comparisons of section 4 for every deleted directory
and for the `.conda` of `gcp_cloudresourcemanager`, `gcp_iam` and `gcp_run` in the release's second set; a negative
case that a committed directory beside a library built from its generator is refused.

**3. komira (komira-ai/komira): delete the generated header's regeneration clause.** In `header.rs`, `aws_act.zig`
and `proto_gen.zig`, delete the clause and keep the line, and bump the generator versions (section 3, step 2);
regenerate the nine committed directories with `regen`; update the 18 `aws_codegen` goldens and the 38 proto
`.golden` files by building their `[gen]` outputs and copying them; run `buildrules mojo sync` for the nine packages
and commit their `buildrules.mojo.lock.bzl`; change `tools/build/gen/README.md:71-73` to match. Tests: the tests section 3 lists, on the new text and versions; the
golden tests on the copied goldens; `:check`, `:table` and `<name>_fresh` of the nine green on the pull request;
`:command_agreement` holding the command where it is still spelled; no change to the tables of `calendar`,
`calendar_ics` and `supervisor_proto`.

**4. buildrules (komira-ai/buildrules): build a mopm package that has generated sources.** Read format 7 in the CLI
(`mojo_lock.zig`, `graph_norm.zig`, `mojo_cmd.zig`) and the rules (`NEWEST_FORMAT`, `compile_format`,
`unit_slice`); `graph_norm.zig` drops a path dependency's `generate` unit's `srcs` and `key` and keeps the unit; add
`generated = {id: target}` to `mojo_package` with the checks both ways as a validation (not a load failure), the
`generated_<id>` and `generated` targets declared from the attribute, a unit's sources taken through a `glob` of the
graph's paths (so a missing file is refused at `unit.bzl:112`, not at load), `--generated` on the `:lib_ungated`
compile, and the generated files among the inputs of the coverage tree; stage the record for `:check` and `:table`, for the package
and its path dependencies; build the `generated` targets and run `mopm record-generated` in `buildrules mojo sync`
and in `rules/mojo/sync.bzl` (the record among the action's outputs and in `committed`, the old record not an
input); teach `buildrules mojo check` and `//ci:lock_hashes` the generated entry; pin the mopm release; convert
`examples/mojo/generated` to a generator that is a build target. Tests: a format 7 fixture through sync, check and
the rules; the first conversion (a package whose `generated` entry its committed table lacks, and whose table
names a deleted file, loads, fails at `unit.bzl:112` and the validation, and builds after a sync); a missing and an extra `generated` entry; a stale record
through `check`; a changed output refused by the build; a package with a coverage floor and a generated source
through `:coverage`; `lock_hashes` on a generated entry; with a fake execer, that sync runs the generator build with
no local-execution flag (that the real farm build ran nothing locally is the summary line,
`Commands: N (cached: N, remote: N, local: 0)`, quoted in the pull request); the existing refusal of a format above
`newest_format`, for 8; format 6 fixtures unchanged.

**5. komira (komira-ai/komira): pin the new mopm and buildrules.** Bump `.buckconfig`'s buildrules commit, the
mopm version of every `src/*/mopm-toolchain.toml`, the mopm label of `release/readme_e2e/packages.bzl` and of each
`mojo_conda(mopm = ...)`, and run `buildrules mojo sync`. The bump spans every release between the pins: komira
pins mopm 0.0.138 and a buildrules commit 10 commits behind buildrules' main at this writing (mopm is at 0.0.149).
Tests: the existing build; the tables unchanged but the `MOPM` line, which is all the pull request holds unchanged.

**6. komira (komira-ai/komira): `plan_proto` builds from its generator.** Section 3, step 4; delete its census
`generated` lines; update its README and the `gen:regen` comment of its `BUCK`; rewrite the root files of the check
set. Tests: `plan_proto`'s tests and its dependents' builds;
the comparisons of section 4 for `plan_proto` (its output against the deleted directory, its record against the old
table, its `.conda` in both release sets); a changed `.proto` without a sync failing `buildrules mojo check` and the
build with the sync command; the darwin part of the check building `plan_proto` from the Linux output.

**7. komira (komira-ai/komira): the other eight proto packages build from their generators.** Section 3, step 5,
with the `generated` entries of `calendar`, `calendar_ics` and `supervisor_proto`; remove the macros' list; update
the eight READMEs and the `gen:regen` comments of their `BUCK` files; rewrite the root files of the check set. Tests: as for 6, for each package and for those three.

**8. komira (komira-ai/komira): remove what served committed generated sources.** Section 3, step 6, with every
file it names; the coverage gate refuses a committed `.mojo` whose line 1 is the generated header, except below the
one exempt directory of the `aws_codegen` goldens, and `generated_paths` and the census lines go; `mopm_migrate`'s
refusal moves to a manifest with `[generated]`; the macros' committed branches and the helpers of
`tools/build/gen/defs.bzl` go; rewrite the sections of `generated_sources.md` and update the documents section 3
gives to step 6. Tests: the gate's refusal, the
exemption held to that one directory, and that a file with the token elsewhere is measured; the two ledger negative
tests still red, built from their generator; `mopm_migrate`'s new case.
