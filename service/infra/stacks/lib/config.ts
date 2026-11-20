// Typed per-stage configuration. Nothing here is a secret or an account id:
// the account comes from the CDK environment at deploy time (CDK_DEFAULT_ACCOUNT).
import * as fs from 'fs';
import * as path from 'path';

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
  /** The tutorial's sandbox settings, from the `tutorial` block of service/config/<stage>.json. Absent when the file has none. */
  tutorial?: TutorialConfig;
}

/**
 * The `tutorial` block of service/config/<stage>.json: what the `stage_settings` item of the config table says about
 * sandboxes (docs/design/tutorial-sign-in.md, section 5). Every field is optional; lib/stage-settings.ts fills the defaults.
 */
export interface TutorialConfig {
  /** The E2B template sandboxes are created from. Absent: the item has none, and the sandbox function answers `tutorial_unavailable`. */
  e2bTemplateId?: string;
  /** E2B's API domain. Default `e2b.app`. */
  e2bDomain?: string;
  /** The sandbox timeout E2B is asked for, in seconds. Default 1800. */
  sandboxTimeoutS?: number;
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

/** service/config: the stages' configuration files, one `<stage>.json` each (the e2e workflow reads them too). */
export const CONFIG_DIR = path.resolve(__dirname, '../../../config');

/** The keys a stage's configuration file may have. Anything else is refused, so a misspelt key never passes as absent. */
const FILE_KEYS = ['stage', 'siteDomain', 'condaDomain', 'apiDomain', 'hostedZoneName', 'disposable', 'tutorial'];
const TUTORIAL_KEYS = ['e2bTemplateId', 'e2bDomain', 'sandboxTimeoutS'];
/** A DNS host name: lower-case labels joined by dots, no scheme, port or path. */
const HOST = /^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/;

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Checks the parsed service/config/<stage>.json (`file` names it in errors) and returns its `tutorial` block. Refuses a key
 * that is not in FILE_KEYS or TUTORIAL_KEYS and a tutorial value of the wrong kind. The other keys' values are held equal to
 * stageConfig by test/config-files.test.ts.
 */
export function parseTutorialConfig(file: string, json: unknown): TutorialConfig | undefined {
  if (!isObject(json)) throw new Error(`${file}: must be a JSON object`);
  for (const k of Object.keys(json)) {
    if (!FILE_KEYS.includes(k)) throw new Error(`${file}: unknown key '${k}'; the keys are ${FILE_KEYS.join(', ')}`);
  }
  const t = json.tutorial;
  if (t === undefined) return undefined;
  if (!isObject(t)) throw new Error(`${file}: 'tutorial' must be an object`);
  for (const k of Object.keys(t)) {
    if (!TUTORIAL_KEYS.includes(k)) throw new Error(`${file}: unknown key 'tutorial.${k}'; the keys are ${TUTORIAL_KEYS.join(', ')}`);
  }
  const out: TutorialConfig = {};
  if (t.e2bTemplateId !== undefined) {
    if (typeof t.e2bTemplateId !== 'string' || !/^[A-Za-z0-9_-]+$/.test(t.e2bTemplateId)) {
      throw new Error(`${file}: 'tutorial.e2bTemplateId' must be a non-empty string of letters, digits, '-' and '_'`);
    }
    out.e2bTemplateId = t.e2bTemplateId;
  }
  if (t.e2bDomain !== undefined) {
    if (typeof t.e2bDomain !== 'string' || !HOST.test(t.e2bDomain)) {
      throw new Error(`${file}: 'tutorial.e2bDomain' must be a host name such as e2b.app (no scheme, port or path)`);
    }
    out.e2bDomain = t.e2bDomain;
  }
  if (t.sandboxTimeoutS !== undefined) {
    if (typeof t.sandboxTimeoutS !== 'number' || !Number.isInteger(t.sandboxTimeoutS) || t.sandboxTimeoutS <= 0) {
      throw new Error(`${file}: 'tutorial.sandboxTimeoutS' must be a whole number of seconds above 0`);
    }
    out.sandboxTimeoutS = t.sandboxTimeoutS;
  }
  return out;
}

/** The `tutorial` block of service/config/<stage>.json, checked (parseTutorialConfig). */
export function readTutorialConfig(stage: Stage): TutorialConfig | undefined {
  const file = path.join(CONFIG_DIR, `${stage}.json`);
  return parseTutorialConfig(`service/config/${stage}.json`, JSON.parse(fs.readFileSync(file, 'utf8')));
}

/**
 * A stage's configuration. `tutorial` defaults to the block in service/config/<stage>.json (readTutorialConfig); tests pass
 * their own.
 */
export function stageConfig(stage: Stage, hostedZoneId?: string, tutorial: TutorialConfig | undefined = readTutorialConfig(stage)): StageConfig {
  const site = stage === 'prod' ? ZONE : `${stage}.${ZONE}`;
  return {
    stage,
    siteDomain: site,
    condaDomain: `conda.${site}`,
    apiDomain: `api.${site}`,
    // Each stage account holds only its own zone; prod holds mopm.dev and delegates beta and gamma (service/infra/dns).
    hostedZoneName: site,
    ...(hostedZoneId ? { hostedZoneId } : {}),
    ...(tutorial ? { tutorial } : {}),
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

/**
 * The secret holding a stage's edge-origin value: the site distribution sends it to the API as the `x-mopm-edge` origin
 * header on `/api/*`, so a function can tell a request that came through the site host. Generated when the site stack
 * creates it (lib/site-stack.ts); never written by hand.
 */
export const edgeOriginSecretName = (s: Stage) => `mopm/${s}/edge-origin`;

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
