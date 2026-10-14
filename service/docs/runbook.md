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

## Publishing: how it runs and how to operate it

`POST /packages/{name}/{version}/files` (begin) reserves the version number as `pending`, records the declared file
and answers with a presigned PUT into `quarantine/<upload id>/<file>` pinned to the exact length and sha256.
`POST .../publish` (commit) takes the version lock, queues the publish on `mopm-<stage>-validate.fifo` (group = package) and answers 202.
The validator Lambda reads the quarantined object, runs the validator, copies the file to `<subdir>/<file>`,
publishes the version, and queues `mopm-<stage>-index.fifo` (group = subdir); the index writer rebuilds the subdir's
repodata, invalidates its two CloudFront paths and marks the publish `published`.

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
