import * as fs from 'fs';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Match } from 'aws-cdk-lib/assertions';
import { ApiStack, AUTH_GRANTS, AUTH_ROUTES, READ_ACTIONS, READ_INDEXES, READ_ROUTES, READ_TABLES } from '../lib/api-stack';
import { STAGES, stageConfig, tableName } from '../lib/config';
import { DUMMY_ACCOUNT, tpl } from './util';

const acts = (s: any): string[] => ([] as string[]).concat(s.Action);
const flat = (v: any): string => (typeof v === 'string' ? v : JSON.stringify(v));

/**
 * Everything the handler's role may do, checked as rules. Allowed: GetItem/Query on the four read tables; per AUTH_GRANTS
 * on the four auth tables (indexes by name only); GetSecretValue on the one OAuth secret. Returns what breaks them.
 */
function policyViolations(stage: string, statements: any[]): string[] {
  const out: string[] = [];
  const secret = `secret:mopm/${stage}/github-oauth-??????`;
  for (const s of statements) {
    if (s.Effect !== 'Allow') continue;
    const res = ([] as any[]).concat(s.Resource).map(flat);
    for (const a of acts(s)) {
      if (a === '*' || a.endsWith(':*')) out.push(`wildcard action ${a}`);
      if (a.startsWith('secretsmanager:')) {
        if (a !== 'secretsmanager:GetSecretValue') out.push(`secret action ${a}`);
        for (const r of res) if (!r.endsWith(secret) && !r.includes(`${secret}"`)) out.push(`secret resource ${r}`);
      }
      if (!a.startsWith('dynamodb:')) continue;
      for (const r of res) {
        const m = /table\/mopm-[a-z]+-([a-z_]+)(\/index\/([^"]+))?/.exec(r);
        if (!m) {
          out.push(`${a} on ${r}`);
          continue;
        }
        const table = m[1]!;
        const index = m[3];
        const grant = AUTH_GRANTS[table];
        const readable = (READ_TABLES as readonly string[]).includes(table);
        if (!readable && !grant) out.push(`${a} on unlisted table ${table}`);
        if (readable && !READ_ACTIONS.includes(a) && !(grant && grant.actions.includes(a))) out.push(`${a} on registry table ${table}`);
        if (grant && !readable && !grant.actions.includes(a)) out.push(`${a} on ${table}`);
        if (index !== undefined && !readable && !(grant?.indexes ?? []).includes(index)) out.push(`${a} on index ${table}/${index}`);
      }
    }
  }
  return out;
}

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

  test('HTTP API serves the read operations and the auth operations, with the default endpoint disabled', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Api', { ProtocolType: 'HTTP', DisableExecuteApiEndpoint: true });
    const keys = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey as string);
    expect(keys.sort()).toEqual(
      [
        ...READ_ROUTES.map((r) => `GET ${r}`),
        'POST /api/v1/auth/device',
        'POST /api/v1/auth/device/poll',
        'POST /api/v1/auth/oidc/exchange',
        'POST /api/v1/me/tokens',
        'GET /api/v1/me/tokens',
        'DELETE /api/v1/me/tokens/{token_id}',
      ].sort(),
    );
    expect(AUTH_ROUTES).toHaveLength(6);
    // The write operations of the registry (claim, publish, yank) are not routed yet.
    expect(keys.some((k) => /\/(claim|publish|files)/.test(k))).toBe(false);
  });

  // Every policy statement the handler's role gets. The role is the only one in the stack with a policy.
  const statements = () =>
    Object.values(t.findResources('AWS::IAM::Policy')).flatMap((r: any) => r.Properties.PolicyDocument.Statement as any[]);
  const flatten = (v: any): string => (typeof v === 'string' ? v : JSON.stringify(v));

  test('registry tables stay read-only: one statement, GetItem and Query, on exactly the four tables', () => {
    const st = statements().filter((s) => s.Sid === 'ReadRegistryTables');
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

  test('the one index the read statement may Query is named exactly; no index wildcard', () => {
    expect(READ_INDEXES).toEqual({ packages: ['by_search_bucket'] });
    const st = statements().filter((s) => s.Sid === 'ReadRegistryTables');
    const resources = JSON.stringify(st[0].Resource);
    expect(resources).toContain(`${tableName(stage, 'packages')}/index/by_search_bucket`);
    expect(resources).not.toContain('index/*');
    expect(resources).not.toContain('by_github_id'); // the owners index is not read by the read API
    expect((resources.match(/\/index\//g) ?? []).length).toBe(1);
  });

  test('each auth table has one statement with exactly its actions; indexes are named, never index/*', () => {
    const st = statements().filter((s) => /^Auth/.test(s.Sid ?? ''));
    expect(st).toHaveLength(Object.keys(AUTH_GRANTS).length);
    for (const [table, g] of Object.entries(AUTH_GRANTS)) {
      const match = st.filter((s) => flatten(s.Resource).includes(`table/${tableName(stage, table)}`));
      expect(match).toHaveLength(1);
      expect(acts(match[0]).sort()).toEqual([...g.actions].sort());
      const res = ([] as any[]).concat(match[0].Resource).map(flatten);
      expect(res).toHaveLength(1 + (g.indexes ?? []).length);
      for (const i of g.indexes ?? []) expect(res.some((r) => r.includes(`/index/${i}`))).toBe(true);
      expect(flatten(match[0].Resource)).not.toContain('index/*');
    }
    expect(AUTH_GRANTS.tokens!.indexes).toEqual(['by_github_id']);
  });

  test('the role may read exactly one secret, the stage OAuth app, and nothing else in Secrets Manager', () => {
    const st = statements().filter((s) => acts(s).some((a) => a.startsWith('secretsmanager:')));
    expect(st).toHaveLength(1);
    expect(acts(st[0])).toEqual(['secretsmanager:GetSecretValue']);
    const res = flatten(st[0].Resource);
    expect(res).toContain(`secret:mopm/${stage}/github-oauth-??????`);
    expect(res).not.toContain('"*"');
    expect(([] as any[]).concat(st[0].Resource)).toHaveLength(1);
    t.hasResourceProperties('AWS::Lambda::Function', {
      Environment: { Variables: Match.objectLike({ MOPM_OAUTH_SECRET_NAME: `mopm/${stage}/github-oauth`, MOPM_REQUIRE_2FA: 'true' }) },
    });
  });

  test('no statement grants delete, scan, batch or transact writes, or a wildcard action, on any table', () => {
    expect(policyViolations(stage, statements())).toEqual([]);
  });

  // Can-fail proof: the checker above flags each planted defect, so a clean result means something.
  test('the policy checker goes red on planted defects', () => {
    const base = statements();
    const withExtra = (extra: any) => [...base, { Effect: 'Allow', ...extra }];
    const tbl = (name: string) => `arn:aws:dynamodb:us-east-1:${DUMMY_ACCOUNT}:table/${tableName(stage, name)}`;
    const mutants: Record<string, any[]> = {
      'DeleteItem on tokens': withExtra({ Action: 'dynamodb:DeleteItem', Resource: tbl('tokens') }),
      'Scan on users': withExtra({ Action: 'dynamodb:Scan', Resource: tbl('users') }),
      'PutItem on packages (registry write)': withExtra({ Action: 'dynamodb:PutItem', Resource: tbl('packages') }),
      'UpdateItem on audit': withExtra({ Action: 'dynamodb:UpdateItem', Resource: tbl('audit') }),
      'wildcard dynamodb action': withExtra({ Action: 'dynamodb:*', Resource: tbl('tokens') }),
      'a table that is not in either list': withExtra({ Action: 'dynamodb:GetItem', Resource: tbl('uploads') }),
      'Query on every tokens index': withExtra({ Action: 'dynamodb:Query', Resource: `${tbl('tokens')}/index/*` }),
      'secret read widened to every secret': withExtra({ Action: 'secretsmanager:GetSecretValue', Resource: '*' }),
      'a second secret': withExtra({ Action: 'secretsmanager:GetSecretValue', Resource: `arn:aws:secretsmanager:us-east-1:${DUMMY_ACCOUNT}:secret:mopm/${stage}/e2e/test-identity-??????` }),
      'secret write': withExtra({ Action: 'secretsmanager:PutSecretValue', Resource: `arn:aws:secretsmanager:us-east-1:${DUMMY_ACCOUNT}:secret:mopm/${stage}/github-oauth-??????` }),
    };
    expect(policyViolations(stage, base)).toEqual([]);
    for (const [name, st] of Object.entries(mutants)) {
      expect({ name, caught: policyViolations(stage, st).length > 0 }).toEqual({ name, caught: true });
    }
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

// The adapter tests in service/api run under exactly these grants (test/fixtures/lambda-auth-grants.json, enforced by
// their fake DynamoDB client). If the adapter needs an action the role lacks, those tests fail; if this list and that
// file drift, this one fails. Both ends must change in the same pull request.
test('AUTH_GRANTS equals the grants the adapter tests are enforced under', () => {
  const file = path.resolve(__dirname, '../../../api/test/fixtures/lambda-auth-grants.json');
  expect(AUTH_GRANTS).toEqual(JSON.parse(fs.readFileSync(file, 'utf8')));
});

test('the pin goes red when the role gains an action the adapter tests do not know', () => {
  const file = path.resolve(__dirname, '../../../api/test/fixtures/lambda-auth-grants.json');
  const widened = { ...AUTH_GRANTS, users: { actions: [...AUTH_GRANTS.users!.actions, 'dynamodb:DeleteItem'] } };
  expect(widened).not.toEqual(JSON.parse(fs.readFileSync(file, 'utf8')));
});
