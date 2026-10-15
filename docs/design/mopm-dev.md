# mopm.dev v2: search, API reference, agents and web login

Status: proposal, for review. The CEO has decided search and docs (Q1, Q2, section 7); the CEO answers Q5, Q7, Q8,
Q10 and Q11 and the API owner Q3 and Q9 before the PRs they gate. The registry API is moving from Node.js to Rust
Lambdas (the API owner's port); search and the docs validator are Rust code in that same service, and this note designs
only what they need from it (6.1). Written against `main` and the unmerged `site/v1` branch. **Unverified** marks what
no code, doc or run has confirmed; every size and timing is an estimate until a synthetic catalogue measures it. Detail
is in [mopm-dev-appendix.md](mopm-dev-appendix.md).

## The CEO's decisions, and where this note answers them

| decision | section | status |
|---|---|---|
| (a) publishers supply docs; `mopm publish` runs `mojo doc`; `mopm-api.json` is the standard; any tool works | 2.1 to 2.3 | done as decided |
| (b) Tantivy; index at publish, as much compute on the publisher as possible, merged server-side | 1.1 to 1.3 | **one deviation**: the registry, not the publisher, builds the Tantivy segment (1.1); needs the CEO's yes (Q8) |
| (c) packages with about 100 versions | 1.5, A.7 | done; one row per package, release lines capped |
| (d) search an LLM can drive end to end | 3 | done, including a scaffold-and-build recipe (3.4) |
| (e) search in Rust Lambdas in the API's Rust service, Tantivy linked | 1.3, 6.1, 6.2 | done; needs komira's Rust bumped to 1.86 (Q11) |

## Decisions at a glance

| area | decision |
|---|---|
| Search | Tantivy 0.26.x, linked into Rust Lambdas in the registry's Rust service: a query Lambda behind `GET /api/v1/search` and a single writer Lambda fed by a `search` queue. Two Tantivy indexes (packages, symbols) under one manifest. The site and the CLI call only API endpoints. |
| Publish-time work | The publisher's machine does the heavy, Mojo-dependent work: it runs `mojo doc` (with no credential in its environment), converts the output to `mopm-api.json` and checks it. The registry validates that plain data, derives the search documents with its one tokenizer and commits them as a small segment that Tantivy merges into the catalogue index. A client-built segment is not accepted (1.1, Q8). |
| Ranking | The brief's order as strict groups: exact name, name prefix, name with a small typo, name part or keyword or summary, symbol, README. Within a group: BM25 (with stemmed alternatives) times a static boost, then name. The order is total for an index generation, and every response names its generation. |
| Versions | One result per package, from its highest published version, with the version count, at most three release lines, the Mojo versions it supports and, given the caller's Mojo, the version to use (1.5). |
| API reference | `mopm publish` runs `mojo doc` automatically and packs `mopm-api.json`, a small versioned format with a published JSON Schema; any tool that emits it also works. The registry validates it, computes "since" markers and links, and stores it per version. Docs are supplied, and attested, by the publisher. |
| Agents | Versioned JSON schemas for search, package, symbol and resolve, shared by the API, `mopm --json` and `mopm mcp`; a Mojo-aware `resolve` that names one toolchain for a set of packages; `llms.txt` with a scaffold-and-build recipe; publisher text labelled untrusted and sanitised; a fuzzy name is never resolved automatically (section 3). |
| Login | GitHub OAuth with PKCE. `/api/*` is served on the site host, so the session is a `__Host-` HttpOnly cookie that never reaches `api.<site>` and needs no credentialed CORS. Every web login shows GitHub's account picker. |
| Takedown | A tombstoned version leaves search (its segment bytes purged by a merge), the stored reference, the landing page and the CDN (an invalidation) within one writer batch (1.6). |
| CLI install | The landing page leads with one install line; that needs a release binary and an installer, which do not exist yet (Q7). |
| Questions | Answered: Q1 search, Q2 docs. Open: Q3 API on the site host; Q5 download counting; Q7 release binary; Q8 who builds the segment; Q9 the Rust service interfaces; Q10 similar names; Q11 komira's Rust version. |

## Goals and non-goals

Goals: (1) **sign in with GitHub** and manage the account (profile, API tokens, packages and owners, invitations,
sessions, sign out everywhere); (2) **a landing page worth looking at**: a large search box, a one-line CLI install,
featured and recent packages, a quickstart, prerendered, dark mode, keyboard-first; (3) **real search** over name,
summary, keywords, README and symbols, typo tolerant on names, one answer for the site, the CLI and agents; (4) **a
package page** led by one copyable install command; (5) **Dokka-style API reference pages**: module tree, symbol
filter, members table, linked signatures, parsed docstrings, copyable examples, "since" markers, version switcher;
(6) **docs with no extra step** at publish; (7) **search an LLM can drive**, from a capability question to a Mojo
toolchain, exact versions, `mopm.toml` lines, imports, signatures and a build, in JSON.

Non-goals for v2: a long-running search server; running Mojo in the registry; semantic or vector search (if it comes,
the registry computes embeddings itself, as 1.1 argues); download counts (Q5); search filters or sort options; a hosted
MCP endpoint; write tools for agents; source links (`mojo doc` emits no locations); docstring coverage; owner
management on the web; changes to device login or publish authorization; the Node-to-Rust port itself.

## What exists today

`site/` on branch `site/v1` (reviewed, **not merged**) is plain TypeScript compiled by `tsc`, no framework or bundler;
every DOM write goes through the `Doc` port, links through `SafeHref`, READMEs through a restricted Markdown renderer.
The site stack's go-live (PR 3) serves the real build behind a CSP, an edge router and interim error responses (4.1).
`dist/` has 86,990 bytes of JavaScript.

The registry API is TypeScript Lambdas in `service/api`; `searchPackages` (`GET /packages?q=`) matches a name prefix
only. The CLI is Zig and has no `search`, `add` or `doc` command (`add` is listed as planned); a dependency is a
`mopm.toml` line followed by `mopm sync`. The resolver picks only versions built for exactly the project's Mojo
(`requires_mojo` is `==<toolchain>`, `src/core/resolve.zig`). mopm has no Rust code yet; komira's toolchains, which mopm
builds with, include Rust 1.85.0 for x86_64 Linux only. Each version record already holds `requires_mojo`,
`provenance`, the description, keywords and the README.

The five site rules bind everything below: (1) no runtime dependencies; (2) no HTML sinks, markup only through `h()`;
(3) no inline script or style, CSP `'self'` with Trusted Types; (4) one artifact for every stage, nothing
stage-specific compiled in or fetched at build time; (5) no live calls in tests, which replay `tests/contract/`.

## The mocks

Static pages in [mock/](mock/) ([what they are and how to view them](mock/README.md)): illustrative data, no
JavaScript. Every element traces to a section of this note.

| page | light | dark | mobile | sections |
|---|---|---|---|---|
| Landing | [index-light](mock/screens/index-light.png) | [index-dark](mock/screens/index-dark.png) | [index-mobile](mock/screens/index-mobile.png) | 5, Q7 |
| Package | [package-light](mock/screens/package-light.png) | [package-dark](mock/screens/package-dark.png) | [package-mobile](mock/screens/package-mobile.png) | 1.5, 5 |
| Search | [search-light](mock/screens/search-light.png) | [search-dark](mock/screens/search-dark.png) | | 1.4, 1.5, 3.6, 5 |
| API reference | [reference-light](mock/screens/reference-light.png) | [reference-dark](mock/screens/reference-dark.png) | | 2.4 to 2.6 |
| Account | [account-light](mock/screens/account-light.png) | [account-dark](mock/screens/account-dark.png) | | 4.3, 4.4 |

## 1. Search

### 1.1 Who does what at publish, and why

The CEO's intent: index at publish time, offload as much compute as possible to the publisher, and merge the new piece
into the big index on the server. This design keeps that shape and moves one step, building the Tantivy segment, to
the registry:

| step | runs on | why there |
|---|---|---|
| run `mojo doc` over the package sources | publisher | needs the compiler, the sources and the dependency `.mojoc` files; seconds to minutes; the registry has none of them (2.1) |
| convert to `mopm-api.json`, check caps, grammar and paths | publisher | a bad file is caught before upload, and the registry never parses compiler output |
| validate `mopm-api.json` and metadata against the schema and caps | registry validator | the trust boundary is plain data checked against a schema |
| derive the search documents: tokenize name, summary, keywords, README, symbols | registry writer | one tokenizer, the same code the query side uses |
| static rank (recency, later downloads) | registry writer | a publisher cannot vouch for it |
| commit a small segment; the merge policy folds it in | registry writer | what Tantivy's writer does on every commit |

**Why the registry builds the segment** (read from the tantivy 0.26.2 source, nothing run; full list in
[appendix A.6](mopm-dev-appendix.md#a6-alternatives-rejected)):

- **Compute saved is about zero**: one package of a few KB plus its symbols indexes in well under 10 ms, about $0.33
  per million publishes (estimate). A batch is dominated by S3 transfer, commit and upload, which a client segment does
  not remove. The expensive step, `mojo doc`, already runs on the publisher; so does conversion and checking.
- **Security**: a segment is binary input to readers not hardened against it (no fuzzing of segment readers, many
  `unwrap`/`panic!` sites, a CRC32 checksum anyone can recompute). Its field norms and token totals feed index-wide
  BM25 statistics, so one crafted segment can lift its own package and shift every other package's score, surviving
  merges. Checking a segment means rebuilding it.
- **Drift and lock-in**: the schema check compares tokenizer names, not code; the index format (0.26.2 writes 7, reads
  4 to 7) is readable only backwards, so CLIs in the field would pin the server; the foreign-segment APIs are
  `#[doc(hidden)]` and rewrite the whole index; the Zig CLI would embed a Rust library per platform.

What remains open with registry-built documents, stated rather than hidden: symbol names are attested by the
publisher, not checked against the `.mojoc`, so a publisher can list names its package does not define and appear in
the symbol group for them. That is bounded (symbol terms count once, at most 500 names enter the package document, and
symbol matches rank below every name, keyword and summary match; 1.4) and is labelled in the agent schema
(`"symbols_verified": false`). Checking names against the `.mojoc` waits on whether `mojo doc` reads one (B.1).

No registry surveyed (A.7) accepts a client-built index; Hex builds docs on the publisher's machine, as 2.1 does. The
CEO's picture, a small index per publish merged into the big one, is how Tantivy works: each commit writes a segment
and the merge policy folds it in. Only who builds the segment changes (Q8).

### 1.2 The search documents

Two Tantivy indexes under one manifest and one generation, both derived only from data the registry has validated.
Two indexes, not one, because BM25's average field length is computed over every document in an index: symbol
documents would shrink it about fifty-fold and let any package's symbol count move every other package's scores.

- **`pkg`**, one document per package (1.5): name (exact, prefix, typo, and its `_`-separated parts), summary,
  keywords, README text, up to 500 exported symbol names; display fields (latest version, version count, release
  lines, the Mojo versions supported, platforms, licence, repository, owners, provenance, publish times).
- **`sym`**, up to 2,000 per package from the latest version's `mopm-api.json`: id (the import path), kind, signature,
  summary, and for a struct its first two `__init__` signatures. A query attaches the best three matching symbols to
  each package result, so an agent gets signatures in the search response.

The tokenizer splits identifiers on `_` and camelCase and keeps the whole token and its parts; Tantivy has none, so the
crate implements one. Summary, keywords and README also get an English-stemmed copy, searched as an alternative, so
"parsing" finds "parser". Schemas, caps and tokenizer: [appendix A.1](mopm-dev-appendix.md#a1-schema-and-tokenizer).

### 1.3 Index, writer and serving

- **One crate, `mopm-search`** (schemas, tokenizer, derivation, query planning, ranking, response types, and the
  writer's loop over an object-store trait), linked by the writer and the query Lambda; nothing else tokenizes or
  ranks, so the site, CLI and agents cannot disagree.
- **Writer**: a FIFO `search` queue (one message group, batches of up to 10) feeds a Rust Lambda with reserved
  concurrency 1. Senders: the validator once a version is published (both passes), `setYanked`, every transition to
  `tombstoned`. Per batch: sync missing files into `/tmp` (each checked against the manifest's size and sha256);
  `delete_term` and `add_document` per affected package; `commit`; upload the new files; write the manifest last with a
  conditional put, so a second writer fails.
- **Failure isolation**: a package whose derivation fails is logged, skipped and re-queued on its own; the rest of the
  batch commits. A batch that still fails goes to a dead-letter queue after 5 receives, with an alarm on queue age; the
  visibility timeout is 6 times the function timeout, sized for a cold download plus a merge at the largest catalogue
  PR 9 measures.
- **Incremental, not rebuilt**: Tantivy's `LogMergePolicy` folds small segments and drops deleted documents. A forced
  merge runs only after a takedown (only the segments that held the package) or above 40 segments, so a full rewrite
  is rare; PR 13 reports full rewrites per day at a given publish rate.
- **Query Lambda**: Rust, ZIP-packaged, x86_64 (komira's Rust toolchain targets x86_64 Linux only). It copies the
  immutable files named by the manifest into `/tmp` (to a `.part` name, checked, then renamed; reused files are size
  checked), opens them with `MmapDirectory`, rechecks the manifest's ETag at most every 30 s, keeps the previous
  generation open for 5 minutes so cursors survive a swap, and deletes files no open generation names. Cold start at
  10,000 packages: about 1.5 to 2 s for 95 to 145 MB at 80 MB/s sequential (A.3); parallel ranged GETs are not yet
  measured.
- **Storage**: a private `search/v1/` prefix, versioning off, read by the two Lambdas only
  ([A.3](mopm-dev-appendix.md#a3-size-and-cost)). **Determinism** is on results, not files (segment ids are random):
  one generation and query give one total order, and every response names its `generation`. **Query safety**:
  Tantivy's query syntax is never exposed; the crate builds queries from its own tokens, at most 256 bytes and 16 terms.

### 1.4 Ranking

Groups in the brief's order. Tantivy cannot rank by group, so the crate runs one small query per group and merges in
code; a package appears once, in its best group.

| group | rule | order within the group |
|---|---|---|
| 0 | the normalised query equals the package name | |
| 1 | the name starts with the normalised query (2 or more characters) | shorter name, then static rank |
| 2 | the name is within a small edit distance of the normalised query | smaller distance, then static rank |
| 3 | enough terms (all when there are 1 or 2, else all but one) match the name's parts, the keywords or the summary | score |
| 4 | as 3, except that some term matches only a symbol name | score |
| 5 | as 4, except that some term matches only the README | score |
| 6 | only when groups 3 to 5 are empty: any term matches | score |

- Groups 0 to 2 normalise as `normaliseName` does, spaces included, so `http client` finds `http_client` exactly.
- **Typos**: `FuzzyTermQuery` on names only, a swap costing one edit: 0 edits up to 3 characters, 1 up to 7, 2 beyond
  (Tantivy's maximum); the first character must match; a typo never counts as a term match in groups 3 to 5.
- **Words**: each term matches its exact form or, in summary, keywords and README, its stem; filler words (`mojo`,
  `package`, `library`, `lib`) are dropped from multi-term queries. The last term (3 or more characters) also matches
  as a prefix, up to 20 completions.
- **Score**: BM25 with field boosts (name parts 10, keywords 5, summary 3, symbols 2, README 1; stems at 0.7 of
  their field) times a static boost (recency; downloads after Q5) through `tweak_score`; ties by name. A symbol name
  counts once however often it is listed. Arithmetic: [appendix A.4](mopm-dev-appendix.md#a4-ranking).

### 1.5 Versions in search

**How others do it** ([appendix A.7](mopm-dev-appendix.md#a7-versions-survey)): every registry surveyed returns one
result per package, keyed on one default version, usually the highest stable version that is not yanked (crates.io
shows serde's 316 versions as one row with `num_versions`). pkg.go.dev adds "Other major versions"; Maven and NuGet
list every version only on request. When every version is withdrawn, crates.io keeps the crate and PyPI, JSR and
docs.rs drop it. A pitfall: crates.io's searchable text is rewritten by whichever version was published last.

**For mopm** (versions are `MAJOR.MINOR.PATCH`, no prereleases; states published, yanked, tombstoned; a version is
built for exactly one Mojo):

| term | rule |
|---|---|
| latest | the highest version in state `published`, never the last one published; the `pkg` document's text and symbols come from it |
| `versions` | published plus yanked versions (as crates.io's `num_versions`); tombstoned are not counted |
| `lines` | the highest published version of each release line (a major, or `0.y`, since minors break under the caret rule), newest 3 only, plus `lines_total`; the row shows other lines as "also 0.9.4", at most 2 |
| updated | latest's `published_at`; `first_published` is the first version's |
| `mojo_versions` | the distinct Mojo versions of published versions, newest first, at most 8 |
| `compatible` | with `mojo=` (the CLI and `mopm mcp` fill it from the project): the newest published version built for that Mojo, or `null`; the result is never hidden for it |
| all yanked | exact-name and prefix matches only (groups 0 and 1), `state: "all_yanked"`, the highest yanked version shown struck through, and the reason; only tombstoned or nothing published: no entry |

- **What an agent copies follows the version it should use**: with `mojo=` set and `compatible` older than latest,
  `requirement` and `links` are built from `compatible` and the result says `"basis": "compatible"`; `symbols` and
  `import` (indexed for latest only) are then left out and `links.api` points at the compatible version's reference.
- **Symbols are searched in the latest version only** (as JSR and pkg.go.dev); a version-pinned question is answered
  from that version's stored `mopm-api.json` (3.2). Full history is the paginated versions endpoint (3.2); package pages
  group versions by line and flag outdated ones (A.7).
- **Several packages, one Mojo**: `resolve` names the newest Mojo every planned dependency has a published version for
  (3.2), the question a scaffold has to answer before writing `[toolchain]`.

### 1.6 Takedown

Every path to `tombstoned` (`state.ts`; a takedown route does not exist yet) goes through one function that sends a
`search` message, deletes the version's stored reference and issues one CloudFront invalidation for
`/api/v1/packages/<n>/*`, `/packages/<n>/*` and `/api/v1/search*`. `delete_term` only marks a document deleted; its
bytes, stored README included, stay until merged. So the writer merges every segment that held the package, writes the
manifest and deletes the old files at once, not after the retention window; the bucket keeps no noncurrent versions.
Query Lambdas drop it within 30 s and the edge within the invalidation's completion (minutes; CloudFront does not
promise a bound). No response is cached as `immutable` (3.2). `GET /api/v1/home` (Featured, Recent) excludes yanked
and tombstoned versions and is read at run time.

## 2. API reference

### 2.1 `mopm publish` runs `mojo doc`

`mopm publish` never runs `mojo` today, but the manifest names the sources (`[targets] lib`, written by `mopm new`),
and `mopm test` already finds the Mojo environment and runs children under a deadline and a memory cap. So `mopm
pack` and `mopm publish`, before packing, before any credential is read, and with no network:

1. take `[docs] api` or `--api-json` if given (another tool's `mopm-api.json`, used as is; the path must stay inside
   the package root after symlinks resolve), else the `lib` directory;
2. find the environment as `mopm test` does; its compiler must equal `--compiler`;
3. run `mojo doc` with the dependency `.mojoc` files on the include path (300 s, 4 GiB), in a fresh private temporary
   directory, stdin from `/dev/null`, with an **allowlisted environment** (`PATH`, `HOME`, `TMPDIR`, `MODULAR_HOME`,
   locale): never `MOPM_*`, `ACTIONS_ID_TOKEN_*` or any `*_TOKEN`;
4. convert to `mopm-api.json` v1, check caps, grammar and duplicate keys, and refuse any string that looks like a local
   path;
5. pack the same bytes in every subdir at `lib/mojo/<name>.mopm-api.json`, so consumers get it installed and an agent
   can read a dependency's API offline (through `mopm api`, which sanitises it as the API does).

Publish executes the Mojo compiler from your environment, as `mopm test` does; with dependencies on `-I` it may
evaluate their compile-time code (**unverified**; PR 7 settles it). That is why step 3 holds no credential.

**Any other tool** needs a one-time `[docs] api = "<path>"` in `mopm.toml`, and no per-publish flag.

**Failure policy**: `[docs] mode` or `--docs` is `auto` (default), `require` or `off`. In `auto` a missing
environment, a failed `mojo doc` or an exceeded cap **publishes without docs and warns loudly**; a named file that is
invalid refuses. `require` refuses in every case (CI uses it). Every publish prints a docs line (`docs: 37 symbols in
4 modules, 81 KiB` or `docs: NONE`), search results carry `has_api: false`, and the site says "No API reference:
generation failed at publish": never silent. **`mopm doc`** runs steps 1 to 4 alone; `--check <file>` runs the shared
vectors' rules (caps, grammar, paths; JSON Schema validation is the registry's); `--from-mojo-doc <raw>` converts
komira's `mojo_doc_json` output. Detail: [appendix B.3](mopm-dev-appendix.md#b3-publish-steps-validation-and-caps).

### 2.2 The `mopm-api.json` standard

mopm defines the format and `mojo doc` is one producer
([schema sketch, appendix B.2](mopm-dev-appendix.md#b2-mopm-apijson-schema-version-1)):

- **Facts only**: what a doc tool knows. Everything derivable ("since", signature tokens, import lines, links, the
  search documents) the registry computes into a served form, so correctness lives in one place.
- **One flat symbol table keyed by import path** (`http_client.client.Client.send`); an overload is
  `<id>#<12 hex of the sha256 of its normalised signature>`. A hit maps to `from http_client.client import Client`,
  the defining module, until a later schema version adds re-exports.
- **Strict and versioned**: `additionalProperties: false`; a new field is a new integer `schema_version`; the registry
  accepts every version it has published. Published at `https://mopm.dev/schema/mopm-api-1.json`, normative text in
  `spec/mopm-api.md`; validators embed the schemas and resolve no remote `$ref`. Same compiler, sources and
  dependencies give the same bytes.

### 2.3 Registry validation, served form and storage

- **Layout**: `validate/layout.ts` allows `lib/mojo/<name>.mopm-api.json` beside a `.mojoc` of the same subdir, live
  (PR 10) before any CLI sends it (PR 11).
- **Validation** (crate `mopm-apidoc`, in the validator): the declared schema version, matching package and version,
  unique ids, every parent, member and `ref` resolving (this package, a declared dependency, `std`), recomputed overload
  keys, no served-form fields, caps, and character rules applied to **decoded** strings; duplicate keys and lone
  surrogate escapes are refused by every parser. Failure refuses with `api_doc_invalid` (or
  `api_doc_unsupported_version`, or `api_doc_too_large` when the served form would pass its cap).
- **Served form** ("since", tokens with resolved links, import lines, `supplied_by: "publisher"`): one file per version,
  stored create-only before the version is published, read through the API only.
- **Trust**: docs and symbol names are attested by the publisher, not checked against the `.mojoc`. Docstrings render
  only through the restricted Markdown renderer; signatures are tokens rendered as text.

### 2.4 Pages

**The browser renders from the served JSON** (`GET /api/v1/packages/<n>/<v>/api`) through the `Doc` port, so a
renderer change applies to every version. Routes `/packages/<n>[/<v>]/api[/<module path>[/<Symbol>]]`
([reference mock](mock/screens/reference-light.png)): a symbol filter (`f`, with `fn:`/`struct:`/`trait:`/`alias:`)
over the module tree on the left; title, badges, signature, docstring, examples and a **members table** in the centre,
with one section per member opening on demand; "On this page" on the right from 84rem; a version switcher that keeps
the symbol; anchors on every heading; "Copy import path". Badges: platforms, "since", "supplied by the publisher".
**Type links** only for a `ref` the registry resolved; every URL built by `src/routes.ts` from grammar-checked
components, none from the JSON ([appendix B.4](mopm-dev-appendix.md#b4-served-form-links-and-paths)).

### 2.5 Examples

Fenced code under `Examples:` renders as a block with a title (text), a copy button and an Output panel when an
`output` block follows, before Parameters. **The copy button copies exactly what is shown**: `%#` setup lines render
collapsed but disclosed and are copied only when expanded. Bidi and invisible characters show as markers. Colour comes
from a small lexer with a fixed set of class names.

### 2.6 "Since" markers and the docstring guide

"Since" is computed at publish against the greatest earlier version's stored reference, keyed by symbol id and
overload key, and fixed then ([appendix B.5](mopm-dev-appendix.md#b5-since-markers)). `/docs/docstrings/` tells
authors how sections, examples and setup lines appear, asks for **a runnable quickstart under `Examples:` in the
package docstring** (it becomes the `example` agents receive), says what `mopm publish` prints about docs, and how
another tool targets `mopm-api.json`.

## 3. Agents and LLMs

A person asks an LLM to write code; the LLM runs `mopm search` or the MCP tool, reads the response, picks one Mojo for
its dependencies, writes `mopm.toml` and the imports, and builds. Every step works from JSON alone and makes an
invented name hard to install. **Versions**: `requirement` is a caret requirement built from the chosen version
(`http_client = "0.4"`) and `version` the exact value the lock will pin; the resolver already admits only versions
built for the project's exact Mojo, so a caret range cannot pick an unusable build, and `/llms.txt` says "commit
`mopm.lock`". Schemas: [appendix E](mopm-dev-appendix.md#e-agents).

### 3.1 Search API

`GET /api/v1/search?q=&mojo=&platform=&limit=&cursor=&fields=` (limit 5 by default, 20 at most, 200 results in all)
returns `mopm-search/v1`:

- **Envelope**: `schema`, `generation`, the query and its normalised form, `total`, `results`, `exact` (the package
  named exactly so, or `null`), `did_you_mean` (never substituted), a fixed `note` when `exact` is null ("No package is
  named '<normalised query>'. Install only names returned here."), `next_cursor`.
- **Result**, 80 to 150 tokens: `name`, `version`, `versions`, `lines` (3) and `lines_total`, `mojo_versions`,
  `compatible` and `basis`, `platform_ok` (with `platform=`), `state`, `match` (an array, such as `["name:exact"]`),
  `requirement`, `import`, `has_api`, `links` pinned to a version (`page`, `api` and `api_md` when `has_api`,
  `llms_txt`, `symbol` per symbol); **`signals`, registry-derived or grammar-checked only**: publish times, `new`,
  `requires_mojo` per line, platforms from the archive subdirs, licence when it parses as SPDX, provenance, native
  dependency count, symbol count, `symbols_verified: false`, `similar_to`; and **publisher text kept apart**:
  `publisher` (summary, repository URL, README snippet with highlight offsets, never HTML), `symbols` (up to three,
  each entry wholly untrusted: id, kind, signature, summary; a struct adds up to two `__init__` signatures), and
  `example` under `fields=` (a capped quickstart).
- Errors are JSON with stable codes; an empty result is a 200; `fields=` trims for a tight context. `searchPackages`
  (`GET /api/v1/packages?q=`, prefix listing) stays as it is.

### 3.2 Package, symbol and resolve

- `GET /api/v1/packages/<n>[/<v>]` returns `mopm-package/v1`: state, latest, the newest 20 versions (`?cursor=` for the
  rest) with state, `requires_mojo`, platforms, dependencies and native dependencies; `has_api`, `example`, and
  `next_steps` (fixed mopm text, never publisher text).
- `GET /api/v1/packages/<n>/<v>/api`: the served `mopm-api.json`. `<v>` is exact, `latest` or a requirement (`0.4`,
  `~1.2`) resolved to the highest matching published version, named in the body.
- `GET /api/v1/packages/<n>/<v>/api/<symbol id>`: one symbol with overloads, docs and examples.
- `GET /api/v1/resolve?names=a,b,c[&mojo=]`: each planned dependency's state, `did_you_mean` and the version to use;
  with `mojo=`, `compatible` per name; without it, `common_mojo` (the newest Mojo every named package has a published
  version for, or `null` with the conflicting names) and each package's version for it, plus a `toolchain` line
  (`mojo = "1.0.0"`) to paste.
- Caching: exact-version responses `public, max-age=3600` with an `ETag`, never `immutable`; `latest`, ranges and
  search `max-age=30` with no `stale-while-revalidate`; the takedown invalidation (1.6) covers the rest.

### 3.3 CLI and MCP

- `mopm search <q> [--json]`, `mopm info <n>[@<v>] [--json]`, `mopm api <n>[@<v>] [<symbol>] [--json|--md]` print the
  API's schemas unchanged with `--json`, a compact table otherwise, and send `mojo=` and `platform=` from the project
  and host. An empty result exits 0.
- `mopm mcp` serves MCP over stdio, calling only the API: tools `mopm_search`, `mopm_package`, `mopm_api` and
  `mopm_resolve` with output schemas and `structuredContent`, resources `mopm://package/{name}/{version}/api.md`. No
  write tools; tool descriptions are fixed strings, never publisher text, and say "send 1 to 3 keywords". A hosted
  endpoint is a later decision.
- **Read commands carry no credential**: `search`, `info`, `api` and `mcp` never send `Authorization`. Every argument,
  which a prompt injection may control, is checked against the name, version-or-requirement or symbol-id grammar
  before a URL is built, and encoded per component (the twin of `src/routes.ts`).

### 3.4 `llms.txt` and Markdown

`/llms.txt` (prerendered) covers the CLI, the API and MCP, and a numbered **scaffold-and-build recipe** that works
today: (1) search with 1 to 3 keywords; (2) `resolve` the chosen names to get one Mojo and a version each; (3)
`mopm new <app> --bin`; (4) set `[toolchain] mojo`; (5) add the `requirement` lines under `[dependencies]` (`mopm add`
is planned, not built); (6) `mopm sync`; (7) write code from `import`, `example` and `mopm_api`; (8) `mopm build` or
`mopm run`; (9) commit `mopm.lock`. It also says: verify names with search or resolve before adding them, and show the
human any package marked `new`, `similar_to` or without provenance before adding it.

`/packages/<n>/<v>/llms.txt` gives the summary, requirement line, import, example and module list;
`/packages/<n>/<v>/api.md` the reference as Markdown. The edge router maps them to API routes; the API renders them from
the served JSON with a versioned renderer, and HTML pages link them as `rel="alternate" type="text/markdown"`.

### 3.5 Publisher text is untrusted

Library owners' text returned verbatim to agents is a known prompt-injection path (a widely used docs server for LLMs
had a CVE for it). So ([appendix E.3](mopm-dev-appendix.md#e3-untrusted-text)):

- no field means "instructions to agents"; publisher text, including signatures, type text, defaults, section titles
  and the repository URL, sits only in `publisher`, `symbols`, `example` and docs, marked `"untrusted": true` in the
  schema and "supplied by the publisher" on pages;
- in Markdown each publisher field gets its own fence, one backtick longer than its longest backtick run, and
  publisher headings never reach the document outline;
- images become `[image: alt]`, links become `text <url>`, link titles and reference definitions are dropped, so a
  rendering chat client fetches nothing and the model reads nothing a person cannot see;
- format characters (Unicode `Cf`, tag characters included), private-use and unassigned code points, C0 and C1 controls
  and HTML comments are stripped; lengths are capped; tool descriptions and `note` never include publisher text;
- the same sanitiser runs on a locally installed `mopm-api.json` read by `mopm api`.

### 3.6 Names that do not exist

LLMs invent package names, often the same ones, and attackers register them. So search and resolve say plainly when a
name does not exist and offer `did_you_mean`, never a substitute; at claim, a confusable name (equal to an existing one
after removing separators and case and folding look-alikes such as `0`/`o`, `1`/`l`/`i`, `rn`/`m`) is refused, and a
name one edit from an existing package carries a `similar_to` signal for 30 days (Q10). Because an invented name is
usually new rather than a near miss, results carry `new` (first published under 30 days ago, or fewer than 3 versions)
and `first_published`, and `/llms.txt` tells agents to put such packages before the human. No endpoint or report lists
frequently searched names that do not exist: it would be a list of names to register.

## 4. Web login and account

### 4.1 Topology: the API under the site's own host

**Decision (Q3): CloudFront serves `/api/*` on the site host** (`https://mopm.dev/api/v1/...`); `api.<site>` stays for
the CLI and CI.

- A site-distribution behaviour with the stage's API domain as origin, every header but `Host` forwarded, all methods;
  caching follows the API's `Cache-Control` and is off wherever the cookie is read. `apiBase()` becomes `/api/v1`.
- The session cookie is **never sent to `api.<site>`**; no credentialed CORS anywhere. Cookie authentication and
  `/auth/web/*` also require a header only the distribution adds.
- **Each new behaviour gets a response headers policy** (`nosniff`, `no-referrer`, HSTS, a `default-src 'none';
  sandbox` CSP for JSON); page CSP in [appendix C.3](mopm-dev-appendix.md#c3-headers-and-csp). Until the API is
  under the site host (Q3), go-live's page CSP has `connect-src https://api.<site>`; the PR adding `/api/*` makes it
  `connect-src 'self'`.
- **No distribution-wide error responses** (they would turn JSON errors into HTML): the edge router serves the 404 page
  outside the route grammar (**unverified** that a CloudFront Function can return the whole page; fallback, a redirect
  to `/404`). **Interim:** until `/api/*` on the site host lands (Q3), go-live maps 403 and 404 to `/404.html` (status
  404) distribution-wide, which serves only the bucket today; the PR adding that behaviour removes them and has the
  edge router answer 404. Each stage's OAuth app gets the exact callback, wildcard off.
- **Rejected**: the browser calling `api.<site>` with credentials (credentialed CORS on every route, the CLI's too).

### 4.2 Endpoints, cookies and CSRF

New under `/api/v1`, additive: `GET /auth/web/start` and `/auth/web/callback`, `POST /auth/web/logout`, `GET /me`,
`GET`/`DELETE /me/sessions`, `POST /me/sessions/revoke-all`, the spec's invitation routes; `/me/tokens` also accepts the
cookie ([appendix C.1](mopm-dev-appendix.md#c1-endpoints-callback-and-plumbing), threats in
[C.2](mopm-dev-appendix.md#c2-threats)). The rules that matter: **start** only as a top-level navigation from this site,
with `state`, S256 PKCE, the exact `redirect_uri` and `prompt=select_account`, the login row consumed once;
**`__Host-mopm_session`** (`Secure; HttpOnly; Path=/; SameSite=Lax`, 7 days) accepted only on `/me/*` and logout, never
on publish or yank, and never a fallback from an invalid `Authorization` header; **CSRF** checks (exact `Origin`,
`Sec-Fetch-Site`, `X-Mopm-CSRF` derived from the session secret) on every non-GET; redirect targets from a stage
setting, never `Host`; **sign out everywhere** through `sessions_not_before`, read strongly consistent; a **fresh
session** (15 minutes) to create or revoke tokens, whose re-login needs a click in GitHub's account picker (for a
single-account user **unverified**; PR 4b checks by hand). Residual risk: script on mopm.dev acting inside an already
fresh window; the token list shows each token's origin.

### 4.3 Invitations

Nothing creates or lists invitations today (`inviteOwner` is specified, not implemented; the table is keyed by `id`).
**PR 4c** adds an invitee index, `inviteOwner` and the two `/me` routes; the account page shows Invitations once 4c is
deployed. Declining is letting the invitation expire.

### 4.4 Account page

**One page, `/account`, in sections** ([account mock](mock/screens/account-light.png)): `noindex`, redirect to `/login`
without a session; `/login` has "Sign in with GitHub" (a link, since `form-action 'self'` would block a form's
redirect). Sections: **Profile** (handle and avatar from the numeric GitHub id); **API tokens** (list with origin and
last use; create through `fetch` with JSON and the CSRF header; the secret shown once in a text node, dropped on
navigation and `pagehide`; revoke); **My packages**; **Invitations**; **Sessions** with Revoke and **Sign out
everywhere** ("Ends every session, in browsers and the CLI, including this one. API tokens keep working."). Listing
tokens needs a session, not a fresh one. GitHub's avatar origin is the CSP's one third-party `img-src`.

## 5. Pages, navigation and budgets

Header: brand, search box (`/` and `s`), Packages, Docs, sign-in or the account menu. Footer: repository, security
policy, docs, shortcuts. A theme toggle sets `data-theme` from `main.ts`; a forced theme flashes on load, accepted.

| URL | kind | content |
|---|---|---|
| `/` | prerendered | search hero; the one-line CLI install (Q7); a search preview; Featured and Recent from `GET /api/v1/home` in fixed-height placeholders; a three-step stepper; "Status: early" |
| `/search?q=` | shell | one row per package: name, latest version, version count, other lines (at most 2), summary, why it matched, up to three matched symbols linking to the reference, a "New" badge and `similar_to` where set (3.6); the ranking explained beside; ten per page, "Show more" up to 200 |
| `/packages/<n>` | shell | metadata; **one install command with copy first**, others under "Other ways"; README; tabs (README, API reference, Versions); side panel with links, licence, keywords, owners, the five newest versions |
| `/packages/<n>/<v>`, `.../versions` | shell | the version page; versions grouped by line (1.5); yanked, tombstoned and outdated-version banners |
| `.../api/...`, `/account`, `/login` | shell | sections 2.4 and 4.4 |
| `/docs/...`, `/llms.txt` | prerendered | docs, the docstring guide, search help, the agent guide (3.4) |

**Featured** is a list of names in the writer's stage settings; **Recent** the last eight published versions. Until
`mopm add` exists the install command is `pixi add mojo-<name>`, with the channel and the `mopm.toml` line under
"Other ways"; `test/layout.test.ts` ties the page to the CLI's command list. Keyboard: `/` or `s`, `f`, `y`, `?`,
`Esc`; copy buttons announce "Copied"; orange is the brand, red only for destructive actions.

**Budgets (enforced in PR 2)**: each route loads only its own modules, and `check-dist` measures each route's import
closure: JavaScript 128 KiB per route, 64 KiB per module, 384 KiB for the tree; CSS a shared `site.css` of 24 KiB
plus one 16 KiB area stylesheet per route. If the landing and package subset of `mock.css` does not fit, the budget
returns to the CEO. Search no longer ships ranking code to the browser.

## 6. Delivery plan

### 6.1 What search and docs need from the Rust API

Not the port itself, only these interfaces from it (Q9):

1. **A Rust workspace in the service tree**, built by Buck2 with komira's Rust toolchain, crates vendored one way. This
   can land before the port (PR V) and the port adopts it. Tantivy pinned to one exact 0.26.x for writer and query
   alike, `default-features = false` with `mmap`, `lz4-compression`, `stopwords` and `stemmer` (no `zstd`, which needs
   a C build script komira's Rust rules do not run); every `build.rs` crate in the closure declared by hand. Tantivy
   0.26.2 declares Rust 1.86; komira has 1.85.0 (Q11, PR V0).
2. ZIP-packaged x86_64 Lambdas, one function per role (query, queue-triggered writer, validator).
3. Routes declared in `spec/api/openapi.yaml`, served by named functions with the shared error envelope and request id.
4. The version and package record types and DynamoDB access as a shared crate, behind traits with in-memory fakes;
   the same for S3 and SQS if the port has them, else `mopm-search` keeps its own object-store trait and fake.
5. A validator hook after the layout check and before `updateVersion`.
6. On the site distribution (Q3), `Cache-Control` honoured for public GETs, the `llms.txt` and `.md` paths routed to
   the API, and a CloudFront invalidation grant for the takedown function.

### 6.2 PRs

One PR each, built and tested by Buck2 targets on remote execution, each naming the mutant that must turn its tests
red ([appendix D](mopm-dev-appendix.md#d-test-plan)). "Port" means it waits for that piece of the Rust API port.

| # | kind | PR | waits for |
|---|---|---|---|
| 0 | site | site/v1 and its Buck2 targets land | |
| 1 | docs | This note and the static mocks | |
| R | release | Release binaries and installer (Q7) | |
| V0 | komira | Rust 1.86 or later in komira's toolchain; mopm moves its komira pin | Q11 |
| V | Rust tree | Workspace skeleton where the API owner agrees, vendored tantivy closure, one smoke test opening an in-memory index | V0, Q9 (location only) |
| 2 | site | Landing and package page build; per-route budgets | 0 |
| 3 | site stack | Go-live: CSP, edge router, headers policies, 403 and 404 to `/404.html` distribution-wide until `/api/*` lands (4.1); the `llms.txt` and `.md` routes come later with the agent-surface PRs (14, 18) | 0 |
| 4a | API | Cookie plumbing, `/me`, sessions, `sessions_not_before` | port (Q9) |
| 4b | API | Web OAuth flow in its own function | port, 4a |
| 4c | API | Invitee index, `inviteOwner`, list and accept | port |
| 5 | site | `/api/*` behaviour, relative `apiBase`, login and account page | 3, 4a, 4b |
| 6 | spec | `spec/mopm-api.md` and `mopm-api-1.json`; `spec/search-api.md` (`mopm-search/v1`, `mopm-package/v1`, `mopm-symbol/v1`, `mopm-resolve/v1`); shared vectors (JSON edge cases, Unicode, fences), contract fixtures | |
| 7 | fixture | `mojo doc` capture: fixture package with non-empty args and a struct with `__init__`; komira's `mojo_doc_json` with a golden | |
| 8 | Rust crate | `mopm-apidoc`: validation, served form, "since", Markdown renderer and sanitiser | 6, 7, V |
| 9 | Rust crate | `mopm-search`: schemas, tokenizer, derivation, groups, ranking, responses, over in-memory indexes; the writer's loop over an object-store trait with a fake | 6, V |
| 10 | API | Layout allows `lib/mojo/<name>.mopm-api.json`, in whichever validator is live | |
| 11 | CLI | `publish` runs `mojo doc`; converter, `[docs]` in the manifest parser and `spec/mopm-toml.md`, `--docs`, `--prefix`, `mopm doc` | 6, 7; 10 deployed |
| 12 | API | Validator checks `mopm-api.json` with crate 8 and stores the served form | port, 8 |
| 13 | API | Search writer, queue and DLQ, takedown function with invalidation, `GET /api/v1/home` | port, 9, 12 |
| 14 | API | Query function: search, package, resolve, `api` lookups, `.md`, `llms.txt` | port, 13 |
| 15 | CLI | `mopm search`, `info`, `api`, `mopm mcp` | 6; 14 deployed to merge |
| 16 | site | Search page | 3, 14 |
| 17 | site | Reference pages | 12, 14 |
| 18 | site | Docstring guide, search help, `/llms.txt` with the recipe | 11 |
| 19 | API | Name similarity at claim (Q10) | port |
| 20 | API | Download counts (Q5) | port, 13 |

Can start now: R, V0, 2, 3, 6, 7, 10, 11; V once Q11 and the workspace location are answered; then 8 and 9 (the
shared crates) with no wait on the port; 15 against fixtures. Waiting on the port: 4a to 4c, 12, 13, 14, 19, 20.
Deployed before the next merges: 10 before 11, 14 before 15 to 17. Deploys stay the CEO's go.

## 7. Questions

**Answered by the CEO (2026-10-15):**

- **Q1, search**: Tantivy, in Rust, in the API's Rust service; indexing at publish time with as much compute as possible
  on the publisher's machine and the new piece merged into the big index on the server. Section 1; the one deviation,
  who builds the segment, is Q8.
- **Q2, docs**: publishers supply their own docs and mopm defines the standard; `mopm publish` runs `mojo doc`
  automatically and packs a versioned `mopm-api.json` with a published schema; any tool emitting it works; no flag in
  the normal path. Section 2.

**Open:**

- **Q3 (API owner): the API on the site host (4.1)**, no distribution-wide error responses, wildcard callback matching
  off, `Cache-Control` honoured for public GETs, `llms.txt` and `.md` routed to the API. **Recommend: yes; switch the
  OAuth setting before PR 4b merges.**
- **Q5 (CEO): download counting** (channel logs without cookies, a daily job, a small cost). **Recommend: yes, after
  PR 16; the boost ships inert until then.**
- **Q7 (CEO): a release binary and a one-line installer** (`curl -fsSL https://mopm.dev/install.sh | sh`, sha256
  checked, binaries on GitHub releases) before the landing page goes live. **Recommend: yes, PR R, beside PR 2; the
  uploads are the CEO's go.**
- **Q8 (CEO): the registry, not the publisher, builds the Tantivy segment.** The publisher runs `mojo doc`, converts
  and checks `mopm-api.json`; the registry validates it and commits the small segment. A client-built segment saves
  about 10 ms per publish and opens crashes, index-wide ranking manipulation and version lock-in (1.1).
  **Recommend: yes.**
- **Q9 (API owner): the interfaces in 6.1**, where the Rust workspace lives, and whether login (4a to 4c) waits for
  the port. **Recommend: agree the workspace location now so PR V lands first and PRs 8 and 9 start; ZIP packaging,
  x86_64; no provisioned concurrency until cold starts show in the logs; build 4a to 4c in Rust after the port's router
  and authenticator, not twice.**
- **Q10 (CEO): similar names at claim (3.6).** **Recommend: refuse confusables; flag one-edit names with `similar_to`
  for 30 days; mark new packages; no manual review queue.** Refusing blocks a publisher outright; flagging only warns.
- **Q11 (CEO, komira's toolchain owner): move komira's Rust from 1.85.0 to 1.86 or later.** Tantivy 0.26.2 needs 1.86;
  the alternative, an older Tantivy, gives up fixes for a toolchain pin. The bump touches every komira Rust target, so
  it is a komira PR with a cached build of the Rust targets. **Recommend: yes, to the newest stable that komira's Rust
  rules build cleanly with.**
