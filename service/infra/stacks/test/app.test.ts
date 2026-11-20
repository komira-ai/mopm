import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { createStageStacks } from '../lib/app';
import { ChannelStack } from '../lib/channel-stack';
import { stageConfig } from '../lib/config';
import { PublishStack } from '../lib/publish-stack';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, HANDLER_STUB_DIR, SITE_STUB_DIR } from './util';

const env = { account: DUMMY_ACCOUNT, region: 'us-east-1' };

test('without a commit the stacks report commit "dev" on the health endpoint', () => {
  const s = createStageStacks(new App(), stageConfig('beta', DUMMY_ZONE_ID), env, '1.2.3', undefined, HANDLER_STUB_DIR, SITE_STUB_DIR);
  const fns = Object.values(Template.fromStack(s.api).findResources('AWS::Lambda::Function')) as any[];
  const handler = fns.find((f) => f.Properties.Handler === 'http/lambda.handler');
  expect(handler.Properties.Environment.Variables.MOPM_COMMIT).toBe('dev');
});

test('a region other than us-east-1 is refused, naming both', () => {
  expect(() =>
    createStageStacks(new App(), stageConfig('beta', DUMMY_ZONE_ID), { ...env, region: 'eu-west-1' }, '1.2.3', 'c', HANDLER_STUB_DIR, SITE_STUB_DIR),
  ).toThrow('stacks must be deployed to us-east-1; got eu-west-1');
});

test('the publish stack refuses a missing handler bundle, naming the path and the fix', () => {
  const app = new App();
  const config = stageConfig('beta', DUMMY_ZONE_ID);
  const channel = new ChannelStack(app, 'c', { env, config });
  expect(() => new PublishStack(app, 'p', { env, config, channel, handlerDir: '/nonexistent/handler' })).toThrow(
    "the handler bundle is missing at /nonexistent/handler; run 'npm ci && npm run build' in service/api first",
  );
});
