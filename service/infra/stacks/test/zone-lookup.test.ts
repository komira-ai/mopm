import { App } from 'aws-cdk-lib';
import { createStageStacks } from '../lib/app';
import { STAGES, stageConfig } from '../lib/config';
import { DUMMY_ACCOUNT, HANDLER_STUB_DIR, SITE_STUB_DIR } from './util';

const EXPECTED_ZONE = { beta: 'beta.mopm.dev', gamma: 'gamma.mopm.dev', prod: 'mopm.dev' } as const;

// Real deploys have no hostedZoneId: the zone is looked up by name in the stage account. Every other test passes a
// dummy id and skips the lookup, so this one synthesizes the stacks WITHOUT it and checks the lookup is requested.
describe.each(STAGES)('hosted zone lookup %s', (stage) => {
  const app = new App();
  createStageStacks(app, stageConfig(stage), { account: DUMMY_ACCOUNT, region: 'us-east-1' }, '1.2.3', 'dev', HANDLER_STUB_DIR, SITE_STUB_DIR);
  const missing = app.synth().manifest.missing ?? [];

  test('requests a hosted-zone lookup for the own zone of the stage in the stage account and region', () => {
    const zones = missing.filter((m) => m.provider === 'hosted-zone');
    expect(zones.length).toBeGreaterThan(0);
    for (const z of zones) {
      expect(z.props).toMatchObject({ account: DUMMY_ACCOUNT, region: 'us-east-1', domainName: EXPECTED_ZONE[stage] });
    }
  });

  test('the stage config carries no zone id by default', () => {
    expect(stageConfig(stage).hostedZoneId).toBeUndefined();
  });
});

// A stage account holds only its own zone, so a host outside it can neither be looked up nor validated.
describe.each(STAGES)('hostnames are inside the looked-up zone %s', (stage) => {
  const c = stageConfig(stage);
  const inside = (host: string) => host === c.hostedZoneName || host.endsWith(`.${c.hostedZoneName}`);

  test('zone is the stage zone', () => {
    expect(c.hostedZoneName).toBe(EXPECTED_ZONE[stage]);
  });

  test.each([['siteDomain'], ['condaDomain'], ['apiDomain']] as const)('%s is inside the zone', (k) => {
    expect(inside(c[k])).toBe(true);
  });

  test('every ACM certificate and record name in the synthesized stacks is inside the zone', () => {
    const app = new App();
    createStageStacks(app, stageConfig(stage, 'Z0DUMMYZONE'), { account: DUMMY_ACCOUNT, region: 'us-east-1' }, '1.2.3', 'dev', HANDLER_STUB_DIR, SITE_STUB_DIR);
    const names: string[] = [];
    for (const art of app.synth().artifacts) {
      const t = (art as unknown as { template?: { Resources?: Record<string, { Type: string; Properties: Record<string, unknown> }> } }).template;
      for (const r of Object.values(t?.Resources ?? {})) {
        if (r.Type === 'AWS::CertificateManager::Certificate') names.push(String(r.Properties.DomainName));
        if (r.Type === 'AWS::Route53::RecordSet') names.push(String(r.Properties.Name).replace(/\.$/, ''));
      }
    }
    expect(names.length).toBeGreaterThanOrEqual(9);
    for (const n of names) expect(inside(n)).toBe(true);
  });
});
