// T16: the build. The same inputs give the same tree byte for byte (no clock, no commit, no randomness), so every
// stage deploys one artifact; the asset id is a content hash, so a changed asset gets a new URL (assets are cached as
// immutable); only the entry and what it imports ship; and checkDist refuses a tree the site stack must not deploy.
import { appendFileSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'fs';
import { join } from 'path';
import { assetId, moduleGraph } from '../tools/build';
import { checkDist, CSS_MAX_BYTES, decodeAttr, DistError, isScriptUrl, JS_MAX_BYTES, JS_TOTAL_MAX_BYTES, REQUIRED } from '../tools/check-dist';
import { cleanup, type Fixture, fixture } from './build-fixture';

const made: Fixture[] = [];
function fresh(files?: Record<string, string>): Fixture {
  const f = fixture(files);
  made.push(f);
  return f;
}
afterAll(() => made.forEach(cleanup));

function tree(f: Fixture, files: string[]): Record<string, string> {
  return Object.fromEntries(files.map((p) => [p, readFileSync(join(f.outDir, p), 'utf8')]));
}

describe('a build', () => {
  test('two builds of the same inputs give the same tree, byte for byte', async () => {
    const a = fresh();
    const b = fresh();
    const ra = a.build();
    await new Promise((r) => setTimeout(r, 20)); // a clock in the output would now differ
    const rb = b.build();
    expect(rb.id).toBe(ra.id);
    expect(rb.files).toEqual(ra.files);
    expect(tree(b, rb.files)).toEqual(tree(a, ra.files));
  });

  test('the tree holds the pages and the hashed assets, and nothing unreferenced', () => {
    const { id, files } = fresh().build();
    expect(id).toMatch(/^[0-9a-f]{16}$/);
    for (const r of REQUIRED) expect(files).toContain(r);
    expect(REQUIRED).toEqual(expect.arrayContaining(['index.html', 'app.html', '404.html', 'docs/index.html', 'docs/mopm-toml/index.html', 'docs/mopm-test/index.html']));
    const assets = files.filter((f) => f.startsWith('assets/'));
    expect(assets.sort()).toEqual(['a.js', 'lazy/b.js', 'lazy/c.js', 'main.js', 'site.css'].map((p) => `assets/${id}/${p}`).sort());
  });

  test('pages load one stylesheet and the entry module, and preload what the entry imports', () => {
    const f = fresh();
    const { id } = f.build();
    const page = readFileSync(join(f.outDir, 'index.html'), 'utf8');
    expect(page).toContain(`<link rel="stylesheet" href="/assets/${id}/site.css">`);
    expect(page).toContain(`<script type="module" src="/assets/${id}/main.js"></script>`);
    expect(page.match(/rel="modulepreload"/g)).toHaveLength(3);
    expect(page).toContain(`<link rel="modulepreload" href="/assets/${id}/lazy/c.js">`);
  });

  test('the id changes when a module changes, and when the stylesheet changes', () => {
    const base = fresh().build().id;
    expect(fresh({ 'lazy/c.js': 'export const c = 30;\n' }).build().id).not.toBe(base);
    const f = fresh();
    writeFileSync(join(f.staticDir, 'site.css'), readFileSync(join(f.staticDir, 'site.css'), 'utf8') + '\n/* x */\n');
    expect(f.build().id).not.toBe(base);
  });

  test('a module that is not imported does not change the id', () => {
    expect(fresh({ 'unused.js': 'export const u = 5;\n' }).build().id).toBe(fresh().build().id);
  });

  test('a build with no entry module refuses', () => {
    const f = fresh();
    unlinkSync(join(f.browserDir, 'main.js'));
    expect(() => f.build()).toThrow(/main\.js is missing/);
  });

  test('a module importing one that was not compiled refuses', () => {
    expect(() => fresh({ 'a.js': "import './gone.js';\n" }).build()).toThrow(/gone\.js is imported but was not compiled/);
  });
});

describe('assetId and moduleGraph', () => {
  test('assetId depends on paths as well as bytes, and on no order', () => {
    const x = Buffer.from('x');
    expect(assetId(new Map([['a.js', x]]))).not.toBe(assetId(new Map([['b.js', x]])));
    expect(assetId(new Map([['ab', Buffer.from('c')]]))).not.toBe(assetId(new Map([['a', Buffer.from('bc')]])));
    const m1 = new Map([['a', x], ['b', Buffer.from('y')]]);
    const m2 = new Map([['b', Buffer.from('y')], ['a', x]]);
    expect(assetId(m1)).toBe(assetId(m2));
  });

  test('moduleGraph follows static and dynamic relative imports, including ../', () => {
    const js = new Map(
      Object.entries({ 'main.js': "import './v/x.js'; import('./y.js');", 'v/x.js': "export * from '../z.js';", 'y.js': '', 'z.js': '' }).map(
        ([k, v]) => [k, Buffer.from(v)] as [string, Buffer],
      ),
    );
    expect(moduleGraph(js, 'main.js')).toEqual(['v/x.js', 'y.js', 'z.js']);
  });
});

describe('reading attribute values as a browser does', () => {
  test('decodeAttr decodes numeric and the known named references in one pass', () => {
    expect(decodeAttr('java&#x73;cript&#58;x')).toBe('javascript:x');
    expect(decodeAttr('/search?q=a&amp;sort=updated')).toBe('/search?q=a&sort=updated');
    expect(decodeAttr('&amp;colon;')).toBe('&colon;');
    expect(decodeAttr('&nbsp;')).toBeNull();
  });

  test.each([
    ['javascript:x', true],
    ['  JaVaScRiPt:x', true],
    ['\x01javascript:x', true],
    ['java\nscript:x', true],
    ['data:text/html,x', true],
    ['vbscript:x', true],
    ['https://example.com/javascript:x', false],
    ['/search?q=javascript:x', false],
    ['#javascript', false],
  ])('isScriptUrl(%j) is %s', (v, want) => {
    expect(isScriptUrl(v)).toBe(want);
  });
});

describe('checkDist refuses', () => {
  function built(): { f: Fixture; id: string } {
    const f = fresh();
    return { f, id: f.build().id };
  }
  const expectRefusal = (f: Fixture, re: RegExp) => {
    expect(() => checkDist(f.outDir)).toThrow(DistError);
    expect(() => checkDist(f.outDir)).toThrow(re);
  };

  test('a fresh build passes', () => {
    const { f } = built();
    expect(() => checkDist(f.outDir)).not.toThrow();
  });

  test('a page referencing an asset that is not there', () => {
    const { f, id } = built();
    unlinkSync(join(f.outDir, 'assets', id, 'site.css'));
    expectRefusal(f, new RegExp(`index\\.html: references /assets/${id}/site\\.css`));
  });

  test('a module importing one that is not there', () => {
    const { f, id } = built();
    unlinkSync(join(f.outDir, 'assets', id, 'lazy', 'c.js'));
    expectRefusal(f, /a\.js: imports assets\/[0-9a-f]+\/lazy\/c\.js/);
  });

  test.each(['index.html', 'app.html', '404.html', 'docs/index.html', 'docs/mopm-test/index.html'])('a missing %s', (p) => {
    const { f } = built();
    rmSync(join(f.outDir, p));
    expectRefusal(f, new RegExp(`missing ${p.replace('.', '\\.')}`));
  });

  test.each([
    ['an inline script', '<script>alert(1)</script>', /an inline <script>/],
    ['a style element', '<style>p{}</style>', /a <style> element/],
    ['a style attribute', '<p style="color:red">x</p>', /a style attribute/],
    ['an event handler', '<p onclick="x()">x</p>', /event-handler attribute onclick/],
    ['an unquoted event handler', '<img src=x onerror=alert(1)>', /event-handler attribute onerror/],
    ['a script URL', '<a href="javascript:alert(1)">x</a>', /a script URL/],
    ['a script with data-src only', '<script data-src="x">alert(1)</script>', /an inline <script>/],
    ['an empty script with data-src only', '<script data-src="/assets/x.js"></script>', /a <script> without one src under \/assets\//],
    ['a script from another origin', '<script src="https://cdn.example/x.js"></script>', /a <script> without one src under \/assets\//],
    ['a script with a src and content', '<script src="/assets/x/main.js">alert(1)</script>', /an inline <script>/],
    ['an unclosed script', '<script src="/assets/x/main.js">alert(1)', /an inline <script>/],
    ['an entity-encoded script URL', '<a href=" java&#x73;cript:x">x</a>', /a script URL .*in href on <a>/],
    ['a named-reference script URL', '<a href="javascript&colon;x">x</a>', /a script URL/],
    ['a tab inside the scheme', '<a href="java&Tab;script:x">x</a>', /a script URL/],
    ['an unknown named reference in a URL', '<a href="&nbsp;javascript:x">x</a>', /an unknown character reference/],
    ['a script URL in a form action', '<form action="javascript:x"></form>', /a script URL .*in action on <form>/],
    ['a script URL in a formaction', '<button formaction="javascript:x">x</button>', /a script URL .*in formaction on <button>/],
  ])('%s in a page', (_what, markup, re) => {
    const { f } = built();
    const p = join(f.outDir, '404.html');
    writeFileSync(p, readFileSync(p, 'utf8').replace('</main>', `${markup}</main>`));
    expectRefusal(f, re);
  });

  test('event-handler-looking text in a page is not a handler', () => {
    const { f } = built();
    const p = join(f.outDir, '404.html');
    writeFileSync(p, readFileSync(p, 'utf8').replace('</main>', '<p title="x onclick=y">a onload=b</p></main>'));
    expect(() => checkDist(f.outDir)).not.toThrow();
  });

  test('a file type the bucket does not serve', () => {
    const { f } = built();
    writeFileSync(join(f.outDir, 'logo.png'), 'x');
    expectRefusal(f, /logo\.png: only \.html, \.js and \.css/);
  });

  test('a stylesheet over the CSS budget', () => {
    const { f, id } = built();
    appendFileSync(join(f.outDir, 'assets', id, 'site.css'), `/*${'x'.repeat(CSS_MAX_BYTES)}*/\n`);
    expectRefusal(f, /CSS is \d+ bytes; the limit is 16384/);
  });

  test('modules each under the per-module limit but over the total', () => {
    const { f, id } = built();
    const each = JS_MAX_BYTES - 100;
    const n = Math.ceil(JS_TOTAL_MAX_BYTES / each) + 1;
    for (let i = 0; i < n; i++) writeFileSync(join(f.outDir, 'assets', id, `big${i}.js`), `export const b = '${'x'.repeat(each - 40)}';\n`);
    expect(() => checkDist(f.outDir)).toThrow(/JavaScript is \d+ bytes in all; the limit is 131072/);
    expect(() => checkDist(f.outDir)).not.toThrow(/limit for one module/);
  });

  test('a script outside assets/', () => {
    const { f } = built();
    writeFileSync(join(f.outDir, 'x.js'), 'export {};\n');
    expectRefusal(f, /x\.js: a script outside assets\//);
  });

  test('a stylesheet outside assets/', () => {
    const { f } = built();
    writeFileSync(join(f.outDir, 'x.css'), 'p{}\n');
    expectRefusal(f, /x\.css: a stylesheet outside assets\//);
  });

  test('a module over the size limit', () => {
    const { f, id } = built();
    writeFileSync(join(f.outDir, 'assets', id, 'lazy', 'b.js'), `export const b = '${'x'.repeat(JS_MAX_BYTES)}';\n`);
    expectRefusal(f, /lazy\/b\.js is \d+ bytes; the limit for one module/);
  });
});
