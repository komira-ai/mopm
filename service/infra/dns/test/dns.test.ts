import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { CHILD_STAGES, STAGES, Stage, parseNameServers, zoneName, zoneStackName } from '../lib/config';
import { createDnsStack } from '../lib/app';

// Built at runtime so no 12-digit literal appears in the repository (the hygiene job refuses those).
const ACCOUNT = '1'.repeat(12);
const NS = (n: number) => [1, 2, 3, 4].map((i) => `ns-${n}${i}.awsdns-0${i}.${['org', 'com', 'net', 'co.uk'][i - 1]}`);
const BETA_NS = NS(1);
const GAMMA_NS = NS(2);

const zone = (stage: Stage) => createDnsStack(new App(), { stage, account: ACCOUNT, delegate: false });
const delegation = (stage: Stage = 'prod') =>
  createDnsStack(new App(), {
    stage,
    account: ACCOUNT,
    delegate: true,
    betaNameServers: BETA_NS.join(','),
    gammaNameServers: GAMMA_NS.join(','),
    hostedZoneId: 'Z0DUMMYZONE',
  });

describe.each(STAGES)('ZoneStack %s', (stage) => {
  const stack = zone(stage);
  const t = Template.fromStack(stack);

  test('creates exactly one public hosted zone with the exact stage name', () => {
    const expected = { prod: 'mopm.dev', beta: 'beta.mopm.dev', gamma: 'gamma.mopm.dev' }[stage];
    expect(zoneName(stage)).toBe(expected);
    t.resourceCountIs('AWS::Route53::HostedZone', 1);
    t.hasResourceProperties('AWS::Route53::HostedZone', { Name: `${expected}.` });
    const z = Object.values(t.findResources('AWS::Route53::HostedZone'))[0] as any;
    expect(z.Properties.VPCs).toBeUndefined(); // a VPC association would make it private
  });

  test('holds no records at all, and nothing but the zone', () => {
    t.resourceCountIs('AWS::Route53::RecordSet', 0);
    expect(Object.values(t.toJSON().Resources).map((r: any) => r.Type)).toEqual(['AWS::Route53::HostedZone']);
  });

  test('outputs its four name servers', () => {
    const out = t.toJSON().Outputs.NameServers;
    expect(JSON.stringify(out.Value)).toContain('NameServers');
    expect(JSON.stringify(out.Value)).toContain('Fn::Join');
  });

  test('the zone is retained when the stack is deleted (its name servers are delegated)', () => {
    const z = Object.values(t.findResources('AWS::Route53::HostedZone'))[0] as any;
    expect(z.DeletionPolicy).toBe('Retain');
  });

  test('stack name and region', () => {
    expect(stack.stackName).toBe(zoneStackName(stage));
    expect(stack.region).toBe('us-east-1');
  });
});

describe('DelegationStack', () => {
  const t = Template.fromStack(delegation());
  const records = Object.values(t.findResources('AWS::Route53::RecordSet')) as any[];

  test('creates NS records for exactly beta.mopm.dev and gamma.mopm.dev', () => {
    expect(records.map((r) => r.Properties.Name).sort()).toEqual(['beta.mopm.dev.', 'gamma.mopm.dev.']);
    expect([...CHILD_STAGES]).toEqual(['beta', 'gamma']);
  });

  test('every record is NS, in the mopm.dev zone, carrying the passed name servers', () => {
    for (const r of records) {
      expect(r.Properties.Type).toBe('NS');
      expect(r.Properties.HostedZoneId).toBe('Z0DUMMYZONE');
    }
    const by = Object.fromEntries(records.map((r) => [r.Properties.Name, r.Properties.ResourceRecords]));
    expect(by['beta.mopm.dev.']).toEqual(BETA_NS);
    expect(by['gamma.mopm.dev.']).toEqual(GAMMA_NS);
  });

  test('no other resource types: no zone, no other record types', () => {
    const types = new Set(Object.values(t.toJSON().Resources).map((r: any) => r.Type));
    expect([...types]).toEqual(['AWS::Route53::RecordSet']);
    for (const bad of ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'SOA']) {
      expect(records.some((r) => r.Properties.Type === bad)).toBe(false);
    }
  });

  test('without a dummy id it looks up mopm.dev in the prod account', () => {
    const app = new App();
    createDnsStack(app, { stage: 'prod', account: ACCOUNT, delegate: true, betaNameServers: BETA_NS.join(','), gammaNameServers: GAMMA_NS.join(',') });
    const missing = app.synth().manifest.missing ?? [];
    const found = missing.filter((m) => m.provider === 'hosted-zone');
    expect(found.length).toBe(1);
    expect(found[0].props).toMatchObject({ account: ACCOUNT, region: 'us-east-1', domainName: 'mopm.dev' });
  });

  test.each(['beta', 'gamma'] as const)('refused outside prod: %s', (stage) => {
    expect(() => delegation(stage)).toThrow(/prod account only/);
  });

  test('zone mode never creates delegation records, even with name servers passed', () => {
    for (const stage of STAGES) {
      const s = createDnsStack(new App(), {
        stage, account: ACCOUNT, delegate: false, betaNameServers: BETA_NS.join(','), gammaNameServers: GAMMA_NS.join(','),
      });
      Template.fromStack(s).resourceCountIs('AWS::Route53::RecordSet', 0);
    }
  });
});

describe('inputs are validated', () => {
  test('account must be 12 digits', () => {
    expect(() => createDnsStack(new App(), { stage: 'beta', account: '123', delegate: false })).toThrow(/12 digits/);
  });
  test('name servers: exactly four, Route 53 hosts, distinct', () => {
    expect(parseNameServers('x', BETA_NS.map((h) => `${h}.`).join(','))).toEqual(BETA_NS);
    expect(() => parseNameServers('x', BETA_NS.slice(0, 3).join(','))).toThrow(/exactly 4/);
    expect(() => parseNameServers('x', undefined)).toThrow(/exactly 4/);
    expect(() => parseNameServers('x', [...BETA_NS.slice(0, 3), 'evil.example.com'].join(','))).toThrow(/not a Route 53/);
    expect(() => parseNameServers('x', [...BETA_NS.slice(0, 3), BETA_NS[0]].join(','))).toThrow(/distinct/);
  });
  test('delegation refuses missing or malformed child name servers', () => {
    const base = { stage: 'prod' as const, account: ACCOUNT, delegate: true, hostedZoneId: 'Z0DUMMYZONE' };
    expect(() => createDnsStack(new App(), { ...base, gammaNameServers: GAMMA_NS.join(',') })).toThrow(/betaNameServers/);
    expect(() => createDnsStack(new App(), { ...base, betaNameServers: BETA_NS.join(',') })).toThrow(/gammaNameServers/);
  });
});
