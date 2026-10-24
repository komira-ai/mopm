import * as fs from 'fs';
import * as path from 'path';
import { ArnFormat, Duration, Stack, StackProps } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import { Construct } from 'constructs';
import { StageConfig, channelBucketName, groupQueueName, indexQueueName, oauthSecretName, tableName, validateQueueName } from './config';
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
  /** Interactive publishing needs a GitHub account with two-factor authentication on (the CEO's rule). On unless set false. */
  require2fa?: boolean;
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
/**
 * The indexes the read statement may Query, by table. Only the search index: the read API never queries the owners index
 * (owners by_github_id); token creation does, and AUTH_GRANTS grants it there.
 */
export const READ_INDEXES: Record<string, string[]> = { packages: ['by_search_bucket'] };
/** The read operations of spec/api/openapi.yaml served by the handler. */
export const READ_ROUTES = [
  '/api/v1/health',
  '/api/v1/packages',
  '/api/v1/packages/{name}',
  '/api/v1/packages/{name}/versions',
  '/api/v1/packages/{name}/owners',
  '/api/v1/packages/{name}/{version}',
];
export const READ_ACTIONS = ['dynamodb:GetItem', 'dynamodb:Query'];
/** The publish operations of spec/api/openapi.yaml: begin an upload, commit it, read a publish's status. */
export const PUBLISH_ROUTES: Array<{ method: apigw.HttpMethod; path: string }> = [
  { method: apigw.HttpMethod.POST, path: '/api/v1/packages/{name}/{version}/files' },
  { method: apigw.HttpMethod.POST, path: '/api/v1/packages/{name}/{version}/publish' },
  { method: apigw.HttpMethod.GET, path: '/api/v1/publishes/{publish_id}' },
  { method: apigw.HttpMethod.PUT, path: '/api/v1/packages/{name}/{version}/yank' },
  // Groups: create, read, abort and commit. The handler answers `route_not_found` to a create until the stage's `groups_enabled` item admits the caller.
  { method: apigw.HttpMethod.POST, path: '/api/v1/groups' },
  { method: apigw.HttpMethod.GET, path: '/api/v1/groups/{group_id}' },
  { method: apigw.HttpMethod.DELETE, path: '/api/v1/groups/{group_id}' },
  // Commit: queues the group's validation on the group queue. Not gated by the groups switch (a group that exists is finished).
  { method: apigw.HttpMethod.POST, path: '/api/v1/groups/{group_id}/commit' },
];
/**
 * What the handler may write, table by table (the reviewed list; api.test.ts pins it). No DeleteItem, no Scan, no
 * UpdateItem. (The tokens table, including the last-used mark, is granted by AUTH_GRANTS.) A new version is a transaction of two PutItems (version + audit).
 */
export const WRITE_GRANTS: Array<{ sid: string; actions: string[]; tables: string[] }> = [
  { sid: 'ReserveVersions', actions: ['dynamodb:PutItem'], tables: ['versions', 'audit'] },
  { sid: 'RecordUploadsAndPublishes', actions: ['dynamodb:GetItem', 'dynamodb:PutItem'], tables: ['uploads', 'publishes'] },
  { sid: 'ReadSwitches', actions: ['dynamodb:GetItem'], tables: ['config'] },
];

/** The operations of spec/api/openapi.yaml for login, tokens and CI exchange. */
export const AUTH_ROUTES: { method: apigw.HttpMethod; path: string }[] = [
  { method: apigw.HttpMethod.POST, path: '/api/v1/auth/device' },
  { method: apigw.HttpMethod.POST, path: '/api/v1/auth/device/poll' },
  { method: apigw.HttpMethod.POST, path: '/api/v1/auth/oidc/exchange' },
  { method: apigw.HttpMethod.POST, path: '/api/v1/me/tokens' },
  { method: apigw.HttpMethod.GET, path: '/api/v1/me/tokens' },
  { method: apigw.HttpMethod.DELETE, path: '/api/v1/me/tokens/{token_id}' },
];

/**
 * What the handler may do on the auth tables, and nothing more. No table gets DeleteItem (the tables deny it to this
 * role anyway; expiry is DynamoDB TTL). `indexes` are the only indexes it may query.
 * - tokens: create (PutItem), read by hash (GetItem), mark used or revoked (UpdateItem), list by account (Query on the index).
 * - users: read and upsert a row at login.
 * - device_logins: start (PutItem), poll (GetItem), record the poll and consume (UpdateItem).
 * - trusted_publishers: read only; nothing in the Lambda registers publishers yet.
 * - owners: read, and Query on its by_github_id index (POST /me/tokens lists the packages the account owns). The table is
 *   also in READ_TABLES; an index is a separate resource, so the index ARN is granted here.
 */
export const AUTH_GRANTS: Record<string, { actions: string[]; indexes?: string[] }> = {
  tokens: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:UpdateItem', 'dynamodb:Query'], indexes: ['by_github_id'] },
  users: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem'] },
  device_logins: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:UpdateItem'] },
  trusted_publishers: { actions: ['dynamodb:GetItem', 'dynamodb:Query'] },
  owners: { actions: ['dynamodb:GetItem', 'dynamodb:Query'], indexes: ['by_github_id'] },
};

/** `GET /index/config.json` is built from code by the API Lambda; every other file under /index/ is read from the bucket by the reader. */
export const INDEX_CONFIG_ROUTE = 'GET /index/config.json';
export const INDEX_READER_ROUTE = 'GET /index/{proxy+}';
/**
 * The reader is unauthenticated and has no CDN in front, so each request is an invocation. The gateway throttles the two
 * index routes (requests per second, with a burst) so a scrape cannot take the account's Lambda concurrency from publish
 * and the read API. (A reservation on the function is not used: Lambda refuses one that leaves the unreserved pool under 10.)
 */
export const INDEX_THROTTLE = { rateLimit: 50, burstLimit: 100 };

/** Methods a browser may use on the read API. HEAD and OPTIONS are listed for preflight; only GET routes exist. */
export const CORS_METHODS = [apigw.CorsHttpMethod.GET, apigw.CorsHttpMethod.HEAD, apigw.CorsHttpMethod.OPTIONS];
/** How long a browser may cache a preflight answer. */
export const CORS_MAX_AGE = Duration.hours(1);
/** The response headers a page may read: the request id to show with an error, and Retry-After so it can say when to try again after a 429 or a read-only 503. */
export const CORS_EXPOSED_HEADERS = ['x-mopm-request-id', 'retry-after'];
/** The one browser origin that may call a stage's API: its own site, over https. Never `*`. */
export const siteOrigin = (c: StageConfig) => `https://${c.siteDomain}`;

export class ApiStack extends Stack {
  readonly api: apigw.HttpApi;
  readonly handler: lambda.Function;
  readonly indexReader: lambda.Function;

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
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'http/lambda.handler',
      // The asset holds one bundled file per handler (esbuild, service/api `npm run build`); the AWS SDK v3 comes with the
      // Node.js 22 runtime and is the one thing left out. test/bundle.test.ts loads every handler from its asset.
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 256,
      // Login calls GitHub and Secrets Manager; the gateway allows 30 seconds.
      timeout: Duration.seconds(10),
      logGroup,
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_VERSION: props.version,
        MOPM_COMMIT: props.commit,
        MOPM_READ_ONLY: String(props.readOnly ?? false),
        // The NAME of the secret holding the stage's GitHub OAuth app (never its value). Created by
        // service/infra/access/lib/oauth-secret.ts; until it exists the device login routes answer 503.
        MOPM_OAUTH_SECRET_NAME: oauthSecretName(c.stage),
        MOPM_REQUIRE_2FA: String(props.require2fa ?? true),
        // The hosts GET /index/config.json names, from the stage's configuration.
        MOPM_API_DOMAIN: c.apiDomain,
        MOPM_CHANNEL_DOMAIN: c.condaDomain,
        // Where uploads go (a presigned PUT into quarantine/) and where a commit is queued. Built from names, not
        // references, so this stack does not depend on the publish stack's exports.
        MOPM_CHANNEL_BUCKET: channelBucketName(c.stage, this.account),
        MOPM_VALIDATE_QUEUE_URL: `https://sqs.${this.region}.amazonaws.com/${this.account}/${validateQueueName(c.stage)}`,
        // Yank and unyank queue a repodata rewrite of the version's subdirs on the index writer's FIFO queue.
        MOPM_INDEX_QUEUE_URL: `https://sqs.${this.region}.amazonaws.com/${this.account}/${indexQueueName(c.stage)}`,
        // A group's commit queues its validation on the group queue (its own queue, so a group never takes a single publish's slot).
        MOPM_GROUP_QUEUE_URL: `https://sqs.${this.region}.amazonaws.com/${this.account}/${groupQueueName(c.stage)}`,
        ...(props.limits?.ratePerAccountPerDay !== undefined ? { MOPM_RATE_PER_ACCOUNT_DAY: String(props.limits.ratePerAccountPerDay) } : {}),
        ...(props.limits?.ratePerTokenPerDay !== undefined ? { MOPM_RATE_PER_TOKEN_DAY: String(props.limits.ratePerTokenPerDay) } : {}),
      },
    });

    // Read-only on the registry's tables and the indexes named in READ_INDEXES: the read API never writes.
    const tableArns = READ_TABLES.map((t) => this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, t) }));
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadRegistryTables',
        actions: READ_ACTIONS,
        resources: [
          ...tableArns,
          ...Object.entries(READ_INDEXES).flatMap(([t, ixs]) =>
            ixs.map((ix) => this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: `${tableName(c.stage, t)}/index/${ix}` })),
          ),
        ],
      }),
    );

    // Login and tokens: per-table, per-action grants (AUTH_GRANTS); a named index gets its own ARN, never `index/*`.
    for (const [table, g] of Object.entries(AUTH_GRANTS)) {
      const arn = this.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, table) });
      this.handler.addToRolePolicy(
        new iam.PolicyStatement({
          sid: `Auth${table.replace(/(^|_)(\w)/g, (_m, _u, ch: string) => ch.toUpperCase())}`,
          actions: g.actions,
          resources: [arn, ...(g.indexes ?? []).map((i) => `${arn}/index/${i}`)],
        }),
      );
    }
    // The GitHub OAuth app of this stage: one secret, read only. Secrets Manager appends six random characters to the
    // name in the ARN, so the ARN ends in six `?` (single-character wildcards), which cannot match a longer name.
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ReadGitHubOAuthSecret',
        actions: ['secretsmanager:GetSecretValue'],
        resources: [
          this.formatArn({
            service: 'secretsmanager',
            resource: 'secret',
            resourceName: `${oauthSecretName(c.stage)}-??????`,
            arnFormat: ArnFormat.COLON_RESOURCE_NAME,
          }),
        ],
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
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'QueueIndexRebuilds',
        actions: ['sqs:SendMessage'],
        resources: [this.formatArn({ service: 'sqs', resource: indexQueueName(c.stage) })],
      }),
    );
    this.handler.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'QueueGroupCommits',
        actions: ['sqs:SendMessage'],
        resources: [this.formatArn({ service: 'sqs', resource: groupQueueName(c.stage) })],
      }),
    );

    // The index reader: its own function and role, so the API role keeps its single quarantine statement. It may read
    // objects under index/ and list the bucket only with that prefix. S3 answers 403 (not 404) for a key that is not
    // there, because that decision ignores the prefix condition; the reader then lists with the exact key as the prefix,
    // which the grant allows, and answers 404 only when no listed key equals it. Any other S3 answer is 502.
    const bucketArn = `arn:aws:s3:::${channelBucketName(c.stage, this.account)}`;
    this.indexReader = new lambda.Function(this, 'IndexReader', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'http/index-lambda.handler',
      code: lambda.Code.fromAsset(handlerDir),
      memorySize: 256,
      timeout: Duration.seconds(10),
      logGroup: new logs.LogGroup(this, 'IndexReaderLogs', {
        retention: logs.RetentionDays.ONE_MONTH,
        removalPolicy: removalPolicyFor(c),
      }),
      environment: { MOPM_STAGE: c.stage, MOPM_CHANNEL_BUCKET: channelBucketName(c.stage, this.account) },
    });
    this.indexReader.addToRolePolicy(
      new iam.PolicyStatement({ sid: 'ReadIndexObjects', actions: ['s3:GetObject'], resources: [`${bucketArn}/index/*`] }),
    );
    this.indexReader.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ListIndexPrefix',
        actions: ['s3:ListBucket'],
        resources: [bucketArn],
        conditions: { StringLike: { 's3:prefix': 'index/*' } },
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
      // The gateway answers preflight itself and adds the allow-origin header to the handler's answers for this
      // origin only. No credentials: the read API takes no cookies and no token.
      corsPreflight: {
        allowOrigins: [siteOrigin(c)],
        allowMethods: CORS_METHODS,
        exposeHeaders: CORS_EXPOSED_HEADERS,
        maxAge: CORS_MAX_AGE,
      },
    });
    const integration = new integrations.HttpLambdaIntegration('ApiIntegration', this.handler);
    for (const route of READ_ROUTES) {
      this.api.addRoutes({ path: route, methods: [apigw.HttpMethod.GET], integration });
    }
    for (const r of AUTH_ROUTES) this.api.addRoutes({ path: r.path, methods: [r.method], integration });
    for (const r of PUBLISH_ROUTES) this.api.addRoutes({ path: r.path, methods: [r.method], integration });
    // The CLI sends no token: neither index route has an authorizer. The literal route wins over the greedy one.
    const configRoutes = this.api.addRoutes({ path: '/index/config.json', methods: [apigw.HttpMethod.GET], integration });
    const readerRoutes = this.api.addRoutes({
      path: '/index/{proxy+}',
      methods: [apigw.HttpMethod.GET],
      integration: new integrations.HttpLambdaIntegration('IndexReaderIntegration', this.indexReader),
    });
    // A route named in RouteSettings must exist when the stage is updated, so the stage depends on each such route.
    // Without the dependency CloudFormation updates the stage first and fails: "Unable to find Route by key".
    const throttled: Record<string, apigw.HttpRoute[]> = {
      [INDEX_CONFIG_ROUTE]: configRoutes,
      [INDEX_READER_ROUTE]: readerRoutes,
    };
    const stage = this.api.defaultStage!;
    const routeSettings: Record<string, { ThrottlingRateLimit: number; ThrottlingBurstLimit: number }> = {};
    for (const [key, routes] of Object.entries(throttled)) {
      routeSettings[key] = { ThrottlingRateLimit: INDEX_THROTTLE.rateLimit, ThrottlingBurstLimit: INDEX_THROTTLE.burstLimit };
      stage.node.addDependency(...routes);
    }
    (stage.node.defaultChild as apigw.CfnStage).routeSettings = routeSettings;

    const target = route53.RecordTarget.fromAlias(
      new targets.ApiGatewayv2DomainProperties(domain.regionalDomainName, domain.regionalHostedZoneId),
    );
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.apiDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.apiDomain, target });
  }
}
