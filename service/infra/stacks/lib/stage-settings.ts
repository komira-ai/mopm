import { Stack } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';
import { StageConfig, tableName } from './config';
import { removalPolicyFor } from './common';

/**
 * The `stage_settings` item of the stage's `config` table (docs/design/tutorial-sign-in.md, section 5, "Stage settings"):
 * what the Rust functions read at cold start instead of environment variables. Code owns it: the API stack writes the whole
 * item at deploy, and a hand edit lasts only until a deploy changes one of its values.
 */
export const STAGE_SETTINGS_KEY = 'stage_settings';
/** E2B's API domain when the stage's `tutorial` block names none. */
export const DEFAULT_E2B_DOMAIN = 'e2b.app';
/** The sandbox timeout E2B is asked for when the stage's `tutorial` block names none: E2B's cleanup of an abandoned sandbox. */
export const DEFAULT_SANDBOX_TIMEOUT_S = 1800;

/** The item, attribute by attribute, as the functions read it. */
export interface StageSettings {
  key: typeof STAGE_SETTINGS_KEY;
  /** The GitHub OAuth callback: the site host's `/api/v2/auth/web/callback`. */
  redirect_uri: string;
  /** The site's origin, `https://<site host>`. */
  site_origin: string;
  /** Sign-in needs a GitHub account with two-factor authentication on (the API stack's `require2fa`). */
  require_2fa: boolean;
  /** Absent until the stage's configuration names a template; the sandbox function then answers `tutorial_unavailable`. */
  e2b_template_id?: string;
  e2b_domain: string;
  sandbox_timeout_s: number;
}

/** The stage's settings: the site host from the stage configuration, the tutorial values from its `tutorial` block or the defaults. */
export function stageSettings(c: StageConfig, require2fa: boolean): StageSettings {
  const t = c.tutorial ?? {};
  return {
    key: STAGE_SETTINGS_KEY,
    redirect_uri: `https://${c.siteDomain}/api/v2/auth/web/callback`,
    site_origin: `https://${c.siteDomain}`,
    require_2fa: require2fa,
    ...(t.e2bTemplateId !== undefined ? { e2b_template_id: t.e2bTemplateId } : {}),
    e2b_domain: t.e2bDomain ?? DEFAULT_E2B_DOMAIN,
    sandbox_timeout_s: t.sandboxTimeoutS ?? DEFAULT_SANDBOX_TIMEOUT_S,
  };
}

/** The item in DynamoDB's attribute-value form: strings `S`, the flag `BOOL`, the timeout `N`. */
export function stageSettingsItem(s: StageSettings): Record<string, Record<string, string | boolean>> {
  return {
    key: { S: s.key },
    redirect_uri: { S: s.redirect_uri },
    site_origin: { S: s.site_origin },
    require_2fa: { BOOL: s.require_2fa },
    ...(s.e2b_template_id !== undefined ? { e2b_template_id: { S: s.e2b_template_id } } : {}),
    e2b_domain: { S: s.e2b_domain },
    sandbox_timeout_s: { N: String(s.sandbox_timeout_s) },
  };
}

export interface StageSettingsWriterProps {
  config: StageConfig;
  require2fa: boolean;
}

/**
 * Writes the `stage_settings` item at deploy: a PutItem of the whole item when the stack is created and whenever a value
 * changes. Its role may put that one key in the config table and nothing else. Deleting the stack leaves the item (the table's
 * policy refuses DeleteItem to every role but the takedown and cleanup roles).
 */
export class StageSettingsWriter extends Construct {
  constructor(scope: Construct, id: string, props: StageSettingsWriterProps) {
    super(scope, id);
    const c = props.config;
    const table = tableName(c.stage, 'config');
    const call: cr.AwsSdkCall = {
      service: 'DynamoDB',
      action: 'PutItem',
      parameters: { TableName: table, Item: stageSettingsItem(stageSettings(c, props.require2fa)) },
      physicalResourceId: cr.PhysicalResourceId.of(`${table}/${STAGE_SETTINGS_KEY}`),
    };
    new cr.AwsCustomResource(this, 'Put', {
      onCreate: call,
      onUpdate: call,
      // The SDK that comes with the runtime: a deploy downloads nothing.
      installLatestAwsSdk: false,
      logGroup: new logs.LogGroup(this, 'Logs', { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: removalPolicyFor(c) }),
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          sid: 'PutStageSettings',
          actions: ['dynamodb:PutItem'],
          resources: [Stack.of(this).formatArn({ service: 'dynamodb', resource: 'table', resourceName: table })],
          conditions: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': [STAGE_SETTINGS_KEY] } },
        }),
      ]),
    });
  }
}
