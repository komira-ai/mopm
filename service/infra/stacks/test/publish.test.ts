import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { INDEXER_TIMEOUT_SECONDS, MAX_RECEIVES, VALIDATOR_MAX_CONCURRENCY, VALIDATOR_TIMEOUT_SECONDS } from '../lib/publish-stack';
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

  test('four FIFO queues: validate and index, each with a FIFO dead-letter queue', () => {
    const queues = Object.values(t.findResources('AWS::SQS::Queue')) as any[];
    expect(queues.map((q) => q.Properties.QueueName).sort()).toEqual(
      [`mopm-${stage}-validate.fifo`, `mopm-${stage}-validate-dlq.fifo`, `mopm-${stage}-index.fifo`, `mopm-${stage}-index-dlq.fifo`].sort(),
    );
    for (const q of queues) {
      expect(q.Properties.FifoQueue).toBe(true);
      // The sender supplies the deduplication id (publish id): never the body hash.
      expect(q.Properties.ContentBasedDeduplication).toBe(false);
      expect(q.Properties.SqsManagedSseEnabled).toBe(true);
    }
    for (const name of ['validate', 'index']) {
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
    t.resourceCountIs('AWS::Lambda::EventSourceMapping', 2);
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
    for (const name of ['validate', 'index']) {
      t.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: `mopm-${stage}-${name}-dlq-depth`,
        MetricName: 'ApproximateNumberOfMessagesVisible',
        Namespace: 'AWS/SQS',
        Threshold: 1,
        ComparisonOperator: 'GreaterThanOrEqualToThreshold',
        TreatMissingData: 'notBreaching',
      });
    }
    t.resourceCountIs('AWS::CloudWatch::Alarm', 2);
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

  test('the API stack sends to the validate queue (commits) and the index queue (yank rebuilds), send-only, and nowhere else', () => {
    const st = Object.values(api.findResources('AWS::IAM::Policy')).flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[]);
    const q = st.filter((s) => ([] as string[]).concat(s.Action).some((a) => a.startsWith('sqs:')));
    expect(q.map((x) => x.Sid).sort()).toEqual(['QueueCommits', 'QueueIndexRebuilds']);
    for (const x of q) expect(([] as string[]).concat(x.Action)).toEqual(['sqs:SendMessage']);
  });
});
