import { authTablesFor, DynamoAuthStore, MemoryAuthStore, ownedPackagesFrom } from '../src/auth';
import type { AuthStore, DeviceLoginRecord, TokenRecord, TrustedPublisher } from '../src/auth';
import { FakeAuthDoc, LAMBDA_GRANTS } from './auth-fake-doc';

// One suite for the AuthStore port, run against the memory adapter (which defines the rules) and the DynamoDB adapter
// on a strict fake client. The DynamoDB run is under the Lambda's real grants: DeleteItem is not among them, and the
// rows the normal paths write must satisfy DynamoDB's own rules (string keys, numeric TTL, aliased names).
// What it proves: the two adapters answer alike, and the DynamoDB one needs no permission the role lacks.
// What it does not: real DynamoDB behaviour (eventual consistency of the index, TTL timing) - see the adapter's header.

const tok = (over: Partial<TokenRecord> & { id: string; hash: string }): TokenRecord => ({
  kind: 'api',
  github_id: 1,
  name: 't',
  prefix: 'mopm_abcdef',
  scopes: ['publish'],
  packages: ['alpha'],
  all_current: false,
  created_at: '2026-10-14T12:00:00.000Z',
  expires_at: '2026-11-13T12:00:00.123Z',
  ...over,
});
const h = (n: number) => String(n).padStart(64, '0');
const login = (over: Partial<DeviceLoginRecord> = {}): DeviceLoginRecord => ({
  id: h(9),
  github_device_code: 'gh-device-code-0123456789',
  client: 'mopm 0.1.0',
  created_at: '2026-10-14T12:00:00.000Z',
  expires_at: '2026-10-14T12:10:00.000Z',
  interval: 5,
  ...over,
});
const tp = (over: Partial<TrustedPublisher> = {}): TrustedPublisher => ({
  id: 'tp1',
  name: 'alpha',
  repository_id: '111',
  repository_owner_id: '222',
  workflow: '.github/workflows/release.yml',
  added_by: 1,
  added_at: '2026-10-14T12:00:00.000Z',
  ...over,
});

type Check = (s: AuthStore) => Promise<void>;
const eq = (a: unknown, b: unknown) => expect(a).toEqual(b);

const CHECKS: Record<string, Check> = {
  'a user keeps created_at across logins, takes the new handle, and two_factor follows the last login': async (s) => {
    const first = await s.upsertUser(7, 'old', '2026-10-01T00:00:00.000Z', true);
    eq(first, { github_id: 7, handle: 'old', created_at: '2026-10-01T00:00:00.000Z', last_login_at: '2026-10-01T00:00:00.000Z', two_factor: true });
    const again = await s.upsertUser(7, 'new', '2026-10-05T00:00:00.000Z');
    eq(again, { github_id: 7, handle: 'new', created_at: '2026-10-01T00:00:00.000Z', last_login_at: '2026-10-05T00:00:00.000Z' });
    eq(await s.getUser(7), again);
    eq(await s.getUser(8), undefined);
  },
  'a token round-trips exactly, millisecond expiry included, by hash': async (s) => {
    const t = tok({ id: 'tok_a', hash: h(1), last_used_at: '2026-10-14T12:30:00.000Z' });
    await s.putToken(t);
    eq(await s.getTokenByHash(h(1)), t);
    eq(await s.getTokenByHash(h(2)), undefined);
  },
  'a CI token has no account: not listed for anyone, found by hash, keeps its single version': async (s) => {
    const t = tok({ id: 'tok_ci', hash: h(3), kind: 'oidc', github_id: undefined, version: '1.0.0', issued_to: 'acme/widgets' });
    delete t.github_id;
    await s.putToken(t);
    eq(await s.getTokenByHash(h(3)), t);
    eq(await s.listTokens(1), []);
  },
  'listTokens returns every token of the account (all kinds, any state) across pages, and nobody elses': async (s) => {
    for (let i = 1; i <= 5; i++) await s.putToken(tok({ id: `tok_${i}`, hash: h(i), github_id: 1, kind: i === 5 ? 'session' : 'api' }));
    await s.putToken(tok({ id: 'tok_other', hash: h(10), github_id: 2 }));
    await s.revokeToken(h(2), '2026-10-14T13:00:00.000Z');
    const ids = (await s.listTokens(1)).map((t) => t.id).sort();
    eq(ids, ['tok_1', 'tok_2', 'tok_3', 'tok_4', 'tok_5']);
    eq((await s.listTokens(2)).map((t) => t.id), ['tok_other']);
    eq(await s.listTokens(3), []);
  },
  'getUserToken finds the account own token and never another accounts': async (s) => {
    await s.putToken(tok({ id: 'tok_mine', hash: h(1), github_id: 1 }));
    await s.putToken(tok({ id: 'tok_theirs', hash: h(2), github_id: 2 }));
    eq((await s.getUserToken(1, 'tok_mine'))?.hash, h(1));
    eq(await s.getUserToken(1, 'tok_theirs'), undefined);
    eq(await s.getUserToken(2, 'tok_mine'), undefined);
    eq(await s.getUserToken(1, 'tok_nope'), undefined);
  },
  'revoking is idempotent, keeps the first time, and a missing token is nothing': async (s) => {
    await s.putToken(tok({ id: 'tok_a', hash: h(1) }));
    await s.revokeToken(h(1), '2026-10-14T13:00:00.000Z');
    await s.revokeToken(h(1), '2026-10-14T14:00:00.000Z');
    eq((await s.getTokenByHash(h(1)))?.revoked_at, '2026-10-14T13:00:00.000Z');
    await s.revokeToken(h(99), '2026-10-14T13:00:00.000Z');
    eq(await s.getTokenByHash(h(99)), undefined); // not created by revoking
  },
  'touching records last_used_at and does not create a token': async (s) => {
    await s.putToken(tok({ id: 'tok_a', hash: h(1) }));
    await s.touchToken(h(1), '2026-10-14T15:00:00.000Z');
    eq((await s.getTokenByHash(h(1)))?.last_used_at, '2026-10-14T15:00:00.000Z');
    await s.touchToken(h(98), '2026-10-14T15:00:00.000Z');
    eq(await s.getTokenByHash(h(98)), undefined);
  },
  'a device login round-trips, records polls, and once consumed is gone for good': async (s) => {
    const l = login();
    await s.putDeviceLogin(l);
    eq(await s.getDeviceLogin(l.id), l);
    await s.setDevicePolled(l.id, '2026-10-14T12:00:07.000Z', 10);
    eq(await s.getDeviceLogin(l.id), { ...l, last_polled_at: '2026-10-14T12:00:07.000Z', interval: 10 });
    await s.deleteDeviceLogin(l.id);
    eq(await s.getDeviceLogin(l.id), undefined);
    await s.deleteDeviceLogin(l.id); // repeating is fine
    await s.setDevicePolled(l.id, '2026-10-14T12:00:09.000Z', 15); // a poll after consumption changes nothing
    eq(await s.getDeviceLogin(l.id), undefined);
    await s.setDevicePolled(h(77), '2026-10-14T12:00:09.000Z', 15); // unknown id: nothing
    eq(await s.getDeviceLogin(h(77)), undefined);
  },
  'trusted publishers are per package, listed, and removable by id': async (s) => {
    await s.addTrustedPublisher(tp({ id: 'tp1' }));
    await s.addTrustedPublisher(tp({ id: 'tp2', environment: 'release' }));
    await s.addTrustedPublisher(tp({ id: 'tp3', name: 'beta_pkg' }));
    const ids = async (n: string) => (await s.listTrustedPublishers(n)).map((x) => x.id).sort();
    eq(await ids('alpha'), ['tp1', 'tp2']);
    eq(await ids('beta_pkg'), ['tp3']);
    eq((await s.listTrustedPublishers('alpha')).find((x) => x.id === 'tp2'), tp({ id: 'tp2', environment: 'release' }));
    await s.removeTrustedPublisher('alpha', 'tp1');
    eq(await ids('alpha'), ['tp2']);
    eq(await ids('nothing'), []);
  },
};

/** The DynamoDB adapter on the strict fake: full access (this suite also writes publishers, which the Lambda cannot). */
const dynamo = () => new DynamoAuthStore(new FakeAuthDoc({ pageSize: 2 }), authTablesFor('t'));

describe.each<[string, () => AuthStore]>([
  ['memory', () => new MemoryAuthStore()],
  ['dynamodb (strict fake)', dynamo],
])('AuthStore contract: %s', (_label, make) => {
  test.each(Object.entries(CHECKS))('%s', async (_name, check) => {
    await check(make());
  });
});

describe('the DynamoDB adapter under the Lambda grants', () => {
  const lambdaStore = () => {
    const doc = new FakeAuthDoc({ pageSize: 2, grants: LAMBDA_GRANTS });
    return { doc, store: new DynamoAuthStore(doc, authTablesFor('t')) };
  };
  // Everything the contract does except publisher writes (the Lambda has no route that writes them).
  const lambdaChecks = Object.entries(CHECKS).filter(([n]) => !n.startsWith('trusted publishers'));

  test.each(lambdaChecks)('%s', async (_n, check) => {
    await check(lambdaStore().store);
  });

  test('trusted publishers can be read (and not written) with the Lambda grants', async () => {
    const { doc, store } = lambdaStore();
    doc.seed('trusted_publishers', { ...tp(), publisher: 'tp1' });
    eq((await store.listTrustedPublishers('alpha')).map((x) => x.id), ['tp1']);
    await expect(store.addTrustedPublisher(tp({ id: 'tp9' }))).rejects.toMatchObject({ name: 'AccessDeniedException' });
    await expect(store.removeTrustedPublisher('alpha', 'tp1')).rejects.toMatchObject({ name: 'AccessDeniedException' });
  });

  test('no row is ever deleted: consuming a login keeps the row, drops GitHubs code, and TTL can still find it', async () => {
    const { doc, store } = lambdaStore();
    await store.putDeviceLogin(login());
    await store.deleteDeviceLogin(login().id);
    const rows = doc.dump('device_logins');
    eq(rows.length, 1);
    expect(rows[0]!.github_device_code).toBeUndefined();
    expect(JSON.stringify(rows)).not.toContain('gh-device-code');
    expect(typeof rows[0]!.expires_at).toBe('number'); // the TTL attribute
    expect(doc.commands).not.toContain('DeleteCommand');
  });

  test('stored rows keep secrets out: a token row has the hash and prefix, no secret field', async () => {
    const { doc, store } = lambdaStore();
    await store.putToken(tok({ id: 'tok_a', hash: h(1) }));
    const row = doc.dump('tokens')[0]!;
    eq(row.token_hash, h(1));
    expect(Object.keys(row).filter((k) => /secret|^token$/.test(k))).toEqual([]);
    eq(typeof row.expires_at, 'number');
    eq(row.expires_at, Math.floor(Date.parse('2026-11-13T12:00:00.123Z') / 1000));
    eq(typeof row.github_id, 'string'); // index keys are strings
  });

  test('ownedPackagesFrom reads the owners index across pages, only that account', async () => {
    const doc = new FakeAuthDoc({ pageSize: 2, grants: LAMBDA_GRANTS });
    for (const [n, g] of [['aa', 1], ['bb', 1], ['cc', 1], ['dd', 2]] as const) doc.seed('owners', { name: n, github_id: String(g), github_id_num: g });
    eq((await ownedPackagesFrom(doc, 'mopm-t-owners')(1)).sort(), ['aa', 'bb', 'cc']);
    eq(await ownedPackagesFrom(doc, 'mopm-t-owners')(3), []);
  });
});

// Can-fail proofs: each planted defect must turn a named check red. Without these, a green contract could mean
// the checks cannot see the defect.
describe('the contract goes red on planted defects', () => {
  const failing = async (name: string, s: AuthStore) => {
    await expect(CHECKS[name]!(s)).rejects.toThrow();
  };

  test('getUserToken that ignores the account', async () => {
    class Mutant extends MemoryAuthStore {
      override async getUserToken(_github_id: number, id: string) {
        return this.dumpTokens().find((t) => t.id === id);
      }
    }
    await failing('getUserToken finds the account own token and never another accounts', new Mutant());
  });

  test('revocation that overwrites the first time', async () => {
    class Mutant extends MemoryAuthStore {
      override async revokeToken(hash: string, at: string) {
        const t = this.dumpTokens().find((x) => x.hash === hash);
        if (t) await this.putToken({ ...t, revoked_at: at });
      }
    }
    await failing('revoking is idempotent, keeps the first time, and a missing token is nothing', new Mutant());
  });

  test('a consumed device login that can still be read', async () => {
    class Mutant extends MemoryAuthStore {
      override async deleteDeviceLogin() {
        /* forgets to consume */
      }
    }
    await failing('a device login round-trips, records polls, and once consumed is gone for good', new Mutant());
  });

  test('the DynamoDB adapter with a token TTL stored as the ISO string (DynamoDB would never expire the row)', async () => {
    const doc = new FakeAuthDoc({});
    const s = new DynamoAuthStore(doc, authTablesFor('t'));
    const original = doc.send.bind(doc);
    doc.send = async (cmd: any) => {
      if (cmd.input?.Item?.expires_at_iso) cmd.input.Item.expires_at = cmd.input.Item.expires_at_iso;
      return original(cmd);
    };
    await expect(s.putToken(tok({ id: 'tok_a', hash: h(1) }))).rejects.toMatchObject({ name: 'ValidationException' });
  });

  test('a raw reserved word in an expression is refused by the strict fake', async () => {
    const doc = new FakeAuthDoc({});
    const { QueryCommand } = await import('@aws-sdk/lib-dynamodb');
    await expect(
      doc.send(new QueryCommand({ TableName: 'mopm-t-trusted_publishers', KeyConditionExpression: 'name = :n', ExpressionAttributeValues: { ':n': 'alpha' } })),
    ).rejects.toMatchObject({ name: 'ValidationException' });
  });
});
