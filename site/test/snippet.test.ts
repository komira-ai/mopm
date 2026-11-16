// T13: the install lines. A registry version is MAJOR.MINOR.PATCH (spec Version); a mopm.toml line appears only for
// a version mopm's requirement grammar can name as written (each part a u64: src/core/semver.zig), so a spelling
// outside the grammar never yields a line mopm would refuse; a version page pins only a published version; the pixi
// command is the one spec/channel.md documents.
import {
  channelAddCommand, condaName, manifestRefusal, manifestSnippet, namespaceChannel, otherChannels, pinnedSnippet, pixiCommands,
  refusalSentence,
} from '../src/snippet';

const F = { namespace: 'komira-ai', name: 'http_client' };
const KEY = '"komira-ai/http_client"';

describe('manifestSnippet (package page)', () => {
  test.each(['0.4.0', '1.0.0', '10.20.30', '0.0.3'])('%s gives a line with the exact spelling', (v) => {
    expect(manifestSnippet(F, v)).toBe(`[dependencies]\n${KEY} = "${v}"`);
  });

  test.each([
    ['1', 'one part'],
    ['1.0', 'two parts'],
    ['1.2.3.4', 'four parts'],
    ['1.0.0rc1', 'a suffix'],
    ['1.0.0-rc.1', 'a pre-release'],
    ['01.2.0', 'a leading zero'],
    ['1.2.', 'a trailing dot'],
    ['1.0.0" evil = "x', 'TOML injection'],
    ['', 'empty'],
  ])('%s (%s) gives none', (v) => {
    expect(manifestSnippet(F, v)).toBeNull();
  });

  // semver.zig parses each part as a u64: 2^64-1 is the largest part mopm accepts.
  test.each(['18446744073709551615.0.0', '1.18446744073709551615.0', '0.0.18446744073709551615'])('%s (each part a u64) gives a line', (v) => {
    expect(manifestSnippet(F, v)).toBe(`[dependencies]\n${KEY} = "${v}"`);
  });

  test.each(['18446744073709551616.0.0', '1.18446744073709551616.0', '0.0.99999999999999999999'])('%s (a part over 2^64-1) gives none', (v) => {
    expect(manifestSnippet(F, v)).toBeNull();
  });

  test('no latest gives none', () => {
    expect(manifestSnippet(F, null)).toBeNull();
  });

  test('the key is the quoted full name, so a TOML parser reads one key and not a table path', () => {
    expect(manifestSnippet({ namespace: 'alice', name: 'json' }, '0.3.0')).toBe('[dependencies]\n"alice/json" = "0.3.0"');
  });

  test('the same name in two namespaces gives two different keys', () => {
    expect(manifestSnippet({ namespace: 'alice', name: 'json' }, '1.0.0')).not.toBe(manifestSnippet({ namespace: 'komira-ai', name: 'json' }, '1.0.0'));
  });

  test('a name that is not a canonical package name gives none', () => {
    for (const name of ['Http-Client', 'foo__bar', 'a"\n[x]', 'a/b', '', 'x']) {
      expect(manifestSnippet({ namespace: 'komira-ai', name }, '1.0.0')).toBeNull();
    }
  });

  test('a namespace that is not a namespace gives none', () => {
    for (const namespace of ['Komira-AI', 'komira--ai', '-komira', 'komira-', 'a/b', 'a"b', 'a b', 'a\nb', '', 'a'.repeat(40)]) {
      expect(manifestSnippet({ namespace, name: 'json' }, '1.0.0')).toBeNull();
    }
  });

  test('a namespace of the longest length (39) still gets a line, and a one-character one too', () => {
    const long = 'a'.repeat(39);
    expect(manifestSnippet({ namespace: long, name: 'json' }, '1.0.0')).toBe(`[dependencies]\n"${long}/json" = "1.0.0"`);
    expect(manifestSnippet({ namespace: '7', name: 'json' }, '1.0.0')).toBe('[dependencies]\n"7/json" = "1.0.0"');
  });

  test('the grammar is anchored at both ends', () => {
    expect(manifestSnippet(F, 'x1.0.0')).toBeNull();
    expect(manifestSnippet(F, '1.0.0x')).toBeNull();
  });
});

describe('pinnedSnippet (version page)', () => {
  test.each(['0.4.0', '10.20.30', '0.0.0'])('a published %s is pinned with =, as written', (v) => {
    expect(pinnedSnippet(F, v, 'published')).toBe(`[dependencies]\n${KEY} = "=${v}"`);
  });

  test('a published version with a part over 2^64-1 gets none', () => {
    expect(pinnedSnippet(F, '1.18446744073709551616.0', 'published')).toBeNull();
    expect(pinnedSnippet(F, '1.18446744073709551615.0', 'published')).toBe(`[dependencies]\n${KEY} = "=1.18446744073709551615.0"`);
  });

  test.each(['yanked', 'tombstoned', 'unknown'] as const)('a %s version gets none', (state) => {
    expect(pinnedSnippet(F, '0.4.0', state)).toBeNull();
  });

  test.each(['1.2', '1.2.3.4', '1.0rc1'])('a published %s (outside the grammar) gets none', (v) => {
    expect(pinnedSnippet(F, v, 'published')).toBeNull();
  });
});

describe('pinnedSnippet refusals (full names)', () => {
  test('a pinned line uses the quoted full-name key', () => {
    expect(pinnedSnippet({ namespace: 'alice', name: 'json' }, '0.3.0', 'published')).toBe('[dependencies]\n"alice/json" = "=0.3.0"');
  });

  test('an invalid namespace or a non-canonical name gets none, even for a published version', () => {
    expect(pinnedSnippet({ namespace: 'Alice', name: 'json' }, '0.3.0', 'published')).toBeNull();
    expect(pinnedSnippet({ namespace: 'alice', name: 'Json' }, '0.3.0', 'published')).toBeNull();
    expect(pinnedSnippet({ namespace: 'alice', name: 'a/b' }, '0.3.0', 'published')).toBeNull();
    expect(pinnedSnippet({ namespace: 'a'.repeat(40), name: 'json' }, '0.3.0', 'published')).toBeNull();
  });

  test('a state that is not published gets none, however valid the name', () => {
    expect(pinnedSnippet({ namespace: 'alice', name: 'json' }, '0.3.0', 'yanked')).toBeNull();
  });
});

describe('why there is no mopm.toml line', () => {
  test.each([
    ['1.2.3', null],
    ['1.2', 'not-a-version'],
    ['1.2.3.4', 'not-a-version'],
    ['1.0rc1', 'not-a-version'],
    ['18446744073709551616.0.0', 'too-large'],
  ] as const)('%s: %s', (v, why) => {
    expect(manifestRefusal(v)).toBe(why);
  });

  test('the sentence names the cause', () => {
    expect(refusalSentence('Version 1.2', '1.2')).toBe('Version 1.2 is not a MAJOR.MINOR.PATCH version, which a mopm.toml requirement needs.');
    expect(refusalSentence('V', '18446744073709551616.0.0')).toBe('V has a part larger than a mopm.toml requirement allows (2^64-1).');
    expect(refusalSentence('V', '1.2.0')).toBeNull();
  });
});

describe('condaName', () => {
  test('is mojo-<namespace>.<name>', () => {
    expect(condaName(F)).toBe('mojo-komira-ai.http_client');
    expect(condaName({ namespace: 'alice', name: 'json' })).toBe('mojo-alice.json');
  });

  test('the same name in two namespaces is two conda names', () => {
    expect(condaName({ namespace: 'alice', name: 'json' })).not.toBe(condaName({ namespace: 'bob', name: 'json' }));
  });
});

describe('namespaceChannel and channelAddCommand', () => {
  test('the channel is the stage root plus the namespace and a slash', () => {
    expect(namespaceChannel('https://conda.mopm.dev/', 'komira-ai')).toBe('https://conda.mopm.dev/komira-ai/');
    expect(namespaceChannel('https://conda.beta.mopm.dev/', 'a')).toBe('https://conda.beta.mopm.dev/a/');
  });

  test('the command adds that channel to the pixi workspace', () => {
    expect(channelAddCommand('https://conda.mopm.dev/komira-ai/')).toBe('pixi workspace channel add https://conda.mopm.dev/komira-ai/');
  });
});

describe('otherChannels', () => {
  const base = 'https://conda.mopm.dev/';

  test('no dependencies need no channel', () => {
    expect(otherChannels(base, 'komira-ai', [])).toEqual([]);
  });

  test('dependencies in the own namespace need none', () => {
    expect(otherChannels(base, 'komira-ai', ['komira-ai/json', 'komira-ai/tls'])).toEqual([]);
  });

  test('each other namespace is listed once, sorted', () => {
    expect(otherChannels(base, 'komira-ai', ['zed/aa', 'alice/json', 'zed/bb', 'alice/yaml', 'komira-ai/tls', 'bob/xx'])).toEqual([
      'https://conda.mopm.dev/alice/',
      'https://conda.mopm.dev/bob/',
      'https://conda.mopm.dev/zed/',
    ]);
  });

  test('a dependency that is not a full name is skipped, and the rest still count', () => {
    expect(otherChannels(base, 'komira-ai', ['json', 'Alice/json', 'alice/Json', 'alice/a/b', '', 'a"b/c', 'bob/ok'])).toEqual(['https://conda.mopm.dev/bob/']);
  });

  test('only skipped dependencies give none', () => {
    expect(otherChannels(base, 'komira-ai', ['flat', 'a/B'])).toEqual([]);
  });
});

describe('pixiCommands', () => {
  const base = 'https://conda.mopm.dev/';

  test('without dependencies: add the namespace channel, then the package', () => {
    expect(pixiCommands(base, F)).toEqual(['pixi workspace channel add https://conda.mopm.dev/komira-ai/', 'pixi add mojo-komira-ai.http_client']);
  });

  test('an empty dependency list is the same as none', () => {
    expect(pixiCommands(base, F, [])).toEqual(pixiCommands(base, F));
  });

  test('with dependencies in other namespaces: own channel first, then theirs sorted, then the package', () => {
    expect(pixiCommands(base, F, ['zed/aa', 'alice/json', 'komira-ai/tls', 'alice/yaml'])).toEqual([
      'pixi workspace channel add https://conda.mopm.dev/komira-ai/',
      'pixi workspace channel add https://conda.mopm.dev/alice/',
      'pixi workspace channel add https://conda.mopm.dev/zed/',
      'pixi add mojo-komira-ai.http_client',
    ]);
  });

  test('dependencies outside the grammar add no channel', () => {
    expect(pixiCommands(base, F, ['flat', 'X/y'])).toEqual(pixiCommands(base, F));
  });

  test('a name or namespace outside the grammar gets none, whatever the dependencies', () => {
    expect(pixiCommands(base, { namespace: 'komira-ai', name: 'Http; rm -rf x' })).toBeNull();
    expect(pixiCommands(base, { namespace: 'Komira-AI', name: 'json' }, ['bob/xx'])).toBeNull();
    expect(pixiCommands(base, { namespace: 'a b', name: 'json' })).toBeNull();
    expect(pixiCommands(base, { namespace: 'a'.repeat(40), name: 'json' })).toBeNull();
  });
});
