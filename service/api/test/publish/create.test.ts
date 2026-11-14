import { errorViewV2 } from '../../src/http/v2-catalogue';
import { RegistryError } from '../../src/errors';
import { MemoryStore } from '../../src/memory-store';
import type { PackageRecord } from '../../src/types';
import { ALICE, BOB, CAROL, DAVE, ERIN, createRig, type Rig } from './create-rig';

/** What a refusal renders as under /api/v2: status, code, message, and Retry-After when it has one. */
async function refused(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    const v = errorViewV2(e);
    return { status: v.status, code: v.body.error.code, message: v.body.error.message, ...(v.retryAfter !== undefined ? { retryAfter: v.retryAfter } : {}) };
  }
  throw new Error('expected a refusal');
}
const nothingWritten = async (r: Rig, full: string) => {
  expect(await r.registry.getPackage(full)).toBeUndefined();
  expect(await r.registry.listAudit(full)).toEqual([]);
};
async function rig(over: Parameters<typeof createRig>[0] = {}) {
  const r = createRig(over);
  await r.seed();
  return r;
}

describe('createPackage: who may create', () => {
  test('a session creates a package in its own user namespace; the row is claimed, has no owner and no expiry, and is audited', async () => {
    const r = await rig();
    expect(await r.creates.create(await r.session(ALICE), 'alice', 'json')).toEqual({ created: true });
    expect(await r.registry.getPackage('alice/json')).toEqual({ name: 'alice/json', state: 'claimed', created_at: '2026-10-14T12:00:00.000Z' });
    expect(await r.registry.listOwners('alice/json')).toEqual([]);
    expect(await r.registry.listAudit('alice/json')).toEqual([{ name: 'alice/json', ts: '2026-10-14T12:00:00.000Z', id: 'a_id0001', actor: 'u:1001', action: 'create' }]);
  });

  test('a second create answers the package that exists with created false and writes nothing more', async () => {
    const r = await rig();
    const t = await r.session(ALICE);
    await r.creates.create(t, 'alice', 'json');
    expect(await r.creates.create(t, 'alice', 'json')).toEqual({ created: false });
    expect(await r.registry.listAudit('alice/json')).toHaveLength(1);
  });

  test('an organization member and an organization admin create in the organization namespace', async () => {
    const r = await rig();
    expect(await r.creates.create(await r.session(CAROL), 'komira-ai', 'json')).toEqual({ created: true });
    expect(await r.creates.create(await r.session(DAVE), 'komira-ai', 'toml')).toEqual({ created: true });
    expect((await r.registry.listAudit('komira-ai/toml'))[0]!.actor).toBe('u:2002');
  });

  test('an API token with publish naming the full name creates it, even in a namespace not yet holding the package', async () => {
    const r = await rig();
    expect(await r.creates.create(await r.api(ALICE, ['alice/json']), 'alice', 'json')).toEqual({ created: true });
  });

  test('a CI token minted for the namespace creates its package; the audit actor is the namespace, or the repository when the token has a ci_owner', async () => {
    const r = await rig();
    expect(await r.creates.create(await r.ci('komira-ai', ['komira-ai/json']), 'komira-ai', 'json')).toEqual({ created: true });
    expect((await r.registry.listAudit('komira-ai/json'))[0]!.actor).toBe('ci:ns:komira-ai');
    expect(await r.creates.create(await r.ci('komira-ai', ['komira-ai/toml'], { ci_owner: 'gh-repo:99' }), 'komira-ai', 'toml')).toEqual({ created: true });
    expect((await r.registry.listAudit('komira-ai/toml'))[0]!.actor).toBe('ci:gh-repo:99');
    // A CI token needs no GitHub call: its right is the namespace publisher it was minted for.
    expect(r.gh.state.calls).toEqual([]);
  });
});

describe('createPackage: defaults', () => {
  test('without an injected clock or id source the audit row still gets a unique id of 32 hex digits', async () => {
    const r = await rig();
    const { CreateService } = await import('../../src/publish/create');
    const plain = new CreateService({ registry: r.registry, auth: r.authn, access: r.access, publishes: r.publishes, config: r.config, flags: r.flags });
    expect(await plain.create(await r.session(ALICE), 'alice', 'json')).toEqual({ created: true });
    expect((await r.registry.listAudit('alice/json'))[0]!.id).toMatch(/^a_[0-9a-f]{32}$/);
  });
});

describe('createPackage: refusals, in order', () => {
  test('read-only mode refuses before the token is looked at', async () => {
    const r = await rig();
    r.flags.ro = true;
    expect(await refused(r.creates.create(undefined, 'alice', 'json'))).toEqual({ status: 503, code: 'read_only_mode', message: 'The registry is read-only right now; new uploads are refused.' });
  });

  test('a read-only switch that cannot be read refuses as unavailable, and is logged', async () => {
    const r = await rig();
    r.flags.broken = true;
    expect(await refused(r.creates.create(await r.session(ALICE), 'alice', 'json'))).toEqual({ status: 503, code: 'unavailable', message: 'The registry is temporarily unavailable.' });
    expect(r.logs).toEqual([{ level: 'error', msg: 'read-only switch unreadable', error: 'Error: config table unreadable' }]);
  });

  test('a switch that cannot be read is refused without a logger too', async () => {
    const r = await rig();
    r.flags.broken = true;
    const { CreateService } = await import('../../src/publish/create');
    const bare = new CreateService({ registry: r.registry, auth: { authenticate: async () => { throw new Error('unreached'); } }, access: r.access, publishes: r.publishes, config: r.config, flags: r.flags });
    expect((await refused(bare.create(undefined, 'alice', 'json'))).code).toBe('unavailable');
  });

  test('no token, a token that is not recognised, and a stale token each fail as the authenticator says', async () => {
    const r = await rig();
    expect((await refused(r.creates.create(undefined, 'alice', 'json'))).code).toBe('token_missing');
    expect((await refused(r.creates.create('Bearer mopm_pat_nothing', 'alice', 'json'))).code).toBe('token_unknown');
    const t = await r.session(ALICE);
    r.clock.advance(2 * 86_400_000);
    expect((await refused(r.creates.create(t, 'alice', 'json'))).code).toBe('token_expired');
  });

  test.each(['Alice', 'a_b', '-a', 'alice-', 'a--b', ''])('the namespace %p is invalid_namespace', async (ns) => {
    const r = await rig();
    expect(await refused(r.creates.create(await r.session(ALICE), ns, 'json'))).toEqual({ status: 400, code: 'invalid_namespace', message: `'${ns}' is not a valid namespace.` });
  });

  test.each(['Json', '1json', 'j', 'json-x', ''])('the name %p is invalid_name', async (name) => {
    const r = await rig();
    expect(await refused(r.creates.create(await r.session(ALICE), 'alice', name))).toEqual({ status: 400, code: 'invalid_name', message: `'${name}' is not a valid package name.` });
  });

  test('a reserved namespace is namespace_reserved, and a namespace nobody made is namespace_not_found', async () => {
    const r = await rig();
    const t = await r.session(ALICE);
    expect(await refused(r.creates.create(t, 'index', 'json'))).toEqual({ status: 403, code: 'namespace_reserved', message: "'index' is reserved." });
    expect(await refused(r.creates.create(t, 'nobody', 'json'))).toEqual({ status: 404, code: 'namespace_not_found', message: "There is no namespace 'nobody'." });
  });

  test("another account's user namespace is not_namespace_member", async () => {
    const r = await rig();
    expect(await refused(r.creates.create(await r.session(ALICE), 'bob', 'json'))).toEqual({ status: 403, code: 'not_namespace_member', message: "You cannot write in 'bob'." });
    await nothingWritten(r, 'bob/json');
  });

  test('an organization non-member is not_namespace_member', async () => {
    const r = await rig();
    expect((await refused(r.creates.create(await r.session(ERIN), 'komira-ai', 'json'))).code).toBe('not_namespace_member');
    await nothingWritten(r, 'komira-ai/json');
  });

  test('a frozen organization is namespace_unverified', async () => {
    const r = await rig();
    const e = await refused(r.creates.create(await r.session(CAROL), 'frozen-org', 'json'));
    expect([e.status, e.code]).toEqual([403, 'namespace_unverified']);
    expect(e.message).toMatch(/^'frozen-org' cannot be verified on GitHub: /);
  });

  test('GitHub being down is unavailable, and nothing is written', async () => {
    const r = await rig();
    r.gh.state.faults.push({ path: /memberships/, reject: true });
    const e = await refused(r.creates.create(await r.session(CAROL), 'komira-ai', 'json'));
    expect([e.status, e.code]).toEqual([503, 'unavailable']);
    await nothingWritten(r, 'komira-ai/json');
  });

  test('a deployment with no GitHub App answers unavailable for an organization, and still serves a user namespace', async () => {
    const r = await rig({ app: false });
    const e = await refused(r.creates.create(await r.session(CAROL), 'komira-ai', 'json'));
    expect([e.status, e.code]).toEqual([503, 'unavailable']);
    expect(await r.creates.create(await r.session(ALICE), 'alice', 'json')).toEqual({ created: true });
  });

  test.each([
    ['an API token that does not name the package', (r: Rig) => r.api(ALICE, ['alice/other'])],
    ['an API token that names a flat package of the same name', (r: Rig) => r.api(ALICE, ['json'])],
    ['an API token with only the stage scope', (r: Rig) => r.api(ALICE, ['alice/json'], ['stage'])],
    ['an API token with only the yank scope', (r: Rig) => r.api(ALICE, ['alice/json'], ['yank'])],
    ['a CI token minted for another namespace', (r: Rig) => r.ci('komira-ai', ['alice/json'])],
    ['a CI token that does not name the package', (r: Rig) => r.ci('alice', ['alice/other'])],
    ['a CI token with only the stage scope', (r: Rig) => r.ci('alice', ['alice/json'], { scopes: ['stage'] })],
    ['a CI token of the v1 exchange (no namespace)', async (r: Rig) => r.ci(undefined as unknown as string, ['alice/json'])],
  ])('%s is scope_missing naming publish and the full name', async (_label, token) => {
    const r = await rig();
    expect(await refused(r.creates.create(await token(r), 'alice', 'json'))).toEqual({
      status: 403,
      code: 'scope_missing',
      message: "The token does not have the 'publish' scope for 'alice/json'.",
    });
    await nothingWritten(r, 'alice/json');
  });

  test('a CI token for a namespace nobody made is namespace_not_found', async () => {
    const r = await rig();
    expect((await refused(r.creates.create(await r.ci('ghost', ['ghost/json']), 'ghost', 'json'))).code).toBe('namespace_not_found');
  });

  test('the token is checked against the package before the namespace right: an API token of a non-member naming the package gets not_namespace_member, one not naming it scope_missing', async () => {
    const r = await rig();
    expect((await refused(r.creates.create(await r.api(ALICE, ['bob/json']), 'bob', 'json'))).code).toBe('not_namespace_member');
    expect((await refused(r.creates.create(await r.api(ALICE, []), 'bob', 'json'))).code).toBe('scope_missing');
  });

  test('the account that left an organization after its token was minted is refused by the live check', async () => {
    const r = await rig();
    const t = await r.api(CAROL, ['komira-ai/json']);
    r.gh.state.memberships.delete('komira-ai/carol');
    expect((await refused(r.creates.create(t, 'komira-ai', 'json'))).code).toBe('not_namespace_member');
  });
});

describe('createPackage: import names', () => {
  test("'collections' is a module of the Mojo standard library, rendered with its exact message", async () => {
    const r = await rig();
    expect(await refused(r.creates.create(await r.session(ALICE), 'alice', 'collections'))).toEqual({
      status: 403,
      code: 'name_reserved',
      message: "'collections' is a module of the Mojo standard library (std.collections).",
    });
    await nothingWritten(r, 'alice/collections');
  });

  test.each(['fn', 'struct', 'mojo', 'int'])("%p is 'reserved'", async (name) => {
    const r = await rig();
    expect(await refused(r.creates.create(await r.session(ALICE), 'alice', name))).toEqual({ status: 403, code: 'name_reserved', message: `'${name}' is reserved.` });
    await nothingWritten(r, `alice/${name}`);
  });

  test('the refusal carries the import name and the reason as detail', async () => {
    const r = await rig();
    await expect(r.creates.create(await r.session(ALICE), 'alice', 'fn')).rejects.toMatchObject({ code: 'name_reserved', detail: { name: 'fn', what: 'reserved' } });
  });

  test('a name the rules refuse now but that already exists is answered 200 (created false), not refused', async () => {
    const r = await rig();
    await r.registry.createPackage({ name: 'alice/collections', state: 'claimed', created_at: '2026-10-01T00:00:00.000Z' });
    expect(await r.creates.create(await r.session(ALICE), 'alice', 'collections')).toEqual({ created: false });
  });

  test('the right to write the namespace is checked before an existing package is answered', async () => {
    const r = await rig();
    await r.registry.createPackage({ name: 'bob/json', state: 'claimed', created_at: '2026-10-01T00:00:00.000Z' });
    expect((await refused(r.creates.create(await r.session(ALICE), 'bob', 'json'))).code).toBe('not_namespace_member');
  });

  test('a refused import name costs no quota', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    const t = await r.session(ALICE);
    await refused(r.creates.create(t, 'alice', 'fn'));
    expect(await r.creates.create(t, 'alice', 'json')).toEqual({ created: true });
  });
});

describe('createPackage: the daily limit', () => {
  test('the account limit refuses the N+1th create with Retry-After to midnight, leaves nothing, and charges nothing for it', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 2 } });
    const tokens = [await r.session(ALICE), await r.session(ALICE), await r.session(ALICE)];
    await r.creates.create(tokens[0]!, 'alice', 'one');
    await r.creates.create(tokens[1]!, 'alice', 'two');
    expect(await refused(r.creates.create(tokens[2]!, 'alice', 'three'))).toEqual({
      status: 429,
      code: 'rate_limited',
      message: 'Too many requests.',
      retryAfter: 43_200,
    });
    await nothingWritten(r, 'alice/three');
    const counters = Object.fromEntries([...r.publishes.counters].map(([k, v]) => [k.replace(/#tok_[0-9a-z]+#/, '#<token>#'), v]));
    expect(counters['rl#cu#1001#2026-10-14']).toBe(2);
    // The refused create's token hit was given back.
    expect([...r.publishes.counters].filter(([k]) => k.startsWith('rl#ct#')).map(([, v]) => v).sort()).toEqual([0, 1, 1]);
  });

  test('the token limit refuses with its own counter; another token of the same account still creates', async () => {
    const r = await rig({ config: { claimRatePerTokenPerDay: 1 } });
    const a = await r.session(ALICE);
    const b = await r.session(ALICE);
    await r.creates.create(a, 'alice', 'one');
    expect((await refused(r.creates.create(a, 'alice', 'two'))).code).toBe('rate_limited');
    expect(await r.creates.create(b, 'alice', 'two')).toEqual({ created: true });
  });

  test('an existing package answered with created false costs nothing', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    const t = await r.session(ALICE);
    await r.creates.create(t, 'alice', 'one');
    expect(await r.creates.create(t, 'alice', 'one')).toEqual({ created: false });
  });

  test('the counter resets on the next UTC day', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    const t = await r.session(ALICE);
    await r.creates.create(t, 'alice', 'one');
    expect((await refused(r.creates.create(t, 'alice', 'two'))).code).toBe('rate_limited');
    r.clock.advance(12 * 3600_000 + 1000);
    const fresh = await r.session(ALICE);
    expect(await r.creates.create(fresh, 'alice', 'two')).toEqual({ created: true });
  });

  test("a CI token is counted per namespace, not per account: two tokens of one namespace share the limit and another namespace's tokens do not", async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    await r.creates.create(await r.ci('komira-ai', ['komira-ai/one']), 'komira-ai', 'one');
    expect((await refused(r.creates.create(await r.ci('komira-ai', ['komira-ai/two']), 'komira-ai', 'two'))).code).toBe('rate_limited');
    expect([...r.publishes.counters.keys()].some((k) => k.startsWith('rl#cu#ns:komira-ai#'))).toBe(true);
    await r.creates.create(await r.ci('alice', ['alice/one']), 'alice', 'one');
  });

  test('the claim_limits override of the actor replaces both limits; a CI token is overridden by ci:ns:<namespace>', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1, claimRatePerTokenPerDay: 1 } });
    r.flags.claimLimits.set('u:1001', 3);
    r.flags.claimLimits.set('ci:ns:komira-ai', 2);
    const t = await r.session(ALICE);
    for (const n of ['one', 'two', 'three']) await r.creates.create(t, 'alice', n);
    expect((await refused(r.creates.create(t, 'alice', 'four'))).code).toBe('rate_limited');
    const c = await r.ci('komira-ai', ['komira-ai/one', 'komira-ai/two', 'komira-ai/three']);
    await r.creates.create(c, 'komira-ai', 'one');
    await r.creates.create(c, 'komira-ai', 'two');
    expect((await refused(r.creates.create(c, 'komira-ai', 'three'))).code).toBe('rate_limited');
  });

  test('an override that cannot be read keeps the config limits', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    r.flags.claimLimits.set('u:1001', 9);
    r.flags.claimLimitsBroken = true;
    const t = await r.session(ALICE);
    await r.creates.create(t, 'alice', 'one');
    expect((await refused(r.creates.create(t, 'alice', 'two'))).code).toBe('rate_limited');
  });

  test('a counter that cannot give a charge back does not hide the refusal', async () => {
    const r = await rig({ config: { claimRatePerAccountPerDay: 1 } });
    const t = await r.session(ALICE);
    await r.creates.create(t, 'alice', 'one');
    const hit = r.publishes.hit.bind(r.publishes);
    r.publishes.hit = async (key, limit, exp, by) => {
      if (by === -1) throw new Error('table down');
      return hit(key, limit, exp, by);
    };
    expect((await refused(r.creates.create(t, 'alice', 'two'))).code).toBe('rate_limited');
  });
});

describe('createPackage: the write', () => {
  /** A store where another request creates the same package between the check and the write. */
  class LosingStore extends MemoryStore {
    override async createPackage(pkg: PackageRecord): Promise<void> {
      await super.createPackage(pkg);
      throw new RegistryError('name_taken', `'${pkg.name}' is already taken.`, { name: pkg.name });
    }
  }
  class FailingStore extends MemoryStore {
    override async createPackage(): Promise<void> {
      throw new Error('table down');
    }
  }

  test('a create that loses the race is created false, writes no audit row, and gives its charge back', async () => {
    const r = await rig({ registry: new LosingStore(), config: { claimRatePerAccountPerDay: 1 } });
    expect(await r.creates.create(await r.session(ALICE), 'alice', 'json')).toEqual({ created: false });
    expect(await r.registry.listAudit('alice/json')).toEqual([]);
    expect(r.publishes.counters.get('rl#cu#1001#2026-10-14')).toBe(0);
  });

  test('a write that fails gives its charge back and the failure goes on', async () => {
    const r = await rig({ registry: new FailingStore(), config: { claimRatePerAccountPerDay: 1 } });
    await expect(r.creates.create(await r.session(ALICE), 'alice', 'json')).rejects.toThrow('table down');
    expect(r.publishes.counters.get('rl#cu#1001#2026-10-14')).toBe(0);
  });

  test('two requests for one name: one creates and the other finds it', async () => {
    const r = await rig();
    const t = await r.session(BOB);
    const results = await Promise.all([r.creates.create(t, 'bob', 'json'), r.creates.create(t, 'bob', 'json')]);
    expect(results.filter((x) => x.created)).toHaveLength(1);
    expect(await r.registry.listAudit('bob/json')).toHaveLength(1);
  });

  test('a flat name and a full name of the same name are different packages', async () => {
    const r = await rig();
    await r.registry.createPackage({ name: 'json', state: 'claimed', created_at: '2026-10-01T00:00:00.000Z' });
    expect(await r.creates.create(await r.session(ALICE), 'alice', 'json')).toEqual({ created: true });
  });
});
