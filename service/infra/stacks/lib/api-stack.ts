import * as fs from 'fs';
import * as path from 'path';
import { Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import { Construct } from 'constructs';
import { StageConfig, channelBucketName, tableName, validateQueueName } from './config';
import { assertRegion, lookupZone, removalPolicyFor } from './common';

export interface ApiStackProps extends StackProps {
  config: StageConfig;
  /** Release version reported by /api/v1/health. */
  version: string;
  /** Git commit the release was built from, reported by /api/v1/health so e2e can prove what is deployed. */
  commit: string;
  /** Directory holding the built handler (`http/lambda.js`). Defaults to service/api/dist; tests pass a stub. */
  handlerDir?: string;
  /** New uploads are refused and /health says so. (The runtime switch is the `read_only` item of the config table.) */
  readOnly?: boolean;
  /** Rate limits of begin-upload per UTC day; the code's defaults (generous) apply when absent. */
  limits?: { ratePerAccountPerDay?: number; ratePerTokenPerDay?: number };
}

/**
 * Where the CI-built handler bundle lives (`npm run build` in service/api writes `dist/`). It is not committed:
 * service-ci.yml and deploy.yml build it before they synthesize or deploy.
 */
export const DEFAULT_HANDLER_DIR = path.resolve(__dirname, '../../../api/dist');

/** The read-only tables the handler may use. Grants are GetItem and Query: never a write, never a Scan. */
export const READ_TABLES = ['packages', 'versions', 'owners', 'audit'] as const;
/** The read operations of spec/api/openapi.yaml served by the handler. */
export const READ_ROUTES = [
  '/api/v1/health',
  '/api/v1/packages',
  '/api/v1/packages/{name}',
  '/api/v1/packages/{name}/versions',
];
export const READ_ACTIONS = ['dynamodb:GetItem', 'dynamodb:Query'];
/** The publish operations of spec/api/openapi.yaml: begin an upload, commit it, read a publish's status. */
export const PUBLISH_ROUTES: Array<{ method: apigw.HttpMethod; path: string }> = [
  { method: apigw.HttpMethod.POST, path: '/api/v1/packages/{name}/{version}/files' },
  { method: apigw.HttpMethod.POST, path: '/api/v1/packages/{name}/{version}/publish' },
  { method: apigw.HttpMethod.GET, path: '/api/v1/publishes/{publish_id}' },
];
/**
 * What the handler may write, table by table (the reviewed list; api.test.ts pins it). No DeleteItem, no Scan, no
 * UpdateItem except the last-used mark of a token. A new version is a transaction of two PutItems (version + audit).
 */
export const WRITE_GRANTS: Array<{ sid: string; actions: string[]; tables: string[] }> = [
  { sid: 'ReserveVersions', actions: ['dynamodb:PutItem'], tables: ['versions', 'audit'] },
  { sid: 'RecordUploadsAndPublishes', actions: ['dynamodb:GetItem', 'dynamodb:PutItem'], tables: ['uploads', 'publishes'] },
  { sid: 'AuthenticateTokens', actions: ['dynamodb:GetItem', 'dynamodb:UpdateItem'], tables: ['tokens'] },
  { sid: 'ReadSwitches', actions: ['dynamodb:GetItem'], tables: ['config'] },
];

export class ApiStack extends Stack {
  readonly api: apigw.HttpApi;
  readonly handler: lambda.Function;

  constructor(scope: Construct, id: string, props: ApiStackProps) {
    super(scope, id, props);
    assertRegion(this);
    const c = props.config;

    const logGroup = new logs.LogGroup(this, 'HandlerLogs', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: removalPolicyFor(c),
    });
    const handlerDir = props.handlerDir ?? DEFAULT_HANDLER_DIR;
    if (!fs.existsSync(handlerDir)) {
      throw new Error(`the API handler bundle is missing at ${handlerDir}; run 'npm ci && npm run build' in service/api first`);
    }
    this.handler = new lambda.Function(this, 'Handler', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'http/lambda.handler',
      // AWS SDK v3 comes with the Node.js 20 runtime, so the bundle is only this package's compiled code.
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 256,
      timeout: Duration.seconds(10),
      logGroup,
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_VERSION: props.version,
        MOPM_COMMIT: props.commit,
        MOPM_READ_ONLY: String(props.readOnly ?? false),
        // Where uploads go (a presigned PUT into quarantine/) and where a commit is queued. Built from names, not
        // references, so this stack does not depend on the publish stack's exports.
        MOPM_CHANNEL_BUCKET: channelBucketName(c.stage, this.account),
        MOPM_VALIDATE_QUEUE_URL: `https://sqs.${this.region}.amazonaws.com/${this.account}/${validateQueueName(c.stage)}`,
        ...(props.limits?.ratePerAccountPerDay !== undefined ? { MOPM_RATE_PER_ACCOUNT_DAY: String(props.limits.ratePerAccountPerDay) } : {}),
        ...(props.limits?.ratePerTokenPerDay !== undefined ? { MOPM_RATE_PER_TOKEN_DAY: String(props.limits.ratePerTokenPerDay) } : {}),
      },
    });

    // Read-only on the registry's tables (and their indexes): the read API never writes.
    const tableArns = READ_TABLES.map((t) => this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, t) }));
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadRegistryTables',
        actions: READ_ACTIONS,
        resources: [...tableArns, ...tableArns.map((a) => `${a}/index/*`)],
      }),
    );

    const arnOf = (t: string) => this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, t) });
    for (const g of WRITE_GRANTS) {
      this.handler.addToRolePolicy(new iam.PolicyStatement({ sid: g.sid, actions: g.actions, resources: g.tables.map(arnOf) }));
    }
    // Uploads: the URL is signed with this role, so the role must be allowed the PUT it signs, and commit looks at the
    // object it was told about (HEAD needs GetObject). Both only under quarantine/; nothing else in the bucket.
    const quarantine = `arn:aws:s3:::${channelBucketName(c.stage, this.account)}/quarantine/*`;
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'UploadToQuarantine', actions: ['s3:PutObject', 's3:GetObject'], resources: [quarantine] }),
    );
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'QueueCommits',
        actions: ['sqs:SendMessage'],
        resources: [this.formatArn({ service: 'sqs', resource: validateQueueName(c.stage) })],
      }),
    );

    const zone = lookupZone(this, c);
    const cert = new acm.Certificate(this, 'Cert', {
      domainName: c.apiDomain,
      validation: acm.CertificateValidation.fromDns(zone),
    });
    const domain = new apigw.DomainName(this, 'Domain', { domainName: c.apiDomain, certificate: cert });

    this.api = new apigw.HttpApi(this, 'Api', {
      apiName: `mopm-${c.stage}`,
      disableExecuteApiEndpoint: true,
      defaultDomainMapping: { domainName: domain },
    });
    const integration = new integrations.HttpLambdaIntegration('ApiIntegration', this.handler);
    for (const route of READ_ROUTES) {
      this.api.addRoutes({ path: route, methods: [apigw.HttpMethod.GET], integration });
    }
    for (const r of PUBLISH_ROUTES) this.api.addRoutes({ path: r.path, methods: [r.method], integration });

    const target = route53.RecordTarget.fromAlias(
      new targets.ApiGatewayv2DomainProperties(domain.regionalDomainName, domain.regionalHostedZoneId),
    );
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.apiDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.apiDomain, target });
  }
}
