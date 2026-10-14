import { App, Environment } from 'aws-cdk-lib';
import { ApiStack } from './api-stack';
import { ChannelStack } from './channel-stack';
import { StageConfig } from './config';
import { DataStack } from './data-stack';
import { SiteStack } from './site-stack';

export interface StageStacks {
  channel: ChannelStack;
  data: DataStack;
  api: ApiStack;
  site: SiteStack;
}

export function createStageStacks(app: App, config: StageConfig, env: Environment, version: string): StageStacks {
  const p = `mopm-${config.stage}`;
  return {
    channel: new ChannelStack(app, `${p}-channel`, { env, config }),
    data: new DataStack(app, `${p}-data`, { env, config }),
    api: new ApiStack(app, `${p}-api`, { env, config, version }),
    site: new SiteStack(app, `${p}-site`, { env, config }),
  };
}
