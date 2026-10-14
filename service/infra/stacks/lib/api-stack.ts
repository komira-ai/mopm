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
import { StageConfig, oauthSecretName, tableName } from './config';
import { assertRegion, lookupZone, removalPolicyFor } from './common';

export interface ApiStackProps extends StackProps {
  config: StageConfig;
  /** Release version reported by /api/v1/health. */
  version: string;
  /** Git commit the release was built from, reported by /api/v1/health so e2e can prove what is deployed. */
  commit: string;
  /** Directory holding the built handler (`http/lambda.js`). Defaults to service/api/dist; tests pass a stub. */
  handlerDir?: string;
  /** New uploads are refused and /health says so. */
  readOnly?: boolean;
  /** Interactive publishing needs a GitHub account with two-factor authentication on (the CEO's rule). On unless set false. */
  require2fa?: boolean;
}

/**
 * Where the CI-built handler bundle lives (`npm run build` in service/api writes `dist/`). It is not committed:
 * service-ci.yml and deploy.yml build it before they synthesize or deploy.
 */
export const DEFAULT_HANDLER_DIR = path.resolve(__dirname, '../../../api/dist');

/** The read-only tables the handler may use. Grants are GetItem and Query: never a write, never a Scan. */
export const READ_TABLES = ['packages', 'versions', 'owners', 'audit'] as const;
/** The indexes the handler may Query, by table. Only these: the other index (owners by_github_id) is not read by the read API. */
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
 */
export const AUTH_GRANTS: Record<string, { actions: string[]; indexes?: string[] }> = {
  tokens: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:UpdateItem', 'dynamodb:Query'], indexes: ['by_github_id'] },
  users: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem'] },
  device_logins: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:UpdateItem'] },
  trusted_publishers: { actions: ['dynamodb:GetItem', 'dynamodb:Query'] },
};

/** Methods a browser may use on the read API. HEAD and OPTIONS are listed for preflight; only GET routes exist. */
export const CORS_METHODS = [apigw.CorsHttpMethod.GET, apigw.CorsHttpMethod.HEAD, apigw.CorsHttpMethod.OPTIONS];
/** How long a browser may cache a preflight answer. */
export const CORS_MAX_AGE = Duration.hours(1);
/** The response header a page may read, so it can show the request id with an error. */
export const CORS_EXPOSED_HEADERS = ['x-mopm-request-id'];
/** The one browser origin that may call a stage's API: its own site, over https. Never `*`. */
export const siteOrigin = (c: StageConfig) => `https://${c.siteDomain}`;

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
      // Login calls GitHub and Secrets Manager; the gateway allows 30 seconds.
      timeout: Duration.seconds(10),
      logGroup,
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_VERSION: props.version,
        MOPM_COMMIT: props.commit,
        MOPM_READ_ONLY: String(props.readOnly ?? false),
        // The NAME of the secret holding the stage's GitHub OAuth app (never its value). Created by
        // service/infra/access/oauth-secret.sh; until it exists the device login routes answer 503.
        MOPM_OAUTH_SECRET_NAME: oauthSecretName(c.stage),
        MOPM_REQUIRE_2FA: String(props.require2fa ?? true),
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

    const target = route53.RecordTarget.fromAlias(
      new targets.ApiGatewayv2DomainProperties(domain.regionalDomainName, domain.regionalHostedZoneId),
    );
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.apiDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.apiDomain, target });
  }
}
