// Tests the bootstrap command (lib/bootstrap.ts) against a fake Host standing in for `aws`, npm and cdk. No AWS access,
// no process is run. Ports the old bootstrap.sh checks: the dry run executes nothing and validates its flags; the cdk
// context and the --approve-iam gate; and every --update-policy / --policy-only scenario. Adds the wrong-account refusal.
import * as fs from 'fs';
import * as path from 'path';
import { bootstrap, renderPolicy, sortKeys } from '../lib/bootstrap';
import { FakeHost, Reply, acct } from './fake-host';

const TEMPLATE = path.join(__dirname, '..', 'cfn-exec-policy.template.json');
const ACCT = acct('5');
const OLD = '{"Version":"2012-10-17","Statement":[{"Sid":"Old","Effect":"Allow","Action":"s3:*","Resource":"*"}]}';
const ARN = `arn:aws:iam::${ACCT}:policy/mopm-gamma-cfn-exec`;

interface World {
  /** 'missing' | the document the current default version holds | 'rendered' (identical to the template) */
  current: string;
  versions: number;
  profileAccount?: string;
}

function world(w: World) {
  const rendered = renderPolicy(fs.readFileSync(TEMPLATE, 'utf8'), 'gamma', ACCT);
  return (argv: string[]): Reply | undefined => {
    const [, svc, op] = argv;
    if (svc === 'sts' && op === 'get-caller-identity') return { status: 0, output: `${w.profileAccount ?? ACCT}\n` };
    if (svc === 'iam' && op === 'get-policy') {
      return w.current === 'missing'
        ? { status: 254, output: 'An error occurred (NoSuchEntity) when calling the GetPolicy operation' }
        : { status: 0, output: 'v5\n' };
    }
    if (svc === 'iam' && op === 'get-policy-version') return { status: 0, output: w.current === 'rendered' ? rendered : w.current };
    if (svc === 'iam' && op === 'list-policy-versions') {
      return argv.join(' ').includes('length(') ? { status: 0, output: `${w.versions}\n` } : { status: 0, output: 'v2\n' };
    }
    return undefined;
  };
}

const args = (...extra: string[]) => ['--stage', 'gamma', '--account', ACCT, '--region', 'us-east-1', '--profile', 'p', ...extra];
function run(w: World, ...extra: string[]) {
  const host = new FakeHost(world(w));
  const rc = bootstrap(args(...extra), host, { templatePath: TEMPLATE });
  return { host, rc };
}
const mutations = (h: FakeHost) => h.lines.filter((l) => /iam (create-policy|create-policy-version|delete-policy-version)/.test(l));

describe('update-policy', () => {
  test('dry run, policy differs, 5 versions: diff shown, delete and create-version printed, nothing mutated', () => {
    const { host, rc } = run({ current: OLD, versions: 5 }, '--update-policy', '--policy-only');
    expect(rc).toBe(0);
    const out = host.out_;
    expect(out).toContain('--- current mopm-gamma-cfn-exec (v5)');
    expect(out).toContain('+++ new (gamma)');
    expect(out).toContain('+      "Sid": "Route53RecordsInStageZone"');
    expect(out).toContain('-      "Sid": "Old"');
    expect(out).toContain('gamma.mopm.dev');
    expect(out).toContain('DRY-RUN: aws iam delete-policy-version');
    expect(out).toContain('DRY-RUN: aws iam create-policy-version');
    expect(out).toContain('--set-as-default');
    expect(out).not.toMatch(/^\+ aws/m);
    expect(mutations(host)).toEqual([]);
    expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
    expect(out).not.toContain('cdk bootstrap');
  });

  test('--apply, differs, 5 versions: the oldest non-default is deleted first, then the new default version; no new policy', () => {
    const { host, rc } = run({ current: OLD, versions: 5 }, '--update-policy', '--policy-only', '--apply');
    expect(rc).toBe(0);
    const m = mutations(host);
    expect(m).toHaveLength(2);
    expect(m[0]).toBe(`aws iam delete-policy-version --profile p --policy-arn ${ARN} --version-id v2`);
    expect(m[1]).toContain('aws iam create-policy-version');
    expect(m[1]).toContain('--set-as-default');
    expect(host.lines.some((l) => l.includes('iam create-policy '))).toBe(false);
  });

  test('fewer than 5 versions: nothing is deleted', () => {
    const { host, rc } = run({ current: OLD, versions: 3 }, '--update-policy', '--policy-only', '--apply');
    expect(rc).toBe(0);
    expect(mutations(host)).toHaveLength(1);
    expect(mutations(host)[0]).toContain('create-policy-version');
  });

  test('differs but no --update-policy: stops, changes nothing, says how to proceed', () => {
    const { host, rc } = run({ current: OLD, versions: 5 }, '--policy-only', '--apply');
    expect(rc).not.toBe(0);
    expect(host.err_).toContain('DIFFERENT document');
    expect(host.err_).toContain('--update-policy');
    expect(mutations(host)).toEqual([]);
  });

  test('identical document: skipped and nothing mutated, even with --update-policy', () => {
    const { host, rc } = run({ current: 'rendered', versions: 5 }, '--update-policy', '--policy-only', '--apply');
    expect(rc).toBe(0);
    expect(host.out_).toContain('identical document');
    expect(mutations(host)).toEqual([]);
  });

  test('identical document in a different key order is still identical (compared by meaning)', () => {
    const rendered = renderPolicy(fs.readFileSync(TEMPLATE, 'utf8'), 'gamma', ACCT);
    const reordered = JSON.stringify(JSON.parse(rendered), (_k, v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).reverse()) : v));
    expect(reordered).not.toBe(JSON.stringify(JSON.parse(rendered)));
    const { host, rc } = run({ current: reordered, versions: 5 }, '--update-policy', '--policy-only', '--apply');
    expect(rc).toBe(0);
    expect(host.out_).toContain('identical document');
  });

  test('policy missing: it is created, with no version call', () => {
    const { host, rc } = run({ current: 'missing', versions: 0 }, '--update-policy', '--policy-only', '--apply');
    expect(rc).toBe(0);
    expect(host.lines.some((l) => l.startsWith('aws iam create-policy --profile p --policy-name mopm-gamma-cfn-exec'))).toBe(true);
    expect(host.lines.some((l) => l.includes('create-policy-version'))).toBe(false);
  });

  test('--policy-only never reaches npm or cdk', () => {
    const { host } = run({ current: 'missing', versions: 0 }, '--policy-only', '--apply');
    expect(host.out_).toContain('--policy-only');
    expect(host.lines.some((l) => /^(npm|npx)/.test(l))).toBe(false);
  });

  test('--apply cannot read the policy for another reason: stops before any change', () => {
    const host = new FakeHost((a) => (a[2] === 'get-policy' ? { status: 254, output: 'AccessDenied' } : a[1] === 'sts' ? { status: 0, output: ACCT } : undefined));
    const rc = bootstrap(args('--policy-only', '--apply'), host, { templatePath: TEMPLATE });
    expect(rc).toBe(1);
    expect(host.err_).toContain('cannot read');
    expect(host.calls.some((c) => c.how === 'inherit')).toBe(false);
  });

  test('dry run with --update-policy whose read fails prints the commands only', () => {
    const host = new FakeHost((a) => (a[2] === 'get-policy' ? { status: 254, output: 'AccessDenied' } : a[1] === 'sts' ? { status: 0, output: ACCT } : undefined));
    const rc = bootstrap(args('--policy-only', '--update-policy'), host, { templatePath: TEMPLATE });
    expect(rc).toBe(0);
    expect(host.out_).toContain('showing the commands only');
    expect(host.out_).toContain('DRY-RUN: aws iam create-policy-version');
  });
});

describe('dry run and flags', () => {
  const plain = () => {
    const host = new FakeHost();
    const rc = bootstrap(['--stage', 'beta', '--account', ACCT, '--region', 'us-west-2', '--profile', 'p'], host, { templatePath: TEMPLATE });
    return { host, rc };
  };

  test('is a dry run by default: prints the commands, executes and calls nothing', () => {
    const { host, rc } = plain();
    expect(rc).toBe(0);
    expect(host.out_).toMatch(/^DRY-RUN: aws iam create-policy/m);
    expect(host.out_).not.toMatch(/^\+ /m);
    expect(host.calls).toEqual([]);
  });

  test.each([
    ['bad stage', ['--stage', 'dev', '--account', ACCT, '--region', 'r', '--profile', 'p']],
    ['short account', ['--stage', 'beta', '--account', '123', '--region', 'r', '--profile', 'p']],
    ['account with a letter', ['--stage', 'beta', '--account', `${acct('1').slice(1)}x`, '--region', 'r', '--profile', 'p']],
    ['no region', ['--stage', 'beta', '--account', ACCT, '--profile', 'p']],
    ['no profile', ['--stage', 'beta', '--account', ACCT, '--region', 'r']],
    ['unknown flag (there is no --repo, no --force)', ['--stage', 'beta', '--account', ACCT, '--region', 'r', '--profile', 'p', '--repo', 'other/repo']],
    ['--force', ['--stage', 'beta', '--account', ACCT, '--region', 'r', '--profile', 'p', '--force']],
  ])('%s is a usage error (status 2) and nothing runs', (_n, a) => {
    const host = new FakeHost();
    expect(bootstrap(a, host, { templatePath: TEMPLATE })).toBe(2);
    expect(host.calls).toEqual([]);
    expect(host.out_).not.toContain('DRY-RUN');
  });

  test('passes the context to cdk bootstrap, shows a cdk diff, and defaults to --require-approval broadening', () => {
    const host = new FakeHost();
    expect(bootstrap(['--stage', 'beta', '--account', ACCT, '--region', 'us-east-1', '--profile', 'p'], host, { templatePath: TEMPLATE })).toBe(0);
    const out = host.outLines;
    const boot = out.find((l) => l.startsWith('DRY-RUN: npx cdk bootstrap'))!;
    for (const v of ['stage=beta', `account=${ACCT}`, 'region=us-east-1']) expect(boot).toContain(`-c ${v}`);
    expect(boot).toContain(`--cloudformation-execution-policies arn:aws:iam::${ACCT}:policy/mopm-beta-cfn-exec`);
    expect(out.some((l) => l.startsWith('DRY-RUN: npx cdk diff mopm-beta-access'))).toBe(true);
    const deploy = out.find((l) => l.startsWith('DRY-RUN: npx cdk deploy mopm-beta-access'))!;
    expect(deploy).toContain('--require-approval broadening');
    expect(out.join('\n')).not.toMatch(/--approve-iam|require-approval never/);
  });

  test('--approve-iam passes --require-approval never to the deploy', () => {
    const host = new FakeHost();
    bootstrap(['--stage', 'beta', '--account', ACCT, '--region', 'us-east-1', '--profile', 'p', '--approve-iam'], host, { templatePath: TEMPLATE });
    expect(host.out_).toContain('--require-approval never');
  });

  test('--help prints the usage and runs nothing', () => {
    const host = new FakeHost();
    expect(bootstrap(['--help'], host, { templatePath: TEMPLATE })).toBe(0);
    expect(host.out_).toContain('usage: bootstrap');
    expect(host.calls).toEqual([]);
  });
});

describe('apply', () => {
  test('runs, in order: create-policy, npm install, cdk bootstrap, cdk diff, cdk deploy (broadening)', () => {
    const { host, rc } = run({ current: 'missing', versions: 0 }, '--apply');
    expect(rc).toBe(0);
    const ran = host.calls.filter((c) => c.how === 'inherit').map((c) => c.argv.slice(0, 3).join(' '));
    expect(ran).toEqual(['aws iam create-policy', 'npm install --no-audit', 'npx cdk bootstrap', 'npx cdk diff', 'npx cdk deploy']);
  });

  test('a failing step stops the rest', () => {
    const host = new FakeHost(world({ current: 'missing', versions: 0 }), (a) => (a[0] === 'npm' ? 7 : 0));
    expect(bootstrap(args('--apply'), host, { templatePath: TEMPLATE })).toBe(1);
    expect(host.err_).toContain('status 7');
    expect(host.lines.some((l) => l.startsWith('npx'))).toBe(false);
  });

  test('a profile in another account is refused before anything changes', () => {
    const other = acct('9');
    const { host, rc } = run({ current: 'missing', versions: 0, profileAccount: other }, '--apply');
    expect(rc).toBe(1);
    expect(host.err_).toContain('refusing');
    expect(host.err_).toContain(other);
    expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
    expect(host.lines.some((l) => l.includes('iam get-policy'))).toBe(false);
  });

  test('--update-policy in a dry run also refuses a wrong account (it makes reads)', () => {
    const { host, rc } = run({ current: OLD, versions: 5, profileAccount: acct('9') }, '--update-policy', '--policy-only');
    expect(rc).toBe(1);
    expect(host.lines.some((l) => l.includes('iam get-policy'))).toBe(false);
  });

  test('a profile whose identity cannot be read is refused', () => {
    const host = new FakeHost((a) => (a[1] === 'sts' ? { status: 255, output: 'expired token' } : undefined));
    expect(bootstrap(args('--apply'), host, { templatePath: TEMPLATE })).toBe(1);
    expect(host.err_).toContain('cannot tell which account');
    expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
  });
});

describe('policy rendering', () => {
  const tpl = fs.readFileSync(TEMPLATE, 'utf8');
  test('fills stage, account and zone; the prod zone is the root zone', () => {
    const gamma = renderPolicy(tpl, 'gamma', ACCT);
    expect(gamma).not.toContain('{{');
    expect(gamma).toContain(ACCT);
    expect(gamma).toContain('gamma.mopm.dev');
    expect(renderPolicy(tpl, 'prod', ACCT)).not.toContain('prod.mopm.dev');
  });
  test('a placeholder the command does not fill is refused', () => {
    expect(() => renderPolicy(`${tpl}{{OTHER}}`, 'gamma', ACCT)).toThrow(/placeholder/);
  });
  test('sortKeys orders nested keys and leaves arrays in order', () => {
    expect(JSON.stringify(sortKeys({ b: [{ z: 1, a: 2 }, 1], a: null }))).toBe('{"a":null,"b":[{"a":2,"z":1},1]}');
  });
});
