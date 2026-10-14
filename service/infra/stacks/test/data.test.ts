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
    for (const id of ['packages', 'versions', 'owners', 'users', 'tokens', 'device_logins', 'trusted_publishers', 'audit']) {
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

  test('packages has the name-search index: constant partition, name sort key, only what a result shows', () => {
    // Mirrors SEARCH_INDEX in service/api/src/dynamo-store.ts (search_bucket is written there, the Query reads this index).
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-packages`,
      GlobalSecondaryIndexes: [
        {
          IndexName: 'by_search_bucket',
          KeySchema: [{ AttributeName: 'search_bucket', KeyType: 'HASH' }, { AttributeName: 'name', KeyType: 'RANGE' }],
          Projection: { ProjectionType: 'INCLUDE', NonKeyAttributes: ['description', 'state', 'created_at'] },
        },
      ],
    });
    const packages = tables.find((r) => r.Properties.TableName === `mopm-${stage}-packages`);
    // Not the whole row: repository and license are never copied into the index.
    expect(JSON.stringify(packages.Properties.GlobalSecondaryIndexes)).not.toMatch(/repository|license|"ALL"/);
    // On-demand: the index needs no capacity of its own.
    expect(packages.Properties.GlobalSecondaryIndexes[0].ProvisionedThroughput).toBeUndefined();
  });

  test('owners has a by-github-id index', () => {
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-owners`,
      GlobalSecondaryIndexes: Match.arrayWith([Match.objectLike({ IndexName: 'by_github_id' })]),
    });
  });

  test('tokens is listed by account through one index (a table update may add only one index at a time)', () => {
    const tokens = tables.find((r) => r.Properties.TableName === `mopm-${stage}-tokens`);
    expect(tokens.Properties.GlobalSecondaryIndexes).toHaveLength(1);
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-tokens`,
      GlobalSecondaryIndexes: [
        Match.objectLike({
          IndexName: 'by_github_id',
          KeySchema: [{ AttributeName: 'github_id', KeyType: 'HASH' }, { AttributeName: 'id', KeyType: 'RANGE' }],
          Projection: { ProjectionType: 'ALL' },
        }),
      ],
    });
  });

  test('device logins are keyed by the hash of the code and expire by TTL', () => {
    t.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: `mopm-${stage}-device_logins`,
      KeySchema: [{ AttributeName: 'id', KeyType: 'HASH' }],
      TimeToLiveSpecification: { AttributeName: 'expires_at', Enabled: true },
    });
  });
});
