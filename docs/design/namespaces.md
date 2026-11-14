# Package names in owner namespaces

Status: proposal, for the CEO's review before any implementation. It changes the public interface (manifest, API, index,
lock, channel, command line). No code changes in this PR. The spec text it implies is in `spec/proposed/namespaces.md`,
marked proposed; nothing reads that file, and the live specs are unchanged until the tasks in section 13 land.

A package's name becomes `<namespace>/<name>`, for example `komira-ai/json`. The namespace is a GitHub login: a user's
own login, or a GitHub organization's. Mojo code imports the last part only (`import json`). Two packages with the same
last part in one dependency closure are a build failure. Each namespace is its own conda channel
(`https://conda.mopm.dev/komira-ai/`). The global names on prod today are deleted, and the komira packages are
published again as `komira-ai/<name>` without the `komira_` prefix.

These are settled and not reopened here: the full-name form and the import name; user and organization namespaces from
GitHub; the import-name clash as a failure with no alias; one conda channel per namespace; deleting the global names
and publishing komira's packages again under `komira-ai/`.

## What exists today

- One flat name is the manifest key, the import name, the registry key, the index path, the lock key and the conda
  name: `spec/mopm-toml.md` (`name = "http_client"  # the import name and the registry name`), `spec/channel.md`
  (`mojo-<name>`), `spec/index.md` (`/index/<aa>/<bb>/<name>`). The grammar `^[a-z][a-z0-9_]{1,63}$` is pinned in
  `spec/api/openapi.yaml` (`Name`), `spec/index-record.schema.json`, `spec/lock.schema.json`,
  `spec/takedowns.schema.json` and in the service (`service/api/src/auth/tokens.ts` `NAME_PATTERN`, `index-files.ts`,
  `http/index-reader.ts`, `publish/indexer.ts`). The client's `nameProblem` (`src/core/manifest.zig`) also refuses
  Mojo keywords and builtins, so that a package can be imported.
- A package exists once claimed: `POST /packages/{name}/claim` (`service/api/src/publish/claim.ts`). First come;
  `name_too_similar` for near names; a fixed reserved set (`mopm`, `mojo`, `max`, `modular`, `std`, `stdlib`); a claim
  with no version expires after 30 days, though nothing frees an expired one yet. Owners are per package, keyed by
  GitHub numeric id, with invitations.
- Login is the GitHub device flow of an OAuth app with scope `read:user` (`service/api/src/auth/device-login.ts`). The
  registry reads `GET https://api.github.com/user` once (id, login, two-factor flag), stores the user by numeric id with
  the login as `handle` (refreshed at every login) and discards the GitHub token. It makes no other GitHub API call.
- CI publishing exchanges a GitHub Actions identity token (`POST /auth/oidc/exchange`). On prod the one configured
  publisher, the komira release workflow (the `PROD_CI_PUBLISHERS` entry in `service/infra/stacks/lib/api-stack.ts`),
  acts for the user account that holds every komira claim, and `service/api/src/auth/ci-publishers.ts` refuses a prod
  publisher without `acts_for`. The `trusted_publishers` table is keyed by package name.
- The channel is one tree at `https://conda.mopm.dev/<subdir>/`, one `repodata.json` per subdir for every package. The
  lock has one channel for every entry (`install_plan.buildLock` takes one `channel_url`).
- No check finds two packages with the same import name in one closure: the import name is the package name, so the
  only clash today is "same name", which resolution already unifies. Nothing requires the library directory
  (`[targets] lib`) to be named like the package.

## 1. Names

| part | grammar | example |
|---|---|---|
| namespace | a GitHub login, lower case: `^[a-z0-9]+(-[a-z0-9]+)*$`, 1 to 39 characters | `komira-ai` |
| name | unchanged: `^[a-z][a-z0-9_]{1,63}$` | `json` |
| full name | `<namespace>/<name>` | `komira-ai/json` |
| import name | the name, the part after `/` | `json` |

- One spelling. GitHub logins ignore case; mopm writes and accepts the lower-case form only, and refuses
  `Komira-AI/json` with a message that gives `komira-ai/json`. The registry answers a non-normalised namespace in a path
  with `invalid_namespace`, as it does for names today.
- The namespace and the name never mix: a namespace has `-` and never `_` or `.`; a name has `_` and never `-` or `.`.
- An import name is never a Mojo keyword or builtin (the lists in `src/core/manifest.zig`) and never one of today's
  reserved names (`mopm`, `mojo`, `max`, `modular`, `std`, `stdlib`). The registry now refuses these too, not only the
  client, so every published package can be imported.
- The library directory is the import name: `[targets] lib` defaults to `src/<import name>`, and a `path` whose last
  component differs is refused (new). Mojo finds a package by its directory or `.mojoc` name, so this is what makes
  the import name of section 4 the name Mojo uses.
- `name_too_similar` and the claim expiry are dropped. A name in your own namespace cannot squat anyone else's, and a
  look-alike namespace is a look-alike GitHub account, which the package page shows with its GitHub link.
- Reserved namespaces, never created, so that a channel URL is never ambiguous: every conda subdir shape,
  `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`, and the channel bucket's other top-level
  prefixes, `index`, `quarantine` and `native-mirror` (all the prefixes `service/infra/stacks/lib/channel-stack.ts`
  uses). A GitHub account with such a login can still publish in an organization's namespace.
- A GitHub login outside the grammar (an enterprise-managed login holds `_`) gets no user namespace; login still works,
  `whoami` says why, and the account can publish in organization namespaces.

## 2. Namespaces and GitHub identity

Accounts and namespaces are keyed by GitHub numeric id, never by login, and no namespace string is ever sent to GitHub.
A namespace is `{namespace, kind: user | org, github_id, created_at}`, plus `installation_id` for an organization;
`github_id` is the user's or the organization's id.

### 2.1 User namespaces

At every login the registry looks up the login it just read from GitHub. If no namespace has that string and the
string fits the grammar and is not reserved, it creates the user namespace `{<login>, user, <id>}`. If the account
already holds it, nothing changes. If another account holds it (section 2.3), the login creates nothing and `whoami`
says why. The login answer and `GET /api/v2/me` carry the account's user namespace; `mopm login` stores it in the
credentials file, and `mopm new` and `mopm init` default to it.

### 2.2 Organization namespaces

The registry gets a second GitHub integration: a GitHub App, "mopm registry", with one organization permission,
Members: read-only, and no repository permission. An organization owner installs it; installing it is itself an
owner's act on GitHub. The App never acts for users and holds no user token.

The membership check, used for every write in an organization namespace, works from ids only:

1. `GET /app/installations/{installation_id}`, as the App. The installation's `account.id` must equal the namespace's
   `github_id`; it gives the organization's current login. A missing installation or another id: refused with
   `namespace_unverified`, and the namespace is frozen.
2. `GET /user/{account id}`, with the installation token: the caller's current GitHub login.
3. `GET /orgs/{current org login}/memberships/{current user login}`, with the installation token. It passes only with
   `user.id` equal to the caller's id, `state: active` and `role` `admin` or `member`. 404 (not a member, an outside
   collaborator), `state: pending` or `role: billing_manager` is `not_namespace_member`, naming the namespace. Any other
   answer, or GitHub unreachable or rate limited, is `unavailable` naming GitHub.

- A pass is cached for 5 minutes per (organization id, account id) in a table with an expiry, so a removal from the
  organization takes effect within 5 minutes. A refusal is not cached, so a new member can publish at once. Writes
  are rare (a publish is a few calls); an installation token allows thousands of calls an hour.
- Creating the namespace: `POST /api/v2/namespaces {"namespace": "komira-ai"}` with a fresh session. The registry finds
  the App's installation on that login (`GET /orgs/komira-ai/installation`, the one call that takes a string, made
  only here), binds the installation's `account.id` and `installation_id`, and runs the check with role `admin`
  required and no cache.
- Renames on GitHub change nothing: every check goes from ids to current logins, so a renamed organization or member
  keeps writing in the namespace with no action, and a stranger who takes an old login never passes step 3, whose
  `user.id` is compared.
- The App uninstalled, or the organization deleted: step 1 fails, the namespace is frozen. Its packages keep resolving
  and installing; every write is refused. An admin unfreezes it by installing the App again and repeating
  `POST /api/v2/namespaces`, which binds the new installation only if its `account.id` is the namespace's
  `github_id`; an organization that took the old name has another id and is refused.
- Reads (index, channel, API reads) never call GitHub. No webhooks: every check is made at write time.

Why an App and not the login token: the login token is discarded on purpose (a stored token that reads every user's
organizations is a liability), and organizations may restrict OAuth apps' access to their data, which the App's own
installation is not subject to. The login stays an OAuth app because its `GET /user` carries the two-factor flag that
the login requires; whether a GitHub App's user token carries it is not established.

For `whoami` only, the login asks for `read:org` as well and records the organizations the user is an active member of
(`GET /user/memberships/orgs?state=active`, then the token is discarded as today). `GET /api/v2/me` lists the
organization namespaces among those, each checked live as above. An organization that restricts OAuth apps is missing
from that list, so `whoami` can omit a namespace the user can write; it never grants anything, and a write always runs
the check.

### 2.3 Renames: the old namespace stays reserved, never redirected

When a user or organization renames itself on GitHub, its namespace keeps its old string and stays bound to its numeric
id. The account keeps every right in it; `alice/json` stays `alice/json`. At the user's next login (for an
organization, when an admin creates it) the new login becomes a second namespace of the same account if it is free.
Packages never move between namespaces: a different full name is a different package. Whoever later takes the old
login on GitHub does not get the namespace, even an empty one: a rule that hands over empty namespaces needs a
"never used" test that a short-lived package defeats, and the old holder still owns it.

Why reserved and not redirected:

1. Published versions are immutable and name their dependencies by full name (`<name>.mopm.json`, the index, every
   lock). `alice/json` must mean the same package for as long as any of those exist.
2. A redirect from `alice` to `alice2` gives one package two names, and the lock and the import-name rule (section 4)
   key on the full name. It also has to end the day someone else takes `alice` on GitHub, and at that moment
   `alice/json` would silently resolve to a stranger's package. That is the repository hijack known from module
   systems that follow GitHub paths, the attack namespaces are meant to close.
3. Reserved namespaces cost little: a renamed account keeps its old namespace and gains the new one; only the next
   holder of an old login is without that one namespace, and the message says why.

A user account converted to an organization on GitHub keeps its id; its user namespace has nobody who can log in as it
and is frozen until an admin of the organization creates it as an organization namespace (same id, kind changed).

### 2.4 Who may do what

| action | user namespace | organization namespace |
|---|---|---|
| create the namespace | automatic at login | an active admin, with the App installed |
| create a package, publish, yank, unyank | the bound account | an active member or admin |
| CI publishing (trusted publisher) | operator configuration, as today | operator configuration, as today |
| takedown | operators | operators |

`role` in `GET /api/v2/me` is `owner` for the user's own namespace and GitHub's `admin` or `member` for an
organization's. Per-package owners and invitations do not exist in `/api/v2`: the namespace is the owner. Several
people maintaining a package use an organization.

Trusted publishers move from packages to namespaces: a publisher of `komira-ai` names the repository, workflow, ref,
environment and events as today, and its `repository_owner_id` must equal the namespace's GitHub id, so only a
repository the namespace's owner owns can publish there. The store keyed by package name gets a namespace key. The
prod `PROD_CI_PUBLISHERS` entry for the komira release becomes a publisher of `komira-ai` with no `acts_for`: the
namespace is the owner, so no user account stands in, and `ci-publishers.ts` accepts such a namespace publisher on
prod. A route to register publishers stays out of scope, as today.

API tokens keep their form: a `packages` list or `all_current`, now of full names. The list may name a package that does
not exist yet, in a namespace the account can write, so that a CI job holding an API token can publish a new package
(the token authorises the `PUT` of section 8; it creates nothing itself). Rights are checked when the token is used, so
a token stops working in an organization within 5 minutes of the account leaving it.

## 3. mopm.toml

```toml
[package]
name = "komira-ai/parquet"           # full name; the import name is "parquet"
version = "0.2.0"

[dependencies]
"komira-ai/json" = "0.1"             # a key with "/" is quoted in TOML
"alice/zstd" = { version = "1.4" }
"komira-ai/util" = { path = "../util", version = "0.1" }

[dev-dependencies]
"komira-ai/testkit" = { path = "../testkit" }

[targets]
lib = { path = "src/parquet" }       # the directory is the import name
```

- `[package] name` and every key of `[dependencies]` and `[dev-dependencies]` are full names. TOML needs the quotes
  around a key holding `/`; mopm's TOML reader already reads quoted keys (`src/core/toml.zig`).
- An un-namespaced name is refused, naming the key and giving the full form. With credentials for the registry:
  `dependency 'json' has no namespace: write it "<namespace>/json" = "0.1", for example "komira-ai/json"` (the example
  comes from a search, section 9), and `package name 'json' has no namespace: write name = "alice/json" (alice is your
  namespace), or another namespace you publish in`. Without credentials the message says `<your GitHub login>`.
- Path dependencies: the key must equal `[package] name` at the path, as today
  (`src/cli/install_cmd.zig` `addPathDep`, now comparing full names). A path package in another namespace is fine.
- Workspaces: mopm has no `[workspace]` table; members are path dependencies and `mopm stage --workspace-root`
  finds them by their `mopm.toml`. They are keyed by full name everywhere (plan, lock, unit graph). A `publish =
  false` helper also has a full name: one grammar, one message.
- `[native-dependencies]` keys are conda names and are unchanged. A Mojo package may share its import name with a native
  library (`komira-ai/zlib` and the conda `zlib`): the two tables never meet.

## 4. Two packages with one import name: a build failure

Mojo resolves `import json` by the package directory or `.mojoc` named `json`, so one closure can hold one package per
import name. There is no rename or alias.

- Where: `mopm lock` checks the resolved closure (registry packages, path packages and the root, `[dependencies]` and
  `[dev-dependencies]` together, since one lock serves both) before writing anything. The same rule is checked on every
  lock read (rule 10 of the proposed lock, for `sync`, `tree`, `plan`, `build`, `test`), and by `mopm plan` when it
  builds the unit graph, which `spec/unit-graph.md` already promises ("Two libraries of one name are refused").
- Resolution is unchanged: distinct full names are distinct packages. mopm does not search for other versions to avoid
  the conflict; the error is deterministic.
- The error names every package with that import name, sorted by full name, with the shortest dependency path from the
  root to each (ties broken by comparing the full names along the path as bytes), `(dev)` on a path that starts in
  `[dev-dependencies]`:

```text
error: 2 packages in the dependency closure have the import name 'json'; Mojo imports a package by the part after '/',
so a closure holds one package per import name:
  alice/json 1.4.2         alice/app -> alice/http 0.3.0 -> alice/json 1.4.2
  komira-ai/json 0.1.0     alice/app -> komira-ai/parquet 0.2.0 -> komira-ai/json 0.1.0
There is no rename: drop one of the dependencies that brings them in.
```

- The root counts: `alice/json` depending, at any depth, on `komira-ai/json` is the same error, with the root's path
  being the root alone. Every clashing import name is reported, sorted, before mopm stops. No lock is written; the exit
  code is the lock failure's (1).
- The publisher meets it first: `mopm pack` and `mopm publish` lock, so a package whose own closure clashes is not
  published. Two packages with one import name that never meet in a closure are no one's problem.
- It keeps the install prefix sound: the conda prefix's `lib/mojo/<import name>.mojoc` stays one file per closure.

## 5. One conda channel per namespace

```text
https://conda.mopm.dev/<namespace>/
  noarch/ linux-64/ linux-aarch64/ osx-arm64/
    repodata.json, repodata.json.zst, current_repodata.json
    mojo-<namespace>.<name>-<version>-<build>.conda
```

- The conda package name is `mojo-<namespace>.<name>`: `komira-ai/json` is `mojo-komira-ai.json` in
  `https://conda.mopm.dev/komira-ai/`, the file `mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda`. `.` is a valid conda
  name character that neither part of a full name has, so the name maps back to one full name, and a conda file name
  still parses (version and build are the last two `-` fields). Inside the archive nothing moves:
  `lib/mojo/json.mojoc` and `lib/mojo/json.mopm.json`, whose `name` is the full name.
- Why the namespace is in the conda name although the channel already carries it: conda's `depends` cannot name a
  channel. With `mojo-<name>`, a `depends` on `mojo-json` would be met by whichever channel the user lists first that
  has a `mojo-json`, any namespace's, and a pixi environment would install it with only a clobber warning. With the
  namespace in the name, `depends: mojo-komira-ai.json` means one package. It also cannot collide with the conda
  packages of the Mojo toolchain (`mojo-compiler`, `mojo-python`), which have no `.`.
- `depends` of another mopm package is `mojo-<namespace>.<name> <range>`.
- A pixi user adds the channel, then the package (pixi 0.79, the version this repository pins):

```sh
pixi workspace channel add https://conda.mopm.dev/komira-ai/
pixi add mojo-komira-ai.json
```

  A package whose closure spans namespaces needs each namespace's channel; the package page lists them. Two
  packages with one import name in a pixi environment are a file clash, which pixi reports as a clobber; mopm refuses
  it (section 4).
- The registry writes each namespace's repodata on its own, so publishing in one namespace never rewrites another's
  files.
- The flat root (`https://conda.mopm.dev/<subdir>/`) keeps a valid empty `repodata.json` per subdir after the deletion
  (section 12), so a conda client still listing it sees "no such package", not a broken channel.

## 6. The sparse index, version 2

- Path: `/index/v2/<aa>/<bb>/<namespace>/<name>`, `aa` and `bb` the namespace's first two and next two characters,
  padded with `_` as today (`komira-ai/json` is `/index/v2/ko/mi/komira-ai/json`). Sharding by the namespace keeps the
  top directories small as accounts grow; a namespace's packages share a directory.
- Each line has `"v": 2`, `name` the full name, `deps[].name` full names, and `files[]` with the conda file name and
  URL of section 5. Everything else is version 1's.
- `/index/v2/takedowns.json` holds full names.
- `/index/config.json` gains two optional keys: `index_versions` (the served versions, `[1, 2]`) and `api_v2_url`
  (`https://api.mopm.dev/api/v2`). A namespace's channel is `channel_url` + `<namespace>/`. A released mopm ignores
  both keys and reads version 1, which is empty once the global names are deleted. A mopm with namespaces refuses a
  registry whose `index_versions` lacks 2: "the registry at <url> serves no namespaced packages (index version 2); it
  is older than this mopm".

## 7. The lock, version 3

`lock_version` 3 has version 2's shape (top-level `mojo` list and per-version `artifacts`) for every project; a
`[toolchain] mojo` project gets a one-element `mojo`, the version that resolved.

- `name` and `deps` hold full names; entries sort by full name as bytes.
- `channels` stays the root project's set of channel roots (`https://conda.mopm.dev/`). An entry's `channel` is a root
  followed by the entry's namespace and `/`; rule 2 becomes "every `channel` is a listed root plus the entry's
  namespace". Rule 3: `url` is `<channel><subdir>/mojo-<namespace>.<name>-<version>-<build>.conda`. Rule 6 stays: a
  full name comes from at most one root.
- New rule 10: no two entries with different full names have the same import name.
- Locks of version 1 and 2 are still read, to say what to do: they cannot match a namespaced manifest, so `mopm lock`
  rewrites them, and `mopm sync --locked` refuses with "mopm.lock predates namespaces (lock_version 2); run
  'mopm lock'". An older mopm refuses version 3 with its existing "update mopm".

## 8. The registry API, version 2

`/api/v2` is served beside `/api/v1`. Every operation that takes or returns a package name takes a full name; the
others are the same operation at both prefixes. Path parameters are `{namespace}/{name}`; a version in a path still
starts with a digit, so `/versions` and `/{version}` stay apart.

| v1 | v2 |
|---|---|
| `GET /packages?q=` | `GET /packages?q=`: `q` is a name prefix, or `<namespace>/` with an optional name prefix; results are full names |
| `GET /packages/{name}` | `GET /packages/{namespace}/{name}`; `owners` is replaced by `namespace` (`NamespaceInfo`: namespace, kind, GitHub id, current login, `frozen`) |
| `POST /packages/{name}/claim` | `PUT /packages/{namespace}/{name}`, no body: create in a namespace the caller can write; 201 created, 200 if it exists |
| `GET /packages/{name}/versions` | `GET /packages/{namespace}/{name}/versions` |
| `GET, PUT /packages/{name}/owners`, `DELETE .../owners/{github_id}` | removed: the namespace is the owner (2.4) |
| `GET /me/invitations`, `POST .../accept` | removed |
| `GET /packages/{name}/{version}` | `GET /packages/{namespace}/{name}/{version}` |
| `POST /packages/{name}/{version}/files`, `.../publish`, `.../yank` | the same under `/packages/{namespace}/{name}/{version}` |
| `GET /me` | `GET /me`: `namespaces: [{namespace, kind, role, packages}]` instead of `packages` and `pending_invitations`; `unavailable_namespace` when another account holds the caller's login |
| `POST /me/tokens` | the same; `packages` holds full names |
| `POST /auth/oidc/exchange` | the same; `name` and `packages[].name` are full names, matched to the namespace's publishers; it mints a token and creates nothing |
| `POST /groups`, `GET /groups/{id}`, commit, yank | the same; members' `name` are full names |
| (none) | `POST /namespaces` (create or re-verify an organization namespace), `GET /namespaces/{namespace}` |

- Creating a package: `PUT` is the only way. It checks the caller's right to write the namespace first (a session, an
  API token whose `packages` names it, or a trusted publisher's token minted for it), then answers 201, or 200 when it
  exists. No 30-day expiry, no similarity check; the per-account limit of 50 a day stays. `mopm publish` sends it when
  the package does not exist, so publishing a new package is one command.
- New error codes: `invalid_namespace` (400), `namespace_not_found` (404), `not_namespace_member` (403),
  `namespace_unverified` (403, the App is not installed, or its account is not the namespace's), `namespace_reserved`
  (403).
- `/api/v1` after v2 ships: reads answer as before; creating a flat package (`claimPackage`, and the OIDC `packages`
  form for a name nobody has) is refused with the existing `name_reserved` (403), hint "package names are in namespaces
  now; update mopm". Publishing new versions of existing flat names keeps working until the deletion, so the komira
  release does not break before it moves.

## 9. Command line

| command | today | with namespaces |
|---|---|---|
| `mopm new <name>` | `[package] name = "<name>"`, directory `<name>` | `mopm new json` writes `name = "<ns>/json"`, `<ns>` the user namespace stored by `mopm login` for `--registry` (default prod); `mopm new komira-ai/json` names the namespace. The directory, `src/json/` and `tests/test_json.mojo` use the import name |
| `mopm init` | name from the directory | `<ns>/<directory name>`; `--name` takes a full or bare name, as `new` does |
| (no stored namespace, bare name) | | refused: "mopm new json needs a namespace: run 'mopm login' (your GitHub login is your namespace) or name it, as in 'mopm new <your login>/json'". The full form works offline |
| `mopm add <name>` | adds `<name>` | `mopm add komira-ai/json[@0.1]`; a bare name is refused with up to 5 full names whose name part is it, from `GET /api/v2/packages?q=` (a suggestion, never a substitute) |
| `mopm login` | stores token and handle | also stores the user namespace (one more optional key in `credentials.json`) |
| `mopm whoami` | handle, packages | handle, then each namespace with its kind and role, then its packages |
| `mopm publish` | uploads | creates the package if it does not exist (`PUT`), then uploads |
| `mopm stage` | members by name | members by full name; `--artifacts <dir>/<subdir>/<namespace>/<name>.mojoc` |
| `mopm tree`, `plan`, errors | names | full names |

## 10. Other formats

- `<name>.mopm.json` (`spec/package-metadata.schema.json`): `schema` 2; `name` and `deps[].name` are full names. The
  file keeps its path, `lib/mojo/<import name>.mopm.json`. An older mopm refuses schema 2, as the spec says; it only
  meets one through a namespace channel.
- The unit graph (`spec/unit-graph.md`): format 6. Unit ids carry the full name,
  `komira-ai/json@0.1.0#mojo1.0.0/lib`; a reader splits at the first `@` (neither part of a name has `@`), so the `/` of
  the name and the `/<mode>` stay apart. A native unit is `native:komira-ai/zlib/<id>`; the id is after the last `/`.
  `package` holds the full name; a new `import` field holds the import name; outputs stay `<import name>.mojoc`.
- The staged set (`spec/staged-set.md`): `plan.json` `version` 2, members' `name` full names; files stay at
  `<dir>/<subdir>/<file>.conda`, which no longer collide since conda names carry the namespace. The group's `set` digest
  is over full names. A version 1 directory is refused, naming `plan.json`: stage it again.

## 11. Compatibility

Every format that changes gets a new version served or read beside the old one: API v2 beside v1, index v2 beside v1
(two optional `config.json` keys), lock 3 (1 and 2 still read), metadata schema 2, unit graph 6, plan.json 2. None of
these can be an optional field of the old version: each re-means `name` (a flat name becomes a full name), and an old
reader that ignored the new field would misread the name instead of refusing. Three departures from additive change
follow from the settled decisions:

- mopm.toml: an un-namespaced name, accepted today, is refused, with the full form in the message.
- `/api/v1` stops creating packages, with an existing code and status.
- The global names are deleted, so a released mopm finds nothing: "<name> (required by mopm.toml) is not in the
  registry's index", and a lock pinning them fails at the download with its taken-down message.

What each side sees; task C6 holds each row, modelled on `tests/drivers/compat_v0_0_104_test.zig` (the previous release's
command line and fake registry, byte for byte, against the current ones):

| reader | data | result |
|---|---|---|
| previous release | the namespaced registry | flat reads work until the deletion, then "not in the registry's index"; flat creation refused `name_reserved` with the update hint |
| previous release | a namespaced `mopm.toml` | refused by its `nameProblem`, naming the key |
| previous release | lock 3, metadata schema 2, plan.json 2, unit graph 6 | each refused with its existing "unknown version" message; nothing is misread |
| this release | the previous release's fake registry | refused: no index version 2, the message of section 6 |
| this release | a lock of version 1 or 2 | `mopm lock` rewrites it; `--locked` refuses with the message of section 7 |
| this release | a plan.json 1 | refused naming the file |

## 12. Migration of prod

### 12.1 The global names

Measured on 2026-11-13 from prod, read-only: `GET https://api.mopm.dev/api/v1/packages?limit=100` followed through
`next_cursor` to the end (139 packages), and `GET /api/v1/packages/{name}/owners` for each (all 139 have one owner, the
same user account, which the prod CI publisher acts for). The komira column is `src/*/mopm.toml` in komira-ai/komira
`main` cloned the same day: 66 komira packages have a `mopm.toml` and are the 66 published ones; 57 `komira_*` names
are claims with no version and no `mopm.toml`; the 16 `kci_*` packages have no source in komira `main`, and no package
outside them depends on one (`depends` of every entry of `https://conda.mopm.dev/linux-64/repodata.json`, the same day).

New name: `komira-ai/<x>` is published again; `(komira-ai/<x>)` is not published again, and is the name it would get
when komira gives it a `mopm.toml`; none: deleted only. "claim" is a claim with no version. Every listed name is
deleted. The `hash` and `async` rows carry the proposed renames of 12.2.

| claimed name | on prod | new name | note |
|---|---|---|---|
| `kci_api` | 0.1.337 | none |  |
| `kci_artifact` | 0.1.337 | none |  |
| `kci_artifact_manifest` | 0.1.337 | none |  |
| `kci_artifact_proto` | 0.1.337 | none |  |
| `kci_cell` | 0.1.337 | none |  |
| `kci_deploy_model_proto` | 0.1.337 | none |  |
| `kci_logs` | 0.1.337 | none |  |
| `kci_manifest_proto` | 0.1.337 | none |  |
| `kci_params` | 0.1.337 | none |  |
| `kci_reconciler` | 0.1.337 | none |  |
| `kci_release_channel` | 0.1.337 | none |  |
| `kci_release_machine` | 0.1.337 | none |  |
| `kci_resource_proto` | 0.1.337 | none |  |
| `kci_validator_report` | 0.1.337 | none |  |
| `kci_validator_rows` | 0.1.337 | none |  |
| `kci_workflow_check` | 0.1.337 | none |  |
| `komira_agg` | claim | (`komira-ai/agg`) |  |
| `komira_agg_api` | claim | (`komira-ai/agg_api`) |  |
| `komira_anomaly` | 0.1.344 | `komira-ai/anomaly` |  |
| `komira_arrow` | claim | (`komira-ai/arrow`) |  |
| `komira_arrow_ipc` | claim | (`komira-ai/arrow_ipc`) |  |
| `komira_async` | claim | (`komira-ai/async_rt`) | `async` is a keyword (12.2) |
| `komira_async_api` | 0.1.344 | `komira-ai/async_api` |  |
| `komira_atomic_alias` | 0.1.344 | `komira-ai/atomic_alias` |  |
| `komira_avro` | claim | (`komira-ai/avro`) |  |
| `komira_awslc` | 0.1.344 | `komira-ai/awslc` |  |
| `komira_batch_eval` | claim | (`komira-ai/batch_eval`) |  |
| `komira_bench` | 0.1.344 | `komira-ai/bench` |  |
| `komira_bench_data` | claim | (`komira-ai/bench_data`) |  |
| `komira_bench_duckdb` | claim | (`komira-ai/bench_duckdb`) |  |
| `komira_bench_report` | 0.1.344 | `komira-ai/bench_report` |  |
| `komira_broker_proto` | 0.1.344 | `komira-ai/broker_proto` |  |
| `komira_buffer` | 0.1.344 | `komira-ai/buffer` | a std module in older Mojo (12.2) |
| `komira_bump_arena` | 0.1.344 | `komira-ai/bump_arena` |  |
| `komira_calendar` | 0.1.344 | `komira-ai/calendar` | Python stdlib name |
| `komira_calendar_ics` | 0.1.344 | `komira-ai/calendar_ics` |  |
| `komira_calendar_proto` | 0.1.344 | `komira-ai/calendar_proto` |  |
| `komira_chat_proto` | 0.1.344 | `komira-ai/chat_proto` |  |
| `komira_clock` | 0.1.344 | `komira-ai/clock` |  |
| `komira_codeworks_api` | 0.1.344 | `komira-ai/codeworks_api` |  |
| `komira_collections` | 0.1.344 | `komira-ai/collections` | also `std.collections`; Python stdlib name (12.2) |
| `komira_column_format` | claim | (`komira-ai/column_format`) |  |
| `komira_column_kernels` | claim | (`komira-ai/column_kernels`) |  |
| `komira_compression` | 0.1.344 | `komira-ai/compression` | Python stdlib name |
| `komira_contacts_proto` | 0.1.344 | `komira-ai/contacts_proto` |  |
| `komira_content_line` | 0.1.344 | `komira-ai/content_line` |  |
| `komira_counters` | 0.1.344 | `komira-ai/counters` |  |
| `komira_crm_proto` | 0.1.344 | `komira-ai/crm_proto` |  |
| `komira_crypto` | 0.1.344 | `komira-ai/crypto` |  |
| `komira_csv` | claim | (`komira-ai/csv`) | Python stdlib name |
| `komira_datetime` | 0.1.344 | `komira-ai/datetime` | Python stdlib name |
| `komira_dynamic_filter` | 0.1.344 | `komira-ai/dynamic_filter` |  |
| `komira_encoding` | 0.1.344 | `komira-ai/encoding` |  |
| `komira_engine_runtime` | claim | (`komira-ai/engine_runtime`) |  |
| `komira_exec_types` | claim | (`komira-ai/exec_types`) |  |
| `komira_expr` | claim | (`komira-ai/expr`) |  |
| `komira_fork_join` | 0.1.344 | `komira-ai/fork_join` |  |
| `komira_fs` | claim | (`komira-ai/fs`) |  |
| `komira_hash` | 0.1.344 | `komira-ai/hashing` | `hash` is a builtin (12.2) |
| `komira_host` | 0.1.344 | `komira-ai/host` |  |
| `komira_host_profile` | claim | (`komira-ai/host_profile`) |  |
| `komira_job_report_proto` | 0.1.344 | `komira-ai/job_report_proto` |  |
| `komira_join_assembly` | claim | (`komira-ai/join_assembly`) |  |
| `komira_json` | 0.1.344 | `komira-ai/json` | Python stdlib name |
| `komira_json_index` | claim | (`komira-ai/json_index`) |  |
| `komira_jsonl` | claim | (`komira-ai/jsonl`) |  |
| `komira_kafka_server` | 0.1.344 | `komira-ai/kafka_server` |  |
| `komira_kernels` | claim | (`komira-ai/kernels`) |  |
| `komira_kg_mode` | 0.1.344 | `komira-ai/kg_mode` |  |
| `komira_kg_spec` | 0.1.344 | `komira-ai/kg_spec` |  |
| `komira_libc` | 0.1.344 | `komira-ai/libc` |  |
| `komira_log` | 0.1.344 | `komira-ai/log` |  |
| `komira_lowering` | claim | (`komira-ai/lowering`) |  |
| `komira_lz4` | 0.1.344 | `komira-ai/lz4` |  |
| `komira_mail_address` | 0.1.344 | `komira-ai/mail_address` |  |
| `komira_mail_message` | 0.1.344 | `komira-ai/mail_message` |  |
| `komira_managed_mail_proto` | 0.1.344 | `komira-ai/managed_mail_proto` |  |
| `komira_mcp_server` | 0.1.344 | `komira-ai/mcp_server` |  |
| `komira_metrics` | 0.1.344 | `komira-ai/metrics` |  |
| `komira_morsel` | claim | (`komira-ai/morsel`) |  |
| `komira_name_registry` | 0.1.344 | `komira-ai/name_registry` |  |
| `komira_objectstore` | claim | (`komira-ai/objectstore`) |  |
| `komira_op_agg_distinct` | claim | (`komira-ai/op_agg_distinct`) |  |
| `komira_op_agg_hash` | claim | (`komira-ai/op_agg_hash`) |  |
| `komira_op_agg_row_api` | claim | (`komira-ai/op_agg_row_api`) |  |
| `komira_op_agg_slab` | claim | (`komira-ai/op_agg_slab`) |  |
| `komira_op_agg_state` | claim | (`komira-ai/op_agg_state`) |  |
| `komira_op_asof` | claim | (`komira-ai/op_asof`) |  |
| `komira_op_join_build` | claim | (`komira-ai/op_join_build`) |  |
| `komira_op_join_probe` | claim | (`komira-ai/op_join_probe`) |  |
| `komira_op_join_stage` | claim | (`komira-ai/op_join_stage`) |  |
| `komira_op_sort` | claim | (`komira-ai/op_sort`) |  |
| `komira_op_sources` | claim | (`komira-ai/op_sources`) |  |
| `komira_op_typed_source_api` | claim | (`komira-ai/op_typed_source_api`) |  |
| `komira_op_window` | claim | (`komira-ai/op_window`) |  |
| `komira_operator_api` | claim | (`komira-ai/operator_api`) |  |
| `komira_parquet` | claim | (`komira-ai/parquet`) |  |
| `komira_parquet_api` | 0.1.344 | `komira-ai/parquet_api` |  |
| `komira_parquet_codec` | claim | (`komira-ai/parquet_codec`) |  |
| `komira_parquet_scan` | claim | (`komira-ai/parquet_scan`) |  |
| `komira_physical_plan` | claim | (`komira-ai/physical_plan`) |  |
| `komira_plan_expr` | claim | (`komira-ai/plan_expr`) |  |
| `komira_plan_ir` | claim | (`komira-ai/plan_ir`) |  |
| `komira_plan_proto` | 0.1.344 | `komira-ai/plan_proto` |  |
| `komira_plan_stats` | claim | (`komira-ai/plan_stats`) |  |
| `komira_plan_wire` | claim | (`komira-ai/plan_wire`) |  |
| `komira_proto_codec` | 0.1.344 | `komira-ai/proto_codec` |  |
| `komira_protobuf` | 0.1.344 | `komira-ai/protobuf` |  |
| `komira_resources` | 0.1.344 | `komira-ai/resources` |  |
| `komira_retry` | 0.1.344 | `komira-ai/retry` |  |
| `komira_row_format` | claim | (`komira-ai/row_format`) |  |
| `komira_rowcell` | 0.1.344 | `komira-ai/rowcell` |  |
| `komira_runtime_paths` | 0.1.344 | `komira-ai/runtime_paths` |  |
| `komira_scalar_arithmetic` | 0.1.344 | `komira-ai/scalar_arithmetic` |  |
| `komira_scan_planning` | claim | (`komira-ai/scan_planning`) |  |
| `komira_scan_source` | claim | (`komira-ai/scan_source`) |  |
| `komira_sdk` | claim | (`komira-ai/sdk`) |  |
| `komira_sdk_exec` | claim | (`komira-ai/sdk_exec`) |  |
| `komira_secret_registry` | claim | (`komira-ai/secret_registry`) |  |
| `komira_secret_store` | claim | (`komira-ai/secret_store`) |  |
| `komira_shuffle` | claim | (`komira-ai/shuffle`) |  |
| `komira_simd` | 0.1.344 | `komira-ai/simd` |  |
| `komira_snapshotter` | 0.1.344 | `komira-ai/snapshotter` |  |
| `komira_spsc_ring` | 0.1.344 | `komira-ai/spsc_ring` |  |
| `komira_sql` | claim | (`komira-ai/sql`) |  |
| `komira_supervisor` | claim | (`komira-ai/supervisor`) |  |
| `komira_supervisor_proto` | 0.1.344 | `komira-ai/supervisor_proto` |  |
| `komira_sync` | 0.1.344 | `komira-ai/sync` |  |
| `komira_test_run_id` | 0.1.344 | `komira-ai/test_run_id` |  |
| `komira_test_verdict` | 0.1.344 | `komira-ai/test_verdict` |  |
| `komira_textproto` | 0.1.344 | `komira-ai/textproto` |  |
| `komira_trace` | 0.1.344 | `komira-ai/trace` | Python stdlib name |
| `komira_udf` | claim | (`komira-ai/udf`) |  |
| `komira_uuid` | 0.1.344 | `komira-ai/uuid` | Python stdlib name |
| `komira_validation_run` | 0.1.344 | `komira-ai/validation_run` |  |
| `komira_vcard` | 0.1.344 | `komira-ai/vcard` |  |
| `komira_wkt` | 0.1.344 | `komira-ai/wkt` |  |
| `komira_xml` | 0.1.344 | `komira-ai/xml` | Python stdlib name |
| `komira_zlib` | 0.1.344 | `komira-ai/zlib` | Python stdlib name |

### 12.2 Clashes

Checked for every new name against: the other new names and komira's top-level `src/` directories (no duplicate: the
only top-level directory without the prefix is `tests`); mopm's keyword, builtin and reserved lists
(`src/core/manifest.zig`, `service/api/src/publish/claim.ts`); the Mojo standard library modules komira imports
(`git grep -h -oE '\b(from|import)\s+std\.[a-z_]+' -- '*.mojo'` in komira: 18 modules, among them `collections`); and the
Python standard library module names.

- `komira_hash`: `hash` is a Mojo builtin, which mopm refuses as a name. Proposed: `komira-ai/hashing`.
- `komira_async`: `async` is a Mojo keyword (`import async` does not parse). Not published today; when it is,
  proposed `komira-ai/async_rt`.
- `komira-ai/collections` and `komira-ai/buffer`: the standard library has `std.collections` (komira imports it) and
  has had a `buffer` module (not checked for Mojo 1.0). Since Mojo 1.0 imports the standard library as
  `std.<module>`, `import collections` is legal and shadows nothing, but a reader may take it for the standard one.
  Proposed: keep them.
- `json`, `csv`, `uuid`, `datetime`, `calendar`, `compression`, `collections`, `xml`, `zlib`, `trace`: also Python
  standard module names. Mojo's `import json` and `Python.import_module("json")` never meet; `zlib` also names a conda
  library, a separate table (section 3). Proposed: keep them.

### 12.3 The change to komira's imports

The import name is the directory name, so dropping the prefix renames each package's `src/komira_<x>` directory and
every import of it. Measured on the same clone (7436 `.mojo` files: `git ls-files '*.mojo' | wc -l`); `names.txt` is
the first column of the 66 rows of 12.1 whose new name has no parentheses, and `P` is
`$(paste -sd'|' names.txt)`:

| query (measured) | lines | files |
|---|---|---|
| `git grep -E "^\s*(from\|import)\s+($P)\b" -- '*.mojo'` | 5958 | 3153 |
| `git grep -E '^\s*(from\|import)\s+komira_' -- '*.mojo'` (every `komira_*` package) | 30830 | 5839 |
| `git grep -w -E "($P)"` (every file: BUCK, `.bzl`, docs, manifests, sources) | 25844 | 4389 |
| the same, `-- '*BUCK' '*.bzl'` only | 14684 | |
| `ls src \| grep -c '^komira_'` (top-level directories) | 260 | |

Proposed landing, in komira, not here: one mechanical pull request made by a rename tool (a Rust binary with its own
tests, per komira's rules) that renames directories and rewrites imports, BUCK targets and `mopm.toml` from a checked-in
mapping, the 66 rows of 12.1 with `hash` renamed. Only the 66 published packages are renamed: the other 194
`komira_*` directories are not mopm packages and keep their names until a later decision. That first change touches
25844 lines in 4389 files (measured, third row), of which 5958 import lines (first row), against 30830 import lines for
all 260 (inferred share: about a fifth). Reviewers check it by running the tool again. Each package's `mopm.toml` gets
`name = "komira-ai/<x>"` and quoted dependency keys in the same pull request, and the release workflow publishes
through the `komira-ai` trusted publisher. It lands after a mopm with task C4 is released, because a mopm without
namespaces cannot read the new manifests.

### 12.4 The deletion: a held tool

After namespaces ship and komira's release publishes under `komira-ai/` (so nothing publishes flat names any more), the
flat names are deleted by a held tool, `service/api/src/ops/delete-global-names` (TypeScript, next to the existing
group tool `ops/group-ops-bin.ts`):

- Dry run by default. `--stage beta|gamma|prod` is required. It never forces and never retries a refused step.
- The work list is read from the stage, not from a file: every package whose name has no namespace, with its versions,
  owners and trusted publishers, the channel objects under each subdir at the root (`<subdir>/mojo-<name>-*.conda`) and
  the version 1 index files. The dry run prints them per name, the totals, and a digest of the whole listing. Each stage
  has its own list.
- `--apply <digest>` lists again and refuses unless the digest is the dry run's, so a version published or a package
  created after the dry run stops it. It also refuses unless `config.json` serves index version 2 and `/api/v1`
  refuses flat creation.
- Per name, in this order: append a `delete_global` audit record (the audit log is append-only and keeps the history);
  take it out of the version 1 index and the root repodata; delete its channel objects; delete its version, owner and
  publisher rows; delete its package row last. A run that stops part way leaves the package row as the work list, and a
  second run also lists by bucket prefix, so it finishes what the first left; a run with nothing left does nothing.
- It runs as the takedown role (on beta and gamma, the takedown or the cleanup role), the only roles the tables and the
  channel bucket let delete. The bucket is versioned and has no expiry rule for package files, so the deleted `.conda`
  files stay restorable by operators as non-current versions; purging them is a separate decision. The tables have
  point-in-time recovery.
- API tokens naming the deleted packages are left to expire (90 days at most): they reach nothing.
- Order: beta, then gamma, then prod, each after its dry-run output has been read. Running it on prod is the CEO's step.

## 13. Implementation tasks and order

S is under 200 lines, M under 600, L more. Each lands with its spec moving from `spec/proposed/namespaces.md` into the
live spec, and its tests. Task ids are prefixed `ns-` so they read apart from rule ids.

Registry:

- ns-R1 (M) Namespaces store; user namespace at login; `read:org` and the login-time membership list; rename and
  reserved rules. Tests: create at login; a renamed account keeps the old namespace and gains the new one; a new holder
  of an old login gets none; reserved and out-of-grammar logins get none and log in.
- ns-R2 (M) The GitHub App and the membership check of 2.2. Tests against a fake GitHub: active admin and member;
  pending, billing manager, outside collaborator refused; a login reused by another id refused (`user.id` differs); an
  organization renamed keeps writing; a pass cached, a refusal not; App missing or on another account (frozen); GitHub
  down (`unavailable`, never a stale pass).
- ns-R3 (L) `/api/v2`: routes, `PUT` create, `/me`, tokens, namespace publishers (a namespace key on the publisher
  store; `ci-publishers.ts` accepts a namespace publisher without `acts_for` on prod), new errors; `/api/v1` stops
  creating. Contract examples for every v2 operation in `tests/contract/`.
- ns-R4 (M) Index v2 and the per-namespace channel writer: index paths, records, per-namespace repodata, conda names,
  `config.json` keys, empty root repodata. Infra: the App's secret beside the OAuth secret.

Client:

- ns-C5 (S) The fake registry (`registry/fake`) serves v2 and namespaces. First, since ns-C2 to ns-C4 test against it.
- ns-C1 (M) Names: full-name grammar in the manifest, `nameProblem`, refusal messages, the library directory rule;
  path and workspace matching by full name. Manifest goldens in `tests/manifest/`; no registry needed.
- ns-C2 (M) The import-name rule at lock, lock read and unit graph, with dependency paths. Tests: two registry
  packages; a path package against a registry package; the root against a dependency; a dev-dependency path; three
  packages; two clashing import names at once.
- ns-C3 (L) Index v2, lock 3, per-namespace channels and conda names, `config.json` keys; metadata schema 2; unit
  graph 6; plan.json 2.
- ns-C4 (M) Commands: `new`, `init`, `add`, `login`, `whoami`, `publish` (create), `stage`. Goldens `tests/new/`,
  `tests/golden/`, examples and docs (`docs/`, `README.md`, `spec/` from proposed to live).
- ns-C6 (M) The cross-version test of section 11.
- ns-C7 A mopm release with ns-C1 to ns-C6 (automatic from main).

Channel and site:

- ns-H1 (S) The package page: full names, the `[dependencies]` line with a quoted key, the pixi commands with the
  channel.
- ns-H2 (S) pixi 0.79 installs `mojo-komira-ai.json` from a namespace channel and a two-namespace closure, on a
  hosted runner.

Migration:

- ns-M0 (operator) Register the GitHub App; install it on `komira-ai`; an admin creates the `komira-ai` namespace;
  the `PROD_CI_PUBLISHERS` entry moves to `komira-ai`. These need the organization owner's and the operator's hands.
- ns-M1 (M) The held deletion tool (12.4) and its tests against fake stores: the order, the digest refusal, a run
  stopped part way and finished by the next.
- ns-M2 (komira) The rename tool and the rename pull request (12.3).
- ns-M3 Run ns-M1: beta, gamma, then prod, each after its dry run is read.

Order: ns-R1, ns-C5 and ns-C1 start at once. ns-R2 after ns-R1; ns-R3 after ns-R2; ns-R4 after ns-R3. ns-C2 after
ns-C1 and ns-C5; ns-C3 after ns-C2; ns-C4 after ns-C3; ns-C6 after ns-R3 and ns-C4; ns-C7 after ns-C6. ns-H1 and ns-H2
after ns-R4. ns-M0 after ns-R4 is on prod. ns-M1 at any time. ns-M2 after ns-C7 and ns-M0. ns-M3 after komira's first
`komira-ai/` publish. ns-R3 is the step a released mopm can observe (flat creation refused); ns-M3 is the one that
removes data.

## Decisions

Choices this design makes that the settled points leave open, one line of reasoning each.

1. Namespace grammar is the lower-case GitHub login: one spelling, as versions and names have.
2. A GitHub App with Members: read for organizations, the OAuth app kept for login: the login's two-factor check works
   today, and the App is not subject to an organization's OAuth app restrictions.
3. The membership check goes from ids to current logins and compares `user.id`: a reused login never passes.
4. Live check at write time, a pass cached 5 minutes, a refusal not cached, no webhooks: removal takes effect quickly,
   a new member at once, with no event machinery.
5. Old namespaces reserved, never redirected, empty or not: section 2.3.
6. No per-package owners in v2: the namespace is the owner; one way to share a package (an organization).
7. Creation is `PUT` alone, which `mopm publish` sends itself; the OIDC exchange only mints a token.
8. Claim expiry and the similarity check dropped: both guarded a shared flat namespace.
9. The registry refuses keywords, builtins and today's reserved names as import names: a published package must be
   importable, and `mojo`, `max`, `modular` stay unshadowed.
10. The library directory must be the import name: otherwise the import-name rule would not be the name Mojo uses.
11. Conda name `mojo-<namespace>.<name>`: a `depends` names one package across channels (question 1).
12. Index sharded by namespace: top directories stay small as accounts grow.
13. Lock 3 has version 2's shape for every project: one new shape, not two.
14. The import-name check covers dev-dependencies and the root: one lock and one test build hold them all.
15. Every format gets a new version instead of an optional field: old readers fail loudly, never misread a name.
16. The flat root keeps empty repodata: a conda client that lists it gets "no package", not a broken channel.
17. The proposed spec is a separate file, `spec/proposed/namespaces.md`: `spec/mopm-toml.md` and `spec/channel.md` are
    pages of the public site, which must not show a proposal as the contract.
18. The deletion tool lists its work from the stage and applies only the digest of its dry run: per-stage data, and no
    surprise between reading and deleting.
19. komira renames only its 66 published packages first: each renamed package is one a user can see.
20. The 139 names are listed in full, as asked, although they include the `kci_*` packages: they are public on the
    registry's package list today.

## Questions for the CEO

1. The conda name: `mojo-<namespace>.<name>` (proposed: `depends` is unambiguous across channels), or the shorter
   `mojo-<name>`, with which pixi's channel priority chooses between two namespaces' `mojo-json`?
2. `komira_hash` becomes `komira-ai/hashing`, and the future `async` package `komira-ai/async_rt`?
3. Keep `komira-ai/collections` and `komira-ai/buffer`, which shadow nothing since the standard library is `std.`?
4. komira renames its 66 published packages first and leaves the other 194 `komira_*` directories for later?
5. The 16 `kci_*` packages are deleted with no replacement (no source in komira `main`, no dependent outside them):
   confirmed?
