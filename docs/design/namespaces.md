# Package names in owner namespaces

Status: proposal, for the CEO's review before any implementation. It changes the public interface (manifest, API, index,
lock, channel, command line). No code changes in this PR. The spec text it implies is in `spec/proposed/namespaces.md`,
marked proposed; nothing reads that file, and the live specs are unchanged until the tasks in section 13 land.

A package's name becomes `<namespace>/<name>`, for example `komira-ai/json`. The namespace is a GitHub login: a user's
own login, or a GitHub organization's. Mojo code imports the last part only (`import json`). Two packages with the same
last part in one dependency closure are a build failure. No import name is a top-level module of the Mojo standard
library. Each namespace is its own conda channel (`https://conda.mopm.dev/komira-ai/`). The global names on prod today
are deleted, except the `kci_*` packages, which stay as they are. All 260 `komira_*` packages of komira are renamed
from the checked-in mapping `docs/design/namespaces-komira-map.tsv` (section 12), mostly by dropping the prefix, and
the published ones are published again as `komira-ai/<new name>`.

These are settled and not reopened here: the full-name form and the import name; user and organization namespaces from
GitHub; the import-name clash as a failure with no alias; one conda channel per namespace, with the conda name
`mojo-<namespace>.<name>`; no import name equal to a top-level module of the Mojo standard library; deleting the global
names except `kci_*`; renaming all 260 `komira_*` packages and publishing komira's packages again under `komira-ai/`.

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
- An import name is never a top-level module of the Mojo standard library (section 1.1). Code writes both
  `import std.collections` and the bare `import collections`, so a package with a standard module's name would shadow
  it or be shadowed by it.

### 1.1 The standard library's module names

The list is read from the toolchain mopm pins, not written from memory: `toolchain/versions.txt` lists `1.0.0`, and
`toolchain/mojo-1.0.0.pixi.lock` pins `mojo-compiler-1.0.0-release.conda` (linux-64, sha256
`4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3`). Its standard library is one file,
`lib/mojo/std.mojoc`: a 96-byte header (`MPKG`, then a 64-character hash) followed by one zstd frame, whose content
records the source path of each of its 251 files, `mojo/stdlib/std/<module>/...mojo`. The top-level modules are the
`<module>` components of those paths. The 251 paths are byte for byte the `.mojo` files under `mojo/stdlib/std/` at the
tag `mojo/v1.0.0` of modular/modular, which confirms the reading.

Mojo 1.0.0, 37 top-level modules (`_plugin`, the 38th directory, starts with `_` and is outside the name grammar
anyway):

`algorithm`, `atomic`, `base64`, `benchmark`, `bit`, `builtin`, `collections`, `compile`, `complex`, `documentation`,
`ffi`, `format`, `gpu`, `hashlib`, `io`, `iter`, `itertools`, `logger`, `math`, `memory`, `origin`, `os`, `pathlib`,
`prelude`, `pwd`, `python`, `random`, `reflection`, `runtime`, `stat`, `subprocess`, `sys`, `tempfile`, `testing`,
`time`, `traits`, `utils`.

- The rule, client and registry alike: a name in that list, or `std` itself (already reserved), is refused as an
  import name. The registry answers `PUT /packages/{namespace}/{name}` with `name_reserved` (403), message
  `'collections' is a module of the Mojo standard library (std.collections).`, hint `Choose another name.`. The client's
  `nameProblem` refuses it for `[package] name`, `mopm new` and `mopm init` with `package name 'collections' is a
  module of the Mojo standard library (std.collections); choose another name`.
- Where the list lives: one checked-in file per Mojo version, `toolchain/mojo-<version>.std-modules.txt`, one module per
  line, read from the paths above. The `toolchain` job of `.github/workflows/kpin-update.yml`, which solves each
  version's lock today and downloads no package, gains a step that downloads the pinned `mojo-compiler`, checks its
  sha256 against the lock, and writes the file (a Zig tool with Zig tests, task ns-C1), so the file is never written
  by hand. The client and the registry refuse the union over every version in `toolchain/versions.txt`; a unit test on each
  side checks that its list equals that union, so the two cannot drift. Tests never download the toolchain.
- A later Mojo version that adds a module: the module joins the union when that version joins `versions.txt`. The
  registry then refuses new packages with that name; a package published earlier under it keeps resolving and
  installing. The client refuses it as `[package] name` and only warns for a dependency key (naming the module and
  the dependency), so a project that depends on such a package keeps building.
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
- The flat root (`https://conda.mopm.dev/<subdir>/`) keeps a valid `repodata.json` per subdir after the deletion
  (section 12), holding only the kept `kci_*` packages (section 12.4), so a conda client still listing it sees "no such
  package" for a deleted name, not a broken channel.

## 6. The sparse index, version 2

- Path: `/index/v2/<aa>/<bb>/<namespace>/<name>`, `aa` and `bb` the namespace's first two and next two characters,
  padded with `_` as today (`komira-ai/json` is `/index/v2/ko/mi/komira-ai/json`). Sharding by the namespace keeps the
  top directories small as accounts grow; a namespace's packages share a directory.
- Each line has `"v": 2`, `name` the full name, `deps[].name` full names, and `files[]` with the conda file name and
  URL of section 5. Everything else is version 1's.
- `/index/v2/takedowns.json` holds full names.
- `/index/config.json` gains two optional keys: `index_versions` (the served versions, `[1, 2]`) and `api_v2_url`
  (`https://api.mopm.dev/api/v2`). A namespace's channel is `channel_url` + `<namespace>/`. A released mopm ignores both
  keys and reads version 1, which holds only the kept `kci_*` packages once the global names are deleted. A mopm with
  namespaces refuses a registry whose `index_versions` lacks 2: "the registry at <url> serves no namespaced packages
  (index version 2); it is older than this mopm".

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
  release does not break before it moves. After the deletion the only flat names left are the kept `kci_*` packages;
  `/api/v1` keeps serving them as it does today, and this design adds no way to move them into a namespace.

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
reader that ignored the new field would misread the name instead of refusing. Four departures from additive change
follow from the settled decisions:

- mopm.toml: an un-namespaced name, accepted today, is refused, with the full form in the message.
- `/api/v1` stops creating packages, with an existing code and status.
- The global names are deleted, except `kci_*`, so a released mopm finds nothing else: "<name> (required by mopm.toml)
  is not in the registry's index", and a lock pinning them fails at the download with its taken-down message. A
  released mopm still resolves and installs the kept `kci_*` packages.
- A name that a released mopm accepts may now be refused: a top-level module of the Mojo standard library (section 1.1).
  None of the 139 names on prod is one (12.1), and the mapping gives none of komira's packages one (12.2).

What each side sees; task C6 holds each row, modelled on `tests/drivers/compat_v0_0_104_test.zig` (the previous release's
command line and fake registry, byte for byte, against the current ones):

| reader | data | result |
|---|---|---|
| previous release | the namespaced registry | flat reads work until the deletion, then "not in the registry's index", except the kept `kci_*` packages, which keep resolving; flat creation refused `name_reserved` with the update hint |
| previous release | a namespaced `mopm.toml` | refused by its `nameProblem`, naming the key |
| previous release | lock 3, metadata schema 2, plan.json 2, unit graph 6 | each refused with its existing "unknown version" message; nothing is misread |
| this release | the previous release's fake registry | refused: no index version 2, the message of section 6 |
| this release | a lock of version 1 or 2 | `mopm lock` rewrites it; `--locked` refuses with the message of section 7 |
| this release | a plan.json 1 | refused naming the file |

## 12. Migration of prod

### 12.1 The global names and komira's packages

Measured on 2026-11-13 from prod, read-only: `GET https://api.mopm.dev/api/v1/packages?limit=100` followed through
`next_cursor` to the end (139 packages), and `GET /api/v1/packages/{name}/owners` for each (all 139 have one owner, the
same user account, which the prod CI publisher acts for). The `kci_*` packages have no source in komira `main`, and no
package outside them depends on one (`depends` of every entry of `https://conda.mopm.dev/linux-64/repodata.json`, the
same day).

The komira side is komira-ai/komira `main`, measured again on 2026-11-14 (its last commit predates both days, so both
measurements read the same tree): `git ls-tree -d --name-only main src/` gives 261 directories, the 260 `komira_*` and
`tests`; `git ls-tree -r --name-only main src/` finds a `mopm.toml` directly under 66 of them, and they are the 66
published on prod; the other 57 `komira_*` names on prod are claims with no version and no `mopm.toml`; 137 `komira_*`
directories have no `mopm.toml` and no name on prod.

Every `komira_*` directory is renamed (12.3), published or not. The mapping is checked in as
`docs/design/namespaces-komira-map.tsv`: 260 lines `<old directory name><TAB><new import name>`, no header, sorted by
the old name as bytes; the full name is `komira-ai/<new import name>`. It is the input of komira's rename tool (task
ns-M2) and the source of the table below, which adds the prod state and the 16 `kci_*` packages.

Columns: "on prod" is the latest version, "claim" for a claim with no version, `—` for no name on prod. "new name"
is `komira-ai/<x>` for a package that is published again (it has a `mopm.toml`), `(komira-ai/<x>)` for a directory
renamed in komira but not published, the name it gets when komira gives it a `mopm.toml`; "kept" for a `kci_*`
package, which is neither renamed nor deleted (12.4). Every other name on prod is deleted. A note says why a name is
not the old name without its `komira_` prefix.

| old name | on prod | new name | note |
|---|---|---|---|
| `kci_api` | 0.1.337 | kept: `kci_api` |  |
| `kci_artifact` | 0.1.337 | kept: `kci_artifact` |  |
| `kci_artifact_manifest` | 0.1.337 | kept: `kci_artifact_manifest` |  |
| `kci_artifact_proto` | 0.1.337 | kept: `kci_artifact_proto` |  |
| `kci_cell` | 0.1.337 | kept: `kci_cell` |  |
| `kci_deploy_model_proto` | 0.1.337 | kept: `kci_deploy_model_proto` |  |
| `kci_logs` | 0.1.337 | kept: `kci_logs` |  |
| `kci_manifest_proto` | 0.1.337 | kept: `kci_manifest_proto` |  |
| `kci_params` | 0.1.337 | kept: `kci_params` |  |
| `kci_reconciler` | 0.1.337 | kept: `kci_reconciler` |  |
| `kci_release_channel` | 0.1.337 | kept: `kci_release_channel` |  |
| `kci_release_machine` | 0.1.337 | kept: `kci_release_machine` |  |
| `kci_resource_proto` | 0.1.337 | kept: `kci_resource_proto` |  |
| `kci_validator_report` | 0.1.337 | kept: `kci_validator_report` |  |
| `kci_validator_rows` | 0.1.337 | kept: `kci_validator_rows` |  |
| `kci_workflow_check` | 0.1.337 | kept: `kci_workflow_check` |  |
| `komira_agg` | claim | (`komira-ai/agg`) |  |
| `komira_agg_api` | claim | (`komira-ai/agg_api`) |  |
| `komira_anomaly` | 0.1.344 | `komira-ai/anomaly` |  |
| `komira_arrow` | claim | (`komira-ai/arrow`) |  |
| `komira_arrow_ipc` | claim | (`komira-ai/arrow_ipc`) |  |
| `komira_async` | claim | (`komira-ai/async_rt`) | `async` is a Mojo keyword (12.2) |
| `komira_async_api` | 0.1.344 | `komira-ai/async_api` |  |
| `komira_atomic_alias` | 0.1.344 | `komira-ai/atomic_alias` |  |
| `komira_authz_api` | — | (`komira-ai/authz_api`) |  |
| `komira_avro` | claim | (`komira-ai/avro`) |  |
| `komira_aws_apigatewayv2` | — | (`komira-ai/aws_apigatewayv2`) |  |
| `komira_aws_core` | — | (`komira-ai/aws_core`) |  |
| `komira_aws_dynamodb` | — | (`komira-ai/aws_dynamodb`) |  |
| `komira_aws_dynamodbstreams` | — | (`komira-ai/aws_dynamodbstreams`) |  |
| `komira_aws_ec2` | — | (`komira-ai/aws_ec2`) |  |
| `komira_aws_ecr` | — | (`komira-ai/aws_ecr`) |  |
| `komira_aws_ecs` | — | (`komira-ai/aws_ecs`) |  |
| `komira_aws_iam` | — | (`komira-ai/aws_iam`) |  |
| `komira_aws_lambda` | — | (`komira-ai/aws_lambda`) |  |
| `komira_aws_lambda_http` | — | (`komira-ai/aws_lambda_http`) |  |
| `komira_aws_logs` | — | (`komira-ai/aws_logs`) |  |
| `komira_aws_metrics` | — | (`komira-ai/aws_metrics`) |  |
| `komira_aws_route53` | — | (`komira-ai/aws_route53`) |  |
| `komira_aws_s3` | — | (`komira-ai/aws_s3`) |  |
| `komira_aws_scheduler` | — | (`komira-ai/aws_scheduler`) |  |
| `komira_aws_secret_store` | — | (`komira-ai/aws_secret_store`) |  |
| `komira_aws_secretsmanager` | — | (`komira-ai/aws_secretsmanager`) |  |
| `komira_aws_ses` | — | (`komira-ai/aws_ses`) |  |
| `komira_aws_sesv2` | — | (`komira-ai/aws_sesv2`) |  |
| `komira_aws_sns` | — | (`komira-ai/aws_sns`) |  |
| `komira_aws_sqs` | — | (`komira-ai/aws_sqs`) |  |
| `komira_awslc` | 0.1.344 | `komira-ai/awslc` |  |
| `komira_azure_blob` | — | (`komira-ai/azure_blob`) |  |
| `komira_azure_core` | — | (`komira-ai/azure_core`) |  |
| `komira_batch_eval` | claim | (`komira-ai/batch_eval`) |  |
| `komira_bench` | 0.1.344 | `komira-ai/bench` |  |
| `komira_bench_corpus` | — | (`komira-ai/bench_corpus`) |  |
| `komira_bench_data` | claim | (`komira-ai/bench_data`) |  |
| `komira_bench_duckdb` | claim | (`komira-ai/bench_duckdb`) |  |
| `komira_bench_q6_phases` | — | (`komira-ai/bench_q6_phases`) |  |
| `komira_bench_report` | 0.1.344 | `komira-ai/bench_report` |  |
| `komira_bench_runner` | — | (`komira-ai/bench_runner`) |  |
| `komira_broker` | — | (`komira-ai/broker`) |  |
| `komira_broker_compaction` | — | (`komira-ai/broker_compaction`) |  |
| `komira_broker_coordinator` | — | (`komira-ai/broker_coordinator`) |  |
| `komira_broker_proto` | 0.1.344 | `komira-ai/broker_proto` |  |
| `komira_buffer` | 0.1.344 | `komira-ai/byte_buffer` | renamed by decision; not a module of Mojo 1.0's std (12.2) |
| `komira_bump_arena` | 0.1.344 | `komira-ai/bump_arena` |  |
| `komira_calendar` | 0.1.344 | `komira-ai/calendar` |  |
| `komira_calendar_ics` | 0.1.344 | `komira-ai/calendar_ics` |  |
| `komira_calendar_proto` | 0.1.344 | `komira-ai/calendar_proto` |  |
| `komira_calendar_store` | — | (`komira-ai/calendar_store`) |  |
| `komira_cdc_ingest` | — | (`komira-ai/cdc_ingest`) |  |
| `komira_chat_proto` | 0.1.344 | `komira-ai/chat_proto` |  |
| `komira_chat_store` | — | (`komira-ai/chat_store`) |  |
| `komira_chunk` | — | (`komira-ai/chunk`) |  |
| `komira_clock` | 0.1.344 | `komira-ai/clock` |  |
| `komira_codeworks_api` | 0.1.344 | `komira-ai/codeworks_api` |  |
| `komira_collections` | 0.1.344 | `komira-ai/containers` | `std.collections` (12.2) |
| `komira_column_format` | claim | (`komira-ai/column_format`) |  |
| `komira_column_kernels` | claim | (`komira-ai/column_kernels`) |  |
| `komira_comms_index` | — | (`komira-ai/comms_index`) |  |
| `komira_compression` | 0.1.344 | `komira-ai/compression` |  |
| `komira_connect` | — | (`komira-ai/connect`) |  |
| `komira_contacts` | — | (`komira-ai/contacts`) |  |
| `komira_contacts_proto` | 0.1.344 | `komira-ai/contacts_proto` |  |
| `komira_content_line` | 0.1.344 | `komira-ai/content_line` |  |
| `komira_counters` | 0.1.344 | `komira-ai/counters` |  |
| `komira_crm` | — | (`komira-ai/crm`) |  |
| `komira_crm_proto` | 0.1.344 | `komira-ai/crm_proto` |  |
| `komira_crypto` | 0.1.344 | `komira-ai/crypto` |  |
| `komira_csv` | claim | (`komira-ai/csv`) |  |
| `komira_datetime` | 0.1.344 | `komira-ai/datetime` |  |
| `komira_db` | — | (`komira-ai/db`) |  |
| `komira_db_postgres` | — | (`komira-ai/db_postgres`) |  |
| `komira_db_sqlite` | — | (`komira-ai/db_sqlite`) |  |
| `komira_decimal_literal` | — | (`komira-ai/decimal_literal`) |  |
| `komira_dispatch_agg_exec` | — | (`komira-ai/dispatch_agg_exec`) |  |
| `komira_dispatch_agg_folds` | — | (`komira-ai/dispatch_agg_folds`) |  |
| `komira_dispatch_join_kernels` | — | (`komira-ai/dispatch_join_kernels`) |  |
| `komira_dispatch_project` | — | (`komira-ai/dispatch_project`) |  |
| `komira_dispatch_scan` | — | (`komira-ai/dispatch_scan`) |  |
| `komira_dispatch_sources` | — | (`komira-ai/dispatch_sources`) |  |
| `komira_dynamic_filter` | 0.1.344 | `komira-ai/dynamic_filter` |  |
| `komira_encoding` | 0.1.344 | `komira-ai/encoding` |  |
| `komira_engine_runtime` | claim | (`komira-ai/engine_runtime`) |  |
| `komira_eval` | — | (`komira-ai/eval`) |  |
| `komira_exec_types` | claim | (`komira-ai/exec_types`) |  |
| `komira_expr` | claim | (`komira-ai/expr`) |  |
| `komira_flight` | — | (`komira-ai/flight`) |  |
| `komira_flight_server` | — | (`komira-ai/flight_server`) |  |
| `komira_fork_join` | 0.1.344 | `komira-ai/fork_join` |  |
| `komira_fs` | claim | (`komira-ai/fs`) |  |
| `komira_gcp_apigateway` | — | (`komira-ai/gcp_apigateway`) |  |
| `komira_gcp_artifactregistry` | — | (`komira-ai/gcp_artifactregistry`) |  |
| `komira_gcp_cloudresourcemanager` | — | (`komira-ai/gcp_cloudresourcemanager`) |  |
| `komira_gcp_cloudscheduler` | — | (`komira-ai/gcp_cloudscheduler`) |  |
| `komira_gcp_compute` | — | (`komira-ai/gcp_compute`) |  |
| `komira_gcp_core` | — | (`komira-ai/gcp_core`) |  |
| `komira_gcp_fcm` | — | (`komira-ai/gcp_fcm`) |  |
| `komira_gcp_firestore` | — | (`komira-ai/gcp_firestore`) |  |
| `komira_gcp_firestore_db` | — | (`komira-ai/gcp_firestore_db`) |  |
| `komira_gcp_iam` | — | (`komira-ai/gcp_iam`) |  |
| `komira_gcp_logging` | — | (`komira-ai/gcp_logging`) |  |
| `komira_gcp_monitoring` | — | (`komira-ai/gcp_monitoring`) |  |
| `komira_gcp_monitoring_client` | — | (`komira-ai/gcp_monitoring_client`) |  |
| `komira_gcp_run` | — | (`komira-ai/gcp_run`) |  |
| `komira_gcp_secret_store` | — | (`komira-ai/gcp_secret_store`) |  |
| `komira_gcp_secretmanager` | — | (`komira-ai/gcp_secretmanager`) |  |
| `komira_gcp_serviceusage` | — | (`komira-ai/gcp_serviceusage`) |  |
| `komira_gcp_storage` | — | (`komira-ai/gcp_storage`) |  |
| `komira_gcp_wif` | — | (`komira-ai/gcp_wif`) |  |
| `komira_git` | — | (`komira-ai/git`) |  |
| `komira_group_ratchet` | — | (`komira-ai/group_ratchet`) |  |
| `komira_grpc` | — | (`komira-ai/grpc`) |  |
| `komira_hash` | 0.1.344 | `komira-ai/hashing` | `hash` is a Mojo builtin; `std.hashlib.hash` (12.2) |
| `komira_host` | 0.1.344 | `komira-ai/host_probe` | `std.gpu.host` (12.2) |
| `komira_host_profile` | claim | (`komira-ai/host_profile`) |  |
| `komira_http_auth` | — | (`komira-ai/http_auth`) |  |
| `komira_http_client` | — | (`komira-ai/http_client`) |  |
| `komira_http_core` | — | (`komira-ai/http_core`) |  |
| `komira_http_server` | — | (`komira-ai/http_server`) |  |
| `komira_iceberg` | — | (`komira-ai/iceberg`) |  |
| `komira_iceberg_catalog` | — | (`komira-ai/iceberg_catalog`) |  |
| `komira_imap_server` | — | (`komira-ai/imap_server`) |  |
| `komira_job_report_proto` | 0.1.344 | `komira-ai/job_report_proto` |  |
| `komira_job_supervisor` | — | (`komira-ai/job_supervisor`) |  |
| `komira_join_assembly` | claim | (`komira-ai/join_assembly`) |  |
| `komira_jose` | — | (`komira-ai/jose`) |  |
| `komira_json` | 0.1.344 | `komira-ai/json` |  |
| `komira_json_index` | claim | (`komira-ai/json_index`) |  |
| `komira_jsonl` | claim | (`komira-ai/jsonl`) |  |
| `komira_jwks` | — | (`komira-ai/jwks`) |  |
| `komira_kafka_broker` | — | (`komira-ai/kafka_broker`) |  |
| `komira_kafka_server` | 0.1.344 | `komira-ai/kafka_server` |  |
| `komira_kernels` | claim | (`komira-ai/kernels`) |  |
| `komira_kg` | — | (`komira-ai/kg`) |  |
| `komira_kg_capture` | — | (`komira-ai/kg_capture`) |  |
| `komira_kg_code` | — | (`komira-ai/kg_code`) |  |
| `komira_kg_enrich` | — | (`komira-ai/kg_enrich`) |  |
| `komira_kg_format` | — | (`komira-ai/kg_format`) |  |
| `komira_kg_llm` | — | (`komira-ai/kg_llm`) |  |
| `komira_kg_mode` | 0.1.344 | `komira-ai/kg_mode` |  |
| `komira_kg_sources` | — | (`komira-ai/kg_sources`) |  |
| `komira_kg_spec` | 0.1.344 | `komira-ai/kg_spec` |  |
| `komira_libc` | 0.1.344 | `komira-ai/libc` |  |
| `komira_log` | 0.1.344 | `komira-ai/log` |  |
| `komira_log_index` | — | (`komira-ai/log_index`) |  |
| `komira_log_query` | — | (`komira-ai/log_query`) |  |
| `komira_lowering` | claim | (`komira-ai/lowering`) |  |
| `komira_lowering_rules` | — | (`komira-ai/lowering_rules`) |  |
| `komira_lz4` | 0.1.344 | `komira-ai/lz4` |  |
| `komira_mail_address` | 0.1.344 | `komira-ai/mail_address` |  |
| `komira_mail_auth` | — | (`komira-ai/mail_auth`) |  |
| `komira_mail_message` | 0.1.344 | `komira-ai/mail_message` |  |
| `komira_mail_store` | — | (`komira-ai/mail_store`) |  |
| `komira_mail_tls` | — | (`komira-ai/mail_tls`) |  |
| `komira_managed_mail_proto` | 0.1.344 | `komira-ai/managed_mail_proto` |  |
| `komira_mcp_server` | 0.1.344 | `komira-ai/mcp_server` |  |
| `komira_metrics` | 0.1.344 | `komira-ai/metrics` |  |
| `komira_metrics_reader` | — | (`komira-ai/metrics_reader`) |  |
| `komira_morsel` | claim | (`komira-ai/morsel`) |  |
| `komira_name_registry` | 0.1.344 | `komira-ai/name_registry` |  |
| `komira_net` | — | (`komira-ai/net`) |  |
| `komira_oauth` | — | (`komira-ai/oauth`) |  |
| `komira_objectstore` | claim | (`komira-ai/objectstore`) |  |
| `komira_objectstore_gcs` | — | (`komira-ai/objectstore_gcs`) |  |
| `komira_objectstore_s3` | — | (`komira-ai/objectstore_s3`) |  |
| `komira_oci` | — | (`komira-ai/oci`) |  |
| `komira_op_agg_distinct` | claim | (`komira-ai/op_agg_distinct`) |  |
| `komira_op_agg_hash` | claim | (`komira-ai/op_agg_hash`) |  |
| `komira_op_agg_row_api` | claim | (`komira-ai/op_agg_row_api`) |  |
| `komira_op_agg_slab` | claim | (`komira-ai/op_agg_slab`) |  |
| `komira_op_agg_stage` | — | (`komira-ai/op_agg_stage`) |  |
| `komira_op_agg_state` | claim | (`komira-ai/op_agg_state`) |  |
| `komira_op_asof` | claim | (`komira-ai/op_asof`) |  |
| `komira_op_fused_kernels` | — | (`komira-ai/op_fused_kernels`) |  |
| `komira_op_join_build` | claim | (`komira-ai/op_join_build`) |  |
| `komira_op_join_probe` | claim | (`komira-ai/op_join_probe`) |  |
| `komira_op_join_sinks` | — | (`komira-ai/op_join_sinks`) |  |
| `komira_op_join_stage` | claim | (`komira-ai/op_join_stage`) |  |
| `komira_op_sort` | claim | (`komira-ai/op_sort`) |  |
| `komira_op_sources` | claim | (`komira-ai/op_sources`) |  |
| `komira_op_spill_rows` | — | (`komira-ai/op_spill_rows`) |  |
| `komira_op_typed_source_api` | claim | (`komira-ai/op_typed_source_api`) |  |
| `komira_op_window` | claim | (`komira-ai/op_window`) |  |
| `komira_operator_api` | claim | (`komira-ai/operator_api`) |  |
| `komira_optimized_plan_header` | — | (`komira-ai/optimized_plan_header`) |  |
| `komira_optimizer` | — | (`komira-ai/optimizer`) |  |
| `komira_orc` | — | (`komira-ai/orc`) |  |
| `komira_parquet` | claim | (`komira-ai/parquet`) |  |
| `komira_parquet_api` | 0.1.344 | `komira-ai/parquet_api` |  |
| `komira_parquet_codec` | claim | (`komira-ai/parquet_codec`) |  |
| `komira_parquet_footers` | — | (`komira-ai/parquet_footers`) |  |
| `komira_parquet_scan` | claim | (`komira-ai/parquet_scan`) |  |
| `komira_parquet_writer` | — | (`komira-ai/parquet_writer`) |  |
| `komira_phase_timers` | — | (`komira-ai/phase_timers`) |  |
| `komira_physical_plan` | claim | (`komira-ai/physical_plan`) |  |
| `komira_pipeline_exec` | — | (`komira-ai/pipeline_exec`) |  |
| `komira_plan_expr` | claim | (`komira-ai/plan_expr`) |  |
| `komira_plan_ir` | claim | (`komira-ai/plan_ir`) |  |
| `komira_plan_proto` | 0.1.344 | `komira-ai/plan_proto` |  |
| `komira_plan_stats` | claim | (`komira-ai/plan_stats`) |  |
| `komira_plan_wire` | claim | (`komira-ai/plan_wire`) |  |
| `komira_pplan_wire` | — | (`komira-ai/pplan_wire`) |  |
| `komira_proto_codec` | 0.1.344 | `komira-ai/proto_codec` |  |
| `komira_protobuf` | 0.1.344 | `komira-ai/protobuf` |  |
| `komira_resource_gate` | — | (`komira-ai/resource_gate`) |  |
| `komira_resources` | 0.1.344 | `komira-ai/resources` |  |
| `komira_retry` | 0.1.344 | `komira-ai/retry` |  |
| `komira_row_format` | claim | (`komira-ai/row_format`) |  |
| `komira_rowcell` | 0.1.344 | `komira-ai/rowcell` |  |
| `komira_runtime_paths` | 0.1.344 | `komira-ai/runtime_paths` |  |
| `komira_scalar_arithmetic` | 0.1.344 | `komira-ai/scalar_arithmetic` |  |
| `komira_scan_planning` | claim | (`komira-ai/scan_planning`) |  |
| `komira_scan_resolver` | — | (`komira-ai/scan_resolver`) |  |
| `komira_scan_source` | claim | (`komira-ai/scan_source`) |  |
| `komira_sdk` | claim | (`komira-ai/sdk`) |  |
| `komira_sdk_exec` | claim | (`komira-ai/sdk_exec`) |  |
| `komira_search` | — | (`komira-ai/search`) |  |
| `komira_search_catalog` | — | (`komira-ai/search_catalog`) |  |
| `komira_search_compaction` | — | (`komira-ai/search_compaction`) |  |
| `komira_search_http` | — | (`komira-ai/search_http`) |  |
| `komira_search_scan` | — | (`komira-ai/search_scan`) |  |
| `komira_secret_env` | — | (`komira-ai/secret_env`) |  |
| `komira_secret_registry` | claim | (`komira-ai/secret_registry`) |  |
| `komira_secret_store` | claim | (`komira-ai/secret_store`) |  |
| `komira_secrets` | — | (`komira-ai/secrets`) |  |
| `komira_secrets_azure` | — | (`komira-ai/secrets_azure`) |  |
| `komira_secrets_conjur` | — | (`komira-ai/secrets_conjur`) |  |
| `komira_secrets_keychain` | — | (`komira-ai/secrets_keychain`) |  |
| `komira_shuffle` | claim | (`komira-ai/shuffle`) |  |
| `komira_shuffle_streaming` | — | (`komira-ai/shuffle_streaming`) |  |
| `komira_simd` | 0.1.344 | `komira-ai/simd_ops` | `std.builtin.simd` (12.2) |
| `komira_smtp_client` | — | (`komira-ai/smtp_client`) |  |
| `komira_smtp_server` | — | (`komira-ai/smtp_server`) |  |
| `komira_snapshotter` | 0.1.344 | `komira-ai/snapshotter` |  |
| `komira_so` | — | (`komira-ai/so`) |  |
| `komira_source_url` | — | (`komira-ai/source_url`) |  |
| `komira_spsc_ring` | 0.1.344 | `komira-ai/spsc_ring` |  |
| `komira_sql` | claim | (`komira-ai/sql`) |  |
| `komira_supervisor` | claim | (`komira-ai/supervisor`) |  |
| `komira_supervisor_proto` | 0.1.344 | `komira-ai/supervisor_proto` |  |
| `komira_sync` | 0.1.344 | `komira-ai/sync` |  |
| `komira_table_store` | — | (`komira-ai/table_store`) |  |
| `komira_telemetry_read` | — | (`komira-ai/telemetry_read`) |  |
| `komira_telemetry_store` | — | (`komira-ai/telemetry_store`) |  |
| `komira_test_run_id` | 0.1.344 | `komira-ai/test_run_id` |  |
| `komira_test_verdict` | 0.1.344 | `komira-ai/test_verdict` |  |
| `komira_textproto` | 0.1.344 | `komira-ai/textproto` |  |
| `komira_trace` | 0.1.344 | `komira-ai/trace` |  |
| `komira_udf` | claim | (`komira-ai/udf`) |  |
| `komira_uuid` | 0.1.344 | `komira-ai/uuid` |  |
| `komira_validation_run` | 0.1.344 | `komira-ai/validation_run` |  |
| `komira_vcard` | 0.1.344 | `komira-ai/vcard` |  |
| `komira_viewport` | — | (`komira-ai/viewport`) |  |
| `komira_webpush` | — | (`komira-ai/webpush`) |  |
| `komira_wkt` | 0.1.344 | `komira-ai/wkt` |  |
| `komira_xml` | 0.1.344 | `komira-ai/xml` |  |
| `komira_zlib` | 0.1.344 | `komira-ai/zlib` |  |

### 12.2 Clashes

Each new name was checked against everything below; the checks are reproducible from the mapping file.

- The Mojo standard library at any depth, not only its top-level modules: every directory and file name under
  `mojo/stdlib/std/` of Mojo 1.0.0 (section 1.1), 173 names once those starting with `_` are left out.
- mopm's keyword, builtin and reserved lists (`src/core/manifest.zig` `keywords` and `builtins`,
  `service/api/src/publish/claim.ts` `RESERVED_NAMES`), and the name grammar `^[a-z][a-z0-9_]{1,63}$`.
- The other 259 new names (no duplicate), and komira's top-level `src/` directory not in the mapping (`tests`).
- Every bare top-level import in komira's `.mojo` files that is not `std` or `komira_*`
  (`git grep -h -oE '^\s*(from|import)\s+[a-z_][a-z0-9_]*' main -- '*.mojo'`, 190 distinct names, many of them words
  of docstrings): the only one equal to a new name is `chunk`, a docstring line in `komira_json_index`, not an
  import.

Dropping the prefix fails these checks for five directories; a sixth is renamed by decision:

| old name | prefix dropped | clashes with | new name |
|---|---|---|---|
| `komira_async` | `async` | a Mojo keyword (`import async` does not parse) | `async_rt` |
| `komira_collections` | `collections` | `std.collections`, a top-level module | `containers` |
| `komira_hash` | `hash` | a Mojo builtin, and `std.hashlib.hash` | `hashing` |
| `komira_host` | `host` | `std.gpu.host` | `host_probe` |
| `komira_simd` | `simd` | `std.builtin.simd` | `simd_ops` |
| `komira_buffer` | `buffer` | nothing in Mojo 1.0.0's standard library; the standard library had `buffer` until at least modular/modular `modular/v25.6.0` (`mojo/stdlib/stdlib/buffer`) | `byte_buffer` |

`komira_buffer` is renamed because the CEO's amendment names it; `buffer` was a standard module in earlier Mojo
releases (row above). The new names describe the packages: `containers` (a slab, an inline value, a variadic pack,
a HyperLogLog sketch), `hashing` (FNV-1a), `host_probe` (CPU, memory and hugepage probes), `simd_ops` (SIMD byte and
bit primitives), `async_rt` (the async runtime), `byte_buffer` (aligned, shared and mapped byte buffers).

Python standard module names (`json`, `csv`, `uuid`, `datetime`, `calendar`, `compression`, `xml`, `zlib`, `trace`)
are kept: Mojo's `import json` and `Python.import_module("json")` never meet. `zlib` also names a conda library, a
separate table (section 3).

### 12.3 The change to komira's imports

The import name is the directory name, so the rename moves each `src/komira_<x>` directory to `src/<new name>` and
rewrites every import of it. Measured on komira `main` the same day (7436 `.mojo` files:
`git ls-tree -r --name-only main | grep -c '\.mojo$'`); `P` is `$(cut -f1 docs/design/namespaces-komira-map.tsv |
paste -sd'|')`, all 260 old names, and `P66` the same for the 66 published ones:

| query (measured) | lines | files |
|---|---|---|
| `git grep -E "^\s*(from\|import)\s+($P)\b" main -- '*.mojo'` | 30308 | 5707 |
| `git grep -E '^\s*(from\|import)\s+komira_' main -- '*.mojo'` (every `komira_` module) | 30830 | |
| `git grep -w -E "($P)" main` (every file: BUCK, `.bzl`, docs, manifests, sources) | 63361 | 7638 |
| the same, `-- '*BUCK' '*.bzl'` only | 17620 | |
| `git grep -E "^\s*(from\|import)\s+($P66)\b" main -- '*.mojo'` (the 66 published only, for comparison) | 5958 | |
| `git grep -w -E "($P66)" main` (the 66 published only, for comparison) | 25844 | 4389 |

The 522 import lines in the second row and not the first (30830 - 30308) import 60 other `komira_*` modules that are
not top-level directories: packages nested under `src/tests/` (conformance and end-to-end suites), generated fixtures
under `tools/`, and modules inside a package (`komira_gcp_firestore_v1` in `src/komira_gcp_firestore`). They are not in
the mapping and keep their names; the rename tool matches whole words (`_` is a word character, so
`komira_gcp_firestore` never matches inside `komira_gcp_firestore_v1`), and none of their names without the prefix is a
new name.

Proposed landing, in komira, not here: one mechanical pull request made by a rename tool (a Rust binary with its own
tests, per komira's rules) that reads `docs/design/namespaces-komira-map.tsv` from mopm and renames directories and
rewrites imports, BUCK targets and `mopm.toml` from it. It renames all 260 directories in one pull request: 63361 lines
in 7638 files (measured, third row), of which 30308 import lines (first row). Reviewers check it by running the tool
again. Each of the 66 published packages' `mopm.toml` gets `name = "komira-ai/<new name>"` and quoted dependency keys
in the same pull request, and the release workflow publishes through the `komira-ai` trusted publisher. It lands after
a mopm with task ns-C4 is released, because a mopm without namespaces cannot read the new manifests.

### 12.4 The deletion: a held tool

After namespaces ship and komira's release publishes under `komira-ai/` (so nothing publishes flat names any more), the
flat names are deleted by a held tool, `service/api/src/ops/delete-global-names` (TypeScript, next to the existing
group tool `ops/group-ops-bin.ts`):

- Dry run by default. `--stage beta|gamma|prod` is required. It never forces and never retries a refused step.
- The work list is read from the stage, not from a file: every package whose name has no namespace, with its versions,
  owners and trusted publishers, the channel objects under each subdir at the root (`<subdir>/mojo-<name>-*.conda`) and
  the version 1 index files. The dry run prints them per name, the totals, and a digest of the whole listing. Each stage
  has its own list.
- Kept: a name that starts with `kci_` is never on the work list. The tool skips it at listing time, before the digest,
  so no later step can reach it: its package, version, owner and publisher rows, its version 1 index file, its root
  repodata entries and its channel objects stay as they are. The dry run prints the kept names in their own section,
  with their count, and the digest covers that section too, so a `kci_*` package created or published after the dry run
  also stops `--apply`. The rule is the prefix, fixed in the tool, not a list; on prod today it keeps the 16 `kci_*`
  names of 12.1.
- `--apply <digest>` lists again and refuses unless the digest is the dry run's, so a version published or a package
  created after the dry run stops it. It also refuses unless `config.json` serves index version 2 and `/api/v1`
  refuses flat creation.
- Per name, in this order: append a `delete_global` audit record (the audit log is append-only and keeps the history);
  take it out of the version 1 index and the root repodata; delete its channel objects; delete its version, owner and
  publisher rows; delete its package row last. A run that stops part way leaves the package row as the work list, and a
  second run also lists by bucket prefix, so it finishes what the first left; a run with nothing left does nothing.
  Rewriting the root repodata keeps the `kci_*` entries.
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
  creating; the standard-library refusal of 1.1 at `PUT` (`name_reserved`), from the checked-in lists, with a test
  that the service's list equals the union of `toolchain/mojo-<version>.std-modules.txt`. Contract examples for every
  v2 operation in `tests/contract/`, among them a refused `collections`.
- ns-R4 (M) Index v2 and the per-namespace channel writer: index paths, records, per-namespace repodata, conda names,
  `config.json` keys, the root repodata with only the kept `kci_*` entries. Infra: the App's secret beside the OAuth
  secret.

Client:

- ns-C5 (S) The fake registry (`registry/fake`) serves v2 and namespaces. First, since ns-C2 to ns-C4 test against it.
- ns-C1 (M) Names: full-name grammar in the manifest, `nameProblem`, refusal messages, the library directory rule;
  path and workspace matching by full name; the standard-library rule of 1.1 (refused as `[package] name`, a warning
  as a dependency key) and `toolchain/mojo-1.0.0.std-modules.txt`, with a test that each version in
  `toolchain/versions.txt` has its file and that the client's list is their union. Manifest goldens in
  `tests/manifest/`: `collections` refused, `containers` accepted, a dependency named `os` warned; no registry needed.
  The writer of the std-modules files (the Zig tool and its step in the `toolchain` job of 1.1), whose Zig tests read
  a small `std.mojoc`-shaped fixture (header, zstd frame, paths) and refuse an archive whose sha256 differs from the
  lock's.
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
  stopped part way and finished by the next; `kci_*` names listed as kept and left untouched in every store (rows,
  version 1 index, root repodata, channel objects); a `kci_*` package published after the dry run changes the digest.
- ns-M2 (komira) The rename tool and the rename pull request (12.3), for all 260 `komira_*` directories, reading
  `docs/design/namespaces-komira-map.tsv`. The tool refuses a mapping that is not 260 sorted, unique lines of two
  fields, or whose new names fail the checks of 12.2.
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
9. The registry refuses keywords, builtins, today's reserved names and the standard library's top-level modules as
   import names: a published package must be importable, and `mojo`, `max`, `modular` and `std.*` stay unshadowed.
10. The library directory must be the import name: otherwise the import-name rule would not be the name Mojo uses.
11. Conda name `mojo-<namespace>.<name>`: a `depends` names one package across channels (question 1).
12. Index sharded by namespace: top directories stay small as accounts grow.
13. Lock 3 has version 2's shape for every project: one new shape, not two.
14. The import-name check covers dev-dependencies and the root: one lock and one test build hold them all.
15. Every format gets a new version instead of an optional field: old readers fail loudly, never misread a name.
16. The flat root keeps its repodata, with only the kept `kci_*` packages: a conda client that lists it gets "no
    package" for a deleted name, not a broken channel.
17. The proposed spec is a separate file, `spec/proposed/namespaces.md`: `spec/mopm-toml.md` and `spec/channel.md` are
    pages of the public site, which must not show a proposal as the contract.
18. The deletion tool lists its work from the stage and applies only the digest of its dry run: per-stage data, and no
    surprise between reading and deleting.
19. komira renames all 260 `komira_*` directories in one pull request, from one checked-in mapping: the CEO's
    amendment; one rename leaves no package half under the old scheme, and a directory published later already has its
    final name.
20. The `kci_*` packages are kept: not deleted, not renamed, skipped by the deletion tool by their `kci_` prefix, on the
    CEO's amendment. They stay flat names on `/api/v1`, the version 1 index and the
    root channel, and the 139 names of 12.1 are listed in full because they are public on the registry today.
21. The standard-library list is read from the pinned `mojo-compiler` package, checked in per Mojo version, and the
    rule refuses the union over `toolchain/versions.txt`: what mopm installs is what the rule protects, and tests stay
    offline.
22. Only top-level modules are refused by the registry and the client (the amendment's rule), but komira's new names
    avoid every standard-library name at any depth (`host`, `simd`): komira chooses its names once, and a stricter
    check costs nothing there.
23. A module added by a later Mojo version is refused for new packages and only warned about in dependency keys: a
    package published before that version keeps building for its users.
24. `komira_buffer` is renamed to `byte_buffer` although Mojo 1.0.0's standard library has no `buffer`: the amendment
    names it, and `buffer` was a standard module in earlier Mojo releases (12.2).
25. The mapping file holds import names, not full names, and no header: the rename tool rewrites directory names and
    imports, which are import names; the namespace is `komira-ai` for every line.

## Questions for the CEO

The five questions of the first version are answered by the CEO's amendment:

1. The conda name stays `mojo-<namespace>.<name>`, one channel per namespace (settled, section 5).
2. `komira_hash` becomes `komira-ai/hashing`; `async` becomes `komira-ai/async_rt` (12.2).
3. `komira-ai/collections` and `komira-ai/buffer` are renamed too, and no import name may be a top-level module of
   the standard library (1.1, 12.2).
4. All 260 `komira_*` directories are renamed, not only the 66 published (12.1, 12.3).
5. The 16 `kci_*` packages are not deleted: they are kept as they are, and the deletion tool skips them (12.4).

Open:

1. The new names this design chose where dropping the prefix is not allowed (12.2): `containers` for
   `komira_collections`, `host_probe` for `komira_host`, `simd_ops` for `komira_simd` and `byte_buffer` for
   `komira_buffer`. Confirmed, or other names?
