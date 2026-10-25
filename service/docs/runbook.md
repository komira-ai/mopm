# Runbook

## First deploys: beta gates gamma

The DynamoDB table `ResourcePolicy` is set through a raw property override in
`service/infra/stacks/lib/data-stack.ts` (`addPropertyOverride('ResourcePolicy', ...)`). Synthesis and the
template tests cannot show that CloudFormation accepts it: the first real deploy is its first exercise.

- Beta deploys first. Read its outcome (stack status, and the table's resource policy afterwards) before
  anything else runs.
- That outcome gates gamma: do not deploy gamma, and do not let `promote.yml` continue, until beta's data
  stack has been created with the policy attached. If beta rejects the override, fix the override in a new
  commit and redeploy beta; gamma and prod wait.
- Prod follows gamma, as in `promote.yml`.

## The channel's repodata (the seed is gone)

The channel stack no longer seeds repodata: its `BucketDeployment` is removed (that change was the deliberate one the
old pinned-hash test guarded; the pin moved to `service/api/test/publish/empty-index.test.ts`). The index writer
(`service/api/src/publish/indexer.ts`) owns every `<subdir>/repodata.json(.zst)`.

- Stages deployed before the change keep the files the seed wrote: the seed's custom resource was `retainOnDelete`,
  so removing it deletes nothing. The first publish into a subdir replaces that subdir's file.
- A stage with no seed (a new or wiped beta/gamma) serves 403 for `repodata.json` until the first publish. The first index
  job creates the empty index of all four subdirs (create-only, never over an existing file), then writes the one it
  was asked to. To create them without publishing, send the index writer a rebuild message: SQS `SendMessage` to
  `mopm-<stage>-index.fifo` with body `{"type":"index","subdir":"noarch"}`, `MessageGroupId` `noarch`,
  any `MessageDeduplicationId`. (A deploy-time custom resource is deliberately not used: it would overwrite live files.)
- Rebuilding is always safe and idempotent: the writer derives the file from the registry's records. After a manual change to
  a version row, send the same message for each affected subdir.

## The sparse index writer

The index writer also owns `index/<aa>/<bb>/<name>` (one NDJSON file per package, `spec/index.md`) and
`index/takedowns.json`, in the channel bucket. Nothing serves them yet (the reader is a separate change), and
CloudFront refuses to serve `index/*` from the conda host.

- Three message kinds on `mopm-<stage>-index.fifo`: `{"type":"index","subdir":...}` (repodata, as before),
  `{"type":"index_pkg","name":...,"rev":N}` (group `pkg:<name>`, dedup id `<name>:<rev>`) and `{"type":"index_takedowns"}`
  (group `takedowns`). `rev` is the sum of the revisions of the package's rows: it only separates dedup ids. A job never trusts
  the message for content: it re-reads the package's rows and writes the whole file, so a late or repeated job writes the
  newest state and cannot bring an older one back.
- Order. Publish and unyank: the last repodata job queues `index_pkg`, so the index never runs ahead of repodata (the CLI
  refuses an index that says `published` while repodata still lists the file as removed). Yank and takedown queue it at once.
  The window that remains is repodata invalidation, which is requested and not awaited.
  A yank or takedown job re-reads all of the package's rows, so it can also list another version whose publish is still
  in flight: the validator marks the row `published` before the last repodata job lists the file. For that short window
  the CLI fails closed on that package (index ahead of repodata) until repodata catches up. Publish and unyank are gated;
  this cross-version case is not, and is accepted.
- A package with no visible version (only a rejected publish) has no file; nothing is written.
- A takedown is an operator action and nothing in the service calls it yet: no route does. After tombstoning the row,
  call `queueTakedownIndex` (`src/publish/takedown.ts`), or send `index_pkg` for the package, `index` for each of its
  subdirs and `index_takedowns` by hand. Until a route exists a takedown needs this manual send.
- **Rollback.** Reverting the writer does not finish a publish that was in flight. Such a record has `status` `indexing`,
  `remaining_subdirs` empty and `index_pending` true; the previous validator only re-sends repodata jobs for
  `remaining_subdirs`, so it sends nothing, and the previous indexer drops `index_pkg` as unrecognised. The version row is
  `published` and repodata lists it, so only the publish record is stale (a client polling it sees `indexing`). Find them
  (`aws dynamodb scan --table-name mopm-<stage>-publishes --filter-expression 'index_pending = :t AND #s = :i'
  --expression-attribute-names '{"#s":"status"}' --expression-attribute-values '{":t":{"BOOL":true},":i":{"S":"indexing"}}'`)
  and, after confirming repodata lists the version, mark each published (a cloud write: needs the maintainers' go):
  `aws dynamodb update-item --table-name mopm-<stage>-publishes --key '{"publish_id":{"S":"<id>"}}'
  --condition-expression '#s = :i AND index_pending = :t' --update-expression 'SET #s = :p, index_pending = :f, rev = rev + :one'
  --expression-attribute-names '{"#s":"status"}' --expression-attribute-values '{":i":{"S":"indexing"},":p":{"S":"published"},":t":{"BOOL":true},":f":{"BOOL":false},":one":{"N":"1"}}'`.
  Or avoid it: do not revert while a publish is in flight (the DLQ and publish records show none).
- **Rebuild everything**: send one `index_pkg` per package (any `rev`, with a dedup id that has not been used in five minutes) and
  one `index_takedowns`. Every write is idempotent.
- Old versions of `index/` files expire 30 days after they are replaced (bucket lifecycle rule `index-noncurrent-expiry`).

### Held step: seed `index/takedowns.json` on each stage

Nothing writes `index/takedowns.json` on a stage that has no takedown, so it does not exist until one message asks for it.
Send it once per stage, after the writer is deployed to that stage. It is a cloud write: it needs the maintainers' go for
each stage, and it is not part of any workflow. Dry run is the default; nothing is sent unless `APPLY=1`.

```sh
#!/usr/bin/env bash
# Seed index/takedowns.json for one stage. Dry run unless APPLY=1.
set -euo pipefail
stage="${1:?usage: seed-takedowns.sh beta|gamma|prod}"
case "$stage" in beta | gamma | prod) ;; *) echo "unknown stage: $stage" >&2; exit 2 ;; esac
region="${AWS_REGION:-us-east-1}"
account="$(aws sts get-caller-identity --query Account --output text)"
queue_url="$(aws sqs get-queue-url --region "$region" --queue-name "mopm-${stage}-index.fifo" --query QueueUrl --output text)"
bucket="mopm-${stage}-channel-${account}"
dedup="seed-takedowns-${stage}-$(date -u +%Y%m%dT%H%M%SZ)"
echo "stage:  $stage"
echo "queue:  $queue_url"
echo "object: s3://${bucket}/index/takedowns.json"
echo "send:   {\"type\":\"index_takedowns\"}  group=takedowns  dedup=$dedup"
if [ "${APPLY:-0}" != "1" ]; then echo "dry run: nothing sent (APPLY=1 to send)"; exit 0; fi
aws sqs send-message --region "$region" --queue-url "$queue_url" \
  --message-group-id takedowns --message-deduplication-id "$dedup" \
  --message-body '{"type":"index_takedowns"}'
echo "sent. In a minute: aws s3 cp s3://${bucket}/index/takedowns.json -"
```

Check the result: `aws s3 cp s3://mopm-<stage>-channel-<account>/index/takedowns.json -` prints exactly
`{"index_version":1,"takedowns":[]}` and a newline. If it is missing after a few minutes, look at the index
dead-letter queue and the indexer's logs (`index_takedowns` is logged on success). Sending it again is harmless.

## Publishing: how it runs and how to operate it

`POST /packages/{name}/{version}/files` (begin) reserves the version number as `pending`, records the declared file
and answers with a presigned PUT into `quarantine/<upload id>/<file>` pinned to the exact length and sha256.
`POST .../publish` (commit) takes the version lock, queues the publish on `mopm-<stage>-validate.fifo` (group = package) and answers 202.
The validator Lambda reads the quarantined object, runs the validator, copies the file to `<subdir>/<file>`,
publishes the version, and queues `mopm-<stage>-index.fifo` (group = subdir); the index writer rebuilds the subdir's
repodata and invalidates its two CloudFront paths. The job that lists the last subdir marks the publish `index_pending` and
queues one `index_pkg` message (group `pkg:<name>`); that job writes the package's sparse-index file and only then marks the
publish `published`. See "The sparse index writer" below.

- **Read-only switch.** Put the item `{"key": "read_only", "value": true}` into the stage's `mopm-<stage>-config` table
  (`aws dynamodb put-item --table-name mopm-<stage>-config --item '{"key":{"S":"read_only"},"value":{"BOOL":true}}'`).
  Within about five seconds begin and commit answer 503 `read_only_mode` and `/api/v1/health` reports `read_only: true`; reads,
  installs, publish status and publishes already accepted continue. Set `value` to `false` (or delete the item with
  the cleanup/takedown role) to lift it. If the table cannot be read, begin and commit answer 503 `unavailable` (they fail closed).
- **Groups switch.** `POST /groups`, `GET /groups/{id}` and `DELETE /groups/{id}` are deployed with the API, and a create is
  answered 404 `route_not_found` unless the item `groups_enabled` of the stage's config table admits the caller. The item is
  `{"key": "groups_enabled", "mode": "allow", "actors": ["u:<github id>"]}` for a list of accounts, or `{"key": "groups_enabled", "mode":
  "all", "deny": ["u:<github id>"]}` for everybody but the actors in `deny` (a `deny` list also applies to `allow`). No item, any other
  mode, or a value that is not a list admits nobody. It gates creation only: a group that exists is still read and aborted with it off, and
  `read_only` refuses a create but not a read or an abort. Takes effect within about five seconds. A group is created, read, aborted,
  committed to validation (`POST /groups/{id}/commit`, which `read_only` also refuses), validated, committed and then released into the
  channel's files and made `visible` (the chain, below).
- **The chain after a commit.** A commit makes the group's members show in the API at once. The channel's files follow, one step at a
  time, and each step is a message: a repodata hop for each subdir the group has files in (index queue, FIFO group = the subdir), then
  an index hop for each member in the header's `write_order` (dependencies first; a dependency cycle is ordered by name; FIFO group
  `pkg:<name>`), then the flip (group queue): every member row becomes `published` at the commit time (a yanked or taken-down member is
  left as it is) and the header becomes `visible`, which also takes it out of the sweeper's index. A hop first sets its gate on the
  header (`repodata_released`, `index_released`) and then builds, so any other build between two hops (a yank, a rebuild, another
  publish) lists the members released so far and no others; no index file is written before every repodata gate is set. The header, not
  the message, says which step is next, so a message delivered twice or late does no harm. Installs see a group's packages arrive one at a
  time, over as many hops as it has subdirs and members: this is not atomic, and the CDN's cache adds up to a minute. The dedup id of a
  step is `grp:<group id>:<attempt>:<step>:<resend>`.
- **Yank and unyank of a group.** `PUT /api/v1/groups/{id}/yank` with the body of a single version's yank (`{"yanked": true, "reason": "..."}`
  or `{"yanked": false}`); read-only mode refuses it, the groups switch does not gate it, and the token needs `yank` or `publish` for every
  member. Only a `visible` group can be yanked or unyanked (`group_not_settled`, 409, otherwise, and for a yank while an unyank runs and
  the other way round). The request writes the intent on the header (`yank`: state `yanking`, the reason, a sequence number, `yanked_set`)
  by a compare-and-set and queues `yank_group` on the group queue; the group stays `visible`. The job yanks each member that is
  `published` (a member somebody yanked by hand, or took down, is left as it is), marks each row it changes with the yank's sequence number
  and records those members in `yanked_set`, sixteen at a time. Then the files follow, as for a single yank: a repodata hop for each
  subdir the yanked members have files in, an index hop for each of them in `write_order`, and the end (`yanked`). The unyank restores
  only the members of `yanked_set` whose row still carries the marker (a member yanked by hand is not restored), then repodata hops, index
  hops, and the end (`restored`). As for a single version, the rows come first: a build nobody asked for between the rows and the hops of
  an unyank can write a restored member into the sparse index before repodata lists it, which installs refuse until the hops finish. While
  a yank or unyank runs the group is in the sweeper's index again, so the group tool's status lists it (`yank` says where it is) and says
  it is not safe to revert. Dedup ids: `grp:<group id>:<attempt>:y<seq>:<step>:<resend>` for a yank and `...:u<seq>:...` for an unyank.
- **How a group is validated.** The commit moves the group to `validating` and queues `mopm-<stage>-group.fifo` (one FIFO group per
  group id; at most two validations run at once, and the single validator keeps its own five). The group validator Lambda checks every
  member's archives and stages its row (phase 1; a bad member, an upload older than 18 hours, a deadline that passed or too many bytes
  ends the group `rejected` and frees its numbers), copies the files into the channel with create-only writes (phase 2; any failure
  from here ends it `failed` and burns its numbers: bytes under those names may be public, and they stay), then checks every row again,
  checks the project totals again and commits (phase 3). It saves its progress in the header every eight members and stops starting
  members after about four minutes (`MOPM_GROUP_BUDGET_MS`), queueing the rest as a message of its own, so a large group takes several
  invocations. Abort and expiry end only a group that is `open`; a validating group finishes or fails. `GET /groups/{id}` shows `failure`
  (`code`, `message`, the `member`) for a group that was rejected or failed.
- **The sweeper.** The Lambda `mopm-<stage>-...GroupSweeper` runs every five minutes (rule `mopm-<stage>-group-sweeper`), reads the index
  `by_sweep` (the headers of groups that are not over: a group leaves it when it is `visible`, and a yank puts it back until it ends) and sends the validate message again for a
  group that is `validating` and has shown no sign of life for 35 minutes (a message in flight is invisible for 30), and the step of the
  chain that is next for a group that is `committed`, or the step of the yank or unyank that is next for a visible group that has one running, and has shown none for 10 minutes (a hop is seconds), with a new dedup id each time,
  at most three times. It never ends or burns a group. After the third resend it only counts the group in `group_sweeper_gave_up`,
  which raises `mopm-<stage>-group-stalled`.
- **The group tool** (`service/api/src/ops/group-ops.ts`, built to `dist/ops/group-ops-bin.js`; run with the stage's credentials,
  `node group-ops-bin.js --stage=<stage> --mode=status`; flags only). `--mode=status` is read-only: the groups that are not over, with
  their phase, their last sign of life and, for a committed one, the members not yet flipped; the depth of the six queues; and a final
  `verdict` line. It exits 0 only when no group is in that list and the queues are empty. **Run it before any revert of this service is
  merged**: an older receiver acknowledges the messages of a newer one and loses them, and a revert deploys to PROD at once.
  `--mode=fail --group=<id>` ends a group that is validating and stuck. Without `--apply` it prints the plan and changes nothing. With
  it, the header is changed first (a compare-and-set that holds only while the group is validating): `rejected` if no copy began (its
  numbers are free), `failed` if one did, and then the numbers are burned. A commit that starts after that loses.
- **Groups that ended.** A group that ended without committing (`aborted`, `expired`, `superseded`, `rejected`, `failed`) has its header
  and member list removed by the table's TTL: the header expires seven days after the later of its end and its deadline, the member list
  two days after that. Its reserved rows stay in the versions table (rows are never deleted) and become free to take, by a group or a
  single publish, at the same moment (`free_after` on the row), so a number never stays stuck behind a header that is gone. A row of a
  group that is alive, or of one that committed (whose header never expires), is never free that way. The commit request's per-member
  items (`grpc#...`) expire seven days after the group's deadline.
- **Group alarms.** `mopm-<stage>-group-invariant` (a committed group had a member a reader could not account for),
  `mopm-<stage>-group-pending-rows` (a package holds 100 or more pending rows, which dead groups leave behind),
  `mopm-<stage>-group-oldest-active` (a validating or committed group has shown no sign of life for 30 minutes) and `mopm-<stage>-group-stalled` (the
  sweeper has resent a group's message three times and it still does not move). The group queue has its own dead-letter queue and alarm,
  `mopm-<stage>-group-dlq-depth`: a message that fails three times lands in `mopm-<stage>-group-dlq.fifo`; the logs of the group validator
  say why (a defect, or a member row that is not as it was staged, which is never committed). Redrive it after the fix, or end the group
  with the tool.
- **Dead-letter queues.** A message that fails three times lands in `mopm-<stage>-validate-dlq.fifo` or
  `mopm-<stage>-index-dlq.fifo`, and the alarm `mopm-<stage>-{validate,index}-dlq-depth` fires. The Lambda logs say why. The publish stays
  `validating` or `indexing`. After fixing the cause, redrive the message from the console or CLI (`start-message-move-task`); both
  handlers are idempotent. A defect in the validator's own code is never reported to the publisher as a rejection.
- **Quarantine** objects are deleted by the validator after the verdict; the bucket's lifecycle rule expires `quarantine/` after a day
  regardless. An upload that was never committed simply expires (its version stays a reservation that the next begin can use).
- **Limits** (defaults in `service/api/src/publish/config.ts`; the API Lambda reads `MOPM_RATE_PER_ACCOUNT_DAY` and
  `MOPM_RATE_PER_TOKEN_DAY`, set from the `limits` prop of the API stack): 100 MB per package, 10 GB per project (counts published and
  yanked files; a full project refuses new publishes and nothing is ever deleted), 2000 begins per account and 1000 per token per UTC day.

## Beta trusts a CI identity: config as code

Unlike the feature flags below, which a person flips in the config table, the CI identity that beta trusts to publish is **code**:
`BETA_CI_PUBLISHERS` in `service/infra/stacks/lib/api-stack.ts`, delivered as the `CI_PUBLISHERS` environment variable of the beta API
function and nowhere else. Design and reasons: `service/docs/adr-ci-publisher-identity.md`.

- **Changing who beta trusts** is a pull request to that constant; promote deploys it to beta. There is no console step. To stop
  trusting the identity, remove the entry in a pull request: a deployed value cannot be switched off at runtime (there is no
  config-table item for it), so the fastest stop is the deploy.
- **Gamma and prod get none of it.** Their function has no `CI_PUBLISHERS` (the `PutItem` on `packages` is the claim route's, on every stage, and there is no CI-only grant), and answers the `packages`
  form of the exchange with `oidc_not_trusted`. The handler also refuses to start on any stage but beta if the variable is present, so
  a function that fails to start with "may be set on the beta stage only" means the variable reached the wrong stage: remove it in
  the stack and redeploy. Trusting a CI identity at gamma or prod stays a deliberate human decision.
- **What a CI-created package looks like.** `claimed`, `ci_owner` = `gh-repo:<repository_id>`, no owner rows (so `owners` is empty in
  the read API), and an audit entry `ci_claim`. Only a token minted for that identity may publish to it. Fixing a wrong name means a
  takedown by an operator; the service has no route that renames or transfers it.
- **Reading a refusal.** `oidc_not_trusted`: the job's repository id, owner id, workflow file, ref, environment or event is not the
  configured one (`pull_request` never is). `not_owner` at the exchange: a name in the request belongs to an account or to another
  identity. `oidc_token_invalid` "token already used": a CI token is exchanged once.
- **One namespace with claims.** A CI exchange and `POST /packages/{name}/claim` create packages by the same conditional write, so a name
  goes to whoever creates it first: a user claim of a CI-created name is `name_taken`, and the exchange for a user-claimed name is
  `not_owner`. The claim rate limit counts user claims only; the exchange is not charged to it.

## Claiming a package name

`POST /packages/{name}/claim` (a user token: a login or an API token; a CI identity token is refused) is the only way a package comes to exist. It writes the package
(`state: claimed`, with `claim_expires_at` 30 days out), its first owner (the account) and an `audit` entry in one DynamoDB transaction, each
row created only if its key is absent, so of two claims of one name exactly one wins and the loser leaves nothing behind. The API role has
`PutItem` on `packages` and `owners` for this and nothing more there: it cannot change or delete an owner or a package.

- Read-only mode refuses a claim (`read_only_mode`), as it refuses an upload. The route is on every stage; there is no switch for it.
- A claim is rate limited per actor: 50 written claims per account and 50 per token per UTC day (`MOPM_CLAIM_RATE_PER_ACCOUNT_DAY`,
  `MOPM_CLAIM_RATE_PER_TOKEN_DAY`, set from the `claimRatePerAccountPerDay` and `claimRatePerTokenPerDay` of the API stack's `limits`).
  Over either, the claim is `429 rate_limited` with `Retry-After` to midnight UTC and writes nothing. Only a claim about to be written is
  charged, and one whose write fails gives its charge back. The counters are `rl#ct#<token>#<day>` and `rl#cu#<github id>#<day>` in the
  `publishes` table (the one the publish limits use), so the role needs no new grant. Any live user token may claim (the spec's `userToken`;
  token scopes are only `publish` and `yank`), so the per-token counter is what bounds a leaked token.
- `name_reserved` is a fixed list in the code (`RESERVED_NAMES`), `name_too_similar` compares the name, with underscores dropped and
  allowing one trailing `s`, with the names that start with the same letter (read from the search index, which is eventually
  consistent: two similar names claimed within a moment of each other can both succeed). `confirm_similar` skips only that check.
- `claim_expires_at` is stored and reported. Nothing yet frees a name whose claim lapsed with no published version; an operator
  who must free one deletes its rows by hand (the API role cannot).
- To see a claim: `audit` rows with `action: claim`, actor `u:<github id>`.

### Beta lets that identity create groups: a static policy

On beta the same identity may also create groups without anyone flipping `groups_enabled`. This is **code** as well:
`BETA_GROUPS_POLICY` in `service/infra/stacks/lib/api-stack.ts`, delivered as the `MOPM_GROUPS_POLICY` environment variable of the beta
API function and nowhere else: `{"mode":"allow","actors":["ci:gh-repo:<repository_id>"]}`, the actors derived from `BETA_CI_PUBLISHERS`. Design and
reasons: the addendum in `service/docs/adr-ci-publisher-identity.md`.

- **A static policy is ORed with the `groups_enabled` item, and a `deny` in the item does not override it.** The two are read
  separately and either one admitting the actor is enough. So on beta, setting `groups_enabled` to `off`, or putting the identity in
  `deny`, does **not** stop the identity from creating groups. Stopping it takes a deploy: remove the policy (or the publisher) in a
  pull request. Groups that exist are unaffected either way (the policy gates creation only).
- **Beta only, twice.** The stack sets the variable when the stage is `beta` and never otherwise, and the handler refuses to start on any
  other stage if it is present ("may be set on the beta stage only"); only the form above loads (never `all`, never an account, one to eight
  `ci:gh-repo:<id>` actors). Gamma and prod keep the human flip of `groups_enabled`.
- **What the identity can do with it.** Create a group whose every member is a package that the identity owns and that its token was
  minted for, at that version. A member outside the token, a package an account or another identity owns, or a caller that is not on
  the list is refused and nothing is created. Everything afterwards (commit, the validator and the chain, abort, `yank --group`) works for
  that identity's own groups and for no other caller. The actor in audit rows, group headers and uploads is `ci:gh-repo:<repository_id>`
  (the identity, not a token), and the group budget per day is counted per identity.

## Groups: enabling, rolling out and recovering

The mechanics of a group are under "Publishing" above; this section is the order of work for an operator. Users' side is
`docs/publishing-a-workspace.md`. Group publish is deployed dark: until `groups_enabled` says otherwise a create answers 404
`route_not_found` and the CLI reports that the registry has no group publish.

### The `groups_enabled` item

One item of the stage's `mopm-<stage>-config` table, read with a consistent read and cached for five seconds in each API container
(`service/api/src/publish/flags.ts`). It gates the creation of a group only: a group that exists is still read, committed, validated,
chained, aborted and yanked with it off. A `put-item` replaces the whole item, so give the complete value each time.

| `mode` | who may create a group | extra fields |
|---|---|---|
| `off` | nobody; also what an absent item, an unknown mode and a field that is not a list mean | none |
| `allow` | the actors in `actors` | `actors`, and `deny` |
| `all` | everybody | `deny` |

An actor in `deny` is refused in every mode: it is the kill switch for one account. An actor is written `u:<github id>`.

```text
# off (the default; deleting the item is the same)
aws dynamodb put-item --table-name mopm-<stage>-config --item '{"key":{"S":"groups_enabled"},"mode":{"S":"off"}}'
# a canary: only these actors
aws dynamodb put-item --table-name mopm-<stage>-config --item '{"key":{"S":"groups_enabled"},"mode":{"S":"allow"},"actors":{"L":[{"S":"u:<github id>"}]}}'
# everybody, except the actors in deny
aws dynamodb put-item --table-name mopm-<stage>-config --item '{"key":{"S":"groups_enabled"},"mode":{"S":"all"},"deny":{"L":[{"S":"u:<github id>"}]}}'
```

Each flip is one stage and one deliberate action by the person who owns that stage; none is part of a deploy. Switching to `off`
stops new groups within about five seconds and lets the ones in flight finish.

### The order: beta, gamma, then a canary on prod

1. **beta.** Set `allow` with the actor of the end-to-end job only. The `group-e2e` job of `e2e.yml` (it runs after the deploy of beta
   and of gamma, never on prod) skips with one line in its summary while the switch is off for its actor, so it is green before the
   switch and proves something after it. Go on only when it has passed on beta: a three-package chain, a group with a rejected
   member, and the yank and unyank of a group.
2. **gamma.** The same `allow`, and the same job. Measure how long one hop takes here (a large group has as many hops
   as it has subdirs plus members) before telling users a figure.
3. **prod, canary.** `allow` with one actor who has been told. Publish one real group and watch it with the group tool (below) until it is
   `visible`; run `--mode=status` and read the queues.
4. **prod, everybody.** `all`, with `deny` empty. Only after the canary group has been published, read and yanked and unyanked.

To go back at any stage, set `off`. To stop one account without stopping the rest, put it in `deny`.

### The group tool

`service/api/src/ops/group-ops.ts`, built by `npm run build` in `service/api` to `dist/ops/group-ops-bin.js`. Run it with the stage's
credentials; every setting is a flag.

```text
node dist/ops/group-ops-bin.js --stage=<beta|gamma|prod> [--region=<region>] --mode=status
node dist/ops/group-ops-bin.js --stage=<beta|gamma|prod> [--region=<region>] --mode=fail --group=<group id> [--apply]
```

- `--mode=status` is read-only (it takes neither `--group` nor `--apply`). It prints one JSON line for each group that is not over (kind
  `group`: status, phase, attempt, members, `unflipped`, `yank` and the seconds since its last sign of life), one for each of the six
  queues (kind `queue`: `visible` and `in_flight`), and a last line of kind `verdict` with `safe_to_revert`. Exit status 0 when there is no
  such group and the queues are empty, 3 when not.
- `--mode=fail` ends a group that is `validating` and has not committed, by id. **It is a dry run unless `--apply` is given**: it prints
  a `plan` line (`dry_run: true`, the status the group would take, and whether that burns its numbers) and changes nothing. With
  `--apply` it first changes the header with a compare-and-set that holds only while the group is validating, so a commit that starts
  meanwhile loses: `rejected` if no copy began (its numbers are free again), `failed` if one did (its numbers are burned). Exit status
  0 done, 2 refused (no such group, or it is not validating or has committed), 4 lost a race (the group changed first: read its status
  and run it again if it is still stuck). It never touches a group that has committed; a committed group is rolled forward by the sweeper.

### Redriving the group queue

A group message that fails three times lands in `mopm-<stage>-group-dlq.fifo` and the alarm `mopm-<stage>-group-dlq-depth` fires. The
index queue has the same arrangement for the hops (`mopm-<stage>-index-dlq.fifo`).

1. Read the logs of the group validator Lambda for the group id. Fix the cause first (a defect, or a member row that is not as it was
   staged, which is never committed). Redriving a message into the defect that sank it only fills the queue again.
2. Redrive. The handlers are idempotent and a step is decided by the group's header, not by the message:
   `aws sqs start-message-move-task --source-arn <arn of mopm-<stage>-group-dlq.fifo>` (the ARN is
   `aws sqs get-queue-attributes --queue-url <url> --attribute-names QueueArn`; the move goes back to the queue the messages came from).
3. If the group will not move, or the fix is not coming, do not redrive: end it with the group tool if it is still `validating`.
4. Run `--mode=status`: the group queue and its dead-letter queue must be empty before you call it done.

### Public bytes after a failed group

A group ends `failed` when something goes wrong after the validator began to copy files (phase 2). By then some of its files may already
be in the channel under `<subdir>/<file>`, written create-only with a one-year immutable cache header, and the CDN may have served them.
What that means:

- Nothing lists them. A group that did not commit never reached the chain, so neither the repodata nor the sparse index names the files and
  no resolver will pick them. A reader who knows the URL can still fetch them.
- The version numbers of its members are burned (a tombstone for each, as for a rejected single publish), because the files under those
  names cannot be told apart from a release. The next publish needs new version numbers. Nothing deletes the files.
- A group that was `rejected` (a phase 1 failure, or the group tool before any copy) copied nothing, and its numbers are free again.
- If the bytes must not stay public (a secret in a package), that is a takedown, not a retry. It is the stage owner's to carry out with the takedown role (the group tool does not do it), and
  the owner of the package is told.

### The rollback precheck

A revert under `service/**` deploys to prod at once, and an older receiver acknowledges the messages of a newer one and loses them. Before
any revert is merged:

1. Set `groups_enabled` to `off` on the stage and wait a few seconds. (On beta this does not stop the CI identity of the static
   policy above; stop it by deploying without `MOPM_GROUPS_POLICY`, or check that its job is not running.)
2. Run `--mode=status` until the verdict says `safe_to_revert: true`: no group is `open`, `validating`, or committed and not yet
   `visible` (a visible group whose yank or unyank is running is listed too), and every queue and dead-letter queue is empty.
3. Only then merge the revert.

A group that is stuck at step 2 is rolled forward (the sweeper, or a redrive) or ended with the group tool; it is not reverted around.

## Cutting over to the Rust port

Every route is TypeScript today (`/api/v1/health` reports `impl: ts` and `e2e.yml` asserts it). Before any route of a stage
is served by the Rust functions (`service/lambda`, the stage config's `rustRoutes`), check all of these on that stage:

1. **No group publish is in flight.** The Rust port keeps and hides a group's members (a version row with a `group_id` that is
   still `pending`) but does not publish a group or flip its members, and it reads no group header. A group that is open,
   validating, or committed and not yet visible would be stuck behind it. Read-only check, no row may come back:
   `aws dynamodb scan --table-name mopm-<stage>-versions --filter-expression 'attribute_exists(group_id) AND #s = :p'
   --expression-attribute-names '{"#s":"state"}' --expression-attribute-values '{":p":{"S":"pending"}}' --select COUNT`.
   A row left by a group that was aborted or expired also shows up here: look at it before going on.
   Until the group publish is in use, no row carries a `group_id` and the count is 0.
2. **No group can start during the cutover.** Group creation stays switched off (or limited to actors who are told) until the
   cutover is done or rolled back.
3. **Group-aware Rust comes first once groups are in use on the stage.** Showing a committed group's members, the order in
   which its files are released and the flip are implemented in TypeScript only. A stage that publishes groups does not move
   to Rust until the Rust port does the same.
4. **`EXPECTED_IMPL` in `.github/workflows/e2e.yml`** is changed in the same change as the route list, so the smoke test still says
   which implementation answered.
