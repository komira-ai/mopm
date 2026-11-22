import { App, Environment } from 'aws-cdk-lib';
import { ApiStack } from './api-stack';
import { ChannelStack } from './channel-stack';
import { REGION, StageConfig, assertStage, stageConfig } from './config';
import { DataStack } from './data-stack';
import { PublishStack } from './publish-stack';
import { SiteStack } from './site-stack';

export interface StageStacks {
  channel: ChannelStack;
  data: DataStack;
  publish: PublishStack;
  api: ApiStack;
  site: SiteStack;
}

export function createStageStacks(
  app: App,
  config: StageConfig,
  env: Environment,
  version: string,
  commit = 'dev',
  handlerDir?: string,
  siteDir?: string,
  rustZipDir?: string,
): StageStacks {
  const p = `mopm-${config.stage}`;
  const channel = new ChannelStack(app, `${p}-channel`, { env, config });
  const data = new DataStack(app, `${p}-data`, { env, config });
  const publish = new PublishStack(app, `${p}-publish`, { env, config, channel, handlerDir });
  const api = new ApiStack(app, `${p}-api`, { env, config, version, commit, handlerDir, rustZipDir });
  const site = new SiteStack(app, `${p}-site`, { env, config, siteDir });
  // Tables and queues exist before the Lambdas that use them are deployed (they are named, not referenced, so CDK
  // would otherwise deploy the stacks in parallel).
  publish.addDependency(data);
  api.addDependency(data);
  api.addDependency(publish);
  return { channel, data, publish, api, site };
}

export interface ContextOptions {
  /** CDK_DEFAULT_ACCOUNT: required; it is never in a file. */
  account?: string;
  /** CDK_DEFAULT_REGION: when set it must be REGION. */
  region?: string;
  /** Test stand-ins for the handler bundle and the site build; unset, the stacks use their real build outputs. */
  handlerDir?: string;
  siteDir?: string;
}

/**
 * The stacks `cdk synth|deploy` builds from the CDK context: `stage` (required), `hostedZoneId`, `version` and `commit`
 * (each defaults to 'dev'), and `rustZipDir`. Absent or empty `rustZipDir`: no Rust function is created (and a deploy
 * removes the ones a stage has); a directory that does not exist is an error.
 */
export function stageStacksFromContext(app: App, opts: ContextOptions): StageStacks {
  const stage = assertStage(String(app.node.tryGetContext('stage') ?? ''));
  if (!opts.account) {
    throw new Error('CDK_DEFAULT_ACCOUNT is not set; the account is provided by the CDK environment at deploy time');
  }
  if (opts.region && opts.region !== REGION) {
    throw new Error(`stacks deploy to ${REGION} only (CloudFront certificates); CDK_DEFAULT_REGION is '${opts.region}'`);
  }
  const zoneId = app.node.tryGetContext('hostedZoneId');
  const version = String(app.node.tryGetContext('version') ?? 'dev');
  const commit = String(app.node.tryGetContext('commit') ?? 'dev');
  const rustZipDir = app.node.tryGetContext('rustZipDir');
  return createStageStacks(
    app,
    stageConfig(stage, zoneId ? String(zoneId) : undefined),
    { account: opts.account, region: REGION },
    version,
    commit,
    opts.handlerDir,
    opts.siteDir,
    rustZipDir ? String(rustZipDir) : undefined,
  );
}
