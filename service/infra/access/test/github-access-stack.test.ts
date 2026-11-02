import { App, CliCredentialsStackSynthesizer } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import * as fs from 'fs';
import * as path from 'path';
import { GithubAccessStack } from '../lib/github-access-stack';
import * as c from '../lib/contract';

const ACCOUNT = '4'.repeat(12); // dummy id, built at runtime so no 12-digit literal is in the tree
const REGION = 'us-west-2';
const REPO = 'example-org/example-repo';
const PREFIX = 'repo:example-org@111/example-repo@222'; // immutable form with dummy ids

function synth(stage: c.Stage, regions = [REGION]): Template {
  const app = new App();
  const stack = new GithubAccessStack(app, `t-${stage}`, {
    stage,
    repo: REPO,
    ownerId: '111',
    repoId: '222',
    regions,
    env: { account: ACCOUNT, region: REGION },
  });
  return Template.fromStack(stack);
}

type Stmt = { Effect: string; Action: string | string[]; Resource?: unknown; Condition?: any; Sid?: string };
const arr = <T>(x: T | T[]): T[] => (Array.isArray(x) ? x : [x]);

function role(t: Template, name: string): any {
  const hits = Object.values(t.findResources('AWS::IAM::Role')).filter(
    (r: any) => r.Properties.RoleName === name,
  );
  expect(hits).toHaveLength(1);
  return hits[0];
}
function policyStatements(t: Template, roleLogicalIdPrefix: string): Stmt[] {
  const out: Stmt[] = [];
  for (const [, p] of Object.entries(t.findResources('AWS::IAM::Policy'))) {
    const roles = JSON.stringify((p as any).Properties.Roles);
    if (roles.includes(roleLogicalIdPrefix)) out.push(...(p as any).Properties.PolicyDocument.Statement);
  }
  return out;
}
const trustStmt = (r: any): any => {
  const st = r.Properties.AssumeRolePolicyDocument.Statement;
  expect(st).toHaveLength(1);
  return st[0];
};
const flat = (x: unknown): string[] => JSON.stringify(x).match(/"[^"]*"/g)?.map((s) => s.slice(1, -1)) ?? [];

describe.each(c.STAGES)('stage %s', (stage) => {
  const t = synth(stage);
  const deploy = role(t, `mopm-${stage}-deploy`);
  const e2e = role(t, `mopm-${stage}-e2e`);

  test('exactly one native GitHub OIDC provider with audience sts.amazonaws.com', () => {
    t.resourceCountIs('AWS::IAM::OIDCProvider', 1);
    t.hasResourceProperties('AWS::IAM::OIDCProvider', {
      Url: 'https://token.actions.githubusercontent.com',
      ClientIdList: ['sts.amazonaws.com'],
    });
    const p: any = Object.values(t.findResources('AWS::IAM::OIDCProvider'))[0];
    expect(p.Properties.ThumbprintList).toBeUndefined(); // not required for GitHub since 2023
  });

  test('no custom resource and no Lambda (the OIDC provider needs neither)', () => {
    t.resourceCountIs('Custom::AWSCDKOpenIdConnectProvider', 0);
    expect(Object.keys(t.findResources('AWS::Lambda::Function'))).toHaveLength(0);
    const types = Object.values(t.toJSON().Resources ?? {}).map((r: any) => r.Type as string);
    expect(types.filter((x) => x.startsWith('Custom::') || x === 'AWS::CloudFormation::CustomResource')).toEqual([]);
  });

  test('synthesizer is CLI credentials: no AssumeRole into the bootstrap roles', () => {
    const app = new App();
    const stack = new GithubAccessStack(app, 'syn', { stage, regions: [REGION], env: { account: ACCOUNT, region: REGION } });
    expect(stack.synthesizer).toBeInstanceOf(CliCredentialsStackSynthesizer);
    const art = app.synth().getStackByName('syn');
    expect(art.assumeRoleArn).toBeUndefined();
    expect(art.cloudFormationExecutionRoleArn).toBeUndefined();
    expect(art.requiresBootstrapStackVersion).toBeUndefined();
    expect(art.bootstrapStackVersionSsmParameter).toBeUndefined();
    // the assets bucket name may appear (the CLI uploads with the admin's credentials); no bootstrap ROLE may
    expect(JSON.stringify(art.manifest)).not.toMatch(/cdk-hnb659fds-[a-z-]*role/);
  });

  test.each([
    ['deploy', () => deploy, 'deploy.yml'],
    ['e2e', () => e2e, 'e2e.yml'],
  ] as const)('%s trust: aud and sub are exact StringEquals, nothing else', (_n, get, file) => {
    const s = trustStmt(get());
    expect(s.Effect).toBe('Allow');
    expect(s.Action).toBe('sts:AssumeRoleWithWebIdentity');
    expect(Object.keys(s.Condition)).toEqual(['StringEquals']); // no StringLike, no ForAny...
    expect(s.Condition.StringEquals).toEqual({
      'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
      'token.actions.githubusercontent.com:sub':
        `${PREFIX}:environment:${stage}:job_workflow_ref:${REPO}/.github/workflows/${file}@refs/heads/main`,
    });
    for (const v of Object.values<string>(s.Condition.StringEquals)) expect(v).not.toMatch(/[*?]/);
    // only the federated OIDC provider of this account may be the principal
    expect(Object.keys(s.Principal)).toEqual(['Federated']);
  });

  test('the two roles are bound to different workflow files', () => {
    const sub = (r: any) => trustStmt(r).Condition.StringEquals['token.actions.githubusercontent.com:sub'];
    expect(sub(deploy)).not.toEqual(sub(e2e));
  });

  test('max session is exactly one hour', () => {
    expect(deploy.Properties.MaxSessionDuration).toBe(3600);
    expect(e2e.Properties.MaxSessionDuration).toBe(3600);
  });

  test('no managed policies on either role', () => {
    expect(deploy.Properties.ManagedPolicyArns).toBeUndefined();
    expect(e2e.Properties.ManagedPolicyArns).toBeUndefined();
  });

  test('deploy role can do nothing but sts:AssumeRole on the CDK bootstrap roles', () => {
    const st = policyStatements(t, 'DeployRole');
    expect(st).toHaveLength(1);
    expect(st[0].Effect).toBe('Allow');
    expect(st[0].Action).toBe('sts:AssumeRole');
    expect(st[0].Condition).toBeUndefined();
    const res = arr(st[0].Resource as string | string[]);
    expect(res).toHaveLength(c.CDK_BOOTSTRAP_ROLE_KINDS.length);
    for (const r of res) {
      expect(r).toMatch(
        new RegExp(`^arn:aws:iam::${ACCOUNT}:role/cdk-hnb659fds-(deploy|file-publishing|image-publishing|lookup)-role-${ACCOUNT}-${REGION}$`),
      );
    }
  });

  test('e2e role: no Allow with a wildcard action, no iam/sts/kms/lambda/cloudformation', () => {
    const st = policyStatements(t, 'E2eRole');
    for (const s of st) {
      expect(s.Effect).toBe('Allow');
      for (const a of arr(s.Action)) {
        expect(a).not.toMatch(/\*/);
        expect(a).toMatch(/^(secretsmanager:GetSecretValue|s3:(GetObject|ListBucket|DeleteObject)|dynamodb:(Query|DeleteItem))$/);
      }
    }
  });

  test('e2e secret access is one test-identity secret pattern', () => {
    const st = policyStatements(t, 'E2eRole').filter((s) => arr(s.Action).some((a) => a.startsWith('secretsmanager:')));
    expect(st).toHaveLength(1);
    expect(st[0].Action).toBe('secretsmanager:GetSecretValue');
    expect(st[0].Resource).toBe(
      `arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:mopm/${stage}/e2e/test-identity-??????`,
    );
  });

  test('e2e S3 read is on the stage channel bucket only', () => {
    const bucket = `mopm-${stage}-channel-${ACCOUNT}`;
    const st = policyStatements(t, 'E2eRole');
    const get = st.find((s) => s.Action === 's3:GetObject')!;
    const list = st.find((s) => s.Action === 's3:ListBucket')!;
    expect(get.Resource).toBe(`arn:aws:s3:::${bucket}/*`);
    expect(list.Resource).toBe(`arn:aws:s3:::${bucket}`);
  });

  test('e2e writes are exactly the cleanup set on disposable stages and absent on prod', () => {
    const st = policyStatements(t, 'E2eRole');
    const writes = st.filter((s) => arr(s.Action).some((a) => /Delete|Put|Update|Create/.test(a)));
    if (!c.isDisposable(stage)) {
      expect(writes).toHaveLength(0);
      expect(st.some((s) => arr(s.Action).some((a) => a.startsWith('dynamodb:')))).toBe(false);
      return;
    }
    expect(writes).toHaveLength(2);
    const rows = writes.find((s) => s.Sid === 'CleanupRows')!;
    expect(arr(rows.Action).sort()).toEqual(['dynamodb:DeleteItem', 'dynamodb:Query']);
    expect(arr(rows.Resource as string[]).sort()).toEqual(
      c.CLEANUP_TABLES.map((x) => `arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/mopm-${stage}-${x}`).sort(),
    );
    expect(flat(rows.Resource).join()).not.toMatch(/audit|tokens|users/);
    expect(rows.Condition).toEqual({ 'ForAllValues:StringLike': { 'dynamodb:LeadingKeys': ['e2e_*'] } });
    const bytes = writes.find((s) => s.Sid === 'CleanupBytes')!;
    expect(bytes.Action).toBe('s3:DeleteObject');
    expect(bytes.Resource).toBe(`arn:aws:s3:::mopm-${stage}-channel-${ACCOUNT}/files/e2e_*`);
  });

  test('no policy anywhere grants Resource "*" or Action "*"', () => {
    const all = [...policyStatements(t, 'DeployRole'), ...policyStatements(t, 'E2eRole')];
    for (const s of all) {
      expect(arr(s.Action as any).every((a) => a !== '*' && !/:\*$/.test(a))).toBe(true);
      expect(arr(s.Resource as any)).not.toContain('*');
    }
  });

  test('the stack creates nothing else that grants access', () => {
    expect(Object.keys(t.findResources('AWS::IAM::User'))).toHaveLength(0);
    expect(Object.keys(t.findResources('AWS::IAM::AccessKey'))).toHaveLength(0);
    expect(Object.keys(t.findResources('AWS::IAM::ManagedPolicy'))).toHaveLength(0);
    expect(Object.keys(t.findResources('AWS::IAM::Policy'))).toHaveLength(2);
  });

  test('stack does not use the bootstrap roles it grants access to', () => {
    const json = JSON.stringify(t.toJSON());
    expect(json).not.toContain('BootstrapVersion');
    expect(json).not.toContain('cdk-hnb659fds-cfn-exec');
  });
});

test('multiple regions: deploy role gets 4 roles per region, still only AssumeRole', () => {
  const t = synth('beta', ['us-west-2', 'us-east-1']);
  const st = policyStatements(t, 'DeployRole');
  expect(st).toHaveLength(1);
  expect(arr(st[0].Resource as string[])).toHaveLength(8);
});

test('trust is bound to komira-ai/mopm main by default', () => {
  const app = new App();
  const t = Template.fromStack(
    new GithubAccessStack(app, 'd', { stage: 'beta', regions: [REGION], env: { account: ACCOUNT, region: REGION } }),
  );
  const subs = Object.values(t.findResources('AWS::IAM::Role'))
    .filter((r: any) => /^mopm-beta-(deploy|e2e)$/.test(r.Properties.RoleName))
    .map((r: any) => r.Properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals['token.actions.githubusercontent.com:sub'],
  );
  expect(subs.sort()).toEqual([
    'repo:komira-ai@305577347/mopm@1418104703:environment:beta:job_workflow_ref:komira-ai/mopm/.github/workflows/deploy.yml@refs/heads/main',
    'repo:komira-ai@305577347/mopm@1418104703:environment:beta:job_workflow_ref:komira-ai/mopm/.github/workflows/e2e.yml@refs/heads/main',
  ]);
});

test('the legacy name-only subject prefix is not trusted', () => {
  const t = synth('beta');
  expect(JSON.stringify(t.toJSON())).not.toContain(`repo:${REPO}:`);
});

test('ids must be numeric', () => {
  const mk = (ownerId: string, repoId: string) => () =>
    new GithubAccessStack(new App(), 'x', { stage: 'beta', repo: REPO, ownerId, repoId, regions: [REGION], env: { account: ACCOUNT, region: REGION } });
  expect(mk('1*', '2')).toThrow(/numeric/);
  expect(mk('1', '')).toThrow(/numeric/);
});

test('stage config is validated', () => {
  expect(() => c.assertStage('staging')).toThrow();
  expect(() => new GithubAccessStack(new App(), 'x', { stage: 'beta', repo: REPO, regions: ['us-west-2'] })).toThrow(/concrete/);
  expect(() => new GithubAccessStack(new App(), 'x', { stage: 'beta', repo: 'bad', regions: ['r'], env: { account: ACCOUNT, region: REGION } })).toThrow(/bad repo/);
});

test('public-repo hygiene: no 12-digit account id literal in the access sources', () => {
  const root = path.join(__dirname, '..');
  for (const f of ['lib/contract.ts', 'lib/github-access-stack.ts', 'bin/access.ts', 'bin/bootstrap.ts', 'bin/oauth-secret.ts', 'lib/bootstrap.ts', 'lib/oauth-secret.ts', 'lib/held.ts', 'lib/diff.ts', 'BOOTSTRAP.md', 'cfn-exec-policy.template.json']) {
    const text = fs.readFileSync(path.join(root, f), 'utf8');
    expect(text.match(/(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])/g) ?? []).toEqual([]);
  }
});

describe('cfn-exec policy template', () => {
  const raw = fs.readFileSync(path.join(__dirname, '..', 'cfn-exec-policy.template.json'), 'utf8');
  const doc = JSON.parse(raw);
  const allows: Stmt[] = doc.Statement.filter((s: Stmt) => s.Effect === 'Allow');
  const denies: Stmt[] = doc.Statement.filter((s: Stmt) => s.Effect === 'Deny');

  test('fits the 6144-character managed-policy limit (whitespace excluded)', () => {
    expect(raw.replace(/\s/g, '').length).toBeLessThan(6144);
  });
  test('is not admin: no "*" action, no "*:*", no iam:* allow', () => {
    for (const s of allows) for (const a of arr(s.Action)) {
      expect(a).not.toBe('*');
      expect(a).not.toBe('iam:*');
    }
    expect(raw).not.toMatch(/AdministratorAccess/);
  });
  test('IAM allows are limited to this stage\'s roles', () => {
    for (const s of allows.filter((x) => arr(x.Action).some((a) => /^iam:(?!CreateServiceLinkedRole)/.test(a)))) {
      expect(s.Resource).toBe('arn:aws:iam::{{ACCOUNT}}:role/mopm-{{STAGE}}-*');
    }
  });
  test('no kms:* and no unconditioned Attach/DetachRolePolicy (privilege escalation)', () => {
    for (const s of allows) for (const a of arr(s.Action)) {
      expect(a).not.toBe('kms:*');
      if (/^iam:(Attach|Detach)RolePolicy$/.test(a)) expect(s.Condition?.ArnLike?.['iam:PolicyARN']).toBeDefined();
    }
  });
  test('denies protect the access roles, the OIDC provider, the bootstrap roles and users', () => {
    const text = JSON.stringify(denies);
    for (const needle of ['role/mopm-{{STAGE}}-deploy', 'role/mopm-{{STAGE}}-e2e', 'role/cdk-hnb659fds-*', 'oidc-provider/token.actions.githubusercontent.com', 'iam:CreateUser', 'iam:CreateAccessKey'])
      expect(text).toContain(needle);
  });
});
