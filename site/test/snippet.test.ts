// T13: the install lines. A mopm.toml line appears only for a version mopm's requirement grammar can name as written
// (one to three numeric parts: src/core/semver.zig), so a conda-only spelling never yields a line mopm would refuse;
// a version page pins only a published version; the pixi command is the one spec/channel.md documents.
import { MANIFEST_VERSION, manifestSnippet, pinnedSnippet, pixiCommand } from '../src/snippet';

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

  test.each(['yanked', 'tombstoned', 'unknown'] as const)('a %s version gets none', (state) => {
    expect(pinnedSnippet('http_client', '0.4.0', state)).toBeNull();
  });

  test.each(['1.2.3.4', '1.0rc1'])('a published %s gets none', (v) => {
    expect(pinnedSnippet('http_client', v, 'published')).toBeNull();
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
