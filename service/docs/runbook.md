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

## Before the first real publish

The channel stack seeds an empty `repodata.json` and `repodata.json.zst` per subdir through a
`BucketDeployment` (`channel-stack.ts`, `EmptyRepodata`). Changing the seed content re-runs that deployment and
overwrites the live repodata on every stage, including prod, with empty files. The index writer must own
repodata before any change to the seed, and the seeding is removed (with the pinned-hash test in
`empty-channel.test.ts`) when the index writer lands, before the first real publish.
