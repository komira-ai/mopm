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
3. **No inline script or style.** The site stack, when it is switched to serve this build (a later change), must send a
   Content-Security-Policy that allows `'self'` only;
   `tools/check-dist.ts` refuses a tree that such a policy would break.
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
`node_modules` laid out from `package-lock.json` and the pinned tarballs of `pins.lock.bzl` (see CONTRIBUTING.md,
"The service packages (TypeScript) on the farm"; the site's kpin files are `pins.toml` and `pins.lock.bzl` here):

| target | the command it replaces |
|---|---|
| `//site:typecheck`, `//site:typecheck_browser` | the two `tsc --noEmit` runs of `npm run typecheck` |
| `//site:test` | `npm test` (`jest --ci`, 2 workers) |
| `//site:browser`, `//site:tools`, `//site:dist` | `npm run build`: the two `tsc -p` runs, then `build/tools/tools/build.js`; `:dist` is `dist/` |
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
or planned commands changes there, the page has to change too. Route vectors are in `test/fixtures/routes.json`; they
also state what the edge router of the site stack must do when the stack is switched to serve this build (it has no
router today). The Markdown attack corpus is `test/fixtures/attacks.md`.
