import { App } from 'aws-cdk-lib';
import { Match } from 'aws-cdk-lib/assertions';
import { ApiStack, READ_ACTIONS, READ_ROUTES, READ_TABLES } from '../lib/api-stack';
import { STAGES, stageConfig, tableName } from '../lib/config';
import { tpl } from './util';

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

  test('HTTP API serves the read operations only, with the default endpoint disabled', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Api', { ProtocolType: 'HTTP', DisableExecuteApiEndpoint: true });
    t.resourceCountIs('AWS::ApiGatewayV2::Route', READ_ROUTES.length);
    for (const r of READ_ROUTES) t.hasResourceProperties('AWS::ApiGatewayV2::Route', { RouteKey: `GET ${r}` });
    const keys = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey as string);
    expect(keys.every((k) => k.startsWith('GET '))).toBe(true);
    expect(keys.sort()).toEqual(
      ['GET /api/v1/health', 'GET /api/v1/packages', 'GET /api/v1/packages/{name}', 'GET /api/v1/packages/{name}/versions'].sort(),
    );
  });

  // Every policy statement the handler's role gets. The role is the only one in the stack with a policy.
  const statements = () =>
    Object.values(t.findResources('AWS::IAM::Policy')).flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[]);
  const acts = (s: any): string[] => ([] as string[]).concat(s.Action);
  const flatten = (v: any): string => (typeof v === 'string' ? v : JSON.stringify(v));

  test('the Lambda role is read-only on the registry tables: GetItem and Query, nothing else', () => {
    const st = statements().filter((s) => acts(s).some((a) => a.startsWith('dynamodb:')));
    expect(st).toHaveLength(1);
    expect(st[0].Effect).toBe('Allow');
    expect(acts(st[0]).sort()).toEqual([...READ_ACTIONS].sort());
    expect(READ_ACTIONS).toEqual(['dynamodb:GetItem', 'dynamodb:Query']);
    const resources = flatten(st[0].Resource);
    for (const table of READ_TABLES) expect(resources).toContain(tableName(stage, table));
    expect(resources).not.toContain('"*"');
    // Nothing outside the four tables (and their indexes) is named.
    const named = (resources.match(/table\/mopm-[a-z]+-[a-z_]+/g) ?? []).map((m) => m.replace(/\/index.*/, ''));
    expect([...new Set(named)].sort()).toEqual(READ_TABLES.map((x) => `table/${tableName(stage, x)}`).sort());
  });

  test('no statement anywhere grants a write, delete, scan or wildcard action', () => {
    const actions = statements().flatMap(acts);
    for (const a of actions.filter((x) => x.startsWith('dynamodb:'))) {
      expect(a).toMatch(/^dynamodb:(GetItem|Query)$/);
    }
    expect(actions.some((a) => a === '*' || a.endsWith(':*'))).toBe(false);
  });

  test('custom domain with a DNS-validated certificate', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::DomainName', { DomainName: host });
    t.hasResourceProperties('AWS::CertificateManager::Certificate', { DomainName: host, ValidationMethod: 'DNS' });
    t.hasResourceProperties('AWS::Route53::RecordSet', Match.objectLike({ Name: `${host}.`, Type: 'A' }));
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
