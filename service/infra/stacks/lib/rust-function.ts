import * as fs from 'fs';
import * as path from 'path';
import { ArnFormat, Duration, Stack } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';
import { StageConfig, tableName } from './config';
import { removalPolicyFor } from './common';
import { STAGE_SETTINGS_KEY } from './stage-settings';

/** What a Rust function may do on one table: the actions, on the table and on the named indexes only (never `index/*`). */
export interface RustTableGrant {
  /** The table's id in TABLES (lib/data-stack.ts), without the stage prefix. */
  table: string;
  actions: string[];
  indexes?: string[];
}

/** One HTTP API route to the function. */
export interface RustRoute {
  method: apigw.HttpMethod;
  path: string;
}

export interface RustFunctionProps {
  config: StageConfig;
  /** The function's name without the stage (`web-login`): the code is `<zipDir>/<name>.zip`, the Lambda `mopm-<stage>-<name>`. */
  name: string;
  /** The directory of the functions' zips (lambda_zip's output, one `<name>.zip` each). */
  zipDir: string;
  api: apigw.HttpApi;
  routes: RustRoute[];
  tables: RustTableGrant[];
  /** Names of the Secrets Manager secrets the function reads (GetSecretValue on each, nothing else). */
  secrets: string[];
}

/**
 * The Lambda's name. The function reads its stage from it (`AWS_LAMBDA_FUNCTION_NAME`, set by Lambda), so it has no
 * environment variable of ours.
 */
export const rustFunctionName = (c: StageConfig, name: string) => `mopm-${c.stage}-${name}`;
/** A function name: lower-case words joined by `-`, as the Lambda name and the zip name use it. */
const NAME = /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/;
/** Under the HTTP API's 30 s wait for an integration, so a slow call ends as the function's own error (as API_LAMBDA_TIMEOUT_SECONDS). */
export const RUST_FUNCTION_TIMEOUT_SECONDS = 25;
export const RUST_FUNCTION_MEMORY_MB = 256;

const pascal = (s: string) => s.replace(/(^|[_-])(\w)/g, (_m, _u, ch: string) => ch.toUpperCase());

/**
 * A Rust Lambda of the registry (docs/design/tutorial-sign-in.md, section 5): custom runtime `provided.al2023` on x86_64,
 * handler `bootstrap`, code from its zip, behind the stage's HTTP API on the routes it is given.
 *
 * Its role is its own and holds only: the table grants and secrets passed in, GetItem of the `stage_settings` item of the
 * config table (every function reads it at cold start), and writing to its own log group. No managed policy.
 */
export class RustFunction extends Construct {
  readonly fn: lambda.Function;
  readonly role: iam.Role;

  constructor(scope: Construct, id: string, props: RustFunctionProps) {
    super(scope, id);
    const c = props.config;
    if (!NAME.test(props.name)) {
      throw new Error(`a Rust function name is lower-case words joined by '-'; got '${props.name}'`);
    }
    if (props.routes.length === 0) {
      throw new Error(`the Rust function '${props.name}' has no route`);
    }
    const zip = path.join(props.zipDir, `${props.name}.zip`);
    if (!fs.existsSync(zip)) {
      throw new Error(`the Rust function zip is missing at ${zip}; build the function's zip (lambda_zip) first`);
    }
    const stack = Stack.of(this);
    const tableArn = (t: string) => stack.formatArn({ service: 'dynamodb', resource: 'table', resourceName: tableName(c.stage, t) });

    const logGroup = new logs.LogGroup(this, 'Logs', { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: removalPolicyFor(c) });
    this.role = new iam.Role(this, 'Role', { assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com') });
    this.role.addToPolicy(
      new iam.PolicyStatement({ sid: 'WriteOwnLogs', actions: ['logs:CreateLogStream', 'logs:PutLogEvents'], resources: [logGroup.logGroupArn] }),
    );
    this.role.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadStageSettings',
        actions: ['dynamodb:GetItem'],
        resources: [tableArn('config')],
        conditions: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': [STAGE_SETTINGS_KEY] } },
      }),
    );
    for (const g of props.tables) {
      const arn = tableArn(g.table);
      this.role.addToPolicy(
        new iam.PolicyStatement({
          sid: `Table${pascal(g.table)}`,
          actions: g.actions,
          resources: [arn, ...(g.indexes ?? []).map((i) => `${arn}/index/${i}`)],
        }),
      );
    }
    if (props.secrets.length > 0) {
      // Secrets Manager appends six random characters to the name in the ARN: six `?`, which cannot match a longer name.
      this.role.addToPolicy(
        new iam.PolicyStatement({
          sid: 'ReadSecrets',
          actions: ['secretsmanager:GetSecretValue'],
          resources: props.secrets.map((s) =>
            stack.formatArn({ service: 'secretsmanager', resource: 'secret', resourceName: `${s}-??????`, arnFormat: ArnFormat.COLON_RESOURCE_NAME }),
          ),
        }),
      );
    }

    this.fn = new lambda.Function(this, 'Function', {
      functionName: rustFunctionName(c, props.name),
      runtime: lambda.Runtime.PROVIDED_AL2023,
      architecture: lambda.Architecture.X86_64,
      handler: 'bootstrap',
      code: lambda.Code.fromAsset(zip),
      role: this.role,
      logGroup,
      memorySize: RUST_FUNCTION_MEMORY_MB,
      timeout: Duration.seconds(RUST_FUNCTION_TIMEOUT_SECONDS),
    });

    // One invoke permission for the API, not one per route (as the TypeScript handler's integration).
    const integration = new integrations.HttpLambdaIntegration(`${id}Integration`, this.fn, { scopePermissionToRoute: false });
    for (const r of props.routes) props.api.addRoutes({ path: r.path, methods: [r.method], integration });
  }
}
