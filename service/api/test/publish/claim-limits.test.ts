import { DynamoFlags, MAX_CLAIM_LIMIT, parseClaimLimits, StaticFlags, AnyFlag } from '../../src/publish/flags';
import { flagsFor } from '../../src/publish/wiring';
import { FakeDoc } from './fake-doc';
import { Harness } from './harness';

const docFor = () => new FakeDoc({ 't-config': 'key' });

const claim = (h: Harness, token: string, name: string) => h.call('POST', `/api/v1/packages/${name}/claim`, token);

async function account(h: Harness, id: number): Promise<string> {
  await h.authStore.upsertUser(id, `user_${id}`, h.clock.now().toISOString());
  return h.token(id, [], ['publish']);
}

/** Claims `n` distinct names (a letter prefix per call keeps them from being too similar) and returns the status codes. */
async function claimMany(h: Harness, token: string, n: number, prefix: string): Promise<number[]> {
  const out: number[] = [];
  for (let i = 0; i < n; i++) out.push((await claim(h, token, `${prefix}${String.fromCharCode(97 + (i % 26))}${String.fromCharCode(97 + Math.floor(i / 26))}x`)).statusCode);
  return out;
}

describe('parseClaimLimits', () => {
  test('keeps whole numbers of 1 or more per actor and clamps to the hard maximum', () => {
    const m = parseClaimLimits({ key: 'claim_limits', limits: { 'u:1': 300, 'u:2': 5000, 'u:3': 1 } });
    expect([...m]).toEqual([['u:1', 300], ['u:2', MAX_CLAIM_LIMIT], ['u:3', 1]]);
    expect(MAX_CLAIM_LIMIT).toBe(1000);
  });
  test('malformed entries and items say nothing', () => {
    expect(parseClaimLimits(undefined).size).toBe(0);
    expect(parseClaimLimits({ key: 'claim_limits' }).size).toBe(0);
    for (const limits of ['300', 300, null, [300], true]) expect(parseClaimLimits({ limits }).size).toBe(0);
    const m = parseClaimLimits({ limits: { 'u:1': '300', 'u:2': 0, 'u:3': -4, 'u:4': 2.5, 'u:5': null, 'u:6': Number.NaN, 'u:7': Infinity, 'u:8': 7 } });
    expect([...m]).toEqual([['u:8', 7]]);
  });
});

describe('the claim_limits item of the config table', () => {
  const put = (doc: FakeDoc, item: Record<string, unknown> | undefined) => {
    if (item) doc.table('t-config').set('claim_limits', { key: 'claim_limits', ...item });
    else doc.table('t-config').delete('claim_limits');
  };

  test('absent: undefined for everybody; present: the listed actor only', async () => {
    const doc = docFor();
    const flags = new DynamoFlags(doc as never, 't-config', 0);
    expect(await flags.claimLimitFor('u:1')).toBeUndefined();
    put(doc, { limits: { 'u:1': 400 } });
    expect([await flags.claimLimitFor('u:1'), await flags.claimLimitFor('u:2'), await flags.claimLimitFor('ci:gh-repo:1')]).toEqual([400, undefined, undefined]);
    put(doc, { limits: { 'u:1': 99999 } });
    expect(await flags.claimLimitFor('u:1')).toBe(MAX_CLAIM_LIMIT);
    put(doc, { limits: 'many' });
    expect(await flags.claimLimitFor('u:1')).toBeUndefined();
  });

  test('read from the same table as groups_enabled, consistently, and cached for the cache window', async () => {
    const doc = docFor();
    let t = 0;
    const flags = new DynamoFlags(doc as never, 't-config', 5000, () => t);
    put(doc, { limits: { 'u:1': 400 } });
    expect(await flags.claimLimitFor('u:1')).toBe(400);
    put(doc, { limits: { 'u:1': 10 } });
    expect(await flags.claimLimitFor('u:1')).toBe(400); // cached
    t = 5001;
    expect(await flags.claimLimitFor('u:1')).toBe(10); // refreshed
  });

  test('an unreadable table throws (as the groups switch does), and a static flag says nothing', async () => {
    const broken = new DynamoFlags({ send: async () => Promise.reject(new Error('AccessDenied')) } as never, 't-config', 0);
    await expect(broken.claimLimitFor('u:1')).rejects.toThrow('AccessDenied');
    expect(await new StaticFlags(false).claimLimitFor('u:1')).toBeUndefined();
    const doc = docFor();
    put(doc, { limits: { 'u:1': 70 } });
    expect(await new AnyFlag([new StaticFlags(false), new DynamoFlags(doc as never, 't-config', 0)]).claimLimitFor('u:1')).toBe(70);
  });
});

describe('the daily claim limit with an override', () => {
  test('no override: 50 claims pass and the 51st is rate_limited', async () => {
    const h = new Harness();
    const t = await account(h, 7);
    const codes = await claimMany(h, t, 51, 'p');
    expect(codes.slice(0, 50).every((c) => c === 201)).toBe(true);
    expect(codes[50]).toBe(429);
  });

  test('an override lifts the limit for the listed account only', async () => {
    const h = new Harness();
    h.flags.claimLimits.set('u:7', 60);
    const t7 = await account(h, 7);
    const t8 = await account(h, 8);
    expect((await claimMany(h, t7, 60, 'p')).every((c) => c === 201)).toBe(true);
    expect((await claim(h, t7, 'zzzzzz_last')).statusCode).toBe(429);
    // Another account has the default.
    const other = await claimMany(h, t8, 51, 'q');
    expect([other.slice(0, 50).every((c) => c === 201), other[50]]).toEqual([true, 429]);
  });

  test('an override of the real item path: the value above the hard cap is clamped, and the 1001st claim is refused', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 3, claimRatePerTokenPerDay: 3 });
    const doc = new FakeDoc({ 'mopm-t-config': 'key' });
    doc.table('mopm-t-config').set('claim_limits', { key: 'claim_limits', limits: { 'u:7': 1_000_000 } });
    // The production switches (static + the config table), as the Lambda builds them.
    const real = flagsFor({}, doc as never, 't');
    h.flags.claimLimitFor = (actor: string) => real.claimLimitFor(actor);
    const t = await account(h, 7);
    const limit = await h.flags.claimLimitFor('u:7');
    expect(limit).toBe(1000);
    // The counter is charged against the clamped value: after 1000 hits the next is refused.
    const day = h.clock.now().toISOString().slice(0, 10);
    const key = `rl#cu#7#${day}`;
    await h.publishes.hit(key, 1000, 0, 999);
    expect((await claim(h, t, 'alpha')).statusCode).toBe(201); // the 1000th
    expect((await claim(h, t, 'bravo')).statusCode).toBe(429); // the 1001st
  });

  test('a config that cannot be read keeps the default limit', async () => {
    const h = new Harness({ claimRatePerAccountPerDay: 1, claimRatePerTokenPerDay: 1 });
    h.flags.claimLimits.set('u:7', 500);
    h.flags.claimLimitsBroken = true;
    const t = await account(h, 7);
    expect((await claim(h, t, 'alpha')).statusCode).toBe(201);
    expect((await claim(h, t, 'bravo')).statusCode).toBe(429);
  });
});
