# site

The mopm.dev web site: plain TypeScript compiled by `tsc` to ES modules the browser loads directly. No framework, no
bundler, no runtime dependencies.

The prerendered pages (`/`, `/docs/`, `/docs/<slug>/`, `404.html`) work without scripts. `/search`,
`/packages/<name>` and `/packages/<name>/<version>` share one shell, `app.html`, which `src/main.ts` fills from one
API call.

| module | what it does |
|---|---|
| `src/routes.ts` | URL routes, the package name and version grammar, path builders |
| `src/host.ts` | the API and conda channel for the hostname a page is served on (three known hosts, nothing else) |
| `src/api.ts`, `src/errors.ts`, `src/decode.ts`, `src/types.ts` | the read API client: one simple CORS GET per call, error mapping, runtime decoding |
| `src/doc.ts` | the Doc port: element and text nodes through a tag and attribute allowlist (`h()`); DOM and string backends |
| `src/links.ts` | URL checking, the only source of `SafeHref` |
| `src/markdown/` | a restricted Markdown parser (linear time) and its renderer, for package readmes and repo docs |
| `src/snippet.ts`, `src/format.ts` | the install lines a page shows; times, sizes and version states as text |
| `src/views/` | the search, package and version views and the shared ones (loading, error, not found), built through a `Doc` |
| `src/main.ts` | the page script: the read-only banner, `/` to focus search, and the app shell's routing |
| `static/site.css` | the one stylesheet |
| `tools/` | the build (Node, run at build time only): page layout, the home, 404 and shell pages, the docs pages, hashing the assets, and the checks on `dist/` |

## Rules

1. **No runtime dependencies.** `dependencies` stays empty; everything shipped to a browser is code in `src/`.
2. **No HTML sinks.** Markup is built only through `h()` and a `Doc`; no string of HTML reaches the DOM and no string
   runs as code. `test/no-sinks.test.ts` checks the source.
3. **No inline script or style.** The CSP allows `'self'` only.
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

`dist/` holds `index.html`, `app.html`, `404.html`, `docs/index.html`, `docs/<slug>/index.html` and
`assets/<id>/`: the modules `main.js` loads and `site.css`, where `<id>` is a hash of their contents (no clock, no
commit), so the same sources give the same tree and a changed asset gets a new URL. `tools/check-dist.ts` refuses a
tree with a missing page, a dangling asset or import, inline script or style, an event-handler attribute, a file
other than `.html`, `.js` or `.css`, or JavaScript or CSS over its size budget.

The home page copy is held to `README.md` and `src/cli/main.zig` by `test/layout.test.ts`: when the list of working
or planned commands changes there, the page has to change too. Route vectors shared with the edge router of the site stack are in `test/fixtures/routes.json`; the Markdown attack
corpus is `test/fixtures/attacks.md`.
