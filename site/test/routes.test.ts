// T3: parseRoute agrees with the shared route vectors (test/fixtures/routes.json), which the edge router in the
// site stack is tested against too; and the path builders encode every segment.
import vectors from './fixtures/routes.json';
import {
  isCanonicalName, isName, isVersion, normaliseName, packagePath, parseRoute, searchPath, VERSION_MAX, versionPath,
} from '../src/routes';

type Vector = { path: string; edge: string; view: ReturnType<typeof parseRoute> };
const V = vectors.vectors as Vector[];

test.each(V.map((v) => [v.path, v] as const))('parseRoute(%j)', (_path, v) => {
  expect(parseRoute(v.path)).toEqual(v.view);
});

test('the vectors are consistent: the shell serves exactly the app routes', () => {
  for (const v of V) expect([v.path, v.view !== null]).toEqual([v.path, v.edge === '/app.html']);
});

test('every redirect goes to the normalised name, which is a package route', () => {
  const redirects = V.filter((v) => v.edge.startsWith('redirect:'));
  expect(redirects.length).toBeGreaterThan(0);
  for (const v of redirects) {
    const raw = v.path.split('/')[2];
    const target = v.edge.slice('redirect:'.length);
    expect(target).toBe(packagePath(normaliseName(raw)));
    expect(normaliseName(raw)).not.toBe(raw);
    expect(parseRoute(target)).toEqual({ kind: 'package', name: normaliseName(raw) });
  }
});

test('a one-segment package path that passes through has no valid normalised form', () => {
  for (const v of V) {
    const parts = v.path.split('/');
    if (v.edge === 'pass' && parts.length === 3 && parts[1] === 'packages' && parts[2] !== '') {
      expect([parts[2], isName(normaliseName(parts[2]))]).toEqual([parts[2], false]);
    }
  }
});

test('the vectors cover the edge cases the plan names', () => {
  const paths = V.map((v) => v.path);
  const named = [
    '/packages/Foo', '/packages/foo__bar', '/packages/foo__bar/1.0', '/packages/a', '/packages/ab/v1',
    '/packages/ab/1.0/extra', '/docs/../x', '/packages/ab/1.0', '/packages/ab/1.0.0.0', '/packages/ab/1.0rc1',
  ];
  for (const p of named) {
    expect(paths).toContain(p);
  }
  expect(paths.some((p) => p.includes('%2F'))).toBe(true);
  const versions = V.filter((v) => v.view?.kind === 'version').map((v) => (v.view as { version: string }).version);
  expect(Math.max(...versions.map((x) => x.length))).toBe(VERSION_MAX);
  expect(paths.some((p) => p.split('/')[3]?.length === VERSION_MAX + 1)).toBe(true);
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

test('path builders encode every segment', () => {
  expect(packagePath('http_client')).toBe('/packages/http_client');
  expect(packagePath('a/b?c#d')).toBe('/packages/a%2Fb%3Fc%23d');
  expect(versionPath('ab', '1.0/../x')).toBe('/packages/ab/1.0%2F..%2Fx');
  expect(searchPath()).toBe('/search');
  expect(searchPath({ q: 'a&b=c', sort: 'updated', cursor: 'x/y' })).toBe('/search?q=a%26b%3Dc&sort=updated&cursor=x%2Fy');
  expect(searchPath({ q: '', sort: 'name' })).toBe('/search');
});
