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
import { StageConfig, tableName } from './config';
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
      memorySize: 128,
      timeout: Duration.seconds(5),
      logGroup,
      environment: {
        MOPM_STAGE: c.stage,
        MOPM_VERSION: props.version,
        MOPM_COMMIT: props.commit,
        MOPM_READ_ONLY: String(props.readOnly ?? false),
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

    const target = route53.RecordTarget.fromAlias(
      new targets.ApiGatewayv2DomainProperties(domain.regionalDomainName, domain.regionalHostedZoneId),
    );
    new route53.ARecord(this, 'ARecord', { zone, recordName: c.apiDomain, target });
    new route53.AaaaRecord(this, 'AaaaRecord', { zone, recordName: c.apiDomain, target });
  }
}
