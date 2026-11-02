// Tests the oauth-secret command (lib/oauth-secret.ts) against a fake Host standing in for `aws`. No AWS access.
// Proves: a dry run touches nothing and does not read the secret; --apply creates or updates the right secret with the
// right JSON; the client secret is never in any argument, any output, or any file left behind; failures change nothing.
import * as fs from 'fs';
import { firstLine, oauthSecret } from '../lib/oauth-secret';
import { FakeHost, Reply, acct } from './fake-host';

const SENTINEL = 's3ntinel-client-secret-0123456789abcdef';
const ID = 'Iv1.abcdef0123456789';
const NAME = 'mopm/gamma/github-oauth';

type Mode = 'exists' | 'missing' | 'denied';
interface Seen { content: string; mode: number; path: string }

/** The fake aws (in setup): describe-secret answers by mode; create/put record the secret file's content and mode at call time. */
function fakeSts(profileAccount?: string) {
  return (argv: string[]): Reply | undefined => (argv[1] === 'sts' ? { status: 0, output: profileAccount ?? '' } : undefined);
}
function setup(mode: Mode, profileAccount?: string) {
  const seen: Seen[] = [];
  const host = new FakeHost(fakeSts(profileAccount));
  const base = host.capture.bind(host);
  host.capture = (argv: string[]): Reply => {
    const f = argv.find((a) => a.startsWith('file://'));
    if (f) {
      const p = f.slice('file://'.length);
      seen.push({ content: fs.readFileSync(p, 'utf8'), mode: fs.statSync(p).mode & 0o777, path: p });
    }
    if (argv[2] === 'describe-secret') {
      if (mode === 'exists') return { status: 0, output: `${NAME}\n` };
      if (mode === 'missing') return { status: 254, output: "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: Secrets Manager can't find the specified secret." };
      return { status: 254, output: 'An error occurred (AccessDeniedException) when calling the DescribeSecret operation: not authorized' };
    }
    return base(argv);
  };
  // create/put go through inherit (they are shown to the admin): record the file there too.
  const inh = host.inherit.bind(host);
  host.inherit = (argv: string[]): number => {
    const f = argv.find((a) => a.startsWith('file://'));
    if (f) {
      const p = f.slice('file://'.length);
      seen.push({ content: fs.readFileSync(p, 'utf8'), mode: fs.statSync(p).mode & 0o777, path: p });
    }
    return inh(argv);
  };
  return { host, seen };
}

const BASE = ['--stage', 'gamma', '--profile', 'p', '--client-id', ID];
const noRead = (): string => { throw new Error('the dry run read the secret'); };
const reading = (s: string) => ({ readSecret: () => s });
const everything = (h: FakeHost): string => [h.out_, h.err_, ...h.calls.map((c) => c.argv.join(' '))].join('\n');
/** The check the argv/output assertions use: does the secret appear anywhere the admin or the process list could see. */
const leaks = (h: FakeHost, secret: string): boolean => everything(h).includes(secret);

test('dry run: prints the commands, calls nothing, never reads or mentions the secret', () => {
  const { host } = setup('exists');
  expect(oauthSecret(BASE, host, { readSecret: noRead })).toBe(0);
  expect(host.out_).toContain('DRY-RUN: aws secretsmanager create-secret');
  expect(host.out_).toContain(NAME);
  expect(host.calls).toEqual([]);
});

test('--apply, secret missing: created with the JSON from the secret, in a 600 file, nothing left behind', () => {
  const { host, seen } = setup('missing');
  expect(oauthSecret([...BASE, '--apply'], host, reading(SENTINEL))).toBe(0);
  const create = host.lines.find((l) => l.includes('secretsmanager create-secret'))!;
  expect(create).toContain(`--profile p --region us-east-1 --name ${NAME}`);
  expect(host.lines.some((l) => l.includes('put-secret-value'))).toBe(false);
  expect(seen).toHaveLength(1);
  expect(JSON.parse(seen[0].content)).toEqual({ client_id: ID, client_secret: SENTINEL });
  expect(seen[0].mode).toBe(0o600);
  expect(fs.existsSync(seen[0].path)).toBe(false);
  expect(leaks(host, SENTINEL)).toBe(false);
});

test('--apply, secret exists: a new version, not a second create', () => {
  const { host, seen } = setup('exists');
  expect(oauthSecret([...BASE, '--apply', '--region', 'us-west-2'], host, reading(SENTINEL))).toBe(0);
  expect(host.lines.some((l) => l.includes(`secretsmanager put-secret-value --profile p --region us-west-2 --secret-id ${NAME}`))).toBe(true);
  expect(host.lines.some((l) => l.includes('create-secret'))).toBe(false);
  expect(fs.existsSync(seen[0].path)).toBe(false);
  expect(leaks(host, SENTINEL)).toBe(false);
});

test('--apply, describe fails for another reason: stop, change nothing, and the file is still removed', () => {
  const { host } = setup('denied');
  expect(oauthSecret([...BASE, '--apply'], host, reading(SENTINEL))).toBe(1);
  expect(host.lines.some((l) => l.includes('create-secret') || l.includes('put-secret-value'))).toBe(false);
  expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
  expect(leaks(host, SENTINEL)).toBe(false);
});

describe('bad input changes nothing and calls nothing', () => {
  test.each([
    ['empty secret', BASE, ''],
    ['secret with a space', BASE, 'has a space'],
    ['secret with a double quote', BASE, 'ab"cd'],
    ['secret with a backslash', BASE, 'ab\\cd'],
    ['bad stage', ['--stage', 'dev', '--profile', 'p', '--client-id', ID], SENTINEL],
    ['missing profile', ['--stage', 'beta', '--client-id', ID], SENTINEL],
    ['bad client id', ['--stage', 'beta', '--profile', 'p', '--client-id', 'bad id'], SENTINEL],
    ['no client id', ['--stage', 'beta', '--profile', 'p'], SENTINEL],
    ['unknown flag (there is no --force)', [...BASE, '--force'], SENTINEL],
    ['empty region', [...BASE, '--region', ''], SENTINEL],
    ['bad account', [...BASE, '--account', '123'], SENTINEL],
  ])('%s exits 2', (_n, a, secret) => {
    const { host } = setup('missing');
    expect(oauthSecret([...a, '--apply'], host, reading(secret))).toBe(2);
    expect(host.calls).toEqual([]);
    expect(leaks(host, SENTINEL)).toBe(false);
  });
});

describe('wrong account', () => {
  test('--apply with --account of another account than the profile: refused before the secret is read or anything changes', () => {
    const { host } = setup('missing', acct('9'));
    expect(oauthSecret([...BASE, '--account', acct('5'), '--apply'], host, { readSecret: noRead })).toBe(1);
    expect(host.err_).toContain('refusing');
    expect(host.calls.filter((c) => c.how === 'inherit')).toEqual([]);
    expect(host.lines.some((l) => l.includes('secretsmanager'))).toBe(false);
  });
  test('--account that matches the profile goes ahead', () => {
    const { host } = setup('missing', acct('5'));
    expect(oauthSecret([...BASE, '--account', acct('5'), '--apply'], host, reading(SENTINEL))).toBe(0);
    expect(host.lines.some((l) => l.includes('create-secret'))).toBe(true);
  });
});

test('the secret is the first line of stdin, without its newline', () => {
  expect(firstLine(`${SENTINEL}\n`)).toBe(SENTINEL);
  expect(firstLine(`${SENTINEL}\r\nsecond`)).toBe(SENTINEL);
  expect(firstLine(SENTINEL)).toBe(SENTINEL);
  expect(firstLine('')).toBe('');
});

// Can-fail proof of the leak check: a command that passed the secret on the command line, or printed it, is seen.
describe('the leak check can fail', () => {
  test('sees a secret in an argument', () => {
    const h = new FakeHost();
    h.inherit(['aws', 'secretsmanager', 'create-secret', '--secret-string', SENTINEL]);
    expect(leaks(h, SENTINEL)).toBe(true);
  });
  test('sees a secret in the output', () => {
    const h = new FakeHost();
    h.out(`stored ${SENTINEL}`);
    expect(leaks(h, SENTINEL)).toBe(true);
  });
});
