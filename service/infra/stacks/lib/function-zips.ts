// The Rust functions' zips as one deploy ships them: a directory of `<name>.zip` and a `sums` file (sha256sum form), built once
// per commit and deployed unchanged to every stage. `check-zips` proves the directory is what the sums say; `check-deployed`
// proves each deployed function runs those bytes (its CodeSha256 is the base64 of the zip's sha256).
import * as crypto from 'crypto';
import * as path from 'path';
import { Stage, StageConfig, assertStage } from './config';
import { rustFunctionName } from './rust-function';

/** The Rust functions, by name without the stage: the zips are `<name>.zip`, the Lambdas `mopm-<stage>-<name>`. */
export const RUST_FUNCTIONS: readonly string[] = ['web-login', 'web-session', 'tutorial-sandbox'];

export const SUMS_FILE = 'sums';

export type ReadFile = (file: string) => Buffer;

const SUMS_LINE = /^[0-9a-f]{64} {2}\S+$/;

/** The lines of a sums file as file name -> lower-hex sha256. A line that is not `<64 hex>  <name>` or repeats a name is refused. */
export function parseSums(text: string): Map<string, string> {
  const sums = new Map<string, string>();
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  for (const line of lines) {
    if (!SUMS_LINE.test(line)) throw new Error(`${SUMS_FILE}: malformed line '${line}'`);
    const file = line.slice(66);
    if (sums.has(file)) throw new Error(`${SUMS_FILE}: '${file}' is listed twice`);
    sums.set(file, line.slice(0, 64));
  }
  return sums;
}

/** What Lambda reports as a function's CodeSha256: the base64 of the 32 bytes of the zip's sha256. */
export const codeSha256 = (hex: string): string => Buffer.from(hex, 'hex').toString('base64');

const sha256Hex = (bytes: Buffer): string => crypto.createHash('sha256').update(bytes).digest('hex');

/** The sums of a directory, or the problem that stops them being read. */
function readSums(zipDir: string, readFile: ReadFile): { sums?: Map<string, string>; problem?: string } {
  try {
    return { sums: parseSums(readFile(path.join(zipDir, SUMS_FILE)).toString('utf8')) };
  } catch (e) {
    return { problem: `cannot use ${path.join(zipDir, SUMS_FILE)}: ${(e as Error).message}` };
  }
}

/** Problems of a zip directory: empty when `sums` lists exactly `<name>.zip` for each Rust function and each zip hashes to its line. */
export function checkZips(zipDir: string, readFile: ReadFile): string[] {
  const { sums, problem } = readSums(zipDir, readFile);
  return sums === undefined ? [problem as string] : zipProblems(zipDir, sums, readFile);
}

function zipProblems(zipDir: string, sums: Map<string, string>, readFile: ReadFile): string[] {
  const wanted = RUST_FUNCTIONS.map((n) => `${n}.zip`);
  const problems: string[] = [];
  for (const file of sums.keys()) {
    if (!wanted.includes(file)) problems.push(`${SUMS_FILE} lists ${file}, which is not one of ${wanted.join(', ')}`);
  }
  for (const file of wanted) {
    const want = sums.get(file);
    if (want === undefined) {
      problems.push(`${SUMS_FILE} does not list ${file}`);
      continue;
    }
    let bytes: Buffer;
    try {
      bytes = readFile(path.join(zipDir, file));
    } catch (e) {
      problems.push(`${file}: cannot read: ${(e as Error).message}`);
      continue;
    }
    const got = sha256Hex(bytes);
    if (got !== want) problems.push(`${file}: sha256 ${got}, the sums say ${want}`);
  }
  return problems;
}

/**
 * Problems of a deployed stage: those of the zip directory, or else one per function whose CodeSha256 is not that of its zip
 * (or cannot be read). `getCodeSha256` takes the Lambda's name.
 */
export function checkDeployed(
  stage: Stage,
  zipDir: string,
  getCodeSha256: (functionName: string) => string,
  readFile: ReadFile,
): string[] {
  const { sums, problem } = readSums(zipDir, readFile);
  if (sums === undefined) return [problem as string];
  const fromZips = zipProblems(zipDir, sums, readFile);
  if (fromZips.length > 0) return fromZips;
  const config = { stage } as StageConfig; // rustFunctionName reads only the stage
  const problems: string[] = [];
  for (const name of RUST_FUNCTIONS) {
    const fn = rustFunctionName(config, name);
    const want = codeSha256(sums.get(`${name}.zip`) as string);
    let got: string;
    try {
      got = getCodeSha256(fn);
    } catch (e) {
      problems.push(`${fn}: could not read CodeSha256: ${(e as Error).message}`);
      continue;
    }
    if (got !== want) problems.push(`${fn}: CodeSha256 ${got}, the sums say ${want} (${name}.zip)`);
  }
  return problems;
}

/** The CDK bootstrap qualifier of the stages' accounts (the CDK default; cdk.json sets no other). */
export const CDK_QUALIFIER = 'hnb659fds';

/**
 * The CDK lookup role of an account and region. The deploy role may assume only the CDK bootstrap roles
 * (service/infra/access), and of those the lookup role is the one that reads: `cdk bootstrap` gives it ReadOnlyAccess,
 * which holds lambda:GetFunctionConfiguration.
 */
export const lookupRoleArn = (account: string, region: string): string =>
  `arn:aws:iam::${account}:role/cdk-${CDK_QUALIFIER}-lookup-role-${account}-${region}`;

/** Runs the AWS CLI with `args` (and `env` added to its environment) and returns its standard output. */
export type Aws = (args: string[], env?: Record<string, string>) => string;

/**
 * A reader of CodeSha256 through the lookup role. The role is assumed once, at the first read; its credentials reach only the
 * `aws lambda` calls made here.
 */
export function codeSha256Reader(aws: Aws, stage: Stage, account: string, region: string): (functionName: string) => string {
  let env: Record<string, string> | undefined;
  return (functionName) => {
    if (env === undefined) {
      const out = aws([
        'sts', 'assume-role', '--role-arn', lookupRoleArn(account, region), '--role-session-name', `mopm-${stage}-codesha256`,
        '--duration-seconds', '900', '--query', 'Credentials', '--output', 'json',
      ]);
      const creds = (JSON.parse(out) ?? {}) as { AccessKeyId?: unknown; SecretAccessKey?: unknown; SessionToken?: unknown };
      if (typeof creds.AccessKeyId !== 'string' || typeof creds.SecretAccessKey !== 'string' || typeof creds.SessionToken !== 'string') {
        throw new Error('the lookup role answered without credentials');
      }
      const { AccessKeyId: id, SecretAccessKey: key, SessionToken: token } = creds;
      env = { AWS_ACCESS_KEY_ID: id, AWS_SECRET_ACCESS_KEY: key, AWS_SESSION_TOKEN: token };
    }
    return aws(
      ['lambda', 'get-function-configuration', '--region', region, '--function-name', functionName, '--query', 'CodeSha256', '--output', 'text'],
      env,
    ).trim();
  };
}

export interface MainDeps {
  aws: Aws;
  readFile: ReadFile;
  out: (line: string) => void;
  err: (line: string) => void;
}

const USAGE =
  'usage: function-zips check-zips --zip-dir <dir> | check-deployed --stage <beta|gamma|prod> --zip-dir <dir> --account <id> --region <region>';
const ACCOUNT = /^[0-9]{12}$/;
const REGION = /^[a-z]{2}(-[a-z]+)+-[0-9]$/;

/** The value of each `--flag value` pair of `args`, or undefined when `args` is not exactly the `flags` once each. */
function flagValues(args: string[], flags: string[]): Record<string, string> | undefined {
  if (args.length !== flags.length * 2) return undefined;
  const values: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!flags.includes(args[i]) || args[i] in values) return undefined;
    values[args[i]] = args[i + 1];
  }
  return values;
}

/** The command line: 0 when every check holds, 1 with each problem on `err`, 2 on a usage error. */
export function main(argv: string[], deps: MainDeps): number {
  const [command, ...rest] = argv;
  const flags =
    command === 'check-zips'
      ? ['--zip-dir']
      : command === 'check-deployed'
        ? ['--stage', '--zip-dir', '--account', '--region']
        : undefined;
  const values = flags && flagValues(rest, flags);
  if (!values) {
    deps.err(USAGE);
    return 2;
  }
  const zipDir = values['--zip-dir'];
  let problems: string[];
  if (command === 'check-zips') {
    problems = checkZips(zipDir, deps.readFile);
  } else {
    let stage: Stage;
    try {
      stage = assertStage(values['--stage']);
    } catch (e) {
      deps.err((e as Error).message);
      return 2;
    }
    // The account is a masked secret in the deploy job: the message never repeats it.
    if (!ACCOUNT.test(values['--account'])) {
      deps.err('--account is not a 12-digit account id');
      return 2;
    }
    if (!REGION.test(values['--region'])) {
      deps.err(`--region '${values['--region']}' is not a region name`);
      return 2;
    }
    const read = codeSha256Reader(deps.aws, stage, values['--account'], values['--region']);
    problems = checkDeployed(stage, zipDir, read, deps.readFile);
  }
  if (problems.length > 0) {
    problems.forEach((p) => deps.err(p));
    return 1;
  }
  RUST_FUNCTIONS.forEach((n) => deps.out(`${command === 'check-zips' ? 'zip' : 'deployed'} ok: ${n}`));
  return 0;
}
