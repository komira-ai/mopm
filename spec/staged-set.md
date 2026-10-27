# The staged set

A staged set is a directory of packages that are meant to be published together,
and the files `mopm publish --staged` keeps beside it. `mopm publish --staged
<dir> --registry <name>` publishes the set through one group (`createGroup`,
`commitGroup` and `getGroup` in `api/openapi.yaml`): either every member is
visible, or none is. `mopm yank --group <id>` yanks or restores what a group
published.

Nothing here is about how a staged set is made. Whatever makes it writes the
files below; `publish --staged` reads them and checks them before it sends a
request.

## The directory

```text
<dir>/
  plan.json                     read: the members, in dependency order
  <subdir>/<file>.conda         read: the files plan.json names, as `mopm pack` makes them
  <readme path>                 read: a member's readme, if plan.json names one
  state.json                    written: the group this directory is being published as
  report.json                   written: what each member came to
```

`<subdir>` is `noarch`, `linux-64`, `linux-aarch64` or `osx-arm64`, as in the
conda channel (`channel.md`). Other files in the directory are ignored.

## plan.json

```json
{
  "version": 1,
  "members": [
    { "name": "http_core", "version": "0.4.0", "action": "upload",
      "manifest_sha256": "<64 hex digits>",
      "files": [ { "subdir": "noarch", "filename": "mojo-http_core-0.4.0-mojo1.0.0_0.conda",
                   "sha256": "<64 hex digits>", "size": 12345 } ],
      "readme": "http_core/README.md" },
    { "name": "http_client", "version": "0.4.0", "action": "skip",
      "reason": "already published with these bytes" }
  ]
}
```

- `members` is in dependency order: a package comes after every package of the
  set it depends on. `publish --staged` uploads in this order.
- `action` is `upload`, `skip` or `refuse`.
  - `upload`: the member goes into the group. It needs `manifest_sha256` (the
    hash `mopm pack` prints, which the registry compares with the manifest in
    the archive; the registry's commit accepts a request without it, and then
    uses the hash it computes, but `mopm` always sends it so that the check
    between pack and publish stays) and one to 20 `files`, each 1 to 100,000,000 bytes, with its
    `sha256` and `size`. A file name is a plain name: no `/`, no `\`, none that
    starts with a dot. `readme` is optional: a path below the directory, up to
    64 KiB of UTF-8.
  - `skip`: the member is not in the group, because the registry already has it
    with these bytes. `reason` says why. The report names it.
  - `refuse`: the staging found the member cannot be published (a yanked version,
    a different file under a version that exists). `publish --staged` refuses the
    whole set before it sends a request. `reason` says why.
- A package appears once. A group has at most 500 members to upload.
- `version` is exactly `MAJOR.MINOR.PATCH`.

## What `publish --staged` does

1. Reads `plan.json`, refuses it if it is not as above or has a `refuse`
   member, and hashes every file and reads every readme. Nothing has been sent.
   `--dry-run` stops here and says what it would send; it reads no token and
   writes no file.
2. Reads the token (`$MOPM_TOKEN`, else the login's) and `state.json`. A state
   written for another registry or another plan (a different `plan.json`) is
   refused: remove the file to start a new group.
3. `POST /groups` with the members to upload. The registry's answer names a
   reservation for each member and a URL for each file it does not hold. While
   it answers `reserving`, the request is repeated. A group the registry
   already has in full (`validating`, `committed`, `visible`) skips to step 6.
4. PUTs each file the registry does not hold, member by member in the plan's
   order, with exactly the headers it named and no token. Each file is read
   again and checked against the plan as it is sent. After each, `state.json`
   is written.
5. `POST /groups/{id}/commit` with each member's `manifest_sha256` and readme.
6. Polls `GET /groups/{id}` until the group is `visible`. A group that ends
   `rejected`, `failed`, `expired`, `aborted` or `superseded` is a failure: the
   report names the member the registry blames, and none of the members is
   published. The wait is 600 seconds unless `--wait <seconds>` says.
7. Writes `report.json`, and exits 0 only if the group is visible.

### `--no-commit`, the resume, and `--abort`

`publish --staged <dir> --no-commit` runs steps 1 to 4 and stops: the group is
`open`, every file is held by the registry, nothing is committed, and nothing is
readable (a member of a group that is not visible is in no API answer, index or
channel). It prints the group id and the plan digest (the sha256 of
`plan.json`), writes `state.json` with `"staged": true`, writes `report.json`
with the run `outcome` `staged`, `group_status` `open`, `plan_sha256`, and each
member that is to be uploaded as `staged`, and **exits 0**: staging is a
success, and the only thing that distinguishes it from a publish is the outcome
word, which is why the outcome is not `published`. A group that is not `open`
when `--no-commit` reaches it (validating, committed, visible) is refused, exit
1.

The same command without `--no-commit`, in the same directory, resumes the same
group: `state.json`'s `plan_sha256` must still match `plan.json`, the registry
reports every file as held, nothing is sent again, and the run goes on with step
5. The token need not be the first run's, only the same actor's (a fresh `--oidc`
exchange of the same packages and versions is). Because the registry opens a group
that ended again as a next attempt when asked for it, a run that finds `staged:
true` in `state.json` first reads the group (`GET /groups/{id}`): `expired`,
`aborted`, `rejected`, `failed`, `superseded` or unknown ends the run with exit 1
and `nothing was sent`, and `state.json` is kept; the caller removes it to stage
again. `committed` becomes true and `staged` false in `state.json` when the commit
is sent.

`publish --staged <dir> --abort` ends the group `state.json` names
(`DELETE /groups/{id}`), which also gives back the actor's place among its open
groups. It reads `plan.json` (for the packages of an `--oidc` exchange and the
digest) and `state.json`; it reads none of the set's files. `state.json` is left
with no group, and `report.json` has the `outcome` `aborted` (`nothing_to_abort`
when `state.json` named no group). A group that already ended without being
published is not an error (exit 0); a directory with no `state.json`, a state of
another registry or plan, and a group that was committed are (exit 1). `--abort`
cannot be combined with `--no-commit` or `--dry-run`.

`--registry` is required, with no default. A rerun after any failure sends the
same request and so asks for the same group: the registry's group id is a
function of the caller and the declared set. Files the registry holds are not
sent again; a group that expired is opened again with the next attempt.

- A **404** from `POST /groups` with no error code or with `route_not_found`
  means the registry has no group publish: the run is refused and nothing is
  uploaded.
- A **429** stops the run where it is, prints how long to wait, and is never
  retried into the limit. The state is kept; run the same command later. The one
  exception: a PUT or a poll answered 429 with a `Retry-After` of 20 seconds or
  less waits that long and is sent again.
- Every request has a time limit, `--timeout` (default 30 seconds): to connect,
  and then for the server on any read or write. A request that is idempotent (the
  PUTs of files, the polls) is repeated at most `--retries` times (default 3)
  with jittered waits when the connection fails or times out or the answer is
  500, 502, 503 or 504; any other 4xx is final. The create and the commit are
  sent once.
- The token goes only to the registry's API, as a bearer token. It is never
  printed, never in a file, and not in the environment of any program mopm
  starts.

## state.json

```json
{ "registry": "<the registry's API root>", "plan_sha256": "<sha256 of plan.json>",
  "group_id": "grp_...", "attempt": 1, "committed": false,
  "uploaded": [ "http_core/noarch/mojo-http_core-0.4.0-mojo1.0.0_0.conda" ] }
```

Written before the first request (with no `group_id`) so a directory that
cannot be written is found while nothing is held. `uploaded` lists
`<package>/<subdir>/<file name>` for each file the registry holds.

## report.json

```json
{ "run_id": "<16 hex digits, new for each run>", "registry": "<API root>",
  "group_id": "grp_...", "group_status": "visible", "outcome": "published",
  "members": [
    { "name": "http_core", "version": "0.4.0", "outcome": "published",
      "files": [ { "subdir": "noarch", "filename": "...", "sha256": "..." } ] },
    { "name": "http_client", "version": "0.4.0", "outcome": "skipped",
      "code": "already published with these bytes" } ] }
```

`outcome` of the run is `published`, `failed`, `rate_limited`,
`no_group_publish` or `timed_out`. `outcome` of a member is:

| outcome | meaning |
|---|---|
| `published` | the group is visible and the member is in it |
| `skipped` | the plan skipped it; `code` is the plan's reason |
| `rejected` | the registry named it as the reason the group ended; `code` is the registry's |
| `not_published` | the group ended, or the run was refused, with this member not published |
| `pending` | the run stopped (a failed PUT, a 429, a timeout) before the group was visible; a rerun continues it |

## mopm yank --group

```text
mopm yank --group <id> --registry <name> --reason <text>
mopm yank --group <id> --registry <name> --unyank
```

`PUT /groups/{id}/yank`, then polls the group until `yank.state` is `yanked`
(or `restored`). Only a group that is `visible` can be yanked. An unyank
restores the versions the group's yank changed and no others: a version yanked
by hand before stays yanked. `--registry` is required.

### When the caller's own open groups share a version

A different set that shares a `(name, version)` with one of the same caller's
open groups takes that version from it: the registry ends the earlier group as
`superseded` (the default, `"on_overlap": "supersede"` in the body of
`POST /groups`), and the earlier run's next poll sees `superseded` and fails as
above. Two runs of one caller that declare different bytes for one version are
the usual cause. The answer to the create that did this lists the ended groups
in `superseded`.

A publisher that wants the second run to fail at create instead sends
`"on_overlap": "refuse"`. The registry then ends nothing, leaves the earlier
group open with its versions held, and answers `group_conflict` with the reason
`overlap_refused` and the ids of the caller's own overlapping groups in the
message. The option is not part of the group id, so a repeated request is the
same group with either value. A registry that predates the option ignores it
and supersedes, without a `superseded` list; `mopm publish --staged` sends
neither today and keeps the default.

Every `group_conflict` also carries `error.reason`, so a publisher need not read
the message: `number_held` (a live group holds a version), `group_failed` (the
group failed and its versions are burned), `open_cap` (the caller has the most
groups open), `supersede_cap` (the set overlaps more open groups than one create
supersedes), `takeover_blocked` (a reserved version whose group has no header is
not free yet), `number_taken` (another publish took a version during the create)
and `overlap_refused`. A reason a client does not know is treated as none.

## The group id

The id of a group is a function of the caller and the declared set, and the
derivation is a stable interface of the hosted registry: a client can compute
the id without any record of it, then `GET /groups/{id}` answers `404
group_not_found` when the caller has no such group, and otherwise the group's
status and, for each member, its declared files (the read creates, reopens and
charges nothing; `POST /groups` of an ended group would reopen it as a next
attempt and charge the group allowance).

```text
group_id = "grp_" + first 32 lowercase hex digits of
           SHA-256( UTF-8 bytes of the compact JSON text of [ actor, set ] )
```

- `actor` is `u:<GitHub account id>` for an account's token (a CI token that
  acts for an account has the account's id), and `ci:gh-repo:<repository id>`
  for the token of a configured CI publisher, whichever token of that identity
  it is. A CI token of any other kind is `ci:<token id>`; it creates no group.
  A client that wants a stable id across runs uses an account token or a
  configured CI publisher, never a per-run token.
- `set` is the array of the members sorted by package `name`. A member is the
  array `[name, version, files]`; `version` is exactly `MAJOR.MINOR.PATCH`.
  `files` is the array of the member's files sorted by the text
  `<subdir>/<filename>`, and a file is the array `[subdir, filename, sha256,
  size]` with `sha256` in lowercase hex and `size` a JSON integer.
- "Compact" is JSON with no white space between tokens and strings written as
  JavaScript's `JSON.stringify` writes them. The order of members and files in
  the request, `on_overlap` and any other option are not part of the id.

For the actor `u:1234` declaring `alpha` 1.0.0 with the one file
`linux-64/mojo-alpha-1.0.0-mojo1.0.0_0.conda` (sha256: 64 times `a`, size 1000)
the text hashed is

```text
["u:1234",[["alpha","1.0.0",[["linux-64","mojo-alpha-1.0.0-mojo1.0.0_0.conda","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",1000]]]]]
```

and the id is `grp_750db8c095f4c2517cedf12a308149e5`. Further vectors, for a
configured CI publisher, several members and files sent out of order, and
one-field differences, are in the registry's test fixtures
(`service/api/test/fixtures/group-id-vectors.json`), and a test fails if any id
changes. A different derivation would be introduced under a new prefix, not as
a different hash under `grp_`.

The fake registry's group ids are opaque: they are not derived this way, and a
client must not compute them.

### What `GET /groups/{id}` adds for each member

`files` lists the facts the caller declared, `subdir`, `filename`, `sha256` and
`size`, sorted by `subdir` and `filename`, from the member's reserved version.
While the group is `open` each file also has `uploaded`: true when the file is in
storage at its declared size. For any other status `uploaded` is absent and the
registry makes no storage check. A member that is not reserved yet, or whose
version number another group or publish took after this group ended, has an
empty `files`. The answers of `DELETE /groups/{id}` and `PUT /groups/{id}/yank`
do not carry `files`. The access rule is the one every read of a group has: the
caller who created it, or an owner of every package in it (a token that acts for
an account must also cover every package); anyone else gets `404
group_not_found`, never 403.

### The group of a version

`GET /packages/{name}/{version}` carries `group_id` for a version a group
published, and no `group_id` for a version a single publish made. A version that
is still pending is not found. The id grants nothing: reading or yanking the
group keeps its own ownership and scope rules.

### A commit without `manifest_sha256`

`manifest_sha256` is optional in the commit of a single publish and in each
member of a group commit. When given it is checked as before (`invalid_request`
for a bad format, `sha256_mismatch` for a difference). When absent the version
holds the hash the registry computes from the archive, and a version whose files
carry different manifest bytes is rejected `manifest_invalid`; when the hash is
given, a file whose manifest differs from it is `sha256_mismatch` instead. A
repeat of a group commit must repeat which members gave the hash and what they
gave; otherwise it is another request and is refused (`group_commit_refused`). A
repeat of a single commit with the same upload ids resumes the same publish
whatever it says about the hash.
