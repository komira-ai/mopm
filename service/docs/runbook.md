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
- A package with no visible version (only a rejected publish) has no file; nothing is written.
- A takedown is an operator action: tombstone the row, then call `queueTakedownIndex` (`src/publish/takedown.ts`), or send
  `index_pkg` for the package, `index` for each of its subdirs and `index_takedowns` by hand.
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
- **Dead-letter queues.** A message that fails three times lands in `mopm-<stage>-validate-dlq.fifo` or
  `mopm-<stage>-index-dlq.fifo`, and the alarm `mopm-<stage>-{validate,index}-dlq-depth` fires. The Lambda logs say why. The publish stays
  `validating` or `indexing`. After fixing the cause, redrive the message from the console or CLI (`start-message-move-task`); both
  handlers are idempotent. A defect in the validator's own code is never reported to the publisher as a rejection.
- **Quarantine** objects are deleted by the validator after the verdict; the bucket's lifecycle rule expires `quarantine/` after a day
  regardless. An upload that was never committed simply expires (its version stays a reservation that the next begin can use).
- **Limits** (defaults in `service/api/src/publish/config.ts`; the API Lambda reads `MOPM_RATE_PER_ACCOUNT_DAY` and
  `MOPM_RATE_PER_TOKEN_DAY`, set from the `limits` prop of the API stack): 100 MB per package, 10 GB per project (counts published and
  yanked files; a full project refuses new publishes and nothing is ever deleted), 2000 begins per account and 1000 per token per UTC day.
