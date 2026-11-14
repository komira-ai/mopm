import { channelFileKey, channelFileUrl, channelNamespaceOf, inChannel, parseRepodataDir, repodataDir, repodataDirOf, repodataDirsOf } from '../src/channel-paths';
import { SUBDIRS_V1 } from '../src/types';

describe('the channel of a name', () => {
  test('a full name is in its namespace, a flat name in the root', () => {
    expect(channelNamespaceOf('komira-ai/json')).toBe('komira-ai');
    expect(channelNamespaceOf('json')).toBeUndefined();
  });
  test('a string that is not a full name is in the root (it has no namespace)', () => {
    expect(channelNamespaceOf('Komira/json')).toBeUndefined();
    expect(channelNamespaceOf('a/b/c')).toBeUndefined();
  });
  test('inChannel: a namespace holds its own full names only; the root holds flat names only', () => {
    expect(inChannel('komira-ai/json', 'komira-ai')).toBe(true);
    expect(inChannel('acme/json', 'komira-ai')).toBe(false);
    expect(inChannel('json', 'komira-ai')).toBe(false);
    expect(inChannel('json', undefined)).toBe(true);
    expect(inChannel('komira-ai/json', undefined)).toBe(false);
  });
});

describe('repodata directories', () => {
  test.each(SUBDIRS_V1)('repodataDirOf: %s is the subdir for a flat name and <namespace>/<subdir> for a full one', (subdir) => {
    expect(repodataDirOf('json', subdir)).toBe(subdir);
    expect(repodataDirOf('komira-ai/json', subdir)).toBe(`komira-ai/${subdir}`);
  });
  test('repodataDir: the root when the namespace is undefined', () => {
    expect(repodataDir(undefined, 'noarch')).toBe('noarch');
    expect(repodataDir('acme', 'noarch')).toBe('acme/noarch');
  });
  test('repodataDirsOf: sorted, one per directory, and the two channels of one subdir stay apart', () => {
    expect(repodataDirsOf('komira-ai/json', ['osx-arm64', 'linux-64', 'osx-arm64'])).toEqual(['komira-ai/linux-64', 'komira-ai/osx-arm64']);
    expect(repodataDirsOf('json', new Set(['noarch', 'linux-64']))).toEqual(['linux-64', 'noarch']);
    expect(repodataDirsOf('json', [])).toEqual([]);
  });
});

describe('parseRepodataDir', () => {
  test.each(SUBDIRS_V1)('a plain subdir (%s) is the root', (subdir) => {
    expect(parseRepodataDir(subdir)).toEqual({ subdir });
  });
  test.each(SUBDIRS_V1)('<namespace>/%s is that namespace', (subdir) => {
    expect(parseRepodataDir(`komira-ai/${subdir}`)).toEqual({ namespace: 'komira-ai', subdir });
  });
  test('what repodataDirOf writes reads back', () => {
    for (const name of ['json', 'a/xy', 'komira-ai/json']) {
      for (const subdir of SUBDIRS_V1) {
        const dir = repodataDirOf(name, subdir);
        const parsed = parseRepodataDir(dir);
        expect(parsed?.subdir).toBe(subdir);
        expect(parsed?.namespace).toBe(channelNamespaceOf(name));
      }
    }
  });
  test('a namespace of 39 characters is accepted, of 40 refused', () => {
    expect(parseRepodataDir(`${'n'.repeat(39)}/noarch`)).toEqual({ namespace: 'n'.repeat(39), subdir: 'noarch' });
    expect(parseRepodataDir(`${'n'.repeat(40)}/noarch`)).toBeUndefined();
  });
  test.each([
    ['empty', ''],
    ['an unknown subdir', 'win-64'],
    ['an unknown subdir in a namespace', 'komira-ai/win-64'],
    ['a namespace alone', 'komira-ai'],
    ['an empty namespace', '/noarch'],
    ['an empty subdir', 'komira-ai/'],
    ['two slashes', 'komira-ai/linux-64/x'],
    ['two slashes, namespace first', 'a/b/noarch'],
    ['an upper-case namespace', 'Komira/noarch'],
    ['a namespace starting with a dash', '-ab/noarch'],
    ['a namespace ending with a dash', 'ab-/noarch'],
    ['a namespace with a double dash', 'a--b/noarch'],
    ['an underscore in the namespace', 'a_b/noarch'],
    ['a dot-dot namespace', '../noarch'],
    ['a trailing slash', 'noarch/'],
    ['a leading slash', '/linux-64'],
  ])('refuses %s', (_, dir) => {
    expect(parseRepodataDir(dir)).toBeUndefined();
  });
});

describe('package file keys and urls', () => {
  test('the key is <repodata dir>/<filename>', () => {
    expect(channelFileKey('json', 'linux-64', 'mojo-json-1.0.0-b.conda')).toBe('linux-64/mojo-json-1.0.0-b.conda');
    expect(channelFileKey('komira-ai/json', 'linux-64', 'mojo-komira-ai.json-1.0.0-b.conda')).toBe('komira-ai/linux-64/mojo-komira-ai.json-1.0.0-b.conda');
  });
  test('the url is the channel url (with or without its trailing slash) and the key', () => {
    for (const base of ['https://conda.mopm.dev', 'https://conda.mopm.dev/', 'https://conda.mopm.dev//']) {
      expect(channelFileUrl(base, 'komira-ai/json', 'noarch', 'f.conda')).toBe('https://conda.mopm.dev/komira-ai/noarch/f.conda');
      expect(channelFileUrl(base, 'json', 'noarch', 'f.conda')).toBe('https://conda.mopm.dev/noarch/f.conda');
    }
  });
});
