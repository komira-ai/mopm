# mopm.dev v2: search, API reference and web login

Status: proposal, for review. **The CEO confirms the search approach (Q1)** and answers Q2, Q5 and Q7 before any of
it is built; the API owner confirms the service changes (sections 1.5, 2.1 and 3; Q3).

Written against `main` and the unmerged `site/v1` branch; file references are paths in this repository. Anything
marked **unverified** has not been checked against code, docs or a run. The detail (index format, ranking arithmetic,
byte budgets, the login callback, threats, the per-PR test plan) is in [mopm-dev-appendix.md](mopm-dev-appendix.md).

## Decisions at a glance

| area | decision |
|---|---|
| Search | A static index sharded by term, rebuilt by the registry after every publish, yank and takedown, served same-origin from the CDN. The browser ranks with in-house code; the API serves the same ranking from the same files (`searchPackages?match=text`), so the CLI and the site agree. Good to about 20,000 packages; past that the site uses the API mode. |
| Ranking | The brief's order as strict groups: exact name, name prefix, name with a small typo, keyword or summary, symbol, README. Within a group, a precomputed integer score, then a fixed static rank: every browser and the API give the same order. |
| API reference | The publisher supplies `mojo doc` JSON (new `mopm publish --api-json`); the registry validates it, converts it once into mopm's own format and stores it per version; the browser renders Dokka-style pages from it. Docs are publisher-attested, not registry-verified (Q2). |
| Login | GitHub OAuth with PKCE. `/api/*` is served on the site host, so the session is a `__Host-` HttpOnly cookie that never reaches `api.<site>` and needs no credentialed CORS. Every web login shows GitHub's account picker. |
| Takedown | A tombstoned version leaves search, the stored reference and the landing page at the next rebuild, and the CDN copies are invalidated (1.6). |
| CLI install | The landing page leads with one install line; that needs a release binary and an installer, which do not exist yet (Q7). |
| Questions | Q1 search approach; Q2 publisher-supplied docs; Q3 API on the site host; Q5 download counting; Q7 release binary and installer. |

## Goals and non-goals

Goals: (1) **sign in with GitHub** in the browser and manage the account: profile, API tokens (secret shown once), my
packages and their owners, invitations, sessions, sign out everywhere; (2) **a landing page worth looking at**: a large
search box, a one-line CLI install, featured and recent packages, a three-step quickstart, prerendered, no layout
shift, dark mode, keyboard-first; (3) **real search** over name, summary, keywords, README and exported symbols, typo
tolerant on names, ranked the same by the site and the API; (4) **a package page** that leads with one copyable install
command, then the README, then an API tab; (5) **API reference pages in the Dokka/KDoc style**: module tree, symbol
filter, members table, signatures with linked types, parsed docstrings, copyable examples, "since" markers, a version
switcher, an anchor on every heading.

Non-goals for v2: a search server (1.7 says when); running code in the browser; running `mojo doc` in the registry
(2.1); download counts (Q5; nothing records downloads, so the mocks show none); search filters or sort options (by
platform, licence or downloads); a site-wide symbol search (a symbol match finds its package, whose reference has the
symbol filter); source links in the reference (`mojo doc` emits no source locations); docstring coverage figures;
owner management on the web (it stays in the API and CLI); changing the CLI's device login or the publish
authorization rules.

## What exists today

`site/` on branch `site/v1` (reviewed, **not merged**, no PR yet) is plain TypeScript compiled by `tsc` to ES modules:
no framework, no bundler. Prerendered pages work without scripts; `/search` and `/packages/...` share one shell. Every
DOM write goes through the `Doc` port (a tag and attribute allowlist), links through `SafeHref`, READMEs through a
restricted Markdown renderer. Its Buck2 targets exist only on that branch, and the site stack's go-live (PR 3) serves
the site build behind a CSP, an edge router and, for now, distribution-wide 404 responses (3.1). `dist/` has 86,990
bytes of JavaScript, all loaded by every page; `tools/check-dist.ts` sums all `.js` against 128 KiB and all `.css`
against 16 KiB.

The five rules bind everything below: (1) no runtime dependencies; (2) no HTML sinks, markup only through `h()`;
(3) no inline script or style, CSP `'self'` with Trusted Types; (4) one artifact for every stage, nothing stage-specific
compiled in or fetched at build time; (5) no live calls in tests, which replay `tests/contract/`.

## The mocks

Static pages in [mock/](mock/) ([what they are and how to view them](mock/README.md)): illustrative data, no
JavaScript. Every element traces to a section of this note.

| page | light | dark | mobile | sections |
|---|---|---|---|---|
| Landing | [index-light](mock/screens/index-light.png) | [index-dark](mock/screens/index-dark.png) | [index-mobile](mock/screens/index-mobile.png) | 4, Q7 |
| Package | [package-light](mock/screens/package-light.png) | [package-dark](mock/screens/package-dark.png) | [package-mobile](mock/screens/package-mobile.png) | 4 |
| Search | [search-light](mock/screens/search-light.png) | [search-dark](mock/screens/search-dark.png) | | 1.3, 1.4, 4 |
| API reference | [reference-light](mock/screens/reference-light.png) | [reference-dark](mock/screens/reference-dark.png) | | 2.3 to 2.5 |
| Account | [account-light](mock/screens/account-light.png) | [account-dark](mock/screens/account-dark.png) | | 3.3, 3.4 |

## 1. Search

### 1.1 What is indexed

Each package is indexed from its **latest published version** (not yanked, not tombstoned). A package whose versions
are all yanked keeps a name-only entry (yanked metadata is already public through the API); a package with nothing
published, or only tombstoned versions, has no entry. Indexed: the name (exact, prefix, typo-tolerant, and its
`_`-separated parts), the version's description and keywords, the exported symbol names of the stored reference
(2.2) and the README with Markdown stripped. Shown, not ranked: owners, platforms, latest version, publish time. The
publish time feeds a small recency boost; downloads have a slot that stays 0 until Q5. Fields, caps and the tokenizer:
[appendix A.1](mopm-dev-appendix.md#a1-document-and-tokenizer).

### 1.2 The static index

- **Files**: one mutable `manifest.json` (60 s TTL) naming an immutable **generation** of name shards (exact, prefix
  and typo matching), term shards (term to postings) and a doc table in 128-doc chunks (display fields only).
- **Each posting carries a precomputed integer impact** (field weights, length normalisation and the static boost
  applied), so the browser scores by adding integers from postings alone and fetches doc chunks only for the results
  it shows.
- **Generations** are named by a hash of their content, published by writing the manifest last, and deleted by the
  writer beyond the last three (after a takedown, all but the live one). A lifecycle rule is not used: S3 expiry counts
  from creation, so a quiet week would delete the live generation.
- **Size**: about 16 to 25 MB in all at 10,000 packages and 35 to 50 MB at 20,000; a first query costs at most about
  300 KB (manifest, one name shard, up to five term shards, ten results' doc chunks). Estimates, enforced as byte
  counts by PR 7's synthetic catalogue ([appendix A.3](mopm-dev-appendix.md#a3-byte-budgets)).
- **Served from** a new `site-data` bucket that only the site distribution reads, at `/search-index/*` and
  `/apidoc/*`; never through `conda.<site>`, which caches for a year. Same origin: `connect-src 'self'`, no CORS.
  Format: [appendix A.2](mopm-dev-appendix.md#a2-index-format).

### 1.3 Ranking

Results fall into groups in the brief's order. Groups 3 to 5 need every query term to match (AND).

| group | rule | order within the group |
|---|---|---|
| 0 | the normalised query equals the package name | |
| 1 | the name starts with the normalised query (2 or more characters) | shorter name, then static rank |
| 2 | the name is within a small edit distance of the normalised query (1.4) | smaller distance, then static rank |
| 3 | every term matches the name's parts, the keywords or the summary | score, then static rank |
| 4 | as 3, except that some term matches only a symbol name | score, then static rank |
| 5 | as 4, except that some term matches only the README | score, then static rank |
| 6 | only when groups 3 to 5 are empty: any term matches | score, then static rank |

- Groups 0 to 2 normalise the query as `normaliseName` does, with spaces too (`[-._ ]+` becomes `_`), so
  `http client` finds `http_client` exactly.
- **Score** is the sum of the terms' integer impacts. **Static rank** is the doc id, assigned by downloads, then
  recency, then name. No floating point and no reader clock enters the order.
- The last term (3 or more characters) also matches as a prefix, up to 20 completions, on the site and in the API.
- This **follows the brief**, plus one group: typo matches on names sit below a real prefix and above any text match.
  A strong README match never outranks a weak summary match. Arithmetic:
  [appendix A.4](mopm-dev-appendix.md#a4-ranking-arithmetic).

### 1.4 Typo tolerance

Package names only. Damerau-Levenshtein (with neighbour swaps) against the whole normalised query: 0 edits for 1 to 3
characters, 1 for 4 to 7, 2 for 8 or more; the first character must match. A typo match is a name match (group 2),
never a term match, so it does not satisfy AND in groups 3 to 5.

### 1.5 Writing the index

A third publish queue, `search` (FIFO, one group: one rebuild at a time, up to 10 messages per batch, so bursts
coalesce), is sent from the validator's `sendIndex` (both passes call it), `setYanked`, and every transition to
`tombstoned`. A rebuild reads the current DynamoDB version records (the README is already on the version item) and
each latest version's stored `index.json` for symbols, so no per-version search document is stored and nothing needs a
backfill. It writes a generation, then `manifest.json` and `home.json`; the same inputs and clock give byte-identical
files. Detail, grants and costs: [appendix A.7](mopm-dev-appendix.md#a7-the-writer).

### 1.6 Takedown

`state.ts` lets any version become `tombstoned` (today only a rejected publish does; a takedown route does not exist
yet). Every path to `tombstoned` goes through one function that sends a `search` message (the next generation drops the
version, and the package when nothing published is left), deletes the version's `apidoc/` prefix, and after the
rebuild invalidates those paths and `/search-index/v1/g/*` on the site distribution. The CDN stops serving within that
rebuild; a browser's own cache cannot be recalled. `home.json` excludes yanked and tombstoned versions and is read at
run time, so nothing is baked into the prerendered landing page.

### 1.7 One ranking for site and API; when to move server-side

The ranking code exists once, in `site/src/search/` (no imports outside itself, no Node or DOM types); `service/api`
gets it through a `//site:search_srcs` filegroup copied into its own tree, keeping `dist/index.js` where CDK expects it.
`searchPackages` gains `match` (`prefix` by default, or `text`), additively; results stop at 200 on both sides. The API
adapter (normalisation, prefix expansion, cutoff, cursors) is where the two could drift, so the shared vectors in
`tests/contract/search/` run in both test targets and PR 7's mutants are planted there
([appendix A.5](mopm-dev-appendix.md#a5-the-api-mode)).

**Move server-side** at any of: more than 20,000 packages; a manifest over 16 KB compressed; a synthetic first query
over 320 KB; caller-dependent results. Step one is free: the site calls `match=text`, which reads the same files.
Alternatives rejected: [appendix A.6](mopm-dev-appendix.md#a6-alternatives-rejected).

## 2. API reference

### 2.1 Extraction: the publisher supplies `mojo doc` output

`mopm publish` (`src/cli/publish_cmd.zig`) takes prebuilt files (`--compiler`, `--mojoc [<subdir>=]<path>`), never
compiles and has no source directory; the validator is a Node Lambda with no Mojo. Neither can run `mojo doc`. So:

- **`mopm pack` and `mopm publish` gain `--api-json [<subdir>=]<path>`**, paired with `--mojoc`; the CLI packs the file
  at `lib/mojo/<name>.api.json` only when the flag is given. Buck2 users produce it with komira's `mojo_doc_json` rule;
  others run `mojo doc -o <name>.api.json <source dir>`.
- `validate/layout.ts` allows the path as optional. (A package otherwise carries `.mojoc` files, optional native
  libraries and metadata, never sources.)
- **Delivery order**: the registry accepts the file (PR 9a) and is deployed before the CLI can send it (PR 9b), so a
  new CLI never meets a registry that answers `layout_not_allowed`.
- **The cost (Q2)**: the registry cannot prove the docs match the `.mojoc`; pages say "documentation supplied by the
  publisher". A registry-side job stays possible only if `mojo doc` works on a `.mojoc` (**unverified**).

### 2.2 Validation, conversion and storage

The raw format is documented as subject to change and has no schema version, so **the validator converts it once into
mopm's own format**; nothing else reads the raw form, and drift is confined to one converter pinned by goldens.

- **Refused with `api_doc_invalid`**: oversize or too deep; a package name that differs; any package or module path
  component outside `[A-Za-z_][A-Za-z0-9_]*`. Symbols named outside the grammar (backtick identifiers) are left out
  and counted, never turned into paths. An unknown compiler version publishes without a reference.
- **Stored** create-only, before the version is marked published (a retry never rewrites it): `index.json` (module
  tree, symbols, since markers) and one file per module under `apidoc/v1/<name>/<version>/` in `site-data`, as
  `application/json`, served at `/apidoc/*`.
- Every docstring-derived field is Markdown rendered only by the restricted renderer; signatures are typed tokens,
  always rendered as text.

What `mojo doc` 1.0.0 is known to emit, what PR 8 must still confirm (argument fields, decorators, struct fields), and
the caps: [appendix B.1 and B.2](mopm-dev-appendix.md#b1-what-mojo-doc-emits).

### 2.3 Pages

**Rendering happens in the browser from the stored JSON**, through the `Doc` port: a renderer change applies to every
version at once, at the cost of pages that need JavaScript (the string backend can prerender later). Prerendering at
publish would put a page generator in the publish path and freeze old versions in an old renderer.

Routes: `/packages/<n>[/<v>]/api` (package overview), `.../api/<module path>`, `.../api/<module path>/<Symbol>`.
Layout ([reference mock](mock/screens/reference-light.png)):

- **Left**: a symbol filter (`f`; `fn:` / `struct:` / `trait:` / `alias:` prefixes) over the module tree, grouped by
  kind; sticky from 64rem, a "Contents" disclosure below.
- **Centre**, for a struct or trait: title and badges, signature, docstring and examples, then a **members table**
  (name, signature, summary, since) so the type reads at a glance, then one section per member whose parameters,
  returns and raises open on demand. A module page is a members table.
- **Right** from 84rem: "On this page". **Version switcher**: a `<select>` in a GET form that keeps the symbol and
  falls back to the module, then the package. **Anchors** on every heading; "Copy import path" in the breadcrumb.
- **Badges** in one quiet style: platforms; "since 0.3.0" in grey, highlighted only for the version shown; "supplied
  by the publisher". Kind chips have one hue per kind, none of them the brand orange or the danger red.
- **Type links** only when a type resolves exactly, inside the version or to a `mojoDeps` dependency; standard-library
  and ambiguous names stay text. Every URL is built by `src/routes.ts` from grammar-checked components with
  `encodeURIComponent`; none comes from the JSON ([appendix B.3](mopm-dev-appendix.md#b3-type-linking-and-paths)).

### 2.4 Examples

- Fenced code in a docstring renders as an example block: a title (shown as text), a copy button, the code, and an
  Output panel when an `output` block follows. Examples come before Parameters.
- **The copy button copies exactly what is shown.** `%#` setup lines render collapsed but disclosed ("2 setup lines")
  and are copied only when expanded, so a publisher cannot hide code in what a reader pastes.
- Bidirectional-override and invisible characters show as visible markers in code and signatures.
- Colour comes from a small lexer in `src/` with a fixed set of class names.

### 2.5 "Since" markers and the docstring guide

The validator computes "since" at publish against the stored reference of the greatest earlier version; it is fixed
then, and absent when that version has no reference ([appendix B.4](mopm-dev-appendix.md#b4-since-markers)). A new
page, `/docs/docstrings/`, tells authors how sections, examples, setup lines and `output` blocks appear, which Markdown
renders, that `__init__.mojo`'s docstring is the package overview, and how to produce and check `<name>.api.json`.

## 3. Web login and account

### 3.1 Topology: the API under the site's own host

**Decision (Q3): CloudFront serves `/api/*` on the site host** (`https://mopm.dev/api/v1/...`); `api.<site>` stays as is
for the CLI and CI.

- A new site-distribution behaviour: the stage's API domain as origin, caching off, every header but `Host`
  forwarded, all methods. `apiBase()` becomes the relative `/api/v1` (still one artifact) and `connect-src 'self'`.
- The session cookie is **never sent to `api.<site>`**. No credentialed CORS anywhere. Cookie authentication and
  `/auth/web/*` also require a header only the distribution adds.
- **Each new behaviour gets a response headers policy** (`nosniff`, `no-referrer`, HSTS, and for the JSON paths a
  `default-src 'none'; sandbox` CSP). The page CSP and the bucket policy: [appendix C.3](mopm-dev-appendix.md#c3-headers-and-csp).
- **No distribution-wide error responses** (they would turn the API's JSON errors into HTML): the edge router serves the
  404 page outside the route grammar (**unverified** that a CloudFront Function can return the whole page; fallback, a
  redirect to `/404`). **Interim:** until the API behaviour lands, go-live maps 403 and 404 to `/404.html` (status 404)
  for the whole distribution, which serves only the bucket today; the PR that adds the API behaviour removes them and
  has the edge router answer 404. Each stage's OAuth app gets the exact callback, wildcard off; PKCE is what stops a
  stolen code.

**Rejected: the browser calls `api.<site>` with credentials**: credentialed CORS with POST, DELETE and custom headers
on every route, the CLI's included; one later mistake there exposes sessions.

### 3.2 Endpoints, cookies and CSRF

New, all under `/api/v1` and additive in the spec: `GET /auth/web/start` and `/auth/web/callback`, `POST
/auth/web/logout`, `GET /me` (the spec's `getMe`), `GET`/`DELETE /me/sessions`, `POST /me/sessions/revoke-all`, and the
spec's invitation routes (3.3); `/me/tokens` also accepts the cookie. The table, the callback's steps and the plumbing
are in [appendix C.1](mopm-dev-appendix.md#c1-endpoints-callback-and-plumbing). The rules that matter:

- **Start** only as a top-level navigation from this site (`Sec-Fetch-*`), rate-limited; `state`, S256 PKCE, the
  exact `redirect_uri` and always `prompt=select_account`. The login row is consumed once, atomically.
- **`__Host-mopm_session`**: `Secure; HttpOnly; Path=/; SameSite=Lax`, 7 days absolute; a new login revokes the old
  session. Accepted only on `/me/*` and logout, never on publish or yank; an invalid `Authorization` header is refused,
  never a fallback to the cookie.
- **CSRF** on every cookie request that is not a GET: exact `Origin`, `Sec-Fetch-Site: same-origin`, and an
  `X-Mopm-CSRF` value derived from the session secret. `redirect_uri`, the expected Origin and redirect targets come
  from a stage setting, never from `Host`. `/auth/web/*` runs in its own function, the only one holding the client
  secret.
- **Sign out everywhere** sets the user's `sessions_not_before`, which authentication checks with a strongly
  consistent read: no session survives it. API tokens keep working.
- **Fresh session** (15 minutes) to create or revoke tokens; listing needs only a session. "Confirm it's you" starts a
  login, and GitHub documents that `prompt=select_account` forces its account picker, so script on mopm.dev cannot
  get a fresh session without a click on github.com (that a single-account user must click is **unverified**; PR 4b
  checks by hand).
- **Residual risk**: script on mopm.dev, despite the CSP, Trusted Types and the sink-free renderer, could act inside an
  already fresh window. mopm stores no email address, so there is no creation email; the token list shows each
  token's origin (web or CLI). Threats: [appendix C.2](mopm-dev-appendix.md#c2-threats).

### 3.3 Invitations

The `invitations` table is keyed by `id` only and `inviteOwner` is in the spec but not implemented, so nothing creates
invitations and nothing can list a user's. **PR 4c** adds an index by invitee, `inviteOwner` and the two `/me` routes;
the account page shows Invitations only once 4c is deployed. Declining is letting the invitation expire; v2 has no
decline endpoint.

### 3.4 Account page

**One page, `/account`, in sections** with a section nav ([account mock](mock/screens/account-light.png)): app shell,
`noindex`, redirect to `/login` without a session. `/login` has "Sign in with GitHub" (a link: `form-action 'self'`
would block a form's redirect), what the app can see, and the fixed error messages.

- **Profile**: GitHub handle and avatar (URL built from the numeric GitHub id, never from input).
- **API tokens**: list (name, origin, created, last used, expires); create (name, scopes, packages, expiry), sent with
  `fetch`, a JSON body and the CSRF header, never a form post; revoke. A new secret is shown once in a text node and
  dropped on navigation and `pagehide`.
- **My packages**: latest version and owners, linking to the package page. **Invitations**: Accept (3.3).
- **Sessions**: browser and CLI sessions with Revoke, then **Sign out everywhere**: "Ends every session, in browsers
  and the CLI, including this one. API tokens keep working."

Decided (open in the first draft): listing tokens needs a session, not a fresh one, since it shows metadata only (a
relaxation of a rule in the spec; creating and revoking stay fresh-only). GitHub's avatar origin joins `img-src`,
images only, the CSP's one third-party origin.

## 4. Pages, navigation and budgets

Header: brand, search box (`/` and `s`), Packages, Docs, "Sign in with GitHub" or the account menu. Footer:
repository, security policy, docs, shortcuts. A theme toggle (System, Dark, Light) sets `data-theme` from `main.ts`;
with no inline script a forced theme flashes the system theme on load, which is accepted.

| URL | kind | content |
|---|---|---|
| `/` | prerendered | search hero; the one-line CLI install with copy and a switcher (installer, from source; Q7); a search preview; Featured as a full-width strip and Recent as a list, fixed-height placeholders filled by the client from `/search-index/v1/home.json`; a three-step stepper; "Status: early" |
| `/search?q=` | shell | packages, each with name, version, summary and why it matched (a symbol-name match links to that package's reference, filtered); the ranking explained beside the results; arrow keys and Enter; ten per page, "Show more" up to 200 |
| `/packages/<n>` | shell | title and metadata (version, published, licence, platforms); **one install command with copy first**, others under "Other ways"; README; tabs as links (README, API reference, Versions); one side panel: install again, links, licence, keywords, owners, recent versions |
| `/packages/<n>/<v>`, `.../versions` | shell | the version page and versions table, same tabs; yanked and tombstoned banners |
| `.../api/...`, `/account`, `/login` | shell | sections 2.3 and 3.4 |
| `/docs/...` | prerendered | repository docs, the docstring guide, search help |

- **Featured** is a list of names in the search writer's stage settings, kept by the project lead; hidden when empty.
  **Recent** is the last eight published versions; the two lists do not repeat a package.
- **Install command**: until `mopm add` exists, `pixi add mojo-<name>` (the conda name keeps the import name's
  underscores, `spec/channel.md`), labelled "in a pixi project that lists the mopm channel", with the channel under
  "Other ways". `test/layout.test.ts` checks the page against the CLI's command list, so the PR that adds `mopm add`
  must change the page.
- **Keyboard**: `/` or `s` search, `f` symbol filter, `y` version-pinned address, `?` a prerendered shortcuts
  `<dialog>`, `Esc`. **Copy buttons**: `data-copy-target` ids from a site counter, one delegated listener, "Copied"
  announced; the text label stays on narrow screens.
- **Colour**: orange is the brand (logo, primary button, active tab); red only for destructive actions, one signal
  each; search highlights use one style, match reasons a neutral chip.

**Budgets (decided now, enforced in PR 2)**: each route loads only its own modules (dynamic `import()` per view), and
`check-dist` measures each route's import closure as `tsc` emits it: JavaScript 128 KiB per route (today's whole-site
figure), 64 KiB per module, 384 KiB for the tree; CSS a shared `site.css` of 24 KiB plus one area stylesheet
(`search.css`, `api.css`, `account.css`) of 16 KiB per route. The mock's `mock.css` is about 64 KB for all five
pages, both themes, mock-only chrome and two rounds of overrides; PR 2 measures the landing and package subset, and if
it does not fit, the budget comes back to the CEO before the build-out continues.

## 5. Delivery plan

One PR each, built and tested by Buck2 targets on remote execution; each names the planted defect (mutant) that must
turn its tests red. Test plan: [appendix D](mopm-dev-appendix.md#d-test-plan).

| # | PR | proves |
|---|---|---|
| 0 | site/v1 and its Buck2 targets land | the base exists on `main` |
| 1 | This note and the static mocks | the plan is agreed; the CEO reacts to the mocks |
| R | Release binaries and installer (if Q7 is yes) | the landing page's install line works |
| 2 | Landing and package page build; per-route budgets | install first, the new landing page, within budget |
| 3 | Site stack go-live: CSP, edge router, headers policies, distribution-wide 404 responses until the API behaviour lands (3.1), `site-data` and its two behaviours | the site deploys topology-ready |
| 4a | API: cookie plumbing, `/me`, sessions, `sessions_not_before` | sessions and revoke-all are sound |
| 4b | API: web OAuth flow in its own function | login is single-use, PKCE-bound, redirect-safe, started only by this site |
| 4c | API: invitee index, `inviteOwner`, list and accept | invitations have data behind them |
| 5 | Site: `/api/*` behaviour, relative `apiBase`, login and account page | the browser flow works with no credentialed CORS |
| 6 | Search writer: `spec/search-index.md`, `search` queue and Lambda, takedown function | deterministic, atomic, follows yanks and takedowns |
| 7 | Search page, client ranking, `match=text` | site and API rank identically |
| 8 | `mojo doc` capture: fixture package, komira's `mojo_doc_json` with a golden | the real 1.0.0 JSON shape |
| 9a | Package format spec and layout allow-list for `<name>.api.json` | the registry accepts it (deployed before 9b) |
| 9b | CLI `--api-json` on `pack` and `publish` | publishers can send it |
| 9c | Converter, `apidoc/` storage, since markers | total over the golden; refuses bad input |
| 10 | Reference pages | Dokka-style pages render from stored JSON safely |
| 11 | Docstring guide and search help | the docs render with the restricted renderer |
| 12 | Download counts (after Q5) | counts feed the boost |

Order: 0 first; 3 before 5 and 6; 4a and 4b before 5; 4c before the Invitations section; 6 before 7; 8 before 9c; 9a
deployed before 9b merges; 9c before 10 and before the writer indexes symbols. R, 2, 4a, 6 and 8 can run in parallel.
PR 1 is the mock; PR 2 is purely the build. Deploys stay the CEO's go.

## 6. Open questions

Q4 (listing tokens) and Q6 (avatars) of the first draft are now decisions, in 3.2 and 3.4.

- **Q1 (CEO): confirm the search approach.** A static sharded index rebuilt by a `search` queue, ranked in the browser
  in the brief's order plus a typo group, the same code serving `searchPackages?match=text`, up to about 20,000
  packages. **Recommend: yes, as in section 1.**
- **Q2 (CEO): the publisher supplies the API reference.** The brief had the validator or indexer run `mojo doc`; neither
  the CLI's publish nor the validator can run Mojo. The cost: **docs are publisher-attested, not registry-verified.**
  **Recommend: yes, with `--api-json` (2.1); revisit a registry-side job only if PR 8 shows `mojo doc` works on a
  `.mojoc`.**
- **Q3 (API owner): the API on the site host (3.1)**, no distribution-wide error responses, wildcard callback matching
  off on every stage's OAuth app. **Recommend: yes; switch the OAuth setting before PR 4b merges.**
- **Q5 (CEO): download counting.** Standard logs on the channel distribution (where downloads happen), cookie logging
  off, a daily aggregation job: new infrastructure and a small cost. **Recommend: yes, after PR 7; the boost ships
  inert until then.**
- **Q7 (CEO): ship a release binary and a one-line installer before the landing page goes live?** The brief asks for a
  one-line CLI install first; today the CLI builds from source with Zig, and no PR delivered a binary. **Recommend: yes,
  as PR R, in parallel with PR 2**: binaries for the three CI platforms on GitHub releases and
  `curl -fsSL https://mopm.dev/install.sh | sh`, which fetches the binary for the platform and checks its sha256. The
  uploads are the CEO's go. Until then the landing page shows the source build, labelled.
