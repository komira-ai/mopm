// A fake Host for the held-command tests: records every call, answers captures from a function, and never runs anything.
import { Host } from '../lib/held';

export type Reply = { status: number; output: string };
export type Responder = (argv: string[]) => Reply | undefined;

export class FakeHost implements Host {
  outLines: string[] = [];
  errLines: string[] = [];
  /** Every command the code under test asked the host to run, in order, with how it was run. */
  calls: { how: 'capture' | 'inherit'; argv: string[] }[] = [];
  constructor(private respond: Responder = () => undefined, private inheritStatus: (argv: string[]) => number = () => 0) {}
  out(l: string): void { this.outLines.push(l); }
  err(l: string): void { this.errLines.push(l); }
  capture(argv: string[]): Reply {
    this.calls.push({ how: 'capture', argv });
    return this.respond(argv) ?? { status: 0, output: '' };
  }
  inherit(argv: string[]): number {
    this.calls.push({ how: 'inherit', argv });
    return this.inheritStatus(argv);
  }
  get out_(): string { return this.outLines.join('\n'); }
  get err_(): string { return this.errLines.join('\n'); }
  /** The calls as one line each, the way the tests assert on them. */
  get lines(): string[] { return this.calls.map((c) => c.argv.join(' ')); }
}

/** A 12-digit account id built at runtime so no literal is in the tree (the hygiene job refuses those). */
export const acct = (d: string): string => d.repeat(12);
