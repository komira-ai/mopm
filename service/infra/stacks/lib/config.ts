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
  /** The stage's own public hosted zone (beta.mopm.dev, gamma.mopm.dev, mopm.dev), looked up by name in the stage account. Every host above sits inside it. */
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
    // Each stage account holds only its own zone; prod holds mopm.dev and delegates beta and gamma (service/infra/dns).
    hostedZoneName: site,
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

/** The secret holding a stage's GitHub OAuth app ({"client_id","client_secret"}); created by service/infra/access/lib/oauth-secret.ts. */
export const oauthSecretName = (s: Stage) => `mopm/${s}/github-oauth`;

/** FIFO queues of the publish pipeline (the API stack builds the validate queue's URL from the name, so the names live here). */
export const validateQueueName = (s: Stage) => `mopm-${s}-validate.fifo`;
export const validateDlqName = (s: Stage) => `mopm-${s}-validate-dlq.fifo`;
export const indexQueueName = (s: Stage) => `mopm-${s}-index.fifo`;
export const indexDlqName = (s: Stage) => `mopm-${s}-index-dlq.fifo`;
export const groupQueueName = (s: Stage) => `mopm-${s}-group.fifo`;
export const groupDlqName = (s: Stage) => `mopm-${s}-group-dlq.fifo`;

/** The four subdirs every channel has (spec/channel.md, Layout). Same list as SUBDIRS_V1 in service/api (a test compares them). */
export const CHANNEL_SUBDIRS = ['noarch', 'linux-64', 'linux-aarch64', 'osx-arm64'] as const;

/**
 * The conda-forge name mirror: one object in the channel bucket, written by the mirror job and read by the validators
 * (service/api/src/validate/native-mirror.ts, MIRROR_KEY; publish.test.ts holds the two equal).
 */
export const NATIVE_MIRROR_KEY = 'native-mirror/conda-forge-names.gz';
