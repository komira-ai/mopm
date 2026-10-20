// Stores one stage's GitHub OAuth app credentials in AWS Secrets Manager, as the secret
// mopm/<stage>/github-oauth (JSON {"client_id": ..., "client_secret": ...}). Run by a human admin with their OWN
// credentials, once per stage, after creating that stage's GitHub OAuth app (BOOTSTRAP.md, "GitHub OAuth app").
// Dry-run by default: prints what it would do and touches nothing. --apply is required to act. Never forces.
// All configuration is flags. The client SECRET is read from standard input, never from a flag or an environment
// variable (argv is world-readable), and is never printed: not in the dry run, not with --apply, not in errors.
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { ACCOUNT_RE, Failure, Host, Runner, UsageError, checkStage, exitCode, parseFlags, requireAccount } from './held';

export const USAGE = `usage: oauth-secret --stage beta|gamma|prod --profile <aws profile> --client-id <GitHub OAuth app client id> [--region <region>] [--account <12 digits>] [--apply]
  Creates the secret mopm/<stage>/github-oauth, or stores a new version when it already exists.
  The client secret is read from stdin (hidden prompt when stdin is a terminal). The client id is not secret.
  --region defaults to us-east-1, the region every mopm stack is in.
  --account, when given, must be the account of the profile: with --apply a profile in another account is refused.
  Without --apply nothing is read from stdin and no AWS call is made: the commands are printed.`;

/** The first line of the input, without its newline (what a shell \`read -r\` returns). */
export function firstLine(text: string): string {
  const i = text.search(/\r?\n/);
  return i < 0 ? text : text.slice(0, i);
}

export interface Options {
  /** Returns the client secret: a hidden prompt on a terminal, otherwise the first line of stdin. Called only with --apply. */
  readSecret(stage: string): string;
}

const CLIENT_ID_RE = /^[A-Za-z0-9._-]{4,100}$/;

export function oauthSecret(argv: string[], host: Host, opts: Options): number {
  return exitCode(host, USAGE, () => {
    const p = parseFlags(argv, ['--stage', '--profile', '--client-id', '--region', '--account'], ['--apply']);
    if (p.help) {
      host.out(USAGE);
      return 0;
    }
    const stage = p.values['--stage'] ?? '';
    const profile = p.values['--profile'] ?? '';
    const clientId = p.values['--client-id'] ?? '';
    const region = '--region' in p.values ? p.values['--region'] : 'us-east-1';
    const account = p.values['--account'];
    checkStage(stage);
    if (!profile) throw new UsageError('--profile is required');
    if (!region) throw new UsageError('--region must not be empty');
    // The same shape the API accepts (src/http/oauth-secret.ts): GitHub client ids look like Iv1.<hex> or Ov23<alphanumerics>.
    if (!CLIENT_ID_RE.test(clientId)) throw new UsageError('--client-id must be 4 to 100 characters of letters, digits, . _ -');
    if (account !== undefined && !ACCOUNT_RE.test(account)) throw new UsageError('--account must be 12 digits');
    const apply = p.flags.has('--apply');

    const name = `mopm/${stage}/github-oauth`;
    const description = `GitHub OAuth app of the mopm ${stage} registry (client id and client secret)`;
    const r = new Runner(host, apply);
    const base = ['aws', 'secretsmanager'];
    const common = ['--profile', profile, '--region', region];

    if (!apply) {
      host.out('# dry run: nothing is read, nothing is called. Re-run with --apply to act.');
      host.out(`# the secret string is JSON {"client_id": "${clientId}", "client_secret": "<read from stdin>"}, passed to the CLI as a file (mode 600), never as an argument.`);
      r.run([...base, 'describe-secret', ...common, '--secret-id', name]);
      r.run([...base, 'create-secret', ...common, '--name', name, '--description', description, '--secret-string', 'file://<temporary file>']);
      host.out('# if the secret already exists, put-secret-value is used instead of create-secret:');
      r.run([...base, 'put-secret-value', ...common, '--secret-id', name, '--secret-string', 'file://<temporary file>']);
      return 0;
    }

    if (account !== undefined) requireAccount(host, profile, account);
    const secret = opts.readSecret(stage);
    if (!secret) throw new UsageError('the client secret is empty (give it on stdin)');
    if (/[\s"\\]/.test(secret)) throw new UsageError('the client secret has whitespace or quote characters; GitHub client secrets do not');

    // The secret goes to the CLI in a file only the admin can read, never in an argument, and the file is removed at the end.
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-oauth-'));
    try {
      const file = path.join(dir, 'secret.json');
      fs.writeFileSync(file, JSON.stringify({ client_id: clientId, client_secret: secret }), { mode: 0o600 });
      fs.chmodSync(file, 0o600);

      // Existing? A missing secret is the normal first run; any other failure stops here.
      const d = host.capture([...base, 'describe-secret', ...common, '--secret-id', name, '--query', 'Name', '--output', 'text']);
      if (d.status === 0) {
        host.out(`secret ${name} exists: storing a new version`);
        r.run([...base, 'put-secret-value', ...common, '--secret-id', name, '--secret-string', `file://${file}`, '--output', 'text', '--query', 'VersionId']);
      } else if (d.output.includes('ResourceNotFoundException')) {
        host.out(`secret ${name} does not exist: creating it`);
        r.run([...base, 'create-secret', ...common, '--name', name, '--description', description, '--secret-string', `file://${file}`, '--output', 'text', '--query', 'Name']);
      } else {
        throw new Failure(`cannot read ${name}: ${d.output.trim()}`);
      }
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    host.out('done. The API reads the client id from this secret at runtime (cached for five minutes); no redeploy is needed.');
    return 0;
  });
}
