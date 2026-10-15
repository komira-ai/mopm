// T13: the install lines. A registry version is MAJOR.MINOR.PATCH (spec Version); a mopm.toml line appears only for
// a version mopm's requirement grammar can name as written (each part a u64: src/core/semver.zig), so a spelling
// outside the grammar never yields a line mopm would refuse; a version page pins only a published version; the pixi
// command is the one spec/channel.md documents.
import { manifestRefusal, manifestSnippet, pinnedSnippet, pixiCommand, refusalSentence } from '../src/snippet';

describe('manifestSnippet (package page)', () => {
  test.each(['0.4.0', '1.0.0', '10.20.30', '0.0.3'])('%s gives a line with the exact spelling', (v) => {
    expect(manifestSnippet('http_client', v)).toBe(`[dependencies]\nhttp_client = "${v}"`);
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
    expect(manifestSnippet('http_client', v)).toBeNull();
  });

  // semver.zig parses each part as a u64: 2^64-1 is the largest part mopm accepts.
  test.each(['18446744073709551615.0.0', '1.18446744073709551615.0', '0.0.18446744073709551615'])('%s (each part a u64) gives a line', (v) => {
    expect(manifestSnippet('http_client', v)).toBe(`[dependencies]\nhttp_client = "${v}"`);
  });

  test.each(['18446744073709551616.0.0', '1.18446744073709551616.0', '0.0.99999999999999999999'])('%s (a part over 2^64-1) gives none', (v) => {
    expect(manifestSnippet('http_client', v)).toBeNull();
  });

  test('no latest gives none', () => {
    expect(manifestSnippet('http_client', null)).toBeNull();
  });

  test('a name that is not a canonical package name gives none', () => {
    expect(manifestSnippet('Http-Client', '1.0.0')).toBeNull();
    expect(manifestSnippet('foo__bar', '1.0.0')).toBeNull();
    expect(manifestSnippet('a"\n[x]', '1.0.0')).toBeNull();
  });

  test('the grammar is anchored at both ends', () => {
    expect(manifestSnippet('http_client', 'x1.0.0')).toBeNull();
    expect(manifestSnippet('http_client', '1.0.0x')).toBeNull();
  });
});

describe('pinnedSnippet (version page)', () => {
  test.each(['0.4.0', '10.20.30', '0.0.0'])('a published %s is pinned with =, as written', (v) => {
    expect(pinnedSnippet('http_client', v, 'published')).toBe(`[dependencies]\nhttp_client = "=${v}"`);
  });

  test('a published version with a part over 2^64-1 gets none', () => {
    expect(pinnedSnippet('http_client', '1.18446744073709551616.0', 'published')).toBeNull();
    expect(pinnedSnippet('http_client', '1.18446744073709551615.0', 'published')).toBe('[dependencies]\nhttp_client = "=1.18446744073709551615.0"');
  });

  test.each(['yanked', 'tombstoned', 'unknown'] as const)('a %s version gets none', (state) => {
    expect(pinnedSnippet('http_client', '0.4.0', state)).toBeNull();
  });

  test.each(['1.2', '1.2.3.4', '1.0rc1'])('a published %s (outside the grammar) gets none', (v) => {
    expect(pinnedSnippet('http_client', v, 'published')).toBeNull();
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

describe('pixiCommand', () => {
  test('is pixi add mojo-<name> for any canonical name, whatever its versions', () => {
    expect(pixiCommand('http_client')).toBe('pixi add mojo-http_client');
    expect(pixiCommand('tls')).toBe('pixi add mojo-tls');
  });

  test('a name that is not canonical gets none', () => {
    expect(pixiCommand('Http; rm -rf x')).toBeNull();
  });
});
