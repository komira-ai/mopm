import * as fs from 'fs';
import * as path from 'path';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES, Stage } from '../lib/config';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, build } from './util';

// Does the scoped CloudFormation execution policy (service/infra/access/cfn-exec-policy.template.json, rendered the
// way bootstrap.sh renders it) allow everything CloudFormation must do to create, update and delete the resources
// these stacks synthesize?
//
// Why it exists: the beta deploy failed because the policy had no Route 53 permission and no ssm:GetParameters for
// the bootstrap version parameter, and nothing here noticed. This test fails when
//  - a template contains a resource type that the reviewed REQUIRED map below does not know (add it, with its actions), or
//  - the rendered policy does not allow a required (action, resource, condition context) of some resource, or a Deny
//    statement blocks it.
// It evaluates the policy with a small IAM evaluator (Allow/Deny, wildcards, the condition operators the policy uses).
// It never calls AWS. The access stack itself is out of scope: an admin deploys it with their own credentials.
//
// Route 53 condition keys: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-rrset-conditions.html
// (route53:ChangeResourceRecordSetsNormalizedRecordNames, ...RecordTypes, ...Actions; names are lower-case, no trailing dot).

type Json = any;
const REGION = 'us-east-1';
const POLICY_FILE = path.resolve(__dirname, '../../access/cfn-exec-policy.template.json');
const ZONE: Record<Stage, string> = { beta: 'beta.mopm.dev', gamma: 'gamma.mopm.dev', prod: 'mopm.dev' };

/** Renders the template the way bootstrap.sh does ({{STAGE}}, {{ACCOUNT}}, {{ZONE}}). */
export function renderPolicy(stage: Stage, account: string = DUMMY_ACCOUNT): Json {
  const text = fs
    .readFileSync(POLICY_FILE, 'utf8')
    .replace(/\{\{STAGE\}\}/g, stage)
    .replace(/\{\{ACCOUNT\}\}/g, account)
    .replace(/\{\{ZONE\}\}/g, ZONE[stage]);
  if (text.includes('{{')) throw new Error('policy template has a placeholder this test (and bootstrap.sh) do not fill');
  return JSON.parse(text);
}

// ---------------------------------------------------------------------------------------------------------------
// A small IAM evaluator.
// ---------------------------------------------------------------------------------------------------------------

const arr = (v: Json): string[] => (v === undefined ? [] : Array.isArray(v) ? v : [v]);

function matches(glob: string, s: string, ignoreCase: boolean): boolean {
  const re = '^' + glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$';
  return new RegExp(re, ignoreCase ? 'i' : '').test(s);
}

/** Context values: condition key -> request values. */
type Context = Record<string, string[]>;

function conditionHolds(cond: Json, ctx: Context): boolean {
  for (const [op, keys] of Object.entries<Json>(cond ?? {})) {
    const forAll = op.startsWith('ForAllValues:');
    const base = op.replace(/^For(All|Any)Values:/, '');
    if (!['StringEquals', 'StringLike', 'ArnLike'].includes(base)) throw new Error(`evaluator does not support ${op}`);
    for (const [key, want] of Object.entries<Json>(keys)) {
      const have = ctx[key];
      if (have === undefined) {
        if (forAll) continue; // AWS: ForAllValues is true when the key is absent
        return false;
      }
      const test = (h: string) => arr(want).some((w) => (base === 'StringEquals' ? h === w : matches(w, h, false)));
      if (!(forAll ? have.every(test) : have.some(test))) return false;
    }
  }
  return true;
}

/** 'allowed' | 'not allowed' | 'denied by <Sid>'. */
export function decide(policy: Json, action: string, resource: string, ctx: Context = {}): string {
  let allowedBy: string | undefined;
  for (const s of policy.Statement) {
    if (!arr(s.Action).some((a) => matches(a, action, true))) continue;
    if (!arr(s.Resource).some((r) => matches(r, resource, false))) continue;
    if (!conditionHolds(s.Condition, ctx)) continue;
    if (s.Effect === 'Deny') return `denied by ${s.Sid}`;
    allowedBy = s.Sid;
  }
  return allowedBy ? 'allowed' : 'not allowed';
}

// ---------------------------------------------------------------------------------------------------------------
// The reviewed map: resource type -> what CloudFormation (running as cfn-exec) must be allowed to do for it.
// ---------------------------------------------------------------------------------------------------------------

interface Need {
  action: string;
  resource: string;
  ctx?: Context;
}
interface Ctx {
  stage: Stage;
  account: string;
  stackName: string;
  template: Json;
}
type Needs = (r: Json, id: string, c: Ctx) => Need[];

const each = (actions: string[], resource: string, ctx?: Context): Need[] => actions.map((action) => ({ action, resource, ctx }));
/** CloudFormation names a resource without an explicit name `<stack>-<logical id>-<random>`. */
const generated = (c: Ctx, id: string) => `${c.stackName}-${id}-A1B2C3D4E5F6`;
const logicalId = (v: Json): string => (v?.Ref ?? v?.['Fn::GetAtt']?.[0]) as string;
function physical(c: Ctx, id: string, nameProp: string): string {
  const v = c.template.Resources[id]?.Properties?.[nameProp];
  return typeof v === 'string' ? v : generated(c, id);
}
/** A CloudFormation string (Fn::Join of literals and the partition) flattened. */
function flat(v: Json): string {
  if (typeof v === 'string') return v;
  if (v?.Ref === 'AWS::Partition') return 'aws';
  if (v?.['Fn::Join']) return (v['Fn::Join'][1] as Json[]).map(flat).join(v['Fn::Join'][0]);
  return '<unresolved>';
}
const bucketArn = (c: Ctx, ref: Json) => `arn:aws:s3:::${physical(c, logicalId(ref), 'BucketName')}`;
const functionArn = (c: Ctx, ref: Json) =>
  `arn:aws:lambda:${REGION}:${c.account}:function:${physical(c, logicalId(ref), 'FunctionName')}`;
const roleArn = (c: Ctx, ref: Json) => `arn:aws:iam::${c.account}:role/${physical(c, logicalId(ref), 'RoleName')}`;
const assetRead = (c: Ctx, code: Json): Need[] =>
  code?.S3Bucket ? each(['s3:GetObject'], `arn:aws:s3:::cdk-hnb659fds-assets-${c.account}-${REGION}/${'a'.repeat(64)}.zip`) : [];

function route53Change(name: string, type: string, zoneId: string): Need[] {
  const normalized = name.replace(/\.$/, '').toLowerCase();
  return [
    ...each(['route53:ChangeResourceRecordSets'], `arn:aws:route53:::hostedzone/${zoneId}`, {
      'route53:ChangeResourceRecordSetsNormalizedRecordNames': [normalized],
      'route53:ChangeResourceRecordSetsRecordTypes': [type],
    }),
    ...each(['route53:GetHostedZone', 'route53:ListResourceRecordSets'], `arn:aws:route53:::hostedzone/${zoneId}`),
    ...each(['route53:GetChange'], 'arn:aws:route53:::change/C0DUMMYCHANGE'),
  ];
}

const apigw = (suffix: string): Needs => () =>
  each(['apigateway:GET', 'apigateway:POST', 'apigateway:PUT', 'apigateway:PATCH', 'apigateway:DELETE'], `arn:aws:apigateway:${REGION}::${suffix}`);

export const REQUIRED: Record<string, Needs> = {
  'AWS::CDK::Metadata': () => [],
  'AWS::S3::Bucket': (r, id, c) =>
    each(
      [
        's3:CreateBucket', 's3:DeleteBucket', 's3:PutBucketVersioning', 's3:PutEncryptionConfiguration',
        's3:PutBucketPublicAccessBlock', 's3:PutLifecycleConfiguration', 's3:PutBucketOwnershipControls', 's3:PutBucketTagging',
      ],
      `arn:aws:s3:::${physical(c, id, 'BucketName')}`,
    ),
  'AWS::S3::BucketPolicy': (r, _id, c) =>
    each(['s3:PutBucketPolicy', 's3:GetBucketPolicy', 's3:DeleteBucketPolicy'], bucketArn(c, r.Properties.Bucket)),
  'AWS::DynamoDB::Table': (r, id, c) => {
    const table = `arn:aws:dynamodb:${REGION}:${c.account}:table/${physical(c, id, 'TableName')}`;
    return [
      ...each(
        [
          'dynamodb:CreateTable', 'dynamodb:DescribeTable', 'dynamodb:UpdateTable', 'dynamodb:DeleteTable',
          'dynamodb:UpdateContinuousBackups', 'dynamodb:DescribeContinuousBackups', 'dynamodb:UpdateTimeToLive',
          'dynamodb:DescribeTimeToLive', 'dynamodb:PutResourcePolicy', 'dynamodb:GetResourcePolicy',
          'dynamodb:TagResource', 'dynamodb:ListTagsOfResource',
        ],
        table,
      ),
      ...((r.Properties.GlobalSecondaryIndexes ?? []) as Json[]).flatMap((g) => each(['dynamodb:UpdateTable'], `${table}/index/${g.IndexName}`)),
    ];
  },
  // DNS validation: CloudFormation writes the validation CNAME into the zone with the caller's credentials.
  'AWS::CertificateManager::Certificate': (r, _id, c) => [
    ...each(
      ['acm:RequestCertificate', 'acm:DescribeCertificate', 'acm:DeleteCertificate', 'acm:AddTagsToCertificate', 'acm:ListTagsForCertificate'],
      `arn:aws:acm:${REGION}:${c.account}:certificate/11111111-aaaa-bbbb-cccc-dddddddddddd`,
    ),
    ...((r.Properties.DomainValidationOptions ?? []) as Json[]).flatMap((o) =>
      route53Change(`_0123456789abcdef.${o.DomainName}.`, 'CNAME', typeof o.HostedZoneId === 'string' ? o.HostedZoneId : '<unresolved zone>'),
    ),
  ],
  'AWS::Route53::RecordSet': (r) =>
    route53Change(
      typeof r.Properties.Name === 'string' ? r.Properties.Name : '<unresolved name>',
      r.Properties.Type,
      typeof r.Properties.HostedZoneId === 'string' ? r.Properties.HostedZoneId : '<unresolved zone>',
    ),
  'AWS::CloudFront::Distribution': (_r, _id, c) =>
    each(
      ['cloudfront:CreateDistribution', 'cloudfront:CreateDistributionWithTags', 'cloudfront:UpdateDistribution', 'cloudfront:DeleteDistribution', 'cloudfront:GetDistribution', 'cloudfront:TagResource'],
      `arn:aws:cloudfront::${c.account}:distribution/E1DUMMY`,
    ),
  'AWS::CloudFront::CachePolicy': (_r, _id, c) =>
    each(['cloudfront:CreateCachePolicy', 'cloudfront:GetCachePolicy', 'cloudfront:UpdateCachePolicy', 'cloudfront:DeleteCachePolicy'], `arn:aws:cloudfront::${c.account}:cache-policy/dummy`),
  'AWS::CloudFront::ResponseHeadersPolicy': (_r, _id, c) =>
    each(
      ['cloudfront:CreateResponseHeadersPolicy', 'cloudfront:GetResponseHeadersPolicy', 'cloudfront:UpdateResponseHeadersPolicy', 'cloudfront:DeleteResponseHeadersPolicy'],
      `arn:aws:cloudfront::${c.account}:response-headers-policy/dummy`,
    ),
  'AWS::CloudFront::OriginAccessControl': (_r, _id, c) =>
    each(
      ['cloudfront:CreateOriginAccessControl', 'cloudfront:GetOriginAccessControl', 'cloudfront:UpdateOriginAccessControl', 'cloudfront:DeleteOriginAccessControl'],
      `arn:aws:cloudfront::${c.account}:origin-access-control/dummy`,
    ),
  'AWS::Logs::LogGroup': (_r, id, c) => [
    ...each(
      ['logs:CreateLogGroup', 'logs:DeleteLogGroup', 'logs:PutRetentionPolicy', 'logs:DeleteRetentionPolicy', 'logs:TagResource'],
      `arn:aws:logs:${REGION}:${c.account}:log-group:${physical(c, id, 'LogGroupName')}`,
    ),
    ...each(['logs:DescribeLogGroups', 'logs:ListTagsForResource'], `arn:aws:logs:${REGION}:${c.account}:log-group:*`),
  ],
  'AWS::Lambda::Function': (r, id, c) => [
    ...each(
      [
        'lambda:CreateFunction', 'lambda:DeleteFunction', 'lambda:GetFunction', 'lambda:GetFunctionConfiguration',
        'lambda:UpdateFunctionCode', 'lambda:UpdateFunctionConfiguration', 'lambda:TagResource', 'lambda:ListTags',
      ],
      `arn:aws:lambda:${REGION}:${c.account}:function:${physical(c, id, 'FunctionName')}`,
    ),
    ...each(['iam:PassRole'], roleArn(c, r.Properties.Role)),
    ...assetRead(c, r.Properties.Code),
    ...((r.Properties.Layers ?? []) as Json[]).flatMap((l) =>
      each(['lambda:GetLayerVersion'], `arn:aws:lambda:${REGION}:${c.account}:layer:${physical(c, logicalId(l), 'LayerName')}:1`),
    ),
  ],
  'AWS::Lambda::Permission': (r, _id, c) =>
    each(['lambda:AddPermission', 'lambda:RemovePermission', 'lambda:GetPolicy'], functionArn(c, r.Properties.FunctionName)),
  'AWS::Lambda::LayerVersion': (r, id, c) => [
    ...each(
      ['lambda:PublishLayerVersion', 'lambda:GetLayerVersion', 'lambda:DeleteLayerVersion'],
      `arn:aws:lambda:${REGION}:${c.account}:layer:${physical(c, id, 'LayerName')}`,
    ),
    ...each(['lambda:GetLayerVersion', 'lambda:DeleteLayerVersion'], `arn:aws:lambda:${REGION}:${c.account}:layer:${physical(c, id, 'LayerName')}:1`),
    ...assetRead(c, r.Properties.Content),
  ],
  // The custom resource of BucketDeployment: CloudFormation invokes its provider function.
  'Custom::CDKBucketDeployment': (r, _id, c) => each(['lambda:InvokeFunction'], functionArn(c, r.Properties.ServiceToken)),
  'AWS::IAM::Role': (r, id, c) => {
    const role = `arn:aws:iam::${c.account}:role/${physical(c, id, 'RoleName')}`;
    return [
      ...each(['iam:CreateRole', 'iam:DeleteRole', 'iam:GetRole', 'iam:TagRole', 'iam:UntagRole', 'iam:UpdateRole', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies'], role),
      ...((r.Properties.ManagedPolicyArns ?? []) as Json[]).flatMap((p) =>
        each(['iam:AttachRolePolicy', 'iam:DetachRolePolicy'], role, { 'iam:PolicyARN': [flat(p)] }),
      ),
      ...(r.Properties.Policies ? each(['iam:PutRolePolicy', 'iam:DeleteRolePolicy', 'iam:GetRolePolicy'], role) : []),
    ];
  },
  'AWS::IAM::Policy': (r, _id, c) =>
    ((r.Properties.Roles ?? []) as Json[]).flatMap((role) => each(['iam:PutRolePolicy', 'iam:GetRolePolicy', 'iam:DeleteRolePolicy'], roleArn(c, role))),
  'AWS::ApiGatewayV2::Api': apigw('/apis/abc123'),
  'AWS::ApiGatewayV2::Stage': apigw('/apis/abc123/stages/$default'),
  'AWS::ApiGatewayV2::Integration': apigw('/apis/abc123/integrations/def456'),
  'AWS::ApiGatewayV2::Route': apigw('/apis/abc123/routes/ghi789'),
  'AWS::ApiGatewayV2::DomainName': apigw('/domainnames/api.example.test'),
  'AWS::ApiGatewayV2::ApiMapping': apigw('/domainnames/api.example.test/apimappings/jkl012'),
};

// ---------------------------------------------------------------------------------------------------------------
// The check.
// ---------------------------------------------------------------------------------------------------------------

interface Report {
  unmapped: string[];
  failures: string[];
  types: Set<string>;
  needCount: number;
}

/** Walk templates ({stackName: template json}) and evaluate every need against the policy. */
export function check(stage: Stage, templates: Record<string, Json>, policy: Json): Report {
  const report: Report = { unmapped: [], failures: [], types: new Set(), needCount: 0 };
  const verify = (where: string, n: Need) => {
    report.needCount++;
    const v = decide(policy, n.action, n.resource, n.ctx);
    if (v !== 'allowed') report.failures.push(`${where}: ${n.action} on ${n.resource} ${JSON.stringify(n.ctx ?? {})} -> ${v}`);
  };
  for (const [stackName, template] of Object.entries(templates)) {
    const c: Ctx = { stage, account: DUMMY_ACCOUNT, stackName, template };
    // Every CDK stack template checks the bootstrap version through an SSM parameter CloudFormation reads as the exec role.
    for (const [pname, p] of Object.entries<Json>(template.Parameters ?? {})) {
      if (String(p.Type).startsWith('AWS::SSM::Parameter::Value')) {
        verify(`${stackName} parameter ${pname}`, { action: 'ssm:GetParameters', resource: `arn:aws:ssm:${REGION}:${c.account}:parameter${p.Default}` });
      }
    }
    for (const [id, r] of Object.entries<Json>(template.Resources ?? {})) {
      report.types.add(r.Type);
      const needs = REQUIRED[r.Type];
      if (!needs) {
        report.unmapped.push(`${stackName} ${id}: ${r.Type}`);
        continue;
      }
      for (const n of needs(r, id, c)) verify(`${stackName} ${id} (${r.Type})`, n);
    }
  }
  return report;
}

const templatesOf = (stage: Stage): Record<string, Json> => {
  const s = build(stage);
  return Object.fromEntries(Object.values(s).map((st) => [st.stackName, Template.fromStack(st).toJSON()]));
};

describe.each(STAGES)('cfn-exec policy covers the %s stacks', (stage) => {
  const templates = templatesOf(stage);
  const policy = renderPolicy(stage);
  const report = check(stage, templates, policy);

  test('every resource type in the synthesized stacks is in the reviewed map', () => {
    expect(report.unmapped).toEqual([]);
  });

  test('the test sees the resource types that broke the first deploy', () => {
    for (const t of ['AWS::Route53::RecordSet', 'AWS::CertificateManager::Certificate', 'AWS::Lambda::Function', 'AWS::IAM::Role', 'Custom::CDKBucketDeployment']) {
      expect(report.types).toContain(t);
    }
    expect(report.needCount).toBeGreaterThan(150);
    // the bootstrap-version rule is what failed first: every stack template must carry it, or the ssm check above is blind
    for (const t of Object.values(templates)) {
      expect(t.Parameters?.BootstrapVersion?.Default).toBe('/cdk-bootstrap/hnb659fds/version');
    }
  });

  test('the rendered policy allows every action CloudFormation needs, on the right resource, and no Deny blocks one', () => {
    expect(report.failures).toEqual([]);
  });

  test('each statement added for these stacks is load-bearing: without it the check fails', () => {
    const added = ['LambdaLayers', 'LogGroupMetadata', 'CdkBootstrapVersionParameter', 'CdkAssetsRead', 'Route53RecordsInStageZone', 'Route53ReadOnly', 'Route53ChangeStatus'];
    for (const sid of added) {
      expect(policy.Statement.some((s: Json) => s.Sid === sid)).toBe(true);
      const without = { ...policy, Statement: policy.Statement.filter((s: Json) => s.Sid !== sid) };
      expect({ sid, failing: check(stage, templates, without).failures.length > 0 }).toEqual({ sid, failing: true });
    }
  });

  test('an unmapped resource type is reported', () => {
    const fake = { 'mopm-x-fake': { Resources: { Q: { Type: 'AWS::Foo::Bar', Properties: {} } } } };
    expect(check(stage, fake, policy).unmapped).toEqual(['mopm-x-fake Q: AWS::Foo::Bar']);
  });
});

describe.each(STAGES)('cfn-exec policy scope %s', (stage) => {
  const policy = renderPolicy(stage);
  const other = stage === 'beta' ? 'gamma' : 'beta';
  const rec = (name: string, type: string) => ({
    'route53:ChangeResourceRecordSetsNormalizedRecordNames': [name],
    'route53:ChangeResourceRecordSetsRecordTypes': [type],
  });
  const zone = 'arn:aws:route53:::hostedzone/Z0DUMMYZONE';
  const change = (name: string, type: string) => decide(policy, 'route53:ChangeResourceRecordSets', zone, rec(name, type));

  test('record changes are allowed for the stage zone and its hosts, as A, AAAA and CNAME only', () => {
    for (const name of [ZONE[stage], `api.${ZONE[stage]}`, `_abc.conda.${ZONE[stage]}`]) {
      for (const type of ['A', 'AAAA', 'CNAME']) expect(change(name, type)).toBe('allowed');
    }
    for (const type of ['NS', 'SOA', 'MX', 'TXT']) expect(change(`api.${ZONE[stage]}`, type)).toBe('not allowed');
  });

  test('record changes outside the stage zone are refused', () => {
    expect(change('example.com', 'A')).toBe('not allowed');
    expect(change('evilmopm.dev', 'A')).toBe('not allowed');
    expect(change(`api.${ZONE[other]}`, 'A')).toBe(stage === 'prod' ? 'allowed' : 'not allowed'); // prod's zone holds the delegations by design
    // a request touching one allowed and one foreign name is refused (ForAllValues)
    expect(
      decide(policy, 'route53:ChangeResourceRecordSets', zone, {
        'route53:ChangeResourceRecordSetsNormalizedRecordNames': [`api.${ZONE[stage]}`, 'example.com'],
        'route53:ChangeResourceRecordSetsRecordTypes': ['A'],
      }),
    ).toBe('not allowed');
  });

  test('delegations in the prod zone cannot be rewritten (NS records are refused)', () => {
    expect(change('beta.mopm.dev', 'NS')).toBe('not allowed');
    expect(change('gamma.mopm.dev', 'NS')).toBe('not allowed');
  });

  test('zone-level Route 53 operations are not granted', () => {
    for (const a of ['route53:CreateHostedZone', 'route53:DeleteHostedZone', 'route53:UpdateHostedZoneComment', 'route53:AssociateVPCWithHostedZone']) {
      expect(decide(policy, a, zone)).toBe('not allowed');
    }
  });

  test('the bootstrap version parameter is readable, other parameters are not', () => {
    const p = (n: string) => `arn:aws:ssm:${REGION}:${DUMMY_ACCOUNT}:parameter${n}`;
    expect(decide(policy, 'ssm:GetParameters', p('/cdk-bootstrap/hnb659fds/version'))).toBe('allowed');
    expect(decide(policy, 'ssm:GetParameters', p('/mopm/secret'))).toBe('not allowed');
    expect(decide(policy, 'ssm:PutParameter', p('/cdk-bootstrap/hnb659fds/version'))).toBe('not allowed');
  });

  test('asset reads are limited to the bootstrap assets bucket of this account', () => {
    expect(decide(policy, 's3:GetObject', `arn:aws:s3:::cdk-hnb659fds-assets-${DUMMY_ACCOUNT}-${REGION}/x.zip`)).toBe('allowed');
    expect(decide(policy, 's3:GetObject', `arn:aws:s3:::cdk-hnb659fds-assets-${'2'.repeat(12)}-${REGION}/x.zip`)).toBe('not allowed');
    expect(decide(policy, 's3:PutObject', `arn:aws:s3:::cdk-hnb659fds-assets-${DUMMY_ACCOUNT}-${REGION}/x.zip`)).toBe('not allowed');
    expect(decide(policy, 's3:GetObject', 'arn:aws:s3:::some-other-bucket/x')).toBe('not allowed');
  });

  test('other stages\' named resources stay out of reach', () => {
    expect(decide(policy, 's3:CreateBucket', `arn:aws:s3:::mopm-${other}-channel-${DUMMY_ACCOUNT}`)).toBe('not allowed');
    expect(decide(policy, 'dynamodb:CreateTable', `arn:aws:dynamodb:${REGION}:${DUMMY_ACCOUNT}:table/mopm-${other}-users`)).toBe('not allowed');
  });

  test('the two Deny statements are exactly the reviewed ones (adding permissions never edits them)', () => {
    const deny = policy.Statement.filter((s: Json) => s.Effect === 'Deny');
    expect(deny).toEqual([
      {
        Sid: 'NeverTouchAccessOrIdentity',
        Effect: 'Deny',
        Action: [
          'iam:CreateUser', 'iam:CreateAccessKey', 'iam:CreateLoginProfile', 'iam:PutUserPolicy', 'iam:AttachUserPolicy',
          'iam:CreateOpenIDConnectProvider', 'iam:UpdateAssumeRolePolicy', 'organizations:*', 'account:*',
        ],
        Resource: '*',
      },
      {
        Sid: 'ProtectAccessRolesAndBootstrap',
        Effect: 'Deny',
        Action: ['iam:*'],
        Resource: [
          `arn:aws:iam::${DUMMY_ACCOUNT}:role/mopm-${stage}-deploy`,
          `arn:aws:iam::${DUMMY_ACCOUNT}:role/mopm-${stage}-e2e`,
          `arn:aws:iam::${DUMMY_ACCOUNT}:role/cdk-hnb659fds-*`,
          `arn:aws:iam::${DUMMY_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com`,
          `arn:aws:iam::${DUMMY_ACCOUNT}:policy/mopm-${stage}-cfn-exec`,
        ],
      },
    ]);
  });

  test('the access roles and the OIDC provider are still denied, whatever is allowed', () => {
    expect(decide(policy, 'iam:UpdateRole', `arn:aws:iam::${DUMMY_ACCOUNT}:role/mopm-${stage}-deploy`)).toBe('denied by ProtectAccessRolesAndBootstrap');
    expect(decide(policy, 'iam:CreateOpenIDConnectProvider', `arn:aws:iam::${DUMMY_ACCOUNT}:oidc-provider/x`)).toBe('denied by NeverTouchAccessOrIdentity');
  });

  test('dummy zone id constant is the one the templates carry', () => {
    expect(zone.endsWith(DUMMY_ZONE_ID)).toBe(true);
  });
});
