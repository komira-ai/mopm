import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { RegistryError } from '../../src/errors';
import { DEFAULT_PUBLISH_CONFIG } from '../../src/publish/config';
import { PublishError } from '../../src/publish/errors';
import { parseGroupCommit } from './v0.0.104/group-commit';
import { groupIdFor, parseGroupRequest } from './v0.0.104/group-request';

/**
 * This command line's requests through the previous release's parsers (test/compat/v0.0.104, pinned; README.md there). The bodies are
 * the files test/fixtures/new-client/{create,commit}.json, which //:compat_v0_0_104 holds to what the current client sends for a set
 * (alpha with a readme, beta with an empty one, gamma with none), and test/fixtures/released-client-v0.0.104/ for the released client's
 * own requests for the same set. The current client names members by full name (docs/design/namespaces.md, section 11): the previous
 * registry refuses its create request instead of misreading it.
 */

const VENDORED = join(__dirname, 'v0.0.104');
const FIXTURES = join(__dirname, '..', 'fixtures');
const fixture = (dir: string, name: string): unknown => JSON.parse(readFileSync(join(FIXTURES, dir, name), 'utf8'));

test('the vendored parsers are the files SHA256SUMS names', () => {
  const lines = readFileSync(join(VENDORED, 'SHA256SUMS'), 'utf8').split('\n').filter((l) => l !== '');
  expect(lines.map((l) => l.slice(66)).sort()).toEqual(['group-commit.ts', 'group-request.ts']);
  for (const line of lines) {
    expect(createHash('sha256').update(readFileSync(join(VENDORED, line.slice(66)))).digest('hex')).toBe(line.slice(0, 64));
  }
});

describe('the create request of the current client, read by the previous registry', () => {
  test('the released client\'s request for the set is read, with its flat names', () => {
    const released = parseGroupRequest(DEFAULT_PUBLISH_CONFIG, fixture('released-client-v0.0.104', 'create.json'));
    expect(released.members.map((m) => m.name)).toEqual(['alpha', 'beta', 'gamma']);
    expect(groupIdFor('octocat', released)).toMatch(/^[0-9a-f]{64}$/);
  });

  test('is refused as invalid_name, naming the first member\'s full name: a full name is never misread as a flat one', () => {
    const body = fixture('new-client', 'create.json') as { members: Array<{ name: string; readme?: unknown }> };
    // The current client names every member by its full name, and declares the readme of alpha.
    expect(body.members.map((m) => m.name)).toEqual(['example/alpha', 'example/beta', 'example/gamma']);
    expect(body.members[0]!.readme).toEqual({ sha256: expect.stringMatching(/^[0-9a-f]{64}$/), size: expect.any(Number) });
    let refused: unknown;
    try {
      parseGroupRequest(DEFAULT_PUBLISH_CONFIG, body);
    } catch (e) {
      refused = e;
    }
    expect(refused).toBeInstanceOf(RegistryError);
    expect((refused as RegistryError).code).toBe('invalid_name');
    expect((refused as RegistryError).message).toBe("'example/alpha' is not a valid package name.");
    expect((refused as RegistryError).detail).toEqual({ name: 'example/alpha' });
  });
});

describe('the commit request of the current client, read by the previous registry', () => {
  const members = { members: ['alpha', 'beta', 'gamma'].map((name) => ({ name, version: '1.0.0', canonical: '1.0.0', subdirs: ['noarch'] })) };

  test('the inline form (the released client\'s) is accepted, and carries each readme into the stored input', () => {
    const { inputs } = parseGroupCommit(members, fixture('released-client-v0.0.104', 'commit.json'));
    expect(inputs.map((i) => [i.name, i.display?.readme])).toEqual([['alpha', '# Alpha "quoted"\nline é 日本 😀 \\ end\n'], ['beta', ''], ['gamma', undefined]]);
  });

  test('the objects form is refused as invalid_request about the readme: the previous registry never commits a member without its readme', () => {
    let refused: unknown;
    try {
      parseGroupCommit(members, fixture('new-client', 'commit.json'));
    } catch (e) {
      refused = e;
    }
    expect(refused).toBeInstanceOf(PublishError);
    expect((refused as PublishError).code).toBe('invalid_request');
    expect((refused as PublishError).message).toContain("'readme' is a string");
  });
});
