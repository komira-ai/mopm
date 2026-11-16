import { createHash } from 'node:crypto';
import type { HttpRequest, HttpResponse } from '../../src/http/router';
import { condaNameOf } from '../../src/names';
import { groupAudit } from '../../src/publish/group-lifecycle';
import { madeVisible } from '../../src/publish/group-chain';
import type { PublishRecord } from '../../src/publish/types';
import type { VersionRecord } from '../../src/types';
import { orgMembership } from '../auth-helpers';
import { ALICE, BOB, CAROL, DAVE, ERIN, NEW_ORG, OCTO, type World } from './replay-v2-world';
import type { Recipe } from './replay-v2';

// One recipe per case of tests/contract/api-v2: the state the case describes, the token it sends, and the few rewrites of the
// request a fixture cannot carry (a real id, a signed CI token). A case file shows the answer of a registry that holds some
// state; a recipe builds that state on the fixed one of replay-v2-world.ts. Cases are keyed by name.

const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const iso = (w: World) => w.clock.now().toISOString();
const minutes = (n: number) => n * 60_000;

const call = (w: World, method: string, path: string, bearer?: string, body?: unknown): Promise<HttpResponse> =>
  w.send({
    method,
    path: `/api/v2${path}`,
    query: {},
    headers: bearer ? { authorization: bearer } : {},
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });

const asJson = (r: HttpResponse) => JSON.parse(r.body) as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

// ---- organization registration and members -------------------------------------------------------------------------------

/** CAROL's user namespace: the fixed world gives her none (she is only a member of `komira-ai`). */
const carolNamespace = async (w: World): Promise<void> => {
  await w.namespaces.createNamespace({ namespace: 'carol', kind: 'user', github_id: CAROL, created_at: iso(w) });
};

/**
 * A recipe for `POST /namespaces/poll`: DAVE started the registration of `acme-labs` (his own `createNamespace` call makes the
 * device row), then GitHub answers the poll as `script` says. The default script approves with a token; the token's account is
 * `approvedBy` (DAVE) and its membership of the organization has `role`. `minutes` moves the clock after the start.
 */
function registrationPoll(o: { script?: Array<Record<string, unknown>>; role?: string; approvedBy?: number; minutes?: number }): Recipe {
  return {
    bearer: session(DAVE),
    setup: async (w) => {
      if (o.script) w.device.state.pollScript = o.script;
      w.device.state.user = { id: o.approvedBy ?? DAVE, login: 'dave', two_factor_authentication: true };
      w.device.state.memberships['acme-labs'] = { body: orgMembership({ id: NEW_ORG, login: 'acme-labs' }, o.role ?? 'admin', 'active', o.approvedBy ?? DAVE) };
      const started = await call(w, 'POST', '/namespaces', await w.session(DAVE), { namespace: 'acme-labs' });
      if (started.statusCode !== 202) throw new Error(`start: ${started.statusCode} ${started.body}`);
      w.ids.device = asJson(started).device_code as string;
      if (o.minutes) w.clock.advance(minutes(o.minutes));
    },
    prepare: async (req, w) => ({ ...req, body: JSON.stringify({ device_code: w.ids.device }) }),
  };
}

// ---- tokens of the fixed accounts ------------------------------------------------------------------------------------------

const session = (id: number) => (w: World) => w.session(id);
const stale = (id: number) => (w: World) => w.session(id, false);
const apiToken = (id: number, packages: string[], scopes: Array<'publish' | 'yank' | 'stage'> = ['publish']) => (w: World) => w.api(id, packages, scopes);

// ---- state -----------------------------------------------------------------------------------------------------------------

const BUILD = 'mojo1.0.0_0';
const fileName = (full: string, version: string) => `${condaNameOf(full)}-${version}-${BUILD}.conda`;
/** The facts a publisher declares for the one file of a version. */
export const fileFacts = (full: string, version: string, over: Record<string, unknown> = {}) => ({
  subdir: 'noarch',
  filename: fileName(full, version),
  sha256: sha(`${full} ${version}`),
  size: 4096,
  ...over,
});

/** A package that has a published version, as a validated publish leaves it. `over` replaces any field of the row. */
export async function addVersion(w: World, full: string, version: string, over: Partial<VersionRecord> = {}): Promise<void> {
  if (!(await w.h.registry.getPackage(full))) await w.makePackage(full, 'active', { created_at: '2026-11-01T08:00:00.000Z' });
  const f = fileFacts(full, version);
  await w.h.registry.createVersion(
    {
      name: full,
      version,
      canonical: version,
      build: BUILD,
      state: 'published',
      published_at: '2026-11-10T08:30:00.000Z',
      published_by: 'alice',
      requires_mojo: '==1.0.0',
      deps: [],
      native: [],
      files: [{ subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.size, url: `https://conda.mopm.dev/${full.split('/')[0]}/noarch/${f.filename}` }],
      manifest_sha256: sha(`manifest ${full} ${version}`),
      rev: 0,
      ...over,
    },
    { name: full, ts: iso(w), id: `a_${full}_${version}`, actor: 'u:1001', action: 'publish_begin', version },
  );
}

/** Begin the upload of the one file of a version, put its bytes where the URL points, and answer the upload id. */
async function begun(w: World, bearer: string, full: string, version: string, subdir = 'noarch'): Promise<string> {
  const r = await call(w, 'POST', `/packages/${full}/${version}/files`, bearer, fileFacts(full, version, { subdir }));
  if (r.statusCode !== 200) throw new Error(`begin: ${r.statusCode} ${r.body}`);
  const id = asJson(r).upload_id as string;
  w.ids.uploads.push(id);
  const up = (await w.h.publishes.getUpload(id))!;
  await w.h.objects.put(up.key, Buffer.alloc(4096), { contentType: 'application/octet-stream' });
  return id;
}

/** A single publish that was committed and is `pending`; answers its id. */
async function committed(w: World, bearer: string, full: string, version: string): Promise<string> {
  const id = await begun(w, bearer, full, version);
  const r = await call(w, 'POST', `/packages/${full}/${version}/publish`, bearer, { upload_ids: [id] });
  if (r.statusCode !== 202) throw new Error(`commit: ${r.statusCode} ${r.body}`);
  w.ids.publish = asJson(r).publish_id as string;
  return w.ids.publish;
}

const setPublish = (w: World, id: string, over: Partial<PublishRecord>) => w.h.publishes.updatePublish(id, (cur) => ({ ...cur, ...over }));

/** A recipe whose request names the publish it asks about: the one made by `committed`, rejected or in `status`. */
const publishWith = (over: Partial<PublishRecord>, full = 'alice/json'): Recipe => ({
  bearer: apiToken(ALICE, [full]),
  prepare: async (req, w) => ({ ...req, path: req.path.replace(/[^/]+$/, w.ids.publish!) }),
  setup: async (w) => {
    await w.makePackage(full);
    const id = await committed(w, await w.api(ALICE, [full]), full, '1.0.0');
    await setPublish(w, id, over);
  },
});

/** The members of a group of two packages in two namespaces, declared as a publisher would. */
const MEMBERS = [
  { name: 'komira-ai/yaml', version: '2.1.0', files: [fileFacts('komira-ai/yaml', '2.1.0')] },
  { name: 'alice/json', version: '1.0.0', files: [fileFacts('alice/json', '1.0.0')] },
];
const GROUP_PACKAGES = ['alice/json', 'komira-ai/yaml'];

/** The fixed state of a group: both packages exist, and ALICE holds a token that stages and publishes them. */
async function groupWorld(w: World): Promise<string> {
  for (const p of GROUP_PACKAGES) await w.makePackage(p);
  return w.api(ALICE, GROUP_PACKAGES);
}
const groupBearer = (w: World) => w.api(ALICE, GROUP_PACKAGES);

/** The group of MEMBERS, created over HTTP: answers the creation body. */
async function openGroup(w: World, extra: Record<string, unknown> = {}): Promise<Record<string, any>> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const r = await call(w, 'POST', '/groups', await groupWorld(w), { members: MEMBERS, ...extra });
  if (r.statusCode !== 201) throw new Error(`create group: ${r.statusCode} ${r.body}`);
  return asJson(r);
}

/** Put the bytes of every file of a created group where its upload URLs point. */
async function uploadAll(w: World, created: Record<string, any>): Promise<void> { // eslint-disable-line @typescript-eslint/no-explicit-any
  for (const m of created.members) for (const f of m.files) await w.h.objects.put(`quarantine/${f.upload_id}/${f.filename}`, Buffer.alloc(4096), { contentType: 'application/octet-stream' });
}

/** The commit request of the group of MEMBERS: the archive manifest of one member is stated, the other's is left to the registry. */
export const COMMIT_BODY = { members: [{ name: 'alice/json', manifest_sha256: 'c'.repeat(64) }, { name: 'komira-ai/yaml' }] };

/** A group that was committed over HTTP (validating), with the files in storage. */
async function validatingGroup(w: World): Promise<string> {
  const created = await openGroup(w);
  await uploadAll(w, created);
  const r = await call(w, 'POST', `/groups/${created.group_id}/commit`, await groupBearer(w), COMMIT_BODY);
  if (r.statusCode !== 202) throw new Error(`commit group: ${r.statusCode} ${r.body}`);
  return created.group_id as string;
}

/**
 * A group the validator and the index writer finished: committed, every member `published`, the group `visible`. The archives are
 * not opened here (the validator reads flat names); the store transitions are the ones its chain makes.
 */
async function visibleGroup(w: World): Promise<string> {
  const gid = await validatingGroup(w);
  const reg = w.h.registry;
  const head = (await reg.getGroup(gid))!;
  const members = (await reg.getGroupMembers(gid))!;
  const at = iso(w);
  const out = await reg.commitGroup(gid, { rev: head.rev, writeOrder: members.members.map((_m, i) => i), now: at, audit: groupAudit(gid, `a_${gid}_commit_1`, 'group_commit', at, 'system') });
  if (out.outcome !== 'committed') throw new Error(`commit marker: ${out.outcome}`);
  for (const [i, m] of members.members.entries()) {
    const f = fileFacts(m.name, m.version);
    const audit = (action: string) => ({ name: m.name, ts: at, id: `a_${gid}_${i}_${action}`, actor: 'system', action, version: m.version });
    await reg.applyGroupEvent(
      m.name,
      m.version,
      {
        type: 'stage',
        group_id: gid,
        attempt: 1,
        fill: {
          version: m.version, build: BUILD, requires_mojo: '==1.0.0', deps: [], native: [], manifest_sha256: sha(`manifest ${m.name}`), published_at: at, published_by: 'alice',
          files: [{ subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.size, url: `https://conda.mopm.dev/${m.name.split('/')[0]}/noarch/${f.filename}` }],
        },
      },
      audit('group_stage'),
    );
    await reg.applyGroupEvent(m.name, m.version, { type: 'group_publish', group_id: gid, attempt: 1, committed_at: at }, audit('group_flip'));
  }
  await reg.updateGroup(gid, (cur) => madeVisible(cur, at));
  return gid;
}

/** The request with these members of its JSON body replaced. */
const withBody = (req: HttpRequest, over: Record<string, unknown>): HttpRequest => ({ ...req, body: JSON.stringify({ ...JSON.parse(req.body ?? '{}'), ...over }) });

/** Start a device login through the router and answer the code to poll with. */
async function startedLogin(w: World): Promise<string> {
  const r = await call(w, 'POST', '/auth/device', undefined, { client: 'mopm 0.1.0' });
  return asJson(r).device_code as string;
}
const polling = (script: Array<Record<string, unknown>>, wait = 0): Recipe => ({
  setup: async (w) => {
    w.device.state.pollScript = script;
  },
  prepare: async (req, w) => {
    const code = await startedLogin(w);
    w.clock.advance(wait);
    return withBody(req, { device_code: code });
  },
});

/** The commit names the uploads the setup began. */
const namingUploads: Recipe['prepare'] = async (req, w) => withBody(req, { upload_ids: w.ids.uploads });

const signedBody = (over: Record<string, unknown> = {}) => async (req: HttpRequest, w: World) => withBody(req, { jwt: w.jwt(over) });
/** Keys every answer of `getHealth` has that the cases do not show: the release and commit the deployment reports. */
const BUILD_KEYS = ['version', 'commit'];

/** A first page of one, then the case's own request continued from its cursor. */
const continueFromFirstPage: Recipe['prepare'] = async (req, w) => {
  const first = JSON.parse((await w.send({ ...req, query: { ...req.query, cursor: undefined, limit: '1' } })).body);
  return { ...req, query: { ...req.query, cursor: first.next_cursor } };
};

/** Packages the search and the reads below look at. */
async function catalogue(w: World): Promise<void> {
  await addVersion(w, 'alice/json', '1.0.0', { published_at: '2026-11-02T09:00:00.000Z' });
  await addVersion(w, 'komira-ai/json', '1.0.0', { published_at: '2026-11-03T10:00:00.000Z' });
  await addVersion(w, 'komira-ai/json', '1.1.0', { published_at: '2026-11-10T08:30:00.000Z' });
  await w.makePackage('komira-ai/jsonschema');
}

/** The additive keys of `getHealth` that most cases leave out; one case shows the implementation and the features. */
const HEALTH_EXTRA = [...BUILD_KEYS, 'impl', 'features'];

/**
 * The recipes by case name. A case with no recipe fails the replay; the ones the handler cannot produce are NOT_PRODUCED_V2 in
 * replay-v2.test.ts, with the reason.
 */
export const RECIPES: Record<string, Recipe> = {
  // ---- tests/contract/api-v2/meta.json
  'prod is up': { world: { stage: 'prod' }, extraKeys: HEALTH_EXTRA },
  'beta in read-only mode': { world: { readOnly: true }, extraKeys: HEALTH_EXTRA },
  'prod is up, names the implementation and lists its features': { world: { stage: 'prod' }, extraKeys: BUILD_KEYS },
  // The case's operation (getHealth) only carries it; the request is a path the API does not have.
  'error route_not_found': { prepare: async (req) => ({ ...req, path: '/api/v2/no_such_operation' }) },

  // ---- tests/contract/api-v2/auth.json
  'start login': {},
  'poll while pending': polling([{ error: 'authorization_pending' }]),
  'poll approved, with the user namespace': polling([{ access_token: 'gho_faketoken', token_type: 'bearer', scope: 'read:user' }]),
  'poll approved by an account whose login another namespace holds': {
    ...polling([{ access_token: 'gho_faketoken', token_type: 'bearer', scope: 'read:user' }]),
    setup: async (w) => {
      w.device.state.user = { id: OCTO, login: 'Alice', two_factor_authentication: true };
    },
  },
  'poll denied': polling([{ error: 'access_denied' }]),
  'poll expired': polling([{ error: 'authorization_pending' }], minutes(11)),
  'exchange a CI identity token': { prepare: signedBody() },
  'exchange a CI identity token for a list of packages': { prepare: signedBody() },
  'exchange a CI identity token for a stage token': { prepare: signedBody() },
  'error device_code_unknown': {},
  'error oidc_token_invalid': {},
  'error oidc_not_trusted': { prepare: signedBody({ repository_id: '999' }) },

  // ---- tests/contract/api-v2/me.json
  'whoami with a user namespace and an organization namespace': {
    bearer: session(ALICE),
    setup: async (w) => {
      await addVersion(w, 'alice/json', '1.0.0');
      await addVersion(w, 'komira-ai/json', '1.0.0');
      await w.makePackage('komira-ai/yaml');
    },
  },
  'whoami of an account whose login another namespace holds': { bearer: session(ERIN) },
  'whoami of an organization member': { bearer: session(CAROL), setup: async (w) => w.makePackage('komira-ai/json') },

  // ---- tests/contract/api-v2/tokens.json
  'create a token for full names': { bearer: session(ALICE) },
  'create a token for all current packages': { bearer: session(ALICE), setup: async (w) => w.makePackage('alice/json') },
  'list tokens never returns a secret': {
    bearer: session(ALICE),
    setup: async (w) => {
      await w.mint('api', { github_id: ALICE, scopes: ['publish'], packages: ['alice/json'] });
      await w.mint('api', { github_id: ALICE, scopes: ['yank'], packages: ['alice/json', 'alice/yaml'], createdAt: '2026-11-14T12:01:00.000Z' });
    },
  },
  'revoke a token': {
    bearer: session(ALICE),
    prepare: async (req, w) => {
      const { id } = await w.mint('api', { github_id: ALICE, scopes: ['publish'], packages: ['alice/json'] });
      return { ...req, path: req.path.replace(/[^/]+$/, id) };
    },
  },
  'error stale_session': { bearer: stale(ALICE) },
  'error token_not_found': { bearer: session(ALICE) },

  // ---- tests/contract/api-v2/namespaces.json
  'start the registration of an organization namespace': { bearer: session(DAVE) },
  'create a namespace outside the grammar': { bearer: session(DAVE) },
  'create a reserved namespace': { bearer: session(DAVE) },
  'create a namespace a user holds': { bearer: session(DAVE) },
  'poll a registration while pending': registrationPoll({ script: [{ error: 'authorization_pending' }] }),
  'poll a registration that was created': registrationPoll({}),
  'poll a registration that was denied': registrationPoll({ script: [{ error: 'access_denied' }] }),
  'poll a registration that expired': registrationPoll({ script: [{ error: 'authorization_pending' }], minutes: 11 }),
  'poll a registration approved by a plain member of the organization': registrationPoll({ role: 'member' }),
  'poll a registration approved by another GitHub account': registrationPoll({ approvedBy: 9999 }),
  'get a user namespace': {},
  'get an organization namespace': {},
  'error invalid_namespace': {},
  'error namespace_not_found': {},
  'error namespace_reserved': {},
  'error namespace_taken': { bearer: session(DAVE) },
  'error not_org_admin': registrationPoll({ role: 'member' }),
  'error github_account_mismatch': registrationPoll({ approvedBy: 9999 }),
  'error not_namespace_member': { bearer: session(ERIN) },
  'error unavailable': registrationPoll({ script: [{ error: 'incorrect_device_code' }] }),
  'list the members of an organization namespace': { bearer: session(ALICE) },
  'list the members as an account that is not one': { bearer: session(ERIN) },
  'list the members of a user namespace': { bearer: session(ALICE) },
  'add a member': { bearer: session(ALICE) },
  'make a member an owner': { bearer: session(ALICE), setup: carolNamespace },
  'set the role a member already has': { bearer: session(ALICE), setup: carolNamespace },
  'set a member as a member of the namespace': { bearer: session(CAROL) },
  'set a member as an account that is not one': { bearer: session(BOB) },
  'demote the only owner': { bearer: session(ALICE) },
  'set an account that has no mopm username': { bearer: session(ALICE) },
  'set an organization namespace as a user': { bearer: session(ALICE) },
  'remove a member': { bearer: session(ALICE), setup: carolNamespace },
  'an owner removes themselves while another owner remains': {
    bearer: session(ALICE),
    setup: async (w) => void (await w.namespaces.setMember({ namespace: 'komira-ai', github_id: CAROL, role: 'owner', added_by: ALICE, added_at: iso(w) })),
  },
  'remove an account that is not a member': { bearer: session(ALICE) },
  'remove the only owner': { bearer: session(ALICE) },
  'remove a member as a member of the namespace': { bearer: session(CAROL), setup: carolNamespace },
  'error not_namespace_owner': { bearer: session(CAROL) },
  'error last_owner': { bearer: session(ALICE) },
  'error member_not_found': { bearer: session(ALICE) },
  'error user_not_found': { bearer: session(ALICE) },

  // ---- tests/contract/api-v2/packages.json
  'search by name prefix in every namespace': { setup: catalogue },
  'search one namespace': { setup: catalogue },
  'search one namespace by name prefix': { setup: catalogue },
  'search, first page of one': { setup: catalogue },
  'search, last page, a package with no version': { setup: catalogue, prepare: continueFromFirstPage },
  'package info': {
    setup: async (w) => {
      await addVersion(w, 'komira-ai/json', '1.0.0', { published_at: '2026-11-03T10:00:00.000Z' });
      await addVersion(w, 'komira-ai/json', '1.1.0', { published_at: '2026-11-10T08:30:00.000Z' });
      await w.h.registry.updateVersion('komira-ai/json', '1.0.0', { type: 'yank', reason: 'wrong license text' }, { name: 'komira-ai/json', ts: iso(w), id: 'a_yank', actor: 'u:1001', action: 'yank', version: '1.0.0' });
    },
  },
  'package info with homepage, keywords and the latest readme': {
    setup: async (w) => {
      await w.makePackage('alice/json', 'active', {
        created_at: '2026-11-01T08:00:00.000Z',
        description: 'A JSON parser for Mojo.',
        license: 'Apache-2.0',
        repository: 'https://github.com/alice/json',
        homepage: 'https://alice.example/json',
        keywords: ['json', 'parser'],
      });
      await addVersion(w, 'alice/json', '0.3.0', {
        published_at: '2026-11-05T15:00:00.000Z',
        description: 'A JSON parser for Mojo.',
        license: 'Apache-2.0',
        repository: 'https://github.com/alice/json',
        homepage: 'https://alice.example/json',
        keywords: ['json', 'parser'],
        readme: '# json\n\nParse JSON.\n',
      });
    },
  },
  'package that has no version yet': { setup: async (w) => w.makePackage('alice/json') },
  'create a package': { bearer: session(ALICE) },
  'create a package that exists': { bearer: apiToken(ALICE, ['komira-ai/json']), setup: async (w) => void (await w.makePackage('komira-ai/json')) },
  'list versions': { setup: catalogue },
  'version detail': { setup: catalogue },
  'version detail with the mopm.toml display fields': {
    setup: async (w) => {
      await addVersion(w, 'komira-ai/json', '1.1.0', {
        description: 'A JSON parser for Mojo.',
        license: 'Apache-2.0',
        repository: 'https://github.com/komira-ai/json',
        homepage: 'https://komira.example/json',
        keywords: ['json', 'parser'],
        readme: '# json\n\nParse JSON.\n',
      });
    },
  },
  'version detail with a source_commit': { setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { source_commit: '9f2c4b7e1d0a83c5b6e7f8091a2b3c4d5e6f7081' }) },
  'version detail of a version a group published': { setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { group_id: 'grp_598a7e4a7e56109c58051a434f3be338' }) },
  'yanked version keeps its files and says why': { setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { state: 'yanked', yank_reason: 'crashes on empty input' }) },
  'tombstoned version has no url': {
    setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { state: 'tombstoned', tombstone: { reason_code: 'malware', date: '2026-11-12' } }),
  },
  'version detail published through a CI identity': {
    setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { provenance: { kind: 'oidc', repository: 'komira-ai/json', workflow_ref: 'komira-ai/json/.github/workflows/release.yml@refs/heads/main' } }),
  },

  // ---- tests/contract/api-v2/publish.json
  'begin an upload': { bearer: apiToken(ALICE, ['alice/json']), setup: async (w) => void (await w.makePackage('alice/json')) },
  'commit': {
    bearer: apiToken(ALICE, ['alice/json']),
    prepare: namingUploads,
    setup: async (w) => {
      await w.makePackage('alice/json');
      await begun(w, await w.api(ALICE, ['alice/json']), 'alice/json', '1.0.0');
    },
  },
  'commit with the display fields and a source_commit': {
    bearer: apiToken(ALICE, ['alice/json']),
    prepare: namingUploads,
    setup: async (w) => {
      await w.makePackage('alice/json');
      await begun(w, await w.api(ALICE, ['alice/json']), 'alice/json', '1.0.0');
    },
  },
  'status pending': publishWith({}),
  'status validating': publishWith({ status: 'validating' }),
  'status indexing': publishWith({ status: 'indexing' }),
  'status published': publishWith({ status: 'published' }),
  'status published with a warning': publishWith({ status: 'published', warnings: ["native dependency 'zlib-ng' is not in the copy of conda-forge's package names"] }),
  'rejected: archive_invalid': publishWith({ status: 'rejected', rejection_code: 'archive_invalid', message: 'The archive is not a valid .conda file.' }),
  'rejected: path_not_allowed': publishWith({ status: 'rejected', rejection_code: 'path_not_allowed', message: "The archive holds 'etc/passwd', outside the allowed paths." }),
  'rejected: limit_exceeded': publishWith({ status: 'rejected', rejection_code: 'limit_exceeded', message: 'The archive expands to more than the limit.' }),
  'rejected: manifest_invalid': publishWith({ status: 'rejected', rejection_code: 'manifest_invalid', message: 'The manifest in the archive names another package.' }),
  'rejected: filename_mismatch': publishWith({ status: 'rejected', rejection_code: 'filename_mismatch', message: 'The file name does not match the package inside.' }),
  'rejected: sha256_mismatch': publishWith({ status: 'rejected', rejection_code: 'sha256_mismatch', message: 'The sha256 of the archive differs from the one declared.' }),
  'rejected: dependency_not_allowed': publishWith({ status: 'rejected', rejection_code: 'dependency_not_allowed', message: "The dependency 'flat_pkg' is not a full name." }),
  'yank': { bearer: apiToken(ALICE, ['komira-ai/json'], ['yank']), setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0') },
  'yank with a publish token': { bearer: apiToken(ALICE, ['komira-ai/json']), setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0') },
  'unyank': { bearer: apiToken(ALICE, ['komira-ai/json'], ['yank']), setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0', { state: 'yanked', yank_reason: 'crashes on empty input' }) },
  'create a group': { bearer: groupBearer, setup: async (w) => void (await groupWorld(w)) },
  'create the same group again while it is open': { bearer: groupBearer, setup: async (w) => void (await openGroup(w)) },
  'create a group, declaring the readme of a member as an object': { bearer: groupBearer, setup: async (w) => void (await groupWorld(w)) },
  'group status open': { bearer: groupBearer, setup: async (w) => void (await openGroup(w)) },
  'group status open, with a file in storage': {
    bearer: groupBearer,
    setup: async (w) => {
      const created = await openGroup(w);
      const m = created.members.find((x: { name: string }) => x.name === 'alice/json');
      const f = m.files[0];
      await w.h.objects.put(`quarantine/${f.upload_id}/${f.filename}`, Buffer.alloc(4096), { contentType: 'application/octet-stream' });
    },
  },
  'group status visible': { bearer: groupBearer, setup: async (w) => void (await visibleGroup(w)) },
  'group status rejected, with why': {
    bearer: groupBearer,
    setup: async (w) => {
      const gid = await validatingGroup(w);
      await w.h.registry.updateGroup(gid, (cur) => ({ ...cur, status: 'rejected', failure: { code: 'filename_mismatch', message: 'The file name does not match the package inside.', member: 'alice/json' } }));
    },
  },
  'group status yanking': {
    bearer: groupBearer,
    setup: async (w) => {
      const gid = await visibleGroup(w);
      const r = await call(w, 'PUT', `/groups/${gid}/yank`, await groupBearer(w), { yanked: true, reason: 'the release is broken' });
      if (r.statusCode !== 202) throw new Error(`yank group: ${r.statusCode} ${r.body}`);
    },
  },
  'abort a group': { bearer: groupBearer, setup: async (w) => void (await openGroup(w)) },
  'commit a group': {
    bearer: groupBearer,
    setup: async (w) => {
      await uploadAll(w, await openGroup(w));
    },
  },
  'commit a group with the source_commit of a member': {
    bearer: groupBearer,
    setup: async (w) => {
      await uploadAll(w, await openGroup(w));
    },
  },
  'commit a group that had already committed': { bearer: groupBearer, setup: async (w) => void (await visibleGroup(w)) },
  'yank a group': { bearer: groupBearer, setup: async (w) => void (await visibleGroup(w)) },
  'unyank a group that was never yanked': { bearer: groupBearer, setup: async (w) => void (await visibleGroup(w)) },

  // ---- tests/contract/api-v2/errors.json (those not placed above)
  'error invalid_request': {},
  'error invalid_name': {},
  'error invalid_version': {},
  'error upload_invalid': { bearer: apiToken(ALICE, ['komira-ai/json']), setup: async (w) => void (await w.makePackage('komira-ai/json')) },
  'error token_missing': {},
  'error token_unknown': { bearer: async () => 'Bearer mopm_unknown2unknown2unknown2unknown2' },
  'error token_expired': {
    bearer: async (w) => {
      const t = (await w.mint('session', { github_id: ALICE, ttlMs: minutes(1) })).bearer;
      w.clock.advance(minutes(5));
      return t;
    },
  },
  'error token_revoked': {
    bearer: async (w) => {
      const t = await w.mint('api', { github_id: ALICE, scopes: ['publish'], packages: ['alice/json'] });
      const r = await call(w, 'DELETE', `/me/tokens/${t.id}`, await w.session(ALICE));
      if (r.statusCode !== 204) throw new Error(`revoke: ${r.statusCode} ${r.body}`);
      return t.bearer;
    },
  },
  'error scope_missing': { bearer: apiToken(ALICE, ['komira-ai/json'], ['stage']), setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0') },
  'error not_owner': {
    bearer: async (w) => (await w.mint('oidc', { scopes: ['publish'], packages: ['komira-ai/json'], version: '1.0.0' })).bearer,
    setup: async (w) => void (await w.makePackage('komira-ai/json')),
  },
  'error name_reserved: a module of the Mojo standard library': { bearer: session(ALICE) },
  'error name_reserved: a keyword': { bearer: session(ALICE) },
  'error name_reserved: a name of the registry': { bearer: session(ALICE) },
  // 9,999,995,000 of the 10,000,000,000 bytes a package may hold are taken, so 5,000 are left.
  'error limit_exceeded': {
    bearer: apiToken(ALICE, ['alice/json']),
    setup: (w) => addVersion(w, 'alice/json', '0.9.0', { files: [{ subdir: 'noarch', filename: fileName('alice/json', '0.9.0'), sha256: sha('big'), size: 9_999_995_000 }] }),
  },
  'error package_not_found': {},
  'error version_not_found': { setup: async (w) => void (await w.makePackage('komira-ai/json')) },
  'error publish_not_found': { bearer: apiToken(ALICE, ['alice/json']) },
  'error group_not_found': { bearer: groupBearer },
  'error version_exists': { bearer: apiToken(ALICE, ['komira-ai/json']), setup: (w) => addVersion(w, 'komira-ai/json', '1.0.0') },
  // The first upload is taken by a publish of its own; a second commit that names it with another file is a different publish.
  'error upload_used': {
    bearer: apiToken(ALICE, ['alice/json']),
    prepare: namingUploads,
    setup: async (w) => {
      await w.makePackage('alice/json');
      const t = await w.api(ALICE, ['alice/json']);
      const first = await begun(w, t, 'alice/json', '1.0.0');
      await begun(w, t, 'alice/json', '1.0.0', 'linux-64');
      const r = await call(w, 'POST', '/packages/alice/json/1.0.0/publish', t, { upload_ids: [first] });
      if (r.statusCode !== 202) throw new Error(`commit: ${r.statusCode} ${r.body}`);
    },
  },
  'error group_not_open': { bearer: groupBearer, setup: async (w) => void (await validatingGroup(w)) },
  // CAROL, a member of komira-ai, holds the number of komira-ai/yaml 2.1.0 in a group of her own.
  'error group_conflict': {
    bearer: groupBearer,
    setup: async (w) => {
      await groupWorld(w);
      const r = await call(w, 'POST', '/groups', await w.api(CAROL, ['komira-ai/yaml']), { members: [MEMBERS[0]] });
      if (r.statusCode !== 201) throw new Error(`carol's group: ${r.statusCode} ${r.body}`);
    },
  },
  'error group_conflict, overlap refused': { bearer: groupBearer, setup: async (w) => void (await openGroup(w)) },
  'error group_commit_refused': {
    bearer: groupBearer,
    setup: async (w) => {
      const created = await openGroup(w);
      await call(w, 'DELETE', `/groups/${created.group_id}`, await groupBearer(w));
    },
  },
  'error group_not_settled': { bearer: groupBearer, setup: async (w) => void (await validatingGroup(w)) },
  'error invalid_transition': { bearer: apiToken(ALICE, ['komira-ai/json'], ['yank']), setup: (w) => addVersion(w, 'komira-ai/json', '1.1.0') },
  'error payload_too_large': { bearer: apiToken(ALICE, ['alice/json']), setup: async (w) => void (await w.makePackage('alice/json')) },
  'error rate_limited': {
    bearer: session(ALICE),
    setup: async (w) => {
      w.h.flags.claimLimits.set(`u:${ALICE}`, 1);
      const r = await call(w, 'PUT', '/packages/alice/first', await w.session(ALICE));
      if (r.statusCode !== 201) throw new Error(`first create: ${r.statusCode} ${r.body}`);
    },
  },
  'error internal_error': { failingStore: true },
  'error read_only_mode': {
    bearer: apiToken(ALICE, ['alice/json']),
    setup: async (w) => {
      await w.makePackage('alice/json');
      w.h.flags.ro = true;
    },
  },
};
