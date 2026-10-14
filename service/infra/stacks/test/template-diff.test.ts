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
  const text = JSON.stringify(json).replace(hostRe, '<site>').replace(stageRe, '<stage>');
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
      const props = n.Properties ?? {};
      const entries: [string, unknown][] = [
        ['DeletionPolicy', n.DeletionPolicy],
        ['UpdateReplacePolicy', n.UpdateReplacePolicy],
        ...Object.entries(props).map(([k, v]) => [`Properties.${k}`, v] as [string, unknown]),
      ];
      for (const [k, v] of entries) out.set(`${name}:${r.Type}:${logicalId}:${k}`, JSON.stringify(v ?? null));
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
const EXPECTED_PROD_DIFF = [
  'api:AWS::Logs::LogGroup:DeletionPolicy',
  'api:AWS::Logs::LogGroup:UpdateReplacePolicy',
  'channel:AWS::S3::Bucket:DeletionPolicy',
  'channel:AWS::S3::Bucket:UpdateReplacePolicy',
  'channel:AWS::S3::BucketPolicy:Properties.PolicyDocument',
  'data:AWS::DynamoDB::Table:DeletionPolicy',
  'data:AWS::DynamoDB::Table:Properties.DeletionProtectionEnabled',
  'data:AWS::DynamoDB::Table:Properties.ResourcePolicy',
  'data:AWS::DynamoDB::Table:UpdateReplacePolicy',
  'site:AWS::S3::Bucket:DeletionPolicy',
  'site:AWS::S3::Bucket:UpdateReplacePolicy',
].sort();

describe('whole-template stage diff', () => {
  const [beta, gamma, prod] = STAGES.map(fingerprint);

  test('beta and gamma synthesize identical templates (modulo names and hosts)', () => {
    expect(differing(beta, gamma)).toEqual([]);
  });

  test.each([['beta', beta], ['gamma', gamma]] as const)('%s differs from prod only in the expected properties', (_n, s) => {
    expect(differing(s, prod)).toEqual(EXPECTED_PROD_DIFF);
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
