# The fake registry

`mopm-fake-registry` is a local stand-in for the hosted registry. It serves
the contract in `spec/` (`api/openapi.yaml`, `channel.md`, `index.md`) from
memory and a directory, so the CLI's publish and install paths can be tested
with no service and no network. It is a test tool: nothing here is deployed.

```text
zig build
./zig-out/bin/mopm-fake-registry --dir <scratch dir> [--port <n>] [--stage beta|gamma|prod]
```

It listens on 127.0.0.1 (`--port 0`, the default, picks a free port) and
prints `mopm-fake-registry listening on http://127.0.0.1:<port>` as its first
line. The API is under `/api/v1`. It answers one request at a time.

## What it implements

| area | operations |
|---|---|
| meta | `getHealth` |
| login | `startDeviceLogin`, `pollDeviceLogin` (the person's decision comes from `/_fake/device`) |
| the caller | `getMe` |
| tokens | `createToken`, `listTokens`, `revokeToken` |
| CI identity | `exchangeOidcToken`: the token is JWT-shaped (three base64url parts); its payload's `repository` claim must be a trusted publisher of the package (`/_fake/trusted`). No signature is checked. |
| packages | `searchPackages` (name prefix, `sort`, cursors), `getPackage`, `claimPackage`, `listVersions` |
| owners | `listOwners`, `inviteOwner`, `removeOwner`, `listInvitations`, `acceptInvitation` |

Claims follow the fake's own rules: `mopm`, `mojo`, `max`, `modular`, `std`
and `stdlib` are reserved, and a name is too similar to another when the two
are equal without underscores or differ by a trailing `s`. Invitations expire
after 7 days and claims after 30, on the fake's clock. Other operations answer
`invalid_request` ("not implemented yet") until they land. Errors follow the catalogue in `openapi.yaml` (`errors.zig` is generated
from it); every answer carries `x-mopm-request-id`.

## Test controls (`/_fake/...`)

Not part of the contract. Each is a POST with a JSON object body.

| path | body | effect |
|---|---|---|
| `/_fake/users` | `{"handle"}` | a GitHub account the fake knows (made on first use) |
| `/_fake/session` | `{"handle", "fresh"?}` | a session token, as a login gives; `"fresh": false` makes it stale |
| `/_fake/device` | `{"user_code", "decision": "approve" \| "deny", "handle"}` | the person's answer to a device login |
| `/_fake/clock` | `{"advance_seconds"}` | moves the fake's clock forward (expiry of tokens, sessions, logins) |
| `/_fake/mode` | `{"read_only"}` | read-only mode, as a stage can be |
| `/_fake/fault` | `{"operation", "code"}` | the next request to that operationId answers that error code |
| `/_fake/trusted` | `{"name", "repository"}` | a trusted publisher of a package, for `exchangeOidcToken` |

## Tested how

`tests/contract/replay.py` replays every valid case of `tests/contract/api`
for the operations above against a running fake: each recipe sets the state
the case describes, and the live answer must have the case's status and error
code and pass the contract checks of `validate.py`. CI runs it in the
`contract` job. Unit tests (`zig build test`) cover the catalogue templates,
times, tokens, names and routing.
