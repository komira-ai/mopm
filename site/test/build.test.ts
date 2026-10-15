// T16: the build. The same inputs give the same tree byte for byte (no clock, no commit, no randomness), so every
// stage deploys one artifact; the asset id is a content hash, so a changed asset gets a new URL (the site stack is to
// cache assets as immutable); only the entry and what it imports ship; and checkDist refuses a tree the site stack must
// not deploy.
import { appendFileSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'fs';
import { join } from 'path';
import { assetId, moduleGraph } from '../tools/build';
import { checkDist, CSS_MAX_BYTES, decodeAttr, DistError, isScriptUrl, JS_MAX_BYTES, JS_TOTAL_MAX_BYTES, REQUIRED, tagsIn } from '../tools/check-dist';
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

describe('reading tags as a browser does', () => {
  test('a slash separates attributes; an unquoted value runs to whitespace or >, slashes included', () => {
    expect(tagsIn('<img/src=x/onerror=alert(1)>')).toEqual([['img', [['src', 'x/onerror=alert(1)']]]]);
    expect(tagsIn('<a/href="/x"/title=t>')).toEqual([['a', [['href', '/x'], ['title', 't']]]]);
    // Inside a name too: 'x/onclick' is two attributes, x and onclick.
    expect(tagsIn('<a x/onclick="alert(1)">x</a>')).toEqual([['a', [['x', ''], ['onclick', 'alert(1)']]]]);
  });

  test('a name runs to whitespace, /, > or =, and may start with =; a quoted value needs no space after it', () => {
    expect(tagsIn('<a x"=1 onclick="y">')).toEqual([['a', [['x"', '1'], ['onclick', 'y']]]]);
    expect(tagsIn('<a =x title="a"href="/b">')).toEqual([['a', [['=x', ''], ['title', 'a'], ['href', '/b']]]]);
    expect(tagsIn('<A HREF = \'/x\' >')).toEqual([['a', [['href', '/x']]]]);
  });

  test('end tags are read but not returned; text and the doctype are skipped', () => {
    expect(tagsIn('<!doctype html><p class="a">x &lt; y</p>')).toEqual([['p', [['class', 'a']]]]);
  });

  test('a page the scanner cannot read throws', () => {
    expect(() => tagsIn('<p>a <!-- b --></p>')).toThrow(/a '<' that does not start a tag/);
    expect(() => tagsIn('<p title="<b>">')).toThrow(/a '<' inside a tag/);
    expect(() => tagsIn('<p title="x')).toThrow(/a tag the page does not close/);
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
    // A '/' separates attributes, and an attribute name may hold '"': the browser reads these tags, so the scanner must.
    ['a script whose src follows a slash', '<script/src="https://evil.example/x.js"></script>', /a <script> without one src under \/assets\//],
    ['an event handler after a slash', '<img/src=x onerror=alert(1)>', /event-handler attribute onerror on <img>/],
    ['a script URL after a slash', '<a/href="javascript:alert(1)">x</a>', /a script URL .*in href on <a>/],
    ['an event handler after a slash inside a name', '<a x/onclick="alert(1)">x</a>', /event-handler attribute onclick on <a>/],
    ['an event handler after a name holding a quote', '<a x"=1 onclick="alert(1)">x</a>', /event-handler attribute onclick on <a>/],
    ['a script URL in xlink:href', '<svg><a xlink:href="javascript:x">x</a></svg>', /a script URL .*in xlink:href on <a>/],
    ['a script URL in an object\'s data', '<object data="javascript:x"></object>', /a script URL .*in data on <object>/],
    ['a script URL in an iframe\'s src', '<iframe src="javascript:x"></iframe>', /a script URL .*in src on <iframe>/],
    // Character references and URL-parser stripping as a browser applies them.
    ['an upper-case hex reference in the scheme', '<a href="java&#X73;cript:x">x</a>', /a script URL .*in href on <a>/],
    ['a decimal reference without its ;', '<a href="java&#115cript:x">x</a>', /a script URL .*in href on <a>/],
    ['a carriage return inside the scheme', '<a href="java\rscript:x">x</a>', /a script URL .*in href on <a>/],
    // The src must start with /assets/, not merely contain it.
    ['a script from another origin under an /assets/ path', '<script src="https://evil.example/assets/x.js"></script>', /a <script> without one src under \/assets\//],
    // A '<' that the scanner would read inside a quoted value, where the browser reads markup: a comment ends at the
    // first '-->', and a title's text ends at '</title>', so the img below is a real element to the browser.
    ['a comment hiding a tag in a quoted value', '<!-- <a title=" --><img src=x onerror=alert(1)>" -->', /a '<' that does not start a tag/],
    ['raw text hiding a tag in a quoted value', '<textarea><a title="</textarea><img src=x onerror=alert(1)>"></textarea>', /a '<' inside a tag/],
    ['a tag without its closing >', '<a href="/x" onclick="alert(1)"</main><p>', /a '<' inside a tag/],
  ])('%s in a page', (_what, markup, re) => {
    const { f } = built();
    const p = join(f.outDir, '404.html');
    writeFileSync(p, readFileSync(p, 'utf8').replace('</main>', `${markup}</main>`));
    expectRefusal(f, re);
  });

  // Two src attributes: a browser uses the first. The rule is one src, so either order is refused; with the real asset
  // first, only the count can refuse it (the prefix check passes).
  test.each([
    ['a script with a second src after the real one', (id: string) => `<script src="/assets/${id}/main.js" src="https://evil.example/x.js"></script>`],
    ['a script with a second src before the real one', (id: string) => `<script src="https://evil.example/x.js" src="/assets/${id}/main.js"></script>`],
  ])('%s', (_what, markup) => {
    const { f, id } = built();
    const p = join(f.outDir, '404.html');
    writeFileSync(p, readFileSync(p, 'utf8').replace('</main>', `${markup(id)}</main>`));
    expectRefusal(f, /a <script> without one src under \/assets\//);
  });

  test('a start tag cut off by the end of the page', () => {
    const { f } = built();
    appendFileSync(join(f.outDir, '404.html'), '<a href="/x" onclick="alert(1)"');
    expectRefusal(f, /404\.html: a tag the page does not close/);
  });

  test('event-handler-looking text in a page is not a handler', () => {
    const { f } = built();
    const p = join(f.outDir, '404.html');
    writeFileSync(p, readFileSync(p, 'utf8').replace('</main>', '<p title="x onclick=y">a onload=b</p></main>'));
    expect(() => checkDist(f.outDir)).not.toThrow();
  });

  test('a file type the bucket is not to serve', () => {
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
