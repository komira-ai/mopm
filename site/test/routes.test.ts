// T3: parseRoute agrees with the route vectors (test/fixtures/routes.json), which also state what the site stack's edge
// router does (service/infra/stacks/test/site-router.test.ts runs that router over the same vectors); and the path
// builders encode every segment.
import vectors from './fixtures/routes.json';
import { DOC_PAGES } from '../src/links';
import {
  DOC_SLUG, flatSearchPath, fullName, isCanonicalName, isName, isNamespace, isVersion, namespaceSearchPath, NAMESPACE_MAX,
  normaliseName, packagePath, parseRoute, searchPath, splitFullName, VERSION_MAX, versionPath,
} from '../src/routes';

type Vector = { path: string; edge: string; view: ReturnType<typeof parseRoute> };
const V = vectors.vectors as Vector[];

test.each(V.map((v) => [v.path, v] as const))('parseRoute(%j)', (_path, v) => {
  expect(parseRoute(v.path)).toEqual(v.view);
});

test('the vectors are consistent: the shell serves exactly the app routes', () => {
  for (const v of V) expect([v.path, v.view !== null]).toEqual([v.path, v.edge === '/app.html']);
});

test('every 301 goes to the normalised name inside the same namespace, which is a package route', () => {
  const redirects = V.filter((v) => v.edge.startsWith('redirect:'));
  expect(redirects.length).toBeGreaterThan(0);
  for (const v of redirects) {
    const [, , namespace, raw] = v.path.split('/');
    const target = v.edge.slice('redirect:'.length);
    const name = normaliseName(raw);
    expect(target).toBe(packagePath({ namespace, name }));
    expect(name).not.toBe(raw);
    expect(parseRoute(target)).toEqual({ kind: 'package', namespace, name });
  }
});

test('every 302 goes to the search flatSearchPath names, and flatSearchPath answers nothing else', () => {
  const found = V.filter((v) => v.edge.startsWith('found:'));
  expect(found.length).toBeGreaterThan(0);
  for (const v of found) expect([v.path, v.edge]).toEqual([v.path, `found:${flatSearchPath(v.path)}`]);
  for (const v of V) {
    if (!v.edge.startsWith('found:')) expect([v.path, flatSearchPath(v.path)]).toEqual([v.path, null]);
  }
});

test('a one- or two-segment package path the router answers with the 404 page has no redirect', () => {
  const passes = V.filter((v) => {
    const parts = v.path.split('/');
    return v.edge === '/404.html' && parts[1] === 'packages' && (parts.length === 3 || parts.length === 4);
  });
  expect(passes.length).toBeGreaterThan(10);
  for (const v of passes) expect([v.path, flatSearchPath(v.path), parseRoute(v.path)]).toEqual([v.path, null, null]);
});

test("the vectors' build holds every page the site builds, and a pass is a file of that build or an asset of another", () => {
  const files = vectors.files;
  const pages = ['/404.html', '/app.html', '/docs/index.html', ...DOC_PAGES.map((d) => `/docs/${d.slug}/index.html`), '/index.html'];
  expect(files.filter((f) => f.endsWith('.html')).sort()).toEqual(pages.sort());
  expect(files).toContain('/install.sh');
  const builds = new Set(files.filter((f) => f.startsWith('/assets/')).map((f) => f.split('/')[2]));
  expect(builds.size).toBe(1);
  for (const v of V.filter((x) => x.edge === 'pass')) {
    const id = v.path.split('/')[2];
    expect([v.path, files.includes(v.path) || (v.path.startsWith('/assets/') && !builds.has(id))]).toEqual([v.path, true]);
  }
  // Every file of the build is reached as it is, and each kind of answer appears.
  for (const f of files) expect(V).toContainEqual(expect.objectContaining({ path: f, edge: 'pass' }));
  for (const edge of ['/404.html', '/index.html', '/app.html', 'pass']) expect(V.some((v) => v.edge === edge)).toBe(true);
});

test('the vectors cover the edge cases the plan names', () => {
  const paths = V.map((v) => v.path);
  const ns39 = 'a'.repeat(NAMESPACE_MAX);
  const named = [
    '/packages/Foo', '/packages/foo__bar', '/packages/foo__bar/1.0', '/packages/a', '/packages/ab/v1',
    '/packages/ab/1.0/extra', '/docs/../x', '/packages/ab/1.0', '/packages/ab/1.0.0.0', '/packages/komira-ai/json/1.0rc1',
    // A bad name with a valid version: only the name check can refuse these (the bad-name vectors above also have a
    // bad version, so they pass even if the name is not checked).
    '/packages/Foo/1.0.0', '/packages/foo__bar/1.0.0', '/packages/9lives/1.0.0',
    // The namespace grammar: length at and over the cap, case, hyphens, other separators, encoding.
    `/packages/${ns39}/json`, `/packages/${ns39}a/json`, '/packages/Komira-AI/json', '/packages/komira--ai/json',
    '/packages/-komira/json', '/packages/komira-/json', '/packages/komira_ai/json', '/packages/komira.ai/json',
    '/packages/komira-ai%2Fjson', '/packages/komira-ai/json%2F1.0.0', '/packages/komira-ai/json/0.1.0',
    '/packages/komira-ai/Json', '/packages/komira-ai/json/1.0.0/extra',
  ];
  for (const p of named) {
    expect(paths).toContain(p);
  }
  expect(paths.filter((p) => p.includes('%2F')).length).toBeGreaterThanOrEqual(2);
  const versions = V.filter((v) => v.view?.kind === 'version').map((v) => (v.view as { version: string }).version);
  expect(Math.max(...versions.map((x) => x.length))).toBe(VERSION_MAX);
  expect(paths.some((p) => p.split('/')[4]?.length === VERSION_MAX + 1)).toBe(true);
  // The namespace cap is on both sides of the vectors: 39 characters is a route, 40 is not.
  expect(V.find((v) => v.path === `/packages/${ns39}/json`)?.view).toEqual({ kind: 'package', namespace: ns39, name: 'json' });
  expect(V.find((v) => v.path === `/packages/${ns39}a/json`)?.view).toBeNull();
});

test('names and versions', () => {
  expect(isName('http_client')).toBe(true);
  expect(isName('a')).toBe(false);
  expect(isName('x'.repeat(64))).toBe(true);
  expect(isName('x'.repeat(65))).toBe(false);
  expect(isName('xhttp\n')).toBe(false);
  // spec Version: MAJOR.MINOR.PATCH, no leading zeros, no suffix, no shorter or longer spelling.
  expect(isVersion('1.0.0')).toBe(true);
  expect(isVersion('0.0.0')).toBe(true);
  expect(isVersion(`1.1.${'1'.repeat(VERSION_MAX - 4)}`)).toBe(true);
  expect(isVersion(`1.1.${'1'.repeat(VERSION_MAX - 3)}`)).toBe(false);
  for (const v of ['1', '1.0', '1.0.0.0', '1.0rc1', '2.0dev3', '1.0.0-beta.1', '1.0.0+local', '01.0.0', '1.00.0', '1.0.00', '1.0.0\n']) {
    expect([v, isVersion(v)]).toEqual([v, false]);
  }
  expect(normaliseName('HTTP--Client.v2')).toBe('http_client_v2');
  expect(normaliseName('foo__bar')).toBe('foo_bar');
  expect(isCanonicalName('foo_bar')).toBe(true);
  expect(isCanonicalName('foo__bar')).toBe(false);
  expect(isCanonicalName('Foo')).toBe(false);
  expect(isCanonicalName('a')).toBe(false);
});

test('isNamespace: lower-case letters, digits and single inner hyphens, at most 39 characters', () => {
  expect(NAMESPACE_MAX).toBe(39);
  for (const ok of ['a', '0', '9lives', 'komira-ai', 'a-b-c', 'a'.repeat(39), `${'a-'.repeat(19)}a`]) {
    expect([ok, isNamespace(ok)]).toEqual([ok, true]);
  }
  for (const bad of ['', 'a'.repeat(40), 'Komira-AI', 'komira--ai', '-komira', 'komira-', '-', 'komira_ai', 'komira.ai', 'a/b', 'a%2Fb', 'ko mira', 'komira\n', 'komirá']) {
    expect([bad, isNamespace(bad)]).toEqual([bad, false]);
  }
});

test('fullName joins the two parts with one slash', () => {
  expect(fullName({ namespace: 'komira-ai', name: 'http_client' })).toBe('komira-ai/http_client');
});

test('splitFullName splits a namespace and a canonical name, and nothing else', () => {
  expect(splitFullName('komira-ai/http_client')).toEqual({ namespace: 'komira-ai', name: 'http_client' });
  const ns40 = 'a'.repeat(39);
  expect(splitFullName(`${ns40}/json`)).toEqual({ namespace: ns40, name: 'json' });
  expect(splitFullName(`${ns40}a/json`)).toBeNull();
  for (const bad of [
    'http_client', // flat
    'json', 'komira-ai/a/b', 'komira-ai//json', // two slashes
    '/json', 'komira-ai/', '/', '', // empty parts
    'komira-ai/HTTP-Client', 'komira-ai/foo__bar', 'komira-ai/Json', 'komira-ai/9lives', // not canonical
    'Komira-AI/json', 'komira_ai/json', 'komira-/json', // not a namespace
  ]) {
    expect([bad, splitFullName(bad)]).toEqual([bad, null]);
  }
  const f = splitFullName('komira-ai/json');
  expect(f && fullName(f)).toBe('komira-ai/json');
});

test('path builders encode every segment', () => {
  const f = { namespace: 'komira-ai', name: 'http_client' };
  expect(packagePath(f)).toBe('/packages/komira-ai/http_client');
  expect(packagePath({ namespace: 'a/b', name: 'c?d#e' })).toBe('/packages/a%2Fb/c%3Fd%23e');
  expect(versionPath(f, '1.0.0')).toBe('/packages/komira-ai/http_client/1.0.0');
  expect(versionPath({ namespace: 'ab', name: 'cd' }, '1.0/../x')).toBe('/packages/ab/cd/1.0%2F..%2Fx');
  expect(parseRoute(versionPath(f, '1.2.3'))).toEqual({ kind: 'version', ...f, version: '1.2.3' });
  expect(namespaceSearchPath('komira-ai')).toBe('/search?q=komira-ai%2F');
  expect(searchPath()).toBe('/search');
  expect(searchPath({ q: 'a&b=c', sort: 'updated', cursor: 'x/y' })).toBe('/search?q=a%26b%3Dc&sort=updated&cursor=x%2Fy');
  expect(searchPath({ q: '', sort: 'name' })).toBe('/search');
});

test('flatSearchPath: a name, a namespace or a spelling of a name searches; anything else is null', () => {
  // A canonical name wins over a namespace reading ('json' is both), with or without a version.
  expect(flatSearchPath('/packages/json')).toBe('/search?q=json');
  expect(flatSearchPath('/packages/json/0.4.0')).toBe('/search?q=json');
  // A namespace that is no canonical name lists the namespace.
  expect(flatSearchPath('/packages/komira-ai')).toBe('/search?q=komira-ai%2F');
  expect(flatSearchPath('/packages/a')).toBe('/search?q=a%2F');
  // Another spelling of a name searches the normalised name.
  expect(flatSearchPath('/packages/HTTP-Client')).toBe('/search?q=http_client');
  expect(flatSearchPath('/packages/foo__bar')).toBe('/search?q=foo_bar');
  for (const none of [
    '/packages/_ab', '/packages/a%2Fb', '/packages/%68ttp_client', '/packages/' + 'a'.repeat(65), // no name, no namespace
    '/packages/ab/1.0', '/packages/Foo/1.0.0', '/packages/foo__bar/1.0.0', '/packages/9lives/1.0.0', // flat but not a flat version
    '/packages/ab/1.0.0/extra', '/packages/komira-ai/json', '/packages/komira-ai/json/1.0.0', // deeper paths
    '/packages', '/packages/', '/search', '/', '/docs/why', '//packages/ab', '/other/ab',
  ]) {
    expect([none, flatSearchPath(none)]).toEqual([none, null]);
  }
});

test('parseRoute reads namespace and name apart and refuses the flat addresses', () => {
  expect(parseRoute('/packages/komira-ai/json')).toEqual({ kind: 'package', namespace: 'komira-ai', name: 'json' });
  expect(parseRoute('/packages/komira-ai/json/0.1.0')).toEqual({ kind: 'version', namespace: 'komira-ai', name: 'json', version: '0.1.0' });
  for (const p of ['/packages/json', '/packages/json/0.1.0', '/packages/komira-ai/json/1.0', '/packages/Komira-AI/json', '/x/packages/a/json', '/packages/komira-ai/json/1.0.0/x']) {
    expect([p, parseRoute(p)]).toEqual([p, null]);
  }
  expect(parseRoute('/search')).toEqual({ kind: 'search' });
});

test('every docs page has a slug the edge router serves (DOC_SLUG), and a docs vector names each', () => {
  const paths = V.map((v) => v.path);
  for (const d of DOC_PAGES) {
    expect([d.slug, DOC_SLUG.test(d.slug)]).toEqual([d.slug, true]);
    // Both spellings: the address with its trailing slash, and without it.
    expect(paths).toContain(`/docs/${d.slug}/`);
    expect(paths).toContain(`/docs/${d.slug}`);
  }
  expect(DOC_SLUG.test('Bad_Slug')).toBe(false);
  expect(DOC_SLUG.test('..')).toBe(false);
});
