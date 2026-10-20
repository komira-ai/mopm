// The home page's internal links all land on a page the build writes (or the app shell), and the two facts a reader acts
// on, where releases are and which platforms the installer serves, are pinned.
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { REPO_URL } from '../src/links';
import { parseRoute } from '../src/routes';
import { cleanup, type Fixture, fixture } from './build-fixture';

let f: Fixture;
let home: string;
beforeAll(() => {
  f = fixture();
  f.build();
  home = readFileSync(join(f.outDir, 'index.html'), 'utf8');
});
afterAll(() => cleanup(f));

const hrefs = () => [...home.matchAll(/<a [^>]*?href="([^"]*)"/g)].map((m) => m[1].replace(/&amp;/g, '&'));

test('the home page has internal links to check', () => {
  expect(hrefs().filter((h) => h.startsWith('/')).length).toBeGreaterThan(3);
});

test('every internal href of the home page resolves to a built page or an app route', () => {
  const bad: string[] = [];
  for (const h of hrefs().filter((x) => x.startsWith('/'))) {
    const path = h.split('#')[0].split('?')[0];
    const built = path.endsWith('/') ? join(f.outDir, path, 'index.html') : join(f.outDir, path);
    if (!existsSync(built) && parseRoute(path) === null) bad.push(h);
  }
  expect(bad).toEqual([]);
});

test('every in-page fragment of the home page names an id on it', () => {
  const ids = new Set([...home.matchAll(/ id="([^"]+)"/g)].map((m) => m[1]));
  const bad = hrefs().filter((h) => h.startsWith('#') && h.length > 1 && !ids.has(h.slice(1)));
  expect(bad).toEqual([]);
});

test('the Releases link is the repository’s latest release', () => {
  expect(hrefs()).toContain(`${REPO_URL}/releases/latest`);
});

test('the install note names the platforms the releases serve', () => {
  const m = /<p class="note" id="install-note">(.*?)<\/p>/s.exec(home);
  expect(m).not.toBeNull();
  expect((m as RegExpExecArray)[1]).toContain('Release binaries for Linux and macOS, on x86_64 and arm64.');
});
