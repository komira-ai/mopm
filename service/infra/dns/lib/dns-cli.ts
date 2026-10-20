// Deploys the Route 53 hosted zone of one stage (or, with --delegate, the prod delegation records).
// Run by a human admin with their OWN credentials. Dry-run by default: prints the commands.
// --apply is required to act. Never forces. All configuration is flags (no environment variables are read).
import { ACCOUNT_RE, Failure, Host, Runner, UsageError, checkStage, exitCode, parseFlags, requireAccount } from './held';

export const USAGE = `usage:
  dns --stage beta|gamma|prod --account <12 digits> --profile <aws profile> [--apply]
      Deploys mopm-dns-<stage>-zone and prints the zone's four name servers.
  dns --stage prod --delegate --beta-ns <4 hosts, comma separated> --gamma-ns <4 hosts, comma separated> \\
      --account <prod account, 12 digits> --profile <prod profile> [--apply]
      Deploys mopm-dns-prod-delegation: NS records for beta.mopm.dev and gamma.mopm.dev in the mopm.dev zone.
  Without --apply nothing is executed; the commands are printed.
  --apply first checks that the profile is in --account and refuses otherwise.`;

const NS_RE = /^ns-[0-9]{1,4}\.awsdns-[0-9]{2}\.(org|com|net|co\.uk)$/;

function checkNs(label: string, csv: string): void {
  const hosts = csv.split(',');
  for (const h of hosts) {
    if (!NS_RE.test(h)) throw new UsageError(`${label} must be 4 comma separated Route 53 name servers (no trailing dots); got '${h}'`);
  }
  if (hosts.length !== 4) throw new UsageError(`${label} must list exactly 4 name servers; got ${hosts.length}`);
}

export function dnsCli(argv: string[], host: Host): number {
  return exitCode(host, USAGE, () => {
    const p = parseFlags(argv, ['--stage', '--account', '--profile', '--beta-ns', '--gamma-ns'], ['--delegate', '--apply']);
    if (p.help) {
      host.out(USAGE);
      return 0;
    }
    const stage = p.values['--stage'] ?? '';
    const account = p.values['--account'] ?? '';
    const profile = p.values['--profile'] ?? '';
    const betaNs = p.values['--beta-ns'] ?? '';
    const gammaNs = p.values['--gamma-ns'] ?? '';
    const delegate = p.flags.has('--delegate');
    const apply = p.flags.has('--apply');
    const region = 'us-east-1';
    checkStage(stage);
    if (!ACCOUNT_RE.test(account)) throw new UsageError('--account must be 12 digits');
    if (!profile) throw new UsageError('--profile is required');

    let stack: string;
    if (delegate) {
      if (stage !== 'prod') throw new UsageError('--delegate runs in the prod account only (--stage prod)');
      checkNs('--beta-ns', betaNs);
      checkNs('--gamma-ns', gammaNs);
      stack = 'mopm-dns-prod-delegation';
    } else {
      if (betaNs || gammaNs) throw new UsageError('--beta-ns/--gamma-ns only apply with --delegate');
      stack = `mopm-dns-${stage}-zone`;
    }

    const r = new Runner(host, apply);
    if (!apply) host.out('# dry run: nothing is executed. Re-run with --apply to act.');
    else requireAccount(host, profile, account);

    r.run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund']);

    // No cdk bootstrap is needed: these stacks use the legacy synthesizer and deploy with your own credentials.
    const deploy = ['npx', 'cdk', 'deploy', stack, '--profile', profile, '--require-approval', 'broadening', '-c', `stage=${stage}`, '-c', `account=${account}`];
    if (delegate) deploy.push('-c', 'delegate=true', '-c', `betaNameServers=${betaNs}`, '-c', `gammaNameServers=${gammaNs}`);
    r.run(deploy);

    if (!delegate) {
      const describe = ['aws', 'cloudformation', 'describe-stacks', '--profile', profile, '--region', region, '--stack-name', stack,
        '--query', "Stacks[0].Outputs[?OutputKey=='NameServers'].OutputValue", '--output', 'text'];
      if (apply) {
        const d = host.capture(describe);
        if (d.status !== 0) throw new Failure(`cannot read the name servers of ${stack}: ${d.output.trim()}`);
        host.out(`# Name servers of the ${stage} zone (four, comma separated):`);
        host.out(d.output.trim());
        host.out('# Enter these (one per line, no trailing dots) where the next README step says.');
      } else {
        r.run(describe);
      }
    } else {
      host.out('# Verify: dig +short NS beta.mopm.dev; dig +short NS gamma.mopm.dev (see README.md).');
    }
    return 0;
  });
}
