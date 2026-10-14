import { App, Environment } from 'aws-cdk-lib';
import { ApiStack } from './api-stack';
import { ChannelStack } from './channel-stack';
import { StageConfig } from './config';
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
): StageStacks {
  const p = `mopm-${config.stage}`;
  const channel = new ChannelStack(app, `${p}-channel`, { env, config });
  const data = new DataStack(app, `${p}-data`, { env, config });
  const publish = new PublishStack(app, `${p}-publish`, { env, config, channel, handlerDir });
  const api = new ApiStack(app, `${p}-api`, { env, config, version, commit, handlerDir });
  const site = new SiteStack(app, `${p}-site`, { env, config });
  // Tables and queues exist before the Lambdas that use them are deployed (they are named, not referenced, so CDK
  // would otherwise deploy the stacks in parallel).
  publish.addDependency(data);
  api.addDependency(data);
  api.addDependency(publish);
  return { channel, data, publish, api, site };
}
