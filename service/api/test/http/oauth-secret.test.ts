import { AuthError } from '../../src/auth';
import { configureAuth, oidcAudiences } from '../../src/http/lambda';
import { OAuthSecretSource, oauthSecretName, type SecretReader } from '../../src/http/oauth-secret';
import { FakeAuthDoc } from '../auth-fake-doc';

// The GitHub OAuth app credentials come from Secrets Manager at runtime, per stage. What these prove: the client id
// is read lazily and cached, every way the secret can be wrong yields `unavailable` (never a crash, never the value in a
// log or an error), and a stage without the secret still wires everything else. What they do not: real Secrets Manager.

const leaks = (lines: string[], needle: string) => lines.join('\n').includes(needle);
const SECRET_VALUE = JSON.stringify({ client_id: 'Iv1.abcdef012345', client_secret: 'super-secret-client-secret-value' });

function reader(values: Array<string | undefined | Error>) {
  const calls: string[] = [];
  const read: SecretReader = async (id) => {
    calls.push(id);
    const v = values.length > 1 ? values.shift()! : values[0]!;
    if (v instanceof Error) throw v;
    return v;
  };
  return { read, calls };
}

async function codeOf(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    return e instanceof AuthError ? e.code : `other:${String(e)}`;
  }
  return 'ok';
}

describe('OAuthSecretSource', () => {
  const make = (values: Array<string | undefined | Error>) => {
    let t = 1_000_000;
    const r = reader(values);
    const src = new OAuthSecretSource({ secretId: 'mopm/beta/github-oauth', read: r.read, now: () => t });
    return { src, calls: r.calls, advance: (ms: number) => (t += ms) };
  };

  test('reads the client id (not the client secret), once, and reuses it for five minutes', async () => {
    const { src, calls, advance } = make([SECRET_VALUE]);
    expect(await src.clientId()).toBe('Iv1.abcdef012345');
    expect(await src.clientId()).toBe('Iv1.abcdef012345');
    expect(calls).toEqual(['mopm/beta/github-oauth']);
    advance(5 * 60_000 + 1);
    await src.clientId();
    expect(calls).toHaveLength(2);
  });

  test('nothing is read until the first use', () => {
    const { calls } = make([SECRET_VALUE]);
    expect(calls).toEqual([]);
  });

  test.each([
    ['the secret does not exist', undefined],
    ['not JSON', 'client_id=abc'],
    ['JSON without a client id', JSON.stringify({ client_secret: 'x' })],
    ['a client id of the wrong type', JSON.stringify({ client_id: 12345678 })],
    ['a client id with spaces or newlines', JSON.stringify({ client_id: 'Iv1.abc def\n' })],
    ['an empty client id', JSON.stringify({ client_id: '' })],
    ['a JSON array', '[]'],
    ['JSON null', 'null'],
    ['reading fails (access denied)', Object.assign(new Error('AccessDenied for arn:aws:secretsmanager:...'), { name: 'AccessDeniedException' })],
  ] as Array<[string, string | undefined | Error]>)('%s: unavailable, and the failure is remembered for 30 seconds only', async (_n, value) => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const { src, calls, advance } = make([value, SECRET_VALUE]);
      expect(await codeOf(src.clientId())).toBe('unavailable');
      expect(await codeOf(src.clientId())).toBe('unavailable'); // remembered: no second read
      expect(calls).toHaveLength(1);
      advance(30_001);
      expect(await src.clientId()).toBe('Iv1.abcdef012345'); // fixed: picked up without a redeploy
    } finally {
      spy.mockRestore();
    }
  });

  test('the secret value never reaches a log line or an error message', async () => {
    const lines: string[] = [];
    const spy = jest.spyOn(console, 'error').mockImplementation((...a: unknown[]) => void lines.push(a.map(String).join(' ')));
    try {
      for (const bad of [`{"client_id": "x", "client_secret": "super-secret-client-secret-value"`, JSON.stringify({ client_id: 'bad id', client_secret: 'super-secret-client-secret-value' })]) {
        const { src } = make([bad]);
        const e = await src.clientId().catch((x: Error) => x);
        expect(String((e as Error).message)).not.toContain('super-secret');
      }
      expect(lines.length).toBeGreaterThan(0);
      expect(leaks(lines, 'super-secret')).toBe(false);
      expect(leaks(lines, 'Iv1')).toBe(false);
    } finally {
      spy.mockRestore();
    }
  });

  // Can-fail proof: the leak check sees a line that carries the value (as a source that logged its input would).
  test('the leak check goes red on a line that carries the secret', () => {
    expect(leaks(['{"reason":"bad: super-secret-client-secret-value"}'], 'super-secret')).toBe(true);
    expect(leaks(['{"reason":"not JSON"}'], 'super-secret')).toBe(false);
  });
});

describe('names and audiences', () => {
  test('the secret is per stage and fixed in form', () => {
    expect(['beta', 'gamma', 'prod'].map(oauthSecretName)).toEqual(['mopm/beta/github-oauth', 'mopm/gamma/github-oauth', 'mopm/prod/github-oauth']);
  });
  test('CI tokens: beta accepts only its own host; gamma and prod keep their earlier audiences', () => {
    expect(oidcAudiences('beta')).toEqual(['beta.mopm.dev']);
    expect(oidcAudiences('gamma')).toEqual(['mopm.dev', 'gamma.mopm.dev']);
    expect(oidcAudiences('prod')).toEqual(['mopm.dev']);
  });
});

describe('configureAuth', () => {
  const doc = new FakeAuthDoc({});

  test('without the secret name in the environment auth is not wired at all', () => {
    expect(configureAuth('beta', doc, {})).toBeUndefined();
  });

  test('wiring reads no secret; the secret is read when a device login first needs it', async () => {
    const r = reader([SECRET_VALUE]);
    const auth = configureAuth('beta', doc, { MOPM_OAUTH_SECRET_NAME: 'mopm/beta/github-oauth' }, r.read)!;
    expect(r.calls).toEqual([]);
    expect(await auth.devices()).toBeDefined();
    expect(r.calls).toEqual(['mopm/beta/github-oauth']);
  });

  test('with the secret absent, devices() is unavailable while tokens and CI exchange are wired', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const auth = configureAuth('beta', doc, { MOPM_OAUTH_SECRET_NAME: 'mopm/beta/github-oauth' }, reader([undefined]).read)!;
      expect(await codeOf(auth.devices())).toBe('unavailable');
      expect(auth.tokens).toBeDefined();
      expect(auth.oidc).toBeDefined();
    } finally {
      spy.mockRestore();
    }
  });
});
