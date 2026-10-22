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
  committed to validation (`POST /groups/{id}/commit`, which `read_only` also refuses) and validated; what follows a commit (repodata,
  the sparse index, the flip to `visible`) is not built yet, so a group that has committed stays `committed`.
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
  `by_sweep` (the headers of groups that are not over) and sends the validate message again for a group that is `validating` and has
  shown no sign of life for 35 minutes (a message in flight is invisible for 30), with a new dedup id each time, at most three times. It
  never ends or burns a group. After the third resend it only counts the group in `group_sweeper_gave_up`, which raises
  `mopm-<stage>-group-stalled`.
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
  `mopm-<stage>-group-oldest-active` (a validating group has shown no sign of life for 30 minutes) and `mopm-<stage>-group-stalled` (the
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
