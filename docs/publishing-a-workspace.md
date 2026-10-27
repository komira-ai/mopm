# Publishing a workspace as one group

`mopm stage` packs the members of a workspace and checks them against a registry, and `mopm publish --staged` publishes the result through one group: the registry validates every member before anything is visible, and either all the members appear in its API at the same moment or none does. `mopm yank --group` takes a group back. This page is the reference for the three commands; the file formats are in [the staged set](../spec/staged-set.md), and publishing one package is in [getting started](getting-started.md).

## Group publish is off on the hosted registries

Group publish is deployed, and it is switched off. On `prod`, `gamma` and `beta` the registry answers a request to create a group with HTTP 404 until its operators enable groups for the account that publishes. Until then `mopm publish --staged` stops before it uploads anything and says that the registry has no group publish (see 404 below). Nothing on this page changes how `mopm publish` of a single package works; that command is the way to publish today.

## The steps

1. `mopm stage` finds the members of the workspace, puts them in dependency order, packs each one from its built artifacts, and checks each version against the registry. It reads no token and writes nothing to the registry.
2. `mopm publish --staged` sends the staged set to the registry as one group, uploads the files, commits the group and waits until it is visible.
3. If the release has to be taken back, `mopm yank --group` yanks every version the group published.

### mopm stage

```text
mopm stage --workspace-root <dir> [<package>...] --artifacts <dir> --compiler <mojo version> --out <dir> --registry <prod|gamma|beta|url>
```

| flag | meaning |
|---|---|
| `--workspace-root <dir>` | The directory searched for members: every directory below it that holds a `mopm.toml`. |
| `<package>...` | Optional package names. With names, the set is those packages and the members they depend on; without, every member. |
| `--artifacts <dir>` | Where the built `.mojoc` files are: `<dir>/<subdir>/<name>.mojoc` for each member. A member with `[native.<id>]` libraries also has each one's static archive beside it, at `<dir>/<subdir>/<name>.native/lib<id>.a` (the native's `soname`, if it sets one, is the file name); stage packs it as `mopm pack --native <id>=<subdir>:<file>` would, and refuses a member whose archive is missing or is not an `ar` archive. A native is built for one platform, so its `.mojoc` is never under `noarch`. |
| `--compiler <mojo version>` | The exact Mojo version the artifacts were built with. |
| `--out <dir>` | Where the staged set is written. |
| `--registry <name>` | Which registry the versions are checked against: `prod`, `gamma`, `beta` or a URL. There is no default. |

A member whose `mopm.toml` has `publish = false` under `[package]` (a test-support helper that other members use as a path dependency or dev-dependency, and that has no built artifact) is never staged. Without package names, `mopm stage` leaves it out and prints one line for it, `not staged <name> <version>: publish = false`. Naming it is refused. A member that is staged may not have one in its `[dependencies]`, directly or through other members (a consumer of the published package could not install it); `mopm stage` refuses that, naming both packages. A `[dev-dependencies]` entry on it is fine. `mopm pack` and `mopm publish` of one package refuse it in the same way. Every other command treats it like any member.

A dependency on another member (a path dependency, or a registry dependency whose name is a member's) is an edge: the dependency comes first, and a cycle is refused. Each file is packed twice and the two results must be the same bytes. For each member the registry is asked, without a token, what it holds for that version, and the member is given an action in `plan.json`:

| action | when |
|---|---|
| `upload` | the registry does not have the version |
| `skip` | the registry has the version with the same files |
| `refuse` | the registry has the version with other bytes, or the version is yanked, or its number is burned |

The run exits 0 when the set is staged, 1 when it refused or failed, and 2 for a usage error. A set with a `refuse` member is written all the same and `mopm stage` exits 1; `mopm publish --staged` will not send it.

### mopm publish --staged

```text
mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc] [--no-commit | --abort]
```

| flag | meaning |
|---|---|
| `--staged <dir>` | The staged set that `mopm stage` wrote. |
| `--registry <name>` | Required, with no default: a staged set is never published to a registry by accident. |
| `--config-dir <dir>` | The directory that holds the login (`mopm login --config-dir` writes it). |
| `--wait <seconds>` | How long to wait for the group to be visible. The default grows with the group: 600 seconds plus 5 seconds for each member (1450 seconds at 170 members, 2100 at 300), because validation and the chain take longer the more members there are. `--wait` replaces the default. |
| `--timeout <seconds>` | How long one request may wait: to connect, and then for the server on any read or write. 1 to 3600; the default is 30 seconds. A transfer that keeps moving is not cut short. |
| `--retries <n>` | How many times a request that can be repeated is repeated after it fails. 0 to 10; the default is 3. |
| `--dry-run` | Check the set and say what would be sent. It reads no token and writes no file. |
| `--oidc` | Inside a GitHub Actions job, take the registry token from the job's identity instead of `$MOPM_TOKEN` or the login. See "Publishing from GitHub Actions without a token" below. |
| `--no-commit` | Upload every file and stop with the group open. See "Staging a group and committing it later" below. |
| `--abort` | End the open group that `state.json` names. Reads `plan.json` and `state.json` only. Cannot be combined with `--no-commit` or `--dry-run`. |

The token is `$MOPM_TOKEN`, else the login's. It is read after the plan has been checked, goes only to the registry's API, is never printed, and is not in the environment of any program mopm starts. The uploads themselves carry no token.

Before it sends anything, mopm checks every file against `plan.json`. Then it asks for the group (one request, repeated while the registry is still reserving the members), uploads each file the registry does not hold, member by member in dependency order, commits the group, and waits. The command exits 0 only when the group is visible.

A member the registry rejects ends the whole group, and none of its members is published. A rejected group frees its version numbers. A group that fails after the registry has begun to copy files burns them, and the next run needs new version numbers.

#### Timeouts and retries

A request that gets no connection, or no answer, within `--timeout` seconds fails with `ConnectTimedOut` or `RequestTimedOut` named in the message, instead of waiting for ever. The uploads of a large set are many requests in a row, so a request that can be repeated without changing anything (the PUT of a file, the poll of the group) is repeated, up to `--retries` times, when the connection fails or times out or the server answers 500, 502, 503 (which is also how storage says `SlowDown`) or 504. The waits between tries grow from about a second to about eight, each with a random part so that clients that failed together do not return together. Any other 4xx (a 403 from an expired upload URL, for instance) is final at once, and so is a request that is not repeatable: the request that creates the group and the commit are sent once, and a rerun of the command is their retry. When the last try fails, the run stops as it always did and prints what that try got.

#### Resuming a run

`mopm publish --staged` writes `state.json` into the staged directory before its first request and updates it after every upload. After any failure (a file that did not upload, a registry that was busy, a wait that ran out) run the same command again (when the wait ran out, the group is still in progress, not failed, and the last lines of the output give the command that keeps waiting): it asks for the same group, does not send the files the registry already holds, and carries on. A `state.json` written for another registry or for another `plan.json` is refused; remove the file to start a new group.

#### Staging a group and committing it later

`--no-commit` splits the run in two so that something can happen between the upload and the commit, for instance the tests of a release that must pass on the exact files the registry will publish:

```text
mopm publish --staged <dir> --registry prod --no-commit    # creates (or resumes) the group, uploads every member, stops
...                                                        # test the files in <dir>; they are the files the group holds
mopm publish --staged <dir> --registry prod                # the same group: commit, wait until visible
mopm publish --staged <dir> --registry prod --abort        # instead, for a job that runs when the release failed
```

The staging run ends 0 with the run outcome `staged`. It prints `staged group <id>: open, <n> file(s) held, not committed, nothing readable` and the sha256 of `plan.json` (the plan digest, also `plan_sha256` in `report.json`), and then the command that commits. Its members have the outcome `staged`. The group is open: the registry has the bytes in quarantine, where nothing reads them, and no member is visible, in the API, the index or the channel. The registry gives the group up to 12 hours to be committed. Until then it holds one of the actor's places among its open groups.

The second run is the ordinary one, in the same directory. `state.json` (kept, with `"staged": true`) names the group, `plan_sha256` in it refuses a directory whose `plan.json` changed, and the run asks for the same group, which the registry reports with every file already held, so nothing is sent again. It then commits and waits as usual. The token may be a different one: with `--oidc` each run makes its own exchange (an identity token is single-use), and the registry gives a token for the same packages and versions again, as the same actor, so the second run reaches the group the first made. A token of another actor does not see the group (`group_not_found`).

Before it asks for the group, a run that resumes a staged group reads it. If the registry has ended it meanwhile (`expired` after its 12 hours, `aborted`, `rejected`) or does not know it, the run ends 1 with `group <id>, staged by an earlier run, is expired: it can no longer be committed; nothing was sent`, and `state.json` is kept. It does not open the group again as a new attempt: remove `state.json` and stage again, which is a decision of the person or job running it. A plain rerun after a failure that was not a staging run is unchanged and does open an ended group again.

`--no-commit` on a group that is already past open (validating, committed, visible) is refused: it stages a group before its commit.

`--abort` ends the group `state.json` names (`DELETE /groups/{id}`), which frees the actor's place at once; its version numbers stay free, since nothing was published. It reads `plan.json` and `state.json` but none of the set's files, so the job that runs after a failure does not need the bytes; with `--oidc` it makes its own exchange for the packages of the plan. The outcome is `aborted` in `report.json`, the members are `not_published`, and `state.json` is left with no group. It ends 0 when the group is aborted, when it had already ended without being published (the registry expired it), and when `state.json` names no group; it ends 1 for a directory with no `state.json`, a `state.json` of another registry or plan, and a group that was committed (the message says to use `mopm yank --group` if it becomes visible).

#### report.json

Every run that gets as far as the registry writes `report.json` into the staged directory: a new run id, the registry, the group id and status, the plan digest (`plan_sha256`), the outcome of the run and one entry for each member. The outcome of a run is `published`, `staged`, `aborted`, `nothing_to_abort`, `failed`, `rate_limited`, `no_group_publish` or `timed_out`. The outcome of a member is one of:

| outcome | meaning |
|---|---|
| `published` | the group is visible and the member is in it |
| `staged` | `--no-commit`: the member's files are uploaded and the group is open; nothing is visible |
| `skipped` | the plan skipped it |
| `rejected` | the registry named it as the reason the group ended |
| `not_published` | the group ended, or the run was refused, with this member not published |
| `pending` | the run stopped before the group was visible; a rerun continues it |

#### 404: the registry has no group publish

A 404 from the request that creates the group means the registry has no group publish, or has not enabled it for you. mopm says so, uploads nothing, and exits 1 with the outcome `no_group_publish`. Run it again when the registry has enabled groups.

#### 429: slow down

A 429 on a PUT or a poll that names a short wait (up to 20 seconds) is waited for and the request is sent again. Any other 429 stops the run where it is. mopm prints that the registry is rate limiting this client and, when the registry says how long, the number of seconds to wait; it never retries into the limit. The state is kept. The outcome is `rate_limited`. Run the same command later.

## Publishing from GitHub Actions without a token

`mopm publish --oidc` and `mopm publish --staged ... --oidc` get their registry token from the identity of the GitHub Actions job that runs them, so no token is stored as a secret. The job needs `permissions: id-token: write`; GitHub then gives the job two variables, `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, and mopm reads them. Outside such a job (either variable missing or empty) the command stops before it sends any request, says what the job needs, and exits 1. A `--dry-run` reads neither variable.

```text
mopm publish --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc --registry beta --oidc
```

The run, for a single package version (a staged set is described after the steps):

1. mopm asks GitHub for an identity token whose audience names the registry: `mopm.dev` for `prod`, and `<stage>.mopm.dev` for the others (`beta.mopm.dev` for `beta`, `gamma.mopm.dev` for `gamma`). The stage is the one the registry reports about itself. mopm sends the request token only to an `https` URL (or a loopback `http` one, for a test).
2. mopm posts that identity token, the package name and the version to the registry's `/auth/oidc/exchange` route. The registry answers a token that can publish that one package version and expires after 15 minutes, if the job's repository, workflow and environment match a trusted publisher registered for the package. If it does not, mopm prints the registry's message and exits 1; nothing is uploaded.
3. mopm publishes with that token.

The registry token is kept in memory. It is not written to a file (`--oidc` does not read or write `credentials.json`), it is not put in the environment, and it is never printed; neither is the identity token. `$MOPM_TOKEN` and a stored login are not used when `--oidc` is given. The two `ACTIONS_ID_TOKEN_REQUEST_` variables are, like `MOPM_TOKEN`, taken out of the environment of every program mopm starts. A rerun asks GitHub for a new identity token, so a run that is repeated never presents one twice.

An identity token can be exchanged once. So `mopm publish --staged --oidc` asks GitHub for one identity token and makes one exchange, in the `packages` form, that lists every member the plan uploads at its version (a plan's skipped members are not listed). The registry answers one token for exactly those package versions, and mopm uses it to create the group, upload the files, commit and wait. A set of one member takes the same path. The `packages` form is for a CI publisher the registry trusts by configuration; if the registry refuses it (`oidc_not_trusted`, or `not_owner` for a name that belongs to someone else), mopm prints the registry's message, ends 1, and creates no group. The registry takes at most 500 packages in one exchange (as many as a group may have), and a group is one unit, so a set of more than 500 members to upload is refused before GitHub or the registry is asked. `mopm publish --oidc` (one package) keeps the `name` and `version` form, the path of a package's registered trusted publisher.

## What a reader sees

The registry's API shows the group at the moment it is committed: a read of any one package, a search and the package pages show every member or none. That is the guarantee of the group, and it is the only one.

The command line does not read the API. `mopm add`, `mopm lock` and `mopm sync` read the registry's repodata and sparse index, which are files, and the registry releases those files in steps after the commit: first the repodata of each platform directory the group has files in, then the index file of each member, one at a time, dependencies first. Only after the last of them is the group `visible`. So an install that runs while a group is being released can see some of its members and not others, always dependencies before the packages that need them, and never an index entry that repodata does not list. A large group takes minutes, and the content delivery network's cache can add up to a minute. Treat a group as published when `mopm publish --staged` exits 0, and not before.

## Yanking a group

```text
mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]
mopm yank --group <id> --registry <prod|gamma|beta|url> --unyank [--config-dir <dir>] [--wait <seconds>]
```

The group id is the one `mopm publish --staged` printed and wrote into `report.json`. `--reason` is required for a yank, 1 to 280 characters, and is refused with `--unyank`. `--registry` is required, with no default. `--wait` is as for `publish --staged`.

A group yank is not one flip, and it is not the inverse of a publish. The registry records the request and answers at once; then it yanks the members one by one, and then it rebuilds the repodata and the index. The command waits until the group says the yank is `yanked` (or, after `--unyank`, `restored`). While it runs, some members are yanked and others are not. An unyank restores only the versions that this group's yank changed: a version somebody yanked by hand before stays yanked.

Only a group that is `visible` can be yanked. Before that the registry answers 409 with the code `group_not_settled`, and mopm prints its hint. A single version can still be yanked on its own through the registry's API at any time.

## Exit status

| command | 0 | 1 | 2 |
|---|---|---|---|
| `mopm stage` | staged | refused or failed | usage error |
| `mopm publish --staged` | the group is visible, or `--dry-run` checked the set, or every member was skipped, or `--no-commit` staged the group, or `--abort` ended it (or found nothing to end) | the plan or a file is wrong, the registry refused, or the run stopped | usage error |
| `mopm yank --group` | the yank is `yanked` (or `restored`) | refused, failed or gave up waiting | usage error |
