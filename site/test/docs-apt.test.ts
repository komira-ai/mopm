// The apt install instructions name the archive keyring that the repository really serves, install it where the
// source's Signed-By points, and use a deb822 source. These tests read the documents that carry the commands
// (RELEASING.md, docs/getting-started.md), and every text that could still carry an older command (README, all
// docs, the install script, the site's sources), and fail when a command and the repository disagree.
import { readFileSync, readdirSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './build-fixture';

const read = (p: string): string => readFileSync(join(REPO_ROOT, p), 'utf8');

/** The one object the repository publishes the keyring as: key `apt/komira-archive-keyring.gpg` on this host. */
const HOST = 'packages.komira.ai';
const KEYRING_OBJECT = 'apt/komira-archive-keyring.gpg';
const KEYRING_URL = `https://${HOST}/${KEYRING_OBJECT}`;

/** The documents that carry the install commands. */
const INSTALL_DOCS = ['RELEASING.md', 'docs/getting-started.md'];

/** Every file of a directory of the repository, recursively, as repository paths. */
function filesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(join(REPO_ROOT, dir), { withFileTypes: true })) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory()) out.push(...filesUnder(p));
    else out.push(p);
  }
  return out;
}

/** Every text that may mention the apt repository: the install script's messages, all docs and the site's sources. */
const SCANNED = ['README.md', 'RELEASING.md', ...filesUnder('docs'), ...filesUnder('site/static').filter((p) => p.endsWith('.sh')), ...filesUnder('site/tools'), ...filesUnder('site/src')];

/** The keyring download command of a document: `curl ... -o <install path> <url>`. */
const KEYRING_COMMAND = /curl [^\n]*-o (\S+) (https:\/\/\S+)/g;

describe('the apt install instructions', () => {
  test.each(INSTALL_DOCS)('%s downloads the keyring from the one object the repository publishes, once', (doc) => {
    const cmds = [...read(doc).matchAll(KEYRING_COMMAND)];
    expect(cmds.length).toBe(1);
    const url = new URL(cmds[0][2]);
    expect({ host: url.host, key: url.pathname.slice(1), scheme: url.protocol }).toEqual({ host: HOST, key: KEYRING_OBJECT, scheme: 'https:' });
    expect(cmds[0][2]).toBe(KEYRING_URL);
  });

  test.each(INSTALL_DOCS)('%s writes a deb822 source whose Signed-By is the path the keyring is installed to', (doc) => {
    const text = read(doc);
    const installPath = [...text.matchAll(KEYRING_COMMAND)][0][1];
    expect(installPath).toMatch(/^\/etc\/apt\/keyrings\/[a-z0-9-]+\.gpg$/);

    // the source file is a .sources file under sources.list.d, written by tee
    const tee = /tee (\/etc\/apt\/sources\.list\.d\/[a-z0-9-]+\.sources)\b/.exec(text);
    expect(tee).not.toBeNull();

    // its stanza, from the line after the here-document opener to the terminator
    const stanza = /<<.EOF.\n([\s\S]*?)\nEOF\n/.exec(text);
    expect(stanza).not.toBeNull();
    const fields = new Map<string, string>();
    for (const line of (stanza as RegExpExecArray)[1].split('\n')) {
      const m = /^([A-Za-z-]+): (.+)$/.exec(line);
      expect(m).not.toBeNull();
      fields.set((m as RegExpExecArray)[1], (m as RegExpExecArray)[2]);
    }
    expect(Object.fromEntries(fields)).toEqual({
      Types: 'deb',
      URIs: `https://${HOST}/apt`,
      Suites: 'stable',
      Components: 'main',
      'Signed-By': installPath,
    });
  });

  test('both documents give the same commands', () => {
    const cmd = (doc: string): string => /sudo install -d[\s\S]*?\nEOF\n/.exec(read(doc))?.[0] ?? '';
    expect(cmd(INSTALL_DOCS[0]).length).toBeGreaterThan(100);
    expect(cmd(INSTALL_DOCS[0])).toBe(cmd(INSTALL_DOCS[1]));
  });
});

describe('no text mentions an apt path the repository does not serve', () => {
  const STALE: [string, RegExp][] = [
    ['the keyring as apt/keyring.gpg', /\/apt\/keyring\.gpg/],
    ['the keyring installed as packages.gpg', /packages\.gpg/],
    ['a one-line source file (.list)', /sources\.list\.d\/[A-Za-z0-9._-]*\.list\b/],
    ['a one-line deb entry with signed-by', /deb \[signed-by=/],
    ['apt-key', /apt-key/],
    ['the keyring served under any name but the published one', /packages\.komira\.ai\/apt\/(?!komira-archive-keyring\.(?:gpg|asc)\b|dists\/)[A-Za-z0-9._-]*\.(?:gpg|asc)\b/],
  ];

  test('the scanned set holds the install documents, the install script and the site sources', () => {
    for (const p of [...INSTALL_DOCS, 'README.md', 'docs/getting-started.md', 'site/static/install.sh', 'site/tools/pages.ts']) expect(SCANNED).toContain(p);
  });

  test.each(STALE)('nothing mentions %s', (_name, re) => {
    const hits = SCANNED.filter((p) => re.test(read(p)));
    expect(hits).toEqual([]);
  });
});
