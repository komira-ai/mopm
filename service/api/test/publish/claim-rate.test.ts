import { DEFAULT_PUBLISH_CONFIG, publishConfigFromEnv } from '../../src/publish/config';
import { Harness } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string; hint: string };
const claim = (h: Harness, token: string, name: string, body?: unknown) => h.call('POST', `/api/v1/packages/${name}/claim`, token, body);

/** An account with a row in the users table, and `n` API tokens of it (each its own token counter). */
async function account(h: Harness, id: number, n = 1): Promise<string[]> {
  await h.authStore.upsertUser(id, `user_${id}`, h.clock.now().toISOString());
  const out: string[] = [];
  for (let i = 0; i < n; i++) out.push(await h.token(id, [], ['publish']));
  return out;
}
const counters = (h: Harness) => Object.fromEntries([...h.publishes.counters].map(([k, v]) => [k.replace(/#tok_[0-9a-z]+#/, '#<token>#'), v]));
const nothingWritten = async (h: Harness, name: string) => {
  expect(await h.registry.getPackage(name)).toBeUndefined();
  expect(await h.registry.listOwners(name)).toEqual([]);
  expect(await h.registry.listAudit(name)).toEqual([]);
};

describe('the claim rate limit', () => {
  test('the defaults are 50 a day for an account and 50 for a token', () => {
    expect(DEFAULT_PUBLISH_CONFIG).toMatchObject({ claimRatePerAccountPerDay: 50, claimRatePerTokenPerDay: 50 });
  });

  test('per account: the Nth claim passes, the N+1th is 429 rate_limited with Retry-After to midnight, and writes nothing', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 3 });
    const tokens = await account(h, 7, 4); // a token each, so only the account's counter can refuse
    for (const [i, name] of ['alpha', 'bravo', 'charlie'].entries()) expect((await claim(h, tokens[i]!, name)).statusCode).toBe(201);
    const res = await claim(h, tokens[3]!, 'delta');
    expect(res.statusCode).toBe(429);
    expect(err(res)).toEqual({ code: 'rate_limited', message: 'Too many requests.', hint: 'Wait 43200 seconds; the Retry-After header says how long.' });
    expect(res.headers['retry-after']).toBe('43200');
    await nothingWritten(h, 'delta');
    // The refused claim is not counted, and the token it came with was given its hit back.
    expect(counters(h)['rl#cu#7#2026-10-14']).toBe(3);
    expect([...h.publishes.counters].filter(([k]) => k.startsWith('rl#ct#')).map(([, v]) => v).sort()).toEqual([0, 1, 1, 1]);
  });

  test('per token: the Nth claim passes, the N+1th with that token is 429, and another token of the same account still claims', async () => {
    const h = new Harness({ claimRatePerTokenPerDay: 2 });
    const [a, b] = await account(h, 7, 2);
    expect((await claim(h, a!, 'alpha')).statusCode).toBe(201);
    expect((await claim(h, a!, 'bravo')).statusCode).toBe(201);
    const res = await claim(h, a!, 'charlie');
    expect([res.statusCode, err(res).code]).toEqual([429, 'rate_limited']);
    await nothingWritten(h, 'charlie');
    expect((await claim(h, b!, 'charlie')).statusCode).toBe(201);
    expect(counters(h)['rl#cu#7#2026-10-14']).toBe(3); // the refused claim was not charged to the account
  });

  test('another account is unaffected by the limit of the first', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 1, claimRatePerTokenPerDay: 1 });
    const [one] = await account(h, 7);
    const [two] = await account(h, 8);
    expect((await claim(h, one!, 'alpha')).statusCode).toBe(201);
    expect((await claim(h, one!, 'bravo')).statusCode).toBe(429);
    expect((await claim(h, two!, 'bravo')).statusCode).toBe(201);
    expect((await h.registry.listOwners('bravo')).map((o) => o.github_id)).toEqual([8]);
  });

  test('the counter resets the next UTC day', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 1 });
    const [t] = await account(h, 7);
    expect((await claim(h, t!, 'alpha')).statusCode).toBe(201);
    expect((await claim(h, t!, 'bravo')).statusCode).toBe(429);
    h.clock.advance(12 * 3600_000 + 1000); // 2026-10-14T12:00:00Z -> 2026-10-15T00:00:01Z
    expect((await claim(h, t!, 'bravo')).statusCode).toBe(201);
    expect(counters(h)['rl#cu#7#2026-10-15']).toBe(1);
  });

  test('the environment overrides the defaults, per stage', async () => {
    const config = publishConfigFromEnv({ MOPM_CLAIM_RATE_PER_ACCOUNT_DAY: '1', MOPM_CLAIM_RATE_PER_TOKEN_DAY: '9' });
    expect(config).toMatchObject({ claimRatePerAccountPerDay: 1, claimRatePerTokenPerDay: 9 });
    expect(() => publishConfigFromEnv({ MOPM_CLAIM_RATE_PER_ACCOUNT_DAY: '0' })).toThrow('MOPM_CLAIM_RATE_PER_ACCOUNT_DAY');
    expect(() => publishConfigFromEnv({ MOPM_CLAIM_RATE_PER_TOKEN_DAY: 'x' })).toThrow('MOPM_CLAIM_RATE_PER_TOKEN_DAY');
    const h = new Harness(config);
    const tokens = await account(h, 7, 2);
    expect((await claim(h, tokens[0]!, 'alpha')).statusCode).toBe(201);
    expect((await claim(h, tokens[1]!, 'bravo')).statusCode).toBe(429);
  });

  test('only a claim that is written is charged: a taken, reserved, invalid or too similar name costs no quota', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 1 });
    const [t] = await account(h, 7);
    await h.registry.createPackage({ name: 'http_client', state: 'active', created_at: '2026-10-01T09:00:00Z' });
    expect(err(await claim(h, t!, 'http_client')).code).toBe('name_taken');
    expect(err(await claim(h, t!, 'mopm')).code).toBe('name_reserved');
    expect(err(await claim(h, t!, 'Bad')).code).toBe('invalid_name');
    expect(err(await claim(h, t!, 'httpclient')).code).toBe('name_too_similar');
    expect(counters(h)).toEqual({});
    expect((await claim(h, t!, 'alpha')).statusCode).toBe(201);
  });

  test('a claim that loses the write (a concurrent claim of the name) gives its charge back', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 1 });
    const [t] = await account(h, 7);
    const real = h.registry.claimPackage.bind(h.registry);
    h.registry.claimPackage = async () => {
      throw new Error('boom');
    };
    expect((await claim(h, t!, 'alpha')).statusCode).toBe(500);
    expect(Object.values(counters(h))).toEqual([0, 0]);
    h.registry.claimPackage = real;
    expect((await claim(h, t!, 'alpha')).statusCode).toBe(201);
  });
});
