import { createHash } from 'node:crypto';
import * as fs from 'fs';
import * as path from 'path';
import type { Principal } from '../../src/auth';
import { DEFAULT_PUBLISH_CONFIG } from '../../src/publish/config';
import { GROUP_ID } from '../../src/publish/group-keys';
import { groupIdFor, parseGroupRequest } from '../../src/publish/group-service';
import { actorOf } from '../../src/publish/service';

/**
 * The group id is a documented interface (spec/staged-set.md, "The group id"; spec/api/openapi.yaml, `createGroup`): a client
 * computes it from the caller and the declared set, and reads the group with GET /groups/{id}. These tests pin it. A change to
 * how the id is derived makes the vectors below red, and the documented change is a new id prefix, not a different hash.
 *
 * What they prove: the exact string that is hashed and the digits that are kept (the vectors' `canonical_json` and `group_id`, from
 * an independent hash of that string), that the request is put into the canonical order first (a vector sends members and files
 * out of order), that the actor and every field of the set take part, and that the forms of the actor are the ones documented.
 */

type Vector = { name: string; actor: string; request: unknown; canonical_json: string; group_id: string };
const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'group-id-vectors.json'), 'utf8')) as { vectors: Vector[] };
const OPENAPI = fs.readFileSync(path.resolve(__dirname, '../../../../spec/api/openapi.yaml'), 'utf8');

const idOf = (actor: string, request: unknown) => groupIdFor(actor, parseGroupRequest(DEFAULT_PUBLISH_CONFIG, request));

describe('the vectors of the group id', () => {
  test('the fixture holds the vectors the documentation quotes (a scan that finds none proves nothing)', () => {
    expect(FIXTURE.vectors.length).toBeGreaterThanOrEqual(4);
    expect(new Set(FIXTURE.vectors.map((v) => v.group_id)).size).toBe(FIXTURE.vectors.length);
    for (const v of FIXTURE.vectors) expect(v.group_id).toMatch(GROUP_ID);
  });

  test.each(FIXTURE.vectors.map((v) => [v.name, v] as const))('%s: the id the registry derives is the vector\'s', (_name, v) => {
    expect(idOf(v.actor, v.request)).toBe(v.group_id);
  });

  test.each(FIXTURE.vectors.map((v) => [v.name, v] as const))('%s: the id is "grp_" and the first 32 hex digits of the sha256 of the canonical JSON', (_name, v) => {
    expect(`grp_${createHash('sha256').update(v.canonical_json, 'utf8').digest('hex').slice(0, 32)}`).toBe(v.group_id);
  });

  test.each(FIXTURE.vectors.map((v) => [v.name, v] as const))('%s: the canonical JSON is an array of the actor and the sorted set, written without white space', (_name, v) => {
    const parsed = JSON.parse(v.canonical_json) as [string, Array<[string, string, Array<[string, string, string, number]>]>];
    expect(parsed[0]).toBe(v.actor);
    expect(JSON.stringify(parsed)).toBe(v.canonical_json);
    const names = parsed[1].map((m) => m[0]);
    expect(names).toEqual([...names].sort());
    for (const m of parsed[1]) {
      const keys = m[2].map((f) => `${f[0]}/${f[1]}`);
      expect(keys).toEqual([...keys].sort());
    }
  });

  test('an id is a function of the actor, the version, and each subdir, file name, digest and size', () => {
    const base = FIXTURE.vectors[0]!;
    const req = JSON.parse(JSON.stringify(base.request)) as { members: Array<{ name: string; version: string; files: Array<Record<string, unknown>> }> };
    const ids = new Set<string>([idOf(base.actor, req)]);
    ids.add(idOf('u:1235', req));
    const edit = (f: (r: typeof req) => void) => {
      const copy = JSON.parse(JSON.stringify(req)) as typeof req;
      f(copy);
      return idOf(base.actor, copy);
    };
    const rename = (r: typeof req, name: string, version: string) => {
      r.members[0]!.name = name;
      r.members[0]!.version = version;
      r.members[0]!.files[0]!.filename = `mojo-${name}-${version}-mojo1.0.0_0.conda`;
    };
    ids.add(edit((r) => rename(r, 'alpha', '1.0.1')));
    ids.add(edit((r) => rename(r, 'alpha2', '1.0.0')));
    ids.add(edit((r) => (r.members[0]!.files[0]!.subdir = 'noarch')));
    ids.add(edit((r) => (r.members[0]!.files[0]!.size = 1001)));
    ids.add(edit((r) => (r.members[0]!.files[0]!.sha256 = 'f'.repeat(64))));
    ids.add(edit((r) => (r.members[0]!.files[0]!.filename = 'mojo-alpha-1.0.0-mojo2.0.0_0.conda')));
    expect(ids.size).toBe(8);
  });

  test('the order of the members and files in the request, and the on_overlap option, are not part of the id', () => {
    const v = FIXTURE.vectors.find((x) => (x.request as { members: unknown[] }).members.length === 2)!;
    const req = v.request as { members: Array<{ files: unknown[] }> };
    const reversed = { members: [...req.members].reverse().map((m) => ({ ...m, files: [...m.files].reverse() })) };
    expect(idOf(v.actor, reversed)).toBe(v.group_id);
    expect(idOf(v.actor, { ...reversed, on_overlap: 'refuse' })).toBe(v.group_id);
    expect(idOf(v.actor, { ...(v.request as object), on_overlap: 'supersede' })).toBe(v.group_id);
  });
});

describe('the actor forms of the group id', () => {
  const principal = (over: Partial<Principal>) => ({ token_id: 'tok_1', kind: 'api', packages: [], scopes: [], ...over }) as unknown as Principal;

  test('an account is u:<github id>, a configured CI publisher is ci:gh-repo:<repository id> whichever token it holds, any other CI token is ci:<token id>', () => {
    expect(actorOf(principal({ github_id: 1234 }))).toBe('u:1234');
    expect(actorOf(principal({ kind: 'oidc', ci_owner: 'gh-repo:987654' }))).toBe('ci:gh-repo:987654');
    expect(actorOf(principal({ kind: 'oidc', ci_owner: 'gh-repo:987654', token_id: 'tok_2' }))).toBe('ci:gh-repo:987654');
    expect(actorOf(principal({ kind: 'oidc' }))).toBe('ci:tok_1');
    // A token that acts for an account is that account's actor.
    expect(actorOf(principal({ kind: 'oidc', github_id: 1234, acts_via: 'gh-repo:987654' }))).toBe('u:1234');
  });

  test('the vectors use the two forms that can create a group', () => {
    expect(FIXTURE.vectors.map((v) => v.actor.replace(/[0-9]+$/, '<n>'))).toEqual(expect.arrayContaining(['u:<n>', 'ci:gh-repo:<n>']));
  });
});

describe('the documentation states the derivation', () => {
  test('the OpenAPI description of createGroup quotes a vector\'s id and its canonical JSON, so a change of either is a change of the contract text', () => {
    const v = FIXTURE.vectors[0]!;
    expect(OPENAPI).toContain(v.group_id);
    expect(OPENAPI).toContain(v.canonical_json);
  });
});
