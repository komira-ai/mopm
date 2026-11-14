# Contract tests

Examples of the registry contract (`spec/`), checked by the Buck2 target
`//:contract` (`tests/drivers/contract_test.zig`). Both the CLI and the hosted
registry are tested against the same contract; these files are the part that
needs no running service. `//:contract_replay` (`tests/drivers/replay_test.zig`)
replays the API cases of `/api/v1` against the fake registry. The cases of
`/api/v2` are replayed against the hosted registry's router by `service/api`'s
`test/http/replay-v2.test.ts` (jest, memory ports, a fixed clock).

```text
./buck2 build //:contract //:contract_replay
```

Both are Zig tests and run on the build farm; there is no Python in them. The
JSON Schema reader (`tests/drivers/jsonschema.zig`) implements only the
keywords the schemas use (including `$defs` with `$ref` to `#/$defs/...`, and
`if`/`then`/`else`) and fails the run, naming the keyword, on any other:
a schema that starts using a new keyword needs it implemented there first. The
OpenAPI checks (`openapi_check.zig`) are structural (see its header); they are
not the full OpenAPI 3.1 meta schema.

## API cases: `api/*.json`

Each file is `{"cases": [...]}`. A case:

```json
{
  "name": "poll approved",
  "operationId": "pollDeviceLogin",
  "request": { "path": {}, "query": {}, "body": {}, "auth": "userToken" },
  "response": { "status": 200, "headers": { "x-mopm-request-id": "..." }, "body": {} },
  "expect": "valid",
  "malformed_request": false
}
```

- `auth` names a security scheme of the operation, or is absent when the
  request carries no token (then only a 401 is a valid answer if the
  operation needs one).
- `expect` is `valid` (default) or `invalid`. An `invalid` case is a
  counter-example and the check FAILS if the contract accepts it. Every
  counter-example has exactly one defect, named by its `name`. These are the
  variants that show the check can go red: a dropped required field, a wrong
  status, a missing header, a value outside a pattern or range, an auth scheme
  the operation does not accept, an error code or message off the catalogue.
- `malformed_request: true` is for error answers to input that cannot satisfy
  the request schema (`invalid_name`, `invalid_version`, `payload_too_large`):
  the request values are not schema-checked, the response still is.

What `//:contract` enforces on every case: path and query parameters are
declared and match their schemas; the request body matches; the response
status is declared by the operation (or is an error); required response
headers are present; the response body matches; an error uses a code from the
catalogue with that code's status, and its message and hint follow the
catalogue template; `rate_limited` carries `Retry-After`. It also requires a passing success case
for every operation, a case for every error code and for every rejection code.

## API cases of v2: `api-v2/*.json`

The same case format and the same checks, against `spec/api/openapi-v2.yaml`
(`/api/v2`: package names are full names `<namespace>/<name>`, a package path is
`/packages/{namespace}/{name}`, and there are namespaces, no owners and no
claim) and its own error catalogue. `//:contract` checks `openapi-v2.yaml` the
way it checks `openapi.yaml`, and the files here the way it checks `api/`: a
passing success case for every operation of the v2 spec, a case for every error
code of its `x-mopm-errors` and for every rejection code. The files are grouped
by area: `meta`, `auth` (device login, CI exchange), `me`, `tokens`,
`namespaces`, `packages` (reads and `createPackage`), `publish` (uploads,
commit, status, yank), `groups` and `errors` (the catalogue, one case per
code). Counter-examples (`expect: invalid`) carry one defect each, among them
a flat name where a full name is required, a `name_reserved` hint of v1's flat
creation under v2's template, a `MeV2` without `namespaces` and a
`NamespaceInfo` without `frozen`.

A few values a registry makes at random (a token secret, a token id, a device
code, an upload id, a publish id, a cursor) are examples here; the replay
compares them by shape (`OPAQUE` in `service/api/test/http/replay-v2.ts`).
`name_taken` and `name_too_similar` are in the v2 catalogue but no operation of
v2 answers them, so their cases are written by hand and are not replayed.

## Examples: `examples/<kind>/{valid,invalid}/`

| kind | schema | file type |
|---|---|---|
| `index-record` | `spec/index-record.schema.json` plus the rules in `spec/index.md` | `.ndjson`, named `<namespace>.<name>.ndjson` after the package `<namespace>/<name>` |
| `index-config` | `spec/index-config.schema.json` | `.json` |
| `takedowns` | `spec/takedowns.schema.json` | `.json` |
| `lock` | `spec/lock.schema.json` plus the rules in `spec/lock.md` (lock 3: full names, `artifacts` per Mojo version, channel `<root><namespace>/`, one package per import name) | `.json` |

Everything under `valid/` must pass and everything under `invalid/` must fail.
Each invalid file has one defect, named by the file name.

The package metadata fixtures under `tests/fixtures` (`<import name>.mopm.json`,
schema 2: `name` and `deps[].name` are full names) are checked against
`spec/package-metadata.schema.json`.

## Adding to the contract

A change to `spec/api/openapi.yaml` (cases in `api/`) or `spec/api/openapi-v2.yaml`
(cases in `api-v2/`) that adds an endpoint needs a success case for it; one that
adds an error code needs the catalogue entry and a case. Removing or retyping
anything already in the file breaks the additive-only rule in the OpenAPI
description and is refused in review.
