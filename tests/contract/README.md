# Contract tests

Examples of the registry contract (`spec/`), checked in CI by `validate.py`.
Both the CLI and the hosted registry are tested against the same contract;
these files are the part that needs no running service.

```text
python -I tests/contract/validate.py
```

Needs `jsonschema`, `openapi-spec-validator` and `PyYAML` (pinned in
`requirements.txt`). CI installs them into a throwaway virtual environment.
Nothing here is part of the mopm build.

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
  mutants that show the check can go red: a dropped required field, a wrong
  status, a missing header, a value outside a pattern or range, an auth scheme
  the operation does not accept, an error code or message off the catalogue.
- `malformed_request: true` is for error answers to input that cannot satisfy
  the request schema (`invalid_name`, `invalid_version`, `payload_too_large`):
  the request values are not schema-checked, the response still is.

What `validate.py` enforces on every case: path and query parameters are
declared and match their schemas; the request body matches; the response
status is declared by the operation (or is an error); required response
headers are present; the response body matches; an error uses a code from the
catalogue with that code's status, and its message and hint follow the
catalogue template; `rate_limited` carries `Retry-After`; an embedded
`manifest` is valid package metadata. It also requires a passing success case
for every operation, a case for every error code and for every rejection code.

## Examples: `examples/<kind>/{valid,invalid}/`

| kind | schema | file type |
|---|---|---|
| `index-record` | `spec/index-record.schema.json` | `.ndjson`, named after the package |
| `index-config` | `spec/index-config.schema.json` | `.json` |
| `takedowns` | `spec/takedowns.schema.json` | `.json` |
| `lock` | `spec/lock.schema.json` plus the rules in `spec/lock.md` | `.json` |

Everything under `valid/` must pass and everything under `invalid/` must fail.
Each invalid file has one defect, named by the file name.

## Adding to the contract

A change to `spec/api/openapi.yaml` that adds an endpoint needs a success
case for it; one that adds an error code needs the catalogue entry and a case.
Removing or retyping anything already in the file breaks the additive-only
rule in the OpenAPI description and is refused in review.
