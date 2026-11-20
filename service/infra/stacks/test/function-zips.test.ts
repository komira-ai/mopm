import * as crypto from 'crypto';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Template } from 'aws-cdk-lib/assertions';
import { STAGES } from '../lib/config';
import {
  Aws,
  MainDeps,
  RUST_FUNCTIONS,
  checkDeployed,
  checkZips,
  codeSha256,
  codeSha256Reader,
  lookupRoleArn,
  main,
  parseSums,
} from '../lib/function-zips';
import { RUST_ZIP_STUB_DIR, build } from './util';

const sha = (b: Buffer | string) => crypto.createHash('sha256').update(b).digest('hex');
const read = (f: string) => fs.readFileSync(f);

let scratch: string;
beforeAll(() => {
  scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-function-zips-'));
});
afterAll(() => {
  fs.rmSync(scratch, { recursive: true, force: true });
});

/** A zip directory: each function's zip holds `bytes-of-<name>`; `sums` is the sha256sum form unless given; `change` gives a zip other bytes than its sums line has, `skip` leaves a zip out. */
function zipDir(opts: { sums?: string | null; skip?: string[]; change?: Record<string, string> } = {}): string {
  const dir = fs.mkdtempSync(path.join(scratch, 'zips-'));
  const lines: string[] = [];
  for (const n of [...RUST_FUNCTIONS].sort()) {
    lines.push(`${sha(`bytes-of-${n}`)}  ${n}.zip`);
    if (!opts.skip?.includes(n)) fs.writeFileSync(path.join(dir, `${n}.zip`), opts.change?.[n] ?? `bytes-of-${n}`);
  }
  if (opts.sums !== null) fs.writeFileSync(path.join(dir, 'sums'), opts.sums ?? `${lines.join('\n')}\n`);
  return dir;
}

const want = (n: string) => codeSha256(sha(`bytes-of-${n}`));
const lambdaOf = (stage: string, n: string) => `mopm-${stage}-${n}`;

describe('parseSums', () => {
  test('reads each line as file -> hex, the final newline optional, empty text as no lines', () => {
    const a = 'a'.repeat(64);
    const b = 'b'.repeat(64);
    expect([...parseSums(`${a}  x.zip\n${b}  y.zip\n`)]).toEqual([['x.zip', a], ['y.zip', b]]);
    expect([...parseSums(`${a}  x.zip`)]).toEqual([['x.zip', a]]);
    expect(parseSums('').size).toBe(0);
  });

  test.each([
    ['a short hash', `${'a'.repeat(63)}  x.zip`],
    ['upper-case hex', `${'A'.repeat(64)}  x.zip`],
    ['one space', `${'a'.repeat(64)} x.zip`],
    ['no name', `${'a'.repeat(64)}  `],
    ['a blank line', `${'a'.repeat(64)}  x.zip\n\n`],
  ])('refuses %s, naming the line', (_what, text) => {
    const bad = text.split('\n').find((l) => !/^[0-9a-f]{64} {2}\S+$/.test(l)) as string;
    expect(() => parseSums(text)).toThrow(new Error(`sums: malformed line '${bad}'`));
  });

  test('refuses a file listed twice', () => {
    const a = 'a'.repeat(64);
    expect(() => parseSums(`${a}  x.zip\n${'b'.repeat(64)}  x.zip\n`)).toThrow(new Error("sums: 'x.zip' is listed twice"));
  });
});

test('codeSha256 is the base64 of the sha256 bytes (the vector of "abc")', () => {
  expect(codeSha256('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')).toBe('ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=');
});

describe('checkZips', () => {
  test('a directory whose sums list exactly the three zips, each matching, has no problem', () => {
    expect(checkZips(zipDir(), read)).toEqual([]);
  });

  test('missing sums is one problem naming the file', () => {
    const dir = zipDir({ sums: null });
    expect(checkZips(dir, read)).toEqual([expect.stringMatching(/^cannot use .*\/sums: ENOENT/)]);
  });

  test('a malformed sums line is reported with the line', () => {
    const dir = zipDir({ sums: 'nonsense\n' });
    expect(checkZips(dir, read)).toEqual([`cannot use ${path.join(dir, 'sums')}: sums: malformed line 'nonsense'`]);
  });

  test('a duplicate sums line is reported', () => {
    const line = `${sha('bytes-of-web-login')}  web-login.zip`;
    const dir = zipDir({ sums: `${line}\n${line}\n` });
    expect(checkZips(dir, read)).toEqual([`cannot use ${path.join(dir, 'sums')}: sums: 'web-login.zip' is listed twice`]);
  });

  test('a listed file that is not one of the three zips is reported', () => {
    const dir = zipDir();
    fs.appendFileSync(path.join(dir, 'sums'), `${'c'.repeat(64)}  extra.zip\n`);
    expect(checkZips(dir, read)).toEqual(['sums lists extra.zip, which is not one of web-login.zip, web-session.zip, tutorial-sandbox.zip']);
  });

  test('a function the sums do not list is reported', () => {
    const lines = ['web-login', 'web-session'].map((n) => `${sha(`bytes-of-${n}`)}  ${n}.zip`);
    expect(checkZips(zipDir({ sums: `${lines.join('\n')}\n` }), read)).toEqual(['sums does not list tutorial-sandbox.zip']);
  });

  test('a zip that is not in the directory is reported', () => {
    const problems = checkZips(zipDir({ skip: ['web-session'] }), read);
    expect(problems).toEqual([expect.stringMatching(/^web-session\.zip: cannot read: ENOENT/)]);
  });

  test('a zip whose bytes differ from its sums line is reported with both hashes', () => {
    const dir = zipDir({ change: { 'web-login': 'other bytes' } });
    expect(checkZips(dir, read)).toEqual([`web-login.zip: sha256 ${sha('other bytes')}, the sums say ${sha('bytes-of-web-login')}`]);
  });
});

describe('checkDeployed', () => {
  const live = (diff: Record<string, string> = {}) => (fn: string) => diff[fn] ?? want(fn.replace(/^mopm-[a-z]+-/, ''));

  test.each(STAGES)('%s: every function with the CodeSha256 of its zip has no problem, and each is asked by its Lambda name', (stage) => {
    const asked: string[] = [];
    const get = (fn: string) => {
      asked.push(fn);
      return live()(fn);
    };
    expect(checkDeployed(stage, zipDir(), get, read)).toEqual([]);
    expect(asked).toEqual(RUST_FUNCTIONS.map((n) => lambdaOf(stage, n)));
  });

  test('one function running other bytes is the only problem', () => {
    const got = codeSha256(sha('stale'));
    expect(checkDeployed('gamma', zipDir(), live({ 'mopm-gamma-web-session': got }), read)).toEqual([
      `mopm-gamma-web-session: CodeSha256 ${got}, the sums say ${want('web-session')} (web-session.zip)`,
    ]);
  });

  test('a function whose CodeSha256 cannot be read is reported with the reason, the others still checked', () => {
    const get = (fn: string) => {
      if (fn === 'mopm-beta-web-login') throw new Error('ResourceNotFoundException');
      return live({ 'mopm-beta-tutorial-sandbox': 'x' })(fn);
    };
    expect(checkDeployed('beta', zipDir(), get, read)).toEqual([
      'mopm-beta-web-login: could not read CodeSha256: ResourceNotFoundException',
      `mopm-beta-tutorial-sandbox: CodeSha256 x, the sums say ${want('tutorial-sandbox')} (tutorial-sandbox.zip)`,
    ]);
  });

  test('a bad zip directory is reported without asking any function', () => {
    const get = jest.fn();
    const dir = zipDir({ sums: null });
    expect(checkDeployed('prod', dir, get, read)).toEqual([expect.stringMatching(/^cannot use .*\/sums: ENOENT/)]);
    expect(get).not.toHaveBeenCalled();
  });

  test('zips that do not match their sums are reported without asking any function', () => {
    const get = jest.fn();
    expect(checkDeployed('prod', zipDir({ change: { 'web-login': 'x' } }), get, read)).toEqual([
      `web-login.zip: sha256 ${sha('x')}, the sums say ${sha('bytes-of-web-login')}`,
    ]);
    expect(get).not.toHaveBeenCalled();
  });
});

/** A 12-digit account id, written so that no 12-digit number is in the file (the hygiene scan refuses one). */
const ACCOUNT = '1'.repeat(12);
const CREDS = { AccessKeyId: 'AKID', SecretAccessKey: 'SECRET', SessionToken: 'TOKEN' };
const LOOKUP_ENV = { AWS_ACCESS_KEY_ID: 'AKID', AWS_SECRET_ACCESS_KEY: 'SECRET', AWS_SESSION_TOKEN: 'TOKEN' };

/** A fake AWS CLI: `sts assume-role` answers `assume` (the lookup role's credentials by default); `lambda get-function-configuration`
 * answers `codeSha(name)` plus a newline, as the CLI prints it. Every call is recorded with its environment. */
function fakeAws(opts: { assume?: () => string; codeSha?: (fn: string) => string } = {}) {
  const calls: { args: string[]; env?: Record<string, string> }[] = [];
  const aws: Aws = (args, env) => {
    calls.push({ args, env });
    if (args[0] === 'sts') return (opts.assume ?? (() => JSON.stringify(CREDS)))();
    const fn = args[args.indexOf('--function-name') + 1];
    return `${(opts.codeSha ?? ((f: string) => want(f.replace(/^mopm-[a-z]+-/, ''))))(fn)}\n`;
  };
  return { aws, calls };
}

describe('the CodeSha256 reader', () => {
  test('the lookup role is the CDK default qualifier role of the account and region', () => {
    expect(lookupRoleArn(ACCOUNT, 'us-east-1')).toBe(`arn:aws:iam::${ACCOUNT}:role/cdk-hnb659fds-lookup-role-${ACCOUNT}-us-east-1`);
  });

  test('assumes the lookup role once, and reads each function with its credentials alone', () => {
    const { aws, calls } = fakeAws();
    const read = codeSha256Reader(aws, 'gamma', ACCOUNT, 'us-east-1');
    expect(read('mopm-gamma-web-login')).toBe(want('web-login'));
    expect(read('mopm-gamma-web-session')).toBe(want('web-session'));
    expect(calls).toEqual([
      {
        args: [
          'sts', 'assume-role', '--role-arn', lookupRoleArn(ACCOUNT, 'us-east-1'), '--role-session-name', 'mopm-gamma-codesha256',
          '--duration-seconds', '900', '--query', 'Credentials', '--output', 'json',
        ],
        env: undefined,
      },
      {
        args: ['lambda', 'get-function-configuration', '--region', 'us-east-1', '--function-name', 'mopm-gamma-web-login', '--query', 'CodeSha256', '--output', 'text'],
        env: LOOKUP_ENV,
      },
      {
        args: ['lambda', 'get-function-configuration', '--region', 'us-east-1', '--function-name', 'mopm-gamma-web-session', '--query', 'CodeSha256', '--output', 'text'],
        env: LOOKUP_ENV,
      },
    ]);
  });

  test.each([
    ['no credentials object', 'null'],
    ['a missing session token', JSON.stringify({ AccessKeyId: 'AKID', SecretAccessKey: 'SECRET' })],
    ['a key that is not a string', JSON.stringify({ ...CREDS, AccessKeyId: 7 })],
  ])('an answer with %s is refused', (_what, answer) => {
    const { aws } = fakeAws({ assume: () => answer });
    expect(() => codeSha256Reader(aws, 'beta', ACCOUNT, 'us-east-1')('mopm-beta-web-login')).toThrow(
      'the lookup role answered without credentials',
    );
  });
});

describe('main', () => {
  function run(argv: string[], aws: Aws = fakeAws().aws) {
    const out: string[] = [];
    const err: string[] = [];
    const deps: MainDeps = { aws, readFile: read, out: (s) => out.push(s), err: (s) => err.push(s) };
    return { code: main(argv, deps), out, err };
  }
  const deployed = (stage: string, dir: string) => ['check-deployed', '--stage', stage, '--zip-dir', dir, '--account', ACCOUNT, '--region', 'us-east-1'];
  const USAGE =
    'usage: function-zips check-zips --zip-dir <dir> | check-deployed --stage <beta|gamma|prod> --zip-dir <dir> --account <id> --region <region>';

  test('check-zips prints one ok line per function and returns 0', () => {
    expect(run(['check-zips', '--zip-dir', zipDir()])).toEqual({
      code: 0,
      out: ['zip ok: web-login', 'zip ok: web-session', 'zip ok: tutorial-sandbox'],
      err: [],
    });
  });

  test('check-zips prints each problem to err and returns 1', () => {
    const dir = zipDir({ change: { 'web-login': 'x', 'web-session': 'y' } });
    expect(run(['check-zips', '--zip-dir', dir])).toEqual({
      code: 1,
      out: [],
      err: [
        `web-login.zip: sha256 ${sha('x')}, the sums say ${sha('bytes-of-web-login')}`,
        `web-session.zip: sha256 ${sha('y')}, the sums say ${sha('bytes-of-web-session')}`,
      ],
    });
  });

  test('check-deployed prints one ok line per function and returns 0, flags in any order', () => {
    const { aws, calls } = fakeAws();
    const r = run(['check-deployed', '--region', 'us-east-1', '--zip-dir', zipDir(), '--account', ACCOUNT, '--stage', 'beta'], aws);
    expect(r).toEqual({
      code: 0,
      out: ['deployed ok: web-login', 'deployed ok: web-session', 'deployed ok: tutorial-sandbox'],
      err: [],
    });
    expect(calls.map((c) => c.args[c.args.indexOf('--function-name') + 1] ?? c.args[0])).toEqual([
      'sts',
      'mopm-beta-web-login',
      'mopm-beta-web-session',
      'mopm-beta-tutorial-sandbox',
    ]);
  });

  test('check-deployed names a function that runs other bytes and returns 1', () => {
    const { aws } = fakeAws({ codeSha: (fn) => (fn === 'mopm-prod-web-login' ? 'zzz' : want(fn.replace(/^mopm-prod-/, ''))) });
    expect(run(deployed('prod', zipDir()), aws)).toEqual({
      code: 1,
      out: [],
      err: [`mopm-prod-web-login: CodeSha256 zzz, the sums say ${want('web-login')} (web-login.zip)`],
    });
  });

  test('a lookup role that cannot be assumed fails every function', () => {
    const { aws } = fakeAws({
      assume: () => {
        throw new Error('AccessDenied');
      },
    });
    expect(run(deployed('beta', zipDir()), aws)).toEqual({
      code: 1,
      out: [],
      err: RUST_FUNCTIONS.map((n) => `mopm-beta-${n}: could not read CodeSha256: AccessDenied`),
    });
  });

  test('a stage that is not beta, gamma or prod is a usage error', () => {
    expect(run(deployed('dev', zipDir()))).toEqual({ code: 2, out: [], err: ["stage must be one of beta, gamma, prod; got 'dev'"] });
  });

  test.each(['12345678901', '1234567890123', 'abcdefghijkl', ''])('the account %p is a usage error that does not repeat it', (acct) => {
    const argv = deployed('beta', 'd');
    argv[argv.indexOf('--account') + 1] = acct;
    expect(run(argv)).toEqual({ code: 2, out: [], err: ['--account is not a 12-digit account id'] });
  });

  test.each(['us-east', 'US-EAST-1', 'us-east-1a', ''])('the region %p is a usage error', (region) => {
    const argv = deployed('beta', 'd');
    argv[argv.indexOf('--region') + 1] = region;
    expect(run(argv)).toEqual({ code: 2, out: [], err: [`--region '${region}' is not a region name`] });
  });

  test.each([
    ['no command', []],
    ['an unknown command', ['check']],
    ['check-zips without its directory', ['check-zips']],
    ['check-zips with a stage', ['check-zips', '--stage', 'beta', '--zip-dir', 'd']],
    ['check-deployed without a stage', ['check-deployed', '--zip-dir', 'd', '--account', ACCOUNT, '--region', 'us-east-1']],
    ['check-deployed without an account and region', ['check-deployed', '--stage', 'beta', '--zip-dir', 'd']],
    ['a repeated flag', ['check-deployed', '--stage', 'beta', '--stage', 'gamma', '--account', ACCOUNT, '--region', 'us-east-1']],
    ['a trailing argument', ['check-zips', '--zip-dir', 'd', 'extra']],
  ])('%s is a usage error', (_what, argv) => {
    expect(run(argv)).toEqual({ code: 2, out: [], err: [USAGE] });
  });
});

describe.each(STAGES)('the stack and the check agree on the functions (%s)', (stage) => {
  test('the provided.al2023 functions of the API stack are exactly mopm-<stage>-<each of RUST_FUNCTIONS>', () => {
    const t = Template.fromStack(build(stage, { rustZipDir: RUST_ZIP_STUB_DIR }).api);
    const names = Object.values(t.findResources('AWS::Lambda::Function', { Properties: { Runtime: 'provided.al2023' } }))
      .map((r: any) => r.Properties.FunctionName)
      .sort();
    expect(names).toEqual(RUST_FUNCTIONS.map((n) => lambdaOf(stage, n)).sort());
  });
});
