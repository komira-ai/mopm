// Tests the app-secret command (lib/app-secret.ts) against a fake Host standing in for `aws`. No AWS access.
// Proves: a dry run touches nothing and reads no key; --apply creates or updates mopm/<stage>/github-app with the right
// JSON; the private key is never in any argument, any output, or any file left behind; bad input and failures change nothing.
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { appSecret } from '../lib/app-secret';
import { FakeHost, Reply, acct } from './fake-host';

const BODY = 'MIIEowIBAAKCAQEAs3ntinelPrivateKeyBody0123456789abcdef+/=';
const PEM = `-----BEGIN RSA PRIVATE KEY-----\n${BODY}\n-----END RSA PRIVATE KEY-----\n`;
const NAME = 'mopm/gamma/github-app';

type Mode = 'exists' | 'missing' | 'denied';
interface Seen { content: string; mode: number; path: string }

function setup(mode: Mode, profileAccount?: string) {
  const seen: Seen[] = [];
  const host = new FakeHost((argv: string[]): Reply | undefined => (argv[1] === 'sts' ? { status: 0, output: profileAccount ?? '' } : undefined));
  const record = (argv: string[]) => {
    const f = argv.find((a) => a.startsWith('file://'));
    if (f) {
      const p = f.slice('file://'.length);
      seen.push({ content: fs.readFileSync(p, 'utf8'), mode: fs.statSync(p).mode & 0o777, path: p });
    }
  };
  const base = host.capture.bind(host);
  host.capture = (argv: string[]): Reply => {
    record(argv);
    if (argv[2] === 'describe-secret') {
      if (mode === 'exists') return { status: 0, output: `${NAME}\n` };
      if (mode === 'missing') return { status: 254, output: 'An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation' };
      return { status: 254, output: 'An error occurred (AccessDeniedException) when calling the DescribeSecret operation: not authorized' };
    }
    return base(argv);
  };
  const inh = host.inherit.bind(host);
  host.inherit = (argv: string[]): number => (record(argv), inh(argv));
  return { host, seen };
}

// The test's own scratch directory, standing in for the workspace scratch directory an operator passes.
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), 'app-secret-test-'));
afterAll(() => fs.rmSync(SCRATCH, { recursive: true, force: true }));
const BASE = ['--stage', 'gamma', '--profile', 'p', '--app-id', '123456', '--key-file', 'app.pem', '--scratch', SCRATCH];
const noRead = (): string => { throw new Error('the dry run read the key'); };
const reading = (s: string) => ({ readKey: () => s });
const everything = (h: FakeHost): string => [h.out_, h.err_, ...h.calls.map((c) => c.argv.join(' '))].join('\n');
const leaks = (h: FakeHost): boolean => everything(h).includes(BODY);

test('dry run: prints the commands, calls nothing, never reads the key file', () => {
  const { host } = setup('exists');
  expect(appSecret(BASE, host, { readKey: noRead })).toBe(0);
  expect(host.out_).toContain('DRY-RUN: aws secretsmanager create-secret');
  expect(host.out_).toContain(NAME);
  expect(host.calls).toEqual([]);
});

test('--help prints the usage and exits 0', () => {
  const { host } = setup('exists');
  expect(appSecret(['--help'], host, { readKey: noRead })).toBe(0);
  expect(host.out_).toContain('usage: app-secret');
});

test('--apply, secret missing: created with {app_id, private_key}, in a 600 file, nothing left behind, key not shown', () => {
  const { host, seen } = setup('missing');
  expect(appSecret([...BASE, '--apply'], host, reading(PEM))).toBe(0);
  expect(host.lines.find((l) => l.includes('secretsmanager create-secret'))).toContain(`--profile p --region us-east-1 --name ${NAME}`);
  expect(host.lines.some((l) => l.includes('put-secret-value'))).toBe(false);
  expect(JSON.parse(seen[0].content)).toEqual({ app_id: '123456', private_key: PEM });
  expect(seen[0].mode).toBe(0o600);
  expect(path.dirname(path.dirname(seen[0].path))).toBe(SCRATCH);
  expect(path.basename(path.dirname(seen[0].path))).toMatch(/^mopm-app-/);
  expect(fs.existsSync(seen[0].path)).toBe(false);
  expect(fs.readdirSync(SCRATCH)).toEqual([]);
  expect(leaks(host)).toBe(false);
});

test('--apply stages the secret in a directory only the admin can read', () => {
  const { host } = setup('missing');
  const modes: number[] = [];
  const inh = host.inherit.bind(host);
  host.inherit = (argv: string[]): number => {
    const f = argv.find((a) => a.startsWith('file://'));
    if (f) modes.push(fs.statSync(path.dirname(f.slice('file://'.length))).mode & 0o777);
    return inh(argv);
  };
  expect(appSecret([...BASE, '--apply'], host, reading(PEM))).toBe(0);
  expect(modes).toEqual([0o700]);
});

test('--apply with a --scratch that is not an existing directory exits 2, calls nothing, writes nothing', () => {
  const file = path.join(SCRATCH, 'not-a-dir');
  fs.writeFileSync(file, 'x');
  try {
    for (const scratch of [path.join(SCRATCH, 'missing'), file]) {
      const { host } = setup('missing');
      const args = [...BASE.slice(0, -2), '--scratch', scratch, '--apply'];
      expect(appSecret(args, host, reading(PEM))).toBe(2);
      expect(host.err_).toContain(`--scratch ${scratch} is not an existing directory`);
      expect(host.calls).toEqual([]);
      expect(leaks(host)).toBe(false);
    }
  } finally {
    fs.rmSync(file);
  }
  expect(fs.readdirSync(SCRATCH)).toEqual([]);
});

test('the dry run names the scratch directory the secret would be staged in', () => {
  const { host } = setup('exists');
  expect(appSecret(BASE, host, { readKey: noRead })).toBe(0);
  expect(host.out_).toContain(`under ${SCRATCH}`);
});

test('--apply, secret exists: a new version, not a second create', () => {
  const { host, seen } = setup('exists');
  expect(appSecret([...BASE, '--apply', '--region', 'us-west-2'], host, reading(PEM))).toBe(0);
  expect(host.lines.some((l) => l.includes(`secretsmanager put-secret-value --profile p --region us-west-2 --secret-id ${NAME}`))).toBe(true);
  expect(host.lines.some((l) => l.includes('create-secret'))).toBe(false);
  expect(fs.existsSync(seen[0].path)).toBe(false);
  expect(leaks(host)).toBe(false);
});

test('--apply, describe fails for another reason: stop, change nothing', () => {
  const { host } = setup('denied');
  expect(appSecret([...BASE, '--apply'], host, reading(PEM))).toBe(1);
  expect(host.lines.some((l) => l.includes('create-secret') || l.includes('put-secret-value'))).toBe(false);
  expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
  expect(leaks(host)).toBe(false);
});

test('--apply with an unreadable key file exits 2 and names the path, not any content', () => {
  const { host } = setup('missing');
  expect(appSecret([...BASE, '--apply'], host, { readKey: () => { throw new Error(`ENOENT ${BODY}`); } })).toBe(2);
  expect(host.err_).toContain('cannot read --key-file app.pem');
  expect(host.calls).toEqual([]);
  expect(leaks(host)).toBe(false);
});

describe('bad input changes nothing and calls nothing', () => {
  test.each([
    ['key file that is not a PEM key', BASE, 'hello'],
    ['a certificate instead of a key', BASE, `-----BEGIN CERTIFICATE-----\n${BODY}\n-----END CERTIFICATE-----\n`],
    ['bad stage', ['--stage', 'dev', '--profile', 'p', '--app-id', '1', '--key-file', 'k'], PEM],
    ['missing profile', ['--stage', 'beta', '--app-id', '1', '--key-file', 'k'], PEM],
    ['app id not a number', ['--stage', 'beta', '--profile', 'p', '--app-id', 'abc', '--key-file', 'k'], PEM],
    ['app id with a leading zero', ['--stage', 'beta', '--profile', 'p', '--app-id', '012', '--key-file', 'k'], PEM],
    ['no app id', ['--stage', 'beta', '--profile', 'p', '--key-file', 'k'], PEM],
    ['no key file', ['--stage', 'beta', '--profile', 'p', '--app-id', '1'], PEM],
    ['no scratch directory', ['--stage', 'beta', '--profile', 'p', '--app-id', '1', '--key-file', 'k'], PEM],
    ['unknown flag (there is no --force)', [...BASE, '--force'], PEM],
    ['empty region', [...BASE, '--region', ''], PEM],
    ['bad account', [...BASE, '--account', '123'], PEM],
  ])('%s exits 2', (_n, a, key) => {
    const { host } = setup('missing');
    expect(appSecret([...a, '--apply'], host, reading(key))).toBe(2);
    expect(host.calls).toEqual([]);
    expect(leaks(host)).toBe(false);
  });
});

describe('wrong account', () => {
  test('--account of another account than the profile: refused before the key is read or anything changes', () => {
    const { host } = setup('missing', acct('9'));
    expect(appSecret([...BASE, '--account', acct('5'), '--apply'], host, { readKey: noRead })).toBe(1);
    expect(host.err_).toContain('refusing');
    expect(host.lines.some((l) => l.includes('secretsmanager'))).toBe(false);
  });
  test('--account that matches the profile goes ahead', () => {
    const { host } = setup('missing', acct('5'));
    expect(appSecret([...BASE, '--account', acct('5'), '--apply'], host, reading(PEM))).toBe(0);
    expect(host.lines.some((l) => l.includes('create-secret'))).toBe(true);
  });
});
