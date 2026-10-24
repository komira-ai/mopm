import * as fs from 'fs';
import * as path from 'path';
import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { GROUP_ALARMS, GROUP_VALIDATOR_MAX_CONCURRENCY, INDEXER_TIMEOUT_SECONDS, MAX_RECEIVES, METRICS_NAMESPACE, SWEEPER_PERIOD_MINUTES, VALIDATOR_MAX_CONCURRENCY, VALIDATOR_TIMEOUT_SECONDS } from '../lib/publish-stack';
import { DUMMY_ACCOUNT, tpl } from './util';

describe.each(STAGES)('PublishStack %s', (stage) => {
  const { publish: t, api, ...rest } = tpl(stage);
  const bucket = `mopm-${stage}-channel-${DUMMY_ACCOUNT}`;
  const fn = (handler: string): any =>
    Object.values(t.findResources('AWS::Lambda::Function')).find((r: any) => r.Properties.Handler === handler);
  const statementsOf = (f: any): any[] => {
    const roleLogical = f.Properties.Role['Fn::GetAtt'][0];
    return Object.values(t.findResources('AWS::IAM::Policy'))
      .filter((p: any) => JSON.stringify(p.Properties.Roles).includes(roleLogical))
      .flatMap((p: any) => p.Properties.PolicyDocument.Statement as any[]);
  };
  const acts = (s: any): string[] => ([] as string[]).concat(s.Action);
  const res = (s: any) => JSON.stringify(s.Resource);

  test('six FIFO queues: validate, index and group, each with a FIFO dead-letter queue', () => {
    const queues = Object.values(t.findResources('AWS::SQS::Queue')) as any[];
    expect(queues.map((q) => q.Properties.QueueName).sort()).toEqual(
      [`mopm-${stage}-validate.fifo`, `mopm-${stage}-validate-dlq.fifo`, `mopm-${stage}-index.fifo`, `mopm-${stage}-index-dlq.fifo`, `mopm-${stage}-group.fifo`, `mopm-${stage}-group-dlq.fifo`].sort(),
    );
    for (const q of queues) {
      expect(q.Properties.FifoQueue).toBe(true);
      // The sender supplies the deduplication id (publish id): never the body hash.
      expect(q.Properties.ContentBasedDeduplication).toBe(false);
      expect(q.Properties.SqsManagedSseEnabled).toBe(true);
    }
    for (const name of ['validate', 'index', 'group']) {
      t.hasResourceProperties('AWS::SQS::Queue', {
        QueueName: `mopm-${stage}-${name}.fifo`,
        RedrivePolicy: Match.objectLike({ maxReceiveCount: MAX_RECEIVES, deadLetterTargetArn: Match.anyValue() }),
      });
    }
  });

  test('queue visibility is six times the Lambda timeout, as AWS advises for an SQS trigger', () => {
    t.hasResourceProperties('AWS::SQS::Queue', { QueueName: `mopm-${stage}-validate.fifo`, VisibilityTimeout: VALIDATOR_TIMEOUT_SECONDS * 6 });
    t.hasResourceProperties('AWS::SQS::Queue', { QueueName: `mopm-${stage}-index.fifo`, VisibilityTimeout: INDEXER_TIMEOUT_SECONDS * 6 });
    t.hasResourceProperties('AWS::Lambda::Function', { Handler: 'publish/validator-lambda.handler', Timeout: VALIDATOR_TIMEOUT_SECONDS, Runtime: 'nodejs22.x' });
    t.hasResourceProperties('AWS::Lambda::Function', { Handler: 'publish/indexer-lambda.handler', Timeout: INDEXER_TIMEOUT_SECONDS, Runtime: 'nodejs22.x' });
  });

  test('the validator is capped at 5 concurrent invocations by its queue trigger, so a publish burst cannot starve the read API; the indexer is not capped', () => {
    expect(VALIDATOR_MAX_CONCURRENCY).toBe(5);
    const maps = Object.values(t.findResources('AWS::Lambda::EventSourceMapping')) as any[];
    const scaling = (queue: string) =>
      maps.find((m) => JSON.stringify(m.Properties.EventSourceArn).includes(queue))?.Properties.ScalingConfig;
    expect(scaling('ValidateQueue')).toEqual({ MaximumConcurrency: 5 });
    expect(scaling('IndexQueue')).toBeUndefined();
  });

  // Lambda refuses a reservation that would leave the account's unreserved concurrency under 10 ("decreases account's
  // UnreservedConcurrentExecution below its minimum value of [10]"), and a new account's whole limit is 10: any
  // reservation fails the deploy and CloudFormation rolls back. Cap with the trigger's maximum concurrency instead.
  test('no function of any stack reserves concurrency', () => {
    for (const [name, template] of Object.entries({ publish: t, api, ...rest })) {
      for (const [id, f] of Object.entries(template.findResources('AWS::Lambda::Function')) as [string, any][]) {
        expect([name, id, f.Properties.ReservedConcurrentExecutions]).toEqual([name, id, undefined]);
      }
    }
  });

  test('each queue triggers its own Lambda, one message at a time', () => {
    t.resourceCountIs('AWS::Lambda::EventSourceMapping', 3);
    t.hasResourceProperties('AWS::Lambda::EventSourceMapping', { BatchSize: 1, EventSourceArn: Match.anyValue() });
    const maps = Object.values(t.findResources('AWS::Lambda::EventSourceMapping')) as any[];
    expect(maps.every((m) => m.Properties.BatchSize === 1)).toBe(true);
  });

  test('the validator role: quarantine read+delete, package writes, version writes, index messages; nothing else', () => {
    const st = statementsOf(fn('publish/validator-lambda.handler'));
    const own = st.filter((s) => s.Sid);
    expect(own.map((s) => s.Sid).sort()).toEqual(
      ['ReadAndDeleteQuarantine', 'ReadRegistry', 'SendIndexMessages', 'WritePackageFiles', 'WriteVersionsAndPublishes'].sort(),
    );
    const by = (sid: string) => own.find((s) => s.Sid === sid);
    expect(acts(by('ReadAndDeleteQuarantine')).sort()).toEqual(['s3:DeleteObject', 's3:GetObject']);
    expect(res(by('ReadAndDeleteQuarantine'))).toContain(`${bucket}/quarantine/*`);
    expect(acts(by('WritePackageFiles'))).toEqual(['s3:PutObject']);
    for (const sub of ['noarch', 'linux-64', 'linux-aarch64', 'osx-arm64']) expect(res(by('WritePackageFiles'))).toContain(`${bucket}/${sub}/mojo-*.conda`);
    expect(res(by('WritePackageFiles'))).not.toContain('repodata');
    expect(acts(by('WriteVersionsAndPublishes'))).toEqual(['dynamodb:PutItem']);
    expect(res(by('WriteVersionsAndPublishes'))).toContain(`mopm-${stage}-versions`);
    expect(res(by('WriteVersionsAndPublishes'))).toContain(`mopm-${stage}-audit`);
    expect(res(by('WriteVersionsAndPublishes'))).not.toContain(`mopm-${stage}-packages`);
    expect(acts(by('SendIndexMessages'))).toEqual(['sqs:SendMessage']);
    expect(res(by('SendIndexMessages'))).not.toContain('validate');
    const all = st.flatMap(acts);
    expect(all.filter((a) => /DeleteItem|DeleteObjectVersion|Scan|^cloudfront|\*/.test(a))).toEqual([]);
  });

  test('the index writer role: repodata and index/ writes only, record reads, its own queue, one invalidation on this distribution', () => {
    const st = statementsOf(fn('publish/indexer-lambda.handler'));
    const own = st.filter((s) => s.Sid);
    expect(own.map((s) => s.Sid).sort()).toEqual(
      ['InvalidateChannelRepodata', 'ReadAndUpdatePublishes', 'ReadRegistryForIndex', 'SendPackageIndexJobs', 'WriteRepodata', 'WriteSparseIndex'].sort(),
    );
    const by = (sid: string) => own.find((s) => s.Sid === sid);
    expect(acts(by('WriteRepodata'))).toEqual(['s3:PutObject']);
    const writes = res(by('WriteRepodata'));
    expect(writes).toContain(`${bucket}/noarch/repodata.json.zst`);
    expect(writes).not.toContain('mojo-');
    expect(writes).not.toContain('quarantine');
    expect(writes).not.toContain('index/');
    // The sparse index: PutObject on index/* and nothing else of the bucket.
    expect(acts(by('WriteSparseIndex'))).toEqual(['s3:PutObject']);
    expect(by('WriteSparseIndex').Effect).toBe('Allow');
    expect(([] as any[]).concat(by('WriteSparseIndex').Resource)).toHaveLength(1);
    expect(res(by('WriteSparseIndex'))).toContain(`${bucket}/index/*`);
    // The one resource is the ARN of exactly `<bucket>/index/*`: no prefix wildcard before `index/`, nothing after it.
    const leaves = (v: any): string[] => (typeof v === 'string' ? [v] : v && typeof v === 'object' ? Object.values(v).flatMap(leaves) : []);
    expect(leaves(by('WriteSparseIndex').Resource).join('').endsWith(`:::${bucket}/index/*`)).toBe(true);
    expect(res(by('WriteSparseIndex'))).not.toContain('repodata');
    expect(res(by('WriteSparseIndex'))).not.toContain('quarantine');
    // Its own queue, send only (the package job of a publish is queued by the last repodata job).
    expect(acts(by('SendPackageIndexJobs'))).toEqual(['sqs:SendMessage']);
    expect(res(by('SendPackageIndexJobs'))).toContain('IndexQueue');
    expect(res(by('SendPackageIndexJobs'))).not.toContain('Validate');
    expect(acts(by('InvalidateChannelRepodata'))).toEqual(['cloudfront:CreateInvalidation']);
    expect(res(by('InvalidateChannelRepodata'))).toContain('distribution/');
    expect(acts(by('ReadRegistryForIndex')).sort()).toEqual(['dynamodb:Query', 'dynamodb:Scan']);
    expect(res(by('ReadRegistryForIndex'))).toContain(`mopm-${stage}-packages`);
    expect(res(by('ReadRegistryForIndex'))).not.toContain(`mopm-${stage}-tokens`);
    // It never reads the bucket (a rebuild comes from the registry) and never deletes.
    expect(st.flatMap(acts).some((a) => a === 's3:DeleteObject' || a === 's3:GetObject' || a === 's3:ListBucket')).toBe(false);
    // Every S3 grant of the role is a PutObject on one of the two scoped sets.
    const s3 = own.filter((s) => acts(s).some((a) => a.startsWith('s3:')));
    expect(s3.map((s) => s.Sid).sort()).toEqual(['WriteRepodata', 'WriteSparseIndex']);
  });

  test('each dead-letter queue has an alarm that fires on a single message', () => {
    for (const name of ['validate', 'index', 'group']) {
      t.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: `mopm-${stage}-${name}-dlq-depth`,
        MetricName: 'ApproximateNumberOfMessagesVisible',
        Namespace: 'AWS/SQS',
        Threshold: 1,
        ComparisonOperator: 'GreaterThanOrEqualToThreshold',
        TreatMissingData: 'notBreaching',
      });
    }
    // ... and the group alarms watch the group metrics (the next test).
    t.resourceCountIs('AWS::CloudWatch::Alarm', 3 + GROUP_ALARMS.length);
  });

  test('four alarms watch the group metrics, in the namespace the handlers write them to; a metric nobody has written yet does not breach', () => {
    // The namespace is the one the handlers' embedded-metric-format lines name (service/api/src/metrics.ts).
    const metrics = fs.readFileSync(path.resolve(__dirname, '../../../api/src/metrics.ts'), 'utf8');
    expect(/METRICS_NAMESPACE = '([^']+)'/.exec(metrics)![1]).toBe(METRICS_NAMESPACE);
    // ... and so are the metric names, which the group code emits (group_pending_rows_per_package_max, group_invariant) and the sweeper (the other two).
    const emitted = [
      fs.readFileSync(path.resolve(__dirname, '../../../api/src/group.ts'), 'utf8'),
      fs.readFileSync(path.resolve(__dirname, '../../../api/src/publish/group-service.ts'), 'utf8'),
      fs.readFileSync(path.resolve(__dirname, '../../../api/src/publish/group-sweeper.ts'), 'utf8'),
    ].join('\n');
    expect(emitted).toContain("name: 'group_invariant'");
    expect(emitted).toContain("name: 'group_pending_rows_per_package_max'");
    expect(emitted).toContain("name: 'group_oldest_nonterminal_age_seconds'");
    expect(emitted).toContain("name: 'group_sweeper_gave_up'");

    expect(GROUP_ALARMS.map((a) => a.metric)).toEqual(['group_invariant', 'group_pending_rows_per_package_max', 'group_oldest_nonterminal_age_seconds', 'group_sweeper_gave_up']);
    for (const a of GROUP_ALARMS) {
      t.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: `mopm-${stage}-${a.name}`,
        MetricName: a.metric,
        Namespace: 'Mopm/Registry',
        Statistic: a.statistic,
        Period: 300,
        EvaluationPeriods: 1,
        Threshold: a.threshold,
        ComparisonOperator: 'GreaterThanOrEqualToThreshold',
        TreatMissingData: 'notBreaching',
      });
    }
    // Any one invariant violation; 30 minutes without a sign of life for a group that is validating; any one stalled group the sweeper gave up on.
    expect(GROUP_ALARMS.find((a) => a.metric === 'group_invariant')).toMatchObject({ threshold: 1, statistic: 'Sum' });
    expect(GROUP_ALARMS.find((a) => a.metric === 'group_oldest_nonterminal_age_seconds')).toMatchObject({ threshold: 1800 });
    expect(GROUP_ALARMS.find((a) => a.metric === 'group_sweeper_gave_up')).toMatchObject({ threshold: 1, statistic: 'Sum' });
  });

  test('the validator has room for a 100 MB archive that unpacks to 512 MB', () => {
    t.hasResourceProperties('AWS::Lambda::Function', { Handler: 'publish/validator-lambda.handler', MemorySize: 3008 });
  });

  test('the validator knows the channel bucket, its public URL and the index queue; the indexer the distribution and the index queue', () => {
    const host = stage === 'prod' ? 'conda.mopm.dev' : `conda.${stage}.mopm.dev`;
    t.hasResourceProperties('AWS::Lambda::Function', {
      Handler: 'publish/validator-lambda.handler',
      Environment: { Variables: Match.objectLike({ MOPM_STAGE: stage, MOPM_CHANNEL_BUCKET: bucket, MOPM_CHANNEL_URL: `https://${host}`, MOPM_INDEX_QUEUE_URL: Match.anyValue() }) },
    });
    t.hasResourceProperties('AWS::Lambda::Function', {
      Handler: 'publish/indexer-lambda.handler',
      Environment: { Variables: Match.objectLike({ MOPM_CHANNEL_BUCKET: bucket, MOPM_DISTRIBUTION_ID: Match.anyValue(), MOPM_INDEX_QUEUE_URL: Match.anyValue() }) },
    });
  });

  test('the indexer is pointed at the index queue, and not the validate queue', () => {
    const env = fn('publish/indexer-lambda.handler').Properties.Environment.Variables;
    expect(JSON.stringify(env.MOPM_INDEX_QUEUE_URL)).toContain('IndexQueue');
    expect(JSON.stringify(env.MOPM_INDEX_QUEUE_URL)).not.toContain('Validate');
  });

  test('the API stack sends to the validate queue (commits), the group queue (group commits) and the index queue (yank rebuilds), send-only, and nowhere else', () => {
    const st = Object.values(api.findResources('AWS::IAM::Policy')).flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[]);
    const q = st.filter((s) => ([] as string[]).concat(s.Action).some((a) => a.startsWith('sqs:')));
    expect(q.map((x) => x.Sid).sort()).toEqual(['QueueCommits', 'QueueGroupCommits', 'QueueIndexRebuilds']);
    for (const x of q) expect(([] as string[]).concat(x.Action)).toEqual(['sqs:SendMessage']);
    // Each statement names its own queue, and the group's names the group queue only.
    expect(res(q.find((x) => x.Sid === 'QueueGroupCommits'))).toContain(`mopm-${stage}-group.fifo`);
    expect(res(q.find((x) => x.Sid === 'QueueCommits'))).not.toContain('group');
  });

  // --- groups: their own queue, validator and sweeper ------------------------------------------------------

  test('group validations run on a queue of their own, at most 2 at a time, and the single validator keeps its 5', () => {
    expect(GROUP_VALIDATOR_MAX_CONCURRENCY).toBe(2);
    const maps = Object.values(t.findResources('AWS::Lambda::EventSourceMapping')) as any[];
    const scaling = (queue: string) => maps.find((m) => JSON.stringify(m.Properties.EventSourceArn).includes(queue))?.Properties.ScalingConfig;
    expect(scaling('GroupQueue')).toEqual({ MaximumConcurrency: 2 });
    expect(scaling('ValidateQueue')).toEqual({ MaximumConcurrency: VALIDATOR_MAX_CONCURRENCY });
    // The group queue's messages wait as long as the validator's (visibility six times the timeout) and go to the group dead-letter queue.
    t.hasResourceProperties('AWS::SQS::Queue', { QueueName: `mopm-${stage}-group.fifo`, VisibilityTimeout: VALIDATOR_TIMEOUT_SECONDS * 6 });
    // Each trigger reads its own queue's function: the group function is not the single validator.
    const target = (queue: string) => JSON.stringify(maps.find((m) => JSON.stringify(m.Properties.EventSourceArn).includes(queue)).Properties.FunctionName);
    expect(target('GroupQueue')).toContain('GroupValidator');
    expect(target('ValidateQueue')).not.toContain('GroupValidator');
  });

  test('the group validator is the validator\'s shape: 3 GB, 300 seconds, its own queue in its environment', () => {
    t.hasResourceProperties('AWS::Lambda::Function', {
      Handler: 'publish/group-validator-lambda.handler',
      Runtime: 'nodejs22.x',
      MemorySize: 3008,
      Timeout: VALIDATOR_TIMEOUT_SECONDS,
      Environment: { Variables: Match.objectLike({ MOPM_STAGE: stage, MOPM_CHANNEL_BUCKET: bucket, MOPM_CHANNEL_URL: Match.anyValue(), MOPM_GROUP_QUEUE_URL: Match.anyValue() }) },
    });
    const env = fn('publish/group-validator-lambda.handler').Properties.Environment.Variables;
    expect(JSON.stringify(env.MOPM_GROUP_QUEUE_URL)).toContain('GroupQueue');
    expect(JSON.stringify(env.MOPM_GROUP_QUEUE_URL)).not.toContain('ValidateQueue');
  });

  test('the group validator role: quarantine read+delete, channel file read+write, registry reads and puts, its own queue; nothing else', () => {
    const st = statementsOf(fn('publish/group-validator-lambda.handler'));
    const own = st.filter((s) => s.Sid);
    expect(own.map((s) => s.Sid).sort()).toEqual(['ReadAndDeleteQuarantine', 'ReadAndWritePackageFiles', 'ReadRegistry', 'SendGroupMessages', 'WriteVersionsAndGroups'].sort());
    const by = (sid: string) => own.find((s) => s.Sid === sid);
    expect(acts(by('ReadAndDeleteQuarantine')).sort()).toEqual(['s3:DeleteObject', 's3:GetObject']);
    expect(res(by('ReadAndDeleteQuarantine'))).toContain(`${bucket}/quarantine/*`);
    // A create-only copy that finds the key taken reads the object to compare it; only the package files, never repodata or index/.
    expect(acts(by('ReadAndWritePackageFiles')).sort()).toEqual(['s3:GetObject', 's3:PutObject']);
    for (const sub of ['noarch', 'linux-64', 'linux-aarch64', 'osx-arm64']) expect(res(by('ReadAndWritePackageFiles'))).toContain(`${bucket}/${sub}/mojo-*.conda`);
    expect(res(by('ReadAndWritePackageFiles'))).not.toContain('repodata');
    expect(res(by('ReadAndWritePackageFiles'))).not.toContain('index/');
    // It reads the upload records (their age) as well as the versions and the group items.
    expect(acts(by('ReadRegistry')).sort()).toEqual(['dynamodb:GetItem', 'dynamodb:Query']);
    for (const table of ['versions', 'publishes', 'uploads']) expect(res(by('ReadRegistry'))).toContain(`mopm-${stage}-${table}`);
    expect(acts(by('WriteVersionsAndGroups'))).toEqual(['dynamodb:PutItem']);
    for (const table of ['versions', 'audit', 'publishes']) expect(res(by('WriteVersionsAndGroups'))).toContain(`mopm-${stage}-${table}`);
    expect(res(by('WriteVersionsAndGroups'))).not.toContain(`mopm-${stage}-packages`);
    // It sends to the group queue (its own continuation) and consumes it; it cannot send to the single or the index queue.
    expect(acts(by('SendGroupMessages'))).toEqual(['sqs:SendMessage']);
    expect(res(by('SendGroupMessages'))).toContain('GroupQueue');
    expect(res(by('SendGroupMessages'))).not.toContain('Validate');
    expect(res(by('SendGroupMessages'))).not.toContain('IndexQueue');
    const all = st.flatMap(acts);
    expect(all.filter((a) => /DeleteItem|DeleteObjectVersion|Scan|^cloudfront|\*/.test(a))).toEqual([]);
  });

  test('the sweeper runs every 5 minutes, reads the sweep index and the headers, writes headers, and sends to the group queue; it cannot end or delete anything', () => {
    expect(SWEEPER_PERIOD_MINUTES).toBe(5);
    t.hasResourceProperties('AWS::Events::Rule', { ScheduleExpression: 'rate(5 minutes)', State: 'ENABLED' });
    t.resourceCountIs('AWS::Events::Rule', 1);
    t.hasResourceProperties('AWS::Lambda::Function', {
      Handler: 'publish/sweeper-lambda.handler',
      Timeout: 60,
      Environment: { Variables: Match.objectLike({ MOPM_STAGE: stage, MOPM_GROUP_QUEUE_URL: Match.anyValue() }) },
    });
    const st = statementsOf(fn('publish/sweeper-lambda.handler'));
    const own = st.filter((s) => s.Sid);
    expect(own.map((s) => s.Sid).sort()).toEqual(['QuerySweepIndex', 'ReadGroups', 'SendGroupMessages', 'WriteGroupHeaders']);
    const by = (sid: string) => own.find((s) => s.Sid === sid);
    expect(acts(by('QuerySweepIndex'))).toEqual(['dynamodb:Query']);
    expect(res(by('QuerySweepIndex'))).toContain(`mopm-${stage}-publishes`);
    expect(res(by('QuerySweepIndex'))).toContain('/index/by_sweep');
    expect(acts(by('ReadGroups'))).toEqual(['dynamodb:GetItem']);
    expect(acts(by('WriteGroupHeaders'))).toEqual(['dynamodb:PutItem']);
    expect(res(by('WriteGroupHeaders'))).toContain(`mopm-${stage}-publishes`);
    expect(res(by('WriteGroupHeaders'))).toContain(`mopm-${stage}-audit`);
    expect(res(by('WriteGroupHeaders'))).not.toContain(`mopm-${stage}-versions`);
    expect(acts(by('SendGroupMessages'))).toEqual(['sqs:SendMessage']);
    expect(res(by('SendGroupMessages'))).toContain('GroupQueue');
    // No bucket, no version rows, no delete, no scan.
    const all = st.flatMap(acts);
    expect(all.some((a) => a.startsWith('s3:'))).toBe(false);
    expect(all.filter((a) => /DeleteItem|Scan|\*/.test(a))).toEqual([]);
    expect(own.filter((s) => acts(s).some((a) => a.startsWith('dynamodb:'))).every((s) => !res(s).includes(`mopm-${stage}-versions`))).toBe(true);
  });
});
