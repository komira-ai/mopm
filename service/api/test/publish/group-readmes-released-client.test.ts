import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { RIGS } from '../group-rig';
import { Chain } from './group-chain-env';
import { GroupEnv, json } from './group-env';
import { pkg, type Pkg } from './harness';
import { Scenario } from './group-scenario';

/**
 * The requests the released command line (v0.0.104) makes, replayed byte for byte against this registry. The bodies are the files
 * test/fixtures/released-client-v0.0.104/{create,commit}.json, which the Zig test //:compat_v0_0_104 holds to what the released
 * client (its own code, tests/compat/v0.0.104) sends for a staged set of alpha, beta and gamma. That client knows nothing of readme
 * objects: it sends no `readme` object in the create, and every readme inline in the commit.
 *
 * The one thing replaced is what depends on the archive: the Zig test's files are small texts, and this registry opens real
 * archives, so each member's `subdir`, `filename`, `sha256` and `size` in the create, and `manifest_sha256` in the commit, are the
 * ones of this test's archive for the same package. Every other byte (member order, key order, escaping of the readmes, spacing) is
 * the client's.
 */

const FIXTURES = join(__dirname, '..', 'fixtures', 'released-client-v0.0.104');
const golden = (name: string): string => readFileSync(join(FIXTURES, name), 'utf8');

const READMES: Record<string, string | undefined> = {
  alpha: '# Alpha "quoted"\nline é 日本 😀 \\ end\n',
  beta: '',
  gamma: undefined,
};

/** The golden create request with each member's file facts replaced by those of `pkgs`. Throws when a member is not in the golden. */
function createBody(pkgs: Pkg[]): string {
  let body = golden('create.json');
  for (const p of pkgs) {
    const member = new RegExp(`("name":"${p.name}","version":"[^"]*","files":\\[\\{"subdir":")[^"]*(","filename":")[^"]*(","sha256":")[0-9a-f]{64}(","size":)\\d+`);
    if (!member.test(body)) throw new Error(`the golden create request has no member ${p.name} in the released client's shape`);
    body = body.replace(member, (_m, a, b, c, d) => `${a}${p.subdir}${b}${p.filename}${c}${p.sha256}${d}${p.bytes.length}`);
  }
  return body;
}

/** The golden commit request with each member's `manifest_sha256` replaced by that of `pkgs`. */
function commitBody(pkgs: Pkg[]): string {
  let body = golden('commit.json');
  for (const p of pkgs) {
    const member = new RegExp(`("name":"${p.name}","manifest_sha256":")[0-9a-f]{64}`);
    if (!member.test(body)) throw new Error(`the golden commit request has no member ${p.name} in the released client's shape`);
    body = body.replace(member, (_m, a) => `${a}${p.manifest}`);
  }
  return body;
}

describe.each(RIGS)('the requests of the released command line: %s', (_label, make) => {
  test('the golden bodies are the released client\'s: readmes inline in the commit, none declared in the create', () => {
    const pkgs = ['alpha', 'beta', 'gamma'].map((name) => pkg({ name, subdir: 'noarch' }));
    const commit = JSON.parse(commitBody(pkgs)) as { members: Array<{ name: string; readme?: unknown }> };
    expect(commit.members.map((m) => [m.name, m.readme])).toEqual([['alpha', READMES.alpha], ['beta', ''], ['gamma', undefined]]);
    expect(commit.members[2]).not.toHaveProperty('readme');
    const create = JSON.parse(createBody(pkgs)) as { members: Array<Record<string, unknown>> };
    expect(create.members.map((m) => Object.keys(m))).toEqual([['name', 'version', 'files'], ['name', 'version', 'files'], ['name', 'version', 'files']]);
    expect(createBody(pkgs).startsWith('{"members":[{"name":"alpha","version":"1.0.0","files":[{"subdir":"noarch","filename":"')).toBe(true);
  });

  test('the released client\'s create, uploads and inline commit are accepted byte for byte; the group publishes and serves its readmes', async () => {
    const env = new GroupEnv(make());
    const s = new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }, { name: 'gamma' }]);
    s.pkgs = s.specs.map((sp) => pkg({ subdir: 'noarch', ...sp }));
    s.token = await env.account(1, 'octocat', s.names);

    const created = await env.call('POST', '/api/v1/groups', s.token, createBody(s.pkgs));
    expect(created.statusCode).toBe(201);
    s.created = json(created);
    s.gid = s.created!.group_id;
    // The answer is what the released client reads: for every member, its files with an upload id and a URL.
    for (const m of s.created!.members as unknown as Array<{ name: string; files: Array<{ put_url?: string; uploaded: boolean }>; readme?: unknown }>) {
      expect(m.files).toHaveLength(1);
      expect(m.files[0]).toMatchObject({ uploaded: false, put_url: expect.any(String) });
      expect(m).not.toHaveProperty('readme'); // it declared none
    }
    await s.upload();

    const committed = await env.call('POST', `/api/v1/groups/${s.gid}/commit`, s.token, commitBody(s.pkgs));
    expect(committed.statusCode).toBe(202);
    const h = (await s.header())!;
    expect(await env.rig.store.getCommitInput(s.gid, h.commit_hash!, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, display: { readme: READMES.alpha } });
    expect(await s.runAll()).toEqual(['committed']);
    await new Chain(env).drain();
    expect((await s.header())!.status).toBe('visible');

    expect(json(await env.call('GET', '/api/v1/packages/alpha/1.0.0')).readme).toBe(READMES.alpha);
    expect(json(await env.call('GET', '/api/v1/packages/alpha')).readme).toBe(READMES.alpha);
    expect(json(await env.call('GET', '/api/v1/packages/gamma/1.0.0'))).not.toHaveProperty('readme');
    // An empty readme is what the registry has always done with it; the replay must not change that.
    const beta = json(await env.call('GET', '/api/v1/packages/beta/1.0.0'));
    expect(beta.readme).toBe('');

    // The same commit again, as a client whose response was lost sends it: a repeat.
    expect((await env.call('POST', `/api/v1/groups/${s.gid}/commit`, s.token, commitBody(s.pkgs))).statusCode).toBe(200);
  });
});
