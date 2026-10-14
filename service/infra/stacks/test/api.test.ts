import { App } from 'aws-cdk-lib';
import { Match } from 'aws-cdk-lib/assertions';
import { ApiStack, PUBLISH_ROUTES, READ_ACTIONS, READ_INDEXES, READ_ROUTES, READ_TABLES, WRITE_GRANTS } from '../lib/api-stack';
import { STAGES, stageConfig, tableName } from '../lib/config';
import { DUMMY_ACCOUNT, tpl } from './util';

describe.each(STAGES)('ApiStack %s', (stage) => {
  const { api: t } = tpl(stage);
  const host = stage === 'prod' ? 'api.mopm.dev' : `api.${stage}.mopm.dev`;

  test('exactly one Node.js Lambda, from the built bundle, configured for its stage', () => {
    t.resourceCountIs('AWS::Lambda::Function', 1);
    t.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs20.x',
      Handler: 'http/lambda.handler',
      Code: { S3Bucket: Match.anyValue(), S3Key: Match.stringLikeRegexp('\\.zip$') },
      Environment: {
        Variables: { MOPM_STAGE: stage, MOPM_VERSION: '1.2.3', MOPM_COMMIT: 'c0ffee', MOPM_READ_ONLY: 'false' },
      },
    });
  });

  test('HTTP API serves the contract operations the handler implements, with the default endpoint disabled', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Api', { ProtocolType: 'HTTP', DisableExecuteApiEndpoint: true });
    t.resourceCountIs('AWS::ApiGatewayV2::Route', READ_ROUTES.length + PUBLISH_ROUTES.length);
    const keys = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey as string);
    expect(keys.sort()).toEqual(
      [
        'GET /api/v1/health',
        'GET /api/v1/packages',
        'GET /api/v1/packages/{name}',
        'GET /api/v1/packages/{name}/versions',
        'GET /api/v1/packages/{name}/owners',
        'GET /api/v1/packages/{name}/{version}',
        'POST /api/v1/packages/{name}/{version}/files',
        'POST /api/v1/packages/{name}/{version}/publish',
        'GET /api/v1/publishes/{publish_id}',
      ].sort(),
    );
  });

  test('the handler is told where uploads go and where commits are queued, by name', () => {
    t.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: Match.objectLike({
          MOPM_CHANNEL_BUCKET: `mopm-${stage}-channel-${DUMMY_ACCOUNT}`,
          MOPM_VALIDATE_QUEUE_URL: `https://sqs.us-east-1.amazonaws.com/${DUMMY_ACCOUNT}/mopm-${stage}-validate.fifo`,
        }),
      },
    });
  });

  // Every policy statement the handler's role gets. The role is the only one in the stack with a policy.
  const statements = () =>
    Object.values(t.findResources('AWS::IAM::Policy')).flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[]);
  const acts = (s: any): string[] => ([] as string[]).concat(s.Action);
  const flatten = (v: any): string => (typeof v === 'string' ? v : JSON.stringify(v));

  test('reads: GetItem and Query on the four read tables, nothing else in that statement', () => {
    const st = statements().filter((s) => acts(s).some((a) => a === 'dynamodb:Query'));
    expect(st).toHaveLength(1);
    expect(st[0].Effect).toBe('Allow');
    expect(acts(st[0]).sort()).toEqual([...READ_ACTIONS].sort());
    expect(READ_ACTIONS).toEqual(['dynamodb:GetItem', 'dynamodb:Query']);
    const resources = flatten(st[0].Resource);
    for (const table of READ_TABLES) expect(resources).toContain(tableName(stage, table));
    expect(resources).not.toContain('"*"');
    const named = (resources.match(/table\/mopm-[a-z]+-[a-z_]+/g) ?? []).map((m) => m.replace(/\/index.*/, ''));
    expect([...new Set(named)].sort()).toEqual(READ_TABLES.map((x) => `table/${tableName(stage, x)}`).sort());
  });

  // The reviewed write grants, pinned by table. A new write needs a line in WRITE_GRANTS (and so a reviewer).
  test('writes: exactly the reviewed grants, table by table', () => {
    expect(WRITE_GRANTS.map((g) => [g.sid, g.actions, g.tables])).toEqual([
      ['ReserveVersions', ['dynamodb:PutItem'], ['versions', 'audit']],
      ['RecordUploadsAndPublishes', ['dynamodb:GetItem', 'dynamodb:PutItem'], ['uploads', 'publishes']],
      ['AuthenticateTokens', ['dynamodb:GetItem', 'dynamodb:UpdateItem'], ['tokens']],
      ['ReadSwitches', ['dynamodb:GetItem'], ['config']],
    ]);
    for (const g of WRITE_GRANTS) {
      const st = statements().find((x) => x.Sid === g.sid);
      expect(st).toBeDefined();
      expect(acts(st).sort()).toEqual([...g.actions].sort());
      const named = (flatten(st.Resource).match(/table\/mopm-[a-z]+-[a-z_]+/g) ?? []).sort();
      expect(named).toEqual(g.tables.map((x) => `table/${tableName(stage, x)}`).sort());
    }
  });

  test('the one index the handler may Query is named exactly; no index wildcard', () => {
    expect(READ_INDEXES).toEqual({ packages: ['by_search_bucket'] });
    const st = statements().filter((s) => acts(s).some((a) => a.startsWith('dynamodb:')));
    const resources = JSON.stringify(st[0].Resource);
    expect(resources).toContain(`${tableName(stage, 'packages')}/index/by_search_bucket`);
    expect(resources).not.toContain('index/*');
    expect(resources).not.toContain('by_github_id'); // the owners index is not read by the read API
    expect((resources.match(/\/index\//g) ?? []).length).toBe(1);
  });

  test('no statement anywhere grants a delete, a scan or a wildcard action', () => {
    const actions = statements().flatMap(acts);
    for (const a of actions.filter((x) => x.startsWith('dynamodb:'))) {
      expect(a).toMatch(/^dynamodb:(GetItem|Query|PutItem|UpdateItem)$/);
    }
    expect(actions.some((a) => a === '*' || a.endsWith(':*'))).toBe(false);
    expect(actions.some((a) => /Delete|Scan|BatchWrite/.test(a))).toBe(false);
  });

  test('S3 and SQS are reachable only where publishing needs them: quarantine/ and the validate queue', () => {
    const s3 = statements().filter((s) => acts(s).some((a) => a.startsWith('s3:')));
    expect(s3).toHaveLength(1);
    expect(acts(s3[0]).sort()).toEqual(['s3:GetObject', 's3:PutObject']);
    expect(flatten(s3[0].Resource)).toContain('/quarantine/*');
    expect(flatten(s3[0].Resource)).toContain(`mopm-${stage}-channel-${DUMMY_ACCOUNT}`);
    const q = statements().filter((s) => acts(s).some((a) => a.startsWith('sqs:')));
    expect(q).toHaveLength(1);
    expect(acts(q[0])).toEqual(['sqs:SendMessage']);
    expect(flatten(q[0].Resource)).toContain(`mopm-${stage}-validate.fifo`);
    expect(flatten(q[0].Resource)).not.toContain('index');
  });

  test('custom domain with a DNS-validated certificate', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::DomainName', { DomainName: host });
    t.hasResourceProperties('AWS::CertificateManager::Certificate', { DomainName: host, ValidationMethod: 'DNS' });
    t.hasResourceProperties('AWS::Route53::RecordSet', Match.objectLike({ Name: `${host}.`, Type: 'A' }));
  });

  test('CORS allows exactly this stage\'s own site origin, over https, and no credentials', () => {
    const own = `https://${stageConfig(stage).siteDomain}`;
    const apis = Object.values(t.findResources('AWS::ApiGatewayV2::Api')) as any[];
    expect(apis).toHaveLength(1);
    const cors = apis[0].Properties.CorsConfiguration;
    expect(cors.AllowOrigins).toEqual([own]);
    expect(own).toBe(stage === 'prod' ? 'https://mopm.dev' : `https://${stage}.mopm.dev`);
    expect(JSON.stringify(cors)).not.toContain('*');
    expect(cors.AllowCredentials).toBeUndefined();
  });

  test('CORS methods are GET, HEAD and OPTIONS only; max-age is bounded; only the request id is exposed', () => {
    const cors = (Object.values(t.findResources('AWS::ApiGatewayV2::Api')) as any[])[0].Properties.CorsConfiguration;
    expect([...cors.AllowMethods].sort()).toEqual(['GET', 'HEAD', 'OPTIONS']);
    expect(cors.MaxAge).toBe(3600);
    expect(cors.ExposeHeaders).toEqual(['x-mopm-request-id']);
    expect(cors.AllowHeaders).toBeUndefined();
  });

  test('log group has bounded retention', () => {
    t.hasResourceProperties('AWS::Logs::LogGroup', { RetentionInDays: 30 });
  });
});

test('a missing handler bundle stops the synth with the fix in the message', () => {
  expect(
    () =>
      new ApiStack(new App(), 'x', {
        env: { account: '1'.repeat(12), region: 'us-east-1' },
        config: stageConfig('beta', 'Z0DUMMYZONE'),
        version: 'v',
        commit: 'c',
        handlerDir: '/nonexistent/handler',
      }),
  ).toThrow(/npm run build/);
});

test('no stage allows another stage\'s origin (the three origin lists are pairwise disjoint)', () => {
  const origins = STAGES.map((st) => {
    const api = tpl(st).api;
    return (Object.values(api.findResources('AWS::ApiGatewayV2::Api')) as any[])[0].Properties.CorsConfiguration.AllowOrigins as string[];
  });
  const all = origins.flat();
  expect(new Set(all).size).toBe(all.length);
  expect(all.sort()).toEqual(['https://beta.mopm.dev', 'https://gamma.mopm.dev', 'https://mopm.dev']);
});
