# mopm_core

The registry's rules that need no storage, no network and no clock, in Rust, ported from the TypeScript registry
(`service/api/src`) with its outputs held **byte for byte**. Nothing deploys this crate; it is a library for the
Lambdas that come after it.

| module | ports | held against |
|---|---|---|
| `version` | `version.ts`: `MAJOR.MINOR.PATCH`, no leading zeros, at most 128 bytes; numeric order of any length | the accepted and refused spellings and the ordering table of `test/version.test.ts` |
| `types`, `state` | `types.ts`, `state.ts`: the records, and `pending -> published -> yanked <-> published`, any -> `tombstoned` | the 16-row transition table and the refused-message table of `test/state.test.ts`; JSON round trips of the stored shape (an optional field is absent, never `null`) |
| `canonical_json` | `canonical-json.ts`: keys sorted at every depth, compact, safe integers only | the TS examples, and the two JavaScript behaviours it depends on (UTF-16 key order, array-index keys first) |
| `zstd` | `zstd.ts`: a frame of raw blocks | the exact bytes of frames of 0, 5, 131072 and 131073 bytes; a round trip of 0 to 300000 bytes through `ruzstd`, an independent decoder |
| `repodata` | `repodata.ts`: `repodata.json` and its `.zst` | the three files `service/api/test/fixtures/repodata.*.json` that the TS writer produced, as bytes; order, determinism and state properties over generated record sets |
| `error` | `errors.ts`, `auth/errors.ts`, `publish/errors.ts`, the three catalogues, `render`, `errorView` | the `x-mopm-errors` table of `spec/api/openapi.yaml` (message, hint, status, per entry) and every rendered error of `tests/contract/api/errors.json` |
| `limits` | `validate/limits.ts` | the seven numbers |
| `display` | `publish/display.ts`: the display metadata of a commit request | every message and bound of the TS function; JavaScript's `length` (UTF-16 units) and `\s` |

The oracles are files the TypeScript side already holds itself to, read by `include_str!` through labels
(`//service/api:repodata.*.json`, `//:lambda.spec.openapi.yaml`, `//:lambda.contract.errors.json`): a change to one of
them that the Rust does not follow is a red build here. No Node ran to make a golden: expected values that are not
in those files are derived from reading the TypeScript.

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
