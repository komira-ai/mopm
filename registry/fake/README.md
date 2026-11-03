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
| publish | `beginUpload` (the `put_url` is the fake's own `/_fake/upload/<id>`, which refuses bytes of another size or sha256), `commitPublish` (single-use uploads, resume while pending, `version_exists` for a version that exists; versions are `MAJOR.MINOR.PATCH` only, anything else is `invalid_version`; `limit_exceeded` when a file would take a package over its byte limit, 10 GB unless `/_fake/limits` lowers it), `getPublishStatus`, `setYanked`, `getVersion` |
| groups | `createGroup`, `getGroup`, `abortGroup`, `commitGroup`, `yankGroup` (spec/staged-set.md; groups.zig). A group's id is a function of the caller and the declared set, so the same request is the same group (the fake's ids are opaque: they are not derived the way the hosted registry's documented derivation is, and a client must not compute them); `getGroup` lists each member's declared files, with `uploaded` while the group is open; `getVersion` names the group that published a version (`group_id`, absent for a single publish); a member may declare its readme at create as `{"sha256", "size"}` (1 to 65536 bytes), and the answer then carries `readme` (`upload_id`, `uploaded`, and, until the bytes are stored, `put_url`, `put_headers` and `expires_at`) beside its files; the bytes go to the same `/_fake/upload/<id>` route as a file's, with the same checksum headers, and the route refuses bytes of another size or sha256; a create that declares the same digest again with another size replaces the size (the object is the one now declared); an object belongs to the member of the group that declared it, so identical bytes in another member, group or user's group need their own PUT; the declaration is not part of the group id; a malformed one is `invalid_request` naming the member; a commit member's `readme` is then a string (inline) or that same `{"sha256", "size"}`: for the object form the fake reads the stored object and refuses, naming the member and leaving the group open, one that was not uploaded or whose file is gone from storage (`upload_invalid`), whose bytes in storage now are not of the size and sha256 named (`upload_invalid`; a create then answers `uploaded: false` with a URL again) or that is not UTF-8 (`invalid_request`); a repeat of a commit on a group past `open` is compared by its request and reads no object, and the two forms are different requests (a ref is never read as an inline text of the same bytes, and an empty inline `readme` is a request apart from none; an empty `readme` is taken and served as `"readme":""`, as the hosted registry does); when the group is visible, `getVersion` and (for the latest version that is published, so not a yanked one) `getPackage` serve the text as `readme`, the same for both forms, and no key for a version without one; `/health` lists `features: ["group_readme_objects"]` while the capability is on; a commit may leave `manifest_sha256` out (the fake opens no archive, so it then keeps the sha256 of the version's first file as the version's hash, which is also what a group publish holds whatever its commit said); it is open for 12 hours of the fake's clock (an open group past that is expired by the next request that meets it) and reopens with the next `attempt` if it ended without committing. After the commit it runs one stage per status poll, as a single publish does: `validating`, `committed`, `visible`; a file whose bytes start with `REJECT:<rejection code>` ends it `rejected` and nothing is visible. A group yank or unyank moves one stage per poll too (`yanking`, `yanked`; `unyanking`, `restored`). The fake keeps no rate counter for groups: use `/_fake/fault`. |

Claims follow the fake's own rules: `mopm`, `mojo`, `max`, `modular`, `std`
and `stdlib` are reserved, and a name is too similar to another when the two
are equal without underscores or differ by a trailing `s`. Invitations expire
after 7 days and claims after 30, on the fake's clock.

A publish moves one stage per status poll (pending, validating, indexing,
published). The fake checks that each file name names the package and version
(`filename_mismatch`) but does not open archives: a file whose bytes start
with `REJECT:<rejection code>` is rejected with that code, so a client can
test every rejection.

Errors follow the catalogue in `openapi.yaml` (`errors.zig` is generated from
it); every answer carries `x-mopm-request-id`.

## Test controls (`/_fake/...`)

Not part of the contract. Each is a POST with a JSON object body.

| path | body | effect |
|---|---|---|
| `/_fake/users` | `{"handle"}` | a GitHub account the fake knows (made on first use) |
| `/_fake/session` | `{"handle", "fresh"?}` | a session token, as a login gives; `"fresh": false` makes it stale |
| `/_fake/device` | `{"user_code", "decision": "approve" \| "deny", "handle"}` | the person's answer to a device login |
| `/_fake/clock` | `{"advance_seconds"}` | moves the fake's clock forward (expiry of tokens, sessions, logins) |
| `/_fake/mode` | `{"read_only"}` | read-only mode, as a stage can be |
| `/_fake/limits` | `{"project_bytes"}` | the per-package byte limit (default 10 GB), to reach `limit_exceeded` with small files |
| `/_fake/fault` | `{"operation", "code"}` | the next request to that operationId answers that error code |
| `/_fake/trusted` | `{"name", "repository"}` | a trusted publisher of a package, for `exchangeOidcToken` |
| `/_fake/ci_publisher` | `{"repository"}` | a CI publisher trusted by configuration, for the `packages` form of `exchangeOidcToken` (a name nobody has claimed is created, owned by the publisher; the one token it returns may create and run a group of exactly those versions) |
| `/_fake/tombstone` | `{"name", "version", "reason_code"}` | an administrator's takedown: no `url`, the sha256 stays |
| `/_fake/groups` | `{"enabled"}` | group publishing on (the default) or off: off, `createGroup` answers `route_not_found`, as a registry that has not enabled groups does |
| `/_fake/readme_objects` | `{"enabled"}` | readmes as uploaded objects on (the default) or off: off, `/health` lists no `features`, a create ignores member `readme` and answers none, and a commit refuses a `readme` that is not a string (`'readme' of '<name>' must be a string`), as a registry from before the capability does; objects already uploaded stay |
| `/_fake/put_fault` | `{"after"}` | after that many more PUTs of upload bytes, the next one answers `unavailable` (once), as storage can fail in the middle of a group |
| `/_fake/commit_clock` | `{"advance_seconds"}` | the clock moves forward by that much when the next group commit arrives (once), so a group can pass its deadline between the create and the commit |
| `/_fake/served` | `{}` | `{"conda"}`: how many `.conda` files `GET /channel/...` has served since the fake started, to count a client's downloads |

## Tested how

`//:contract_replay` (`tests/drivers/replay_test.zig`) replays every valid case of `tests/contract/api`
for the operations above against a running fake: each recipe sets the state
the case describes, and the live answer must have the case's status and error
code and pass the contract checks of `//:contract`. The farm builds it. Unit tests (`zig build test`) cover the catalogue templates,
times, tokens, names and routing.
