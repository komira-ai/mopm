import { Stack, StackProps } from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { StageConfig, isDisposable, tableName } from './config';
import { anyone, assertRegion, deleteAllowedRoleArns, notNamedRoles, removalPolicyFor } from './common';

export interface DataStackProps extends StackProps {
  config: StageConfig;
}

const S = dynamodb.AttributeType.STRING;

interface TableDef {
  id: string;
  pk: string;
  sk?: string;
  /** Attribute holding an epoch-seconds expiry. DynamoDB TTL is lazy cleanup only; code checks expiry on every read. */
  ttl?: string;
  /** A global secondary index. `include` projects only those attributes (plus the keys); absent projects everything. */
  gsi?: { name: string; pk: string; sk?: string; include?: string[] };
  /** Rows are never deleted by anyone (append-only). */
  appendOnly?: boolean;
}

/** Tables from the design (data model). Versions are create-once via conditional writes in code. */
export const TABLES: TableDef[] = [
  // Name search (service/api/src/dynamo-store.ts, SEARCH_INDEX, writes `search_bucket` and reads this index): every
  // row has the same `search_bucket`, so a prefix search is one Query with begins_with on `name`, in name order. One
  // partition is deliberate: a GSI partition serves ~3000 reads a second, far above search traffic over thousands of
  // names, and "browse everything" stays a single ordered Query. The index is sparse: a row without the attribute
  // (written before this index existed) is not searchable until it is backfilled. Projection is what a search result
  // shows, so the Lambda never reads the table for it; repository and license stay out of the index.
  { id: 'packages', pk: 'name', gsi: { name: 'by_search_bucket', pk: 'search_bucket', sk: 'name', include: ['description', 'state', 'created_at'] } },
  { id: 'versions', pk: 'name', sk: 'version' },
  { id: 'owners', pk: 'name', sk: 'github_id', gsi: { name: 'by_github_id', pk: 'github_id', sk: 'name' } },
  { id: 'invitations', pk: 'id', ttl: 'expires_at' },
  { id: 'users', pk: 'github_id' },
  { id: 'uploads', pk: 'upload_id', ttl: 'expires_at' },
  { id: 'tokens', pk: 'token_hash', ttl: 'expires_at' },
  { id: 'trusted_publishers', pk: 'name', sk: 'publisher' },
  { id: 'audit', pk: 'name', sk: 'ts_seq', appendOnly: true },
  { id: 'reserved_names', pk: 'name' },
];

export class DataStack extends Stack {
  readonly tables: Record<string, dynamodb.Table> = {};

  constructor(scope: Construct, id: string, props: DataStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;
    const prod = !isDisposable(c.stage);
    const allowed = deleteAllowedRoleArns(this, c);

    for (const d of TABLES) {
      const t = new dynamodb.Table(this, d.id, {
        tableName: tableName(c.stage, d.id),
        partitionKey: { name: d.pk, type: S },
        ...(d.sk ? { sortKey: { name: d.sk, type: S } } : {}),
        billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
        pointInTimeRecovery: true,
        deletionProtection: prod,
        encryption: dynamodb.TableEncryption.AWS_MANAGED,
        removalPolicy: removalPolicyFor(c),
        ...(d.ttl ? { timeToLiveAttribute: d.ttl } : {}),
      });
      if (d.gsi) {
        t.addGlobalSecondaryIndex({
          indexName: d.gsi.name,
          partitionKey: { name: d.gsi.pk, type: S },
          ...(d.gsi.sk ? { sortKey: { name: d.gsi.sk, type: S } } : {}),
          ...(d.gsi.include
            ? { projectionType: dynamodb.ProjectionType.INCLUDE, nonKeyAttributes: d.gsi.include }
            : { projectionType: dynamodb.ProjectionType.ALL }),
        });
      }

      // Resource policy: nobody deletes rows except the named roles; audit is append-only for everyone.
      const stmt = new iam.PolicyStatement({
        sid: 'DenyDeleteItem',
        effect: iam.Effect.DENY,
        principals: [anyone()],
        actions: ['dynamodb:DeleteItem'],
        resources: ['*'],
        ...(d.appendOnly ? {} : { conditions: notNamedRoles(allowed) }),
      });
      (t.node.defaultChild as dynamodb.CfnTable).addPropertyOverride('ResourcePolicy', {
        PolicyDocument: new iam.PolicyDocument({ statements: [stmt] }).toJSON(),
      });
      this.tables[d.id] = t;
    }
  }
}
