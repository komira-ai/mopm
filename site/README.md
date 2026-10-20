# site

The mopm.dev web site: plain TypeScript compiled by `tsc` to ES modules the browser loads directly. No framework, no
bundler, no runtime dependencies.

The prerendered pages (`/`, `/docs/`, `/docs/<slug>/`, `404.html`) work without scripts; the home page's "Recently
updated" list is the one part a script fills (one `searchPackages?sort=updated` call), and without scripts it
links to the package list instead. Copy buttons are added by the script too, so without it a command is plain text. `/search`,
`/packages/<name>` and `/packages/<name>/<version>` share one shell, `app.html`, which `src/main.ts` fills from one
API call (`src/app.ts` picks the call and the view).

| module | what it does |
|---|---|
| `src/routes.ts` | URL routes, the package name and version grammar, path builders |
| `src/host.ts` | the API and conda channel for the hostname a page is served on (three known hosts, nothing else) |
| `src/api.ts`, `src/errors.ts`, `src/decode.ts`, `src/types.ts` | the read API client: one simple CORS GET per call, error mapping, runtime decoding |
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
| `tools/` | the build (Node, run at build time only): page layout, the home, 404 and shell pages, the docs pages, hashing the assets, and the checks on `dist/` |

## Rules

1. **No runtime dependencies.** `dependencies` stays empty; everything shipped to a browser is code in `src/`.
2. **No HTML sinks.** Markup is built only through `h()` and a `Doc`; no string of HTML reaches the DOM and no string
   runs as code. `test/no-sinks.test.ts` checks the source.
3. **No inline script or style.** The site stack sends a Content-Security-Policy that allows scripts, styles and
   images from `'self'` only, fetches from the stage's API host only, and requires Trusted Types with no policy (see
   "How it is served"); `tools/check-dist.ts` refuses a tree that this policy would break.
4. **One artifact for every stage.** Nothing stage-specific is compiled in: the API host comes from the page's
   hostname (`src/host.ts`).
5. **No live calls in tests.** `test/setup.ts` makes the global `fetch` throw; the client takes `fetch` as a
   parameter, and tests replay the API contract fixtures (`tests/contract/api/` at the repository root).

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
`assets/<id>/`: the modules `main.js` loads and the stylesheets, where `<id>` is a hash of their contents (no clock, no
commit), so the same sources give the same tree and a changed asset gets a new URL. `tools/check-dist.ts` refuses a
tree with a missing page, a dangling asset or import, markup its tag scanner cannot read as a browser does (a
comment, a `<` inside a tag, an unclosed tag), a script that is not an empty `<script src="/assets/...">`, a
style element or attribute, an event-handler attribute, a `javascript:`, `data:` or `vbscript:` URL, a file
other than `.html`, `.js` or `.css`, or JavaScript or CSS over its size budget (64 KiB a module and 128 KiB in all for
JavaScript; for CSS, the design note's 24 KiB for the shared `site.css`, 16 KiB for each area stylesheet, and 30 KiB for
the stylesheets one page links together, down from the 32 KiB the single stylesheet had).

Each page links `site.css` and then only its own area's sheet: the home page `home.css`, the docs pages `docs.css`, the
404 page nothing more. The app shell serves search, package and version views from one page and picks the view after
it loads, so it links both `package.css` and `search.css`; one sheet per view would need a script-inserted `<link>` and
a flash of an unstyled view on every load. It is the heaviest page, and the 30 KiB page budget is set over it with room for
its next view's styles.

The home page copy is held to `README.md` and `src/cli/main.zig` by `test/layout.test.ts`: when the list of working
or planned commands changes there, the page has to change too. Route vectors are in `test/fixtures/routes.json`; the
site stack's edge router is tested against the same file. The Markdown attack corpus is `test/fixtures/attacks.md`.

## How it is served

`service/infra/stacks/lib/site-stack.ts` deploys `dist/` (built by `npm run build` here in deploy.yml, or `//site:dist`
with Buck2) to a private bucket behind CloudFront, and refuses to synthesize when `index.html`, `app.html`, `404.html`
or `assets/` is missing. Merging a change under `site/` (or to `spec/mopm-toml.md` or `docs/mopm-test.md`, which the
docs pages are rendered from) starts promote.yml, which deploys it to beta, gamma and prod in turn.

- **Two uploads.** `assets/` goes first, with `Cache-Control: public, max-age=31536000, immutable`, and is never
  pruned: the pages of an earlier release (an open tab, a rollback) still find their assets. The pages (everything
  else) go second, with a short cache (`public, max-age=60, s-maxage=300`); pages that are no longer built are
  removed, and each deploy invalidates the CloudFront cache. Neither upload deletes its objects when its deployment
  resource is deleted, so if the first deploy (the one that replaces the placeholder page) rolls back, the bucket keeps
  the new pages under the old distribution settings (no CSP, router or 404 page): fix forward by deploying again; a
  rollback does not restore the placeholder.
- **Edge router.** A CloudFront Function on viewer-request, generated from the grammar in `src/routes.ts`: `/` is
  `index.html`; `/search`, `/packages/<name>` and `/packages/<name>/<version>` (a valid, normalised name and a valid
  version) are `app.html`; `/docs`, `/docs/` and `/docs/<slug>[/]` are the docs page's `index.html`; a package name
  that normalises to a different valid name gets a 301 to the normalised path, query kept. Everything else goes to
  the bucket as it is.
- **Not found.** A missing key (403 or 404 from the bucket) gets `404.html` with status 404; nothing is answered with
  the home page. These are distribution-wide error responses, an interim choice until the API is served from this
  distribution (`docs/design/mopm-dev.md`, §4.1).
- **Headers.** The CSP `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src
  https://api.<site host>; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none';
  require-trusted-types-for 'script'; trusted-types 'none'`, plus HSTS, `X-Content-Type-Options`,
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cross-Origin-Opener-Policy` and
  `Cross-Origin-Resource-Policy` `same-origin`, and a `Permissions-Policy` that turns off camera, microphone,
  geolocation, payment and USB.
- **Smoke test.** e2e.yml checks the site host after every deploy: the home page and one of its assets, the app shell
  for a package route, a 404 for an unknown file, and the CSP's API host.
