# site

The mopm.dev web site: plain TypeScript compiled by `tsc` to ES modules the browser loads directly. No framework, no
bundler, no runtime dependencies.

This package holds the parts the pages are built from:

| module | what it does |
|---|---|
| `src/routes.ts` | URL routes, the package name and version grammar, path builders |
| `src/host.ts` | the API and conda channel for the hostname a page is served on (three known hosts, nothing else) |
| `src/api.ts`, `src/errors.ts`, `src/decode.ts`, `src/types.ts` | the read API client: one simple CORS GET per call, error mapping, runtime decoding |
| `src/doc.ts` | the Doc port: element and text nodes through a tag and attribute allowlist (`h()`); DOM and string backends |
| `src/links.ts` | URL checking, the only source of `SafeHref` |
| `src/markdown/` | a restricted Markdown parser (linear time) and its renderer, for package readmes and repo docs |

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
npm run build       # compiles src to build/browser/
```

Route vectors shared with the edge router of the site stack are in `test/fixtures/routes.json`; the Markdown attack
corpus is `test/fixtures/attacks.md`.
