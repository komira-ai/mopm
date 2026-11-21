import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { createStageStacks, stageStacksFromContext } from '../lib/app';
import { ChannelStack } from '../lib/channel-stack';
import { stageConfig } from '../lib/config';
import { PublishStack } from '../lib/publish-stack';
import { DUMMY_ACCOUNT, DUMMY_ZONE_ID, HANDLER_STUB_DIR, RUST_ZIP_STUB_DIR, SITE_STUB_DIR } from './util';

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

describe('stageStacksFromContext reads the CDK context', () => {
  const from = (context: Record<string, string>, env: { account?: string; region?: string } = { account: DUMMY_ACCOUNT, region: 'us-east-1' }) =>
    stageStacksFromContext(new App({ context }), { ...env, handlerDir: HANDLER_STUB_DIR, siteDir: SITE_STUB_DIR });
  const rustNames = (s: ReturnType<typeof from>) =>
    Object.values(Template.fromStack(s.api).findResources('AWS::Lambda::Function', { Properties: { Runtime: 'provided.al2023' } }))
      .map((r: any) => r.Properties.FunctionName)
      .sort();
  const base = { stage: 'beta', hostedZoneId: DUMMY_ZONE_ID };

  test('rustZipDir creates exactly the three Rust functions', () => {
    expect(rustNames(from({ ...base, rustZipDir: RUST_ZIP_STUB_DIR }))).toEqual([
      'mopm-beta-tutorial-sandbox',
      'mopm-beta-web-login',
      'mopm-beta-web-session',
    ]);
  });

  test('without rustZipDir no Rust function is created', () => {
    expect(rustNames(from(base))).toEqual([]);
  });

  test('an empty rustZipDir creates no Rust function', () => {
    expect(rustNames(from({ ...base, rustZipDir: '' }))).toEqual([]);
  });

  test('a rustZipDir that does not exist is refused, naming it', () => {
    expect(() => from({ ...base, rustZipDir: '/nonexistent/zips' })).toThrow(
      'the Rust function zips are missing: /nonexistent/zips does not exist',
    );
  });

  test.each([
    ['missing', {}, "stage must be one of beta, gamma, prod; got ''"],
    ['invalid', { stage: 'dev' }, "stage must be one of beta, gamma, prod; got 'dev'"],
  ])('a %s stage is refused', (_w, ctx, message) => {
    expect(() => from(ctx)).toThrow(message);
  });

  test('no account is refused', () => {
    expect(() => from(base, {})).toThrow(
      'CDK_DEFAULT_ACCOUNT is not set; the account is provided by the CDK environment at deploy time',
    );
  });

  test('a region other than us-east-1 is refused, naming it', () => {
    expect(() => from(base, { account: DUMMY_ACCOUNT, region: 'eu-west-1' })).toThrow(
      "stacks deploy to us-east-1 only (CloudFront certificates); CDK_DEFAULT_REGION is 'eu-west-1'",
    );
  });

  test('the hosted zone id of the context is used, and without one the stacks still build (the zone is looked up at deploy)', () => {
    const zoneIds = (s: ReturnType<typeof from>) => JSON.stringify(Template.fromStack(s.site).toJSON()).includes(DUMMY_ZONE_ID);
    expect([zoneIds(from(base)), zoneIds(from({ stage: 'beta' }))]).toEqual([true, false]);
  });

  test('an unset region is accepted', () => {
    expect(() => from(base, { account: DUMMY_ACCOUNT })).not.toThrow();
  });

  test.each([
    ['absent', {}, 'dev', 'dev'],
    ['set', { version: '9.8.7', commit: 'abc123' }, '9.8.7', 'abc123'],
  ])('version and commit %s: the health handler reports them', (_w, ctx, version, commit) => {
    const fns = Object.values(Template.fromStack(from({ ...base, ...ctx }).api).findResources('AWS::Lambda::Function')) as any[];
    const vars = fns.find((f) => f.Properties.Handler === 'http/lambda.handler').Properties.Environment.Variables;
    expect([vars.MOPM_VERSION, vars.MOPM_COMMIT]).toEqual([version, commit]);
  });
});
