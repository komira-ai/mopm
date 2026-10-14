// Typed per-stage configuration. Nothing here is a secret or an account id:
// the account comes from the CDK environment at deploy time (CDK_DEFAULT_ACCOUNT).

export const STAGES = ['beta', 'gamma', 'prod'] as const;
export type Stage = (typeof STAGES)[number];

export interface StageConfig {
  stage: Stage;
  /** Host of the HTTP API custom domain. */
  apiDomain: string;
  /** Host of the conda channel (S3 + CloudFront). */
  condaDomain: string;
  /** Host of the website. */
  siteDomain: string;
  /** Public hosted zone, looked up by name in the stage account. */
  hostedZoneName: string;
  /** Dummy-synth only: skips the hosted zone lookup. Never set at real deploys. */
  hostedZoneId?: string;
}

/** ACM certificates for CloudFront must live in us-east-1, so every stack does. */
export const REGION = 'us-east-1';

export const ZONE = 'mopm.dev';

export function assertStage(s: string): Stage {
  if (!(STAGES as readonly string[]).includes(s)) {
    throw new Error(`stage must be one of ${STAGES.join(', ')}; got '${s}'`);
  }
  return s as Stage;
}

/** Only beta and gamma are disposable. Prod is the only durable registry. */
export const isDisposable = (stage: Stage): boolean => stage !== 'prod';

export function stageConfig(stage: Stage, hostedZoneId?: string): StageConfig {
  const site = stage === 'prod' ? ZONE : `${stage}.${ZONE}`;
  return {
    stage,
    siteDomain: site,
    condaDomain: `conda.${site}`,
    apiDomain: `api.${site}`,
    hostedZoneName: ZONE,
    ...(hostedZoneId ? { hostedZoneId } : {}),
  };
}

/** Role names the bucket and table policies exempt from the delete deny. Created by the access/service stacks. */
export const takedownRoleName = (s: Stage) => `mopm-${s}-takedown`;
export const cleanupRoleName = (s: Stage) => `mopm-${s}-cleanup`;

/** Roles that may delete data on this stage: takedown everywhere, cleanup only where disposable. */
export const deleteAllowedRoleNames = (s: Stage): string[] =>
  isDisposable(s) ? [takedownRoleName(s), cleanupRoleName(s)] : [takedownRoleName(s)];

export const channelBucketName = (s: Stage, account: string) => `mopm-${s}-channel-${account}`;
export const siteBucketName = (s: Stage, account: string) => `mopm-${s}-site-${account}`;
export const tableName = (s: Stage, table: string) => `mopm-${s}-${table}`;
