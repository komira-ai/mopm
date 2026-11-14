// Stores one stage's registry GitHub App credentials in AWS Secrets Manager, as the secret mopm/<stage>/github-app
// (JSON {"app_id": ..., "private_key": ...}), beside the OAuth secret of oauth-secret.ts. Run by a human admin with their
// OWN credentials, once per stage, after creating that stage's GitHub App and downloading its private key (BOOTSTRAP.md,
// "GitHub App"). Dry-run by default: prints what it would do and touches nothing. --apply is required to act. Never forces.
// All configuration is flags. The private key is read from the PEM file the --key-file flag names (the file GitHub
// generated; its path is not secret, its content is), never from a flag value or an environment variable, and is never
// printed: not in the dry run, not with --apply, not in errors. Nothing runs this in CI.
import * as fs from 'fs';
import * as path from 'path';
import { ACCOUNT_RE, Failure, Host, Runner, UsageError, checkStage, exitCode, parseFlags, requireAccount } from './held';

export const USAGE = `usage: app-secret --stage beta|gamma|prod --profile <aws profile> --app-id <GitHub App id> --key-file <private key .pem> --scratch <dir> [--region <region>] [--account <12 digits>] [--apply]
  Creates the secret mopm/<stage>/github-app, or stores a new version when it already exists.
  The private key is read from --key-file, only with --apply. The App id is a number and is not secret.
  --scratch is the workspace scratch directory (it must exist): with --apply the secret JSON is staged there, in a
  directory only you can read, and removed at the end.
  --region defaults to us-east-1, the region every mopm stack is in.
  --account, when given, must be the account of the profile: with --apply a profile in another account is refused.
  Without --apply nothing is read and no AWS call is made: the commands are printed.`;

export interface Options {
  /** Returns the content of the key file. Called only with --apply. */
  readKey(file: string): string;
}

const APP_ID_RE = /^[1-9][0-9]{0,15}$/;
const PEM_RE = /^-----BEGIN (RSA )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+\r?\n-----END (RSA )?PRIVATE KEY-----\s*$/;

export function appSecret(argv: string[], host: Host, opts: Options): number {
  return exitCode(host, USAGE, () => {
    const p = parseFlags(argv, ['--stage', '--profile', '--app-id', '--key-file', '--scratch', '--region', '--account'], ['--apply']);
    if (p.help) {
      host.out(USAGE);
      return 0;
    }
    const stage = p.values['--stage'] ?? '';
    const profile = p.values['--profile'] ?? '';
    const appId = p.values['--app-id'] ?? '';
    const keyFile = p.values['--key-file'] ?? '';
    const scratch = p.values['--scratch'] ?? '';
    const region = '--region' in p.values ? p.values['--region'] : 'us-east-1';
    const account = p.values['--account'];
    checkStage(stage);
    if (!profile) throw new UsageError('--profile is required');
    if (!region) throw new UsageError('--region must not be empty');
    // The same shape the API accepts (src/http/app-secret.ts): the App's numeric id.
    if (!APP_ID_RE.test(appId)) throw new UsageError('--app-id must be the App\'s numeric id');
    if (!keyFile) throw new UsageError('--key-file is required');
    if (!scratch) throw new UsageError('--scratch is required (the workspace scratch directory)');
    if (account !== undefined && !ACCOUNT_RE.test(account)) throw new UsageError('--account must be 12 digits');
    const apply = p.flags.has('--apply');

    const name = `mopm/${stage}/github-app`;
    const description = `GitHub App of the mopm ${stage} registry (app id and private key)`;
    const r = new Runner(host, apply);
    const base = ['aws', 'secretsmanager'];
    const common = ['--profile', profile, '--region', region];

    if (!apply) {
      host.out('# dry run: nothing is read, nothing is called. Re-run with --apply to act.');
      host.out(`# the secret string is JSON {"app_id": "${appId}", "private_key": "<the content of ${keyFile}>"}, passed to the CLI as a file (mode 600) under ${scratch}, never as an argument.`);
      r.run([...base, 'describe-secret', ...common, '--secret-id', name]);
      r.run([...base, 'create-secret', ...common, '--name', name, '--description', description, '--secret-string', 'file://<temporary file>']);
      host.out('# if the secret already exists, put-secret-value is used instead of create-secret:');
      r.run([...base, 'put-secret-value', ...common, '--secret-id', name, '--secret-string', 'file://<temporary file>']);
      return 0;
    }

    if (account !== undefined) requireAccount(host, profile, account);
    let key: string;
    try {
      key = opts.readKey(keyFile);
    } catch {
      throw new UsageError(`cannot read --key-file ${keyFile}`);
    }
    if (!PEM_RE.test(key)) throw new UsageError('--key-file is not a PEM private key (a PKCS#1 RSA or a PKCS#8 private key block)');

    // The key goes to the CLI in a file only the admin can read, in the workspace scratch directory, never in an argument,
    // and the file is removed at the end.
    let isDir = false;
    try {
      isDir = fs.statSync(scratch).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) throw new UsageError(`--scratch ${scratch} is not an existing directory`);
    const dir = fs.mkdtempSync(path.join(scratch, 'mopm-app-'));
    fs.chmodSync(dir, 0o700);
    try {
      const file = path.join(dir, 'secret.json');
      fs.writeFileSync(file, JSON.stringify({ app_id: appId, private_key: key }), { mode: 0o600 });
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
    host.out('done. The API reads the App id and key from this secret at runtime (cached for five minutes); no redeploy is needed.');
    return 0;
  });
}
