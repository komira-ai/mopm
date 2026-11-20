import * as fs from 'fs';
import * as path from 'path';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ApiStack } from '../lib/api-stack';
import { STAGES, Stage, stageConfig } from '../lib/config';
import { DEFAULT_E2B_DOMAIN, DEFAULT_SANDBOX_TIMEOUT_S, stageSettings, stageSettingsItem } from '../lib/stage-settings';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, HANDLER_STUB_DIR, RUST_ZIP_STUB_DIR, build, cfnFlat } from './util';

const SITE: Record<Stage, string> = { beta: 'beta.mopm.dev', gamma: 'gamma.mopm.dev', prod: 'mopm.dev' };

/** The API stack synthesized with the Rust functions on, and its `Custom::AWS` resources. */
function apiWithRust(stage: Stage, opts: { tutorial?: object; require2fa?: boolean } = {}): Template {
  const app = new App();
  const api = new ApiStack(app, `mopm-${stage}-api`, {
    env: { account: DUMMY_ACCOUNT, region: 'us-east-1' },
    config: stageConfig(stage, DUMMY_ZONE_ID, opts.tutorial ?? {}),
    version: '1.2.3',
    commit: 'c0ffee',
    handlerDir: HANDLER_STUB_DIR,
    rustZipDir: RUST_ZIP_STUB_DIR,
    ...(opts.require2fa !== undefined ? { require2fa: opts.require2fa } : {}),
  });
  return Template.fromStack(api);
}

/** The SDK call the custom resource makes on create (CDK stores it as a JSON string). */
function createCall(t: Template): any {
  const crs = Object.values(t.findResources('Custom::AWS')) as any[];
  expect(crs).toHaveLength(1);
  return JSON.parse(cfnFlat(crs[0].Properties.Create));
}

describe.each(STAGES)('stage_settings on %s', (stage) => {
  test('without a template id: the site host, two-factor on, the default domain and timeout, and no e2b_template_id', () => {
    const call = createCall(apiWithRust(stage));
    expect(call).toMatchObject({ service: 'DynamoDB', action: 'PutItem' });
    expect(call.parameters).toEqual({
      TableName: `mopm-${stage}-config`,
      Item: {
        key: { S: 'stage_settings' },
        redirect_uri: { S: `https://${SITE[stage]}/api/v2/auth/web/callback` },
        site_origin: { S: `https://${SITE[stage]}` },
        require_2fa: { BOOL: true },
        e2b_domain: { S: 'e2b.app' },
        sandbox_timeout_s: { N: '1800' },
      },
    });
  });

  test('with a template id, a domain and a timeout from the tutorial block, and two-factor off', () => {
    const call = createCall(apiWithRust(stage, { tutorial: { e2bTemplateId: 'tpl-abc_1', e2bDomain: 'e2b.example', sandboxTimeoutS: 600 }, require2fa: false }));
    expect(call.parameters.Item).toEqual({
      key: { S: 'stage_settings' },
      redirect_uri: { S: `https://${SITE[stage]}/api/v2/auth/web/callback` },
      site_origin: { S: `https://${SITE[stage]}` },
      require_2fa: { BOOL: false },
      e2b_template_id: { S: 'tpl-abc_1' },
      e2b_domain: { S: 'e2b.example' },
      sandbox_timeout_s: { N: '600' },
    });
  });

  test('the item written for beta with a full tutorial block is the item the Rust side parses (service/lambda/web fixture)', () => {
    const call = createCall(apiWithRust('beta', { tutorial: { e2bTemplateId: 'tpl-abc_1', e2bDomain: 'e2b.example', sandboxTimeoutS: 600 }, require2fa: false }));
    const fixture = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../lambda/web/tests/fixtures/stage_settings_item.json'), 'utf8'));
    expect(call.parameters.Item).toEqual(fixture);
  });

  test('a block with only a template id keeps the default domain and timeout', () => {
    const call = createCall(apiWithRust(stage, { tutorial: { e2bTemplateId: 'tpl-only' } }));
    expect(call.parameters.Item).toEqual({
      key: { S: 'stage_settings' },
      redirect_uri: { S: `https://${SITE[stage]}/api/v2/auth/web/callback` },
      site_origin: { S: `https://${SITE[stage]}` },
      require_2fa: { BOOL: true },
      e2b_template_id: { S: 'tpl-only' },
      e2b_domain: { S: 'e2b.app' },
      sandbox_timeout_s: { N: '1800' },
    });
  });

  test('the same item is written on update, so a changed value reaches the table at the next deploy', () => {
    const t = apiWithRust(stage, { tutorial: { e2bTemplateId: 'tpl' } });
    const cr = Object.values(t.findResources('Custom::AWS'))[0] as any;
    expect(JSON.parse(cfnFlat(cr.Properties.Update))).toEqual(createCall(t));
    expect(cr.Properties.Delete).toBeUndefined();
  });

  test("the writer may put only the stage_settings key of this stage's config table", () => {
    const t = apiWithRust(stage);
    const policies = Object.values(t.findResources('AWS::IAM::Policy')) as any[];
    const writer = policies.filter((p) => p.Properties.PolicyDocument.Statement.some((s: any) => s.Sid === 'PutStageSettings'));
    expect(writer).toHaveLength(1);
    expect(writer[0].Properties.PolicyDocument.Statement.map((s: any) => ({ ...s, Resource: cfnFlat(s.Resource) }))).toEqual([
      {
        Sid: 'PutStageSettings',
        Effect: 'Allow',
        Action: 'dynamodb:PutItem',
        Resource: `arn:aws:dynamodb:us-east-1:${DUMMY_ACCOUNT}:table/mopm-${stage}-config`,
        Condition: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['stage_settings'] } },
      },
    ]);
  });

  test("the writer installs no SDK at deploy and logs to a group kept a month", () => {
    const t = apiWithRust(stage);
    const cr = Object.values(t.findResources('Custom::AWS'))[0] as any;
    expect(cr.Properties.InstallLatestAwsSdk).toBe(false);
    const groups = Object.values(t.findResources('AWS::Logs::LogGroup')) as any[];
    expect(groups.every((g) => g.Properties.RetentionInDays === 30)).toBe(true);
  });
});

describe('stageSettings', () => {
  test('defaults: no tutorial block at all is the same as an empty one', () => {
    const none = stageSettings(stageConfig('prod', undefined, undefined), true);
    const empty = stageSettings(stageConfig('prod', undefined, {}), true);
    expect(none).toEqual(empty);
    expect(none).toEqual({
      key: 'stage_settings',
      redirect_uri: 'https://mopm.dev/api/v2/auth/web/callback',
      site_origin: 'https://mopm.dev',
      require_2fa: true,
      e2b_domain: DEFAULT_E2B_DOMAIN,
      sandbox_timeout_s: DEFAULT_SANDBOX_TIMEOUT_S,
    });
    expect([DEFAULT_E2B_DOMAIN, DEFAULT_SANDBOX_TIMEOUT_S]).toEqual(['e2b.app', 1800]);
  });

  test('the attribute-value form has no e2b_template_id when the settings have none', () => {
    expect(Object.keys(stageSettingsItem(stageSettings(stageConfig('beta', undefined, {}), true)))).not.toContain('e2b_template_id');
  });
});

describe.each(STAGES)('the Rust switch (rustZipDir) on %s', (stage) => {
  const off = build(stage);
  const on = build(stage, { rustZipDir: RUST_ZIP_STUB_DIR });

  test('absent: no Rust function, no custom resource, no stage_settings writer, no web-session route', () => {
    const t = Template.fromStack(off.api);
    t.resourceCountIs('Custom::AWS', 0);
    const runtimes = Object.values(t.findResources('AWS::Lambda::Function')).map((f: any) => f.Properties.Runtime);
    expect(runtimes).not.toContain('provided.al2023');
    expect(runtimes.every((r) => r === 'nodejs22.x')).toBe(true);
    const keys = Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r: any) => r.Properties.RouteKey);
    expect(keys).not.toContain('GET /api/v2/auth/web/session');
    expect(keys).not.toContain('POST /api/v2/auth/web/logout');
  });

  test('present: every resource of the stack without it is there and unchanged; what is added is only the writer, the web-login, web-session and tutorial-sandbox functions, and the E2B secret with its policy', () => {
    const a = Template.fromStack(off.api).toJSON().Resources as Record<string, any>;
    const b = Template.fromStack(on.api).toJSON().Resources as Record<string, any>;
    for (const [id, r] of Object.entries(a)) expect(b[id]).toEqual(r);
    const added = Object.keys(b).filter((id) => !(id in a)).map((id) => b[id].Type).sort();
    // Three Rust functions (an integration, a role, a log group and an invoke permission each; five routes) and the writer
    // (a function, its role and log group, the custom resource), and the E2B secret with its policy.
    expect(added).toEqual([
      'AWS::ApiGatewayV2::Integration',
      'AWS::ApiGatewayV2::Integration',
      'AWS::ApiGatewayV2::Integration',
      'AWS::ApiGatewayV2::Route',
      'AWS::ApiGatewayV2::Route',
      'AWS::ApiGatewayV2::Route',
      'AWS::ApiGatewayV2::Route',
      'AWS::ApiGatewayV2::Route',
      'AWS::IAM::Policy',
      'AWS::IAM::Policy',
      'AWS::IAM::Policy',
      'AWS::IAM::Policy',
      'AWS::IAM::Role',
      'AWS::IAM::Role',
      'AWS::IAM::Role',
      'AWS::IAM::Role',
      'AWS::Lambda::Function',
      'AWS::Lambda::Function',
      'AWS::Lambda::Function',
      'AWS::Lambda::Function',
      'AWS::Lambda::Permission',
      'AWS::Lambda::Permission',
      'AWS::Lambda::Permission',
      'AWS::Logs::LogGroup',
      'AWS::Logs::LogGroup',
      'AWS::Logs::LogGroup',
      'AWS::Logs::LogGroup',
      'AWS::SecretsManager::ResourcePolicy',
      'AWS::SecretsManager::Secret',
      'Custom::AWS',
    ]);
    const fns = Object.values(b).filter((r) => r.Type === 'AWS::Lambda::Function');
    const rust = fns.filter((r) => r.Properties.Runtime === 'provided.al2023').map((r) => r.Properties.FunctionName).sort();
    expect(rust).toEqual([`mopm-${stage}-tutorial-sandbox`, `mopm-${stage}-web-login`, `mopm-${stage}-web-session`]);
  });

  test('the other stacks do not change with it', () => {
    for (const k of ['channel', 'data', 'publish', 'site'] as const) {
      expect(Template.fromStack(on[k]).toJSON()).toEqual(Template.fromStack(off[k]).toJSON());
    }
  });
});

test('a rustZipDir that does not exist is refused, naming it', () => {
  const dir = path.join(RUST_ZIP_STUB_DIR, 'absent');
  expect(() => build('beta', { rustZipDir: dir })).toThrow(`the Rust function zips are missing: ${dir} does not exist`);
});
