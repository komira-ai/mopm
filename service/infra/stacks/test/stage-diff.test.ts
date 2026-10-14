import { STAGES, Stage } from '../lib/config';
import { bucketStatements, exemptRoles, tpl } from './util';

// The settings that may legitimately differ between stages, summarised from the synthesized templates.
function settings(stage: Stage): Record<string, unknown> {
  const t = tpl(stage);
  const tables = Object.values(t.data.findResources('AWS::DynamoDB::Table')) as any[];
  const uniq = (xs: unknown[]) => [...new Set(xs.map((x) => JSON.stringify(x)))].sort().join('|');
  const del = bucketStatements(t.channel).find((x) => x.Sid === 'DenyDeleteExceptNamedRoles');
  const tableDel = tables
    .filter((r) => !String(r.Properties.TableName).endsWith('-audit'))
    .map((r) => exemptRoles(r.Properties.ResourcePolicy.PolicyDocument.Statement[0]));
  const bucketRetention = (tt: any) =>
    uniq(Object.values(tt.findResources('AWS::S3::Bucket')).map((r: any) => r.DeletionPolicy));
  return {
    'channel.bucket.deletionPolicy': bucketRetention(t.channel),
    'site.bucket.deletionPolicy': bucketRetention(t.site),
    'data.tables.deletionPolicy': uniq(tables.map((r) => r.DeletionPolicy)),
    'data.tables.deletionProtection': uniq(tables.map((r) => Boolean(r.Properties.DeletionProtectionEnabled))),
    'data.tables.pitr': uniq(tables.map((r) => r.Properties.PointInTimeRecoverySpecification)),
    'data.tables.deleteExemptRoles': uniq(tableDel),
    'channel.bucket.deleteExemptRoles': exemptRoles(del).join(','),
    'channel.bucket.versioning': uniq(Object.values(t.channel.findResources('AWS::S3::Bucket')).map((r: any) => r.Properties.VersioningConfiguration)),
    'api.runtime': uniq(Object.values(t.api.findResources('AWS::Lambda::Function')).map((r: any) => r.Properties.Runtime)),
    'channel.cachePolicies': uniq(Object.values(t.channel.findResources('AWS::CloudFront::CachePolicy')).map((r: any) => ({ ...r.Properties.CachePolicyConfig, Name: 'x' }))),
  };
}

function diff(a: Record<string, unknown>, b: Record<string, unknown>): string[] {
  return Object.keys(a).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k])).sort();
}

// Exactly the settings that differ between a disposable stage and prod. Adding to this list is a reviewed decision.
const EXPECTED_PROD_DIFF = [
  'channel.bucket.deleteExemptRoles',
  'channel.bucket.deletionPolicy',
  'data.tables.deleteExemptRoles',
  'data.tables.deletionPolicy',
  'data.tables.deletionProtection',
  'site.bucket.deletionPolicy',
];

describe('stage diff', () => {
  const [beta, gamma, prod] = STAGES.map(settings);

  test('beta and gamma are configured identically', () => {
    expect(diff(beta, gamma)).toEqual([]);
  });

  test.each([['beta', beta], ['gamma', gamma]] as const)('%s differs from prod in exactly the expected settings', (_n, s) => {
    expect(diff(s, prod)).toEqual(EXPECTED_PROD_DIFF);
  });

  test('prod values', () => {
    expect(prod['data.tables.deletionProtection']).toBe('true');
    expect(prod['data.tables.deletionPolicy']).toBe('"Retain"');
    expect(prod['channel.bucket.deleteExemptRoles']).toBe('takedown');
  });

  test('beta values (disposable)', () => {
    expect(beta['data.tables.deletionProtection']).toBe('false');
    expect(beta['data.tables.deletionPolicy']).toBe('"Delete"');
    expect(beta['channel.bucket.deleteExemptRoles']).toBe('cleanup,takedown');
  });

  test('PITR and versioning are on in every stage', () => {
    for (const s of [beta, gamma, prod]) {
      expect(s['data.tables.pitr']).toBe('{"PointInTimeRecoveryEnabled":true}');
    }
  });
});
