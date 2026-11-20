// The tokens row a Rust web login writes for its session (service/lambda/core/tests/fixtures/web_session_record.json;
// mopm_ports' test holds the Rust TokenRecord to `record`) is one the TypeScript Authenticator accepts as a session of
// its account: valid for seven days, never fresh, and the bearer of its token is that session.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { AuthError, Authenticator, MemoryAuthStore } from '../../src/auth';
import type { TokenRecord } from '../../src/auth';
import { TestClock } from '../auth-helpers';

const FIXTURE = path.join(__dirname, '../../../lambda/core/tests/fixtures/web_session_record.json');
const DOC = JSON.parse(fs.readFileSync(FIXTURE, 'utf8')) as { token: string; now: string; record: TokenRecord };
const DAY = 86_400_000;

async function setup(ms: number) {
  const store = new MemoryAuthStore();
  await store.putToken(DOC.record);
  const clock = new TestClock(Date.parse(DOC.now) + ms);
  return { auth: new Authenticator({ store, now: clock.now }) };
}

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(AuthError);
    return (e as AuthError).code;
  }
  throw new Error('expected an AuthError, got success');
}

test('the row is a session of its account, created now, fresh until its creation, expiring in seven days', () => {
  expect(DOC.record).toMatchObject({ kind: 'session', github_id: 4242, name: 'web login', scopes: [], packages: [] });
  expect(DOC.record.fresh_until).toBe(DOC.record.created_at);
  expect(DOC.record.created_at).toBe(DOC.now);
  expect(Date.parse(DOC.record.expires_at) - Date.parse(DOC.record.created_at)).toBe(7 * DAY);
});

test('the Authenticator accepts the token as that session, a minute after the login', async () => {
  const { auth } = await setup(60_000);
  const p = await auth.authenticate(`Bearer ${DOC.token}`);
  expect(p).toEqual({
    token_id: DOC.record.id,
    kind: 'session',
    github_id: 4242,
    scopes: [],
    packages: [],
    version: undefined,
    versions: undefined,
    ci_owner: undefined,
    acts_via: undefined,
    fresh_until: DOC.record.fresh_until,
  });
  expect(auth.userToken(p)).toBe(4242);
});

test('the session is never fresh, so it cannot reach a fresh-session route', async () => {
  const { auth } = await setup(0);
  const p = await auth.authenticate(`Bearer ${DOC.token}`);
  expect(await code(Promise.resolve().then(() => auth.freshSession(p)))).toBe('stale_session');
});

test('it is valid until the last millisecond of its seven days and expired from then on', async () => {
  const before = await setup(7 * DAY - 1);
  await expect(before.auth.authenticate(`Bearer ${DOC.token}`)).resolves.toMatchObject({ kind: 'session' });
  const at = await setup(7 * DAY);
  expect(await code(at.auth.authenticate(`Bearer ${DOC.token}`))).toBe('token_expired');
});

test('another token of the same grammar is not this session', async () => {
  const { auth } = await setup(0);
  const other = `mopm_${'a'.repeat(40)}`;
  expect(other).not.toBe(DOC.token);
  expect(await code(auth.authenticate(`Bearer ${other}`))).toBe('token_unknown');
});
