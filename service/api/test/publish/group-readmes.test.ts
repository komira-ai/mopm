import type { HttpResponse } from '../../src/http/router';
import { commitRequestHash } from '../../src/group-store';
import { parseGroupCommit } from '../../src/publish/group-commit';
import { readmeUploadIdFor } from '../../src/publish/group-keys';
import { RIGS, memoryRig, type Rig } from '../group-rig';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { ReadmeScenario, refOf, sha } from './group-readme-scenario';

/**
 * A member's readme as an uploaded object: declared by digest and size at create, uploaded through the presigned PUT of the
 * answer, named again at commit, which reads it and goes on exactly as if the text had been in the request. Each test says
 * what it proves.
 */

const text = (s: string) => Buffer.from(s, 'utf8');
const detail = (r: HttpResponse) => json(r).error.message as string;

/** Run the validator job and the chain behind it until the group is visible. */
async function publish(s: ReadmeScenario): Promise<void> {
  expect(await s.runAll()).toEqual(['committed']);
  await new Chain(s.env).drain();
  expect((await s.header())!.status).toBe('visible');
}

describe('GET /health', () => {
  test('lists the optional features this registry serves', async () => {
    const env = new GroupEnv(memoryRig());
    const r = await env.call('GET', '/api/v1/health');
    expect(json(r).features).toEqual(['group_readme_objects']);
  });
});

describe('a group whose readmes pass the size of a request', () => {
  test('is created with readme refs, uploaded, committed with a small body, validated and served with every readme', async () => {
    const env = new GroupEnv(memoryRig());
    const n = 110;
    const specs = Array.from({ length: n }, (_, i) => ({ name: `rm${String(i).padStart(3, '0')}` }));
    const readmes: Record<string, Buffer> = {};
    for (const [i, sp] of specs.entries()) readmes[sp.name] = text(`# ${sp.name}\n`.padEnd((60 + (i % 5)) * 1024 - 1, 'x') + '\n');
    const total = Object.values(readmes).reduce((a, b) => a + b.length, 0);
    expect(total).toBeGreaterThan(6 * 1024 * 1024);
    for (const b of Object.values(readmes)) {
      expect(b.length).toBeGreaterThanOrEqual(60 * 1024);
      expect(b.length).toBeLessThanOrEqual(64 * 1024);
    }

    const s = await new ReadmeScenario(env, specs, readmes).ready();
    const body = JSON.stringify(s.objectsBody());
    expect(Buffer.byteLength(body)).toBeLessThan(64 * 1024);
    const r = await s.commit(body);
    expect(r.statusCode).toBe(202);
    await publish(s);

    for (const sp of specs) {
      const v = json(await env.call('GET', `/api/v1/packages/${sp.name}/1.0.0`));
      expect(v.readme).toBe(readmes[sp.name]!.toString('utf8'));
      expect(json(await env.call('GET', `/api/v1/packages/${sp.name}`)).readme).toBe(readmes[sp.name]!.toString('utf8'));
    }
  }, 180_000);
});

describe.each(RIGS)('commit with readme objects: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const two = (declare = true) => new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: text('# alpha\n'), beta: text('# beta\n') }, declare);

  describe('create', () => {
    test('a member that declared a readme gets an upload pinned to its digest and size; once the object is stored it is uploaded', async () => {
      const s = await two().create();
      const a = s.answerOf('alpha');
      const ref = refOf(s.readmes.alpha!);
      expect(a.readme).toMatchObject({ ...ref, uploaded: false, upload_id: readmeUploadIdFor(s.gid, { name: 'alpha', canonical: '1.0.0' }, ref.sha256) });
      expect(a.readme.upload_id).toMatch(/^upl_r[0-9a-f]{31}$/);
      expect(a.readme.put_headers).toEqual({ 'content-length': String(ref.size), 'x-amz-checksum-sha256': Buffer.from(ref.sha256, 'hex').toString('base64') });
      expect(a.readme.put_url).toContain(s.readmeKey('alpha'));
      expect(typeof a.readme.expires_at).toBe('string');
      await s.uploadReadmes(['alpha']);
      const again = json(await env.create(s.token, s.members()));
      const got = again.members.find((m: { name: string }) => m.name === 'alpha');
      expect(got.readme).toEqual({ ...ref, upload_id: a.readme.upload_id, uploaded: true });
      expect(again.members.find((m: { name: string }) => m.name === 'beta').readme.uploaded).toBe(false);
    });

    test('a readme object already stored at another size is not taken as uploaded: the answer gives an upload pinned to the declared size', async () => {
      const first = await two().create();
      const ref = refOf(first.readmes.alpha!);
      await env.objects.put(first.readmeKey('alpha'), first.readmes.alpha!.subarray(0, ref.size - 1), { contentType: 'application/octet-stream' });
      const again = json(await env.create(first.token, first.members()));
      const got = again.members.find((m: { name: string }) => m.name === 'alpha');
      expect(got.readme).toMatchObject({ ...ref, uploaded: false, upload_id: first.answerOf('alpha').readme.upload_id });
      expect(got.readme.put_headers).toEqual({ 'content-length': String(ref.size), 'x-amz-checksum-sha256': Buffer.from(ref.sha256, 'hex').toString('base64') });
      expect(got.readme.put_url).toContain(first.readmeKey('alpha'));
    });

    test('a member that declared none has no readme in its answer, and no upload record is written for a readme', async () => {
      const s = await new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: text('# alpha\n') }).create();
      expect(s.answerOf('beta')).not.toHaveProperty('readme');
      expect(await env.publishes.getUpload(s.answerOf('alpha').readme.upload_id)).toBeUndefined();
    });

    test('the group id is the same with and without readme declarations', async () => {
      const plain = await two(false).create();
      const withRefs = json(await env.create(plain.token, plain.members().map((m) => ({ ...m, readme: refOf(plain.readmes[m.name]!) }))));
      expect(withRefs.group_id).toBe(plain.gid);
    });

    test('an answer that is still reserving carries no readme', async () => {
      const specs = Array.from({ length: 20 }, (_, i) => ({ name: `rv${String(i).padStart(2, '0')}` }));
      const readmes = Object.fromEntries(specs.map((sp) => [sp.name, text('# r\n')]));
      const adopt = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = async (...a) => {
        env.mono += 10_000; // the creation budget is spent after the first batch
        return adopt(...a);
      };
      const s = new ReadmeScenario(env, specs, readmes);
      await s.create();
      expect(s.created).toMatchObject({ reserving: { done: 16, total: 20 } });
      for (const m of (s.created as unknown as { members: Array<Record<string, unknown>> }).members) {
        expect(m).not.toHaveProperty('readme');
        expect(m.files).toEqual([]);
      }
    });

    test.each([
      ['an uppercase sha256', { sha256: 'A'.repeat(64), size: 5 }],
      ['a short sha256', { sha256: 'a'.repeat(63), size: 5 }],
      ['a sha256 that is not a string', { sha256: 5, size: 5 }],
      ['a size of 0', { sha256: 'a'.repeat(64), size: 0 }],
      ['a size of 65537', { sha256: 'a'.repeat(64), size: 65537 }],
      ['a size that is not an integer', { sha256: 'a'.repeat(64), size: 1.5 }],
      ['a size that is a string', { sha256: 'a'.repeat(64), size: '5' }],
      ['no sha256', { size: 5 }],
      ['no size', { sha256: 'a'.repeat(64) }],
      ['a string', 'abc'],
      ['null', null],
      ['a list', []],
    ])('%s is invalid_request naming the member', async (_n, bad) => {
      const s = await new ReadmeScenario(env, [{ name: 'alpha' }], {}).create();
      const members = [{ ...s.members()[0]!, readme: bad }];
      const r = await env.create(s.token, members);
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      expect(detail(r)).toContain(`'readme' of 'alpha' is {"sha256", "size"} of a readme of 1 to 65536 bytes`);
    });

    test('a readme of 65536 bytes and one of 1 byte are taken', async () => {
      const big = new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: text('x'.repeat(65536)), beta: text('y') });
      await big.create();
      expect(big.answerOf('alpha').readme.size).toBe(65536);
      expect(big.answerOf('beta').readme.size).toBe(1);
    });
  });

  describe('commit', () => {
    test('a group whose readmes are uploaded is committed with refs, and the stored inputs carry the text', async () => {
      const s = await two().ready();
      const r = await s.commit(s.objectsBody());
      expect(r.statusCode).toBe(202);
      const h = (await s.header())!;
      expect(await rig.store.getCommitInput(s.gid, h.commit_hash!, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { readme: '# alpha\n' } });
      expect(await rig.store.getCommitInput(s.gid, h.commit_hash!, 1)).toEqual({ name: 'beta', manifest_sha256: s.pkgs[1]!.manifest, display: { readme: '# beta\n' } });
    });

    test('other display fields of a member travel with its readme ref', async () => {
      const s = await two().ready();
      const body = s.objectsBody();
      Object.assign(body.members[0]!, { description: 'The first', keywords: ['a'] });
      expect((await s.commit(body)).statusCode).toBe(202);
      const h = (await s.header())!;
      const stored = await rig.store.getCommitInput(s.gid, h.commit_hash!, 0);
      expect(stored).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { description: 'The first', keywords: ['a'], readme: '# alpha\n' } });
      expect(Object.keys(stored!.display!)).toEqual(['description', 'keywords', 'readme']);
    });

    test('a member without a manifest hash and with a source commit is stored in the key order of the inline form', async () => {
      const s = await two().ready();
      const body = s.objectsBody();
      delete (body.members[0] as Record<string, unknown>).manifest_sha256;
      Object.assign(body.members[0]!, { source_commit: 'c'.repeat(40) });
      expect((await s.commit(body)).statusCode).toBe(202);
      const h = (await s.header())!;
      const stored = await rig.store.getCommitInput(s.gid, h.commit_hash!, 0);
      expect(stored).toEqual({ name: 'alpha', display: { readme: '# alpha\n' }, source_commit: 'c'.repeat(40) });
      expect(Object.keys(stored!)).toEqual(['name', 'display', 'source_commit']);
    });

    test('a readme whose object is absent is upload_invalid naming the member; the group stays open and a correct commit then succeeds', async () => {
      const s = await two().create();
      await s.upload();
      await s.uploadReadmes(['alpha']);
      const r = await s.commit(s.objectsBody());
      expect(errorCode(r)).toBe('upload_invalid');
      expect(detail(r)).toContain(`the readme of 'beta' (sha256 ${sha(s.readmes.beta!)}) was not uploaded`);
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
      await s.uploadReadmes(['beta']);
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    });

    test.each([
      ['another sha256 at the declared size', (b: Buffer) => text('# BETA\n'.padEnd(b.length, '.'))],
      ['bytes of another size', (b: Buffer) => b.subarray(0, b.length - 1)],
    ])('stored bytes with %s are upload_invalid naming the member; the group stays open and a correct commit then succeeds', async (_n, wrong) => {
      const s = await two().create();
      await s.upload();
      await s.uploadReadmes(['alpha']);
      await env.objects.put(s.readmeKey('beta'), wrong(s.readmes.beta!), { contentType: 'application/octet-stream' });
      const r = await s.commit(s.objectsBody());
      expect(errorCode(r)).toBe('upload_invalid');
      expect(detail(r)).toContain(`the readme of 'beta' in storage is not the one named (sha256 ${sha(s.readmes.beta!)}, ${s.readmes.beta!.length} bytes)`);
      expect((await s.header())!.status).toBe('open');
      await s.uploadReadmes(['beta']);
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    });

    test('stored bytes with the declared sha256 but a commit ref one byte larger are upload_invalid naming the member; the group stays open and a correct commit then succeeds', async () => {
      const s = await two().ready();
      const ref = refOf(s.readmes.beta!);
      const body = s.objectsBody();
      Object.assign(body.members[1]!, { readme: { sha256: ref.sha256, size: ref.size + 1 } });
      const r = await s.commit(body);
      expect(errorCode(r)).toBe('upload_invalid');
      expect(detail(r)).toContain(`the readme of 'beta' in storage is not the one named (sha256 ${ref.sha256}, ${ref.size + 1} bytes)`);
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    });

    test('a commit that names another sha256 than the one the create declared is upload_invalid "was not uploaded" naming the member; the group stays open', async () => {
      const s = await two().ready();
      const other = refOf(text('# not the declared one\n'));
      const body = s.objectsBody();
      Object.assign(body.members[1]!, { readme: other });
      const r = await s.commit(body);
      expect(errorCode(r)).toBe('upload_invalid');
      expect(detail(r)).toContain(`the readme of 'beta' (sha256 ${other.sha256}) was not uploaded`);
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    });

    test('bytes that are not UTF-8 are invalid_request naming the member; the group stays open', async () => {
      const bad = Buffer.from([0x23, 0x20, 0xff, 0xfe, 0x0a]);
      const s = new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: text('# alpha\n'), beta: bad });
      await s.ready();
      const r = await s.commit(s.objectsBody());
      expect(errorCode(r)).toBe('invalid_request');
      expect(detail(r)).toContain("the readme of 'beta' is not UTF-8 text");
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
      const fixed = { members: s.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest, readme: '# ok\n' })) };
      expect((await s.commit(fixed)).statusCode).toBe(202);
    });

    test.each([
      ['an uppercase sha256', { sha256: 'A'.repeat(64), size: 5 }],
      ['a sha256 that is not a string', { sha256: 5, size: 5 }],
      ['a size of 0', { sha256: 'a'.repeat(64), size: 0 }],
      ['a size of 65537', { sha256: 'a'.repeat(64), size: 65537 }],
      ['a size that is not an integer', { sha256: 'a'.repeat(64), size: 2.5 }],
      ['no sha256', { size: 5 }],
      ['no size', { sha256: 'a'.repeat(64) }],
      ['null', null],
      ['a number', 7],
      ['a list', []],
    ])('%s in the commit is invalid_request naming the member; the group stays open and a correct commit then succeeds', async (_n, bad) => {
      const s = await two().ready();
      const body = s.objectsBody();
      Object.assign(body.members[1]!, { readme: bad });
      const r = await s.commit(body);
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      expect(detail(r)).toContain(`'readme' of 'beta' is a string or {"sha256", "size"} of a readme of 1 to 65536 bytes`);
      expect((await s.header())!.status).toBe('open');
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    });

    test('an inline readme is still accepted, also on a group whose create declared readme refs', async () => {
      const s = await two().ready();
      expect((await s.commit(s.inlineBody())).statusCode).toBe(202);
      const h = (await s.header())!;
      expect(await rig.store.getCommitInput(s.gid, h.commit_hash!, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { readme: '# alpha\n' } });
      await publish(s);
      expect(json(await env.call('GET', '/api/v1/packages/alpha/1.0.0')).readme).toBe('# alpha\n');
    });

    test('an inline readme is accepted on a group that declared none', async () => {
      const s = await two(false).ready();
      expect((await s.commit(s.inlineBody())).statusCode).toBe(202);
    });

    test('an inline readme over 65536 bytes keeps its own message', async () => {
      const s = await two(false).ready();
      const body = s.inlineBody();
      body.members[0]!.readme = 'x'.repeat(65537);
      const r = await s.commit(body);
      expect(detail(r)).toContain("'readme' is a string of at most 65536 bytes of UTF-8");
    });
  });

  describe('the request hash', () => {
    test('a repeat of an object-form commit answers as a repeat without reading any object, in every state after the first', async () => {
      const s = await two().ready();
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
      const hash = (await s.header())!.commit_hash;
      for (const key of [s.readmeKey('alpha'), s.readmeKey('beta')]) await env.objects.delete(key);
      const gets: string[] = [];
      const get = env.objects.get.bind(env.objects);
      env.objects.get = async (k) => {
        gets.push(k);
        return get(k);
      };

      expect((await s.commit(s.objectsBody())).statusCode).toBe(202); // validating
      expect(await s.runAll()).toEqual(['committed']);
      expect((await s.commit(s.objectsBody())).statusCode).toBe(200); // committed
      await new Chain(env).drain();
      expect((await s.header())!.status).toBe('visible');
      const visible = await s.commit(s.objectsBody());
      expect(visible.statusCode).toBe(200); // visible
      expect(json(visible).status).toBe('visible');
      expect((await s.header())!.commit_hash).toBe(hash);
      expect(gets.filter((k) => k.endsWith('/README.md'))).toEqual([]);
    });

    test('a repeat in the other form is group_commit_refused, in both directions', async () => {
      const s = await two().ready();
      expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
      expect(errorCode(await s.commit(s.inlineBody()))).toBe('group_commit_refused');

      const t = new ReadmeScenario(env, [{ name: 'gamma' }], { gamma: text('# g\n') });
      await t.ready();
      expect((await t.commit(t.inlineBody())).statusCode).toBe(202);
      expect(errorCode(await t.commit(t.objectsBody()))).toBe('group_commit_refused');
    });

    test('the hash of an inline request is the one the unchanged rule gives', () => {
      const members = { members: [{ name: 'alpha', version: '1.0.0', canonical: '1.0.0', subdirs: [] }, { name: 'beta', version: '1.0.0', canonical: '1.0.0', subdirs: [] }] };
      const body = { members: [{ name: 'beta' }, { source_commit: 'b'.repeat(40), name: 'alpha', manifest_sha256: 'a'.repeat(64), readme: '# r', description: 'd' }] };
      const { hash, inputs } = parseGroupCommit(members, body);
      // sha256 of the JSON of the inputs, first 16 hex digits, computed with the rule as it was before readme objects.
      expect(JSON.stringify(inputs)).toBe('[{"name":"alpha","manifest_sha256":"' + 'a'.repeat(64) + '","display":{"description":"d","readme":"# r"},"source_commit":"' + 'b'.repeat(40) + '"},{"name":"beta"}]');
      expect(hash).toBe('e2b559e41632a8dd');
      expect(hash).toBe(commitRequestHash(JSON.stringify(inputs)));
    });

    test('a request that names a readme by digest has another hash than the same request inline', () => {
      const members = { members: [{ name: 'alpha', version: '1.0.0', canonical: '1.0.0', subdirs: [] }] };
      const inline = parseGroupCommit(members, { members: [{ name: 'alpha', readme: '# r' }] });
      const named = parseGroupCommit(members, { members: [{ name: 'alpha', readme: { sha256: sha('# r'), size: 3 } }] });
      expect(named.hash).not.toBe(inline.hash);
      expect(named.hash).toBe(commitRequestHash(JSON.stringify([{ name: 'alpha', readme_ref: { sha256: sha('# r'), size: 3 } }])));
      expect(named.named).toHaveLength(1);
    });
  });
});

describe.each(RIGS)('the same set in either form: %s', (_label, make) => {
  const BOM = '﻿# Título "quoted" \\ back\\slash \\n é 日本 😀\r\nline "two"\n';
  const set = [
    { name: 'alpha', readme: BOM },
    { name: 'beta', readme: '# beta\n\nplain\n' },
    { name: 'gamma' },
  ];

  /** One registry instance: the group published with the readmes as the form says; everything it stored and serves. */
  async function run(objects: boolean) {
    const env = new GroupEnv(make());
    const readmes = Object.fromEntries(set.filter((m) => m.readme !== undefined).map((m) => [m.name, text(m.readme!)]));
    const s = new ReadmeScenario(env, set.map((m) => ({ name: m.name })), readmes, objects);
    await s.ready();
    expect((await s.commit(objects ? s.objectsBody() : s.inlineBody())).statusCode).toBe(202);
    const h = (await s.header())!;
    const inputs = await Promise.all(set.map((_m, i) => env.rig.store.getCommitInput(s.gid, h.commit_hash!, i)));
    await publish(s);
    const served: Record<string, string> = {};
    for (const m of set) {
      served[`version ${m.name}`] = (await env.call('GET', `/api/v1/packages/${m.name}/1.0.0`)).body;
      served[`package ${m.name}`] = (await env.call('GET', `/api/v1/packages/${m.name}`)).body;
    }
    const channel = Object.fromEntries(env.objects.keys().filter((k) => !k.startsWith('quarantine/')).map((k) => [k, env.objects.objects.get(k)!.body.toString('base64')]));
    return { gid: s.gid, hash: h.commit_hash, inputs, served, channel };
  }

  test('yields identical stored commit inputs, getVersion and getPackage bodies, index files and repodata', async () => {
    const inline = await run(false);
    const objects = await run(true);
    expect(objects.gid).toBe(inline.gid);
    expect(objects.hash).not.toBe(inline.hash);
    expect(JSON.stringify(objects.inputs)).toBe(JSON.stringify(inline.inputs));
    expect(objects.served).toEqual(inline.served);
    expect(Object.keys(inline.channel).some((k) => k.endsWith('repodata.json'))).toBe(true);
    expect(objects.channel).toEqual(inline.channel);
    // The text came through whole: the BOM, the non-ASCII, the quotes and the backslashes.
    expect(JSON.parse(objects.served['version alpha']!).readme).toBe(BOM);
    expect(JSON.parse(objects.served['package alpha']!).readme).toBe(BOM);
    expect(JSON.parse(objects.served['version gamma']!)).not.toHaveProperty('readme');
  }, 60_000);
});
