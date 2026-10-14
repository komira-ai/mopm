// T13: the install lines. A mopm.toml line appears only for a version mopm's requirement grammar can name as written
// (one to three numeric parts: src/core/semver.zig), so a conda-only spelling never yields a line mopm would refuse;
// a version page pins only a published version; the pixi command is the one spec/channel.md documents.
import { MANIFEST_VERSION, manifestRefusal, manifestSnippet, pinnedSnippet, pixiCommand, refusalSentence } from '../src/snippet';

describe('manifestSnippet (package page)', () => {
  test.each(['0.4.0', '1.0', '1', '10.20.30', '0.0.3'])('%s gives a line with the exact spelling', (v) => {
    expect(manifestSnippet('http_client', v)).toBe(`[dependencies]\nhttp_client = "${v}"`);
  });

  test.each([
    ['1.2.3.4', 'four parts'],
    ['1.0rc1', 'a conda pre-release suffix'],
    ['1.0dev0', 'a dev suffix'],
    ['01.2', 'a leading zero'],
    ['1.', 'a trailing dot'],
    ['1.0" evil = "x', 'TOML injection'],
    ['', 'empty'],
  ])('%s (%s) gives none', (v) => {
    expect(manifestSnippet('http_client', v)).toBeNull();
  });

  // semver.zig parses each part as a u64: 2^64-1 is the largest part mopm accepts.
  test.each(['18446744073709551615', '1.18446744073709551615', '0.0.18446744073709551615'])('%s (each part a u64) gives a line', (v) => {
    expect(manifestSnippet('http_client', v)).toBe(`[dependencies]\nhttp_client = "${v}"`);
  });

  test.each(['18446744073709551616', '1.18446744073709551616', '0.0.99999999999999999999'])('%s (a part over 2^64-1) gives none', (v) => {
    expect(manifestSnippet('http_client', v)).toBeNull();
  });

  test('no latest gives none', () => {
    expect(manifestSnippet('http_client', null)).toBeNull();
  });

  test('a name that is not a canonical package name gives none', () => {
    expect(manifestSnippet('Http-Client', '1.0')).toBeNull();
    expect(manifestSnippet('foo__bar', '1.0')).toBeNull();
    expect(manifestSnippet('a"\n[x]', '1.0')).toBeNull();
  });

  test('MANIFEST_VERSION is anchored at both ends', () => {
    expect(MANIFEST_VERSION.test('x1.0')).toBe(false);
    expect(MANIFEST_VERSION.test('1.0x')).toBe(false);
  });
});

describe('pinnedSnippet (version page)', () => {
  test('a published version is pinned with =', () => {
    expect(pinnedSnippet('http_client', '0.4.0', 'published')).toBe('[dependencies]\nhttp_client = "=0.4.0"');
  });

  // semver.zig compares only the parts a comparator has: '=1.2' matches 1.2.9, '=1.2.0' only 1.2.0.
  test.each([
    ['1.2', '=1.2.0'],
    ['1', '=1.0.0'],
    ['0.4', '=0.4.0'],
    ['10.20.30', '=10.20.30'],
  ])('a published %s is pinned on all three parts as %s', (v, req) => {
    expect(pinnedSnippet('http_client', v, 'published')).toBe(`[dependencies]\nhttp_client = "${req}"`);
  });

  test('a published version with a part over 2^64-1 gets none', () => {
    expect(pinnedSnippet('http_client', '1.18446744073709551616', 'published')).toBeNull();
    expect(pinnedSnippet('http_client', '1.18446744073709551615', 'published')).toBe('[dependencies]\nhttp_client = "=1.18446744073709551615.0"');
  });

  test.each(['yanked', 'tombstoned', 'unknown'] as const)('a %s version gets none', (state) => {
    expect(pinnedSnippet('http_client', '0.4.0', state)).toBeNull();
  });

  test.each(['1.2.3.4', '1.0rc1'])('a published %s gets none', (v) => {
    expect(pinnedSnippet('http_client', v, 'published')).toBeNull();
  });
});

describe('why there is no mopm.toml line', () => {
  test.each([
    ['1.2.3', null],
    ['1.2.3.4', 'parts'],
    ['1.0rc1', 'suffix'],
    ['1.0dev0', 'suffix'],
    ['1.0a1', 'suffix'],
    ['1.2.3.4b2', 'suffix'],
    ['18446744073709551616', 'too-large'],
  ] as const)('%s: %s', (v, why) => {
    expect(manifestRefusal(v)).toBe(why);
  });

  test('the sentence names the cause', () => {
    expect(refusalSentence('Version 1.0rc1', '1.0rc1')).toBe('Version 1.0rc1 has a conda pre-release suffix, which a mopm.toml requirement cannot name.');
    expect(refusalSentence('Version 1.2.3.4', '1.2.3.4')).toBe('Version 1.2.3.4 has more than three numeric parts, which a mopm.toml requirement cannot name.');
    expect(refusalSentence('V', '18446744073709551616')).toBe('V has a part larger than a mopm.toml requirement allows (2^64-1).');
    expect(refusalSentence('V', '1.2')).toBeNull();
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
