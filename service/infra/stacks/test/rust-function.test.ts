import { App, Stack } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES, Stage, stageConfig } from '../lib/config';
import { API_GATEWAY_INTEGRATION_SECONDS } from '../lib/api-stack';
import { RUST_FUNCTION_TIMEOUT_SECONDS, RustFunction, RustFunctionProps } from '../lib/rust-function';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, RUST_ZIP_STUB_DIR, cfnFlat } from './util';

const A = DUMMY_ACCOUNT;

/** A stack with one HTTP API and the given Rust functions on it (props default to a `fixture-a` with one route and no grants). */
function synth(stage: Stage, fns: Array<Partial<RustFunctionProps> & { id: string }>): Template {
  const app = new App();
  const stack = new Stack(app, 'Harness', { env: { account: A, region: 'us-east-1' } });
  const api = new apigw.HttpApi(stack, 'Api');
  for (const { id, ...p } of fns) {
    new RustFunction(stack, id, {
      config: stageConfig(stage, DUMMY_ZONE_ID, {}),
      name: 'fixture-a',
      zipDir: RUST_ZIP_STUB_DIR,
      api,
      routes: [{ method: apigw.HttpMethod.GET, path: '/api/v2/fixture' }],
      tables: [],
      secrets: [],
      ...p,
    });
  }
  return Template.fromStack(stack);
}

/** Every statement of the role policies, with its ARNs flattened, keyed by the role's logical id. */
function rolePolicies(t: Template): Record<string, any[]> {
  const out: Record<string, any[]> = {};
  for (const p of Object.values(t.findResources('AWS::IAM::Policy')) as any[]) {
    for (const r of p.Properties.Roles) {
      out[r.Ref] = (out[r.Ref] ?? []).concat(
        p.Properties.PolicyDocument.Statement.map((s: any) => ({ ...s, Resource: ([] as any[]).concat(s.Resource).map(cfnFlat) })),
      );
    }
  }
  return out;
}

const roleId = (t: Template) => Object.keys(t.findResources('AWS::IAM::Role'))[0]!;
const logsId = (t: Template) => Object.keys(t.findResources('AWS::Logs::LogGroup'))[0]!;

describe.each(STAGES)('RustFunction on %s', (stage) => {
  const t = synth(stage, [
    {
      id: 'Fixture',
      routes: [
        { method: apigw.HttpMethod.GET, path: '/api/v2/fixture' },
        { method: apigw.HttpMethod.POST, path: '/api/v2/fixture/act' },
      ],
      tables: [
        { table: 'tokens', actions: ['dynamodb:GetItem', 'dynamodb:UpdateItem'] },
        { table: 'web_logins', actions: ['dynamodb:PutItem'], indexes: ['by_x'] },
      ],
      secrets: [`mopm/${stage}/github-oauth`],
    },
  ]);

  test('provided.al2023 on x86_64, handler bootstrap, named mopm-<stage>-<function>, under the gateway wait', () => {
    t.resourceCountIs('AWS::Lambda::Function', 1);
    t.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: `mopm-${stage}-fixture-a`,
      Runtime: 'provided.al2023',
      Architectures: ['x86_64'],
      Handler: 'bootstrap',
      MemorySize: 256,
      Timeout: RUST_FUNCTION_TIMEOUT_SECONDS,
    });
    expect(RUST_FUNCTION_TIMEOUT_SECONDS).toBeLessThan(API_GATEWAY_INTEGRATION_SECONDS);
  });

  test('sets no environment variable: the function reads its stage from AWS_LAMBDA_FUNCTION_NAME', () => {
    const fn = Object.values(t.findResources('AWS::Lambda::Function'))[0] as any;
    expect(fn.Properties.Environment).toBeUndefined();
  });

  test('the role holds exactly the passed grants, the stage_settings read and its own log writes (golden), and no managed policy', () => {
    const role = Object.values(t.findResources('AWS::IAM::Role'))[0] as any;
    expect(role.Properties.ManagedPolicyArns).toBeUndefined();
    expect(role.Properties.Policies).toBeUndefined();
    expect(role.Properties.AssumeRolePolicyDocument.Statement).toEqual([
      { Action: 'sts:AssumeRole', Effect: 'Allow', Principal: { Service: 'lambda.amazonaws.com' } },
    ]);
    const table = (n: string) => `arn:aws:dynamodb:us-east-1:${A}:table/mopm-${stage}-${n}`;
    expect(rolePolicies(t)).toEqual({
      [roleId(t)]: [
        { Sid: 'WriteOwnLogs', Effect: 'Allow', Action: ['logs:CreateLogStream', 'logs:PutLogEvents'], Resource: [`<${logsId(t)}.Arn>`] },
        {
          Sid: 'ReadStageSettings',
          Effect: 'Allow',
          Action: 'dynamodb:GetItem',
          Resource: [table('config')],
          Condition: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['stage_settings'] } },
        },
        { Sid: 'TableTokens', Effect: 'Allow', Action: ['dynamodb:GetItem', 'dynamodb:UpdateItem'], Resource: [table('tokens')] },
        { Sid: 'TableWebLogins', Effect: 'Allow', Action: 'dynamodb:PutItem', Resource: [table('web_logins'), `${table('web_logins')}/index/by_x`] },
        {
          Sid: 'ReadSecrets',
          Effect: 'Allow',
          Action: 'secretsmanager:GetSecretValue',
          Resource: [`arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/github-oauth-??????`],
        },
      ],
    });
  });

  test('the function runs as that role and logs to its own group, kept a month, retained on prod only', () => {
    const fn = Object.values(t.findResources('AWS::Lambda::Function'))[0] as any;
    expect(fn.Properties.Role).toEqual({ 'Fn::GetAtt': [roleId(t), 'Arn'] });
    expect(fn.Properties.LoggingConfig).toEqual({ LogGroup: { Ref: logsId(t) } });
    const lg = t.findResources('AWS::Logs::LogGroup')[logsId(t)] as any;
    expect(lg.Properties.RetentionInDays).toBe(30);
    expect(lg.DeletionPolicy).toBe(stage === 'prod' ? 'Retain' : 'Delete');
  });

  test('each passed route reaches the function through one integration and one invoke permission', () => {
    const routes = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey).sort();
    expect(routes).toEqual(['GET /api/v2/fixture', 'POST /api/v2/fixture/act']);
    const integrations = Object.values(t.findResources('AWS::ApiGatewayV2::Integration')) as any[];
    expect(integrations).toHaveLength(1);
    const fnId = Object.keys(t.findResources('AWS::Lambda::Function'))[0]!;
    expect(integrations[0].Properties.IntegrationUri).toEqual({ 'Fn::GetAtt': [fnId, 'Arn'] });
    const perms = Object.values(t.findResources('AWS::Lambda::Permission')) as any[];
    expect(perms).toHaveLength(1);
    expect(perms[0].Properties.FunctionName).toEqual({ 'Fn::GetAtt': [fnId, 'Arn'] });
  });
});

describe('RustFunction boundaries', () => {
  test('without secrets the role has no secrets statement; without tables only the stage_settings read and its logs', () => {
    const t = synth('beta', [{ id: 'Fixture' }]);
    expect(Object.values(rolePolicies(t))[0]!.map((s) => s.Sid)).toEqual(['WriteOwnLogs', 'ReadStageSettings']);
  });

  test('two functions get two roles, each with only its own grants', () => {
    const t = synth('beta', [
      { id: 'A', tables: [{ table: 'tokens', actions: ['dynamodb:GetItem'] }], routes: [{ method: apigw.HttpMethod.GET, path: '/a' }] },
      { id: 'B', name: 'fixture-b', secrets: ['mopm/beta/e2b'], routes: [{ method: apigw.HttpMethod.GET, path: '/b' }] },
    ]);
    t.resourceCountIs('AWS::IAM::Role', 2);
    const sids = Object.values(rolePolicies(t)).map((ss) => ss.map((s) => s.Sid));
    expect(sids.sort()).toEqual([
      ['WriteOwnLogs', 'ReadStageSettings', 'ReadSecrets'],
      ['WriteOwnLogs', 'ReadStageSettings', 'TableTokens'],
    ]);
    const names = Object.values(t.findResources('AWS::Lambda::Function')).map((f: any) => f.Properties.FunctionName).sort();
    expect(names).toEqual(['mopm-beta-fixture-a', 'mopm-beta-fixture-b']);
  });

  test('a missing zip is refused, naming the path', () => {
    expect(() => synth('beta', [{ id: 'X', name: 'absent' }])).toThrow(
      `the Rust function zip is missing at ${RUST_ZIP_STUB_DIR}/absent.zip; build the function's zip (lambda_zip) first`,
    );
  });

  test('a function with no route is refused', () => {
    expect(() => synth('beta', [{ id: 'X', routes: [] }])).toThrow("the Rust function 'fixture-a' has no route");
  });

  test.each(['', 'Web-login', 'web_login', 'web-', '-web', 'web--login', '../web', '1web'])('the name %p is refused', (name) => {
    expect(() => synth('beta', [{ id: 'X', name }])).toThrow(`a Rust function name is lower-case words joined by '-'; got '${name}'`);
  });
});
