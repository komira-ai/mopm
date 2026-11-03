import { RIGS } from '../group-rig';
import { Chain } from './group-chain-env';
import { GroupEnv, json } from './group-env';
import { pkg } from './harness';
import { Scenario } from './group-scenario';

/**
 * The requests the released command line makes (the code at komira-ai/mopm commit d0b9020: `createBody` in
 * src/cli/group_publish.zig and `commitBody` in src/cli/group_plan.zig), replayed byte for byte against this registry. That client
 * knows nothing of readme objects: it sends no `readme` object in the create, and every readme inline in the commit.
 */

/** Zig's `std.json.encodeJsonString` with default options: `"` and `\` escaped, \b \f \n \r \t by name, other control characters as \u00XX; everything else (non-ASCII too) as it is. */
function zigString(s: string): string {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (c === 8) out += '\\b';
    else if (c === 12) out += '\\f';
    else if (c === 10) out += '\\n';
    else if (c === 13) out += '\\r';
    else if (c === 9) out += '\\t';
    else if (c < 0x20) out += `\\u${c.toString(16).padStart(4, '0')}`;
    else out += ch;
  }
  return out + '"';
}

const READMES: Record<string, string | undefined> = {
  alpha: '# Alpha "quoted"\nline é 日本 😀 \\ end\n',
  beta: '',
  gamma: undefined,
};

/** `Publisher.createBody`: members in plan order, no spaces, files with subdir, filename, sha256 and size. */
function createBody(pkgs: ReturnType<typeof pkg>[]): string {
  const members = pkgs.map((p) => `{"name":${zigString(p.name)},"version":${zigString(p.version)},"files":[{"subdir":${zigString(p.subdir)},"filename":${zigString(p.filename)},"sha256":"${p.sha256}","size":${p.bytes.length}}]}`);
  return `{"members":[${members.join(',')}]}`;
}

/** `group_plan.commitBody`: name, manifest_sha256, then `readme` when there is one (an empty readme is `""`). */
function commitBody(pkgs: ReturnType<typeof pkg>[]): string {
  const members = pkgs.map((p) => {
    const readme = READMES[p.name];
    return `{"name":${zigString(p.name)},"manifest_sha256":"${p.manifest}"${readme === undefined ? '' : `,"readme":${zigString(readme)}`}}`;
  });
  return `{"members":[${members.join(',')}]}`;
}

describe.each(RIGS)('the requests of the released command line: %s', (_label, make) => {
  test('the bodies are the ones the released code writes', () => {
    const pkgs = ['alpha', 'beta', 'gamma'].map((name) => pkg({ name, subdir: 'noarch' }));
    const commit = commitBody(pkgs);
    expect(commit).toBe(
      `{"members":[{"name":"alpha","manifest_sha256":"${pkgs[0]!.manifest}","readme":"# Alpha \\"quoted\\"\\nline é 日本 😀 \\\\ end\\n"},` +
        `{"name":"beta","manifest_sha256":"${pkgs[1]!.manifest}","readme":""},{"name":"gamma","manifest_sha256":"${pkgs[2]!.manifest}"}]}`,
    );
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
