// guide/sandbox.ts, the author's guide's sandbox snippet (docs/tutorial-author-guide.md): the grant becomes a client
// of that one sandbox, one sandbox per page, renewed before its expires_at, replaced once when it is gone.
import { Sandbox, SandboxNotRunningError, SandboxUnreachableError, TimeoutError } from 'e2b';
import {
  askForSandbox,
  connect,
  GrantRefused,
  PageSandbox,
  RENEW_BEFORE_MS,
  sandboxGone,
  type GrantAnswer,
  type SandboxGrant,
} from '../guide/sandbox';

const EXPIRES = '2026-11-20T10:30:00.000Z';
const UNTIL = Date.parse(EXPIRES);

function grant(id: string): SandboxGrant {
  return { sandbox_id: id, access_token: `token-${id}`, envd_version: '0.4.2', domain: 'e2b.app', expires_at: EXPIRES };
}

/** A stand-in for the SDK client: the tests only compare identities. */
function fakeSandbox(id: string): Sandbox {
  return { sandboxId: id } as unknown as Sandbox;
}

/** A gate that answers the given grants in order and counts the requests. */
function asker(answers: GrantAnswer[]): { ask: () => Promise<GrantAnswer>; calls: () => number } {
  let n = 0;
  return {
    ask: async () => answers[Math.min(n++, answers.length - 1)],
    calls: () => n,
  };
}

const open = (g: SandboxGrant) => fakeSandbox(g.sandbox_id);

describe('connect', () => {
  test('builds a client of the grant sandbox, on its domain, with no traffic token', () => {
    const s = connect(grant('i8x3k2p9q1v7m4n6s5t0'));
    expect(s).toBeInstanceOf(Sandbox);
    expect(s.sandboxId).toBe('i8x3k2p9q1v7m4n6s5t0');
    expect(s.sandboxDomain).toBe('e2b.app');
    expect(s.trafficAccessToken).toBeUndefined();
  });
});

describe('sandboxGone', () => {
  test('is true for a sandbox that is not running or cannot be reached', () => {
    expect(sandboxGone(new SandboxNotRunningError('gone'))).toBe(true);
    expect(sandboxGone(new SandboxUnreachableError('no answer'))).toBe(true);
  });
  test('is false for other errors, including a plain timeout', () => {
    expect(sandboxGone(new TimeoutError('request timed out'))).toBe(false);
    expect(sandboxGone(new Error('boom'))).toBe(false);
    expect(sandboxGone('a string')).toBe(false);
  });
});

describe('askForSandbox', () => {
  test('a grant is returned as it is, with no session call', async () => {
    const session = jest.fn(async () => ({}));
    const sandbox = jest.fn(async (): Promise<GrantAnswer> => grant('a'));
    expect(await askForSandbox({ session, sandbox })).toEqual(grant('a'));
    expect(session).not.toHaveBeenCalled();
    expect(sandbox).toHaveBeenCalledTimes(1);
  });
  test('csrf_failed asks for the session again and the sandbox once more', async () => {
    const session = jest.fn(async () => ({}));
    const answers: GrantAnswer[] = [{ error: 'csrf_failed' }, grant('b')];
    const sandbox = jest.fn(async (): Promise<GrantAnswer> => answers.shift() as GrantAnswer);
    expect(await askForSandbox({ session, sandbox })).toEqual(grant('b'));
    expect(session).toHaveBeenCalledTimes(1);
    expect(sandbox).toHaveBeenCalledTimes(2);
  });
  test('a second csrf_failed is returned, not retried again', async () => {
    const session = jest.fn(async () => ({}));
    const sandbox = jest.fn(async (): Promise<GrantAnswer> => ({ error: 'csrf_failed' }));
    expect(await askForSandbox({ session, sandbox })).toEqual({ error: 'csrf_failed' });
    expect(sandbox).toHaveBeenCalledTimes(2);
  });
  test('any other error is returned at once', async () => {
    const session = jest.fn(async () => ({}));
    const sandbox = jest.fn(async (): Promise<GrantAnswer> => ({ error: 'session_required' }));
    expect(await askForSandbox({ session, sandbox })).toEqual({ error: 'session_required' });
    expect(session).not.toHaveBeenCalled();
    expect(sandbox).toHaveBeenCalledTimes(1);
  });
});

describe('PageSandbox', () => {
  test('asks for a sandbox when first needed and reuses it', async () => {
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => UNTIL - 10 * 60_000, open);
    expect(p.expiresAt()).toBeNull();
    const first = await p.get();
    expect(first.sandboxId).toBe('one');
    expect(await p.get()).toBe(first);
    expect(a.calls()).toBe(1);
    expect(p.expiresAt()).toBe(UNTIL);
  });

  test('reuses the sandbox until RENEW_BEFORE_MS before expires_at, and asks for a new one from then on', async () => {
    let now = UNTIL - RENEW_BEFORE_MS - 1;
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => now, open);
    expect((await p.get()).sandboxId).toBe('one');
    expect((await p.get()).sandboxId).toBe('one');
    now = UNTIL - RENEW_BEFORE_MS;
    expect((await p.get()).sandboxId).toBe('two');
    expect(a.calls()).toBe(2);
  });

  test('callers asking at the same time share one request', async () => {
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    const [x, y] = await Promise.all([p.get(), p.get()]);
    expect(x).toBe(y);
    expect(a.calls()).toBe(1);
  });

  test('a refusal throws GrantRefused with the code, holds nothing, and the next get asks again', async () => {
    const a = asker([{ error: 'session_required' }, grant('one')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    const refused = await p.get().catch((e: unknown) => e);
    expect(refused).toBeInstanceOf(GrantRefused);
    expect((refused as GrantRefused).code).toBe('session_required');
    expect((refused as GrantRefused).message).toBe('the sandbox endpoint answered session_required');
    expect(p.expiresAt()).toBeNull();
    expect((await p.get()).sandboxId).toBe('one');
  });

  test('drop forgets the sandbox', async () => {
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    await p.get();
    p.drop();
    expect(p.expiresAt()).toBeNull();
    expect((await p.get()).sandboxId).toBe('two');
  });

  test('use runs once more on a new sandbox when the first is gone', async () => {
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    const seen: string[] = [];
    const out = await p.use(async (s) => {
      seen.push(s.sandboxId);
      if (s.sandboxId === 'one') throw new SandboxNotRunningError('gone');
      return 'ran';
    });
    expect(out).toBe('ran');
    expect(seen).toEqual(['one', 'two']);
  });

  test('use gives up after the second sandbox is gone too', async () => {
    const a = asker([grant('one'), grant('two'), grant('three')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    const err = await p.use(async () => {
      throw new SandboxUnreachableError('no answer');
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(SandboxUnreachableError);
    expect(a.calls()).toBe(2);
  });

  test('use does not retry an error that is not a gone sandbox', async () => {
    const a = asker([grant('one'), grant('two')]);
    const p = new PageSandbox(a.ask, () => 0, open);
    let runs = 0;
    const err = await p.use(async () => {
      runs += 1;
      throw new Error('the program failed');
    }).catch((e: unknown) => e);
    expect((err as Error).message).toBe('the program failed');
    expect(runs).toBe(1);
    expect(a.calls()).toBe(1);
  });

  test('by default it opens the grant with connect and reads the clock', async () => {
    const p = new PageSandbox(async () => ({ ...grant('real'), expires_at: '2999-01-01T00:00:00.000Z' }));
    const s = await p.get();
    expect(s).toBeInstanceOf(Sandbox);
    expect(s.sandboxId).toBe('real');
    expect(await p.get()).toBe(s);
  });
});
