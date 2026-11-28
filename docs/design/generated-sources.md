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
  alternative of section 5, in one). The lock
  is remade by `buildrules mojo sync`, which builds the generator and records its output. The build fails with that
  command when the record is stale, as komira's freshness gate does today.

## 1. mopm: the manifest, the record and the graph

### The manifest

```toml
[targets]
lib = { path = "generated/plan_proto" }

[generated.plan_proto]
generator = "protoc-gen-mojo 1"
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
      "generator": "protoc-gen-mojo 1",
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
  "generator": "protoc-gen-mojo 1",
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

- `source_sha256` (`src/core/source_digest.zig`) is computed by `mopm stage` (`src/cli/stage_cmd.zig:493`) and
  `mopm publish` (`src/cli/publish_cmd.zig:289`) from the package directory in the tree. For the generated files it
  takes the record: the line of each output is `<recorded sha256> <path>`, the line a file on disk with those bytes
  would give, so the digest is computed offline and equals the digest of the same bytes in the tree. A file in the
  tree below an `out` is refused, as `plan` refuses it. The manifest is hashed as today, so adding the table changes
  a package's digest once, like any edit of its sources. In komira the published versions' digest comes from the
  release's `mopm stage` job, which reads the tree; buildrules' `mojo_conda` stages no library directory
  (`rules/mojo/pack.bzl:37-87`, `workspace_tree`: "Nothing else of the package is staged"), so the packages it packs
  carry no digest today (`source_digest.zig:96-110`), and this does not change that.
- The commands that compile a package from the tree themselves (`mopm build`, `mopm test`) take
  `--generated <full name>/<id>=<dir>` for each table of the package and of its path dependencies, check every file
  of `<dir>` against the record as `mopm unit build` does (the same refusals), copy the library with the outputs at
  their recorded paths into a scratch tree under `.mopm/`, and compile that. Without the option they refuse such a
  package, naming the table and the option. A person without a build system runs the generator by hand and mopm
  checks the bytes; mopm still runs no generator.
- `mopm lock`, `add`, `remove`, `install` and `tree` parse the table (the manifest must parse), ignore it, and do not
  touch the record.

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
| komira | `tools/build/mopm_migrate` (`plan.zig:632`, `emit.zig:409` write `GRAPH` load lines) | nothing: it writes loads and parses no graph |

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
`newest_format` is refused holds it today, and brief 3 keeps that test for format 8.

## 2. buildrules

**A target's output as a source.** `mojo_package` takes `generated = {"<generate unit id>": "<target>"}`, the
target whose default output is the directory the generator writes, as it takes `natives` for a provided native
today. The key is the unit's full id, so two packages that use one table name never collide in a dependent. Each
`generate` unit of the package's graph, its own and its path dependencies', must have an entry and each entry a
unit; a dependent names the declaring package's alias. Unlike `check_provided_native` (`rules/mojo/defs.bzl:379`),
which fails when the package loads, this check is a validation of the build (with `:check`), so that a package whose
table does not yet have the unit still loads (the first conversion, below). It declares `generated_<id>`, an alias
of the target, for each entry the package's own tables name, and `generated`, a directory of every such output, both
from the attribute alone and not from the graph, which `sync` builds. Every action of a library unit will take the
directories as inputs and pass `--generated <generate id>=<dir>` to `mopm unit build`: the release compile, the
test, coverage and profile compiles of the same unit, the bitcode compile of the branch-coverage path
(`rules/mojo/unit.bzl:537`), and the coverage tree, which stages the library's sources for the line tables
(`_coverage_tree`, `unit.bzl:438`). The generated sources will not be in the unit's `srcs`: the check at
`unit.bzl:112` (`the graph names the source ... but the target's srcs do not include it`) will skip a source with
`generated`.

**The first conversion of a package.** One pull request adds the table, the `generated` entry and deletes the
directory; `buildrules mojo sync` then builds `generated` (declared from the attribute, so it exists although the
committed table has no `generate` unit), records, and plans, and the new table has the unit. Until the sync has run,
the package loads and its build fails the validation with the sync command. Adding, renaming or removing a table
later is the same order.

**One execution platform.** The generate action runs on Linux x86_64 whatever the target platform (komira's `_gen`
rules give their generator that execution platform, as buildrules runs `:check` and `:table` there), so one output
serves the Linux and macOS builds of a library, and the record is the same for every platform's graph. A macOS
compile checks that output's bytes like any other, so a generator that wrote other bytes on another host would be
refused, not compiled.

**The sync hashes an output it must first build.** `buildrules mojo sync` already builds a program before it plans:
the pinned mopm, with `buck2 build <label> --show-full-output` (`cli/src/mojo_cmd.zig:543-549`). It builds every
package's `generated` target the same way, in one `buck2 build`, runs `mopm record-generated <id>=<dir>...` in each
package that has generated sources, and then plans as today. So a sync of komira runs its generators on the farm, and
that build, like every farm build, reports `local: 0`.
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
(`golden/logs_pure_probe.mojo` begins `# @generated by aws-client-gen`). They are test data, not library sources,
and stay committed with their header; the coverage rule below names that directory as its one exemption.

**The order.**

1. The libraries komira builds itself stop being committed, at once: the four macros build from `<name>_gen`, and
   the 33 directories under `src/` and the 14 under `tools/build/` are deleted with their `<name>_fresh`. The
   `generated` lines of their `coverage_census.tsv` (in `aws_secretsmanager` and `gcp_secretmanager`) go with them.
   The macros keep building the nine mopm packages from their committed directory, by a list of the nine that is
   temporary: the pull request of step 4 removes it. The line of the generated header that names the regeneration
   command goes in this step too, so that the nine records of steps 3 and 4 are made once: it is spelled in three
   emitters, `tools/build/proto-codegen/src/header.rs:25`, `tools/build/cloud/aws_act.zig:39` and
   `tools/build/mojo/tools/proto_gen.zig:39` (held equal by `tools/build/gen:command_agreement`), and the nine
   committed directories are regenerated in the same pull request, with the 18 goldens.
2. When mopm and buildrules have released the generated source: komira pins them.
3. `plan_proto` first: its `[generated.plan_proto]`, its `mopm-generated.lock`, `mojo_package(generated = ...)`, its
   adopted library's `srcs` from the generator's output instead of `glob(["generated/plan_proto/**/*.mojo"])`,
   `mojo_conda`'s `dir` the package directory, `src/plan_proto` (buildrules resolves `members` such as
   `../proto_codec` against `dir`, `rules/mojo/pack.bzl:23-35`, so the empty default would fail with "leaves the
   repository"), and the directory deleted.
4. The other eight proto packages the same way. The three packages that plan one of them as a path dependency
   (`calendar` and `calendar_ics` plan `calendar_proto`, `supervisor_proto` plans `broker_proto`) gain the
   `generated` entry for it in their `mojo_package` and are synced in the same pull request; no mopm package plans
   `plan_proto`. The macros' list of nine goes.
5. What served committed sources is deleted: `tools/build/gen:regen`, `fresh.zig`, the `gen_fresh` rule,
   `transition.bzl` and its lint, `:command_agreement`, `tools/build/gen/*_test.zig`, the whole of
   `tools/build/tests/functional/gen_tools` (`fresh_driver_test.zig`, `regen_driver_test.zig`,
   `committed_data_test.zig`, `fake_buck2.zig`, its `BUCK` and its hand-written fixture), `tools/build/tests/negative/gen_commit`, and the uses in `tools/build/mojo/defs.bzl:396`
   (`fresh_gate`), `tools/build/mojo/readme.bzl:205` and `tools/build/tests/functional/mojo_gcp_client/defs.bzl`.
   The two negative tests of the ledger (`tests//negative/mojo_gcp_client:rest_reaches_plugin`,
   `tests//negative/proto:tasks_db_wrong_outs`) build from their generator, now the only way, and stay red as
   before. `tools/build/mopm_migrate` refuses a package with a `generated/` directory (`plan.zig:359`); with none
   left, the refusal and its case (`mopm_migrate_test.zig:857`) become a package whose manifest has `[generated]`.

**What replaces the freshness gate and `regen`.** For the libraries komira builds itself, nothing is needed: the
library is compiled from the generator's output, so there is nothing to be stale. For the nine mopm packages, the
compile of the library (section 1), and `buildrules mojo sync` in place of `regen`.

**Coverage.** A generated source that is not a committed file is not staged for the coverage gate
(`tools/build/coverage/README.md`, "Generated sources"), and generated files are not measured today, so no floor
moves. Once no committed library source is generated, the rule that sets aside a committed file whose line 1 is
`# @generated` only lets a hand-written file leave measurement by gaining the header; the last komira pull request
makes the gate refuse such a file instead, except below `tools/build/tests/functional/aws_codegen/golden/`, the one
directory named as exempt (the goldens above; a test holds the list to that one entry), and removes
`generated_paths` and the census's `generated` lines.

**`generated_sources.md`.** Its status becomes "decided: a generated-source input in the package graph (2026-11-28),
because generated code is not checked in", and its sections change so:

- the line limit: a generated file is no longer a file of the repository, but Mojo still hangs on very large files,
  so the generator keeps splitting a large module into `_parts/`;
- coverage: as above;
- third-party text: neither the botocore and googleapis inputs nor the text derived from them is committed; the
  `NOTICE` entry stays, because the build still compiles code derived from them;
- the transition ledger, the single-path rule and the size projection: removed, with the machinery they describe.

Its other mentions go with step 5: `tools/build/gen/README.md`, `tools/build/mojo/README.md` ("Committed generated
sources"), `tools/build/ns_rename/README.md` and `docs/design/object_store.md` (by `git grep` for `gen:regen`,
`gen_fresh` and `_fresh`).

**The root files of the check set.** Every pull request that adds or deletes a target (steps 1, 3 and 4: the
`<name>_fresh` targets, the generator aliases) rewrites `ci/roots/` and `ci/test_roots/` with the command in
`tools/build/ci/README.md` (`tools/build/ci/targets.bxl:generate`), which the guard names when they are out of date.

**Repositories that copy komira's toolchains.** A repository that copies komira's `toolchains/BUCK` changes its copy
in the same commit as komira's when step 2 moves the mopm pin.

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
  it passes the sources only to its load check), but no `sole` check guards it, so komira's pull requests show those
  `.conda` files unchanged, byte for byte.
- The generator's output is the same bytes before and after, so the `.mojoc` is too. A dependent's lock pins the
  `.conda` by sha256 and never needs the sources.

## 5. What the committed lock records: an open question

Not committing the generated files removes their 105 conflicts, but what the lock files record decides what still
conflicts. The design above takes the first way; the owner is choosing, and switching to the second is this
section's edit plus the changes it lists. The design of komira-ai/komira#2509 expects a member pull request to
change only the `.proto` and its claim; under either way that holds for the files a person edits, not for the lock
lines.

**First way (written above): the record holds every output's sha256.**
- Conflicts: two pull requests that change one `.proto` conflict in `mopm-generated.lock` (its input line and the
  changed outputs' lines) and in `buildrules.mojo.lock.bzl` (the same lines once per platform), as that file already
  conflicts for any hand-written source two pull requests both edit. The second pull request takes main's files and
  runs `buildrules mojo sync` on the farm.
- Reproducibility: the lock names every byte a build compiles; a generator that changes without a version bump, or
  writes other bytes on another host, is refused by the compile.
- The digest: `source_sha256` covers the output bytes, so two builds of one version for two Mojo compilers are known
  to compile the same generated code.
- mopm without a build system: `mopm build --generated` checks the bytes a person generated.

**Second way: the lock records nothing about the outputs.** A generated source is named by its generator's name and
version (in the manifest) and its inputs, which `plan` hashes offline from the tree; the build makes the bytes.
- What changes: no `mopm-generated.lock` and no `mopm record-generated`; the library unit lists its `generate` units
  (`"generated": ["generate:..."]`) instead of each output, and its key hashes their keys; `mopm unit build` and
  `mopm build` take every `.mojo` file of `<dir>` and check nothing against a hash; `buildrules mojo sync` builds no
  generator; in `source_sha256` the outputs' lines give way to the generator's text and the inputs' lines.
- Conflicts: only the input's line in the `generate` unit of `buildrules.mojo.lock.bzl`, once per platform, still
  conflicts when two pull requests change one `.proto`; the outputs no longer appear.
- Reproducibility: the lock no longer names the bytes compiled. komira's generators are built from the repository's
  own Rust source and change without a version bump, so the same graph and key can then stand for other bytes; the
  build system's own keys still rebuild what changed, but mopm's key does not move, and a generator that writes other
  bytes on another host goes unnoticed.
- The digest: `source_sha256` covers the generator's name and the inputs, not the code compiled, so a build added for
  another Mojo compiler can compile other generated code under the same digest.
- mopm without a build system: `mopm build --generated` accepts whatever a person generated.

## 6. The pull requests, in order

Each lands alone. The first two can start at once, in parallel.

1. **mopm: the generated source.** The manifest table, `mopm-generated.lock`, `mopm record-generated`, format 7,
   `--generated` for `unit build`, `build` and `test`, the digest from the record, the specs, and
   `//:compat_generated`. After it: mopm can plan and check a library built from uncommitted generator output;
   every other project is unchanged. Its merge releases mopm by itself (`RELEASING.md`: releases are automatic from
   main once every stage is green); nobody cuts it, and the release's version is the one pull request 3 pins.
2. **komira: komira's own generated libraries are not committed.** The 33 directories under `src/` and the 14 under
   `tools/build/` deleted, the four macros building from `<name>_gen`, and `generated_sources.md` rewritten to the
   decision with the nine mopm packages as what remains, and the header's regeneration line removed. After it: 47 of
   the 57 directories are gone; the nine proto packages are still committed and gated.
3. **buildrules: build a package with generated sources.** After mopm's release. Format 7, `generated` in
   `mojo_package`, the sync step, the checks, the new mopm pin, and `examples/mojo/generated` converted. After it:
   buildrules builds such a package; every other package is unchanged.
4. **komira: pin that mopm and buildrules.** After buildrules merges. After it: no behaviour changes; the tables
   name the new mopm.
5. **komira: `plan_proto` is not committed.** After it: a plan vocabulary pull request changes the `.proto` and lock
   lines only.
6. **komira: the other eight proto packages are not committed.** After it: no library source is committed.
7. **komira: remove the committed-source machinery.** After 2 and 6. After it: one way to build a generated
   library, and the coverage gate refuses a committed generated file outside the goldens' directory.

## 7. Briefs

**1. mopm (komira-ai/mopm): a library source generated by the build.** Add `[generated.<id>]` (`generator`, `inputs`,
`out`) to the manifest with the rules of section 1; the `mopm-generated.lock` format (`spec/`, with a JSON schema);
`mopm record-generated <id>=<dir>...`; in `plan`, read each member's record, exit 3 when it is stale and 4 when a
file lies below an `out`, and print `generate` units, `generated` sources and format 7 only when there is one;
`mopm unit build` and `unit test` read formats 6 and 7 and take `--generated`; `source_sha256` from the record in
`stage` and `publish`; `mopm build` and `test` take `--generated` and refuse such a package without it. Update `spec/unit-graph.md`, `spec/mopm-toml.md`, `spec/lock.md` (a
pointer) and the changelog. Tests: graph goldens for a package with a generated source alone, below hand-written
files, and as a path dependency; each stale case and the committed-copy refusal with its exact message; the record
command's refusals (symbolic link, a file that is not `.mojo`, a test-file name, empty directory, unknown id); `unit build` with a
changed byte, an extra file, a missing and an unused `--generated`; `mopm build` and `test` with the same four cases
and without the option; a path dependency whose library directory is an `out`; a format 6 graph read unchanged; the
digest equal to that of the same files on disk; `//:compat_generated` (the previous release's core readers on new
data, and these readers on the previous release's); `unit_cmd`'s format test for 7 and 8.

**2. komira (komira-ai/komira): stop committing the generated libraries komira builds itself.** Make the four
generating macros build from `<name>_gen` when a library is not one of the nine mopm packages (a list of the nine,
temporary: brief 6 removes it), with the generator on the Linux x86_64 execution platform; delete the 33 directories
under `src/` and the 14 generated ones under `tools/build/` (not the hand-written fixture of
`tools/build/tests/functional/gen_tools`, nor the 18 goldens of `aws_codegen`), their `<name>_fresh` targets and
their census `generated` lines; remove the regeneration line from the three header emitters and regenerate the nine
committed directories and the goldens with it; rewrite the root files of the check set
(`tools/build/ci/targets.bxl:generate`); rewrite `docs/design/generated_sources.md` as section 3 says. Tests: each
library's existing tests, now on the generator's output; the build of every deleted library's dependents; the
`.conda` of `gcp_cloudresourcemanager`, `gcp_iam` and `gcp_run` in the release's second set, byte for byte before
and after; the emitters' tests and goldens with the new header; a negative case that a committed directory beside a
library built from its generator is refused.

**3. buildrules (komira-ai/buildrules): build a mopm package that has generated sources.** Read format 7 in the CLI
(`mojo_lock.zig`, `graph_norm.zig`, `mojo_cmd.zig`) and the rules (`NEWEST_FORMAT`, `compile_format`,
`unit_slice`); `graph_norm.zig` drops a path dependency's `generate` unit's `srcs` and `key` and keeps the unit; add
`generated = {id: target}` to `mojo_package` with the checks both ways as a validation (not a load failure), the
`generated_<id>` and `generated` targets declared from the attribute, and `--generated` on every action of a `lib`
unit (release, test, coverage and profile compiles, the branch-coverage bitcode, the coverage tree); stage the
record for `:check` and `:table`, for the package and its path dependencies; build the `generated` targets and run `mopm record-generated`
in `buildrules mojo sync` and in `rules/mojo/sync.bzl` (the record among the action's outputs and in `committed`,
the old record not an input); teach `buildrules mojo check` and `//ci:lock_hashes` the generated entry; pin the mopm
release; convert `examples/mojo/generated` to a generator that is a build target. Tests: a format 7 fixture through
sync, check and the rules; the first conversion (a package whose `generated` entry its committed table lacks loads,
fails the validation with the sync command, and builds after a sync); a missing and an extra `generated` entry; a
stale record through `check`; a changed output refused by the build; a package with a coverage floor and a generated
source through `:coverage`; `lock_hashes` on a generated entry; the sync's farm build reporting `local: 0`; the
existing refusal of a format above `newest_format`, for 8; format 6 fixtures unchanged.

**4. komira (komira-ai/komira): pin the new mopm and buildrules.** Bump `.buckconfig`'s buildrules commit, the
mopm version of every `src/*/mopm-toolchain.toml`, the mopm label of `release/readme_e2e/packages.bzl` and of each
`mojo_conda(mopm = ...)`, and run `buildrules mojo sync`; a repository that copies komira's `toolchains/BUCK`
follows in the same commit. Tests: the existing build; no graph changes but the `MOPM` line.

**5. komira (komira-ai/komira): `plan_proto` builds from its generator.** Section 3, step 3, in the order of "The
first conversion" (section 2); delete its census `generated` lines; rewrite the root files of the check set. Tests:
`plan_proto`'s tests and its dependents' builds; the `.mojoc` digest, and the `.conda` of both release sets, equal
before and after; a changed `.proto` without a sync failing `buildrules mojo check` and the build with the sync
command; the darwin part of the check building `plan_proto` from the Linux output.

**6. komira (komira-ai/komira): the other eight proto packages build from their generators.** Section 3, step 4,
with the `generated` entries of `calendar`, `calendar_ics` and `supervisor_proto`; remove the macros' list of nine;
rewrite the root files of the check set. Tests: as for 5, for each package and for those three.

**7. komira (komira-ai/komira): remove what served committed generated sources.** Section 3, step 5, with every
file it names; the coverage gate refuses a committed `.mojo` whose line 1 is the generated header, except below the
one exempt directory of the `aws_codegen` goldens, and `generated_paths` and the census lines go; `mopm_migrate`'s
refusal moves to a manifest with `[generated]`; update the documents section 3 names. Tests: the gate's refusal, the
exemption held to that one directory, and that a file with the token elsewhere is measured; the two ledger negative
tests still red, built from their generator; `mopm_migrate`'s new case.
