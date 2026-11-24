# site

The mopm.dev web site: plain TypeScript compiled by `tsc` to ES modules the browser loads directly. No framework, and no
bundler or runtime dependency outside the one exception of rule 1, the tutorial's bundle of E2B's SDK.

The prerendered pages (`/`, `/docs/`, `/docs/<slug>/`, `404.html`) work without scripts; the home page's "Recently
updated" list is the one part a script fills (one `searchPackages?sort=updated` call), and without scripts it
links to the package list instead. Copy buttons are added by the script too, so without it a command is plain text.
`/search`, `/packages/<namespace>/<name>` and `/packages/<namespace>/<name>/<version>` share one shell, `app.html`,
which `src/main.ts` fills from one call to the registry API version 2 (`src/app.ts` picks the call and the view).

| module | what it does |
|---|---|
| `src/routes.ts` | URL routes, the namespace, package name and version grammar, full names, path builders, the search a flat address is sent to |
| `src/host.ts` | the API and conda channel for the hostname a page is served on (three known hosts, nothing else) |
| `src/api.ts`, `src/errors.ts`, `src/decode.ts`, `src/types.ts` | the read API client: one same-origin GET per call under `/api/v2`, error mapping, runtime decoding |
| `src/doc.ts` | the Doc port: element and text nodes through a tag and attribute allowlist (`h()`); DOM and string backends |
| `src/links.ts` | URL checking, the only source of `SafeHref` |
| `src/markdown/` | a restricted Markdown parser (linear time) and its renderer, for package readmes and repo docs |
| `src/snippet.ts`, `src/format.ts` | the install lines a page shows; times, sizes and version states as text |
| `src/copy.ts` | the Copy button the page script adds to each command block (`.copy-box`), with a live "Copied" status |
| `src/views/` | the search, package and version views, the home page's recently updated list, and the shared ones (loading, error, not found), built through a `Doc` |
| `src/app.ts` | the app shell's routing: the API call an address makes and the view its answer gives (no DOM) |
| `src/mount.ts` | putting a view on the page (title, focus, noindex, canonical address, Retry) and the home page's conda channel, against the few DOM members it uses |
| `src/enhance.ts` | what the page script adds once a page is on screen: the copy buttons and the home page's recently updated list, against a small DOM port |
| `src/main.ts` | the page script: connects `app.ts`, `mount.ts` and `enhance.ts` to the real document, plus the read-only banner and `/` to focus search |
| `static/` | the stylesheets: `site.css`, shared by every page (tokens, header, footer, buttons, code, cards), and one per area (`home.css`, `package.css` for package and version pages, `search.css`, `docs.css`); `tools/layout.ts` says which page loads which |
| `src/tutorial/gate.ts` | the tutorial's gate: the session, a sandbox and sign-out over the site's own `/api/v2` routes (`credentials: 'same-origin'`, the CSRF header), the sign-in link, and `replayGate`, a fake that replays recorded answers; no page imports it yet |
| `src/tutorial/runner.ts` | the tutorial's runner: from a sandbox grant alone (E2B's `Sandbox` constructor with the sandbox's access token, no API key), writes a lesson's edited files into its directory and runs the lesson's command, giving the exit code and output, or `sandbox_not_running` / `sandbox_unreachable`; bundled with `e2b` into `tutorial.js`, which no page loads yet |
| `src/tutorial/node-stub.ts` | the empty module the bundle gives `e2b`'s six `node:*` imports, which only its template builder uses |
| `tools/` | the build (Node, run at build time only): page layout, the home, 404 and shell pages, the docs pages, hashing the assets, and the checks on `dist/`; `headers.ts`, the security headers the site stack sends; `preview.ts`, the local preview |

## Rules

1. **No runtime dependencies, with one exception.** Everything shipped to a browser is code in `src/`, except E2B's SDK:
   - **which package:** `e2b`, pinned exactly (`2.64.0`), the one entry of `dependencies`;
   - **which file:** it ships only inside `assets/<id>/tutorial.js`, the bundle `tools/build.ts` makes with esbuild (a
     pinned dev dependency) of `src/tutorial/runner.ts`, and only the tutorial pages may load it (`tools/check-dist.ts`
     refuses any other page that does). Every other page loads the `tsc` modules of `main.js`, as before;
   - **why:** the tutorial runs a lesson's code in an E2B sandbox that the browser talks to directly, with the sandbox's
     own access token (`docs/design/tutorial-sign-in.md`, sections 4 and 7). If an upgrade of `e2b` breaks the
     constructor the runner uses, the design's fallback is a small client of the sandbox agent's API in `src/tutorial/`,
     and this exception goes.
2. **No HTML sinks.** Markup is built only through `h()` and a `Doc`; no string of HTML reaches the DOM and no string
   runs as code. `test/no-sinks.test.ts` checks the source.
3. **No inline script or style.** The site stack sends a Content-Security-Policy that allows scripts, styles and
   images from `'self'` only, fetches to the page's own origin and E2B's sandboxes only, and requires Trusted Types
   with no policy (see "How it is served"); `tools/check-dist.ts` refuses a tree that this policy would break.
4. **One artifact for every stage.** Nothing stage-specific is compiled in: the API is read on the page's own origin
   (`/api/v2`), and `src/host.ts` only decides from the page's hostname whether there is an API at all.
5. **No live calls in tests.** `test/setup.ts` makes the global `fetch` throw; the client takes `fetch` as a
   parameter, and tests replay the API contract fixtures of version 2 (`tests/contract/api-v2/` at the repository root).

## Scripts

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck   # src, test (Node + DOM types), then src alone with no Node types
npm test            # jest
npm run build       # compiles src and tools to build/, then writes dist/ (and checks it)
```

On the build farm the same commands are Buck2 targets (`site/BUCK`, run from the repository root), over
`node_modules` laid out from `package-lock.json` and the pinned tarballs of `buildrules.lock.bzl` (buildrules' `npm_package`;
regenerate it with `buildrules npm sync site` after `npm install`, see CONTRIBUTING.md, "The service packages (TypeScript) on
the farm"). The steps are the scripts of `package.json`; the `buildrules` key there names the build output (`dist`) and the `ci` action:

| target | the command it replaces |
|---|---|
| `//site:typecheck` | `npm run typecheck` (both `tsc --noEmit` runs) |
| `//site:test` | `npm test` (`jest --ci`, 2 workers) |
| `//site:build`, `//site:dist` | `npm run build` (the two `tsc -p` runs, then `build/tools/tools/build.js`); `:dist` is its `dist/` |
| `//site:ci` | typecheck, test and build together |
| `//site:check` | `buildrules.lock.bzl` still matches `package.json` and `package-lock.json` (also a validation of every step) |
| `//site:dist_has_pages` | the job's `test -f dist/<page>` checks (`check_dist.js`) |

`dist/` holds `index.html`, `app.html`, `404.html`, `docs/index.html`, `docs/<slug>/index.html` and
`assets/<id>/`: the modules `main.js` loads, the stylesheets and `tutorial.js` (rule 1's bundle: one minified ES module, no
source map), where `<id>` is a hash of their contents (no clock, no
commit), so the same sources give the same tree and a changed asset gets a new URL. `tools/check-dist.ts` refuses a
tree with a missing page, a dangling asset or import, markup its tag scanner cannot read as a browser does (a
comment, a `<` inside a tag, an unclosed tag), a script that is not an empty `<script src="/assets/...">`, a
style element or attribute, an event-handler attribute, a `javascript:`, `data:` or `vbscript:` URL, a file
other than `.html`, `.js` or `.css`, JavaScript that names a source map, `tutorial.js` loaded by a page that is not a
tutorial page (`tutorial.html` or one under `tutorial/`), or JavaScript or CSS over its size budget (64 KiB a module and
128 KiB in all for the `tsc` modules; 320 KiB for `tutorial.js`, `TUTORIAL_JS_MAX_BYTES`, set from its first measurement
of 309,160 bytes; for CSS, the design note's 24 KiB for the shared `site.css`, 16 KiB for each area stylesheet, and 30 KiB for
the stylesheets one page links together, down from the 32 KiB the single stylesheet had).

Each page links `site.css` and then only its own area's sheet: the home page `home.css`, the docs pages `docs.css`, the
404 page nothing more. The app shell serves search, package and version views from one page and picks the view after
it loads, so it links both `package.css` and `search.css`; one sheet per view would need a script-inserted `<link>` and
a flash of an unstyled view on every load. It is the heaviest page, and the 30 KiB page budget is set over it with room for
its next view's styles.

The home page copy is held to `README.md`, `src/cli/main.zig`, `VERSION` and `static/install.sh` by
`test/layout.test.ts`: when the list of working or planned commands, the install command, the release targets and file
names, the verification commands or the version series change there, the page has to change too. The page names the
version series (`0.0.x`), never a patch number, because a release is cut on every merge. Route vectors are in `test/fixtures/routes.json`; the
site stack's edge router is tested against the same file. The Markdown attack corpus is `test/fixtures/attacks.md`.

## Preview

`npm run preview` serves the built site on `127.0.0.1` and plays our side of the tutorial's sign-in and sandbox
routes, so the tutorial pages can be written before those routes are deployed (`docs/design/tutorial-sign-in.md`,
"Running it locally against the stub"). It is a local tool: nothing of it is in `dist/`.

```sh
npm ci --ignore-scripts --no-audit --no-fund && npm run build
npm run preview -- --scenario signed-out        # the session route answers 401 session_required
npm run preview -- --scenario signed-in         # a fixed login and CSRF value; with no key, a sandbox is tutorial_unavailable
E2B_API_KEY=<a key from your own E2B account> \
  npm run preview -- --scenario signed-in --e2b-template base   # creates real sandboxes, internet access off
npm run preview -- --scenario csrf-failed       # the sandbox and sign-out routes answer 403 csrf_failed
npm run preview -- --scenario unavailable       # the sandbox route answers 503 tutorial_unavailable, Retry-After: 30
npm run preview -- --scenario session-expired   # the session route answers 200, then the sandbox route 401
```

It prints its address, `http://127.0.0.1:<port>/tutorial` (the system picks the port), and serves `dist/` there with
the site's security headers (`tools/headers.ts`, the builder the site stack uses), whose `connect-src` is the page's
own origin and `https://*.e2b.app`. It answers `GET /api/v2/auth/web/session`, `POST /api/v2/auth/web/logout` and
`POST /api/v2/tutorial/sandbox` with the contract's statuses and bodies; any other `/api/` path is 404
`route_not_found`. The sandbox and sign-out routes make the real route's checks: no `Authorization` header, a session,
`X-Mopm-CSRF` equal to the session's value, `Origin` equal to the page's origin, `Sec-Fetch-Site: same-origin`, and no
body. A sign-out ends the fake session until the preview is started again. `/tutorial` and `/tutorial/<lesson>` serve
`tutorial.html` once the build has one, and the 404 page until then.

`E2B_API_KEY` is the one setting read from the environment, because it is secret material; the preview sends it to E2B
and never prints or writes it. Get a key from your own E2B account. With it, the signed-in scenario sends E2B the
create call of the design's section 4 (`templateID` from `--e2b-template`, `base` when it is not given, `timeout`
1800, internet access off) and answers what the browser needs to reach that sandbox. E2B's `base` template has no Mojo
toolchain, so run commands such as `echo` or `python3 -c` until the tutorial's own template exists.

## How it is served

`service/infra/stacks/lib/site-stack.ts` deploys `dist/` (built by `npm run build` here in deploy.yml, or `//site:dist`
with Buck2) to a private bucket behind CloudFront, and refuses to synthesize when `index.html`, `app.html`, `404.html`
or `assets/` is missing. Merging a change under `site/` (or to `spec/mopm-toml.md`, `docs/mopm-test.md`,
`docs/why-and-design.md`, `docs/getting-started.md`, `docs/configuration.md`, `docs/examples.md` or `docs/publishing-a-workspace.md`, which the docs pages are rendered from) starts promote.yml, which deploys it to beta, gamma and prod in turn.

- **Two uploads.** `assets/` goes first, with `Cache-Control: public, max-age=31536000, immutable`, and is never
  pruned: the pages of an earlier release (an open tab, a rollback) still find their assets. The pages (everything
  else) go second, with a short cache (`public, max-age=60, s-maxage=300`); pages that are no longer built are
  removed, and each deploy invalidates the CloudFront cache. Neither upload deletes its objects when its deployment
  resource is deleted, so if the first deploy (the one that replaces the placeholder page) rolls back, the bucket keeps
  the new pages under the old distribution settings (no CSP, router or 404 page): fix forward by deploying again; a
  rollback does not restore the placeholder.
- **Edge router.** A CloudFront Function on viewer-request and viewer-response, generated from the grammar in
  `src/routes.ts` and the list of files in `dist/`: `/` is
  `index.html`; `/search`, `/packages/<namespace>/<name>` and `/packages/<namespace>/<name>/<version>` (a valid
  namespace, a valid, normalised name and a valid version) are `app.html`; `/docs`, `/docs/` and `/docs/<slug>[/]` are
  the docs page's `index.html`; a name under a valid namespace that normalises to a different valid name gets a 301 to
  the normalised path, query kept (a namespace is never normalised). A one-segment `/packages/<x>` and a flat
  `/packages/<name>/<version>`, the addresses of the names before namespaces, get a 302 to a search: for the name in
  every namespace, or for a namespace's packages when `<x>` is a namespace and no name (`src/routes.ts`
  `flatSearchPath`). A file of the build goes to the bucket as it is, and so does an asset under an id that is not this
  build's (an earlier build's, which the bucket keeps).
- **Not found.** Anything else (an unknown page, a docs slug with no page, a file the build does not have, including
  one under this build's `assets/<id>/`) is rewritten to `404.html`, and the same function turns that response's 200
  into 404 on viewer-response; nothing is answered with the home page. There are no distribution-wide error
  responses, so the API's JSON errors under `/api/*` reach the browser as JSON. A request for a key that exists in no
  build under an earlier build's id gets the bucket's own 403.
- **API.** `/api/*` goes to the stage's API (`api.<site host>`) over HTTPS, uncached, with every viewer header but
  `Host`, the cookies and the query string, a 30 s origin read timeout, and an `x-mopm-edge` origin header whose value
  is the generated secret `mopm/<stage>/edge-origin`. Its responses get their own headers: `nosniff`, `no-referrer`,
  HSTS and `Content-Security-Policy: default-src 'none'; sandbox; frame-ancestors 'none'`. The pages read the API
  here, on their own host (`src/host.ts` gives the relative `/api/v2`); `api.<site host>` stays as it is for the CLI
  and CI.
- **Headers.** The CSP `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'
  https://*.<E2B domain>; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none';
  require-trusted-types-for 'script'; trusted-types 'none'`, where the E2B domain is the stage's `e2b_domain` setting
  (the `tutorial` block's `e2bDomain`, `e2b.app` by default), plus HSTS, `X-Content-Type-Options`,
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cross-Origin-Opener-Policy` and
  `Cross-Origin-Resource-Policy` `same-origin`, and a `Permissions-Policy` that turns off camera, microphone,
  geolocation, payment and USB.
- **Smoke test.** e2e.yml checks the site host after every deploy: the home page and one of its assets, the app shell
  for a package route, a 404 for an unknown file, and the CSP's `connect-src`.
