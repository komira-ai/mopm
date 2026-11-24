// The tutorial bundle (tools/build.ts bundleTutorial, TUTORIAL_BUNDLE) and what checkDist holds it to:
//  - the real bundle, built from all of src/ as tsc writes it, is one minified ES module with the e2b SDK in it, within
//    TUTORIAL_JS_MAX_BYTES, with no source map, no path of this machine, no import left and no eval; the same inputs
//    give the same bytes; and no page of the build loads it;
//  - e2b's six node:* imports get the empty stub, any other node:* module fails the build, and so do an esbuild warning
//    and a missing entry or stub;
//  - checkDist refuses the bundle over its budget (and passes it at the budget), keeps it out of the tsc modules'
//    budgets, refuses it on a page that is not a tutorial page, and refuses JavaScript that names a source map.
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { bundleTutorial, NODE_STUB, NODE_STUBS, TUTORIAL_ENTRY } from '../tools/build';
import { checkDist, DistError, isTutorialBundle, isTutorialPage, JS_MAX_BYTES, JS_TOTAL_MAX_BYTES, TUTORIAL_BUNDLE, TUTORIAL_JS_MAX_BYTES } from '../tools/check-dist';
import { cleanup, type Fixture, fixture, realBrowserFiles, REPO_ROOT } from './build-fixture';

const made: Fixture[] = [];
function fresh(files?: Record<string, string>): Fixture {
  const f = fixture(files);
  made.push(f);
  return f;
}
afterAll(() => made.forEach(cleanup));

const expectRefusal = (f: Fixture, message: string) => {
  expect(() => checkDist(f.outDir)).toThrow(DistError);
  expect(() => checkDist(f.outDir)).toThrow(message);
};

describe('the real bundle', () => {
  // One real build for the assertions below (esbuild over the SDK takes a moment); a second for the byte comparison.
  const real = fresh(realBrowserFiles());
  const { id, files, tutorialBytes } = real.build();
  const path = `assets/${id}/${TUTORIAL_BUNDLE}`;
  const bundle = readFileSync(join(real.outDir, path), 'utf8');

  test(`is one file, assets/<id>/${TUTORIAL_BUNDLE}, within TUTORIAL_JS_MAX_BYTES (320 KiB)`, () => {
    expect(TUTORIAL_JS_MAX_BYTES).toBe(327_680);
    expect(files.filter(isTutorialBundle)).toEqual([path]);
    expect(Buffer.byteLength(bundle)).toBe(tutorialBytes);
    expect(tutorialBytes).toBeLessThanOrEqual(TUTORIAL_JS_MAX_BYTES);
  });

  test('holds the e2b SDK and the runner, and exports the runner', () => {
    // The headers the SDK's client sends the agent, which only its code carries.
    expect(bundle).toContain('X-Access-Token');
    expect(bundle).toContain('E2b-Sandbox-Id');
    expect(bundle).toMatch(/export\{[^}]*\bas e2bRunner\b[^}]*\};?\s*(\/\*[\s\S]*\*\/\s*)?$/);
  });

  test('is minified and names no source map and no path of this machine', () => {
    expect(bundle.split('\n').length).toBeLessThan(100);
    expect(bundle).not.toContain('sourceMappingURL');
    expect(bundle).not.toContain('node_modules');
    for (const dir of [REPO_ROOT, real.root, real.browserDir]) expect(bundle).not.toContain(dir);
  });

  test('is self-contained: no import statement is left in it (so none of a node:* module)', () => {
    // An import statement as esbuild writes one: import{...}from"x", import*as x from"x", import"x". The SDK's own
    // `import(specifier)`, which it never runs in a browser, and strings such as "dynamic import" are not.
    expect(bundle).not.toMatch(/(?:^|[;}])\s*import\s*[{*"'`]|\bfrom\s*["'`]/m);
  });

  test('runs no string as code (the page CSP requires Trusted Types with no policy)', () => {
    expect(bundle).not.toMatch(/\beval\s*\(|\bnew Function\b/);
  });

  test('no page of this build loads it', () => {
    for (const page of files.filter((f) => f.endsWith('.html'))) expect(readFileSync(join(real.outDir, page), 'utf8')).not.toContain(TUTORIAL_BUNDLE);
  });

  test('the same inputs give the same bytes', () => {
    const again = fresh(realBrowserFiles());
    const r = again.build();
    expect(r.id).toBe(id);
    expect(readFileSync(join(again.outDir, path), 'utf8')).toBe(bundle);
  });
});

describe('bundleTutorial', () => {
  const browserDir = (files: Record<string, string>): string => {
    const f = fresh(files);
    return f.browserDir;
  };

  test(`gives each of e2b's node:* imports (${NODE_STUBS.join(', ')}) the empty stub`, () => {
    const imports = NODE_STUBS.map((m, i) => `import * as m${i} from '${m}';`).join('\n');
    const uses = NODE_STUBS.map((_, i) => `m${i}`).join(', ');
    const out = bundleTutorial(browserDir({ [TUTORIAL_ENTRY]: `${imports}\nexport const all = [${uses}];\n` })).toString('utf8');
    expect(out).not.toMatch(/node:/);
    expect(out).toMatch(/export\{.*\ball\b.*\}/);
  });

  test('a node:* module that is not one of the six fails the build', () => {
    const dir = browserDir({ [TUTORIAL_ENTRY]: "import { gzipSync } from 'node:zlib';\nexport const z = gzipSync;\n" });
    expect(() => bundleTutorial(dir)).toThrow(/Could not resolve "node:zlib"/);
  });

  test('an esbuild warning fails the build', () => {
    const dir = browserDir({ [TUTORIAL_ENTRY]: 'export const o = { a: 1, a: 2 };\n' });
    expect(() => bundleTutorial(dir)).toThrow(`build: esbuild warned on ${TUTORIAL_ENTRY}: Duplicate key "a" in object literal`);
  });

  test.each([TUTORIAL_ENTRY, NODE_STUB])('a build without %s refuses', (m) => {
    const f = fresh();
    unlinkSync(join(f.browserDir, m));
    expect(() => f.build()).toThrow(`build: ${join(f.browserDir, m)} is missing; run tsc -p tsconfig.browser.json first`);
  });

});

describe('checkDist and the tutorial bundle', () => {
  function built(): { f: Fixture; id: string } {
    const f = fresh();
    return { f, id: f.build().id };
  }
  const write = (f: Fixture, path: string, text: string) => {
    mkdirSync(dirname(join(f.outDir, path)), { recursive: true });
    writeFileSync(join(f.outDir, path), text);
  };
  /** A module of exactly n bytes. */
  const sized = (n: number): string => `export const b='${'x'.repeat(n - 19)}';\n`;

  test('a bundle at exactly TUTORIAL_JS_MAX_BYTES passes, one byte more is refused', () => {
    const { f, id } = built();
    const p = `assets/${id}/${TUTORIAL_BUNDLE}`;
    write(f, p, sized(TUTORIAL_JS_MAX_BYTES));
    expect(readFileSync(join(f.outDir, p)).length).toBe(TUTORIAL_JS_MAX_BYTES);
    expect(() => checkDist(f.outDir)).not.toThrow();
    write(f, p, sized(TUTORIAL_JS_MAX_BYTES + 1));
    expectRefusal(f, `${p} is ${TUTORIAL_JS_MAX_BYTES + 1} bytes; the limit for the tutorial bundle is ${TUTORIAL_JS_MAX_BYTES}`);
  });

  test('the bundle is not one of the tsc modules: over their per-module and total limits, it passes', () => {
    expect(TUTORIAL_JS_MAX_BYTES).toBeGreaterThan(JS_TOTAL_MAX_BYTES);
    const { f, id } = built();
    write(f, `assets/${id}/${TUTORIAL_BUNDLE}`, sized(JS_TOTAL_MAX_BYTES + 1));
    expect(() => checkDist(f.outDir)).not.toThrow();
  });

  test(`a module named ${TUTORIAL_BUNDLE} below assets/<id>/ is a tsc module, with their limit`, () => {
    const { f, id } = built();
    const p = `assets/${id}/lazy/${TUTORIAL_BUNDLE}`;
    write(f, p, sized(JS_MAX_BYTES + 1));
    expectRefusal(f, `${p} is ${JS_MAX_BYTES + 1} bytes; the limit for one module is ${JS_MAX_BYTES}`);
  });

  test('a page that is not a tutorial page loading the bundle is refused; the tutorial pages may', () => {
    const { f, id } = built();
    const script = `<script type="module" src="/assets/${id}/${TUTORIAL_BUNDLE}"></script>`;
    const home = readFileSync(join(f.outDir, 'index.html'), 'utf8');
    write(f, 'tutorial.html', home.replace('</head>', `${script}\n</head>`));
    write(f, 'tutorial/hello/index.html', home.replace('</head>', `${script}\n</head>`));
    expect(() => checkDist(f.outDir)).not.toThrow();
    write(f, 'index.html', home.replace('</head>', `<link rel="modulepreload" href="/assets/${id}/${TUTORIAL_BUNDLE}">\n</head>`));
    expectRefusal(f, `index.html: loads /assets/${id}/${TUTORIAL_BUNDLE}; only the tutorial pages do`);
  });

  test.each(['//# sourceMappingURL=main.js.map', '//@ sourceMappingURL=main.js.map', '/*# sourceMappingURL=main.js.map */'])(
    'JavaScript naming a source map (%s) is refused, the bundle and a tsc module alike',
    (comment) => {
      const { f, id } = built();
      for (const m of ['main.js', TUTORIAL_BUNDLE]) {
        const p = `assets/${id}/${m}`;
        const before = readFileSync(join(f.outDir, p), 'utf8');
        write(f, p, `${before}${comment}\n`);
        expectRefusal(f, `${p}: names a source map`);
        write(f, p, before);
      }
      expect(() => checkDist(f.outDir)).not.toThrow();
    },
  );

  test('isTutorialBundle and isTutorialPage', () => {
    expect([`assets/0123456789abcdef/${TUTORIAL_BUNDLE}`, `assets/x/lazy/${TUTORIAL_BUNDLE}`, TUTORIAL_BUNDLE, 'assets/x/tutorial.css'].map(isTutorialBundle)).toEqual([true, false, false, false]);
    expect(['tutorial.html', 'tutorial/hello/index.html', 'index.html', 'docs/tutorial.html', 'tutorials.html'].map(isTutorialPage)).toEqual([true, true, false, false, false]);
  });
});
