# mopm.dev v2: appendix

The detail behind [mopm-dev.md](mopm-dev.md). Section letters: A search, B API reference, C login, D test plan, E
agents. Anything marked **unverified** has not been checked against code, docs or a run; Tantivy facts were read from
the tantivy 0.26.2 source and its crates.io metadata (index format 7, `rust-version = "1.86"`, below the 1.99.0 that
komira's Rust rules now pin and above the 1.85.0 at mopm's current komira pin, which PR V0 moves), nothing was
built or run, and every size and timing is an estimate. `spec/search-api.md` and `spec/mopm-api.md` (PR 6)
become the normative copies of E.1, E.2 and B.2.

## A. Search

### A.1 Schema and tokenizer

Two Tantivy indexes, `pkg` and `sym`, with separate schemas, committed together and named by one manifest. One index
holding both kinds would make `Searcher::total_num_docs` (which BM25's average field length divides by) count symbol
documents that have no package text, so every package field would look long and any package's symbol count would move
other packages' scores.

**`pkg` index**, one document per package:

| field | source | Tantivy options | cap |
|---|---|---|---|
| `pkg` | package name | raw, indexed, stored (the `delete_term` key) | 64 chars |
| `name` | package name, lowercased | raw, indexed: exact and fuzzy matching | 64 chars |
| `name_len` | its length in characters | u64, fast (group 1 order) | |
| `name_prefix` | package name | edge n-grams 2 to 64 (`NgramTokenizer::prefix_only`) | |
| `name_parts` | the name's `_` parts | `mopm_ident`, freqs | |
| `summary` | latest's `description` | `mopm_ident`, positions, stored | 512 chars |
| `keywords` | latest's `keywords` | `mopm_ident`, freqs | 10 x 32 |
| `symbols` | symbol names from latest's `mopm-api.json`: top-level symbols first, then members, distinct | `mopm_ident`, basic (no term frequency) | 500 names |
| `readme` | latest's README, Markdown stripped | `mopm_text`, positions, not stored | 64 KiB |
| `readme_snip` | the first 8 KiB of the same text | `mopm_text`, positions, stored (snippets) | 8 KiB |
| `summary_stem`, `keywords_stem`, `readme_stem` | the same text | `mopm_stem`, freqs | as above |
| `state` | `ok` or `all_yanked` | raw, indexed, fast | |
| `published_at`, `first_published_at` | version records | date, fast, stored | |
| `downloads_30d` | 0 until PR 20 (Q5) | u64, fast | |
| `display` | latest version, version count, lines (newest 3 and total), `mojo_versions`, `(version, requires_mojo, platforms)` for the newest 256 published versions, licence (SPDX-checked), repository, owners (3 plus count), provenance, native dependency count, symbol count, `has_api` | stored JSON only | 16 KiB |

A README match beyond the first 8 KiB ranks but returns no snippet. The summary comes from the highest published
version, not `PackageRecord.description`: nothing in production calls `createPackage`, so that field carries no
maintained text.

**`sym` index**, up to 2,000 documents per package: `pkg` (raw, indexed, the delete key), `sym_id` (raw and
`mopm_ident`), `sym_summary` (`mopm_ident`), and stored only: `kind`, `signature` (4 KiB), `inits` (a struct's first two
`__init__` signatures), `import`.

**Tokenizers** (one implementation each, in `mopm-search`, registered on both writer and reader):

- `mopm_ident`: Unicode NFKC; split on anything outside letters, digits and `_`; split each token on `_` and on
  camelCase boundaries (detected before lowercasing); emit the whole token and its parts, lowercased; drop terms shorter
  than 2 or longer than 32 characters. Identifiers are never stemmed.
- `mopm_text`: `mopm_ident` plus about 30 English stopwords, for the README.
- `mopm_stem`: `mopm_text` plus Tantivy's English `Stemmer` (pure Rust), for the `_stem` fields only.

The README is stripped by a Markdown module in the crate. Because Tantivy's schema check compares tokenizer names only,
the crate's tests pin each tokenizer's output on a fixed corpus; any change is a reindex (A.2), never a silent drift.

### A.2 Storage and the writer's loop

```
search/v1/manifest.json                     # mutable; see below
search/v1/<index>/meta/<generation>.json    # Tantivy's meta.json, per index (pkg, sym)
search/v1/<index>/files/<segment file>      # immutable segment files
```

- **Manifest**: `{format, generation, committed_at, tantivy, schema_hash, indexes: {pkg: {meta_key, files: [{name,
  sha256, size}]}, sym: {...}}}`. The bucket has versioning off, so a deleted file leaves no noncurrent copy.
- **Batch** (FIFO `search` queue, one group, batch size up to 10, an explicit exception to the `BatchSize === 1`
  assertion; the single group serialises batches, no reserved concurrency): read the manifest and its ETag; download each listed file missing from `/tmp` to
  `<name>.part`, check size and sha256, rename; size-check files already present; write each `meta.json`; open each
  index with `writer_with_num_threads(1, 50_000_000)` (the thread count pinned, since a bigger Lambda has more vCPUs and
  the default would split the heap below Tantivy's per-thread floor); for each distinct package, read its version
  records and latest's served `mopm-api.json`, then `delete_term(pkg)` in both indexes and add the package document and
  its symbol documents (or nothing, when no version is published); `commit`; `wait_merging_threads()`; read each
  `meta.json` again (merges rewrite it) and upload the files it names that the store lacks; put the `meta` objects; put
  the manifest with `If-Match: <ETag>`. A failed conditional put means a second writer ran: the batch fails and SQS
  redelivers it.
- **Failure isolation**: a package whose derivation fails (bad stored data, a missing served file, a panic caught at
  the package boundary) is logged, left out and sent back to the queue as its own message with a retry count; the rest
  of the batch commits. `maxReceiveCount` 5, then a dead-letter queue with redrive; an alarm on the age of the oldest
  message. Visibility timeout at least 6 times the function timeout; the function timeout covers a cold download plus a
  forced merge at the largest catalogue PR 9 measures.
- **Merging**: Tantivy's `LogMergePolicy`, with `set_del_docs_ratio_before_merge` so deleted documents leave the BM25
  statistics within a few merges. `IndexWriter::merge` is forced only after a takedown (of the segments that held the
  package) or above 40 segments; a rule of "more than 10" would fire every few batches, since the policy keeps about 8
  segments per level, and each fire rewrites the whole index that every query instance then downloads.
- **Retention**: files referenced by the last three generations and any written in the last 10 minutes are kept; the
  rest are deleted by the writer. After a takedown, every file not in the live generation is deleted at once. S3
  lifecycle expiry is not used (it counts from creation, so a quiet week would delete live files).
- **Reindex**: a schema or tokenizer change bumps `format` and `schema_hash`; the writer builds both indexes from every
  package's records under a new prefix (`search/v<n+1>/`) and then switches the manifest. Publishes during the build go
  to the queue and are applied to the new prefix after the switch (the writer replays messages received since the
  build began). The same path rebuilds after a lost index.
- **Deploy order**: a Tantivy upgrade deploys the query function first (index formats are readable only backwards); a
  reindex deploys the writer first, building `v<n+1>` while the query function still reads `v<n>`, then the query
  function that reads `v<n+1>`.
- **Senders and dedup ids**: the validator's `sendIndex` on both passes (`<publish_id>:search`), `setYanked` (with
  the record's `rev`), and the takedown function.
- **Grants**: the writer reads the version and package tables, the owners index and served API files, and writes
  `search/*`; the query function reads `search/*` and, for package lookups, the version table.

### A.3 Size and cost

Assumptions: about 400 unique terms per package; positions on summary and README; up to 8 KiB of README stored (lz4);
stemmed copies add about a third to the package index; about 150 B per symbol document.

| packages | `pkg` index | `sym` index (50 symbols each) | cold start (sequential download at about 80 MB/s, plus 100 ms init) |
|---|---|---|---|
| 1,000 | 3 to 9 MB | 7.5 MB | about 0.3 s |
| 10,000 | 25 to 90 MB | 75 MB | about 1.5 to 2 s |
| 100,000 | 250 to 900 MB | 750 MB | 10 s or more: move to EFS or a provisioned instance |

- **Writer**: a batch costs a few S3 GETs for the manifest, the new segment files (KB to a few MB), and DynamoDB reads
  for the affected packages only. Indexing one package with its symbols is well under 10 ms (about $0.33 per million
  publishes at 2 GB); S3 and commit time dominate. A cold writer downloads both indexes once.
- **Query**: a warm query over 10,000 packages is a few ms of CPU (estimate); cold cost is the download above.
  Parallel ranged GETs would shorten it; not measured. Lambdas are x86_64 (komira's Rust toolchain has no arm64
  target), at x86_64 prices. One provisioned instance costs a fixed monthly amount and is not planned until logs show
  cold starts (Q9).
- PR 9's synthetic catalogue (1,000, 10,000 and 100,000 packages), a separate bench target outside the welded tests,
  measures index bytes; PR 13 reports batch time on remote execution as a relative figure (it does not measure Lambda)
  and full rewrites per day at a given publish rate. Measuring the deployed writer needs the CEO's go.

### A.4 Ranking

For a query: normalise (`[-._ ]+` to `_`, lowercase) for groups 0 to 2; tokenize with `mopm_ident` for groups 3 to 6,
dropping `mojo`, `package`, `library` and `lib` when other terms remain; at most 16 terms and 256 bytes, longer input is
cut and the response says so. All queries run on the `pkg` index.

| group | Tantivy query |
|---|---|
| 0 | `TermQuery(name, q)` |
| 1 | `TermQuery(name_prefix, q)` for 2 to 64 characters |
| 2 | `FuzzyTermQuery::new(name, q, k, true)`, `k` = 0, 1 or 2 by length; up to 1,000 hits, then first-character check and the true distance computed in code (the query scores every hit 1.0) |
| 3 | `BooleanQuery::with_minimum_required_clauses` over one clause per term (all terms when 1 or 2, else all but one); each clause is SHOULD over `name_parts^10`, `keywords^5`, `summary^3`, `keywords_stem^3.5`, `summary_stem^2.1` |
| 4 | the same with `symbols^2` added |
| 5 | the same with `readme^1` and `readme_stem^0.7` added |
| 6 | SHOULD over every term and field, only when 3 to 5 return nothing |

- Every group except 0 and 1 is restricted to `state:ok` (a filter clause, no score). A package keeps its best group.
  Groups 4 and 5 hold only packages not already in 3 or 4.
- **Last term**: when it has 3 or more characters, up to 20 completions from the term dictionary of each field (by
  document frequency, then byte order) join it as SHOULD alternatives with boost 0.7; the exact term keeps 1.0.
- **Symbol stuffing**: `symbols` is indexed without term frequency, holds at most 500 distinct names, and its field
  norm grows with the list, so listing many names lowers each one's score; group 4 always ranks below group 3.
- **Static boost** through `tweak_score`: `score * (1 + 0.15 * log10(1 + downloads_30d)) * (1 + 0.10 *
  exp(-age_days / 180))`, `age_days` from `published_at` to the generation's commit time (stored in the manifest), so
  no reader clock enters.
- **Order**: group ascending; group 1 by `name_len` then the boost, through `tweak_score` with a tuple key before the
  200 cut, so the shortest names are never cut; group 2 by distance, then the boost; groups 3 to 6 by boosted score;
  then name. The key is a tuple, so the order is total; float arithmetic runs in one binary over one generation.
- **Symbols per result**: one query on the `sym` index restricted to the page's packages (a `pkg` term set), the query
  terms over `sym_id` and `sym_summary`; up to three per package by score, then id.
- **Snippets**: `SnippetGenerator` over `summary` and `readme_snip`, 200 characters, highlight ranges returned as UTF-8
  byte offsets into the plain text, never HTML.
- **Cursor**: `base64url(generation, offset, HMAC-SHA256 of both under a stage key)`; the offset is clamped to 200. A
  forged cursor gets `invalid_request`; a cursor naming the previous generation (kept open 5 minutes) still pages; one
  naming a newer generation makes the instance refresh the manifest first; anything older gets `cursor_stale`.

### A.5 Serving

- The query function keeps the opened `Searcher` per index per generation in memory, checks the manifest ETag at most
  every 30 s, downloads only files it lacks (to `.part`, size and sha256 checked against the manifest, renamed), opens
  the new generation before dropping the old, keeps the previous one for 5 minutes, and then deletes files in `/tmp` no
  open generation names (Tantivy's garbage collection never sees files copied in from outside).
- Responses: search, `latest` and ranges `Cache-Control: public, max-age=30` (no `stale-while-revalidate`, so the edge
  never serves past 30 s); exact-version `public, max-age=3600` with an `ETag`; `ETag` for search = generation plus a
  hash of the normalised query. The takedown function invalidates the paths in mopm-dev.md 1.6.
- Throttling at API Gateway per route; 429 with `Retry-After`. A missing or empty `User-Agent` is allowed but logged.
- Memory and `/tmp`: 2 GB and 2 GB ephemeral storage until 10,000 packages (estimate; PR 14 sets them from PR 9's
  catalogue). The swap needs room for two generations.

### A.6 Alternatives rejected

| alternative | why not |
|---|---|
| The publisher builds a Tantivy segment; the registry merges it | Saves about 10 ms per publish. Untrusted binary into readers with no fuzzing of segment formats and many `unwrap`/`panic!` sites; CRC32 only; crafted field norms, term frequencies and token totals skew index-wide BM25 and survive merges (`merger.rs` copies field norms, sums token totals); the schema check compares tokenizer names only; index format readable only backwards, so old CLIs pin the server; `add_segment`, `merge_indices` and `merge_filtered_segments` are `#[doc(hidden)]` and the merge functions rewrite the whole index; the Zig CLI would embed Rust per platform; verifying a segment is a rebuild plus a diff |
| The publisher uploads a search document; the registry indexes it as sent | A second copy of facts the registry already derives from metadata, README and `mopm-api.json`; it would need to be checked equal to that derivation, which is the derivation |
| One index holding package and symbol documents | BM25's average field length counts every document, so symbol documents distort package scores and let one package's symbol count shift others (A.1) |
| A forced full merge whenever there are more than 10 segments | `LogMergePolicy` routinely keeps more, so it would rewrite the whole index every few batches (A.2) |
| The first draft's static index sharded by term, ranked in the browser | Superseded by the CEO's decision (Q1); it capped out near 20,000 packages and needed the ranking twice |
| A full rebuild per writer batch | Every query instance would re-download the whole index after every publish |
| EFS for the index | A VPC, NFS latency on cold data; reconsider past about 100,000 packages |
| Container-image Lambdas | About 1 s cold starts reported (Quickwit's measurements), against ZIP |
| A hosted search service (OpenSearch, Algolia, Typesense) | Servers or a third party to run and pay for; results differ per stage unless each has one |
| A separate search stack outside the API's Rust service | A second deployment, auth and error model; the CEO placed search in the API's service |
| Exposing Tantivy's `QueryParser` syntax | No nesting-depth guard in its grammar; regexes and field syntax are surface we do not need |
| Embeddings supplied by the publisher | Unverifiable, like a segment; if semantic search comes, the registry computes vectors |

### A.7 Versions survey

Read from each registry's live API, docs or open source code.

| registry | search result | default version | when everything is withdrawn |
|---|---|---|---|
| crates.io | one row; `default_version`, `max_stable_version`, `newest_version`, `num_versions` (serde: 316) | highest stable not yanked, then highest not yanked, then highest | kept; `include_yanked` defaults to yes |
| docs.rs | per crate; version-pinned pages with an "outdated version" banner; URLs accept requirements (`~2`, `latest`) | latest non-yanked non-prerelease, else latest prerelease | none |
| npm | one object per package, one `version` | the latest (dist-tag source **unverified**) | deprecating a package removes it from website search |
| PyPI | no search API; indexes one document per project | highest non-yanked release with files, stable first | not indexed |
| pkg.go.dev | grouped by module, "Other major versions: v2 v1" | highest release, then prerelease, then pseudo-version; retracted hidden | |
| Maven Central | one per artifact, `latestVersion`, `versionCount`; per-version mode on request | most recent | |
| hex.pm | one per package, `latest_version`, `latest_stable_version`, retirements | latest | retired versions warn; docs built on the publisher's machine |
| JSR | Algolia indexes for packages, symbols (latest version) and docs; in-package search in the browser | highest non-prerelease non-yanked; no fallback | skipped |
| NuGet | grouped by package ID, metadata from the latest, `versions` array | latest | unlisted packages never appear |
| Packagist | one row, no version | | `abandoned` flag in another endpoint |

Pitfall (crates.io): the searchable text lives on the crate row and every publish rewrites it, so publishing a
backport replaces the description; mopm derives the document from the highest published version.

**mopm's package page with about 100 versions**: header shows the latest; the side panel the five newest; the
Versions tab groups by line (major, or `0.y`), highest patch first, older patches collapsed; yanked versions struck
through with the reason and still linked; tombstoned versions as text; the versions API paginated (20 per page). A
page for an older version shows "You are viewing an outdated version; the latest is X", and when the shown line is
older, names the newest line. A 0.x package with 99 lines still shows three in a search result (`lines_total: 99`).

## B. API reference

### B.1 What `mojo doc` emits

Known from real 1.0.0 output (komira's `tools/build/examples/hellopkg_doc.json`, the golden of its `mojo_doc_json`
rule, which runs `mojo doc -I<dir of each dep .mojoc> <library source dir> -o <out>` and exits non-zero when the
source does not compile):

- one JSON document for a directory: `{decl: {kind: "package", name, summary, description, modules[], packages[]},
  version}`; modules hold `aliases`, `functions`, `structs`, `traits`;
- an overload has `args`, `async`, `constraints`, `deprecated`, `description`, `hasDefaultImplementation`,
  `isImplicitConversion`, `isStabilityTracked`, `isStable`, `isStatic`, `kind`, `name`, `parameters`, `raises`,
  `raisesDoc`, `returns: {type}`, `signature`, `sinceVersion`, `summary`;
- the compiler parses the docstring's first sentence and its `Args:`, `Parameters:`, `Returns:`, `Raises:` and
  `Constraints:` sections; `Examples:` and fenced code stay Markdown in `description`;
- structs and traits carry `parentTraits[].path`; there are no source locations and no record of re-exports.

**Unverified**, settled by PR 7's golden (which must have non-empty `args` and a struct with `__init__`): which
underscore names the compiler emits (the golden has no struct, so whether `__init__` and other dunders appear is
unknown; if the compiler drops them the converter cannot recover them and `omitted.private` counts only names the
converter saw); argument and parameter field names; decorators; the struct-field shape; whether empty values are
omitted; declaration order; whether output embeds absolute paths or depends on `--docs-base-path`; whether an
installed `.mojoc` of the package on `-I` shadows the sources; whether dependency compile-time code runs; the
compiler's `conda-meta` file name; whether `mojo doc` works on a `.mojoc`; run time on large packages.

### B.2 `mopm-api.json`, schema version 1

Published at `https://mopm.dev/schema/mopm-api-1.json` (JSON Schema, current draft), `additionalProperties: false`
everywhere. `$schema` must equal that URL exactly; validators embed the compiled schemas and never fetch a `$ref`.

```
{ "$schema": "https://mopm.dev/schema/mopm-api-1.json", "schema_version": 1,
  "package": "http_client", "version": "0.4.0",
  "generator": { "name": "mopm", "version": "0.0.2", "source": "mojo-doc", "source_version": "1.0.0" },
  "modules": [Module], "symbols": [Symbol], "omitted": { "non_identifier_names": 0, "private": 12 } }

Module   { id, doc: Doc, members: [symbol id] }                       # top-level symbols only
Symbol   { id, kind: "struct"|"trait"|"function"|"alias", name, parent?, doc: Doc,
           deprecated?: {message}, flags?: [Flag], ...by kind }
  struct   parameters: [Param], traits: [TypeRef], fields: [{name, type: TypeRef, doc: Doc}], members: [id]
  trait    parents: [TypeRef], members: [id]
  function overloads: [Overload]
  alias    type?: TypeRef, value?: string, parameters?: [Param]
Overload { key, signature, parameters: [Param], args: [Arg], returns?: {type: TypeRef, doc}, raises: bool,
           raises_doc?, constraints?, doc: Doc, deprecated?, flags? }
Arg      { name, type: TypeRef, convention?: "read"|"mut"|"var"|"ref"|..., kind?: "positional"|"positional_only"|
           "keyword_only"|"variadic"|"variadic_keyword", default?: string, doc? }
Param    Arg plus infer_only?: bool
TypeRef  { text, ref?: id }                                           # ref covers the head type only
Doc      { summary, body?: markdown, examples?: [{title?, lang, code, output?}], sections?: [{title, body}] }
Flag     "static"|"async"|"implicit_conversion"|"has_default_impl"|"stable"|"stability_tracked"
```

- **Ids**: a dotted import path `<package>(.<component>)*`, each component `[A-Za-z_][A-Za-z0-9_]*`, at most 128
  characters. The `__init__` module's id is the package; a member is `http_client.client.Client.send`. An overload key
  is `<symbol id>#<first 12 hex of sha256(signature with whitespace runs collapsed)>`, the identity for "since" and the
  page anchor. A type `ref` names its package in its first component: this package, a declared dependency or `std`.
- **Doc**: `body` is Markdown with parsed sections removed; fenced blocks under `Examples:` become `examples`, and a
  block followed by an `output` block becomes `output`; other `Heading:` sections become `sections`; `%#` setup lines
  are kept verbatim. The package-level `doc.examples[0]` (module `__init__`) is the package's `example` for agents;
  without one, the first fenced Mojo block of the README.
- **Forbidden in the publish form** (the registry adds them to the served form): `since`, `supplied_by`, signature
  tokens, `import`, `refs_resolved`.
- **Canonical bytes**: keys sorted, UTF-8, `\n`, no timestamps, no paths; modules sorted by id; symbols and overloads in
  `mojo doc`'s order.
- **Untrusted, all of it**: every string in the file, signatures, type text, defaults, alias values, constraints and
  section titles included, is publisher text (E.3).

**Mapping from `mojo doc` 1.0.0**: `decl` and nested `packages[]` give ids (depth at most 8); `modules[]` give `Module`
(`__init__` is the package overview); `summary`/`description` give `doc.summary` plus `body`, `examples` and
`sections`; `args[]`/`parameters[]` give `Arg`/`Param` (field names **unverified**); `returns.type`, `raises`,
`raisesDoc`, `constraints`, `deprecated` (`""` is absent) map by name; `async`, `isStatic`, `isImplicitConversion`,
`hasDefaultImplementation`, `isStable`, `isStabilityTracked` become `flags`; `parentTraits[].path` becomes
`traits`/`parents` with `ref`; `sinceVersion` is dropped; struct dunders the compiler emits are kept; other names
starting with `_` and backtick names are left out and counted in `omitted`. A later schema version can add `reexports`
for tools that know them.

### B.3 Publish steps, validation and caps

**CLI steps** (inside `prepare()` in `src/cli/publish_cmd.zig`, for `pack` and `publish`, before the token is read;
`publish --dry-run` shows the result):

1. `--api-json <path>` or `[docs] api = "<path>"`: use the file as is (step 5), after checking that its real path
   stays inside the package root; errors never echo file content. Otherwise `[targets].lib.path` relative to
   `mopm.toml`; no `lib` target means no docs, with a note. `[docs]` is new to the manifest parser (`onlyKeys` in
   `src/core/manifest.zig` refuses unknown tables today) and to `spec/mopm-toml.md`.
2. The environment through `autolink.prepare` (`--prefix`, then `CONDA_PREFIX`, then `MODULAR_HOME`); `pack` and
   `publish` gain `--prefix` in `parseFlags`/`takesValue`. The compiler version, read from the environment's
   `conda-meta` record of `mojo-compiler` (file name **unverified**), must equal `--compiler`.
3. A fresh `mkdtemp` directory, mode 0700, holding an include directory with links to every installed dependency
   `.mojoc` in the closure (leaving out `<name>.mojoc`) and the output file; nothing in it is followed as a symlink
   when read back.
4. `<prefix>/bin/mojo doc -I <tmp>/inc <libdir> -o <tmp>/raw.json` through `test_proc` (own process group, 300 s
   deadline, 4 GiB cap, SIGKILL on expiry), working directory `<tmp>`, stdin `/dev/null`, and an environment built from
   an allowlist, not inherited: `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_*`, and `MODULAR_HOME=<prefix>/share/max`. No
   `MOPM_*`, `ACTIONS_ID_TOKEN_*`, `*_TOKEN`, `*_SECRET` or cloud credential variable reaches it. The last 40 lines of
   stderr kept.
5. Read at most 16 MiB; convert; check caps, id grammar and character rules on decoded strings; refuse duplicate keys
   and lone surrogate escapes; refuse any string containing the source directory, the prefix, `$HOME`, the temporary
   directory or any of their real paths, and warn on any other absolute-path-shaped string (`/home/`, `/Users/`,
   `C:\`). The CLI does conversion, caps, grammar and paths; JSON Schema validation is the registry's, and `mopm doc
   --check` matches the registry on the shared vectors, not in general.
6. Pack the same bytes at `lib/mojo/<name>.mopm-api.json` in every subdir.

**Failure policy** (flag beats manifest beats default):

| case | `auto` (default) | `require` | `off` |
|---|---|---|---|
| no environment, no `mojo`, compiler mismatch | warning, no docs | refuse | not run |
| `mojo doc` fails, times out or is killed | warning with stderr tail, no docs | refuse | not run |
| over a cap, conversion or validation fails | warning naming the rule, no docs; never truncated | refuse | not run |
| `--api-json` or `[docs] api` file invalid or outside the package | refuse | refuse | not run |

**Caps** (checked by the CLI and again by the registry):

| limit | value |
|---|---|
| `mopm-api.json` | 4 MiB (archives store zstd raw blocks, so four subdirs cost at most 16 MiB of the 100 MB package limit) |
| served form | 8 MiB; over it, the registry refuses the publish with `api_doc_too_large` and the publisher republishes with fewer symbols or `--docs off` |
| symbols plus overloads | 5,000 |
| docstring per symbol | 32 KiB |
| signature or type text | 4 KiB |
| overloads per function | 256 |
| arguments or parameters per overload | 64 |
| examples per symbol | 32 |
| subpackage depth | 8 |
| JSON nesting | 32 |
| identifier component | 128 characters |

**Registry validation** (`mopm-apidoc` in the validator, before `updateVersion`): JSON Schema for the declared
`schema_version` (unknown: `api_doc_unsupported_version`); `package` and `version` equal the publish; ids unique and
grammatical, so `..`, `/`, `%2e%2e`, a backslash or a bidi control cannot reach a storage key, route or link; every
`parent`, `members` entry and module member exists; every `ref` names an existing id in this package, a declared
dependency or `std`; overload keys equal the recomputed hash; no forbidden field; the caps. Character rules apply to
decoded strings (so `\u0000` counts as a C0 control): no C0 or C1 control except tab and newline, no lone surrogate
(the parser is configured to refuse it, not replace it), no duplicate object key (refused by the Rust parser, the Zig
CLI and the site's reader alike, so none of them sees different content); bidi controls are allowed in docs and shown
as markers. Each subdir's archive may carry its own file; the validator stores each distinct one once by sha256 and
records which subdirs have which.

### B.4 Served form, links and paths

The validator writes one served file per version (`apidoc/v1/<name>/<version>/api.json`, private, create-only, at most
8 MiB) before the version is published; a retry never rewrites it. It adds, per symbol and overload: `since` (B.5),
`import` (`from <defining module id> import <Name>`; with no re-export data the defining module is the only path
known to exist), signature tokens `{k: "kw"|"name"|"type"|"punct"|"text", s, ref?}`, and `supplied_by: "publisher"` at
the top.

A type token gets a `ref` only when it resolves exactly: the `ref` the file gave for the head type; else the package's
own symbol table by simple name when unique; else the name-to-id map of every `ref` in the file. A `ref` in the package
links within the version; one in a declared dependency links to that package's latest reference at the same id,
falling back to its module page; `std` stays text with the id in a `title`; anything else stays text.

The API serves the whole file, one module or one symbol from it, and Markdown rendered from it by a versioned renderer
(E.3 rules). Every URL and key is built from grammar-checked components by builders in `src/routes.ts` and their Rust
twin, applying `encodeURIComponent` per component; no URL comes from the JSON.

Rendering rules: every docstring-derived field goes through the restricted Markdown renderer or is plain text; raw
HTML in a docstring is never passed through; signature tokens and example info strings are text; symbol anchors come
from a typed builder (`s-` plus the id) and each rendered docstring gets its own heading-id prefix (`d<n>-`), so a
heading never equals a symbol anchor. The tags new to the `Doc` allowlist (`details`, `summary`, `select`, `option`,
`dialog`, `data-copy-target`) are for the renderer's own chrome only (the members table, the version switcher, the
shortcuts dialog), never produced from docstring Markdown, each with a test.

### B.5 "Since" markers

Computed at publish against the served file of the **greatest earlier version** (published or yanked, not
tombstoned): a symbol id or overload key absent there gets `since` = this version; one present inherits its marker; if
that version has no reference, `since` is unset. A version published out of order (1.2.5 after 2.0.0) compares with
1.2.4. Fixed at publish; `mojo doc`'s `sinceVersion` is ignored. The validate queue is grouped per package, so markers
are computed in order.

## C. Web login

### C.1 Endpoints, callback and plumbing

All under `/api/v1`, added to `spec/api/openapi.yaml` (additively), to `AUTH_ROUTES` (`api-stack.ts`) and to
`routeAuth` (`auth-routes.ts`).

| endpoint | does |
|---|---|
| `GET /auth/web/start?return_to=` | checks `Sec-Fetch-*` and `return_to`; stores the login row; sets the login cookie; 302 to GitHub (below) |
| `GET /auth/web/callback?code&state` | the steps below; 303 to the site |
| `POST /auth/web/logout` | revokes this session, clears the cookie, 204 |
| `GET /me` | implements the spec's `getMe` (not implemented today); adds `csrf`, `fresh_until`, `expires_at` |
| `GET /me/sessions`, `DELETE /me/sessions/{id}` | list and revoke `session` tokens (browser and CLI) |
| `POST /me/sessions/revoke-all` | sets `sessions_not_before` on the user row to now; needs a session, not a fresh one; never touches API tokens |
| `GET /me/invitations`, `POST /me/invitations/{id}/accept` | implements the spec (needs PR 4c's invitee index and `inviteOwner`) |
| `/me/tokens` (existing) | also accepts the cookie; list needs a session, create and revoke a fresh one; each token records how it was created |

`GET /auth/web/start?return_to=`:

- Refused unless `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` and `Sec-Fetch-Site` is `none` or
  `same-origin`, so another site cannot start a login (or force a re-login that revokes the victim's session).
  Rate-limited per IP.
- `return_to` is checked here and stored server-side, never in `state`: it must start with `/` but not `//` or `/\`,
  have no control characters or backslashes, be at most 256 characters, decoded once, and match the site's route
  grammar; otherwise `/account`.
- Stores `{id: sha256(txn), state_hash, code_verifier, return_to, expires_at: now + 600 s}` in a `web_logins` table
  (TTL on `expires_at`), sets `__Host-mopm_login=<txn>` (same attributes as the session cookie, `Max-Age=600`), and
  answers 302 to GitHub's authorize URL with `scope=read:user`, a 256-bit `state`, an S256 `code_challenge`, the exact
  `redirect_uri` from the stage setting, and `prompt=select_account`, which GitHub documents as forcing the account
  picker.

`GET /auth/web/callback?code&state`, in order:

1. Require the login cookie; consume its row atomically (an update that sets `consumed_at` and removes the verifier,
   conditioned on `attribute_not_exists(consumed_at)`). Today's device-login consume is conditioned only on
   `attribute_exists(id)`, which is not single-use.
2. Compare the state hash in constant time; check expiry.
3. Exchange the code with `client_secret`, `code_verifier` and the same `redirect_uri`, `Accept: application/json`.
4. `GET /user`; apply the existing two-factor rule (on by default, fails closed); upsert the user; discard the GitHub
   token.
5. Mint a session token (`kind: 'session'`, name `web login`, `fresh_until` now + 15 minutes, 7 days absolute).
6. Revoke the session the incoming cookie held, if any; set the session cookie; clear the login cookie; 303 to the
   site origin from the stage setting plus `return_to`. Answer with `Referrer-Policy: no-referrer` and
   `Cache-Control: no-store`.

GitHub's `error=access_denied` or any failure gives a 303 to `/login?error=<code>`, from a fixed list of codes.

**Cookies and authentication**: only the exact name `__Host-mopm_session` is read, and a request carrying two of them
is refused. An `Authorization` header that is present wins, and when it is invalid the request is refused; it never
falls back to the cookie. `Authenticator.authenticate`, for `kind: 'session'`, reads the user's `sessions_not_before`
with a strongly consistent read and refuses a session issued before it. That is one extra read per cookie request;
the session listing stays display-only on its eventually consistent index.

**CSRF token**: `X-Mopm-CSRF` = base64url(SHA-256("mopm-csrf\0" + session secret)), derived, so nothing new is stored;
`GET /me` returns it. A request that has a body must send `application/json`; logout, revoke-all and
`DELETE /me/sessions/{id}` have no body. A request from another stage's origin to this site's `/api/*` is
cross-origin: its custom header forces a preflight, which API Gateway's CORS settings answer without allowing that
origin, and the exact-Origin check refuses it in any case.

**Plumbing and infrastructure**: the Lambda event type gains `cookies` (payload format 2.0 puts request cookies there);
`HttpResponse` gains `cookies` and redirects; the `web_logins` table; a `sessions_not_before` attribute on the user
row; read grants for the owners `by_github_id` index and the invitations table, which `/me` needs; `/auth/web/*` in its
own function, the only one whose OAuth secret source returns `client_secret` (the comments in `oauth-secret.ts` and
`github.ts` that say the secret is never read change for that function only); the CloudFront `/api/*` behaviour adds an
origin header whose value is a stage secret, and cookie authentication and `/auth/web/*` refuse requests without it.

### C.2 Threats

| threat | defence |
|---|---|
| Login CSRF (attacker's account logged in) | `state` bound to the login cookie and single-use; PKCE ties the code to a verifier held only on the server; a callback without a matching cookie is refused; start refuses cross-site navigations |
| Forced re-login by another site | the `Sec-Fetch-*` checks on start |
| Session fixation | a session is minted only at the callback and never read from a URL; `__Host-` stops a sibling host planting one; the previous session is revoked at login |
| Open redirect via `return_to` | the C.1 rules; the redirect origin comes from the stage setting, never from `Host` |
| Code leakage | exact callback, wildcard off; PKCE (a stolen code is useless without the verifier); the callback answers 303 at once with `no-referrer` |
| Cross-stage requests | all stages are same-site, so SameSite does not separate them; the Origin check, host-only cookies and no credentialed CORS do |
| Direct calls to `api.<site>` with a cookie | the cookie is never sent there; cookie auth also requires the distribution's origin header |
| Session theft by XSS | HttpOnly; the token never reaches script |
| XSS minting a publish token | CSP `'self'` with Trusted Types, no HTML sinks, the restricted renderer; a fresh session needs a click in GitHub's account picker (`prompt=select_account`), which script on mopm.dev cannot perform. Residual: script could act inside an already fresh 15-minute window; the token list shows each token's origin |
| The token secret leaking from the page | shown in a text node only; never in the URL, history state, storage or the console; dropped on route change and `pagehide` |
| Stolen session used for publishing | sessions cannot publish or yank (`tokens.ts`); the cookie is not accepted on those routes |
| A stolen session surviving "Sign out everywhere" | `sessions_not_before`, checked with a strongly consistent read |
| Hidden code in a copied example | the copy button copies exactly what is shown; setup lines are disclosed; bidi and invisible characters are shown as markers |
| A tombstoned package still served | the takedown function, the merge that purges its segment bytes, no bucket versioning, and a CloudFront invalidation; no response is `immutable` (mopm-dev.md, 1.6) |
| The publish token reaching `mojo doc` or dependency code | the child's environment is an allowlist, built before the token is read (B.3 step 4) |
| A publisher-supplied path escaping the package | `[docs] api` real path must stay inside the package root (B.3 step 1) |
| Path traversal through module or symbol names | the B.3 grammar and the B.4 builders |
| A crafted search index from a publisher | none is accepted; the registry derives every document from validated data (A.6) |
| A publisher listing symbols it does not define | bounded: no term frequency, 500 names, group 4 below group 3; labelled `symbols_verified: false` (A.4) |
| Query-language abuse in search | no Tantivy query syntax; queries built from tokens, 256 bytes, 16 terms (A.4) |
| A forged search cursor | HMAC over generation and offset, offset clamped (A.4) |
| A truncated or tampered index file in `/tmp` | size and sha256 against the manifest before use (A.2, A.5) |
| Prompt injection through publisher text | labelled, sanitised, fenced, kept out of tool descriptions and `note` (E.3) |
| Exfiltration through images or hidden link text in agent Markdown | images and links rewritten to visible text (E.3) |
| An agent tricked into an authenticated call | read commands send no credential; arguments grammar-checked before a URL is built (E.2) |
| An agent installing an invented name | `exact: null` with a fixed note, `did_you_mean` never substituted, `new` marked; names differing only by case or separators are one name once PR 19 refuses runs of `_` (E.4) |
| Session cookies in logs | standard logs on the site distribution stay off; download logs (Q5) are on the channel distribution, with cookie logging off |

### C.3 Headers and CSP

The page CSP for v2 (site/v1's plan, with `connect-src 'self'` and one image origin added):

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' <GitHub's avatar origin>;
connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none';
require-trusted-types-for 'script'; trusted-types 'none'
```

The response headers policy on the `/api/*` behaviour: `X-Content-Type-Options: nosniff`, `Referrer-Policy:
no-referrer`, HSTS, and `Content-Security-Policy: default-src 'none'; sandbox; frame-ancestors 'none'` (every API
response is JSON, Markdown or plain text, never a page). The API itself sets `Cache-Control: no-store` on the callback
and `/me`, and `text/markdown; charset=utf-8` or `text/plain; charset=utf-8` on the `.md` and `llms.txt` routes. No
bucket is exposed through the site distribution: search files and served references are read by Lambdas only.

## D. Test plan

Every PR's tests run as Buck2 targets on remote execution. The mutant is the planted defect that must turn the named
test red before the PR is ready.

| # | tests (and mutant) |
|---|---|
| 0 | site/v1's existing tests and targets |
| R | the installer checks the binary's sha256 (mutant: skip the check; a tampered fixture binary must be refused); an unknown platform is refused with a message |
| V0 | after the pin moves, mopm's Rust targets build with komira's toolchain (cached build named by target) and the toolchain BUCK at the new pin names 1.99.0 (mutant: none; this is a pin, proven by the build) |
| V | one Rust test opens an in-memory Tantivy index with the pinned feature set and the `mopm_ident` stub tokenizer (mutant: enable a default feature that pulls `zstd-sys`; the build must fail on the missing build script) |
| 2 | layout: one `h1`, landmarks, install block before the README (mutant: README first); copy buttons have no inline handler (mutant: `onclick`); dialog content prerendered; `check-dist` per-route closures (mutant: a route over 128 KiB; a 25 KiB `site.css`); the home page's placeholders have fixed heights |
| 3 | router vectors give the 404 page outside the grammar (mutant: pass-through); `llms.txt` and `.md` paths map to API routes and nothing else does (mutant: map `/packages/<n>` to the API); no `CustomErrorResponses` (mutant: add one); the exact CSP per stage; the `/api/*` behaviour has its headers policy (mutant: drop it) |
| 4a | contract fixtures for `getMe`; the cookie never accepted on publish (mutant: accept it); an invalid `Authorization` with a valid cookie refused (mutant: fall back); two session cookies refused; revoke-all leaves API tokens (mutant: revoke every kind); a session issued before `sessions_not_before` refused while the listing index lags (mutant: an eventually consistent read) |
| 4b | a fake GitHub; a replayed callback refused (mutant: drop the `consumed_at` condition); a state mismatch refused; the `return_to` corpus (`//x`, `/\x`, `%2F%2Fx`, control characters, 257 characters) becomes `/account` (mutant: allow `//`); CSRF: missing header, wrong Origin, `text/plain` body each refused; start refused for `Sec-Fetch-Site: cross-site` (mutant: drop the check); the authorize URL carries S256 and `prompt=select_account` (mutant: drop `prompt`); `redirect_uri` comes from the setting with a forged `Host` (mutant: build it from `Host`); only the auth function holds the secret grant (stack test) |
| 4c | listing by invitee uses the new index and the API role still has no Scan grant; accept makes the caller an owner; an expired invitation refused |
| 5 | the `/api/*` behaviour does not forward `Host` (mutant: forward it) and does not cache cookie routes (mutant: cache `/me`); the secret is shown once and gone after `pagehide` (mutant: keep it in history state); a stale session shows "Confirm it's you"; token creation sends JSON with the CSRF header (mutant: a form post) |
| 6 | the JSON Schemas validate every valid vector and refuse every invalid one (mutant: drop `additionalProperties: false`, an extra-field vector must fail); each invalid vector names the rule it breaks; the shared corpora: JSON edge cases (`\u0000` escape, `\u202e` escape in an id, lone `\ud800`, a duplicate key with differing values), Unicode (tag characters, variation selectors, U+2061 to U+2064, U+00AD, C1 controls, private use), fences (a longer backtick run, a fake `## mopm note` heading); contract fixtures for every `mopm-*/v1` schema validate |
| 7 | komira's `mojo_doc_json` rule with `golden=`: red on any byte change; the golden has non-empty `args` and `parameters`, a struct with `__init__`, and the fields B.2 maps are present |
| 8 | the shared vectors through the validator (each JSON edge case refused; mutant: check raw bytes instead of decoded strings, the `\u0000` vector must fail); each cap refused just over its limit (mutant: off by one); the path corpus (`..`, `/`, `%2e%2e`, a backslash, bidi characters, `pkg.._x`) refused (mutant: a prefix check); a `ref` to an undeclared package refused (mutant: accept any package); a forged overload key refused (mutant: skip recompute); a served-form field in the publish form refused; a served form over 8 MiB refused with `api_doc_too_large`; "since" over a three-version history with an out-of-order publish; the docstring attack corpus through the Markdown renderer; the Unicode corpus through the sanitiser (mutant: strip only the old zero-width list, a tag-character vector must fail); a remote `$ref` is not fetched (mutant: enable resolution against a fixture URL) |
| 9 | tokenizer output pinned on a corpus (mutant: drop camelCase splitting); ranking vectors over in-memory indexes: group order (mutant: swap groups 2 and 3), typo bounds (mutant: `k = 2` at 4 characters), a typo never satisfies a term (mutant: let it), first character must match, group 1 keeps the shortest names past 200 prefix hits (mutant: order after the cut), all-yanked packages only in groups 0 and 1 (mutant: in text groups), the document comes from the highest published version (mutant: last published), name tie-break makes the order total (mutant: drop it); adding 2,000 symbols to package B leaves A and C in the same order (mutant: one index for both kinds); `parsing` and `parser` find "parse" in a summary (mutant: no stem fields); a 4-term query with one off-topic word still returns the right package (mutant: strict AND); a package listing 500 copies of `json` scores no higher than one listing it once (mutant: term frequency on); `compatible` and `basis: "compatible"` with requirement from the compatible version (mutant: requirement from `version`); `lines` capped at 3 with `lines_total` for a 99-line 0.x package; `common_mojo` over three packages, and `null` with the conflict named; the writer loop over the fake object store: manifest last, conditional put, a truncated file re-fetched (mutant: reuse it), one poison package does not stall the batch (mutant: fail the batch); the query cap at 16 terms |
| 9b | the synthetic catalogue bench (1,000, 10,000, 100,000 packages), a separate non-welded target: index bytes per index |
| 10 | the layout accepts `lib/mojo/<name>.mopm-api.json` only beside a `.mojoc` of the same subdir (mutant: accept it anywhere) |
| 11 | a fixture package with a fake `mojo` (a script under `test_proc`) producing the golden: the archive carries the converted file in every subdir; the fake `mojo` dumps its environment and `MOPM_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and `GH_TOKEN` set in the parent are absent (mutant: inherit the environment); `auto` with a failing `mojo` publishes without docs and prints `docs: NONE` (mutant: print nothing); `require` refuses; an invalid `--api-json` file refuses in `auto` (mutant: warn only); `[docs] api` pointing through a symlink outside the package refuses (mutant: no real-path check); a string containing the source directory, its real path or the temp dir refuses (mutant: skip the check); a compiler mismatch never runs `mojo doc`; `[docs]` parses in `mopm.toml` (mutant: leave `onlyKeys` unchanged); `mopm doc --check` agrees with crate 8 on every shared vector |
| 12 | an invalid `mopm-api.json` refuses the publish and stores nothing (mutant: store before validating); served files are create-only (mutant: overwrite on retry); identical files across subdirs stored once |
| 13 | against fakes of S3, DynamoDB, SQS and CloudFront: the manifest is written last (mutant: manifest first, caught by a reader between writes); a conditional-put conflict fails the batch (mutant: unconditional put); a yank leaves the next generation's text ranking; a tombstone purges the package's bytes from every file of the live generation, checked by opening every segment and reading every stored document, deleted ones included, for a marker (mutant: `delete_term` without merge); the tombstone issues the invalidation for the three paths (mutant: none issued); eight quiet days keep the live files (mutant: age-based deletion); a poison package goes back to the queue alone and the rest commits; the DLQ, `maxReceiveCount` and queue-age alarm exist (stack test); the bucket has versioning off (stack test); the retry pass sends `search` (mutant: send only from `moveToIndexing`); `GET /api/v1/home` excludes yanked versions; batch time and full rewrites per day on the synthetic catalogue (relative figures) |
| 14 | the API answers the shared contract vectors (`exact: null` with the note built from the normalised query, `did_you_mean`, `cursor_stale`, a forged cursor, the 200-result stop); a query over 256 bytes is cut and flagged; Tantivy syntax in `q` (`name:x`, `/re/`, deep parentheses) is treated as text (mutant: route `q` through `QueryParser`); publisher text appears only under `publisher`, `symbols`, `example` and docs (mutants: put the summary in `signals`; put `signature` outside the untrusted object); `api.md` contains no `![` and no reference definition (mutant: pass images through); a docstring with a longer backtick run and a `## mopm note` heading stays inside its fence (mutant: a fixed three-backtick fence); the Unicode corpus is stripped; `has_api: false` omits `api` links; a new generation is picked up without a cold start; a cursor survives the swap to the next generation; requirement versions resolve to the highest matching published version; responses carry the `Cache-Control` of 3.2 (mutant: `immutable`) |
| 15 | CLI `--json` output equals the contract fixture bytes (mutant: reorder fields); an empty result exits 0 (mutant: exit 1); `mopm mcp` lists its tools in a fixed order with output schemas, and a tool description never contains fixture publisher text (mutant: interpolate the summary); a traversal name (`../me/tokens`, `%2e%2e`) is refused before any request (mutant: pass it through); no `Authorization` header on search, info, api or mcp calls with a stored credential present (mutant: attach it); `mopm api` on an installed file applies the sanitiser |
| 16 | the search page renders one row per package with version, version count and at most two other lines from fixtures; the "New" badge renders from fixtures; match reasons and symbols render through `h()` only (mutant: an HTML snippet); arrow keys and Enter; "Show more" stops at 200 |
| 17 | views over the served golden; type links only for resolved refs (mutant: link unresolved names); a docstring heading equal to a symbol anchor stays distinct (mutant: unprefixed ids); setup lines copied only when shown (mutant: copy hidden lines); bidi markers visible; the version switcher's fallback chain; docstring raw `<dialog>` renders as text (mutant: pass it through) |
| 18 | the existing docs test; `/llms.txt` lists only commands the CLI has (mutant: name `mopm add` before it exists); the scaffold-and-build recipe runs against the fake registry and fixture packages to a built binary (mutant: drop the `[toolchain]` step; the build must fail) |
| 19 | publish answers `invalid_name` for `http__client`, `http_client_` and `a__b` (mutant: the old pattern `^[a-z][a-z0-9_]{1,63}$`), and still accepts `http_client`, `h2` and a 64-character canonical name (mutant: refuse any `_`); the index-record, lock and takedowns schemas refuse the same names; a test asserts that the OpenAPI `Name` pattern, the schema name patterns and `site/src/routes.ts` `NAME` have the same source as `NAME_PATTERN`, as `validate.test.ts` does for `SONAME_PATTERN` (mutant: leave the old pattern in `openapi.yaml`); the `invalid_name` hint names the new rule (mutant: keep the old hint) (Q10) |
| 20 | aggregation over fixture log lines: 200 and 206 counted, 304 not; the log configuration excludes cookies (stack test) |

## E. Agents

### E.1 `mopm-search/v1`

```json
{"schema": "mopm-search/v1", "generation": "g-7f3a", "query": {"q": "http client", "normalized": "http_client",
 "mojo": "1.0.0", "platform": "linux-64", "truncated": false}, "total": 3,
 "exact": "http_client", "did_you_mean": [], "note": null, "next_cursor": null,
 "results": [{
   "name": "http_client", "version": "0.4.2", "versions": 37,
   "lines": {"0.4": "0.4.2", "0.3": "0.3.9", "0.2": "0.2.7"}, "lines_total": 5,
   "mojo_versions": ["1.0.0", "0.26.1"], "compatible": "0.4.2", "basis": "latest", "platform_ok": true,
   "state": "ok", "match": ["name:exact"],
   "requirement": "http_client = \"0.4\"", "import": "from http_client.client import Client", "has_api": true,
   "symbols": [{"untrusted": true, "id": "http_client.client.Client", "kind": "struct",
                "signature": "struct Client", "inits": ["fn __init__(out self, base_url: String)"],
                "summary": "An HTTP/1.1 client with pooling."}],
   "links": {"page": "https://mopm.dev/packages/http_client/0.4.2",
             "api": "https://mopm.dev/api/v1/packages/http_client/0.4.2/api",
             "api_md": "https://mopm.dev/packages/http_client/0.4.2/api.md",
             "llms_txt": "https://mopm.dev/packages/http_client/0.4.2/llms.txt",
             "symbol": {"http_client.client.Client":
                        "https://mopm.dev/api/v1/packages/http_client/0.4.2/api/http_client.client.Client"}},
   "signals": {"published_at": "...", "first_published_at": "...", "new": false,
               "requires_mojo": {"0.4": "==1.0.0", "0.3": "==0.26.1"},
               "platforms": ["linux-64", "osx-arm64"], "license": "Apache-2.0", "provenance": "oidc",
               "native_deps": 1, "symbol_count": 41, "symbols_verified": false},
   "publisher": {"untrusted": true, "summary": "...", "repository": "https://github.com/...",
                 "snippet": {"text": "...", "highlights": [[4, 8]]}}}]}
```

- `note`, when `exact` is null: "No package is named '<query.normalized>'. Install only names returned here." Fixed
  text around a value that follows the name grammar; never raw `q` or publisher text.
- `basis`: `latest`, or `compatible` when `mojo=` names a Mojo the latest does not support and an older version does;
  then `version` stays the latest, `requirement` and `links` come from `compatible`, and `symbols` and `import` are
  omitted (they were indexed for latest; `links.api` points at the compatible version). `compatible: null` when no
  version fits.
- `signals` holds only registry-derived values and values checked against a grammar: `license` is present only when it
  parses as an SPDX expression; `platforms` only known subdir names, taken from the archives. Anything else the recipe
  declares is left out.
- `new`: first published under 30 days ago, or fewer than 3 versions.
- `state: "all_yanked"` adds `yank_reason` under `publisher`; `version` is the highest yanked version.
- `fields=name,version,requirement` returns only those keys per result; `example` is returned only when named
  (untrusted, at most 2 KiB); unknown fields are an error.
- Error body: `{"schema": "mopm-error/v1", "code": "...", "message": "...", "request_id": "..."}`, the API's existing
  envelope with the schema tag added.
- The `mopm` package-URL type is not registered, so ids are plain `<name>@<version>` and symbol ids, not purls.

### E.2 Package, symbol, resolve and MCP

- `GET /api/v1/packages/<n>[/<v>]` returns `{schema: "mopm-package/v1", name, state, latest, versions: [{version,
  state, published_at, requires_mojo, platforms, dependencies: [{name, requirement}], native_deps: [id]}],
  next_cursor, has_api, example?, publisher: {untrusted, summary, repository}, links, next_steps: [string]}`; 20
  versions per page, newest first. `next_steps` is fixed text keyed by state, such as "Add `<requirement>` under
  `[dependencies]`, set `[toolchain] mojo` to one of `<mojo_versions>`, then run `mopm sync`."
- `GET /api/v1/packages/<n>/<v>/api` returns the served file (B.4); `.../api/<symbol id>` returns `{schema:
  "mopm-symbol/v1", package, version, symbol, overloads, import, since, links}`; `<v>` accepts an exact version,
  `latest`, or a requirement in `mopm.toml` syntax. Unversioned `llms.txt` redirects to the latest version's.
- `GET /api/v1/resolve?names=a,b[&mojo=]` (at most 50): `{schema: "mopm-resolve/v1", mojo, common_mojo, toolchain,
  results: [{name, exists, state, version, compatible, requirement, did_you_mean}], conflicts}`. Without `mojo=`,
  `common_mojo` is the newest Mojo for which every existing name has a published version (from the 256 newest versions
  in each `display`), `version` and `requirement` are chosen for it, and `toolchain` is `mojo = "<common_mojo>"`; when
  none exists, `common_mojo` is `null` and `conflicts` names the packages with no shared Mojo.
- `mopm mcp` tools: `mopm_search(q, mojo?, platform?, limit?)`, `mopm_package(name, version?)`, `mopm_api(name,
  version?, symbol?)`, `mopm_resolve(names, mojo?)`; each `outputSchema` is the matching JSON Schema; results carry
  `structuredContent` and the same JSON as text. Tool annotations mark them read-only. Descriptions say "send 1 to 3
  keywords, not a sentence".
- **Arguments and credentials**: every argument is checked before a URL is built (name grammar, version or requirement
  grammar, symbol-id grammar, `names` at most 50) and encoded per component by the Zig twin of `src/routes.ts`; a
  failure is a tool error naming the argument, with no request sent. These commands never attach the stored credential
  or `$MOPM_TOKEN`. The server rate-limits and sanitises outputs (the MCP rule) and caches responses by generation.

### E.3 Untrusted text

Publisher text is: description, keywords, README, repository URL, every string in `mopm-api.json` (docstrings,
signatures, type text, argument defaults, alias values, constraints, `raises_doc`, example code and titles, section
titles, symbol names beyond their grammar), yank reasons and deprecation messages. In agent responses (JSON, Markdown,
MCP) it:

- appears only in `publisher` objects, `symbols[]` entries (each wholly marked), `example` and docs, each marked
  `"untrusted": true`;
- in Markdown, each field is fenced on its own with an info string `publisher-supplied`; the fence is backticks, one
  longer than the longest backtick run in the content and at least 3 (CommonMark's rule; the same for `~`), so content
  cannot close it; headings inside publisher Markdown are rendered as plain text lines, never into the outline;
- has images turned into `[image: <alt>]`, links into `text <url>` with the URL visible, link titles and reference
  definitions (`[x]: url "title"`, `[//]: #`) dropped, HTML comments and raw HTML removed;
- has every code point of Unicode general category `Cf` removed (zero-width characters, bidi controls, U+2061 to
  U+2064, U+00AD, U+061C, U+180E, U+FEFF, tag characters U+E0000 to U+E007F; ZWJ is removed too), plus variation
  selectors (U+FE00 to U+FE0F, U+E0100 to U+E01EF), U+034F, the Hangul fillers U+115F, U+1160, U+3164 and U+FFA0,
  private-use (`Co`) and unassigned code points, and C0 and C1 controls except newline; then is cut to its cap (summary
  512, snippet 200 characters, signature 4 KiB, example 2 KiB);
- never appears in tool names, tool descriptions, `note`, error messages or `llms.txt` headings.

The same sanitiser (one Rust implementation, a Zig port checked against the shared corpus) runs on `mopm api`'s local
reads of an installed `mopm-api.json`; `/llms.txt` points agents to `mopm api`, not to the file. A phrase that looks
like an instruction to an agent is not blocked (that is a content judgement), but no field gives it a place that reads
as mopm's own voice.

### E.4 Normalised and new names

- **Normalised** (the whole claim-time rule, Q10): lowercase, with runs of `-`, `.` and `_` collapsed to one `_`. That
  is the same equivalence as PyPI's PEP 503, which collapses runs to `-`; mopm's canonical form uses `_`. Only a name
  already in canonical form is accepted. In place today: `spec/api/openapi.yaml` says names in paths are normalised and
  a non-normalised name gets `invalid_name`; publish refuses any name outside `^[a-z][a-z0-9_]{1,63}$` (`NAME_PATTERN`
  in `service/api`), and `spec/index-record.schema.json` uses the same pattern, so upper case, `-` and `.` are refused.
  Not yet: that pattern accepts runs of `_` and a trailing `_`, so `http__client` could be published beside
  `http_client`. PR 19 changes the pattern to `^[a-z][a-z0-9]*(_[a-z0-9]+)*$` (length 2 to 64) in every copy of the
  old one (service, OpenAPI `Name` and filename patterns, index-record, lock and takedowns schemas, site router, fake
  registry), refusing both, a trailing `_` because PyPI also requires a name to end with a letter or digit. Nothing beyond it: no look-alike
  folding, no similarity flag.
- **New** (flagged): `signals.new` (E.1); `/llms.txt` tells agents to show a `new` or no-provenance package to the
  human before adding it. A brand-new name that exactly matches an invented one still gets a clean
  group-0 hit; `new` is what tells the agent to ask.
- No endpoint, report or log export lists frequent `exact: null` queries.
- The `reserved_names` table holds names the project lead reserves; nothing reserves names automatically.
