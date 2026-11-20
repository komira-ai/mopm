import * as fs from 'fs';
import * as path from 'path';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { RUST_ZIP_STUB_DIR, DUMMY_ACCOUNT, build, cfnFlat } from './util';

const A = DUMMY_ACCOUNT;
/** The grants table of the design's section 5, the same file the Rust tests' fake DynamoDB enforces. */
const GRANTS_FILE = path.resolve(__dirname, '../../../lambda/testing/tests/fixtures/web_session_grants.json');
const ROUTES = ['GET /api/v2/auth/web/session', 'POST /api/v2/auth/web/logout'];

type Json = Record<string, any>;
const resources = (t: Template, type: string) => t.findResources(type) as Json;
const flat = (s: Json): Json => ({ ...s, Resource: ([] as any[]).concat(s.Resource).map(cfnFlat) });

describe.each(STAGES)('the web-session function on %s', (stage) => {
  const t = Template.fromStack(build(stage, { rustZipDir: RUST_ZIP_STUB_DIR }).api);
  const fns = Object.entries(resources(t, 'AWS::Lambda::Function')).filter(([, f]) => f.Properties.FunctionName === `mopm-${stage}-web-session`);
  const [fnId, fn] = fns[0]!;
  const roleId = fn.Properties.Role['Fn::GetAtt'][0] as string;
  const policies = Object.values(resources(t, 'AWS::IAM::Policy')).filter((p) => p.Properties.Roles.some((r: Json) => r.Ref === roleId));
  const statements = policies.flatMap((p) => p.Properties.PolicyDocument.Statement as Json[]).map(flat);
  const table = (n: string) => `arn:aws:dynamodb:us-east-1:${A}:table/mopm-${stage}-${n}`;
  const logsId = Object.keys(resources(t, 'AWS::Logs::LogGroup')).find((id) => id.startsWith('WebSession'))!;

  test('is one provided.al2023 function on x86_64, handler bootstrap, named mopm-<stage>-web-session, with no environment', () => {
    expect(fns).toHaveLength(1);
    expect(fn.Properties).toMatchObject({
      FunctionName: `mopm-${stage}-web-session`,
      Runtime: 'provided.al2023',
      Architectures: ['x86_64'],
      Handler: 'bootstrap',
    });
    expect(fn.Properties.Environment).toBeUndefined();
  });

  test('its role holds exactly the log writes, the stage_settings read, tokens, users and the edge-origin secret', () => {
    expect(statements).toEqual([
      { Sid: 'WriteOwnLogs', Effect: 'Allow', Action: ['logs:CreateLogStream', 'logs:PutLogEvents'], Resource: [`<${logsId}.Arn>`] },
      {
        Sid: 'ReadStageSettings',
        Effect: 'Allow',
        Action: 'dynamodb:GetItem',
        Resource: [table('config')],
        Condition: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['stage_settings'] } },
      },
      { Sid: 'TableTokens', Effect: 'Allow', Action: ['dynamodb:GetItem', 'dynamodb:UpdateItem'], Resource: [table('tokens')] },
      { Sid: 'TableUsers', Effect: 'Allow', Action: 'dynamodb:GetItem', Resource: [table('users')] },
      {
        Sid: 'ReadSecrets',
        Effect: 'Allow',
        Action: 'secretsmanager:GetSecretValue',
        Resource: [`arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/edge-origin-??????`],
      },
    ]);
  });

  test("the role's per-table actions equal the grants table the Rust tests' fake DynamoDB enforces", () => {
    const derived: Record<string, string[]> = {};
    for (const s of statements.filter((x) => /^(ReadStageSettings|Table)/.test(x.Sid))) {
      for (const arn of s.Resource as string[]) {
        derived[arn.split(`table/mopm-${stage}-`)[1]!] = [...([] as string[]).concat(s.Action)].sort();
      }
    }
    const file: Record<string, { actions: string[] }> = JSON.parse(fs.readFileSync(GRANTS_FILE, 'utf8'));
    const expected = Object.fromEntries(Object.entries(file).map(([k, v]) => [k, [...v.actions].sort()]));
    expect(derived).toEqual(expected);
  });

  test('the two routes integrate with this function and no other route does', () => {
    const routes = Object.values(resources(t, 'AWS::ApiGatewayV2::Route'));
    const integrations = resources(t, 'AWS::ApiGatewayV2::Integration');
    const toFn = routes
      .filter((r) => {
        const id = r.Properties.Target['Fn::Join'][1].find((x: any) => x?.Ref)?.Ref as string;
        return integrations[id].Properties.IntegrationUri['Fn::GetAtt']?.[0] === fnId;
      })
      .map((r) => r.Properties.RouteKey)
      .sort();
    expect(toFn).toEqual([...ROUTES].sort());
    expect(Object.values(resources(t, 'AWS::Lambda::Permission')).filter((p) => p.Properties.FunctionName['Fn::GetAtt']?.[0] === fnId)).toHaveLength(1);
  });

  test('the TypeScript handler has neither route', () => {
    const tsIntegrationIds = Object.entries(resources(t, 'AWS::ApiGatewayV2::Integration'))
      .filter(([, i]) => i.Properties.IntegrationUri['Fn::GetAtt']?.[0] !== fnId)
      .map(([id]) => id);
    const tsRoutes = Object.values(resources(t, 'AWS::ApiGatewayV2::Route'))
      .filter((r) => tsIntegrationIds.includes(r.Properties.Target['Fn::Join'][1].find((x: any) => x?.Ref)?.Ref))
      .map((r) => r.Properties.RouteKey);
    for (const k of ROUTES) expect(tsRoutes).not.toContain(k);
  });

  test("no other function's role or policy changes: the IAM resources of the API stack are those of the default build plus the Rust functions' and the stage_settings writer's", () => {
    const off = Template.fromStack(build(stage).api).toJSON().Resources as Json;
    const on = Template.fromStack(build(stage, { rustZipDir: RUST_ZIP_STUB_DIR }).api).toJSON().Resources as Json;
    const iam = (rs: Json) => Object.fromEntries(Object.entries(rs).filter(([, r]) => r.Type === 'AWS::IAM::Role' || r.Type === 'AWS::IAM::Policy'));
    const a = iam(off);
    const b = iam(on);
    for (const [id, r] of Object.entries(a)) expect(b[id]).toEqual(r);
    // The web-login function's own role is held by web-login.test.ts.
    const added = Object.entries(b).filter(([id]) => !(id in a) && !id.startsWith('WebSession') && !id.startsWith('WebLogin'));
    // What remains is the stage_settings writer's: its policy (PutStageSettings only) and the role of the function behind it.
    expect(added.map(([, r]) => r.Type).sort()).toEqual(['AWS::IAM::Policy', 'AWS::IAM::Role']);
    const writer = added.find(([, r]) => r.Type === 'AWS::IAM::Policy')![1];
    expect(writer.Properties.PolicyDocument.Statement.map((s: Json) => s.Sid)).toEqual(['PutStageSettings']);
  });

  test('the other stacks are the same with and without the Rust functions', () => {
    const off = build(stage);
    const on = build(stage, { rustZipDir: RUST_ZIP_STUB_DIR });
    for (const k of ['channel', 'data', 'publish', 'site'] as const) {
      expect(Template.fromStack(on[k]).toJSON()).toEqual(Template.fromStack(off[k]).toJSON());
    }
  });
});
