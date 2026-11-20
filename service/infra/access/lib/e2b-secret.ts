// Stores one stage's E2B API key in AWS Secrets Manager, as a new version of the secret mopm/<stage>/e2b (JSON
// {"api_key": ...}). Run by the owner with their OWN credentials, once per stage and again on rotation, after the stack
// that creates the (empty) secret is deployed on that stage (BOOTSTRAP.md, "E2B API key"). It only stores versions:
// it never creates or deletes the secret, and stops when the secret does not exist.
// Dry-run by default: prints what it would do and touches nothing. --apply is required to act. Never forces.
// All configuration is flags. The key is read from standard input, never from a flag or an environment variable
// (argv is world-readable), and is never printed: not in the dry run, not with --apply, not in errors.
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { ACCOUNT_RE, Failure, Host, Runner, UsageError, checkStage, exitCode, parseFlags, requireAccount } from './held';

export const USAGE = `usage: e2b-secret --stage beta|gamma|prod --profile <aws profile> [--region <region>] [--account <12 digits>] [--apply]
  Stores the E2B API key as a new version of the secret mopm/<stage>/e2b. The secret must exist (the stack creates it).
  The key is read from stdin (hidden prompt when stdin is a terminal), never from a flag.
  --region defaults to us-east-1, the region every mopm stack is in.
  --account, when given, must be the account of the profile: with --apply a profile in another account is refused.
  Without --apply nothing is read from stdin and no AWS call is made: the commands are printed.`;

export interface Options {
  /** Returns the key: a hidden prompt on a terminal, otherwise stdin. Called only with --apply, after the secret is found. */
  readKey(stage: string): string;
}

/** Whitespace (a newline included) or a control character: an E2B key has none, so one is a paste or input mistake. */
const BAD_KEY_CHAR = /[\s\x00-\x1f\x7f]/;

export function e2bSecret(argv: string[], host: Host, opts: Options): number {
  return exitCode(host, USAGE, () => {
    const p = parseFlags(argv, ['--stage', '--profile', '--region', '--account'], ['--apply']);
    if (p.help) {
      host.out(USAGE);
      return 0;
    }
    const stage = p.values['--stage'] ?? '';
    const profile = p.values['--profile'] ?? '';
    const region = '--region' in p.values ? p.values['--region'] : 'us-east-1';
    const account = p.values['--account'];
    checkStage(stage);
    if (!profile) throw new UsageError('--profile is required');
    if (!region) throw new UsageError('--region must not be empty');
    if (account !== undefined && !ACCOUNT_RE.test(account)) throw new UsageError('--account must be 12 digits');
    const apply = p.flags.has('--apply');

    const name = `mopm/${stage}/e2b`;
    const r = new Runner(host, apply);
    const base = ['aws', 'secretsmanager'];
    const common = ['--profile', profile, '--region', region];
    const describe = [...base, 'describe-secret', ...common, '--secret-id', name, '--query', 'Name', '--output', 'text'];

    if (!apply) {
      host.out('# dry run: nothing is read, nothing is called. Re-run with --apply to act.');
      host.out('# the secret string is JSON {"api_key": "<read from stdin>"}, passed to the CLI as a file (mode 600), never as an argument.');
      if (account !== undefined) r.run(['aws', 'sts', 'get-caller-identity', '--profile', profile, '--query', 'Account', '--output', 'text']);
      r.run(describe);
      r.run([...base, 'put-secret-value', ...common, '--secret-id', name, '--secret-string', 'file://<temporary file>', '--output', 'text', '--query', 'VersionId']);
      host.out(`# if ${name} does not exist this stops: deploy the stack on ${stage} first. It never creates the secret.`);
      return 0;
    }

    if (account !== undefined) requireAccount(host, profile, account);

    // The secret must already exist: the stack owns it (and its resource policy). Checked before the key is asked for.
    const d = host.capture(describe);
    if (d.status !== 0) {
      if (d.output.includes('ResourceNotFoundException')) {
        throw new Failure(`secret ${name} does not exist: deploy the stack on ${stage} first, then run this again. Nothing was changed.`);
      }
      throw new Failure(`cannot read ${name}: ${d.output.trim()}`);
    }

    const key = opts.readKey(stage);
    if (!key) throw new UsageError('the E2B API key is empty (give it on stdin)');
    if (BAD_KEY_CHAR.test(key)) throw new UsageError('the E2B API key has whitespace, a line break or a control character in it; E2B keys do not');

    // The key goes to the CLI in a file only the owner can read, never in an argument, and the file is removed at the end.
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-e2b-'));
    try {
      const file = path.join(dir, 'secret.json');
      fs.writeFileSync(file, JSON.stringify({ api_key: key }), { mode: 0o600 });
      fs.chmodSync(file, 0o600);
      host.out(`secret ${name} exists: storing a new version`);
      r.run([...base, 'put-secret-value', ...common, '--secret-id', name, '--secret-string', `file://${file}`, '--output', 'text', '--query', 'VersionId']);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    host.out(`done: ${name} has a new version.`);
    return 0;
  });
}
