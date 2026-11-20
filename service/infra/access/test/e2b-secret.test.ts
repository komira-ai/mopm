// Tests the e2b-secret command (lib/e2b-secret.ts, and its bin/ entry) against a fake Host standing in for `aws`. No
// AWS access. Proves: a dry run calls nothing and reads no key; --apply stores exactly one new version of
// mopm/<stage>/e2b with the JSON {"api_key": ...} and never creates or deletes a secret; the key is never in any
// argument, any output, any error, or any file left behind; every refusal changes nothing. Output is asserted line by
// line, so a key that slipped into a message would fail the equality, not only the leak check.
import * as fs from 'fs';
import { USAGE, e2bSecret } from '../lib/e2b-secret';
import { FakeHost, Reply, acct } from './fake-host';

const KEY = 'e2b_s3ntinel0123456789abcdef0123456789abcd';
const NAME = 'mopm/gamma/e2b';
const DESCRIBE = `aws secretsmanager describe-secret --profile p --region us-east-1 --secret-id ${NAME} --query Name --output text`;
const STS = 'aws sts get-caller-identity --profile p --query Account --output text';

type Mode = 'exists' | 'missing' | 'denied';
interface Seen { content: string; mode: number; path: string }

/**
 * The fake aws: sts answers profileAccount; describe-secret answers by mode; put-secret-value (run through inherit, as the
 * owner sees it) records the secret file's content and mode at call time and exits putStatus.
 */
function setup(mode: Mode, opts: { profileAccount?: string; putStatus?: number } = {}) {
  const seen: Seen[] = [];
  const host = new FakeHost(
    (argv: string[]): Reply | undefined => {
      if (argv[1] === 'sts') return { status: 0, output: `${opts.profileAccount ?? ''}\n` };
      if (argv[2] !== 'describe-secret') return undefined;
      if (mode === 'exists') return { status: 0, output: `${NAME}\n` };
      if (mode === 'missing') return { status: 254, output: "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: Secrets Manager can't find the specified secret." };
      return { status: 254, output: 'An error occurred (AccessDeniedException) when calling the DescribeSecret operation: not authorized\n' };
    },
    (argv: string[]): number => {
      const f = argv.find((a) => a.startsWith('file://'));
      if (f) {
        const p = f.slice('file://'.length);
        seen.push({ content: fs.readFileSync(p, 'utf8'), mode: fs.statSync(p).mode & 0o777, path: p });
      }
      return opts.putStatus ?? 0;
    },
  );
  return { host, seen };
}

const BASE = ['--stage', 'gamma', '--profile', 'p'];
const noRead = (): string => { throw new Error('the key was read'); };
const reading = (s: string) => ({ readKey: () => s });
const everything = (h: FakeHost): string => [h.out_, h.err_, ...h.calls.map((c) => c.argv.join(' '))].join('\n');
/** Does the key appear anywhere the owner or the process list could see it. */
const leaks = (h: FakeHost, secret: string): boolean => everything(h).includes(secret);
const put = (region: string, file: string) =>
  `aws secretsmanager put-secret-value --profile p --region ${region} --secret-id ${NAME} --secret-string file://${file} --output text --query VersionId`;

describe('dry run', () => {
  test('prints the commands, calls nothing, never reads the key', () => {
    const { host } = setup('exists');
    expect(e2bSecret(BASE, host, { readKey: noRead })).toBe(0);
    expect(host.outLines).toEqual([
      '# dry run: nothing is read, nothing is called. Re-run with --apply to act.',
      '# the secret string is JSON {"api_key": "<read from stdin>"}, passed to the CLI as a file (mode 600), never as an argument.',
      `DRY-RUN: ${DESCRIBE}`,
      `DRY-RUN: aws secretsmanager put-secret-value --profile p --region us-east-1 --secret-id ${NAME} --secret-string 'file://<temporary file>' --output text --query VersionId`,
      `# if ${NAME} does not exist this stops: deploy the stack on gamma first. It never creates the secret.`,
    ]);
    expect(host.errLines).toEqual([]);
    expect(host.calls).toEqual([]);
  });

  test('with --account and --region: the account check is shown too, still nothing is called', () => {
    const { host } = setup('exists');
    expect(e2bSecret([...BASE, '--account', acct('5'), '--region', 'us-west-2'], host, { readKey: noRead })).toBe(0);
    expect(host.outLines[2]).toBe(`DRY-RUN: ${STS}`);
    expect(host.outLines[3]).toBe(`DRY-RUN: ${DESCRIBE.replace('us-east-1', 'us-west-2')}`);
    expect(host.calls).toEqual([]);
  });

  test('--help prints the usage and nothing else', () => {
    const { host } = setup('exists');
    expect(e2bSecret(['--help'], host, { readKey: noRead })).toBe(0);
    expect(host.outLines).toEqual([USAGE]);
    expect(host.calls).toEqual([]);
  });
});

describe('--apply', () => {
  test('stores exactly one new version with {"api_key": key}, in a 600 file that is removed; never create or delete', () => {
    const { host, seen } = setup('exists');
    expect(e2bSecret([...BASE, '--apply'], host, reading(KEY))).toBe(0);
    expect(seen).toHaveLength(1);
    expect(JSON.parse(seen[0].content)).toEqual({ api_key: KEY });
    expect(seen[0].content).toBe(`{"api_key":"${KEY}"}`);
    expect(seen[0].mode).toBe(0o600);
    expect(fs.existsSync(seen[0].path)).toBe(false);
    expect(host.lines).toEqual([DESCRIBE, put('us-east-1', seen[0].path)]);
    expect(host.calls.map((c) => c.how)).toEqual(['capture', 'inherit']);
    expect(host.lines.some((l) => /create-secret|delete-secret|--force/.test(l))).toBe(false);
    expect(host.outLines).toEqual([
      `secret ${NAME} exists: storing a new version`,
      `+ ${put('us-east-1', seen[0].path)}`,
      `done: ${NAME} has a new version.`,
    ]);
    expect(host.errLines).toEqual([]);
    expect(leaks(host, KEY)).toBe(false);
  });

  test('--account matching the profile, and --region: the account is checked first, then the same single put', () => {
    const { host, seen } = setup('exists', { profileAccount: acct('5') });
    expect(e2bSecret([...BASE, '--account', acct('5'), '--region', 'us-west-2', '--apply'], host, reading(KEY))).toBe(0);
    expect(host.lines).toEqual([STS, DESCRIBE.replace('us-east-1', 'us-west-2'), put('us-west-2', seen[0].path)]);
    expect(leaks(host, KEY)).toBe(false);
  });

  test('the put fails: exit 1, the error names the command but not the key, and the file is still removed', () => {
    const { host, seen } = setup('exists', { putStatus: 255 });
    expect(e2bSecret([...BASE, '--apply'], host, reading(KEY))).toBe(1);
    expect(host.errLines).toEqual([`command failed with status 255: ${put('us-east-1', seen[0].path)}`]);
    expect(fs.existsSync(seen[0].path)).toBe(false);
    expect(leaks(host, KEY)).toBe(false);
  });

  test('an error while reading the key (ctrl-C at the prompt) propagates; nothing is stored', () => {
    const { host, seen } = setup('exists');
    expect(() => e2bSecret([...BASE, '--apply'], host, { readKey: () => { throw new Error('interrupted'); } })).toThrow(/^interrupted$/);
    expect(host.lines).toEqual([DESCRIBE]);
    expect(seen).toEqual([]);
  });
});

describe('refusals change nothing', () => {
  test('the secret does not exist: says to deploy the stack first, never creates it, never asks for the key', () => {
    const { host } = setup('missing');
    expect(e2bSecret([...BASE, '--apply'], host, { readKey: noRead })).toBe(1);
    expect(host.errLines).toEqual([`secret ${NAME} does not exist: deploy the stack on gamma first, then run this again. Nothing was changed.`]);
    expect(host.lines).toEqual([DESCRIBE]);
    expect(host.outLines).toEqual([]);
  });

  test('describe fails for another reason: stops with the AWS message, never asks for the key', () => {
    const { host } = setup('denied');
    expect(e2bSecret([...BASE, '--apply'], host, { readKey: noRead })).toBe(1);
    expect(host.errLines).toEqual([`cannot read ${NAME}: An error occurred (AccessDeniedException) when calling the DescribeSecret operation: not authorized`]);
    expect(host.lines).toEqual([DESCRIBE]);
  });

  test('--account of another account than the profile: refused before any secretsmanager call or key read', () => {
    const { host } = setup('exists', { profileAccount: acct('9') });
    expect(e2bSecret([...BASE, '--account', acct('5'), '--apply'], host, { readKey: noRead })).toBe(1);
    expect(host.errLines).toEqual([`refusing: profile p is in account ${acct('9')}, but --account says ${acct('5')}. Nothing was changed.`]);
    expect(host.lines).toEqual([STS]);
  });

  const BAD_KEY = 'the E2B API key has whitespace, a line break or a control character in it; E2B keys do not';
  test.each([
    ['empty key', '', 'the E2B API key is empty (give it on stdin)'],
    ['a newline in the middle', `${KEY.slice(0, 10)}\n${KEY.slice(10)}`, BAD_KEY],
    ['a carriage return in the middle', `${KEY.slice(0, 10)}\r${KEY.slice(10)}`, BAD_KEY],
    ['a space in the middle', `${KEY.slice(0, 10)} ${KEY.slice(10)}`, BAD_KEY],
    ['a leading space', ` ${KEY}`, BAD_KEY],
    ['a trailing tab', `${KEY}\t`, BAD_KEY],
    ['a second line (two keys pasted)', `${KEY}\n${KEY}`, BAD_KEY],
    ['a control character', `${KEY}\x1b`, BAD_KEY],
    ['a DEL character', `${KEY}\x7f`, BAD_KEY],
  ])('%s: exit 2 with an exact message, no put, no file', (_n, key, message) => {
    const { host, seen } = setup('exists');
    expect(e2bSecret([...BASE, '--apply'], host, reading(key))).toBe(2);
    expect(host.errLines).toEqual([message]);
    expect(host.lines).toEqual([DESCRIBE]);
    expect(seen).toEqual([]);
    expect(leaks(host, KEY.slice(10))).toBe(false);
  });

  test.each([
    ['no --stage', ['--profile', 'p'], '--stage must be beta, gamma or prod'],
    ['unknown stage', ['--stage', 'dev', '--profile', 'p'], '--stage must be beta, gamma or prod'],
    ['no --profile', ['--stage', 'beta'], '--profile is required'],
    ['empty --region', [...BASE, '--region', ''], '--region must not be empty'],
    ['--account not 12 digits', [...BASE, '--account', '123'], '--account must be 12 digits'],
    ['unknown flag (there is no --force)', [...BASE, '--force'], 'unknown flag: --force'],
    ['the key as a flag is not a flag', [...BASE, '--api-key', KEY], 'unknown flag: --api-key'],
    ['--stage without a value (at the end of the line)', ['--profile', 'p', '--apply', '--stage'], '--stage must be beta, gamma or prod'],
  ])('%s: exit 2, nothing called, the key never read', (_n, argv, message) => {
    const { host } = setup('exists');
    expect(e2bSecret(argv.includes('--apply') ? argv : [...argv, '--apply'], host, { readKey: noRead })).toBe(2);
    expect(host.errLines[0]).toBe(message);
    expect(host.errLines.slice(1)).toEqual(message.startsWith('unknown flag') ? [USAGE] : []);
    expect(host.calls).toEqual([]);
    expect(host.out_).toBe('');
  });
});

test('the bin entry forwards argv to the command with the real host: a dry run prints and sets exit code 0', () => {
  const written: string[] = [];
  const w = jest.spyOn(process.stdout, 'write').mockImplementation((s) => { written.push(String(s)); return true; });
  const savedArgv = process.argv;
  const savedCode = process.exitCode;
  process.argv = ['node', 'e2b-secret', '--stage', 'beta', '--profile', 'p'];
  try {
    jest.isolateModules(() => { require('../bin/e2b-secret'); });
    expect(process.exitCode).toBe(0);
    expect(written[0]).toBe('# dry run: nothing is read, nothing is called. Re-run with --apply to act.\n');
    expect(written.join('')).toContain('DRY-RUN: aws secretsmanager put-secret-value --profile p --region us-east-1 --secret-id mopm/beta/e2b');
  } finally {
    w.mockRestore();
    process.argv = savedArgv;
    process.exitCode = savedCode;
  }
});

// The leak check can fail: a key passed on the command line, or printed, is seen.
describe('the leak check can fail', () => {
  test('sees a key in an argument', () => {
    const h = new FakeHost();
    h.inherit(['aws', 'secretsmanager', 'put-secret-value', '--secret-string', KEY]);
    expect(leaks(h, KEY)).toBe(true);
  });
  test('sees a key in an error', () => {
    const h = new FakeHost();
    h.err(`bad key ${KEY}`);
    expect(leaks(h, KEY)).toBe(true);
  });
});
