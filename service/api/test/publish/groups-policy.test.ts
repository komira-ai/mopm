import { GROUPS_POLICY_ENV, parseStaticGroupsPolicy, policyAllows } from '../../src/publish/flags';
import { flagsFor } from '../../src/publish/wiring';
import { FakeDoc } from './fake-doc';

// MOPM_GROUPS_POLICY: the static groups policy of the beta stage, config as code. What these prove: it loads on beta only (the
// function does not start with it anywhere else), it can name CI identities and nothing wider, a malformed value is refused whole,
// and, wired as the API function wires it, it admits exactly its actors next to the runtime item of the config table, which
// cannot switch it off.

const ACTOR = 'ci:gh-repo:1376408823';
const policy = (over: Record<string, unknown> = {}) => JSON.stringify({ mode: 'allow', actors: [ACTOR], ...over });

describe('parseStaticGroupsPolicy: the stage gate', () => {
  test('absent or empty is off, on every stage', () => {
    for (const stage of ['beta', 'gamma', 'prod']) {
      expect(parseStaticGroupsPolicy(stage, undefined)).toEqual({ mode: 'off' });
      expect(parseStaticGroupsPolicy(stage, '')).toEqual({ mode: 'off' });
    }
  });

  test('beta loads the allow list', () => {
    const p = parseStaticGroupsPolicy('beta', policy());
    expect(p).toEqual({ mode: 'allow', actors: [ACTOR], deny: [] });
    expect(policyAllows(p, ACTOR)).toBe(true);
    expect(policyAllows(p, 'ci:gh-repo:999')).toBe(false);
    expect(policyAllows(p, 'u:1')).toBe(false);
  });

  test.each(['gamma', 'prod', 'dev', 'Beta', ''])('stage %j refuses to load a value, even a valid one', (stage) => {
    expect(() => parseStaticGroupsPolicy(stage, policy())).toThrow(/beta stage only/);
  });
});

describe('parseStaticGroupsPolicy: a malformed or wider value is refused whole', () => {
  const cases: Array<[string, string]> = [
    ['not JSON', '{'],
    ['an array', '[]'],
    ['null', 'null'],
    ['mode all', JSON.stringify({ mode: 'all' })],
    ['mode off', JSON.stringify({ mode: 'off', actors: [ACTOR] })],
    ['no mode', JSON.stringify({ actors: [ACTOR] })],
    ['no actors', JSON.stringify({ mode: 'allow' })],
    ['an empty actor list', policy({ actors: [] })],
    ['too many actors', policy({ actors: Array.from({ length: 9 }, (_x, i) => `ci:gh-repo:${100 + i}`) })],
    ['an account actor', policy({ actors: ['u:1'] })],
    ['a token actor', policy({ actors: ['ci:tok_abc'] })],
    ['an actor with a repository name', policy({ actors: ['ci:gh-repo:komira-ai/komira'] })],
    ['an actor with a leading zero id', policy({ actors: ['ci:gh-repo:0123'] })],
    ['an actor that is not a string', policy({ actors: [1376408823] })],
    ['a repeated actor', policy({ actors: [ACTOR, ACTOR] })],
    ['a deny list', policy({ deny: [ACTOR] })],
    ['an unknown key', policy({ everyone: true })],
  ];
  test.each(cases)('%s', (_n, raw) => {
    expect(() => parseStaticGroupsPolicy('beta', raw)).toThrow(new RegExp(`${GROUPS_POLICY_ENV} is not valid`));
  });
});

describe('flagsFor: the policy as the API function wires it', () => {
  const docWith = (item?: Record<string, unknown>) => {
    const doc = new FakeDoc({ 'mopm-beta-config': 'key' });
    if (item) doc.table('mopm-beta-config').set('groups_enabled', { key: 'groups_enabled', ...item });
    return doc as never;
  };
  const env = { [GROUPS_POLICY_ENV]: policy() };

  test('on beta it admits exactly the named identity, and nobody else', async () => {
    const flags = flagsFor(env, docWith(), 'beta');
    expect(await flags.groupsFor(ACTOR)).toBe(true);
    for (const other of ['ci:gh-repo:999', 'ci:tok_abc', 'u:1', '']) expect(await flags.groupsFor(other)).toBe(false);
    expect(await flags.readOnly()).toBe(false);
  });

  test('without the variable groups are off, as before', async () => {
    const flags = flagsFor({}, docWith(), 'beta');
    expect(await flags.groupsFor(ACTOR)).toBe(false);
  });

  test('gamma and prod throw when the variable is set: the function does not start', () => {
    for (const stage of ['gamma', 'prod']) expect(() => flagsFor(env, docWith(), stage)).toThrow(/beta stage only/);
  });

  test('the item of the config table adds to the policy, and its deny does not remove the identity (stopping it takes a deploy)', async () => {
    const flags = flagsFor(env, docWith({ mode: 'allow', actors: ['u:1'], deny: [ACTOR] }), 'beta');
    expect(await flags.groupsFor('u:1')).toBe(true); // the human flip still works next to it
    expect(await flags.groupsFor(ACTOR)).toBe(true); // a deny in the table does not override the static policy
  });

  test('read-only mode is unchanged by the policy', async () => {
    const flags = flagsFor({ ...env, MOPM_READ_ONLY: 'true' }, docWith(), 'beta');
    expect(await flags.readOnly()).toBe(true);
  });
});
