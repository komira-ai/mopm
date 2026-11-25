// The home page's internal links all land on a page the build writes (or the app shell), and the two facts a reader acts
// on, where releases are and which platforms the installer serves, are pinned.
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { REPO_URL } from '../src/links';
import { parseRoute } from '../src/routes';
import { START_PATH } from '../src/session';
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

// The header's sign-in link is the one internal href that is no page: the site distribution sends /api/* to the API
// (README.md, "How it is served"), and only the start route is linked. Defect caught: any other API path linked, or a
// page link that the build does not write.
test('every internal href of the home page resolves to a built page or an app route, but the sign-in link', () => {
  const bad: string[] = [];
  const internal = hrefs().filter((x) => x.startsWith('/'));
  expect(internal.filter((x) => x.startsWith('/api/'))).toEqual([`${START_PATH}?return_to=%2F`]);
  for (const h of internal) {
    const path = h.split('#')[0].split('?')[0];
    if (path === START_PATH) continue;
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
  expect((m as RegExpExecArray)[1]).toContain('Release binaries for Linux (x86_64, arm64) and macOS (arm64).');
});

// macos-x86_64 (an Intel Mac) is no longer a release platform (release/drop-macos-x86_64): no part of the home page names
// it as one, neither in TARGETS (tools/pages.ts) nor in the install note. docs-values.test.ts holds the list to the targets
// the release tools build.
test('the home page names no Intel Mac release, and lists exactly the three release targets', () => {
  expect(home).not.toMatch(/macos-x86_64|macOS \(x86_64|Intel Mac/i);
  const files = /<p[^>]* id="release-files"[^>]*>(.*?)<\/p>/s.exec(home);
  expect(files).not.toBeNull();
  const targets = [...(files as RegExpExecArray)[1].matchAll(/<code>((?:linux|macos)-[a-z0-9_]+)<\/code>/g)].map((m) => m[1]);
  expect(targets).toEqual(['linux-x86_64', 'linux-aarch64', 'macos-arm64']);
});
