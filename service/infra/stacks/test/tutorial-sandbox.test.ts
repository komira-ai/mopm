import * as fs from 'fs';
import * as path from 'path';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES, Stage, stageConfig } from '../lib/config';
import { stageSettings, stageSettingsItem } from '../lib/stage-settings';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, RUST_ZIP_STUB_DIR, build, cfnFlat } from './util';

const A = DUMMY_ACCOUNT;
const GRANTS_FILE = path.resolve(__dirname, '../../../lambda/fn_tutorial_sandbox/tests/fixtures/grants.json');
const ITEM_FILE = path.join(__dirname, 'fixtures/stage-settings-item.json');

type Grants = Record<string, { actions: string[] }>;
/** The grants the function's own tests run under (service/lambda/fn_tutorial_sandbox/tests/fixtures/grants.json). */
const grants = (): Grants => JSON.parse(fs.readFileSync(GRANTS_FILE, 'utf8'));

/** The stage's stacks with the Rust functions on. */
const stacks = (stage: Stage) => build(stage, { rustZipDir: RUST_ZIP_STUB_DIR });
const apiTemplate = (stage: Stage) => Template.fromStack(stacks(stage).api);

/** cfnFlat, with a value it does not know (an import from another stack) kept as its JSON, which no secret ARN glob matches. */
const flat = (v: any): string => {
  try {
    return cfnFlat(v);
  } catch {
    return JSON.stringify(v);
  }
};

const pascal = (s: string) => s.replace(/(^|[_-])(\w)/g, (_m, _u, ch: string) => ch.toUpperCase());

/** Every statement of every role policy of a template, with its ARNs flattened, keyed by the role's logical id. */
function rolePolicies(t: Template): Record<string, any[]> {
  const out: Record<string, any[]> = {};
  for (const p of Object.values(t.findResources('AWS::IAM::Policy')) as any[]) {
    for (const r of p.Properties.Roles) {
      out[r.Ref] = (out[r.Ref] ?? []).concat(
        p.Properties.PolicyDocument.Statement.map((s: any) => ({ ...s, Resource: ([] as any[]).concat(s.Resource).map(flat) })),
      );
    }
  }
  return out;
}

/** The logical id of the tutorial-sandbox function's role in an API template. */
function sandboxRoleId(t: Template, stage: Stage): string {
  const fns = Object.values(t.findResources('AWS::Lambda::Function')) as any[];
  const fn = fns.find((f) => f.Properties.FunctionName === `mopm-${stage}-tutorial-sandbox`);
  return fn.Properties.Role['Fn::GetAtt'][0];
}

/**
 * What is wrong with the E2B secret and its policy in a stage's API template, as a list of sentences (empty: nothing). The
 * secret exists once under its name with no value and no generator; one resource policy on it, with blockPublicPolicy, holds
 * exactly one statement: Deny GetSecretValue on `*` to every principal whose ARN is not the sandbox function's role
 * (ArnNotEquals on aws:PrincipalArn, never NotPrincipal), so PutSecretValue and CloudFormation stay allowed.
 */
export function e2bSecretProblems(template: any, stage: Stage): string[] {
  const res = template.Resources as Record<string, any>;
  const ofType = (type: string) => Object.entries(res).filter(([, r]) => r.Type === type);
  const out: string[] = [];
  const secrets = ofType('AWS::SecretsManager::Secret').filter(([, r]) => r.Properties.Name === `mopm/${stage}/e2b`);
  if (secrets.length !== 1) return [`expected one secret named mopm/${stage}/e2b, found ${secrets.length}`];
  const [secretId, secret] = secrets[0]!;
  for (const k of ['SecretString', 'GenerateSecretString']) {
    if (secret.Properties[k] !== undefined) out.push(`the secret has ${k}: its value must be written by the operator, never by the stack`);
  }
  const policies = ofType('AWS::SecretsManager::ResourcePolicy').filter(([, r]) => r.Properties.SecretId?.Ref === secretId);
  if (policies.length !== 1) return [...out, `expected one resource policy on the secret, found ${policies.length}`];
  const props = policies[0]![1].Properties;
  if (props.BlockPublicPolicy !== true) out.push('blockPublicPolicy is not true');
  const statements: any[] = props.ResourcePolicy.Statement;
  if (statements.length !== 1) return [...out, `expected exactly one statement, found ${statements.length}`];
  const st = statements[0];
  if (st.NotPrincipal !== undefined) out.push('the statement uses NotPrincipal');
  if (st.Effect !== 'Deny') out.push(`the statement is ${st.Effect}, not Deny`);
  if (JSON.stringify(st.Principal) !== JSON.stringify({ AWS: '*' })) out.push('the Principal is not {"AWS":"*"}');
  if (st.Action !== 'secretsmanager:GetSecretValue') out.push('the Action is not exactly secretsmanager:GetSecretValue');
  if (st.Resource !== '*') out.push('the Resource is not "*"');
  const role = { 'Fn::GetAtt': [sandboxRoleId(Template.fromJSON(template), stage), 'Arn'] };
  if (JSON.stringify(st.Condition) !== JSON.stringify({ ArnNotEquals: { 'aws:PrincipalArn': role } })) {
    out.push('the Condition is not ArnNotEquals aws:PrincipalArn on the tutorial-sandbox function\'s role alone');
  }
  return out;
}

const clone = (v: any) => JSON.parse(JSON.stringify(v));
/** The template of `t` with the resource policy of the E2B secret changed by `f`. */
function withPolicy(t: Template, f: (props: any) => void): any {
  const json = clone(t.toJSON());
  const [, p] = Object.entries(json.Resources).find(([, r]: [string, any]) => r.Type === 'AWS::SecretsManager::ResourcePolicy') as [string, any];
  f(p.Properties);
  return json;
}

/** Whether an IAM glob (`*` and `?`) can match a concrete string. */
const globMatches = (glob: string, s: string) =>
  new RegExp(`^${glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')}$`).test(s);

describe.each(STAGES)('the tutorial-sandbox function on %s', (stage) => {
  const t = apiTemplate(stage);
  const fnId = () => Object.keys(t.findResources('AWS::Lambda::Function', { Properties: { FunctionName: `mopm-${stage}-tutorial-sandbox` } }))[0]!;

  test('is a provided.al2023 function named mopm-<stage>-tutorial-sandbox, routed from POST /api/v2/tutorial/sandbox only', () => {
    t.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: `mopm-${stage}-tutorial-sandbox`,
      Runtime: 'provided.al2023',
      Handler: 'bootstrap',
      Architectures: ['x86_64'],
    });
    const routes = (Object.values(t.findResources('AWS::ApiGatewayV2::Route')) as any[]).filter(
      (r) => JSON.stringify(r.Properties.Target).includes(`"Ref":"${integrationIdOf(t, fnId())}"`),
    );
    expect(routes.map((r) => r.Properties.RouteKey)).toEqual(['POST /api/v2/tutorial/sandbox']);
  });

  test('its role holds the shared grants (tokens and users), the stage_settings read, GetSecretValue on the edge-origin and E2B secrets, and its logs', () => {
    const g = grants();
    const table = (n: string) => `arn:aws:dynamodb:us-east-1:${A}:table/mopm-${stage}-${n}`;
    const roleId = sandboxRoleId(t, stage);
    const logs = (Object.values(t.findResources('AWS::Lambda::Function')) as any[]).find((f) => f.Properties.FunctionName === `mopm-${stage}-tutorial-sandbox`).Properties
      .LoggingConfig.LogGroup.Ref;
    const { config, ...tables } = g;
    expect(rolePolicies(t)[roleId]).toEqual([
      { Sid: 'WriteOwnLogs', Effect: 'Allow', Action: ['logs:CreateLogStream', 'logs:PutLogEvents'], Resource: [`<${logs}.Arn>`] },
      {
        Sid: 'ReadStageSettings',
        Effect: 'Allow',
        Action: config!.actions.length === 1 ? config!.actions[0] : config!.actions,
        Resource: [table('config')],
        Condition: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['stage_settings'] } },
      },
      ...Object.entries(tables).map(([name, v]) => ({
        Sid: `Table${pascal(name)}`,
        Effect: 'Allow',
        Action: v.actions.length === 1 ? v.actions[0] : v.actions,
        Resource: [table(name)],
      })),
      {
        Sid: 'ReadSecrets',
        Effect: 'Allow',
        Action: 'secretsmanager:GetSecretValue',
        Resource: [
          `arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/edge-origin-??????`,
          `arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/e2b-??????`,
        ],
      },
    ]);
  });

  test('the E2B secret is created without a value and without a generator, kept on prod only', () => {
    const secrets = t.findResources('AWS::SecretsManager::Secret') as Record<string, any>;
    const e2b = Object.values(secrets).filter((s) => s.Properties.Name === `mopm/${stage}/e2b`);
    expect(e2b).toHaveLength(1);
    expect(Object.keys(e2b[0].Properties).sort()).toEqual(['Description', 'Name']);
    expect(e2b[0].DeletionPolicy).toBe(stage === 'prod' ? 'Retain' : 'Delete');
  });

  test('the secret\'s policy is one Deny of GetSecretValue to everyone but the function\'s role, with blockPublicPolicy', () => {
    expect(e2bSecretProblems(t.toJSON(), stage)).toEqual([]);
    const p = Object.values(t.findResources('AWS::SecretsManager::ResourcePolicy')) as any[];
    expect(p).toHaveLength(1);
    expect(p[0].Properties.BlockPublicPolicy).toBe(true);
    expect(p[0].Properties.ResourcePolicy.Statement).toEqual([
      {
        Sid: 'OnlyTheSandboxFunctionReads',
        Effect: 'Deny',
        Principal: { AWS: '*' },
        Action: 'secretsmanager:GetSecretValue',
        Resource: '*',
        Condition: { ArnNotEquals: { 'aws:PrincipalArn': { 'Fn::GetAtt': [sandboxRoleId(t, stage), 'Arn'] } } },
      },
    ]);
  });

  test('no other role in any stack of the stage has an Allow whose resource could match the E2B secret', () => {
    const s = stacks(stage);
    const secretArn = `arn:aws:secretsmanager:us-east-1:${A}:secret:mopm/${stage}/e2b-AbCdEf`;
    const own = sandboxRoleId(apiTemplate(stage), stage);
    let checked = 0;
    for (const stack of Object.values(s)) {
      const tpl = Template.fromStack(stack);
      const statements: Array<[string, any]> = [];
      for (const [roleId, ss] of Object.entries(rolePolicies(tpl))) {
        if (stack === s.api && roleId === own) continue;
        for (const st of ss) statements.push([`${stack.stackName} ${roleId}`, st]);
      }
      for (const [id, r] of Object.entries(tpl.findResources('AWS::IAM::Role')) as Array<[string, any]>) {
        for (const p of r.Properties.Policies ?? []) {
          for (const st of p.PolicyDocument.Statement) {
            statements.push([`${stack.stackName} ${id}`, { ...st, Resource: ([] as any[]).concat(st.Resource).map(flat) }]);
          }
        }
      }
      for (const [who, st] of statements) {
        checked++;
        if (st.Effect !== 'Allow') continue;
        const actions: string[] = ([] as string[]).concat(st.Action);
        const reads = actions.some((a) => globMatches(a.toLowerCase(), 'secretsmanager:getsecretvalue'));
        const matches = (st.Resource as string[]).some((r) => globMatches(r, secretArn));
        expect({ who, reaches: reads && matches }).toEqual({ who, reaches: false });
      }
    }
    expect(checked).toBeGreaterThan(10);
  });

  test('without the Rust zips the stack has no E2B secret and no secret policy', () => {
    const off = Template.fromStack(build(stage).api);
    off.resourceCountIs('AWS::SecretsManager::Secret', 0);
    off.resourceCountIs('AWS::SecretsManager::ResourcePolicy', 0);
  });
});

/** The logical id of the integration whose target is the function. */
function integrationIdOf(t: Template, fnLogicalId: string): string {
  const [id] = Object.entries(t.findResources('AWS::ApiGatewayV2::Integration')).find(
    ([, i]: [string, any]) => i.Properties.IntegrationUri['Fn::GetAtt'][0] === fnLogicalId,
  )!;
  return id;
}

describe('the E2B secret policy check fails on a defect', () => {
  const t = apiTemplate('beta');
  const problems = (f: (p: any) => void) => e2bSecretProblems(withPolicy(t, f), 'beta');

  test('a template as synthesized has no problem', () => {
    expect(e2bSecretProblems(t.toJSON(), 'beta')).toEqual([]);
  });

  test('a policy without its Deny (an Allow) is reported', () => {
    expect(problems((p) => (p.ResourcePolicy.Statement[0].Effect = 'Allow'))).toEqual(['the statement is Allow, not Deny']);
  });

  test('a policy with no statement is reported', () => {
    expect(problems((p) => (p.ResourcePolicy.Statement = []))).toEqual(['expected exactly one statement, found 0']);
  });

  test('a policy that names another role is reported', () => {
    const other = { 'Fn::GetAtt': ['SomeOtherRole', 'Arn'] };
    expect(problems((p) => (p.ResourcePolicy.Statement[0].Condition.ArnNotEquals['aws:PrincipalArn'] = other))).toEqual([
      "the Condition is not ArnNotEquals aws:PrincipalArn on the tutorial-sandbox function's role alone",
    ]);
  });

  test('a policy with NotPrincipal in place of the condition is reported', () => {
    const out = problems((p) => {
      const st = p.ResourcePolicy.Statement[0];
      st.NotPrincipal = { AWS: st.Condition.ArnNotEquals['aws:PrincipalArn'] };
      delete st.Condition;
    });
    expect(out).toContain('the statement uses NotPrincipal');
    expect(out).toContain("the Condition is not ArnNotEquals aws:PrincipalArn on the tutorial-sandbox function's role alone");
  });

  test('a policy that denies more or less than GetSecretValue, or not on every principal, is reported', () => {
    expect(problems((p) => (p.ResourcePolicy.Statement[0].Action = 'secretsmanager:*'))).toEqual(['the Action is not exactly secretsmanager:GetSecretValue']);
    expect(problems((p) => (p.ResourcePolicy.Statement[0].Principal = { AWS: `arn:aws:iam::${A}:root` }))).toEqual(['the Principal is not {"AWS":"*"}']);
    expect(problems((p) => (p.ResourcePolicy.Statement[0].Resource = 'arn:aws:secretsmanager:*'))).toEqual(['the Resource is not "*"']);
  });

  test('a second statement or a missing blockPublicPolicy is reported', () => {
    expect(problems((p) => p.ResourcePolicy.Statement.push({ ...p.ResourcePolicy.Statement[0] }))).toEqual(['expected exactly one statement, found 2']);
    expect(problems((p) => (p.BlockPublicPolicy = false))).toEqual(['blockPublicPolicy is not true']);
  });

  test('a secret with a generated or given value is reported, and so is a missing secret or policy', () => {
    const edit = (f: (secret: any, json: any) => void) => {
      const json = clone(t.toJSON());
      const [, s] = Object.entries(json.Resources).find(([, r]: [string, any]) => r.Type === 'AWS::SecretsManager::Secret' && r.Properties.Name === 'mopm/beta/e2b') as [string, any];
      f(s, json);
      return e2bSecretProblems(json, 'beta');
    };
    expect(edit((s) => (s.Properties.GenerateSecretString = {}))).toEqual([
      'the secret has GenerateSecretString: its value must be written by the operator, never by the stack',
    ]);
    expect(edit((s) => (s.Properties.SecretString = 'x'))).toEqual(['the secret has SecretString: its value must be written by the operator, never by the stack']);
    expect(edit((s) => (s.Properties.Name = 'mopm/beta/other'))).toEqual(['expected one secret named mopm/beta/e2b, found 0']);
    expect(
      edit((_s, json) => {
        for (const [k, r] of Object.entries<any>(json.Resources)) if (r.Type === 'AWS::SecretsManager::ResourcePolicy') delete json.Resources[k];
      }),
    ).toEqual(['expected one resource policy on the secret, found 0']);
  });
});

describe('the stage settings item the function reads', () => {
  test('the item the stack writes for beta with a template id is the checked-in fixture the function tests load', () => {
    const item = stageSettingsItem(stageSettings(stageConfig('beta', DUMMY_ZONE_ID, { e2bTemplateId: 'mopm-tutorial-beta' }), true));
    expect(JSON.parse(fs.readFileSync(ITEM_FILE, 'utf8'))).toEqual(item);
    expect(fs.readFileSync(ITEM_FILE, 'utf8')).toBe(JSON.stringify(item, null, 2) + '\n');
  });
});
