import {
  HttpGitHubAppApi,
  MemoryMembershipPassStore,
  MemoryNamespaceStore,
  NamespaceAccess,
  OrgMembership,
  mintToken,
  type NamespaceRecord,
} from '../../src/auth';
import { routePublish } from '../../src/http/publish-routes';
import { condaNameOf } from '../../src/names';
import { GroupService, groupIdFor } from '../../src/publish/group-service';
import { MemoryPresigner, MemoryQueue } from '../../src/publish/memory';
import { APP_ID, APP_PRIVATE_KEY, fakeGitHubApp } from '../github-app-fake';
import { Harness, sha256 } from './harness';

// The publish and group operations under /api/v2 (docs/design/namespaces.md section 8): a package is
// /packages/{namespace}/{name}, the namespace is the owner, and a file is mojo-<namespace>.<name>-<version>-<build>.conda.

const ALICE = 1; // owns the user namespace alice
const BOB = 2; // owns the user namespace bob
const CAROL = 3; // an active member of the organization komira-ai
const ORG_ID = 77;
const INST = 5555;
const FROZEN_ID = 78;
const BUILD = 'mojo1.0.0_0';
const SHA = 'a'.repeat(64);

const body = (r: { body: string }) => JSON.parse(r.body);
const err = (r: { body: string }) => body(r).error as { code: string; message: string; hint: string };
const fileOf = (full: string, version = '1.0.0') => `${condaNameOf(full)}-${version}-${BUILD}.conda`;
const fileFacts = (full: string, version = '1.0.0', over: Record<string, unknown> = {}) => ({ subdir: 'noarch', filename: fileOf(full, version), sha256: SHA, size: 100, ...over });
const member = (full: string, version = '1.0.0') => ({ name: full, version, files: [fileFacts(full, version)] });

async function rig() {
  const h = new Harness();
  const gh = fakeGitHubApp(h.clock.now);
  gh.install(INST, { id: ORG_ID, login: 'komira-ai' }).user(CAROL, 'carol').member('komira-ai', 'carol', CAROL);
  const store = new MemoryNamespaceStore();
  const at = h.clock.now().toISOString();
  const rows: NamespaceRecord[] = [
    { namespace: 'alice', kind: 'user', github_id: ALICE, created_at: at },
    { namespace: 'bob', kind: 'user', github_id: BOB, created_at: at },
    { namespace: 'komira-ai', kind: 'org', github_id: ORG_ID, created_at: at, installation_id: INST },
    { namespace: 'frozen-org', kind: 'org', github_id: FROZEN_ID, created_at: at },
  ];
  for (const r of rows) await store.createNamespace(r);
  const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, h.clock.now, gh.fetchFn);
  const membership = new OrgMembership({ app, passes: new MemoryMembershipPassStore(), now: h.clock.now });
  const access = new NamespaceAccess({ namespaces: store, users: h.authStore, membership });
  h.namespaces = access;
  h.v2 = { access, namespaces: store };
  h.build();
  for (const [id, handle] of [[ALICE, 'alice'], [BOB, 'bob'], [CAROL, 'carol']] as const) await h.authStore.upsertUser(id, handle, at);
  const make = (full: string) => h.registry.createPackage({ name: full, state: 'active', created_at: at });
  return { h, gh, store, access, make };
}
type Rig = Awaited<ReturnType<typeof rig>>;

const begin = (r: Rig, token: string | undefined, full: string, version = '1.0.0', over: Record<string, unknown> = {}) =>
  r.h.call('POST', `/api/v2/packages/${full}/${version}/files`, token, fileFacts(full, version, over));
const commit = (r: Rig, token: string, full: string, uploadIds: string[], version = '1.0.0') =>
  r.h.call('POST', `/api/v2/packages/${full}/${version}/publish`, token, { upload_ids: uploadIds });
const yank = (r: Rig, token: string | undefined, full: string, version = '1.0.0', b: unknown = { yanked: true, reason: 'broken' }) =>
  r.h.call('PUT', `/api/v2/packages/${full}/${version}/yank`, token, b);

/** A package that has a published version, as a validated publish leaves it. */
async function withVersion(r: Rig, full: string, version = '1.0.0') {
  await r.make(full);
  const f = fileFacts(full, version);
  await r.h.registry.createVersion(
    {
      name: full, version, canonical: version, build: BUILD, state: 'published', published_at: r.h.clock.now().toISOString(), requires_mojo: '', deps: [], native: [],
      files: [{ subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.size }], manifest_sha256: SHA, rev: 0,
    },
    { name: full, ts: r.h.clock.now().toISOString(), id: `a_${full}_${version}`, actor: 'u:1', action: 'publish_begin', version },
  );
}

/** A token of the CI identity of a publisher of `namespace`, minted for the full names it publishes. */
async function ciToken(r: Rig, namespace: string, packages: string[], version = '1.0.0'): Promise<string> {
  const t = r.h.clock.now();
  const m = await mintToken(r.h.authStore, {
    kind: 'oidc',
    name: 'ci',
    scopes: ['publish'],
    packages,
    all_current: false,
    version,
    versions: Object.fromEntries(packages.map((n) => [n, version])),
    ci_namespace: namespace,
    created_at: t.toISOString(),
    expires_at: new Date(t.getTime() + 3_600_000).toISOString(),
  });
  return m.secret;
}

describe('begin, commit and yank under /api/v2 by the namespace owner', () => {
  test('a user namespace owner begins an upload, commits it, and the publish record carries the full name and the v2 status_url', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    const started = await begin(r, token, 'alice/json');
    expect(started.statusCode).toBe(200);
    const up = (await r.h.publishes.getUpload(body(started).upload_id))!;
    expect(up).toMatchObject({ name: 'alice/json', version: '1.0.0', filename: 'mojo-alice.json-1.0.0-mojo1.0.0_0.conda' });
    expect(await r.h.registry.getVersion('alice/json', '1.0.0')).toMatchObject({ state: 'pending', published_by: 'alice' });
    await r.h.objects.put(up.key, Buffer.alloc(100), { contentType: 'application/octet-stream' });

    const done = await commit(r, token, 'alice/json', [up.upload_id]);
    expect(done.statusCode).toBe(202);
    const id = body(done).publish_id as string;
    expect(body(done).status_url).toBe(`/api/v2/publishes/${id}`);
    expect(r.h.validateQueue.sent.map((m) => m.groupId)).toEqual(['alice/json']);

    const status = await r.h.call('GET', `/api/v2/publishes/${id}`, token);
    expect(status.statusCode).toBe(200);
    expect(body(status)).toMatchObject({ publish_id: id, name: 'alice/json', version: '1.0.0', status: 'pending' });
  });

  test('yank and unyank work, and the audit and index messages are keyed by the full name', async () => {
    const r = await rig();
    await withVersion(r, 'alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['yank']);
    const y = await yank(r, token, 'alice/json');
    expect([y.statusCode, body(y)]).toMatchObject([200, { version: '1.0.0', state: 'yanked', yank_reason: 'broken' }]);
    expect(r.h.indexQueue.sent.map((m) => m.groupId)).toContain('pkg:alice/json');
    const back = await yank(r, token, 'alice/json', '1.0.0', { yanked: false });
    expect([back.statusCode, body(back).state]).toEqual([200, 'published']);
    expect((await r.h.registry.listAudit('alice/json')).map((a) => a.action).sort()).toEqual(['publish_begin', 'unyank', 'yank']);
  });

  test('yanking a version the package does not have is version_not_found', async () => {
    const r = await rig();
    await r.make('alice/json');
    const res = await yank(r, await r.h.token(ALICE, ['alice/json'], ['yank']), 'alice/json', '9.9.9');
    expect([res.statusCode, err(res).code]).toEqual([404, 'version_not_found']);
  });

  test('a package that was never created is package_not_found, after the namespace check', async () => {
    const r = await rig();
    const res = await begin(r, await r.h.token(ALICE, ['alice/json'], ['publish']), 'alice/json');
    expect([res.statusCode, err(res)]).toMatchObject([404, { code: 'package_not_found' }]);
  });
});

describe('who may write in the namespace', () => {
  test('an active member of the organization begins and commits; the handle recorded is the member\'s, not the organization\'s', async () => {
    const r = await rig();
    await r.make('komira-ai/json');
    const token = await r.h.token(CAROL, ['komira-ai/json'], ['publish']);
    const started = await begin(r, token, 'komira-ai/json');
    expect(started.statusCode).toBe(200);
    expect((await r.h.registry.getVersion('komira-ai/json', '1.0.0'))?.published_by).toBe('carol');
    expect(r.gh.reads()).toContain('GET /orgs/komira-ai/memberships/carol');
  });

  test('an account that is neither the owner nor a member is not_namespace_member (403) for begin, commit and yank', async () => {
    const r = await rig();
    await withVersion(r, 'alice/json');
    await withVersion(r, 'komira-ai/json');
    for (const full of ['alice/json', 'komira-ai/json']) {
      const token = await r.h.token(BOB, [full], ['publish']);
      const ns = full.split('/')[0]!;
      for (const res of [await begin(r, token, full), await commit(r, token, full, ['upl_x']), await yank(r, token, full)]) {
        expect([res.statusCode, err(res).code, err(res).message]).toEqual([403, 'not_namespace_member', `You cannot write in '${ns}'.`]);
      }
    }
    expect((await r.h.registry.getVersion('alice/json', '1.0.0'))?.state).toBe('published');
  });

  test('a member removed from the organization after the token was made is refused at once (the check is live)', async () => {
    const r = await rig();
    await r.make('komira-ai/json');
    const token = await r.h.token(CAROL, ['komira-ai/json'], ['publish']);
    expect((await begin(r, token, 'komira-ai/json')).statusCode).toBe(200);
    r.h.clock.advance(10 * 60_000); // past the kept pass
    r.gh.removeMember('komira-ai', 'carol');
    expect(err(await begin(r, token, 'komira-ai/json', '1.0.1')).code).toBe('not_namespace_member');
  });

  test('an organization namespace whose App installation is gone is namespace_unverified (403), with the message of the catalogue', async () => {
    const r = await rig();
    await r.make('frozen-org/json');
    const res = await begin(r, await r.h.token(CAROL, ['frozen-org/json'], ['publish']), 'frozen-org/json');
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([
      403,
      'namespace_unverified',
      "'frozen-org' cannot be verified on GitHub: the mopm registry GitHub App is not installed on the organization.",
    ]);
  });

  test('a namespace nobody made is namespace_not_found (404)', async () => {
    const r = await rig();
    const res = await begin(r, await r.h.token(ALICE, ['ghost/json'], ['publish']), 'ghost/json');
    expect([res.statusCode, err(res).code]).toEqual([404, 'namespace_not_found']);
  });

  test('a token that does not name the package is scope_missing, rendered from the v2 catalogue', async () => {
    const r = await rig();
    await r.make('alice/json');
    const res = await begin(r, await r.h.token(ALICE, ['alice/other'], ['publish']), 'alice/json');
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([403, 'scope_missing', "The token does not have the 'publish' scope for 'alice/json'."]);
  });

  test('a session-style token without a github id (an oidc token without a namespace) is not_owner', async () => {
    const r = await rig();
    await r.make('alice/json');
    const t = r.h.clock.now();
    const m = await mintToken(r.h.authStore, {
      kind: 'oidc', name: 'ci', scopes: ['publish'], packages: ['alice/json'], all_current: false, version: '1.0.0',
      created_at: t.toISOString(), expires_at: new Date(t.getTime() + 3_600_000).toISOString(),
    });
    const res = await begin(r, m.secret, 'alice/json');
    expect([res.statusCode, err(res).code]).toEqual([403, 'not_owner']);
  });

  test('without the namespace wiring a write to a full name is unavailable (503)', async () => {
    const r = await rig();
    await r.make('alice/json');
    r.h.namespaces = undefined;
    r.h.build();
    const res = await begin(r, await r.h.token(ALICE, ['alice/json'], ['publish']), 'alice/json');
    expect([res.statusCode, err(res).code]).toEqual([503, 'unavailable']);
  });

  test('a deployment with no GitHub App cannot check an organization: unavailable, while a user namespace still works', async () => {
    const r = await rig();
    await r.make('komira-ai/json');
    await r.make('alice/json');
    r.h.namespaces = new NamespaceAccess({ namespaces: r.store, users: r.h.authStore });
    r.h.build();
    const org = await begin(r, await r.h.token(CAROL, ['komira-ai/json'], ['publish']), 'komira-ai/json');
    expect([org.statusCode, err(org).code, err(org).message]).toEqual([503, 'unavailable', 'The registry is temporarily unavailable.']);
    expect((await begin(r, await r.h.token(ALICE, ['alice/json'], ['publish']), 'alice/json')).statusCode).toBe(200);
  });

  test('without the v2 deps every publish path of /api/v2 is unavailable, and /api/v1 is not affected', async () => {
    const r = await rig();
    const res = await routePublish({ method: 'POST', path: '/api/v2/packages/alice/json/1.0.0/files', query: {}, headers: {}, body: '{}' }, r.h.deps.publish!, 'rid');
    expect([res?.statusCode, JSON.parse(res!.body).error.code]).toEqual([503, 'unavailable']);
    const v1 = await routePublish({ method: 'GET', path: '/api/v1/publishes/pub_x', query: {}, headers: {} }, r.h.deps.publish!, 'rid');
    expect(v1?.statusCode).toBe(401);
  });
});

describe('the file name rule under /api/v2', () => {
  test('the conda name is mojo-<namespace>.<name>: the flat file name of the same package is upload_invalid, and names the one expected', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    const res = await begin(r, token, 'alice/json', '1.0.0', { filename: 'mojo-json-1.0.0-mojo1.0.0_0.conda' });
    expect([res.statusCode, err(res).code]).toEqual([400, 'upload_invalid']);
    expect(err(res).message).toBe('The upload does not match what was declared: the file name must be mojo-alice.json-1.0.0-<build>.conda.');
    expect(await r.h.registry.getVersion('alice/json', '1.0.0')).toBeUndefined();
  });

  test('a file named for another namespace\'s package is refused', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    expect(err(await begin(r, token, 'alice/json', '1.0.0', { filename: fileOf('bob/json') })).code).toBe('upload_invalid');
  });
});

describe('a CI token of a namespace\'s publisher', () => {
  test('is allowed for the full names of its namespace: begin and commit, the handle recorded being ci', async () => {
    const r = await rig();
    await r.make('komira-ai/json');
    const token = await ciToken(r, 'komira-ai', ['komira-ai/json']);
    const started = await begin(r, token, 'komira-ai/json');
    expect(started.statusCode).toBe(200);
    expect((await r.h.registry.getVersion('komira-ai/json', '1.0.0'))?.published_by).toBe('ci');
    const up = (await r.h.publishes.getUpload(body(started).upload_id))!;
    await r.h.objects.put(up.key, Buffer.alloc(100), { contentType: 'application/octet-stream' });
    expect((await commit(r, token, 'komira-ai/json', [up.upload_id])).statusCode).toBe(202);
  });

  test('can yank the version it was minted for', async () => {
    const r = await rig();
    await withVersion(r, 'komira-ai/json');
    const res = await yank(r, await ciToken(r, 'komira-ai', ['komira-ai/json']), 'komira-ai/json');
    expect(res.statusCode).toBe(200);
  });

  test('is refused (not_namespace_member) for a package of another namespace even when the token names it', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await ciToken(r, 'komira-ai', ['alice/json']);
    const res = await begin(r, token, 'alice/json');
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([403, 'not_namespace_member', "You cannot write in 'alice'."]);
    expect(await r.h.registry.getVersion('alice/json', '1.0.0')).toBeUndefined();
  });

  test('is scope_missing for a package its token does not name, and for another version', async () => {
    const r = await rig();
    await r.make('komira-ai/json');
    await r.make('komira-ai/other');
    const token = await ciToken(r, 'komira-ai', ['komira-ai/json']);
    expect(err(await begin(r, token, 'komira-ai/other')).code).toBe('scope_missing');
    expect(err(await begin(r, token, 'komira-ai/json', '2.0.0')).code).toBe('scope_missing');
  });

  test('is refused on a frozen organization namespace (namespace_unverified), and for a package that does not exist', async () => {
    const r = await rig();
    await r.make('frozen-org/json');
    expect(err(await begin(r, await ciToken(r, 'frozen-org', ['frozen-org/json']), 'frozen-org/json')).code).toBe('namespace_unverified');
    expect(err(await begin(r, await ciToken(r, 'komira-ai', ['komira-ai/new']), 'komira-ai/new')).code).toBe('package_not_found');
  });

  test('is refused when the namespace row is gone, and without the namespace wiring (unavailable)', async () => {
    const r = await rig();
    await r.make('ghost/json');
    expect(err(await begin(r, await ciToken(r, 'ghost', ['ghost/json']), 'ghost/json')).code).toBe('namespace_not_found');
    await r.make('komira-ai/json');
    r.h.namespaces = undefined;
    r.h.build();
    expect(err(await begin(r, await ciToken(r, 'komira-ai', ['komira-ai/json']), 'komira-ai/json')).code).toBe('unavailable');
  });

  test('never owns a flat package, even one whose registered trusted publisher would admit an ordinary CI token', async () => {
    const r = await rig();
    await r.h.registry.createPackage({ name: 'flat_pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    const token = await ciToken(r, 'komira-ai', ['flat_pkg']);
    const res = await r.h.call('POST', '/api/v1/packages/flat_pkg/1.0.0/files', token, {
      subdir: 'noarch', filename: 'mojo-flat_pkg-1.0.0-mojo1.0.0_0.conda', sha256: SHA, size: 100,
    });
    expect([res.statusCode, err(res).code]).toEqual([403, 'not_owner']);
  });

  test('an acts_for CI token (it has the account\'s github id) is checked as that account', async () => {
    const r = await rig();
    await r.make('alice/json');
    const t = r.h.clock.now();
    const mk = async (id: number) =>
      (
        await mintToken(r.h.authStore, {
          kind: 'oidc', github_id: id, name: 'ci', scopes: ['publish'], packages: ['alice/json'], all_current: false, version: '1.0.0', acts_via: 'gh-repo:5',
          created_at: t.toISOString(), expires_at: new Date(t.getTime() + 3_600_000).toISOString(),
        })
      ).secret;
    expect((await begin(r, await mk(ALICE), 'alice/json')).statusCode).toBe(200);
    expect(err(await begin(r, await mk(BOB), 'alice/json', '1.0.0')).code).toBe('not_namespace_member');
  });
});

describe('the paths of /api/v2', () => {
  test.each([
    ['an uppercase namespace', 'Alice/json', 'invalid_namespace', "'Alice' is not a valid namespace."],
    ['a namespace with an underscore', 'my_org/json', 'invalid_namespace', "'my_org' is not a valid namespace."],
    ['a name with a hyphen', 'alice/my-json', 'invalid_name', "'my-json' is not a valid package name."],
    ['a name that is too short', 'alice/j', 'invalid_name', "'j' is not a valid package name."],
  ])('%s is %s before anything is looked up', async (_label, full, code, message) => {
    const r = await rig();
    for (const res of [await begin(r, undefined, full), await yank(r, undefined, full), await r.h.call('POST', `/api/v2/packages/${full}/1.0.0/publish`, undefined, {})]) {
      expect([res.statusCode, err(res).code, err(res).message]).toEqual([400, code, message]);
    }
  });

  test('a flat name in the path of /api/v2 is not one of its routes, and /api/v2 has no claim route', async () => {
    const r = await rig();
    const token = await r.h.token(ALICE, ['json'], ['publish']);
    for (const [method, path] of [
      ['POST', '/api/v2/packages/json/1.0.0/files'],
      ['POST', '/api/v2/packages/alice/json/claim'],
      ['POST', '/api/v2/packages/alice/json/1.0.0/claim'],
    ] as const) {
      const res = await r.h.call(method, path, token, {});
      expect({ path, status: res.statusCode, code: err(res).code }).toEqual({ path, status: 404, code: 'route_not_found' });
    }
  });

  test.each(['/api/v1/packages/%E0%A4%A/1.0.0/files', '/api/v2/packages/alice/%E0%A4%A/1.0.0/files', '/api/v3/packages/alice/json/1.0.0/files', '/other'])(
    'a path that does not decode, or is under no known prefix (%s), is not a route of the publish operations',
    async (path) => {
      const r = await rig();
      expect(await routePublish({ method: 'POST', path, query: {}, headers: {}, body: '{}' }, r.h.deps.publish!, 'rid', r.h.v2)).toBeUndefined();
    },
  );

  test('a full name sent encoded to /api/v1 is invalid_name there, not a package of v2', async () => {
    const r = await rig();
    const res = await r.h.call('POST', '/api/v1/packages/alice%2Fjson/1.0.0/files', await r.h.token(ALICE, ['alice/json'], ['publish']), fileFacts('alice/json'));
    expect([res.statusCode, err(res).code]).toEqual([400, 'invalid_name']);
  });

  test('a publish is seen by the API its package name belongs to: v1 does not show a full name\'s, v2 does not show a flat one\'s', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    const up = (await r.h.publishes.getUpload(body(await begin(r, token, 'alice/json')).upload_id))!;
    await r.h.objects.put(up.key, Buffer.alloc(100), { contentType: 'application/octet-stream' });
    const id = body(await commit(r, token, 'alice/json', [up.upload_id])).publish_id as string;
    const viaV1 = await r.h.call('GET', `/api/v1/publishes/${id}`, token);
    expect([viaV1.statusCode, err(viaV1).code]).toEqual([404, 'publish_not_found']);

    const a = await r.h.account(5, 'flatty', ['flat_one']);
    const flat = await r.h.upload(a.token, { name: 'flat_one', version: '1.0.0', subdir: 'noarch', bytes: Buffer.alloc(10), filename: 'mojo-flat_one-1.0.0-mojo1.0.0_0.conda', sha256: sha256(Buffer.alloc(10)), manifest: SHA });
    const flatCommit = await r.h.commit(a.token, 'flat_one', '1.0.0', [flat.upload_id!], SHA);
    expect(body(flatCommit).status_url).toMatch(/^\/api\/v1\/publishes\//);
    const flatId = body(flatCommit).publish_id as string;
    expect((await r.h.call('GET', `/api/v1/publishes/${flatId}`, a.token)).statusCode).toBe(200);
    expect(err(await r.h.call('GET', `/api/v2/publishes/${flatId}`, a.token)).code).toBe('publish_not_found');
  });

  test('read-only mode refuses a begin under /api/v2 with the v2 rendering, and a yank is still allowed', async () => {
    const r = await rig();
    await withVersion(r, 'alice/json');
    r.h.flags.ro = true;
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    expect([(await begin(r, token, 'alice/json', '2.0.0')).statusCode]).toEqual([503]);
    expect((await yank(r, token, 'alice/json')).statusCode).toBe(200);
  });

  test('an internal failure under /api/v2 is internal_error (500) and is logged', async () => {
    const r = await rig();
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    jest.spyOn(r.h.service, 'begin').mockRejectedValue(new Error('boom'));
    const res = await begin(r, token, 'alice/json');
    expect([res.statusCode, err(res).code]).toEqual([500, 'internal_error']);
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });
});

describe('groups under /api/v2', () => {
  const create = (r: Rig, token: string, members: unknown[], version: 'v1' | 'v2' = 'v2') => r.h.call('POST', `/api/${version}/groups`, token, { members });

  test('a group spans two namespaces: each member is checked against its own namespace, and the answer lists full names', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('alice/json');
    await r.make('komira-ai/yaml');
    // Carol is a member of komira-ai but owns no namespace of her own: she may not write alice/json.
    const refused = await create(r, await r.h.token(CAROL, ['alice/json', 'komira-ai/yaml'], ['publish']), [member('alice/json'), member('komira-ai/yaml')]);
    expect([refused.statusCode, err(refused).code, err(refused).message]).toEqual([403, 'not_namespace_member', "You cannot write in 'alice'."]);

    // Alice is also an admin of the organization, so she may write both.
    r.gh.user(ALICE, 'alice').member('komira-ai', 'alice', ALICE, 'admin');
    const ok = await create(r, await r.h.token(ALICE, ['alice/json', 'komira-ai/yaml'], ['publish']), [member('komira-ai/yaml'), member('alice/json')]);
    expect(ok.statusCode).toBe(201);
    expect(body(ok).members.map((m: { name: string }) => m.name)).toEqual(['alice/json', 'komira-ai/yaml']);
    const gid = body(ok).group_id as string;
    expect(gid).toBe(groupIdFor('u:1', r.h.groupService.parse({ members: [member('alice/json'), member('komira-ai/yaml')] }, 'v2')));
    const upload = await r.h.publishes.getUpload(body(ok).members[0].files[0].upload_id);
    expect(body(ok).members[0].files[0].filename).toBe('mojo-alice.json-1.0.0-mojo1.0.0_0.conda');
    expect(upload).toMatchObject({ name: 'alice/json' });

    const got = await r.h.call('GET', `/api/v2/groups/${gid}`, await r.h.token(ALICE, ['alice/json', 'komira-ai/yaml'], ['publish']));
    expect([got.statusCode, body(got).members.map((m: { name: string }) => m.name)]).toEqual([200, ['alice/json', 'komira-ai/yaml']]);
    const aborted = await r.h.call('DELETE', `/api/v2/groups/${gid}`, await r.h.token(ALICE, ['alice/json'], ['publish']));
    expect(aborted.statusCode).toBe(200);
  });

  test('flat member names are invalid_name under /api/v2, and full names are invalid_name under /api/v1', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('alice/json');
    await r.h.registry.createPackage({ name: 'flat_one', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    const token = await r.h.token(ALICE, ['alice/json', 'flat_one'], ['publish']);
    const flatInV2 = await create(r, token, [member('alice/json'), { name: 'flat_one', version: '1.0.0', files: [fileFacts('flat_one')] }]);
    expect([flatInV2.statusCode, err(flatInV2).code, err(flatInV2).message]).toEqual([400, 'invalid_name', "'flat_one' is not a valid package name."]);
    const fullInV1 = await create(r, token, [member('alice/json')], 'v1');
    expect([fullInV1.statusCode, err(fullInV1).code, err(fullInV1).message]).toEqual([400, 'invalid_name', "'alice/json' is not a valid package name."]);
    expect(r.h.groupService.parse({ members: [{ name: 'flat_one', version: '1.0.0', files: [fileFacts('flat_one')] }] }).members).toHaveLength(1); // the default is v1
  });

  test('a member whose file carries the flat conda name is upload_invalid, and a non-member account is refused for the whole group', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    const wrongFile = await create(r, token, [{ name: 'alice/json', version: '1.0.0', files: [fileFacts('alice/json', '1.0.0', { filename: 'mojo-json-1.0.0-mojo1.0.0_0.conda' })] }]);
    expect([wrongFile.statusCode, err(wrongFile).code]).toEqual([400, 'upload_invalid']);
    const notMine = await create(r, await r.h.token(BOB, ['alice/json'], ['publish']), [member('alice/json')]);
    expect([notMine.statusCode, err(notMine).code]).toEqual([403, 'not_namespace_member']);
  });

  test('a CI token of a namespace creates a group of that namespace\'s full names only; the token must cover every member', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('komira-ai/yaml');
    await r.make('alice/json');
    const token = await ciToken(r, 'komira-ai', ['komira-ai/yaml', 'alice/json']);
    const mixed = await create(r, token, [member('komira-ai/yaml'), member('alice/json')]);
    expect([mixed.statusCode, err(mixed).code]).toEqual([403, 'not_namespace_member']);
    const own = await create(r, await ciToken(r, 'komira-ai', ['komira-ai/yaml']), [member('komira-ai/yaml')]);
    expect(own.statusCode).toBe(201);
    const uncovered = await create(r, await ciToken(r, 'komira-ai', ['komira-ai/yaml']), [member('komira-ai/other')]);
    expect([uncovered.statusCode, err(uncovered).code]).toEqual([403, 'scope_missing']);
  });

  test('the commit of a group answers a status_url under /api/v2', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('alice/json');
    const token = await r.h.token(ALICE, ['alice/json'], ['publish']);
    r.h.deps.publish!.groups = new GroupService({
      registry: r.h.registry, namespaces: r.access, publishes: r.h.publishes, objects: r.h.objects, presigner: new MemoryPresigner(), config: r.h.config,
      groupQueue: new MemoryQueue(), now: r.h.clock.now,
    });
    const made = await create(r, token, [member('alice/json')]);
    expect(made.statusCode).toBe(201);
    const gid = body(made).group_id as string;
    const f = body(made).members[0].files[0];
    await r.h.objects.put(`quarantine/${f.upload_id}/${f.filename}`, Buffer.alloc(100), { contentType: 'application/octet-stream' });
    const done = await r.h.call('POST', `/api/v2/groups/${gid}/commit`, token, { members: [{ name: 'alice/json' }] });
    expect([done.statusCode, body(done).status_url]).toEqual([202, `/api/v2/groups/${gid}`]);
  });

  test('a group yank re-checks the namespace of every member: a creator who left the organization is not_namespace_member', async () => {
    const r = await rig();
    r.h.flags.groupsAll = true;
    await r.make('komira-ai/yaml');
    const token = await r.h.token(CAROL, ['komira-ai/yaml'], ['publish']);
    r.h.deps.publish!.groups = new GroupService({
      registry: r.h.registry, namespaces: r.access, publishes: r.h.publishes, objects: r.h.objects, presigner: new MemoryPresigner(), config: r.h.config,
      groupQueue: new MemoryQueue(), now: r.h.clock.now,
    });
    const gid = body(await create(r, token, [member('komira-ai/yaml')])).group_id as string;
    const at = r.h.clock.now().toISOString();
    const audit = (id: string) => ({ name: gid, ts: at, id, actor: 'u:3', action: 'test_step' });
    await r.h.registry.updateGroup(gid, (cur) => ({ ...cur, status: 'validating' }), audit('a_validating'));
    const header = (await r.h.registry.getGroup(gid))!;
    expect(await r.h.registry.commitGroup(gid, { rev: header.rev, writeOrder: [0], now: at, audit: audit('a_commit') })).toMatchObject({ outcome: 'committed' });
    await r.h.registry.updateGroup(gid, (cur) => ({ ...cur, status: 'visible' }), audit('a_visible'));
    r.h.clock.advance(10 * 60_000); // past the kept pass
    r.gh.removeMember('komira-ai', 'carol');
    const res = await r.h.call('PUT', `/api/v2/groups/${gid}/yank`, token, { yanked: true, reason: 'x' });
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([403, 'not_namespace_member', "You cannot write in 'komira-ai'."]);
  });
});

describe('/api/v1 after names moved into namespaces', () => {
  const hint = 'package names are in namespaces now; update mopm';

  test('a claim is refused with name_reserved and the update hint, whoever asks and whatever the registry\'s mode', async () => {
    const r = await rig();
    const token = await r.h.token(ALICE, [], ['publish']);
    for (const t of [token, undefined, 'mp_bogus']) {
      const res = await r.h.call('POST', '/api/v1/packages/some_name/claim', t);
      expect([res.statusCode, err(res)]).toEqual([403, { code: 'name_reserved', message: "'some_name' is reserved.", hint }]);
    }
    r.h.flags.ro = true;
    expect(err(await r.h.call('POST', '/api/v1/packages/some_name/claim', token)).hint).toBe(hint);
    r.h.flags.broken = true;
    expect(err(await r.h.call('POST', '/api/v1/packages/some_name/claim', token, 'not json')).hint).toBe(hint);
    expect(await r.h.registry.getPackage('some_name')).toBeUndefined();
    expect(await r.h.registry.listOwners('some_name')).toEqual([]);
  });

  test('publishing to a flat package that exists is unchanged: begin accepts the flat file name, and v1 refuses the namespaced one', async () => {
    const r = await rig();
    const a = await r.h.account(9, 'flatty', ['old_pkg']);
    const ok = await r.h.call('POST', '/api/v1/packages/old_pkg/1.0.0/files', a.token, {
      subdir: 'noarch', filename: 'mojo-old_pkg-1.0.0-mojo1.0.0_0.conda', sha256: SHA, size: 100,
    });
    expect(ok.statusCode).toBe(200);
    const wrong = await r.h.call('POST', '/api/v1/packages/old_pkg/1.1.0/files', a.token, {
      subdir: 'noarch', filename: 'mojo-flatty.old_pkg-1.1.0-mojo1.0.0_0.conda', sha256: SHA, size: 100,
    });
    expect([wrong.statusCode, err(wrong).code]).toEqual([400, 'upload_invalid']);
    expect((await r.h.registry.getVersion('old_pkg', '1.0.0'))?.published_by).toBe('flatty');
  });
});
