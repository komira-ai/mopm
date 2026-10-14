import { Match } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import { TABLES } from '../lib/data-stack';
import { exemptRoles, tpl } from './util';

describe.each(STAGES)('DataStack %s', (stage) => {
  const { data: t } = tpl(stage);
  const tables = Object.values(t.findResources('AWS::DynamoDB::Table')) as any[];

  test('one table per entity with the expected names', () => {
    expect(tables.map((r) => r.Properties.TableName).sort()).toEqual(
      TABLES.map((d) => `mopm-${stage}-${d.id}`).sort(),
    );
    for (const id of ['packages', 'versions', 'owners', 'users', 'tokens', 'trusted_publishers', 'audit']) {
      expect(TABLES.map((d) => d.id)).toContain(id);
    }
  });

  test('every table is on-demand, has PITR and AWS-managed encryption', () => {
    for (const r of tables) {
      expect(r.Properties.BillingMode).toBe('PAY_PER_REQUEST');
      expect(r.Properties.PointInTimeRecoverySpecification).toEqual({ PointInTimeRecoveryEnabled: true });
      expect(r.Properties.SSESpecification).toMatchObject({ SSEEnabled: true });
    }
  });

  test('versions is keyed on name + version; tokens on the hash only', () => {
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-versions`,
      KeySchema: [{ AttributeName: 'name', KeyType: 'HASH' }, { AttributeName: 'version', KeyType: 'RANGE' }],
    });
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-tokens`,
      KeySchema: [{ AttributeName: 'token_hash', KeyType: 'HASH' }],
      TimeToLiveSpecification: { AttributeName: 'expires_at', Enabled: true },
    });
  });

  test('deletion protection and retention only on prod', () => {
    for (const r of tables) {
      expect(Boolean(r.Properties.DeletionProtectionEnabled)).toBe(stage === 'prod');
      expect(r.DeletionPolicy).toBe(stage === 'prod' ? 'Retain' : 'Delete');
    }
  });

  test('DeleteItem is denied to everyone except the named roles; audit is append-only', () => {
    for (const r of tables) {
      const stmt = r.Properties.ResourcePolicy.PolicyDocument.Statement[0];
      expect(stmt.Effect).toBe('Deny');
      expect(stmt.Action).toBe('dynamodb:DeleteItem');
      expect(stmt.Principal).toEqual({ AWS: '*' });
      if (r.Properties.TableName === `mopm-${stage}-audit`) {
        expect(stmt.Condition).toBeUndefined();
      } else {
        expect(exemptRoles(stmt)).toEqual(stage === 'prod' ? ['takedown'] : ['cleanup', 'takedown']);
      }
    }
  });

  test('owners has a by-github-id index', () => {
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-owners`,
      GlobalSecondaryIndexes: Match.arrayWith([Match.objectLike({ IndexName: 'by_github_id' })]),
    });
  });
});
