import { Template } from 'aws-cdk-lib/assertions';
import { STAGES, Stage, stageConfig } from '../lib/config';
import { build } from './util';

// Whole-template stage diff. The summarised stage-diff test only watches named settings; this one compares every
// property of every resource in every stack, so a stage-dependent branch added anywhere (hosts, SSE, TLS policy,
// public-access blocks, API settings, log-group removal) shows up here and must be added to the list below on review.

const siteHost = (s: Stage) => stageConfig(s).siteDomain;

/** Replace the stage name and the stage's site host with tokens so only real differences remain. */
function normalise(stage: Stage, json: unknown): unknown {
  const host = siteHost(stage);
  const hostRe = new RegExp(`(?<![A-Za-z0-9-])${host.replace(/\./g, '\\.')}(?![A-Za-z0-9-])`, 'g');
  const stageRe = new RegExp(`(?<![A-Za-z0-9])${stage}(?![A-Za-z0-9])`, 'gi');
  const text = JSON.stringify(json)
    .replace(hostRe, '<site>')
    // CDK builds logical ids and generated names from the construct path, which contains the stage ("mopmbeta...").
    .replace(new RegExp(`mopm${stage}`, 'g'), 'mopm<stage>')
    .replace(stageRe, '<stage>')
    // ... and ends them with an 8-character hash of that path, which therefore differs per stage. A BucketDeployment
    // with a key prefix (the site's assets/) tags the bucket with the prefix before the hash.
    .replace(/aws-cdk:cr-owned:((?:[^:"]+:)?)[0-9a-f]{8}/g, 'aws-cdk:cr-owned:$1<hash>')
    .replace(/(?<=[A-Za-z0-9])[0-9A-F]{8}(?=")/g, '');
  return JSON.parse(text);
}

/** Set of "<stack>:<resource type>:<DeletionPolicy|UpdateReplacePolicy|Properties.X>" whose value differs from prod. */
function fingerprint(stage: Stage): Map<string, string> {
  const out = new Map<string, string>();
  const stacks = build(stage);
  for (const [name, stack] of Object.entries(stacks)) {
    const resources = Template.fromStack(stack).toJSON().Resources ?? {};
    for (const [logicalId, r] of Object.entries<any>(resources)) {
      const n = normalise(stage, r) as any;
      const id = normalise(stage, logicalId) as string;
      const props = n.Properties ?? {};
      const entries: [string, unknown][] = [
        ['present', r.Type],
        ...Object.entries(n)
          .filter(([k]) => k !== 'Properties' && k !== 'Type')
          .map(([k, v]) => [k, v] as [string, unknown]), // DeletionPolicy, UpdateReplacePolicy, DependsOn, Metadata, Condition, ...
        ...Object.entries(props).map(([k, v]) => [`Properties.${k}`, v] as [string, unknown]),
      ];
      for (const [k, v] of entries) out.set(`${name}:${r.Type}:${id}:${k}`, JSON.stringify(v ?? null));
    }
    // Every other template section (Outputs, Parameters, Conditions, Mappings, Rules, Description, ...): a
    // stage-dependent output or condition must not slip past a check that only looked at resources.
    const whole = Template.fromStack(stack).toJSON() as Record<string, any>;
    for (const [section, body] of Object.entries(whole)) {
      if (section === 'Resources') continue;
      const named = body && typeof body === 'object' && !Array.isArray(body) && section !== 'Metadata';
      if (named) {
        for (const [key, v] of Object.entries<any>(body)) {
          out.set(`${name}:${section}:${normalise(stage, key) as string}:value`, JSON.stringify(normalise(stage, v)));
        }
      } else {
        out.set(`${name}:${section}:-:value`, JSON.stringify(normalise(stage, body ?? null)));
      }
    }
  }
  return out;
}

function differing(a: Map<string, string>, b: Map<string, string>): string[] {
  const keys = new Set([...a.keys(), ...b.keys()]);
  const typeOnly = (k: string) => k.replace(/:[^:]*:([^:]*)$/, ':$1'); // drop the logical id
  const out = new Set<string>();
  for (const k of keys) {
    if ((a.get(k) ?? 'null') !== (b.get(k) ?? 'null')) {
      out.add(typeOnly(k));
      if (!EXPECTED_PROD_DIFF.includes(typeOnly(k))) {
        // Unexpected difference: show both values so the failure is diagnosable from the CI log alone.
        console.log(`DIFF ${k}\n  a=${(a.get(k) ?? 'null').slice(0, 400)}\n  b=${(b.get(k) ?? 'null').slice(0, 400)}`);
      }
    }
  }
  return [...out].sort();
}

// Every difference between a disposable stage and prod. Adding to this list is a reviewed decision.
// The packages name-search index (data:AWS::DynamoDB::Table:Properties.GlobalSecondaryIndexes) adds no entry: its
// keys, projection and name are the same in every stage (no stage-dependent setting), so it is in the shared template
// and the "identical modulo names" checks below cover it. The 'search index is the same in every stage' test pins that.
const EXPECTED_PROD_DIFF = [
  // The API function's Environment: prod has CI_PUBLISHERS (the CI identity that acts for an account), gamma has no such variable;
  // the next describe pins that this is the one variable by which their Environments differ.
  'api:AWS::Lambda::Function:Properties.Environment',
  'api:AWS::Logs::LogGroup:DeletionPolicy',
  'api:AWS::Logs::LogGroup:UpdateReplacePolicy',
  'channel:AWS::S3::Bucket:DeletionPolicy',
  'channel:AWS::S3::Bucket:UpdateReplacePolicy',
  'channel:AWS::S3::BucketPolicy:Properties.PolicyDocument',
  'data:AWS::DynamoDB::Table:DeletionPolicy',
  'data:AWS::DynamoDB::Table:Properties.DeletionProtectionEnabled',
  'data:AWS::DynamoDB::Table:Properties.ResourcePolicy',
  'data:AWS::DynamoDB::Table:UpdateReplacePolicy',
  'publish:AWS::Logs::LogGroup:DeletionPolicy',
  'publish:AWS::Logs::LogGroup:UpdateReplacePolicy',
  'site:AWS::S3::Bucket:DeletionPolicy',
  'site:AWS::S3::Bucket:UpdateReplacePolicy',
].sort();

// What only the beta stage has: two variables of the API function (its Environment), CI_PUBLISHERS and MOPM_GROUPS_POLICY, and
// nothing else (the next describe pins that the Environment differs in exactly those two). The role's policy is identical on every
// stage (package creation is the claim route's grant). Config-as-code trust is beta's alone, so this is the whole of beta's
// difference from gamma. Adding to this list is a reviewed decision.
const EXPECTED_BETA_ONLY_DIFF = ['api:AWS::Lambda::Function:Properties.Environment'];
const EXPECTED_BETA_ONLY_ENV = ['CI_PUBLISHERS', 'MOPM_GROUPS_POLICY'];
// What prod has that gamma does not: CI_PUBLISHERS, whose one row acts for an account (the stack test pins the row). No groups policy.
const EXPECTED_PROD_ONLY_ENV = ['CI_PUBLISHERS'];

/** The names of the environment variables of the API function (the one with the stage's OAuth secret name) on a stage. */
function apiEnvNames(stage: Stage): string[] {
  const fns = Object.values(Template.fromStack(build(stage).api).findResources('AWS::Lambda::Function')) as any[];
  const api = fns.filter((f) => f.Properties.Environment?.Variables?.MOPM_OAUTH_SECRET_NAME !== undefined);
  expect(api).toHaveLength(1);
  return Object.keys(api[0].Properties.Environment.Variables).sort();
}

describe('whole-template stage diff', () => {
  const [beta, gamma, prod] = STAGES.map(fingerprint);

  test('beta and gamma synthesize identical templates (modulo names and hosts), except for the beta-only CI trust', () => {
    expect(differing(beta, gamma)).toEqual(EXPECTED_BETA_ONLY_DIFF);
  });

  test('gamma differs from prod only in the expected properties', () => {
    expect(differing(gamma, prod)).toEqual(EXPECTED_PROD_DIFF);
  });

  test('beta differs from prod in the expected properties and the beta-only CI trust', () => {
    expect(differing(beta, prod)).toEqual([...new Set([...EXPECTED_PROD_DIFF, ...EXPECTED_BETA_ONLY_DIFF])].sort());
  });
});

describe('the environment of the API function per stage', () => {
  const [beta, gamma, prod] = STAGES.map(apiEnvNames);

  test('beta has exactly two variables that gamma does not, the two beta-only ones, and gamma has none that beta lacks', () => {
    expect(beta!.filter((n) => !gamma!.includes(n))).toEqual(EXPECTED_BETA_ONLY_ENV);
    expect(gamma!.filter((n) => !beta!.includes(n))).toEqual([]);
  });

  test('prod has exactly one variable that gamma does not, CI_PUBLISHERS, and gamma has none that prod lacks', () => {
    expect(prod!.filter((n) => !gamma!.includes(n))).toEqual(EXPECTED_PROD_ONLY_ENV);
    expect(gamma!.filter((n) => !prod!.includes(n))).toEqual([]);
  });

  test('neither gamma nor prod has the beta-only groups policy', () => {
    expect(gamma).not.toContain('MOPM_GROUPS_POLICY');
    expect(prod).not.toContain('MOPM_GROUPS_POLICY');
    expect(gamma).not.toContain('CI_PUBLISHERS');
  });
});

describe('search index per stage', () => {
  test('the packages search index is byte-identical in every stage', () => {
    const indexes = STAGES.map((s) => {
      const tables = Object.values(Template.fromStack(build(s).data).findResources('AWS::DynamoDB::Table')) as any[];
      return JSON.stringify(tables.find((r) => r.Properties.TableName === `mopm-${s}-packages`).Properties.GlobalSecondaryIndexes);
    });
    expect(indexes[0]).toContain('by_search_bucket');
    expect(new Set(indexes).size).toBe(1);
  });
});

describe('hosts per stage', () => {
  const expected: Record<Stage, string[]> = {
    beta: ['beta.mopm.dev', 'conda.beta.mopm.dev', 'api.beta.mopm.dev'],
    gamma: ['gamma.mopm.dev', 'conda.gamma.mopm.dev', 'api.gamma.mopm.dev'],
    prod: ['mopm.dev', 'conda.mopm.dev', 'api.mopm.dev'],
  };
  test.each(STAGES)('%s hosts', (stage) => {
    const c = stageConfig(stage);
    expect([c.siteDomain, c.condaDomain, c.apiDomain]).toEqual(expected[stage]);
  });
});
