import * as fs from 'fs';
import { Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as events from 'aws-cdk-lib/aws-events';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import { Construct } from 'constructs';
import { DEFAULT_HANDLER_DIR } from './api-stack';
import { ChannelStack } from './channel-stack';
import { CHANNEL_SUBDIRS, StageConfig, channelBucketName, groupDlqName, groupQueueName, indexDlqName, indexQueueName, tableName, validateDlqName, validateQueueName } from './config';
import { assertRegion, removalPolicyFor } from './common';

export interface PublishStackProps extends StackProps {
  config: StageConfig;
  channel: ChannelStack;
  /** Directory holding the built handlers (`publish/validator-lambda.js`, `publish/indexer-lambda.js`). */
  handlerDir?: string;
}

/**
 * Concurrent validator invocations at most, set as the validate queue trigger's maximum concurrency (the event source
 * mapping's ScalingConfig; its minimum is 2); the rest of a burst waits in the queue. It is NOT a reservation on the
 * function (`reservedConcurrentExecutions`): Lambda refuses a reservation that leaves the account's unreserved pool
 * under 10, and a new account's whole limit is 10, so the deploy rolls back (publish.test.ts pins both).
 */
export const VALIDATOR_MAX_CONCURRENCY = 5;
/**
 * Concurrent group validations at most, on a queue of their own: a group's job copies up to a few GB and takes minutes, and it
 * must never take a single publish's slot (the single validator keeps VALIDATOR_MAX_CONCURRENCY for itself). The mapping's
 * minimum is 2.
 */
export const GROUP_VALIDATOR_MAX_CONCURRENCY = 2;
/** Minutes between runs of the group sweeper. */
export const SWEEPER_PERIOD_MINUTES = 5;

/** Seconds a Lambda may run. The queue's visibility timeout is six times that, as AWS advises for an SQS trigger. */
export const VALIDATOR_TIMEOUT_SECONDS = 300;
export const INDEXER_TIMEOUT_SECONDS = 120;
export const MAX_RECEIVES = 3;

/**
 * The publish pipeline behind the API: two FIFO queues, each with a dead-letter queue and an alarm on it, and the
 * two Lambdas they trigger.
 *
 *  - validate queue (group = package): the validator reads the quarantined upload, runs validatePackage, copies the
 *    files into the channel, publishes the version, then sends one message per affected subdir to
 *  - index queue (group = subdir, `pkg:<name>` or `takedowns`): the index writer rebuilds a subdir's repodata from the
 *    registry's records, writes it and invalidates its two CloudFront paths; the last subdir job of a publish queues
 *    the package's job, which writes the package's sparse-index file and marks the publish published.
 *
 * Two roles, because they need different things: the validator reads and deletes quarantine, writes package files
 * and moves a version to published; the index writer writes only the repodata files, the files under index/, the
 * messages of its own queue and the invalidation.
 */
export class PublishStack extends Stack {
  readonly validateQueue: sqs.Queue;
  readonly validateDlq: sqs.Queue;
  readonly indexQueue: sqs.Queue;
  readonly indexDlq: sqs.Queue;
  readonly groupQueue: sqs.Queue;
  readonly groupDlq: sqs.Queue;
  readonly validator: lambda.Function;
  readonly indexer: lambda.Function;
  readonly groupValidator: lambda.Function;
  readonly sweeper: lambda.Function;

  constructor(scope: Construct, id: string, props: PublishStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;
    const handlerDir = props.handlerDir ?? DEFAULT_HANDLER_DIR;
    if (!fs.existsSync(handlerDir)) {
      throw new Error(`the handler bundle is missing at ${handlerDir}; run 'npm ci && npm run build' in service/api first`);
    }
    const bucketName = channelBucketName(c.stage, this.account);
    const bucketArn = `arn:aws:s3:::${bucketName}`;
    const table = (t: string) => this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, t) });

    const fifo = (qid: string, queueName: string, visibilitySeconds: number, dlq?: sqs.Queue) =>
      new sqs.Queue(this, qid, {
        queueName,
        fifo: true,
        // Deduplication ids are supplied by the sender (publish id, publish id + subdir), never derived from the body.
        contentBasedDeduplication: false,
        encryption: sqs.QueueEncryption.SQS_MANAGED,
        enforceSSL: true,
        visibilityTimeout: Duration.seconds(visibilitySeconds),
        retentionPeriod: Duration.days(dlq ? 4 : 14),
        ...(dlq ? { deadLetterQueue: { queue: dlq, maxReceiveCount: MAX_RECEIVES } } : {}),
      });
    this.validateDlq = fifo('ValidateDlq', validateDlqName(c.stage), 30);
    this.indexDlq = fifo('IndexDlq', indexDlqName(c.stage), 30);
    this.validateQueue = fifo('ValidateQueue', validateQueueName(c.stage), VALIDATOR_TIMEOUT_SECONDS * 6, this.validateDlq);
    this.indexQueue = fifo('IndexQueue', indexQueueName(c.stage), INDEXER_TIMEOUT_SECONDS * 6, this.indexDlq);
    this.groupDlq = fifo('GroupDlq', groupDlqName(c.stage), 30);
    this.groupQueue = fifo('GroupQueue', groupQueueName(c.stage), VALIDATOR_TIMEOUT_SECONDS * 6, this.groupDlq);

    const logGroup = (lid: string) =>
      new logs.LogGroup(this, lid, { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: removalPolicyFor(c) });

    // --- the validator ---------------------------------------------------------------------------------------
    this.validator = new lambda.Function(this, 'Validator', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'publish/validator-lambda.handler',
      code: lambda.Code.fromAsset(handlerDir),
      // A 100 MB archive may unpack to 512 MB; the buffers of one archive plus the decompressors need room.
      memorySize: 3008,
      timeout: Duration.seconds(VALIDATOR_TIMEOUT_SECONDS),
      logGroup: logGroup('ValidatorLogs'),
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_CHANNEL_BUCKET: bucketName,
        MOPM_CHANNEL_URL: `https://${c.condaDomain}`,
        MOPM_INDEX_QUEUE_URL: this.indexQueue.queueUrl,
      },
    });
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadAndDeleteQuarantine',
        actions: ['s3:GetObject', 's3:DeleteObject'],
        resources: [`${bucketArn}/quarantine/*`],
      }),
    );
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WritePackageFiles',
        actions: ['s3:PutObject'],
        resources: CHANNEL_SUBDIRS.map((s) => `${bucketArn}/${s}/mojo-*.conda`),
      }),
    );
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadRegistry',
        actions: ['dynamodb:GetItem', 'dynamodb:Query'],
        resources: [table('versions'), table('publishes')],
      }),
    );
    // A version moves pending -> published (or tombstoned) with a conditional write on its revision, together with its
    // audit row: a transaction of two PutItems, so PutItem on exactly these two tables and the publish records.
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WriteVersionsAndPublishes',
        actions: ['dynamodb:PutItem'],
        resources: [table('versions'), table('audit'), table('publishes')],
      }),
    );
    // The package's first published version moves it claimed -> active: a GetItem of the row and a PutItem conditional on its state
    // (src/dynamo-store.ts, activatePackage). Nothing else of that table is read or written here.
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'ActivatePackages', actions: ['dynamodb:GetItem', 'dynamodb:PutItem'], resources: [table('packages')] }),
    );
    this.validator.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendIndexMessages', actions: ['sqs:SendMessage'], resources: [this.indexQueue.queueArn] }),
    );
    // The trigger is declared by hand rather than with SqsEventSource: that helper puts the queue's own unique id (which
    // embeds a hash of its path, and so differs per stage) into the mapping's logical id, and the whole-template stage
    // diff (template-diff.test.ts) would then see three different resources.
    this.validateQueue.grantConsumeMessages(this.validator);
    // A publish burst must not take the account's whole Lambda concurrency pool and starve the read API: the trigger
    // invokes the validator at most VALIDATOR_MAX_CONCURRENCY times at once (this also bounds the 3 GB buffers in flight).
    // Excess messages wait in the queue. A cap on the trigger takes nothing from the account's unreserved pool.
    new lambda.EventSourceMapping(this, 'ValidatorTrigger', {
      target: this.validator,
      eventSourceArn: this.validateQueue.queueArn,
      batchSize: 1,
      maxConcurrency: VALIDATOR_MAX_CONCURRENCY,
    });

    // --- the index writer ------------------------------------------------------------------------------------
    this.indexer = new lambda.Function(this, 'Indexer', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'publish/indexer-lambda.handler',
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 1024,
      timeout: Duration.seconds(INDEXER_TIMEOUT_SECONDS),
      logGroup: logGroup('IndexerLogs'),
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_CHANNEL_BUCKET: bucketName,
        MOPM_DISTRIBUTION_ID: props.channel.distribution.distributionId,
        MOPM_INDEX_QUEUE_URL: this.indexQueue.queueUrl,
        MOPM_GROUP_QUEUE_URL: this.groupQueue.queueUrl,
      },
    });
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WriteRepodata',
        actions: ['s3:PutObject'],
        resources: CHANNEL_SUBDIRS.flatMap((s) => [`${bucketArn}/${s}/repodata.json`, `${bucketArn}/${s}/repodata.json.zst`]),
      }),
    );
    // The sparse index (spec/index.md): one file per package and the takedown log, all under index/. PutObject only:
    // the writer never reads its own output (it rebuilds from the registry's rows).
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WriteSparseIndex',
        actions: ['s3:PutObject'],
        resources: [`${bucketArn}/index/*`],
      }),
    );
    // The last repodata job of a publish (or an unyank chain) queues the package's index job on this same queue.
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendPackageIndexJobs', actions: ['sqs:SendMessage'], resources: [this.indexQueue.queueArn] }),
    );
    // The last index hop of a committed group's chain queues the flip on the group queue (src/publish/group-chain.ts). The hops release
    // their gates on the group's header with the PutItem on the publishes table below; the flip itself is the group validator's.
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendFlipMessages', actions: ['sqs:SendMessage'], resources: [this.groupQueue.queueArn] }),
    );
    // The index is rebuilt from every record: the package names (a Scan of the small packages table) and their versions.
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadRegistryForIndex',
        actions: ['dynamodb:Scan', 'dynamodb:Query'],
        resources: [table('packages'), table('versions')],
      }),
    );
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadAndUpdatePublishes',
        actions: ['dynamodb:GetItem', 'dynamodb:PutItem'],
        resources: [table('publishes')],
      }),
    );
    this.indexer.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'InvalidateChannelRepodata',
        actions: ['cloudfront:CreateInvalidation'],
        resources: [`arn:aws:cloudfront::${this.account}:distribution/${props.channel.distribution.distributionId}`],
      }),
    );
    this.indexQueue.grantConsumeMessages(this.indexer);
    new lambda.EventSourceMapping(this, 'IndexerTrigger', { target: this.indexer, eventSourceArn: this.indexQueue.queueArn, batchSize: 1 });

    // --- the group validator ---------------------------------------------------------------------------------
    // The same code shape as the validator, on a queue of its own (see GROUP_VALIDATOR_MAX_CONCURRENCY): a group's job validates
    // every member, copies the files into the channel and commits the group (src/publish/group-validator.ts).
    this.groupValidator = new lambda.Function(this, 'GroupValidator', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'publish/group-validator-lambda.handler',
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 3008,
      timeout: Duration.seconds(VALIDATOR_TIMEOUT_SECONDS),
      logGroup: logGroup('GroupValidatorLogs'),
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_CHANNEL_BUCKET: bucketName,
        MOPM_CHANNEL_URL: `https://${c.condaDomain}`,
        MOPM_GROUP_QUEUE_URL: this.groupQueue.queueUrl,
        MOPM_INDEX_QUEUE_URL: this.indexQueue.queueUrl,
      },
    });
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadAndDeleteQuarantine',
        actions: ['s3:GetObject', 's3:DeleteObject'],
        resources: [`${bucketArn}/quarantine/*`],
      }),
    );
    // A create-only write that finds the key taken reads the object to compare its bytes (a repeat of the step leaves the same ones).
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadAndWritePackageFiles',
        actions: ['s3:GetObject', 's3:PutObject'],
        resources: CHANNEL_SUBDIRS.map((s) => `${bucketArn}/${s}/mojo-*.conda`),
      }),
    );
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadRegistry',
        actions: ['dynamodb:GetItem', 'dynamodb:Query'],
        resources: [table('versions'), table('publishes'), table('uploads')],
      }),
    );
    // Stage, burn and commit are conditional writes on a revision (a row, or the group's header) with an audit row each: PutItem only.
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WriteVersionsAndGroups',
        actions: ['dynamodb:PutItem'],
        resources: [table('versions'), table('audit'), table('publishes')],
      }),
    );
    // The flip publishes the members, so it also moves each member's package claimed -> active (the same read and conditional put as the validator's).
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'ActivatePackages', actions: ['dynamodb:GetItem', 'dynamodb:PutItem'], resources: [table('packages')] }),
    );
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendGroupMessages', actions: ['sqs:SendMessage'], resources: [this.groupQueue.queueArn] }),
    );
    // A committed group's chain starts with a repodata hop on the index queue (src/publish/group-chain.ts); the flip that ends it is
    // a message on the group queue, which this function consumes.
    this.groupValidator.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendChainMessages', actions: ['sqs:SendMessage'], resources: [this.indexQueue.queueArn] }),
    );
    this.groupQueue.grantConsumeMessages(this.groupValidator);
    new lambda.EventSourceMapping(this, 'GroupValidatorTrigger', {
      target: this.groupValidator,
      eventSourceArn: this.groupQueue.queueArn,
      batchSize: 1,
      maxConcurrency: GROUP_VALIDATOR_MAX_CONCURRENCY,
    });

    // --- the group sweeper -----------------------------------------------------------------------------------
    // Every SWEEPER_PERIOD_MINUTES: find a group that has stopped (validating, or committed and not yet visible) and send its message again
    // (src/publish/group-sweeper.ts). It reads the sparse index of groups that are not over, and writes only the header's
    // resend counter. It ends and burns nothing.
    this.sweeper = new lambda.Function(this, 'GroupSweeper', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'publish/sweeper-lambda.handler',
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 256,
      timeout: Duration.seconds(60),
      logGroup: logGroup('GroupSweeperLogs'),
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_GROUP_QUEUE_URL: this.groupQueue.queueUrl,
        MOPM_INDEX_QUEUE_URL: this.indexQueue.queueUrl,
      },
    });
    this.sweeper.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadGroups',
        actions: ['dynamodb:GetItem'],
        resources: [table('publishes')],
      }),
    );
    this.sweeper.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'QuerySweepIndex',
        actions: ['dynamodb:Query'],
        resources: [`${table('publishes')}/index/by_sweep`],
      }),
    );
    this.sweeper.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'WriteGroupHeaders',
        actions: ['dynamodb:PutItem'],
        resources: [table('publishes'), table('audit')],
      }),
    );
    this.sweeper.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendGroupMessages', actions: ['sqs:SendMessage'], resources: [this.groupQueue.queueArn] }),
    );
    // A stalled chain is resent from the step the header says is next: a repodata or index hop on the index queue, or the flip on the group queue.
    this.sweeper.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'SendChainMessages', actions: ['sqs:SendMessage'], resources: [this.indexQueue.queueArn] }),
    );
    const schedule = new events.Rule(this, 'GroupSweeperSchedule', {
      ruleName: `mopm-${c.stage}-group-sweeper`,
      schedule: events.Schedule.rate(Duration.minutes(SWEEPER_PERIOD_MINUTES)),
    });
    // The target and the permission are declared by hand rather than with `targets.LambdaFunction`: that helper puts a hash of
    // the construct path (which contains the stage's stack name) into the permission's logical id, and the whole-template stage
    // diff (template-diff.test.ts) would then see three different resources.
    schedule.addTarget({ bind: () => ({ id: 'GroupSweeper', arn: this.sweeper.functionArn }) });
    this.sweeper.addPermission('AllowGroupSweeperSchedule', { principal: new iam.ServicePrincipal('events.amazonaws.com'), sourceArn: schedule.ruleArn });

    // --- alarms: anything in a dead-letter queue is a publish that needs a person ---------------------------
    for (const [aid, q, label] of [
      ['ValidateDlqAlarm', this.validateDlq, 'validate'],
      ['IndexDlqAlarm', this.indexDlq, 'index'],
      ['GroupDlqAlarm', this.groupDlq, 'group'],
    ] as const) {
      new cloudwatch.Alarm(this, aid, {
        alarmName: `mopm-${c.stage}-${label}-dlq-depth`,
        alarmDescription: `A ${label} message failed ${MAX_RECEIVES} times and is in the dead-letter queue; look at the Lambda logs, then redrive or reject.`,
        metric: q.metricApproximateNumberOfMessagesVisible({ period: Duration.minutes(1), statistic: 'Maximum' }),
        threshold: 1,
        evaluationPeriods: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
    }

    // --- alarms on the group metrics (embedded-metric-format lines the handlers write; src/metrics.ts) ----------
    // A metric that is never written does not breach: `NOT_BREACHING` on all of them, so an alarm sits quiet until its
    // metric exists.
    for (const a of GROUP_ALARMS) {
      new cloudwatch.Alarm(this, a.id, {
        alarmName: `mopm-${c.stage}-${a.name}`,
        alarmDescription: a.description,
        metric: new cloudwatch.Metric({ namespace: METRICS_NAMESPACE, metricName: a.metric, statistic: a.statistic, period: Duration.minutes(5) }),
        threshold: a.threshold,
        evaluationPeriods: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
    }
  }
}

/** The namespace of the embedded-metric-format lines (service/api/src/metrics.ts, METRICS_NAMESPACE; publish.test.ts holds the two equal). */
export const METRICS_NAMESPACE = 'Mopm/Registry';

/**
 * Alarms on the group metrics. `group_invariant` is written by a reader that found a committed group with a member it
 * cannot account for; `group_pending_rows_per_package_max` by group creation (the most pending rows any member's package
 * holds: dead groups leave theirs behind); `group_oldest_nonterminal_age_seconds` is written by the group sweeper: seconds since the
 * least recently active group that is validating, or committed and not yet visible, showed a sign of life
 * (a visible group has left the sweeper's index); `group_sweeper_gave_up` counts the stalled groups it has resent as often as it will.
 */
export const GROUP_ALARMS: Array<{ id: string; name: string; metric: string; statistic: string; threshold: number; description: string }> = [
  {
    id: 'GroupInvariantAlarm',
    name: 'group-invariant',
    metric: 'group_invariant',
    statistic: 'Sum',
    threshold: 1,
    description: 'A reader found a committed group with a member it cannot account for; the group is hidden (API) or the build fails. Look at the logs for the group id.',
  },
  {
    id: 'GroupPendingRowsAlarm',
    name: 'group-pending-rows',
    metric: 'group_pending_rows_per_package_max',
    statistic: 'Maximum',
    threshold: 100,
    description: 'A package holds 100 or more pending version rows; groups that ended leave theirs behind. Look at the groups that created them.',
  },
  {
    id: 'GroupOldestActiveAlarm',
    name: 'group-oldest-active',
    metric: 'group_oldest_nonterminal_age_seconds',
    statistic: 'Maximum',
    threshold: 1800,
    description: 'A group that is validating or committed (and not yet visible) has shown no sign of life for 30 minutes. The sweeper resends a validate message after 35 minutes and a step of the chain after 10; look at the logs.',
  },
  {
    id: 'GroupStalledAlarm',
    name: 'group-stalled',
    metric: 'group_sweeper_gave_up',
    statistic: 'Sum',
    threshold: 1,
    description: 'A group stopped validating and the sweeper has resent its message as often as it will. A person decides: read it with the status mode of the group tool, then end it or leave it.',
  },
];
