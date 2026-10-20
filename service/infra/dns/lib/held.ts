// The shared shape of a held, human-run ops command: dry run unless --apply, flags only (no environment
// variable is read), the admin's own credentials, never forces, and with --apply a profile in the wrong account is
// refused before anything is changed. Everything that touches the outside world goes through a Host, so the tests
// run the whole command against a fake and no AWS or process call is ever made.
//
// A copy of this file lives in service/infra/dns/lib/held.ts (the packages build separately); keep them identical.
import { spawnSync } from 'child_process';

export interface Host {
  out(line: string): void;
  err(line: string): void;
  /** Runs a command to completion; the combined stdout and stderr is returned, nothing is shown. */
  capture(argv: string[]): { status: number; output: string };
  /** Runs a command with the terminal attached; returns its exit status. */
  inherit(argv: string[]): number;
}

/** A bad flag or value: exit status 2. */
export class UsageError extends Error {}
/** A refusal or a failed step: exit status 1. */
export class Failure extends Error {}

export const ACCOUNT_RE = /^[0-9]{12}$/;

export function realHost(cwd: string): Host {
  return {
    out: (l) => process.stdout.write(`${l}\n`),
    err: (l) => process.stderr.write(`${l}\n`),
    capture: (argv) => {
      const r = spawnSync(argv[0], argv.slice(1), { cwd, encoding: 'utf8' });
      return { status: r.status ?? 1, output: `${r.stdout ?? ''}${r.stderr ?? ''}${r.error ? String(r.error) : ''}` };
    },
    inherit: (argv) => spawnSync(argv[0], argv.slice(1), { cwd, stdio: 'inherit' }).status ?? 1,
  };
}

/** Shell-quotes one word for display, so a printed command can be pasted. */
export function quote(a: string): string {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`;
}

export interface Parsed {
  values: Record<string, string>;
  flags: Set<string>;
  help: boolean;
}

/** Flags with a value (`--stage beta`) and switches. A value flag at the end of the line gets ''. Anything else is a usage error. */
export function parseFlags(argv: string[], valueFlags: string[], switches: string[]): Parsed {
  const p: Parsed = { values: {}, flags: new Set(), help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') p.help = true;
    else if (valueFlags.includes(a)) {
      p.values[a] = argv[i + 1] ?? '';
      i++;
    } else if (switches.includes(a)) p.flags.add(a);
    else throw new UsageError(`unknown flag: ${a}`);
  }
  return p;
}

export function checkStage(stage: string): asserts stage is 'beta' | 'gamma' | 'prod' {
  if (!['beta', 'gamma', 'prod'].includes(stage)) throw new UsageError('--stage must be beta, gamma or prod');
}

/** Prints the command in a dry run; runs it (and echoes it) with --apply. A failing command stops the whole command. */
export class Runner {
  constructor(readonly host: Host, readonly apply: boolean) {}

  run(argv: string[]): void {
    const shown = argv.map(quote).join(' ');
    if (!this.apply) {
      this.host.out(`DRY-RUN: ${shown}`);
      return;
    }
    this.host.out(`+ ${shown}`);
    const status = this.host.inherit(argv);
    if (status !== 0) throw new Failure(`command failed with status ${status}: ${shown}`);
  }
}

/** Refuses unless the profile's credentials belong to the account the admin named. Read-only (sts get-caller-identity). */
export function requireAccount(host: Host, profile: string, account: string): void {
  const r = host.capture(['aws', 'sts', 'get-caller-identity', '--profile', profile, '--query', 'Account', '--output', 'text']);
  if (r.status !== 0) throw new Failure(`cannot tell which account profile ${profile} is in: ${r.output.trim()}`);
  const actual = r.output.trim();
  if (actual !== account) {
    throw new Failure(`refusing: profile ${profile} is in account ${actual}, but --account says ${account}. Nothing was changed.`);
  }
}

/** Turns a thrown error into a message and an exit status; anything unexpected is rethrown. */
export function exitCode(host: Host, usage: string, fn: () => number): number {
  try {
    return fn();
  } catch (e) {
    if (e instanceof UsageError) {
      host.err(e.message);
      if (e.message.startsWith('unknown flag')) host.err(usage);
      return 2;
    }
    if (e instanceof Failure) {
      host.err(e.message);
      return 1;
    }
    throw e;
  }
}
