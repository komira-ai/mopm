import { App } from 'aws-cdk-lib';
import { createStageStacks } from '../lib/app';
import { STAGES, stageConfig } from '../lib/config';
import { DUMMY_ACCOUNT } from './util';

// Real deploys have no hostedZoneId: the zone is looked up by name in the stage account. Every other test passes a
// dummy id and skips the lookup, so this one synthesizes the stacks WITHOUT it and checks the lookup is requested.
describe.each(STAGES)('hosted zone lookup %s', (stage) => {
  const app = new App();
  createStageStacks(app, stageConfig(stage), { account: DUMMY_ACCOUNT, region: 'us-east-1' }, '1.2.3');
  const missing = app.synth().manifest.missing ?? [];

  test('requests a hosted-zone lookup for mopm.dev in the stage account and region', () => {
    const zones = missing.filter((m) => m.provider === 'hosted-zone');
    expect(zones.length).toBeGreaterThan(0);
    for (const z of zones) {
      expect(z.props).toMatchObject({ account: DUMMY_ACCOUNT, region: 'us-east-1', domainName: 'mopm.dev' });
    }
  });

  test('the stage config carries no zone id by default', () => {
    expect(stageConfig(stage).hostedZoneId).toBeUndefined();
  });
});
