import * as fs from 'fs';
import * as path from 'path';
import { App, Stack } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES, Stage, stageConfig } from '../lib/config';
import { RustFunction } from '../lib/rust-function';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, RUST_ZIP_STUB_DIR, build, cfnFlat } from './util';

const A = DUMMY_ACCOUNT;
// The grants the function's own tests run under (service/lambda/fn_web_login/tests/fixtures/role_grants.json).
const GRANTS: Record<string, { actions: string[] }> = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, '../../../lambda/fn_web_login/tests/fixtures/role_grants.json'), 'utf8'),
);

type Statement = { Sid?: string; Effect: string; Action: string | string[]; Resource: string | string[]; Condition?: unknown };

/** Every IAM policy statement of the template (managed policies and inline role policies), by the logical id of the role it is attached to. */
function statementsByRole(t: Template): Record<string, Statement[]> {
  const out: Record<string, Statement[]> = {};
  const add = (role: string, doc: any) => {
    for (const s of ([] as any[]).concat(doc.Statement)) {
      out[role] = (out[role] ?? []).concat({ ...s, Resource: ([] as any[]).concat(s.Resource).map(cfnFlat) });
    }
  };
  for (const p of Object.values(t.findResources('AWS::IAM::Policy')) as any[]) {
    for (const r of p.Properties.Roles) add(r.Ref, p.Properties.PolicyDocument);
  }
  for (const [id, r] of Object.entries(t.findResources('AWS::IAM::Role')) as Array<[string, any]>) {
    for (const p of r.Properties.Policies ?? []) add(id, p.PolicyDocument);
  }
  return out;
}

/** The Lambda function (by its name or logical id) each role belongs to. */
function functionOfRole(t: Template): Record<string, { name: string; runtime: string }> {
  const out: Record<string, { name: string; runtime: string }> = {};
  for (const [id, f] of Object.entries(t.findResources('AWS::Lambda::Function')) as Array<[string, any]>) {
    const role = f.Properties.Role?.['Fn::GetAtt']?.[0];
    if (role) out[role] = { name: f.Properties.FunctionName ?? id, runtime: f.Properties.Runtime };
  }
  return out;
}

/**
 * The roles whose policies allow reading the secret `secretName`: a statement that allows GetSecretValue (or secretsmanager:* or
 * *) on that secret's ARN pattern or on everything. Each is reported as the name of the function that runs as it.
 */
function readersOfSecret(t: Template, secretName: string): string[] {
  const fns = functionOfRole(t);
  const readers: string[] = [];
  for (const [role, statements] of Object.entries(statementsByRole(t))) {
    const reads = statements.some((s) => {
      if (s.Effect !== 'Allow') return false;
      const actions = ([] as string[]).concat(s.Action);
      const grants = actions.some((a) => a === '*' || a === 'secretsmanager:*' || a === 'secretsmanager:GetSecretValue');
      const resources = ([] as string[]).concat(s.Resource);
      return grants && resources.some((r) => r === '*' || r.includes(`:secret:${secretName}-`));
    });
    if (reads) readers.push(fns[role]?.name ?? role);
  }
  return readers.sort();
}

describe.each(STAGES)('the web-login function on %s', (stage) => {
  const t = Template.fromStack(build(stage, { rustZipDir: RUST_ZIP_STUB_DIR }).api);
  const name = `mopm-${stage}-web-login`;
  const fnEntry = () => Object.entries(t.findResources('AWS::Lambda::Function')).find(([, f]: [string, any]) => f.Properties.FunctionName === name)!;
  const roleId = () => (fnEntry()[1] as any).Properties.Role['Fn::GetAtt'][0] as string;
  const table = (n: string) => `arn:aws:dynamodb:us-east-1:${A}:table/mopm-${stage}-${n}`;

  test('serves GET /api/v2/auth/web/start and /callback as a provided.al2023 x86_64 function with handler bootstrap', () => {
    t.hasResourceProperties('AWS::Lambda::Function', { FunctionName: name, Runtime: 'provided.al2023', Architectures: ['x86_64'], Handler: 'bootstrap' });
    const [fnId] = fnEntry();
    const integrations = Object.entries(t.findResources('AWS::ApiGatewayV2::Integration')).filter(
      ([, i]: [string, any]) => i.Properties.IntegrationUri?.['Fn::GetAtt']?.[0] === fnId,
    );
    expect(integrations).toHaveLength(1);
    const routes = Object.values(t.findResources('AWS::ApiGatewayV2::Route')) as any[];
    const routed = routes.filter((r) => JSON.stringify(r.Properties.Target).includes(integrations[0]![0])).map((r) => r.Properties.RouteKey);
    expect(routed.sort()).toEqual(['GET /api/v2/auth/web/callback', 'GET /api/v2/auth/web/start']);
  });

  test('its role holds exactly the DynamoDB grants of role_grants.json, and the config read is limited to the stage_settings item', () => {
    const statements = statementsByRole(t)[roleId()]!;
    const dynamo = statements.filter((s) => ([] as string[]).concat(s.Action).every((a) => a.startsWith('dynamodb:')));
    const byTable: Record<string, string[]> = {};
    for (const s of dynamo) {
      expect(s.Effect).toBe('Allow');
      const resources = ([] as string[]).concat(s.Resource);
      expect(resources).toHaveLength(1);
      const tbl = resources[0]!.replace(`arn:aws:dynamodb:us-east-1:${A}:table/mopm-${stage}-`, '');
      expect(byTable[tbl]).toBeUndefined();
      byTable[tbl] = ([] as string[]).concat(s.Action).sort();
    }
    expect(byTable).toEqual(Object.fromEntries(Object.entries(GRANTS).map(([k, v]) => [k, [...v.actions].sort()])));
    const config = dynamo.find((s) => s.Resource.toString() === table('config'))!;
    expect(config.Condition).toEqual({ 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['stage_settings'] } });
    expect(dynamo.filter((s) => s.Condition !== undefined)).toEqual([config]);
  });

  test('its role has no DeleteItem, Query, Scan, index grant, wildcard action or wildcard resource', () => {
    const statements = statementsByRole(t)[roleId()]!;
    const actions = statements.flatMap((s) => ([] as string[]).concat(s.Action));
    expect(actions.filter((a) => /DeleteItem|Query|Scan|\*/.test(a))).toEqual([]);
    const resources = statements.flatMap((s) => ([] as string[]).concat(s.Resource));
    expect(resources.filter((r) => r.includes('/index/') || r.includes('*'))).toEqual([]);
  });

  test('its secrets statement is GetSecretValue on the OAuth app secret and the edge-origin secret and nothing else', () => {
    const s = statementsByRole(t)[roleId()]!.filter((x) => ([] as string[]).concat(x.Action).some((a) => a.startsWith('secretsmanager:')));
    expect(s).toEqual([
      {
        Sid: 'ReadSecrets',
        Effect: 'Allow',
        Action: 'secretsmanager:GetSecretValue',
        Resource: [
          `arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/github-oauth-??????`,
          `arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/edge-origin-??????`,
        ],
      },
    ]);
  });

  test('only the web-login role and the API handler (the device login) can read the OAuth secret', () => {
    const readers = readersOfSecret(t, `mopm/${stage}/github-oauth`);
    const handlers = Object.entries(t.findResources('AWS::Lambda::Function')).filter(
      ([, f]: [string, any]) => f.Properties.Runtime === 'nodejs22.x' && f.Properties.Environment?.Variables?.MOPM_OAUTH_SECRET_NAME,
    );
    expect(handlers).toHaveLength(1);
    const handlerName = handlers[0]![0];
    expect(readers).toEqual([handlerName, name].sort());
    expect(readers.filter((r) => r.includes('web-login'))).toEqual([name]);
  });
});

describe('the OAuth secret reader check', () => {
  const second = (secrets: string[]) => {
    const stack = new Stack(new App(), 'Harness', { env: { account: A, region: 'us-east-1' } });
    const api = new apigw.HttpApi(stack, 'Api');
    for (const [id, fn] of [['A', 'fixture-a'], ['B', 'fixture-b']] as const) {
      new RustFunction(stack, id, {
        config: stageConfig('beta', DUMMY_ZONE_ID, {}),
        name: fn,
        zipDir: RUST_ZIP_STUB_DIR,
        api,
        routes: [{ method: apigw.HttpMethod.GET, path: `/api/v2/${fn}` }],
        tables: [],
        secrets: id === 'B' ? secrets : ['mopm/beta/github-oauth'],
      });
    }
    return Template.fromStack(stack);
  };

  test('reports a second Rust function that is granted the OAuth secret', () => {
    expect(readersOfSecret(second(['mopm/beta/github-oauth']), 'mopm/beta/github-oauth')).toEqual(['mopm-beta-fixture-a', 'mopm-beta-fixture-b']);
  });

  test('does not report a function granted only another secret', () => {
    expect(readersOfSecret(second(['mopm/beta/edge-origin']), 'mopm/beta/github-oauth')).toEqual(['mopm-beta-fixture-a']);
  });
});

test.each(STAGES)('with rustZipDir unset, %s has no web-login function, route or role', (stage: Stage) => {
  const t = Template.fromStack(build(stage).api);
  const names = Object.values(t.findResources('AWS::Lambda::Function')).map((f: any) => f.Properties.FunctionName);
  expect(names).not.toContain(`mopm-${stage}-web-login`);
  const routes = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey);
  expect(routes.filter((r) => r.includes('/auth/web/'))).toEqual([]);
  expect(JSON.stringify(t.toJSON())).not.toContain('web-login');
});
