# mopm_core

The registry's rules that need no storage, no network and no clock, in Rust, ported from the TypeScript registry
(`service/api/src`) with its outputs held **byte for byte**. Nothing deploys this crate; it is a library for the
Lambdas that come after it.

| module | ports | held against |
|---|---|---|
| `version` | `version.ts`: `MAJOR.MINOR.PATCH`, no leading zeros, at most 128 bytes; numeric order of any length | the accepted and refused spellings and the ordering table of `test/version.test.ts` |
| `types`, `state` | `types.ts`, `state.ts`: the records, and `pending -> published -> yanked <-> published`, any -> `tombstoned` | the 16-row transition table and the refused-message table of `test/state.test.ts`; JSON round trips of the stored shape (an optional field is absent, never `null`); a pending row tagged with a `group_id` refuses a single `Publish` |
| `canonical_json` | `canonical-json.ts`: keys sorted at every depth, compact, safe integers only | the TS examples, and the two JavaScript behaviours it depends on (UTF-16 key order, array-index keys first) |
| `zstd` | `zstd.ts`: a frame of raw blocks | the exact bytes of frames of 0, 5, 131072 and 131073 bytes; a round trip of 0 to 300000 bytes through `ruzstd`, an independent decoder |
| `repodata` | `repodata.ts`: `repodata.json` and its `.zst` | the three files `service/api/test/fixtures/repodata.*.json` that the TS writer produced, as bytes; order, determinism and state properties over generated record sets |
| `error` | `errors.ts`, `auth/errors.ts`, `publish/errors.ts`, the three catalogues, `render`, `errorView` | the `x-mopm-errors` table of `spec/api/openapi.yaml` (message, hint, status, per entry) and every rendered error of `tests/contract/api/errors.json` |
| `limits` | `validate/limits.ts` | the seven numbers |
| `display` | `publish/display.ts`: the display metadata of a commit request | every message and bound of the TS function; JavaScript's `length` (UTF-16 units) and `\s` |
| `token` | `auth/tokens.ts`: `generateTokenSecret` from bytes the caller supplies, `hashToken`, the row's `prefix`, `TOKEN_PATTERN`; the fields of a web session's row (`web login`, `fresh_until` = `created_at`, 7 days) | `tests/fixtures/token_vectors.json` and `tests/fixtures/web_session_record.json`, which `service/api/test/auth/*.test.ts` hold `tokens.ts` and the TypeScript `Authenticator` to |
| `csrf` | the CSRF value of docs/design/tutorial-sign-in.md section 2 (no TypeScript yet) | the vectors' `csrf`, computed with Node's crypto in the same jest test |
| `return_to` | the `return_to` rule of appendix C.1 of docs/design/mopm-dev-appendix.md, falling back to `/tutorial` | the route vectors of `site/test/fixtures/routes.json`: a path is kept exactly when the edge router serves a page for it |

The oracles are files the TypeScript side already holds itself to, read by `include_str!` at their real paths
(`service/api/test/fixtures/repodata.*.json`, `spec/api/openapi.yaml`, `tests/contract/api/errors.json`,
`site/test/fixtures/routes.json`; `extra_srcs` in `BUCK` makes them inputs): a change to one of
them that the Rust does not follow is a red build here. Except for the token fixtures, no Node ran to make a golden:
expected values that are not in those files are derived from reading the TypeScript. The token fixtures
(`tests/fixtures`) were computed with Node's crypto, and the jest tests in `service/api/test/auth` check them against
`tokens.ts` on every run, so both languages are held to the same file.

The route grammar of `return_to` is written twice: in `site/src/routes.ts` (the site and its edge router) and in
`return_to.rs`. The shared route vectors hold the two equal for `/`, `/search`, `/packages/...` and `/docs/...`. The
tutorial routes are not in `routes.ts` yet, so `/tutorial/<lesson>` is held only by this crate's own tests.

## Group publish rows

`VersionRecord` carries the optional `group_id` and `staged_attempt` that the TypeScript registry's group publish (a set of
packages that become visible together) writes, so a row written by one implementation keeps them when the other rewrites it.
No row has them until that feature is used. This crate does not publish groups and reads
no group header, so it cannot tell that a group committed: every row with a `group_id` that is still `pending` is
hidden (the index lists no `pending` row) and a single `Publish` of it is refused. A committed group's members show only
after the group's own steps flip them to `published`, which the Rust port does not do. Moving traffic to the Rust port
while any group is open, validating or committed and not yet visible is therefore wrong; `service/docs/runbook.md`
("Cutting over to the Rust port") says when it is safe.

## Where Rust and TypeScript differ on purpose

* One `ErrorCode` and one `RegistryError` instead of three classes: the codes are one namespace and a code has one
  status in every table. The three template tables stay three, because which codes a route can answer with is part
  of the behaviour (a code the publish table lacks is `internal_error` there, whatever raised it).
* `apply_event` returns `Applied::Unchanged` or `Applied::Changed(record)` where TypeScript returns the same
  object or a new one.
* Versions compare without a big-integer type (no leading zeros, so length then digits).
* `display`: a URL is judged by the `url` crate (WHATWG, like `new URL`), not by the same code; they agree on every
  input in the tests, not by construction.

## JavaScript behaviour reproduced on purpose

* `Object.keys(o).sort()` is UTF-16 code unit order (`cmp_utf16`): a character outside the BMP sorts before
  `U+E000..U+FFFF`, the reverse of UTF-8 order. Used for object keys, `removed` and `depends`.
* A JavaScript object lists its array-index keys (`"0"`, `"10"`) first, in numeric order; `canonical_json` does too.
* `1.0` is the integer 1; `-0` is `0`.
