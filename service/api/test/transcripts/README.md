# Seeds and transcripts of the registry API

The registry API is being ported to Rust behind the same routes. Two implementations of one HTTP API are
compared by what they answer, so the questions "what state did the request start from" and "what exactly
came back" must be data, not TypeScript. This directory holds the TypeScript side of that: the loader and runner
that make the data, and the tests that keep the data true. Nothing here is deployed.

## Seeds (`../fixtures/seeds/*.json`)

A seed is the contents of the stores before a request. Sections, applied in this order: `bulk_packages`,
`packages`, `owners`, `versions` (each `{record, audit}`: the version row and the audit row written with it), `users`,
`tokens`, `bulk_tokens`, `trusted_publishers`, `uploads`, `publishes`. Records are the shapes of
`src/types.ts`, `src/auth/types.ts` and `src/publish/types.ts`.

- A token is written as `{secret, record}`: the secret a request can send as its bearer value, and the row without
  `hash` and `prefix`. The loader stores `hash` (SHA-256 of the secret, lowercase hex) and `prefix` (the first
  eleven characters of the secret).
- `bulk_packages` and `bulk_tokens` generate rows: `{n:04}` in a format is n, zero-padded to four digits, for n from 0
  to count - 1; the secret of a bulk token is `secret_prefix` followed by n in base 6 over the digits 2 to 7, four
  digits wide.

`seeds/seeds.test.ts` holds the seeds that replaced the replay recipes of `http/replay.test.ts` to the builders
they came from (`seeds/legacy-recipes.ts`), so the conversion changed no value. `http/replay.test.ts` now loads
the seed files.

## Scenarios and transcripts (`../fixtures/transcripts/`)

A **scenario** (`scenarios/NAME.json`) is a `world` and a list of `steps`.

- `world`: `seeds` (names, applied in order), `clock` (ISO, default 2026-10-14T12:00:00Z), `auth` and `publish` (which
  route families are wired), `read_only`, `limits` (publish limits, as `PublishConfig`), `github` (what the fake
  GitHub answers: `poll_script`, `user`, `user_status`), `require_2fa`, `faults.store` (every registry call fails),
  `stage`, `version`, `commit`.
- A step is one of
  - `{request: {method, path, query?, headers?, token?, body? | json?}, expect?: {status, code?}}`: `token` is
    shorthand for `authorization: Bearer <token>`; `json` is the body written as JSON (compact); `body` may be
    `{"$repeat": [text, n]}`. Strings may hold `{{N.path}}`: member `path` (dot separated) of the JSON body of the
    response to the N-th request (counting requests only, from 0). `expect` is what the author meant the request to
    reach; the test fails if the answer is not that, so a scenario cannot silently stop covering its branch.
  - `{set: {read_only?, flags_broken?, clock?, advance_s?}}`: flip the read-only switch, make it unreadable, set or
    move the clock.
  - `{put_object: {upload_id, content}}`: what the browser-side upload does between begin-upload and commit: the
    bytes appear in the bucket under the upload's key.

A **golden** (`golden/NAME.json`) is what running the scenario produced: `description`, `world`, and `steps` in
which every request is resolved (templates filled in, shorthands expanded) and followed by its `response`: `status`,
`headers` as a list of `[name, value]` pairs in the order and spelling sent, and `body` as the exact string. A second
implementation needs only the goldens: build the world, replay each step in order, compare status, headers
and body byte for byte.

Rules a replaying implementation must follow, because the TypeScript run did:

- **Random source.** Identifiers and secrets come from `randomBytes`. In a scenario the k-th call (k from 0, over the whole
  scenario) of `randomBytes(n)` returns the n bytes `(k * 167 + j * 29 + 11) mod 256`, j from 0 to n - 1. The publish
  side does not use it: an upload id is `upl_` and a counter in hex (32 digits) that begin-upload and yank advance
  for each id they make (begin takes one for the audit row, then one for the upload), from 1; a publish id is derived
  from the name, version and upload ids.
- **Clock.** The clock is the world's, moved only by `set`. A request does not move it.
- **Request ids.** The N-th request (from 1) is answered with request id `req-N` in `x-mopm-request-id`.
- **The switch.** Before each request the read-only switch is read once (like the Lambda does); an unreadable
  switch counts as writable for that read, and begin/commit then refuse because they read it themselves.

What is not here, on purpose:

- `GET /health`: it carries the deployed version and commit, and says which implementation answered (`impl`), so its
  bytes differ by design. It has its own tests (`http/router.test.ts`, the contract cases, end-to-end).
- A successful CI exchange (needs a signed token; the refusals before a signature matters are covered), and the
  validator's verdicts (the validator corpus).
- `isBase64Encoded`, duplicate query parameters and other things the API gateway does before the router: they are the
  Lambda's (`lambda/handlers.test.ts`). A request in a golden has the body and query the router receives.

## Recording

`MOPM_RECORD_TRANSCRIPTS=1 npx jest test/transcripts` rewrites the golden files from the scenarios. Without it, a
golden that is missing or differs fails the test, which prints the transcript it got (plain, and in base64 for CI logs,
which mask credential-shaped text). Review a golden diff as you would review a change in behaviour: it is one.

## Defects the tests catch

`transcripts.test.ts` fails when an answer changes by a byte (a status, a header, the order of members of a body, an
error text), when a scenario's `expect` no longer holds, and when a scenario has no golden or a golden no scenario.
`seeds/seeds.test.ts` fails when a seed differs from the builder it was made from, or a seed file is not accounted for.
