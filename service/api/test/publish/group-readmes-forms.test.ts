import { parseGroupCommit } from '../../src/publish/group-commit';
import { quarantineKeyFor, readmeUploadIdFor } from '../../src/publish/group-keys';
import { RIGS } from '../group-rig';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { ReadmeScenario, refOf, sha } from './group-readme-scenario';

/**
 * How a commit names its members and their readmes: in any order, in either form, with fields this registry does not know; and
 * which member, group and actor an uploaded readme belongs to. Each test says what it proves.
 */

const text = (s: string) => Buffer.from(s, 'utf8');
const detail = (r: { body: string }) => JSON.parse(r.body).error.message as string;
const notUploaded = (name: string, b: Buffer) => `The upload does not match what was declared: the readme of '${name}' (sha256 ${sha(b)}) was not uploaded.`;

describe.each(RIGS)('the members of a commit in another order than the group\'s: %s', (_label, make) => {
  const NAMES = ['aa', 'bb', 'cc', 'dd', 'ee', 'ff'];
  // aa, dd and ff name their readme by digest, bb and ee send it inline, cc has none: the references are not next to each other.
  const FORM: Record<string, 'ref' | 'inline' | 'none'> = { aa: 'ref', bb: 'inline', cc: 'none', dd: 'ref', ee: 'inline', ff: 'ref' };
  const readmes = Object.fromEntries(NAMES.filter((n) => FORM[n] !== 'none').map((n) => [n, text(`# ${n}\n\nreadme of ${n}\n`)]));

  /** The commit entry of a member in the form it is to be sent. */
  const entry = (s: ReadmeScenario, name: string, form: 'ref' | 'inline' | 'none') => {
    const p = s.pkgs.find((x) => x.name === name)!;
    const readme = form === 'ref' ? { readme: refOf(readmes[name]!) } : form === 'inline' ? { readme: readmes[name]!.toString('utf8') } : {};
    return { name, manifest_sha256: p.manifest, ...readme };
  };
  const mixed = (s: ReadmeScenario, order: string[]) => ({ members: order.map((n) => entry(s, n, FORM[n]!)) });
  const allInline = (s: ReadmeScenario, order: string[]) => ({ members: order.map((n) => entry(s, n, FORM[n] === 'none' ? 'none' : 'inline')) });

  async function run(body: (s: ReadmeScenario) => unknown) {
    const env = new GroupEnv(make());
    const s = await new ReadmeScenario(env, NAMES.map((name) => ({ name })), readmes).ready();
    expect((await s.commit(body(s))).statusCode).toBe(202);
    return { env, s };
  }
  const published = async (env: GroupEnv, s: ReadmeScenario) => {
    expect(await s.runAll()).toEqual(['committed']);
    await new Chain(env).drain();
    expect((await s.header())!.status).toBe('visible');
    const served: Record<string, string> = {};
    for (const n of NAMES) {
      served[`version ${n}`] = (await env.call('GET', `/api/v1/packages/${n}/1.0.0`)).body;
      served[`package ${n}`] = (await env.call('GET', `/api/v1/packages/${n}`)).body;
    }
    const channel = Object.fromEntries(env.objects.keys().filter((k) => !k.startsWith('quarantine/')).map((k) => [k, env.objects.objects.get(k)!.body.toString('base64')]));
    return { served, channel };
  };
  const SCRAMBLED = ['ff', 'cc', 'aa', 'ee', 'dd', 'bb'];
  const OTHER = ['dd', 'bb', 'ff', 'aa', 'cc', 'ee'];

  test('each member keeps its own readme in the stored inputs, whichever position it has in the request', async () => {
    const { env, s } = await run((x) => mixed(x, SCRAMBLED));
    const group = (await env.rig.store.getGroupMembers(s.gid))!.members.map((m) => m.name);
    expect(group).toEqual(NAMES);
    const hash = (await s.header())!.commit_hash!;
    for (const [i, n] of group.entries()) {
      const stored = await env.rig.store.getCommitInput(s.gid, hash, i);
      expect(stored).toEqual({ name: n, manifest_sha256: s.pkgs.find((p) => p.name === n)!.manifest, ...(FORM[n] === 'none' ? {} : { display: { readme: readmes[n]!.toString('utf8') } }) });
    }
  });

  test('the same members named in yet another order are the same request: one hash, and the repeat answers as a repeat', async () => {
    const { env, s } = await run((x) => mixed(x, SCRAMBLED));
    const hash = (await s.header())!.commit_hash;
    const repeat = await s.commit(mixed(s, OTHER));
    expect(repeat.statusCode).toBe(202);
    expect((await s.header())!.commit_hash).toBe(hash);
    expect(env.groupQueue.sent).toHaveLength(1);
    const members = { members: s.pkgs.map((p) => ({ name: p.name, version: p.version, canonical: p.version, subdirs: [] })) };
    expect(parseGroupCommit(members, mixed(s, SCRAMBLED)).hash).toBe(hash);
    expect(parseGroupCommit(members, mixed(s, OTHER)).hash).toBe(hash);
    expect(parseGroupCommit(members, mixed(s, NAMES)).hash).toBe(hash);
  });

  test('a repeat in which one member changed form is another request and is refused', async () => {
    const { s } = await run((x) => mixed(x, SCRAMBLED));
    const flipped = mixed(s, OTHER);
    flipped.members[flipped.members.findIndex((m) => m.name === 'dd')] = entry(s, 'dd', 'inline');
    expect(errorCode(await s.commit(flipped))).toBe('group_commit_refused');
  });

  test('the output of a mixed, reordered commit is byte-identical to that of the same set sent all inline', async () => {
    const a = await run((x) => mixed(x, SCRAMBLED));
    const b = await run((x) => allInline(x, NAMES));
    expect((await a.s.header())!.commit_hash).not.toBe((await b.s.header())!.commit_hash);
    const one = await published(a.env, a.s);
    const two = await published(b.env, b.s);
    expect(one.served).toEqual(two.served);
    expect(Object.keys(two.channel).some((k) => k.endsWith('repodata.json'))).toBe(true);
    expect(one.channel).toEqual(two.channel);
    expect(JSON.parse(one.served['version dd']!).readme).toBe(readmes.dd!.toString('utf8'));
    expect(JSON.parse(one.served['version ee']!).readme).toBe(readmes.ee!.toString('utf8'));
    expect(JSON.parse(one.served['version cc']!)).not.toHaveProperty('readme');
  }, 60_000);
});

describe.each(RIGS)('a readme reference with fields this registry does not know: %s', (_label, make) => {
  const members = { members: [{ name: 'alpha', version: '1.0.0', canonical: '1.0.0', subdirs: [] }] };
  const REF = { sha256: sha('# r'), size: 3 };

  test('the request hash is the same for any order of the properties of a reference and any fields added to it', () => {
    const plain = parseGroupCommit(members, { members: [{ name: 'alpha', readme: { sha256: REF.sha256, size: REF.size } }] });
    const reordered = parseGroupCommit(members, { members: [{ name: 'alpha', readme: { size: REF.size, sha256: REF.sha256 } }] });
    const extra = parseGroupCommit(members, { members: [{ name: 'alpha', readme: { zz: [1], size: REF.size, mime: 'text/markdown', sha256: REF.sha256, note: null } }] });
    expect(reordered.hash).toBe(plain.hash);
    expect(extra.hash).toBe(plain.hash);
    expect(extra.named.map((n) => n.ref)).toEqual([REF]);
    expect(Object.keys(extra.named[0]!.ref)).toEqual(['sha256', 'size']);
  });

  test('create and commit take a reference with extra fields; the stored input and the served readme are those of a plain one', async () => {
    const env = new GroupEnv(make());
    const readmes = { alpha: text('# extra\n') };
    const s = new ReadmeScenario(env, [{ name: 'alpha' }], readmes);
    s.pkgs = [];
    const created = await s.createRaw();
    expect(created.statusCode).toBe(201);
    // Create again with fields added to the reference: the same group, the same answer.
    const extra = s.members().map((m) => ({ ...m, readme: { note: 'x', size: m.readme!.size, sha256: m.readme!.sha256, more: { a: 1 } } }));
    const again = await env.create(s.token, extra);
    expect([200, 201]).toContain(again.statusCode);
    s.created = json(again);
    s.gid = s.created!.group_id;
    expect(s.answerOf('alpha').readme).toEqual({ ...refOf(readmes.alpha), upload_id: expect.any(String), uploaded: false, put_url: expect.any(String), put_headers: expect.any(Object), expires_at: expect.any(String) });
    expect(Object.keys(s.answerOf('alpha').readme)).not.toContain('note');
    await s.upload();
    await s.uploadReadmes();
    const body = { members: [{ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, readme: { more: true, size: refOf(readmes.alpha).size, sha256: refOf(readmes.alpha).sha256 } }] };
    expect((await s.commit(body)).statusCode).toBe(202);
    expect(await env.rig.store.getCommitInput(s.gid, (await s.header())!.commit_hash!, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { readme: '# extra\n' } });
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202); // the plain form is the same request
    expect(env.groupQueue.sent).toHaveLength(1);
  });
});

describe.each(RIGS)('who an uploaded readme belongs to: %s', (_label, make) => {
  const SAME = text('# the same text in many places\n');
  let env: GroupEnv;
  beforeEach(() => {
    env = new GroupEnv(make());
  });
  const keyOf = (gid: string, name: string, canonical: string, b: Buffer) => quarantineKeyFor(readmeUploadIdFor(gid, { name, canonical }, sha(b)), 'README.md');

  test('identical bytes in two members: a commit that names a member\'s readme where only the other member uploaded it is "was not uploaded" for that member', async () => {
    const s = new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: SAME, beta: SAME });
    await s.create();
    await s.upload();
    await s.uploadReadmes(['alpha']);
    expect(s.answerOf('alpha').readme.upload_id).not.toBe(s.answerOf('beta').readme.upload_id);
    const r = await s.commit(s.objectsBody());
    expect(errorCode(r)).toBe('upload_invalid');
    expect(detail(r)).toBe(notUploaded('beta', SAME));
    expect(r.body).not.toContain('the same text');
    expect((await s.header())!.status).toBe('open');
    // The create answers the same: beta's object is not there, whatever alpha holds.
    const again = json(await env.create(s.token, s.members()));
    expect(again.members.find((m: { name: string }) => m.name === 'beta').readme.uploaded).toBe(false);
    expect(again.members.find((m: { name: string }) => m.name === 'alpha').readme.uploaded).toBe(true);
    await s.uploadReadmes(['beta']);
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
  });

  test('identical bytes in two groups: the other group\'s upload is not this group\'s', async () => {
    const one = new ReadmeScenario(env, [{ name: 'alpha' }], { alpha: SAME });
    await one.create();
    await one.upload();
    await one.uploadReadmes();
    // Another set (alpha and gamma): another group, and its alpha has the same text.
    const two = new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'gamma' }], { alpha: SAME, gamma: text('# gamma\n') });
    await two.create();
    expect(two.gid).not.toBe(one.gid);
    expect(env.objects.keys().filter((k) => k.endsWith('/README.md'))).toEqual([keyOf(one.gid, 'alpha', '1.0.0', SAME)]);
    await two.upload();
    await two.uploadReadmes(['gamma']);
    expect(two.answerOf('alpha').readme.uploaded).toBe(false);
    const r = await two.commit(two.objectsBody());
    expect(errorCode(r)).toBe('upload_invalid');
    expect(detail(r)).toBe(notUploaded('alpha', SAME));
    expect((await two.header())!.status).toBe('open');
  });

  test('identical bytes from two actors: a stranger cannot commit on the group, and after the first group ends a co-owner\'s group for the same package and version has an object of its own', async () => {
    const mine = new ReadmeScenario(env, [{ name: 'alpha' }], { alpha: SAME }, true, 1);
    await mine.create();
    await mine.upload();
    await mine.uploadReadmes();
    const theirs = new ReadmeScenario(env, [{ name: 'alpha' }], { alpha: SAME }, true, 2);
    const stranger = await new ReadmeScenario(env, [{ name: 'zeta' }], { zeta: SAME }, true, 3).createRaw(); // an account that owns none of the group's packages
    expect(stranger.statusCode).toBe(201);
    const strangerToken = await env.token(3, ['zeta']);
    const refused = await env.call('POST', `/api/v1/groups/${mine.gid}/commit`, strangerToken, mine.objectsBody());
    expect(refused.statusCode).toBe(404);
    expect(errorCode(refused)).toBe('group_not_found');
    expect(refused.body).not.toContain('the same text');
    expect((await mine.header())!.status).toBe('open');

    expect((await env.abort(mine.token, mine.gid)).statusCode).toBe(200);
    await theirs.create();
    expect(theirs.gid).not.toBe(mine.gid);
    expect(theirs.answerOf('alpha').readme.uploaded).toBe(false);
    await theirs.upload();
    const r = await theirs.commit(theirs.objectsBody());
    expect(errorCode(r)).toBe('upload_invalid');
    expect(detail(r)).toBe(notUploaded('alpha', SAME));
    expect(r.body).not.toContain('the same text');
  });

  test('the object of a readme is named by the version: a group of 1.0.0 and one of 1.0.1 hold their own, and a spelling that is not the canonical version is invalid_version', async () => {
    const old = new ReadmeScenario(env, [{ name: 'alpha', version: '1.0.0' }], { alpha: SAME });
    await old.create();
    const next = new ReadmeScenario(env, [{ name: 'alpha', version: '1.0.1' }], { alpha: SAME });
    await next.create();
    expect(old.gid).not.toBe(next.gid);
    expect(old.answerOf('alpha').readme.upload_id).not.toBe(next.answerOf('alpha').readme.upload_id);
    for (const spelling of ['1.0', '01.0.0', 'v1.0.0', '1.0.0.0', '1.0.0 ']) {
      const members = old.members().map((m) => ({ ...m, version: spelling }));
      const r = await env.create(old.token, members);
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_version');
    }
  });
});
