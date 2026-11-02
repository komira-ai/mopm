// One-time per-stage-account bootstrap, run by a human admin with their OWN credentials.
// Dry-run by default: prints the commands. --apply is required to act. Never forces.
// All configuration is flags (no environment variables are read).
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { ACCOUNT_RE, Failure, Host, Parsed, Runner, UsageError, checkStage, exitCode, parseFlags, requireAccount } from './held';
import { unifiedDiff } from './diff';

export const USAGE = `usage: bootstrap --stage beta|gamma|prod --account <12 digits> --region <region> --profile <aws profile> [--apply] [--approve-iam] [--update-policy] [--policy-only]
  Runs, in order: create the scoped CloudFormation execution policy (skipped if an identical one exists;
  stops if a different one exists), cdk bootstrap, cdk diff, deploy the access stack.
  Without --apply nothing is executed; the commands are printed.
  --apply first checks that the profile is in --account and refuses otherwise.
  --update-policy: if the policy exists with a different document, print the diff (current default version vs
  cfn-exec-policy.template.json) and create the new document as the new default version, first deleting the oldest
  non-default version when IAM's limit of 5 is reached. In a dry run this makes read-only calls (sts get-caller-identity,
  iam get-policy, get-policy-version) to show the diff; if get-policy fails, only the commands are printed.
  --policy-only stops after the policy step (no cdk bootstrap, diff or deploy): the way to roll a policy change out
  to a stage that is already bootstrapped.
  --approve-iam passes --require-approval never to cdk deploy, for non-interactive shells. Use it only
  after a human reviewed the printed cdk diff (IAM changes are otherwise confirmed interactively).`;

/** The same JSON with every object's keys sorted, so two documents compare by meaning, not by key order. */
export function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v !== null && typeof v === 'object') {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys((v as Record<string, unknown>)[k])]));
  }
  return v;
}
const norm = (text: string): string => JSON.stringify(sortKeys(JSON.parse(text)));
const pretty = (text: string): string => JSON.stringify(sortKeys(JSON.parse(text)), null, 2);

/** The policy template with the stage, account and zone filled in. */
export function renderPolicy(template: string, stage: string, account: string): string {
  const zone = stage === 'prod' ? 'mopm.dev' : `${stage}.mopm.dev`;
  const rendered = template.replaceAll('{{STAGE}}', stage).replaceAll('{{ACCOUNT}}', account).replaceAll('{{ZONE}}', zone);
  if (rendered.includes('{{')) throw new Failure('cfn-exec-policy.template.json has a placeholder this script does not fill');
  return rendered.replace(/\n+$/, '');
}

export interface Options {
  /** Path of cfn-exec-policy.template.json. */
  templatePath: string;
}

export function bootstrap(argv: string[], host: Host, opts: Options): number {
  return exitCode(host, USAGE, () => {
    const p: Parsed = parseFlags(argv, ['--stage', '--account', '--region', '--profile'], ['--apply', '--approve-iam', '--update-policy', '--policy-only']);
    if (p.help) {
      host.out(USAGE);
      return 0;
    }
    const stage = p.values['--stage'] ?? '';
    const account = p.values['--account'] ?? '';
    const region = p.values['--region'] ?? '';
    const profile = p.values['--profile'] ?? '';
    checkStage(stage);
    if (!ACCOUNT_RE.test(account)) throw new UsageError('--account must be 12 digits');
    if (!region) throw new UsageError('--region is required');
    if (!profile) throw new UsageError('--profile is required');
    const apply = p.flags.has('--apply');
    const updatePolicy = p.flags.has('--update-policy');

    const policyName = `mopm-${stage}-cfn-exec`;
    const policyArn = `arn:aws:iam::${account}:policy/${policyName}`;
    const r = new Runner(host, apply);
    const aws = (...args: string[]) => host.capture(['aws', ...args]);

    if (!apply) host.out('# dry run: nothing is executed. Re-run with --apply to act.');

    // 1. Scoped execution policy. Resumable: an existing policy with an identical document is kept. A different one
    // stops the command, unless --update-policy is given: then the differences are printed and the new document
    // becomes a new default version.
    const rendered = renderPolicy(fs.readFileSync(opts.templatePath, 'utf8'), stage, account);
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-policy-'));
    try {
      const docPath = path.join(tmp, 'policy.json');
      fs.writeFileSync(docPath, `${rendered}\n`, { mode: 0o600 });

      // Reads: always with --apply; in a dry run only with --update-policy (read-only, so the diff can be shown first).
      let state: 'unknown' | 'exists' | 'missing' = 'unknown';
      let version = '';
      if (apply || updatePolicy) {
        requireAccount(host, profile, account);
        const g = aws('iam', 'get-policy', '--profile', profile, '--policy-arn', policyArn, '--query', 'Policy.DefaultVersionId', '--output', 'text');
        if (g.status === 0) {
          state = 'exists';
          version = g.output.trim();
        } else if (g.output.includes('NoSuchEntity')) state = 'missing';
        else if (apply) throw new Failure(`cannot read ${policyArn}: ${g.output.trim()}`);
        else host.out(`# could not read ${policyArn} (${g.output.trim()}); showing the commands only`);
      } else {
        host.out(`# with --apply: the profile must be in account ${account}, else the command refuses before changing anything.`);
      }

      const updateVersion = (): void => {
        // IAM keeps at most 5 versions of a managed policy: free a slot first by deleting the oldest non-default one.
        const c = aws('iam', 'list-policy-versions', '--profile', profile, '--policy-arn', policyArn, '--query', 'length(Versions)', '--output', 'text');
        if (c.status !== 0) throw new Failure(`cannot list the versions of ${policyArn}: ${c.output.trim()}`);
        if (parseInt(c.output.trim(), 10) >= 5) {
          const o = aws('iam', 'list-policy-versions', '--profile', profile, '--policy-arn', policyArn,
            '--query', 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId', '--output', 'text');
          if (o.status !== 0) throw new Failure(`cannot find the oldest version of ${policyArn}: ${o.output.trim()}`);
          r.run(['aws', 'iam', 'delete-policy-version', '--profile', profile, '--policy-arn', policyArn, '--version-id', o.output.trim()]);
        }
        r.run(['aws', 'iam', 'create-policy-version', '--profile', profile, '--policy-arn', policyArn, '--policy-document', `file://${docPath}`, '--set-as-default']);
      };

      if (state === 'exists') {
        const e = aws('iam', 'get-policy-version', '--profile', profile, '--policy-arn', policyArn, '--version-id', version,
          '--query', 'PolicyVersion.Document', '--output', 'json');
        if (e.status !== 0) throw new Failure(`cannot read version ${version} of ${policyArn}: ${e.output.trim()}`);
        if (norm(e.output) === norm(rendered)) {
          host.out(`policy ${policyName} already exists with an identical document: skipping`);
        } else if (updatePolicy) {
          host.out(`# policy ${policyName} differs from cfn-exec-policy.template.json (- current default ${version}, + new):`);
          for (const l of unifiedDiff(pretty(e.output).split('\n'), pretty(rendered).split('\n'), `current ${policyName} (${version})`, `new (${stage})`)) host.out(l);
          updateVersion();
        } else {
          host.err(`policy ${policyArn} exists with a DIFFERENT document than cfn-exec-policy.template.json.`);
          throw new Failure('Stopping: nothing is changed without --update-policy. Re-run with --update-policy to see the diff and roll the new document out as a new policy version.');
        }
      } else if (state === 'missing') {
        if (!apply) {
          host.out(`# rendered policy document for ${policyName}:`);
          host.out(rendered);
        }
        r.run(['aws', 'iam', 'create-policy', '--profile', profile, '--policy-name', policyName, '--policy-document', `file://${docPath}`]);
      } else {
        host.out(`# rendered policy document for ${policyName}:`);
        host.out(rendered);
        host.out('# with --apply: an existing identical policy is skipped; a different one stops the command unless --update-policy is given.');
        if (updatePolicy) {
          r.run(['aws', 'iam', 'create-policy-version', '--profile', profile, '--policy-arn', policyArn, '--policy-document', 'file://<rendered above>', '--set-as-default']);
        } else {
          r.run(['aws', 'iam', 'create-policy', '--profile', profile, '--policy-name', policyName, '--policy-document', 'file://<rendered above>']);
        }
      }
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }

    if (p.flags.has('--policy-only')) {
      host.out('# --policy-only: bootstrap, diff and deploy skipped');
      return 0;
    }

    // CDK loads the app (bin/access.ts) for every command, including bootstrap, so the context is required throughout.
    const ctx = ['-c', `stage=${stage}`, '-c', `account=${account}`, '-c', `region=${region}`];

    // 2. CDK bootstrap with the scoped policy (never AdministratorAccess).
    r.run(['npm', 'install', '--no-audit', '--no-fund']);
    r.run(['npx', 'cdk', 'bootstrap', `aws://${account}/${region}`, '--profile', profile, '--cloudformation-execution-policies', policyArn, ...ctx]);

    // 3. Always show the diff first. The access stack (GitHub OIDC provider + deploy and e2e roles) deploys with the
    // admin's own credentials (CliCredentialsStackSynthesizer), NOT via the scoped execution role, which denies these resources.
    r.run(['npx', 'cdk', 'diff', `mopm-${stage}-access`, '--profile', profile, ...ctx]);
    const approval = p.flags.has('--approve-iam') ? 'never' : 'broadening';
    r.run(['npx', 'cdk', 'deploy', `mopm-${stage}-access`, '--profile', profile, '--require-approval', approval, ...ctx]);

    host.out(`# Remaining manual steps (see BOOTSTRAP.md): set the repo OIDC subject template once,
# create the ${stage} GitHub environment, and store AWS_ACCOUNT_ID and AWS_REGION as environment secrets (no ARNs are stored).`);
    return 0;
  });
}
