// Tests the dns command (lib/dns-cli.ts) against a fake Host. No AWS access, no process is run. Ports the old dns.sh
// checks: a dry run by default that executes nothing, and strict flag validation; adds the wrong-account refusal.
import { dnsCli } from '../lib/dns-cli';
import { FakeHost, Reply, acct } from './fake-host';

const ACCT = acct('4');
const NS = (n: number) => [1, 2, 3, 4].map((i) => `ns-${n}${i}.awsdns-0${i}.${['org', 'com', 'net', 'co.uk'][i - 1]}`).join(',');
const BETA = NS(1);
const GAMMA = NS(2);
const zone = (...extra: string[]) => ['--stage', 'beta', '--account', ACCT, '--profile', 'p', ...extra];
const deleg = (...extra: string[]) => ['--stage', 'prod', '--delegate', '--beta-ns', BETA, '--gamma-ns', GAMMA, '--account', ACCT, '--profile', 'p', ...extra];
const inherited = (h: FakeHost) => h.calls.filter((c) => c.how === 'inherit').map((c) => c.argv.join(' '));

test('is a dry run by default: prints the deploy, executes and calls nothing', () => {
  const host = new FakeHost();
  expect(dnsCli(zone(), host)).toBe(0);
  expect(host.out_).toMatch(/^DRY-RUN: npx cdk deploy mopm-dns-beta-zone/m);
  expect(host.out_).toMatch(/^DRY-RUN: aws cloudformation describe-stacks .*--region us-east-1 --stack-name mopm-dns-beta-zone/m);
  expect(host.out_).not.toMatch(/^\+ /m);
  expect(host.calls).toEqual([]);
});

test('the zone deploy carries the stage and account as context and the broadening approval', () => {
  const host = new FakeHost();
  dnsCli(zone(), host);
  const d = host.outLines.find((l) => l.startsWith('DRY-RUN: npx cdk deploy'))!;
  expect(d).toContain('--require-approval broadening');
  expect(d).toContain('-c stage=beta');
  expect(d).toContain(`-c account=${ACCT}`);
  expect(d).not.toContain('delegate');
});

test('the delegation deploy carries the name servers and runs no describe-stacks', () => {
  const host = new FakeHost();
  expect(dnsCli(deleg(), host)).toBe(0);
  const d = host.outLines.find((l) => l.startsWith('DRY-RUN: npx cdk deploy mopm-dns-prod-delegation'))!;
  expect(d).toContain('-c delegate=true');
  expect(d).toContain(`-c betaNameServers=${BETA}`);
  expect(d).toContain(`-c gammaNameServers=${GAMMA}`);
  expect(host.out_).not.toContain('describe-stacks');
  expect(host.out_).toContain('dig +short NS beta.mopm.dev');
});

describe('validates its flags: status 2 and nothing runs', () => {
  const bad = [
    ['bad stage', ['--stage', 'dev', '--account', ACCT, '--profile', 'p']],
    ['short account', ['--stage', 'beta', '--account', '123', '--profile', 'p']],
    ['no profile', ['--stage', 'beta', '--account', ACCT]],
    ['--delegate without --stage prod', ['--stage', 'beta', '--delegate', '--account', ACCT, '--profile', 'p', '--beta-ns', BETA, '--gamma-ns', GAMMA]],
    ['--delegate without name servers', ['--stage', 'prod', '--delegate', '--account', ACCT, '--profile', 'p']],
    ['--delegate with one-letter name servers', ['--stage', 'prod', '--delegate', '--account', ACCT, '--profile', 'p', '--beta-ns', 'a,b,c,d', '--gamma-ns', 'a,b,c,d']],
    ['name servers with a trailing dot', deleg().map((a) => (a === BETA ? BETA.replace('.org', '.org.') : a))],
    ['three name servers', deleg().map((a) => (a === GAMMA ? GAMMA.split(',').slice(0, 3).join(',') : a))],
    ['five name servers', deleg().map((a) => (a === GAMMA ? `${GAMMA},${BETA.split(',')[0]}` : a))],
    ['name servers without --delegate', zone('--beta-ns', BETA)],
    ['unknown flag', zone('--force')],
  ] as [string, string[]][];
  test.each(bad)('%s', (_n, a) => {
    const host = new FakeHost();
    expect(dnsCli(a, host)).toBe(2);
    expect(host.calls).toEqual([]);
    expect(host.out_).not.toContain('DRY-RUN: npx cdk deploy');
  });
});

describe('apply', () => {
  const aws = (profileAccount: string) => (argv: string[]): Reply | undefined => {
    if (argv[1] === 'sts') return { status: 0, output: `${profileAccount}\n` };
    if (argv[1] === 'cloudformation') return { status: 0, output: 'ns-1.awsdns-01.org,ns-2.awsdns-02.com\n' };
    return undefined;
  };

  test('installs, deploys, then reads and prints the name servers', () => {
    const host = new FakeHost(aws(ACCT));
    expect(dnsCli(zone('--apply'), host)).toBe(0);
    expect(inherited(host).map((l) => l.split(' ').slice(0, 3).join(' '))).toEqual(['npm ci --ignore-scripts', 'npx cdk deploy']);
    expect(host.out_).toContain('# Name servers of the beta zone');
    expect(host.out_).toContain('ns-1.awsdns-01.org,ns-2.awsdns-02.com');
  });

  test('a profile in another account is refused before anything runs', () => {
    const host = new FakeHost(aws(acct('9')));
    expect(dnsCli(zone('--apply'), host)).toBe(1);
    expect(host.err_).toContain('refusing');
    expect(inherited(host)).toEqual([]);
  });

  test('a failing deploy stops before the name servers are read', () => {
    const host = new FakeHost(aws(ACCT), (a) => (a[1] === 'cdk' ? 1 : 0));
    expect(dnsCli(zone('--apply'), host)).toBe(1);
    expect(host.calls.some((c) => c.argv[1] === 'cloudformation')).toBe(false);
  });
});
