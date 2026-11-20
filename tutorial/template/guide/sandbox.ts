// tutorial/template/guide/sandbox.ts
// The page's sandbox: the grant of POST /api/v2/tutorial/sandbox as an e2b `Sandbox` that reaches that one sandbox
// with its access token, and renewed before the grant's expires_at or when the sandbox turns out to be gone.
import { Sandbox, SandboxNotRunningError, SandboxUnreachableError } from 'e2b';

/** The 201 of POST /api/v2/tutorial/sandbox (`SandboxGrant` of site/src/tutorial/gate.ts). */
export interface SandboxGrant {
  sandbox_id: string;
  access_token: string;
  envd_version: string;
  domain: string;
  expires_at: string;
}

/** What the gate's `sandbox()` answers: a grant, or a code of the endpoint's error table. */
export type GrantAnswer = SandboxGrant | { error: string };

/** The endpoint refused a sandbox; `code` is the error table's code, which picks the page's message. */
export class GrantRefused extends Error {
  constructor(readonly code: string) {
    super(`the sandbox endpoint answered ${code}`);
    this.name = 'GrantRefused';
  }
}

/** The gate's `sandbox()`, asked once more after a fresh `session()` when the answer is `csrf_failed`. */
export async function askForSandbox(gate: {
  session(): Promise<unknown>;
  sandbox(): Promise<GrantAnswer>;
}): Promise<GrantAnswer> {
  const a = await gate.sandbox();
  if (!('error' in a) || a.error !== 'csrf_failed') return a;
  await gate.session();
  return gate.sandbox();
}

/** A client of the grant's sandbox. It carries the sandbox's own token only: no API key reaches the page. */
export function connect(g: SandboxGrant): Sandbox {
  return new Sandbox({
    sandboxId: g.sandbox_id,
    sandboxDomain: g.domain,
    envdVersion: g.envd_version,
    envdAccessToken: g.access_token,
  });
}

/** Whether an SDK error means the sandbox is gone or out of reach: the page then needs a new one. */
export function sandboxGone(e: unknown): boolean {
  return e instanceof SandboxNotRunningError || e instanceof SandboxUnreachableError;
}

/** A grant this close to its expires_at is replaced before use, so no call starts on a sandbox about to end. */
export const RENEW_BEFORE_MS = 60_000;

/** One sandbox per page, asked for when first needed and replaced when it ends. */
export class PageSandbox {
  private held: { sandbox: Sandbox; until: number } | null = null;
  private pending: Promise<Sandbox> | null = null;

  constructor(
    private readonly ask: () => Promise<GrantAnswer>,
    private readonly now: () => number = Date.now,
    private readonly open: (g: SandboxGrant) => Sandbox = connect,
  ) {}

  /** The sandbox; a new one when none is held or it ends within RENEW_BEFORE_MS. Throws GrantRefused. */
  get(): Promise<Sandbox> {
    const h = this.held;
    if (h !== null && this.now() < h.until - RENEW_BEFORE_MS) return Promise.resolve(h.sandbox);
    // Callers that ask at the same time share one request, so the page never holds two sandboxes.
    this.pending ??= this.renew().finally(() => {
      this.pending = null;
    });
    return this.pending;
  }

  /** When the held sandbox ends (ms since the epoch), or null when none is held. */
  expiresAt(): number | null {
    return this.held === null ? null : this.held.until;
  }

  /** Forgets the sandbox, so the next `get()` asks for a new one. */
  drop(): void {
    this.held = null;
  }

  /**
   * Runs `f` on the sandbox. When the sandbox turns out to be gone, runs `f` once more on a new one. A new sandbox
   * starts from the template, so `f` writes what it needs (the editor's files) before it runs anything.
   */
  async use<T>(f: (s: Sandbox) => Promise<T>): Promise<T> {
    try {
      return await f(await this.get());
    } catch (e) {
      if (!sandboxGone(e)) throw e;
      this.drop();
      return f(await this.get());
    }
  }

  private async renew(): Promise<Sandbox> {
    this.held = null;
    const a = await this.ask();
    if ('error' in a) throw new GrantRefused(a.error);
    this.held = { sandbox: this.open(a), until: Date.parse(a.expires_at) };
    return this.held.sandbox;
  }
}
