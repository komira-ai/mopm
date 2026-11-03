import { parseGroupCommit } from '../../src/publish/group-commit';
import { RIGS, type Rig } from '../group-rig';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { quarantineKeyFor, readmeUploadIdFor } from '../../src/publish/group-keys';
import { ReadmeScenario, refOf, sha } from './group-readme-scenario';

/**
 * A member's readme as an object, when storage fails or time and other requests move while the commit reads it, and when members
 * are named in another order than the group's. Each test says what it proves.
 */

const text = (s: string) => Buffer.from(s, 'utf8');
const DAY = 24 * 3_600_000;

/** Run the validator job and the chain behind it until the group is visible. */
async function publish(s: ReadmeScenario): Promise<void> {
  expect(await s.runAll()).toEqual(['committed']);
  await new Chain(s.env).drain();
  expect((await s.header())!.status).toBe('visible');
}

/** A gate: calls to `hold` wait until `open()`; `arrived` resolves once `n` calls are waiting. */
class Gate {
  private waiting: Array<() => void> = [];
  private watchers: Array<{ n: number; wake: () => void }> = [];
  private opened = false;
  hold(): Promise<void> {
    if (this.opened) return Promise.resolve();
    return new Promise((r) => {
      this.waiting.push(r);
      for (const w of this.watchers.filter((x) => this.waiting.length >= x.n)) w.wake();
    });
  }
  arrived(n: number): Promise<void> {
    if (this.waiting.length >= n) return Promise.resolve();
    return new Promise((wake) => this.watchers.push({ n, wake }));
  }
  open() {
    this.opened = true;
    for (const r of this.waiting.splice(0)) r();
  }
}

const isReadme = (k: string) => k.endsWith('/README.md');

describe.each(RIGS)('readme objects over failing storage: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    jest.spyOn(console, 'error').mockImplementation(() => undefined); // the router logs each internal error
  });
  afterEach(() => jest.restoreAllMocks());
  const many = (n: number) => {
    const specs = Array.from({ length: n }, (_, i) => ({ name: `rm${String(i).padStart(2, '0')}` }));
    return new ReadmeScenario(env, specs, Object.fromEntries(specs.map((sp) => [sp.name, text(`# ${sp.name}\n`)])));
  };
  const inputsOf = (s: ReadmeScenario, hash: string) => Promise.all(s.pkgs.map((_p, i) => rig.store.getCommitInput(s.gid, hash, i)));

  test('a HEAD of a readme object that is rejected makes the create an error; the group stays open, and the same create succeeds once storage is back', async () => {
    const s = many(3);
    const head = env.objects.head.bind(env.objects);
    let down = true;
    env.objects.head = async (k) => {
      if (down && isReadme(k)) throw new Error('storage unavailable');
      return head(k);
    };
    const failed = await s.createRaw();
    expect(failed.statusCode).toBe(500);
    expect(env.groupQueue.sent).toEqual([]);
    down = false;
    await s.create();
    expect((await s.header())!.status).toBe('open');
    for (const sp of s.specs) expect(s.answerOf(sp.name!).readme).toMatchObject({ uploaded: false });
    await s.upload();
    await s.uploadReadmes();
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
  });

  test('a GET of a readme object that is rejected makes the commit an error; the group stays open with no commit hash or inputs and nothing queued, and the commit succeeds once storage is back', async () => {
    const s = await many(2).ready();
    const before = await s.header();
    const hash = parseGroupCommit({ members: s.pkgs.map((p) => ({ name: p.name, version: p.version, canonical: p.version, subdirs: [] })) }, s.objectsBody()).hash;
    const get = env.objects.get.bind(env.objects);
    let down = true;
    env.objects.get = async (k) => {
      if (down && isReadme(k)) throw new Error('storage unavailable');
      return get(k);
    };
    const r = await s.commit(s.objectsBody());
    expect(r.statusCode).toBe(500);
    expect(await s.header()).toEqual(before);
    expect(await inputsOf(s, hash)).toEqual([undefined, undefined]);
    expect(env.groupQueue.sent).toEqual([]);
    down = false;
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    expect((await s.header())!.commit_hash).toBe(hash);
    await publish(s);
  });

  test('a GET that is rejected in a later batch, after the first batch was read and decoded, leaves no input stored and nothing queued; the retry publishes every readme', async () => {
    const s = await many(20).ready();
    const before = await s.header();
    const hash = parseGroupCommit({ members: s.pkgs.map((p) => ({ name: p.name, version: p.version, canonical: p.version, subdirs: [] })) }, s.objectsBody()).hash;
    const late = new Set(s.pkgs.slice(16).map((p) => s.readmeKey(p.name)));
    const read: string[] = [];
    const get = env.objects.get.bind(env.objects);
    let down = true;
    env.objects.get = async (k) => {
      if (isReadme(k)) read.push(k);
      if (down && late.has(k)) throw new Error('storage unavailable');
      return get(k);
    };
    const r = await s.commit(s.objectsBody());
    expect(r.statusCode).toBe(500);
    expect(read.slice(0, 16).sort()).toEqual(s.pkgs.slice(0, 16).map((p) => s.readmeKey(p.name)).sort()); // the first batch was read before the failure
    expect(read.length).toBeGreaterThan(16);
    expect(await s.header()).toEqual(before);
    expect((await inputsOf(s, hash)).every((i) => i === undefined)).toBe(true);
    expect(env.groupQueue.sent).toEqual([]);
    down = false;
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    await publish(s);
    for (const p of s.pkgs) expect(json(await env.call('GET', `/api/v1/packages/${p.name}/1.0.0`)).readme).toBe(`# ${p.name}\n`);
  });

  test('a HEAD of a file that is rejected during a commit with readme objects is an error with the group open', async () => {
    const s = await many(2).ready();
    const head = env.objects.head.bind(env.objects);
    env.objects.head = async (k) => {
      if (!isReadme(k)) throw new Error('storage unavailable');
      return head(k);
    };
    expect((await s.commit(s.objectsBody())).statusCode).toBe(500);
    expect((await s.header())!.status).toBe('open');
    expect(env.groupQueue.sent).toEqual([]);
  });
});

describe.each(RIGS)('readme objects while the commit reads them: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let gate: Gate;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    gate = new Gate();
  });
  const two = () => new ReadmeScenario(env, [{ name: 'alpha' }, { name: 'beta' }], { alpha: text('# alpha\n'), beta: text('# beta\n') });
  /** Reads of readme objects wait at the gate. */
  const hold = (first = Infinity) => {
    const get = env.objects.get.bind(env.objects);
    let n = 0;
    env.objects.get = async (k) => {
      if (isReadme(k) && n++ < first) await gate.hold();
      return get(k);
    };
  };
  /** Start a commit that stops at its first read; returns what it will answer. */
  const started = async (s: ReadmeScenario, body: unknown) => {
    const pending = s.commit(body);
    await gate.arrived(1);
    return pending;
  };

  test('a group aborted while its readmes are read is not committed: the request is refused, no validation is queued, no commit hash is set', async () => {
    const s = await two().ready();
    hold();
    const pending = started(s, s.objectsBody());
    await gate.arrived(2);
    expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
    gate.open();
    const r = await pending;
    expect(errorCode(r)).toBe('group_commit_refused');
    expect(json(r).error.message).toContain('aborted');
    const h = (await s.header())!;
    expect(h.status).toBe('aborted');
    expect(h.commit_hash).toBeUndefined();
    expect(env.groupQueue.sent).toEqual([]);
  });

  test('a deadline that passes while the readmes are read refuses the request; no validation is queued and no commit hash is set', async () => {
    const s = await two().ready();
    hold();
    const pending = started(s, s.objectsBody());
    await gate.arrived(2);
    env.clock.advance(30 * DAY);
    gate.open();
    const r = await pending;
    expect(errorCode(r)).toBe('group_commit_refused');
    expect(json(r).error.message).toContain('past its deadline');
    expect((await s.header())!.commit_hash).toBeUndefined();
    expect(env.groupQueue.sent).toEqual([]);
  });

  test('a group that is aborted and opened again while its readmes are read is not committed by the old request; the group stays open on its new attempt and a new commit then succeeds', async () => {
    const s = await two().ready();
    hold();
    const pending = started(s, s.objectsBody());
    await gate.arrived(2);
    expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
    expect([200, 201]).toContain((await env.create(s.token, s.members())).statusCode);
    expect(await s.header()).toMatchObject({ status: 'open', attempt: 2 });
    gate.open();
    const r = await pending;
    expect(errorCode(r)).toBe('group_commit_refused');
    expect(json(r).error.message).toContain('opened again');
    const h = (await s.header())!;
    expect(h).toMatchObject({ status: 'open', attempt: 2 });
    expect(h.commit_hash).toBeUndefined();
    expect(env.groupQueue.sent).toEqual([]);
    expect((await s.commit(s.objectsBody())).statusCode).toBe(202);
    await publish(s);
  });

  test('an inline commit that wins while an object-form commit reads its readmes starts the only validation; the object-form request is refused and its inputs are never the group\'s', async () => {
    const s = await two().ready();
    hold();
    const objects = started(s, s.objectsBody());
    await gate.arrived(2);
    // The inline commit (which reads no object) wins the compare-and-set on the header.
    expect((await s.commit({ members: s.pkgs.map((p) => ({ name: p.name, manifest_sha256: p.manifest, readme: `INLINE ${p.name}\n` })) })).statusCode).toBe(202);
    const winner = (await s.header())!.commit_hash!;
    gate.open();
    const r = await objects;
    expect(errorCode(r)).toBe('group_commit_refused');
    const h = (await s.header())!;
    expect(h.status).toBe('validating');
    expect(h.commit_hash).toBe(winner);
    expect(env.groupQueue.sent).toHaveLength(1);
    expect(await rig.store.getCommitInput(s.gid, winner, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { readme: 'INLINE alpha\n' } });
    await publish(s);
    expect(json(await env.call('GET', '/api/v1/packages/alpha/1.0.0')).readme).toBe('INLINE alpha\n');
    expect(json(await env.call('GET', '/api/v1/packages/beta/1.0.0')).readme).toBe('INLINE beta\n');
  });

  test('an object-form commit that wins while another object-form commit of other refs reads its readmes: only the winner\'s hash and inputs are the group\'s', async () => {
    const s = await two().ready();
    const other = text('# beta, the other\n');
    await env.objects.put(quarantineKeyFor(readmeUploadIdFor(s.gid, { name: 'beta', canonical: '1.0.0' }, sha(other)), 'README.md'), other, { contentType: 'application/octet-stream' });
    const second = s.objectsBody();
    Object.assign(second.members[1]!, { readme: refOf(other) });
    hold(2); // only the first request's two reads wait
    const slow = started(s, s.objectsBody());
    await gate.arrived(2);
    expect((await s.commit(second)).statusCode).toBe(202);
    const winner = (await s.header())!.commit_hash!;
    gate.open();
    expect(errorCode(await slow)).toBe('group_commit_refused');
    expect((await s.header())!.commit_hash).toBe(winner);
    expect(env.groupQueue.sent).toHaveLength(1);
    expect(await rig.store.getCommitInput(s.gid, winner, 1)).toEqual({ name: 'beta', manifest_sha256: s.pkgs[1]!.manifest, display: { readme: '# beta, the other\n' } });
    await publish(s);
    expect(json(await env.call('GET', '/api/v1/packages/beta/1.0.0')).readme).toBe('# beta, the other\n');
    expect(json(await env.call('GET', '/api/v1/packages/alpha/1.0.0')).readme).toBe('# alpha\n');
  });

  test('two identical object-form commits that read at the same time queue one validation and answer for the same hash', async () => {
    const s = await two().ready();
    hold();
    const a = started(s, s.objectsBody());
    const b = s.commit(s.objectsBody());
    await gate.arrived(4);
    gate.open();
    const [ra, rb] = [await a, await b];
    expect([ra.statusCode, rb.statusCode]).toEqual([202, 202]);
    expect(env.groupQueue.sent).toHaveLength(1);
    await publish(s);
    expect(json(await env.call('GET', '/api/v1/packages/beta/1.0.0')).readme).toBe('# beta\n');
  });
});
