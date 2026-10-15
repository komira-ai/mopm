# mopm.dev v2: appendix

The detail behind [mopm-dev.md](mopm-dev.md). Section letters: A search, B API reference, C login, D test plan.
Anything marked **unverified** has not been checked against code, docs or a run. `spec/search-index.md` (PR 6)
becomes the normative copy of section A.

## A. Search

### A.1 Document and tokenizer

| field | source | indexed as | cap |
|---|---|---|---|
| `name` | package name | exact, prefix and typo matching (name shards); its `_`-separated parts as terms | 64 chars |
| `summary` | latest version's `description` (`display.ts`) | terms | 512 chars |
| `keywords` | latest version's `keywords` | terms | 10 x 32 |
| `symbols` | exported names from the stored `apidoc/.../index.json` (B.2) | terms: the whole name and its camelCase and snake_case parts | 2,000 names |
| `readme` | latest version's `readme`, Markdown stripped | terms, stopwords removed | 500 most frequent terms |
| `owners` | `listOwners` (public: `security: []`) | display only | 20 |
| `platforms` | subdirs of `files[]` | display only | 4 |
| `updated_at` | latest version's publish time | recency boost | |
| `downloads_30d` | none today; 0 until Q5 | popularity boost | |

The summary comes from the latest version rather than `PackageRecord.description`: nothing in production calls
`createPackage` and `claimPackage` is not implemented, so that field carries no maintained text.

**Tokenizer** (one implementation, shared by the writer, the browser and the API): Unicode NFKC, lowercase, split on
anything outside `[a-z0-9_]`, then split each token on `_` and on camelCase boundaries (camelCase is detected before
lowercasing) and keep both the whole token and its parts. Terms shorter than 2 or longer than 32 characters are
dropped. No stemming: it surprises in identifier-heavy text, and a stemmer is code we would own forever. About 30
English stopwords apply to the README field only. The README is stripped by a Markdown module shared with the site
that imports nothing from `doc.ts`.

### A.2 Index format

All files are JSON, compressed by CloudFront at the edge, in the `site-data` bucket:

```
search-index/v1/manifest.json                     # max-age=60; names the live generation
search-index/v1/home.json                         # max-age=60; Featured and Recent for the landing page
search-index/v1/g/<generation>/names/<prefix>.json  # [name, docId] pairs, sorted by name
search-index/v1/g/<generation>/t/<shard>.json       # term shards
search-index/v1/g/<generation>/d/<chunk>.json       # doc table, 128 docs per chunk
```

- **Generation id**: the first 32 hex digits of SHA-256 over the generation's sorted (path, bytes) pairs. Content
  derived, so identical inputs give the same id, and not guessable without having read a manifest. `built_at` lives
  only in the manifest, outside the hashed bytes. Files under `g/` are served `public, max-age=31536000, immutable`.
- **Manifest**: `{format: 2, generation, built_at, doc_count, names: [prefix...], shards: [first term of each
  shard...], chunks, chunk_size: 128}`. A client finds a term's shard by binary search over `shards`.
- **Term shard**: `{"<term>": [df, docDelta, fieldMask, impact, docDelta, fieldMask, impact, ...]}`. `df` is the
  true document frequency, even when the list is capped. Postings are sorted by doc id and delta-encoded.
  `fieldMask` has one bit per field: name parts, keywords, summary, symbols, readme. `impact` is an integer from 1 to
  65,535 (A.4). A term never spans shards. The writer splits a shard over 32 KiB compressed and merges neighbours
  under 8 KiB.
- **Posting caps**: a term found in the README of more than 25% of documents is dropped from the README field as a
  frequency stopword. Any posting list is capped at 5,000 documents, keeping the highest impacts. A consequence,
  shared by the site and the API: an AND query with a capped term can miss a document whose impact for that term
  fell below the cut. At the 20,000-package ceiling, the cap is a quarter of the catalogue.
- **Name shards** start as one file (`names/_.json`). A shard over 32 KiB splits by first character, then by the first
  two. Typo matching reads every name shard for the query's first character: at most about four at 20,000 packages
  (an estimate; skew such as many names starting `mojo` is why the two-character split exists).
- **Doc chunks**: by doc id, 128 per file. Each doc holds its name, latest version, summary cut to 200 characters,
  `updated_at` (day), platforms, up to three owners plus a count, and a yanked flag. Chunk 0 holds the 128 highest
  static ranks and is preloaded.
- **Atomic publication and retention**: the writer writes the generation, then `manifest.json` and `home.json`. It
  then deletes every generation except the live one, the two before it and any written in the last 10 minutes. After
  a rebuild caused by a takedown it deletes every generation but the live one. A client that gets a 404 for a shard
  fetches the manifest again once and retries. S3 lifecycle expiry is not used: it counts from each object's
  creation, so a week with no publish would delete the live generation.

### A.3 Byte budgets

Assumptions (estimates, enforced as byte counts by PR 7's synthetic catalogue): about 400 unique terms per package; 4
to 6 bytes per compressed posting (delta, mask and impact, plus the term key that rare terms pay for); shards filled
to about 69% of 32 KiB (about 22 KB) by split-on-overflow; about 100 bytes per doc in the doc table (12.5 KB per
chunk); about 15 bytes per name.

| packages | postings | term shards | doc chunks | names | manifest (compressed) | whole index |
|---|---|---|---|---|---|---|
| 1,000 | 0.4 M (1.6-2.4 MB) | 75-110 | 8 (0.1 MB) | 15 KB, 1 file | ~1-2 KB | ~2 MB |
| 10,000 | 4 M (16-24 MB) | 730-1,100 | 79 (1 MB) | 150 KB, ~36 files | ~4-6 KB | ~16-25 MB |
| 20,000 | 8 M (32-48 MB) | 1,450-2,200 | 157 (2 MB) | 300 KB, ~40-70 files | ~8-11 KB | ~35-50 MB |

**First query, worst case**: the manifest, one name shard (at most 32 KB), up to five term shards (four terms plus a
second shard for the last term's prefix range, at most 160 KB) and the doc chunks of its first ten results (at most
ten chunks at 12.5 KB; chunk 0 is already loaded). About 250 KB at 1,000 packages, 300 KB at 10,000 and 310 KB at
20,000. Typical queries cost less, because popular results sit in the low chunks.

**Why there is no 100,000-package row**: at that size the manifest alone would be 60 to 100 KB raw (some 5,500 to
9,000 shard keys), over the 16 KB trigger, and the catalogue would be five times past the 20,000-package ceiling at
which the site switches to the API mode (mopm-dev.md, 1.7).

**Rebuild cost** at 10,000 packages: about 10,000 DynamoDB item reads, up to 10,000 S3 reads of `index.json`, and about
1,000 S3 writes per generation (a fraction of a cent). A rebuild holds the postings in memory: about 4 M postings, a
few hundred MB in a Lambda with 2 GB.

### A.4 Ranking arithmetic

The writer computes, once per generation, for each term `t` and document `d` (k1 = 1.2, b = 0.75):

```
tf'(t,d)    = sum over fields f of  w_f * tf_f(t,d) / (1 - b + b * len_f(d) / avglen_f)
w_f         = name parts 10, keywords 5, summary 3, symbols 2, readme 1
idf(t)      = ln(1 + (N - df(t) + 0.5) / (df(t) + 0.5))
boost(d)    = (1 + 0.15 * log10(1 + downloads_30d(d))) * (1 + 0.10 * exp(-age_days(d) / 180))
impact(t,d) = clamp(round(1000 * idf(t) * tf'(t,d) * (k1 + 1) / (tf'(t,d) + k1) * boost(d)), 1, 65535)
```

- `age_days` counts from `updated_at` to the generation's `built_at`, on the writer's clock only, so a reader's clock
  never enters. Floating point runs once, in the writer; the browser and the API only add integers, so every reader
  gives the same order (the earlier draft scored with `Math.log` and `Math.exp` on both sides, whose results
  ECMAScript lets implementations approximate differently).
- The boost is not capped: 1,000,000 downloads gives 1.9x and 10,000,000 gives 2.05x. Recency adds at most 10%.
  Folding the per-document boost into each term's impact is exact: the boost multiplies the sum.
- **Score** of `d` for a query: the sum over query terms of the term's impact in `d`. For the last term, also
  matched as a prefix, the contribution is the maximum over its completions, where a completion other than the exact
  term counts `impact * 7 / 10`, rounded down in integers.
- **Completions** of the last term (at least 3 characters): vocabulary terms that start with it, from the shard that
  holds the prefix and, when the range continues, the next one (at most two shards). At most 20, by `df` descending,
  then byte order; the exact term, when present, is always one of them at full weight.
- **Groups 3 to 6**: field classes are A (name parts, keywords, summary), B (symbols) and C (README). A term's best
  class is the best class set in its `fieldMask` (for the last term, the best over its completions). A document
  satisfying AND goes to group 3, 4 or 5 according to the worst best class over the query's terms (A, B or C). Group 6
  (OR) exists only when groups 3 to 5 are empty.
- **Order**: group ascending; in group 1 shorter name, in group 2 smaller edit distance, in groups 3 to 6 higher
  score; then doc id ascending. A document appears once, in its best group. The order is total, which the shared
  vectors (A.5) rely on.
- **Typo matching** (group 2): optimal-string-alignment Damerau-Levenshtein (insert, delete, substitute, swap two
  neighbours) in a band of width `2k + 1`, with an early exit once a whole row exceeds `k`; a candidate whose length
  differs by more than `k` is skipped before any work. `k` is 0 for 1 to 3 characters, 1 for 4 to 7, 2 for 8 or more;
  the first character must match. A typo match never enters groups 0 or 1, and never satisfies a term for AND.

### A.5 The API mode

- `searchPackages` gains an optional query parameter `match`, enum `[prefix, text]`, default `prefix`; existing
  callers see no change.
- With `match=text`: `q` is required (1 to 64 characters), `sort` must be absent, results come in ranking order, and
  each `PackageSummary` gains an optional `matched` array naming the fields that matched. `limit` stays at most 100.
  `next_cursor` encodes the generation and an offset; a cursor from an older generation gets `invalid_request` with a
  new code, `cursor_stale`. Results stop at 200, on the API and on the site.
- The API Lambda reads the same files from `site-data` (a read grant on `search-index/*`), caches shards by
  generation and checks the manifest at most once a minute. The last term is always matched as a prefix (A.4), so the
  API and the site agree for the same `q`.
- There is no `mopm search` command in `src/cli/` today. When one is written it calls `match=text`.
- **Client loading**: when the search box gets focus (or `/` is pressed), the client prefetches the manifest and doc
  chunk 0; the first keystroke fetches the name shard; term shards are fetched in parallel as terms are typed and kept
  for the page's lifetime. Typing is debounced by 80 ms. Targets, not gates: ranking 10,000 documents under 8 ms once
  shards are loaded (PR 7 gates an operation count instead), and a first query in two round trips. Without
  JavaScript the form submits to `/search?q=`, whose shell needs scripts; its `<noscript>` text links to the package
  list.

### A.6 Alternatives rejected

| alternative | why not |
|---|---|
| DynamoDB `contains` filters or scans | full scans per query; no ranking; cost grows with the catalogue |
| A hosted search service (OpenSearch, Algolia, Typesense) | servers or a third party to run and pay for; a third-party `connect-src`; different results per stage unless each stage gets one |
| A JavaScript search library (lunr, MiniSearch, FlexSearch) | breaks the no-runtime-dependency rule, and the API would need the same library to agree |
| SQLite in WebAssembly over HTTP range requests | a runtime dependency plus `'wasm-unsafe-eval'` in the CSP |
| A static-site search generator with its own client | a binary build tool and a client we do not own |
| One monolithic index file | grows linearly: 16 MB or more at 10,000 packages |
| Client-only search with no API mode | the CLI and the site would rank differently |
| Floating-point scores computed by each reader | engines may round `Math.log` and `Math.exp` differently, and a reader's clock skews recency |
| A per-version search document stored at publish | a second copy of public text with its own deletion duty; the version record already holds the README |

### A.7 The writer

- **Queue**: `search`, FIFO with one message group, so one rebuild runs at a time. Its event source mapping takes up
  to 10 messages per batch, an explicit, commented exception to `publish.test.ts`'s `BatchSize === 1` assertion: a
  rebuild covers the whole catalogue, so a batch of ten is one rebuild. While a message of the group is in flight SQS
  hands out no other message of that group, so a rebuild cannot drain the queue itself; batching is what coalesces.
- **Senders**: the validator's `sendIndex`, which both the first pass and the retry pass (`status === 'indexing'`)
  call, with dedup id `<publish_id>:search` (sending from `moveToIndexing` alone would lose the message if the Lambda
  died between the state change and the send); `setYanked`, with a dedup id carrying the record's `rev`; and the
  takedown function, on every transition to `tombstoned`.
- **Inputs**: the DynamoDB version records (description, keywords and README, at most `README_MAX_BYTES` = 65,536,
  already stored on the version item) and each latest version's `apidoc/v1/<name>/<version>/index.json`. The earlier
  draft's per-version documents in S3 are dropped: the README premise behind them was wrong, they needed a backfill,
  and they were a second public copy with its own deletion duty.
- **Output and retention**: A.2. The writer takes the clock as an input, so the same inputs and clock give
  byte-identical files and the same generation id.
- **Grants**: read the version and package tables and the owners index; read `apidoc/*`, write and delete
  `search-index/*` in `site-data`. The takedown function alone may invalidate paths on the site distribution.
- **Cost and time**: A.3. The 60 s target at 10,000 packages is measured on a synthetic catalogue, not gated, because
  in-memory runs do not measure the DynamoDB and S3 I/O that dominate it; PR 6 gates operation counts.

## B. API reference

### B.1 What `mojo doc` emits

Known from real 1.0.0 output (komira's `tools/build/examples/hellopkg_doc.json`, the golden of its `mojo_doc_json`
rule) and the 1.0.0 man page:

- one JSON document for a directory: `{decl: <package>, version}`; packages hold `modules[]` and nested `packages[]`;
  modules hold `aliases`, `functions`, `structs`, `traits`;
- functions carry `overloads[]`, each with a flat `signature` string, `summary`, `description`, `args[]`,
  `parameters[]`, `returns`, `raises`, `raisesDoc`, `constraints`, `deprecated`;
- the compiler parses the docstring's first sentence and its `Args:`, `Parameters:`, `Returns:`, `Raises:` and
  `Constraints:` sections into those fields; everything else, including `Examples:` and fenced code, stays Markdown in
  `description`;
- structs and traits carry `parentTraits[].path` (also read by komira's knowledge-graph deriver);
- there are no source locations and no record of re-exports; names starting with `_` are already left out.

**Unverified**, settled by PR 8's golden before the converter is written: the fields of an argument (the golden's
`args` list is empty, so `name`, `type`, `path`, `convention` and `passingKind` are not shown in any real output);
whether decorators are emitted (the mock shows none); the full struct, trait and field shape; whether empty `default`
and `traits` are omitted; whether `%#` example lines are stripped; the parametric alias type gap reported upstream;
what `--docs-base-path` does to `path`.

### B.2 Conversion checks

The publish is refused with `api_doc_invalid` when any of these fail:

- raw file at most 4 MiB; JSON nesting depth at most 64;
- the top-level package `name` equals the package name;
- every package and module path component matches `[A-Za-z_][A-Za-z0-9_]*`, at most 128 characters (so `..`, `/`,
  `%2e%2e`, a backslash or a bidirectional control cannot reach a storage key, a route or a link);
- at most 5,000 symbols, 32 KiB of docstring per symbol, 4 KiB per signature, 8 levels of subpackages.

Not refusals:

- an unknown top-level compiler `version`: the version gets no reference and a note;
- a symbol name outside the grammar (a backtick identifier): left out of the reference, counted, and shown as "N
  symbols not shown"; it never becomes a path or an id;
- declarations starting with `_` are dropped, except a struct's dunder methods; the `__init__` module is not dropped,
  it is the package overview.

Converted output: `index.json` at most 256 KiB, each module file at most 512 KiB, 2 MiB per version. Each subdir's
archive may carry its own file; the validator stores each distinct one once (by sha256) and records which subdirs
have which. Objects are written create-only, as `application/json`, before `updateVersion` marks the version
published; a validator retry of an already published version never rewrites them.

**Rendering rules the converter's output assumes**:

- Every docstring-derived field (`summary`, `description`, `args[].description`, `returns`, `raisesDoc`,
  `constraints`, `deprecated`) goes through the restricted Markdown renderer, or is shown as plain text.
- Signature tokens are always text. An example's info string becomes text, never a class name. The lexer uses a fixed
  set of class names.
- Symbol anchors come from a typed builder (`s-` plus the grammar-checked name); each rendered docstring gets its own
  heading-id prefix (`d<n>-`), so a docstring heading can never equal a symbol anchor or clobber a DOM global; copy
  targets get ids from a site counter.
- The tags and attributes new to the `Doc` allowlist (`details`, `summary`, `select`, `option`, `dialog`,
  `data-copy-target`) are added explicitly, each with a test.

### B.3 Type linking and paths

The converter turns each `signature` into tokens `{k: "kw"|"name"|"type"|"punct"|"text", s, ref?}`. A type token gets
a `ref` only when it resolves exactly, in this order:

1. the `path` the JSON gives for the head type of an argument, parameter or return;
2. the package's own symbol table, by simple name, when the name is unique in the package;
3. the name-to-path map built from every `path` seen in the same document.

A `ref` under the package links within the version. A `ref` under a dependency named in the version's `mojoDeps` links
to that package's latest reference at the same path, falling back to its module page. A `ref` under the standard
library (`/std/...`) stays plain text with the path in a `title`. An ambiguous or unresolved name stays plain text.

Every URL and storage key is built from components that passed the B.2 grammar, by builders in `src/routes.ts` (and
their twin in the converter) that apply `encodeURIComponent` to each component. No URL comes from the JSON.

### B.4 "Since" markers

The validator computes them at publish against the stored `index.json` of the **greatest earlier version** in version
order (published or yanked, not tombstoned): a symbol or overload absent there gets `since` = this version; one
present inherits its marker; if the earlier version has no reference, `since` stays unset and nothing is shown.
Identity is the module path plus the name and, for overloads, the normalised signature. A version published out of
order (1.2.5 after 2.0.0) is compared with 1.2.4. The marker is fixed at publish. Author-written `sinceVersion` text is
ignored in favour of the computed one. The validate queue is grouped per package, so markers are computed in order.

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
| A tombstoned package still served | the takedown function (mopm-dev.md, 1.6) |
| Path traversal through module or symbol names | the B.2 grammar and the B.3 builders |
| Session cookies in logs | standard logs on the site distribution stay off; download logs (Q5) are on the channel distribution, with cookie logging off |

### C.3 Headers and CSP

The page CSP for v2 (site/v1's plan, with `connect-src 'self'` and one image origin added):

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' <GitHub's avatar origin>;
connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none';
require-trusted-types-for 'script'; trusted-types 'none'
```

Response headers policies on the new behaviours: `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`
and HSTS on `/api/*`, `/search-index/*` and `/apidoc/*`; on the two JSON paths also
`Content-Security-Policy: default-src 'none'; sandbox; frame-ancestors 'none'`. The API itself sets
`Referrer-Policy: no-referrer` and `Cache-Control: no-store` on the callback and `/me`. The writer and the validator
write every `site-data` object with `Content-Type: application/json`.

The `site-data` bucket belongs to the publish stack. Its policy lets the site distribution read through origin access
control, with an `aws:SourceArn` condition naming that distribution, whose id comes from a stage setting rather than a
CDK reference between stacks (a reference would make the two stacks depend on each other). Until the setting is filled
after the site stack's first deploy, the two paths answer 403 and the site shows search as unavailable. Whether CDK
accepts this arrangement without an override is **unverified**; PR 3 settles it.

## D. Test plan

Every PR's tests run as Buck2 targets on remote execution. The mutant is the planted defect that must turn the named
test red before the PR is ready.

| # | tests (and mutant) |
|---|---|
| 0 | site/v1's existing tests and targets |
| R | the installer checks the binary's sha256 (mutant: skip the check; a tampered fixture binary must be refused); an unknown platform is refused with a message |
| 2 | layout: one `h1`, landmarks, install block before the README (mutant: README first); copy buttons have no inline handler (mutant: `onclick`); dialog content prerendered; `check-dist` per-route closures (mutant: a route over 128 KiB; a 25 KiB `site.css`); the home page's placeholders have fixed heights |
| 3 | router vectors give the 404 page outside the grammar (mutant: pass-through); no `CustomErrorResponses` (mutant: add one); the exact CSP per stage; each new behaviour has its headers policy (mutant: drop it from `/apidoc/*`); the `site-data` policy names only the site distribution (mutant: a wildcard source); the channel distribution has no origin for `site-data` |
| 4a | contract fixtures for `getMe`; the cookie never accepted on publish (mutant: accept it); an invalid `Authorization` with a valid cookie refused (mutant: fall back); two session cookies refused; revoke-all leaves API tokens (mutant: revoke every kind); a session issued before `sessions_not_before` refused while the listing index lags (mutant: an eventually consistent read) |
| 4b | a fake GitHub; a replayed callback refused (mutant: drop the `consumed_at` condition); a state mismatch refused; the `return_to` corpus (`//x`, `/\x`, `%2F%2Fx`, control characters, 257 characters) becomes `/account` (mutant: allow `//`); CSRF: missing header, wrong Origin, `text/plain` body each refused; start refused for `Sec-Fetch-Site: cross-site` (mutant: drop the check); the authorize URL carries S256 and `prompt=select_account` (mutant: drop `prompt`); `redirect_uri` comes from the setting with a forged `Host` (mutant: build it from `Host`); only the auth function holds the secret grant (stack test) |
| 4c | listing by invitee uses the new index and the API role still has no Scan grant (`api.test.ts`); accept makes the caller an owner; an expired invitation refused |
| 5 | the `/api/*` behaviour has caching off and does not forward `Host` (mutant: forward it); the secret is shown once and gone after `pagehide` (mutant: keep it in history state); a stale session shows "Confirm it's you"; token creation sends JSON with the CSRF header (mutant: a form post) |
| 6 | the same inputs and clock give byte-identical generations and the same id; the manifest is written last (mutant: manifest first, caught by a reader between writes); a yank removes the version from the next generation; a tombstone removes it, deletes its `apidoc/` prefix and invalidates (mutant: no `search` message on tombstone); eight quiet days keep the live generation (mutant: age-based deletion); the validator's retry pass sends `search` (mutant: send only from `moveToIndexing`); an all-tombstoned package has no entry; `home.json` excludes yanked versions; synthetic 10,000- and 20,000-package catalogues within A.3's byte budgets; operation counts |
| 7 | shared vectors run by both test targets; adapter mutants: query normalisation (drop the space-to-`_` rule), prefix expansion off in the API, a 201st result returned, a cursor offset off by one; group order (mutant: swap groups 2 and 3); typo bounds (mutant: `k = 2` at 4 characters); a typo match never satisfies AND (mutant: let it); near-tie vectors that only integer scoring orders stably; `cursor_stale`; first-query bytes at most 320 KB on the 20,000-package catalogue |
| 8 | komira's `mojo_doc_json` rule with `golden=`: red from the first build on any byte change; the fields the converter reads are present |
| 9a | the layout accepts `lib/mojo/<name>.api.json` only beside a `.mojoc` of the same subdir (mutant: accept it anywhere) |
| 9b | the CLI packs the file only when `--api-json` is given (mutant: always pack); `<subdir>=` pairing with `--mojoc` |
| 9c | goldens in, converted files out; each cap refused just over its limit (mutant: off by one); an unknown compiler version publishes without a reference; the path corpus (`..`, `/`, `%2e%2e`, a backslash, bidi characters, `pkg/../other`) refused (mutant: a prefix check); a backtick symbol left out and counted; since markers over a three-version history with an out-of-order publish; `apidoc/` objects are create-only (mutant: overwrite on retry) |
| 10 | views over the converted golden; type links only for resolved refs (mutant: link unresolved names); the docstring attack corpus through the renderer; a docstring heading equal to a symbol anchor stays distinct (mutant: unprefixed ids); setup lines copied only when shown (mutant: copy hidden lines); bidi markers visible; the version switcher's fallback chain |
| 11 | the existing docs test |
| 12 | aggregation over fixture log lines: 200 and 206 counted, 304 not; the log configuration excludes cookies (stack test) |
