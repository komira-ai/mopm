# The fake registry

`mopm-fake-registry` is a local stand-in for the hosted registry. It serves
the contract in `spec/` (`api/openapi.yaml`, `channel.md`, `index.md`) from
memory and a directory, so the CLI's publish and install paths can be tested
with no service and no network. It is a test tool: nothing here is deployed.

It also serves package names in owner namespaces, `<namespace>/<name>`, as
`spec/proposed/namespaces.md` describes them (API v2, index version 2, one
channel per namespace), beside version 1, so the client can be built against
them before the hosted registry has them.

```text
zig build
./zig-out/bin/mopm-fake-registry --dir <scratch dir> [--port <n>] [--stage beta|gamma|prod]
```

It listens on 127.0.0.1 (`--port 0`, the default, picks a free port) and
prints `mopm-fake-registry listening on http://127.0.0.1:<port>` as its first
line. The API is under `/api/v1` and `/api/v2`. It answers one request at a time.

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
| publish | `beginUpload` (the `put_url` is the fake's own `/_fake/upload/<id>`, which refuses bytes of another size or sha256), `commitPublish` (single-use uploads, resume while pending, `version_exists` for a version that exists, except that a published version takes one build it does not have: see "Builds of a version"; versions are `MAJOR.MINOR.PATCH` only, anything else is `invalid_version`; `limit_exceeded` when a file would take a package over its byte limit, 10 GB unless `/_fake/limits` lowers it), `getPublishStatus`, `setYanked`, `getVersion` |
| groups | `createGroup`, `getGroup`, `abortGroup`, `commitGroup`, `yankGroup` (spec/staged-set.md; groups.zig). A group's id is a function of the caller and the declared set, so the same request is the same group (the fake's ids are opaque: they are not derived the way the hosted registry's documented derivation is, and a client must not compute them); `getGroup` lists each member's declared files, with `uploaded` while the group is open; `getVersion` names the group that published a version (`group_id`, absent for a single publish); a member may declare its readme at create as `{"sha256", "size"}` (1 to 65536 bytes), and the answer then carries `readme` (`upload_id`, `uploaded`, and, until the bytes are stored, `put_url`, `put_headers` and `expires_at`) beside its files; the bytes go to the same `/_fake/upload/<id>` route as a file's, with the same checksum headers, and the route refuses bytes of another size or sha256; a create that declares the same digest again with another size replaces the size (the object is the one now declared); an object belongs to the member of the group that declared it, so identical bytes in another member, group or user's group need their own PUT; the declaration is not part of the group id; a malformed one is `invalid_request` naming the member; a commit member's `readme` is then a string (inline) or that same `{"sha256", "size"}`: for the object form the fake reads the stored object and refuses, naming the member and leaving the group open, one that was not uploaded or whose file is gone from storage (`upload_invalid`), whose bytes in storage now are not of the size and sha256 named (`upload_invalid`; a create then answers `uploaded: false` with a URL again) or that is not UTF-8 (`invalid_request`); a repeat of a commit on a group past `open` is compared by its request and reads no object, and the two forms are different requests (a ref is never read as an inline text of the same bytes, and an empty inline `readme` is a request apart from none; an empty `readme` is taken and served as `"readme":""`, as the hosted registry does); when the group is visible, `getVersion` and (for the latest version that is published, so not a yanked one) `getPackage` serve the text as `readme`, the same for both forms, and no key for a version without one; `/health` lists `features: ["group_readme_objects"]` while the capability is on; a commit may leave `manifest_sha256` out (the fake opens no archive, so it then keeps the sha256 of the version's first file as the version's hash; a member whose commit states one holds that, as the hosted registry holds the archive's, which the commit states); it is open for 12 hours of the fake's clock (an open group past that is expired by the next request that meets it) and reopens with the next `attempt` if it ended without committing. After the commit it runs one stage per status poll, as a single publish does: `validating`, `committed`, `visible`; a file whose bytes start with `REJECT:<rejection code>` ends it `rejected` and nothing is visible. A group yank or unyank moves one stage per poll too (`yanking`, `yanked`; `unyanking`, `restored`). The fake keeps no rate counter for groups: use `/_fake/fault`. |

### Builds of a version (builds.zig)

A build is the files of a version built with one Mojo compiler. Its build string is `mojo<compiler>_0`, the end of each of its file
names (`mojo-<name>-<version>-<build>.conda`); the fake reads the build off the file names and stores nothing else. A version holds
the files of one or more builds, and its primary build is the one with the lowest compiler, compared as numbers part by part
(`1.2.0` before `1.10.0`).

- A new version may be published with several builds at once: one commit of up to 20 uploads, or one group member.
- An add is a publish (a single commit, or a group member) of a version that is already published, with the files of one build the
  version does not have. The files are appended when the publish is published (a single publish) or when the group is committed (a
  group), never before, and never replace a file. The version's other fields, `published_at`, `manifest_sha256` and `group_id`
  among them, stay as they were. The same upload ids committed again resume the add, as they do for a new version.
- `version_exists` refuses an add of a build the version already has (a published file is never replaced), of the files of
  more than one build, of a build another publish or a group that is validating holds, of a build whose own publish was
  rejected (the build is burned, as a rejected version is), of any version that is yanked, taken down or rejected, and of any
  single publish into a version a group published (`getVersion` shows its `group_id`), whatever it adds: a build is added to a
  group's version by a group member. So does a
  commit whose `manifest_sha256` is not the one the version was committed with (the sources differ). The message is the
  catalogue's, the same for every refusal. A group is refused at create for everything but the manifest, which is compared at the
  commit (the group stays open); a refusal uses up no upload.
- The manifest compared is the one the version's commit stated; a version committed without one holds the sha256 of its first file,
  and an add that states none is compared by its own first file's sha256, as the fake computes it when a commit leaves it out.
- A group's yank acts on whole versions only: it yanks the versions of the members that are not adds, and a group whose members
  are all adds goes `yanking`, `yanked` with `yanked_members` 0 and every version still published; its unyank restores nothing.
- What is served. Index lines of version 2 (`v` 2) carry the top-level `build`, `requires_mojo` and `files` of the primary build and
  `builds`: every build, sorted by compiler, each `{build, requires_mojo, files}` (a version with one build lists that one). Index
  lines of version 1 are unchanged. `getVersion` under `/api/v2` has `requires_mojo` and `files` of the primary build and `builds`;
  under `/api/v1` it has the primary build only. A taken-down version's builds keep their sha256 and lose their `url`. The repodata
  lists every file with its own build and compiler.
- What it does not do. It opens no archive, so it does not check `source_sha256` inside the archives (the hosted registry does): a
  build is "from the same sources" when the commit states the version's `manifest_sha256`, and the dependencies and system
  libraries of the files are not compared. A file name is checked as before (`filename_mismatch`: it must start with the conda name
  and version); the build is whatever the name ends with.

### `/api/v2`: names in namespaces (spec/api/openapi-v2.yaml)

A package is `/packages/{namespace}/{name}`; every name in a body or answer is a full name. A v1 package and a package
in a namespace never meet: v1 routes see only v1 names, v2 routes only full names.

| area | operations |
|---|---|
| unchanged | `getHealth`, `startDeviceLogin`, `pollDeviceLogin`, `listTokens`, `revokeToken`, `getPublishStatus` (the same handlers as v1) |
| namespaces | `createNamespace` (`POST /namespaces {"namespace"}`, a fresh session: starts the registration of an organization namespace and answers 202 with a device code bound to the caller; `invalid_namespace`, `namespace_reserved` and `namespace_taken` come before it), `pollNamespace` (`POST /namespaces/poll`, a token of the same account: `pending`, `denied`, `expired`, or `created` with the `NamespaceInfo` once approved, see below), `getNamespace` (public, `NamespaceInfo` with `namespace`, `kind`, `github_id`, `login`) |
| members | `listMembers` (`GET /namespaces/{namespace}/members`, any owner or member of it, sorted by `user`), `setMember` (`PUT .../members/{user} {"role": "owner" \| "member"}`, a fresh session of an owner: 201 when added, 200 when the role changed or was already that; the only owner made a member is `last_owner`), `removeMember` (`DELETE`, a fresh session of an owner: 204; `member_not_found`; the only owner is `last_owner`). `{user}` is a mopm username, a namespace of kind user, else `user_not_found`; a user namespace has no members |
| the caller | `getMe` (`MeV2`: the namespaces the caller can write now, its user namespaces first, each with its role and packages; `unavailable_namespace` when its login cannot be its namespace: outside the grammar, reserved, or held by another account) |
| tokens | `createToken`: `packages` are full names, which may name a package not created yet in a namespace the caller can write; `all_current` is the packages of every namespace the caller can write now |
| CI identity | `exchangeOidcToken`: `name` (or each `packages[].name`) is a full name whose namespace has the token's repository as a publisher (`/_fake/trusted` with `namespace`), all of one namespace (`invalid_request` otherwise); it mints a token and creates nothing |
| packages | `searchPackages` (`q` a name prefix, matched in every namespace, or `<namespace>/` with an optional name prefix; `/` may be sent as `%2F`), `getPackage` (`namespace` instead of `owners`), `createPackage` (`PUT`, no body: 201 created, 200 if it exists; the right is checked first; a CI token, `publish` or `stage`, creates only a package it names), `listVersions` |
| publish, groups | `getVersion`, `beginUpload`, `commitPublish`, `setYanked`, and the five group operations, as v1, with full names; a file is `mojo-<namespace>.<name>-<version>-<build>.conda` (`filename_mismatch` otherwise) |
| removed | owners, invitations and `claimPackage`: `route_not_found` |

GitHub is asked about an organization once, when its namespace is registered: the poll of an approved registration
reads the fake's GitHub (`/_fake/org`) and creates the namespace only when the approving account is the caller's own
(`github_account_mismatch`) and is an active admin of the organization whose current login is the namespace (a member, a
billing manager, a pending admin, a non-member, an organization renamed away, or no such organization is `not_org_admin`);
a string any namespace holds by then is `namespace_taken`. The caller becomes its first owner and the namespace keeps the
organization's GitHub id. Afterwards GitHub is not asked: who may write in an organization namespace is the member table
of the registry, checked when a token is used and never cached, so a member removed is refused (`not_namespace_member`) at
the next request. Who may write elsewhere: in a user namespace, the account of its GitHub id; a CI identity token, when the
namespace has its repository as a publisher. The first login of an account (`pollDeviceLogin`, or `/_fake/session`) makes its
user namespace, its login in lower case, when that is in the grammar, not reserved and free; a renamed account keeps its old
namespace and gains the new one at its next login. The registry refuses keywords, builtins and the reserved names as import
names (`name_reserved`). The error codes `invalid_namespace`, `not_namespace_member`, `not_namespace_owner`, `not_org_admin`,
`github_account_mismatch`, `namespace_taken`, `last_owner`, `member_not_found`, `user_not_found`, `namespace_reserved` and
`namespace_not_found` are in `ns_errors.zig`, from `spec/api/openapi-v2.yaml`, until they join the catalogue.

Files: `index/config.json` adds `index_versions: [1, 2]` and `api_v2_url`. Index version 2 is
`index/v2/<aa>/<bb>/<namespace>/<name>` (records `v` 2, full names, the URLs of the namespace's channel) and
`index/v2/takedowns.json`. Each namespace has its channel, `channel/<namespace>/<subdir>/` (repodata whose conda names
are `mojo-<namespace>.<name>`), written for every namespace, empty until it holds a package. The flat root
`channel/<subdir>/` and index version 1 hold only v1 packages.

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
| `/_fake/session` | `{"handle", "fresh"?}` | a session token, as a login gives (it makes the account's user namespace, as a login does); `"fresh": false` makes it stale |
| `/_fake/device` | `{"user_code", "decision": "approve" \| "deny", "handle"?}` | the person's answer to a device login (`handle` required) or to the registration of an organization namespace (`handle` optional: without it the account that started the registration approves; another handle is an approval by another GitHub account) |
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
| `/_fake/org` | `{"login", "members"?: [{"handle", "role", "state"?}]}` | a GitHub organization (made on first use), what the fake's GitHub says when an organization namespace is registered: `members` replaces the members, role `admin`, `member` or `billing_manager`, state `active` (the default) or `pending` |
| `/_fake/rename` | `{"login", "to"}` | the GitHub account or organization `login` is called `to` from now on; namespaces keep their names |
| `/_fake/trusted` | `{"namespace", "repository"}` | a trusted publisher of a namespace, for v2's `exchangeOidcToken` |
| `/_fake/v1_creation` | `{"enabled"}` | whether `/api/v1` creates packages (the default). Off, `claimPackage` and `exchangeOidcToken` (either form) for a name nobody has answer `name_reserved` with the hint `package names are in namespaces now; update mopm`; names that exist keep publishing |
| `/_fake/served` | `{}` | `{"conda"}`: how many `.conda` files `GET /channel/...` has served since the fake started, to count a client's downloads |

## Tested how

`//:contract_replay` (`tests/drivers/replay_test.zig`) replays every valid case of `tests/contract/api`
for the operations above against a running fake: each recipe sets the state
the case describes, and the live answer must have the case's status and error
code and pass the contract checks of `//:contract`. The farm builds it. Unit tests (`zig build test`) cover the catalogue templates,
times, tokens, names and routing; `builds_test.zig` covers the builds of a version (new versions with several builds, adds by single
publish and by group, each refusal, what the index, `getVersion` and the repodata show); `namespaces_test.zig` and `namespaces_publish_test.zig` cover `/api/v2`, namespaces
and the files of index version 2 and the namespace channels. The contract cases of v2 are `tests/contract/api-v2` (checked
against `spec/api/openapi-v2.yaml` by `//:contract`, and replayed against the hosted registry's router by `service/api`'s
`test/http/replay-v2.test.ts`); `//:contract_replay` replays v1's only, and the fake's replay of the v2 cases is not part of that
check yet.
