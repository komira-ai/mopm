// The tutorial's prerendered pages (tools/tutorial.ts, written by tools/build.ts to dist/tutorial/): every lesson of the
// repository renders, with its title, its place and the runner's mount point, in the shell every page has and with no
// sign-in; the index lists the lessons in order; hostile Markdown in a lesson renders inert; the pages pass checkDist's
// page rules, and a broken one fails the build's check; the route vectors serve `/tutorial` and `/tutorial/<lesson>`
// from these files and nothing else under `/tutorial`; parseRoute (the app shell) routes none of them; and no page
// outside tutorial/ links to one but by the header's Tutorial entry.
import vectors from './fixtures/routes.json';
import { readFileSync, rmSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { escapeText, serialize } from '../src/doc';
import { parseRoute } from '../src/routes';
import { checkDist, DistError, tagsIn, TUTORIAL_BUNDLE } from '../tools/check-dist';
import { LESSON_SCHEMA, loadLessons, readLessonSchema } from '../tools/lessons';
import { stylesheetsFor } from '../tools/layout';
import { LESSON_ID_PREFIX, lessonArticle, RUNNER_ID, TUTORIAL_PATH } from '../tools/tutorial';
import { withoutTutorialLink } from '../tools/tutorial-link';
import { cleanup, type Fixture, fixture, goodLesson, LESSONS_DIR, lessonJson, lessonTree, REPO_ROOT } from './build-fixture';
import { MD_ATTRS, MD_TAGS, tagsOf, unescapeAttr } from './md';

const SCHEMA = readLessonSchema(join(REPO_ROOT, LESSON_SCHEMA));
const LESSONS = loadLessons(LESSONS_DIR, SCHEMA);

const made: Fixture[] = [];
const trees: string[] = [];
afterAll(() => {
  made.forEach(cleanup);
  for (const t of trees) rmSync(dirname(t), { recursive: true, force: true });
});

function built(lessonsDir?: string): { f: Fixture; id: string; files: string[]; pages: string[]; page: (p: string) => string } {
  const f = fixture({}, lessonsDir);
  made.push(f);
  const r = f.build();
  return { f, ...r, pages: r.files.filter((p) => p.startsWith('tutorial/')), page: (p) => readFileSync(join(f.outDir, p), 'utf8') };
}

const real = built();

/** Every <script> of a page as the page rules' tag scanner reads it (any case, any spacing), as its attributes. */
const scriptsOf = (html: string) => tagsIn(html).filter(([t]) => t === 'script').map(([, attrs]) => attrs);
const moduleScript = (src: string) => [['type', 'module'], ['src', src]];

/** <main>'s inner HTML. */
const mainOf = (html: string): string => {
  const m = /<main id="main" class="wrap" tabindex="-1">([\s\S]*)<\/main>/.exec(html);
  if (!m) throw new Error('no <main>');
  return m[1];
};

describe("the tutorial's pages in a build of the repository", () => {
  test('dist/tutorial/ holds the index and one page per lesson, at the paths of their routes, and nothing else', () => {
    expect(real.pages).toEqual(['tutorial/index.html', ...LESSONS.map((l) => `tutorial/${l.id}/index.html`)].sort());
  });

  test("every lesson renders: its title as the h1, its place, its text, and the runner mount holding its files and commands", () => {
    LESSONS.forEach((l, i) => {
      const html = real.page(`tutorial/${l.id}/index.html`);
      const main = mainOf(html);
      expect(html).toContain(`<title>${l.title} (tutorial) · mopm</title>`);
      expect(main.match(/<h1>/g)).toHaveLength(1);
      expect(main).toContain(`<h1>${l.title}</h1>`);
      expect(main).toContain(`<p class="lesson-place muted small">Lesson ${i + 1} of ${LESSONS.length}</p>`);
      const files = l.files.map((f) => `<div class="lesson-file"><p class="lesson-path"><code>${f.path}</code></p><pre class="lesson-text"><code>${escapeText(f.text)}</code></pre></div>`);
      const commands = `<dl class="lesson-commands"><dt>Run</dt><dd class="lesson-command-run"><code>${l.actions.run}</code></dd>${l.actions.test === undefined ? '' : `<dt>Test</dt><dd class="lesson-command-test"><code>${l.actions.test}</code></dd>`}</dl>`;
      expect(main).toContain(`<section id="${RUNNER_ID}" class="lesson-runner" aria-label="Try it" data-lesson="${l.id}"><div class="lesson-files">${files.join('')}</div>${commands}</section>`);
      expect(l.files.map((f) => f.path)).toEqual(l.editable);
      for (const f of l.files) expect(f.text).toBe(readFileSync(join(LESSONS_DIR, l.id, 'project', f.path), 'utf8'));
      expect(main).toContain(`<a href="${TUTORIAL_PATH}">Tutorial</a>`);
      expect(main).toContain(serialize(lessonArticle(l).node));
    });
  });

  test("hello's text renders through the Markdown renderer, with no fallback in any lesson", () => {
    const main = mainOf(real.page('tutorial/hello/index.html'));
    expect(main).toContain('<p>Press <strong>Run</strong>: mopm builds the program');
    expect(main).toContain('<code>src/main.mojo</code>');
    for (const l of LESSONS) expect([l.id, lessonArticle(l).fallbacks]).toEqual([l.id, 0]);
  });

  test('the index lists every lesson in order, each a link to its route with its summary', () => {
    const main = mainOf(real.page('tutorial/index.html'));
    const items = LESSONS.map((l) => `<li><h2><a href="/tutorial/${l.id}">${l.title}</a></h2><p>${l.summary}</p></li>`);
    expect(main).toContain(`<ol class="lesson-list">${items.join('')}</ol>`);
  });

  // The header's account box is every page's, its sign-in link back to the page's own route (test/layout.test.ts holds
  // it on the pages of dist/); nothing else of a page is a sign-in: the lesson's own sign-in card is the script's.
  test("the pages are the shell every page has, with no sign-in but the header's, the shared stylesheet only and the page script; a lesson's page loads the tutorial bundle after it, the index does not", () => {
    for (const p of real.pages) {
      const page = real.page(p);
      const route = `/${p.replace(/\/?index\.html$/, '')}`;
      const account = `<div class="site-account" id="site-account"><a class="button sign-in" href="/api/v2/auth/web/start?return_to=${encodeURIComponent(route)}"><span>Sign in<span class="sign-in-more"> with GitHub</span></span></a></div>`;
      expect([p, page.split(account).length]).toEqual([p, 2]);
      const html = page.replace(account, '');
      expect(html).toContain('<body data-page="tutorial">');
      expect(html).toContain(`<link rel="stylesheet" href="/assets/${real.id}/site.css">`);
      expect(html.match(/rel="stylesheet"/g)).toHaveLength(1);
      const scripts = [moduleScript(`/assets/${real.id}/main.js`)];
      if (p !== 'tutorial/index.html') scripts.push(moduleScript(`/assets/${real.id}/${TUTORIAL_BUNDLE}`));
      expect([p, scriptsOf(html)]).toEqual([p, scripts]);
      expect(html).not.toMatch(/sign[ -]?in|sign out|log ?in|\/api\//i);
      expect(html).toContain('<nav class="site-nav" aria-label="Site"><ul><li><a href="/search">Packages</a></li><li><a href="/docs/">Docs</a></li>');
    }
  });

  test('the pages pass the page rules of dist/', () => {
    expect(() => checkDist(real.f.outDir)).not.toThrow();
  });
});

describe('how the tutorial is reached', () => {
  // The header's "Tutorial" entry, and nothing else: every stage deploys this one build, and a stage without the
  // tutorial's E2B template serves no tutorial page (service/infra/stacks/lib/site-stack.ts servesTutorial), so the stack
  // takes the entry out of its pages (tools/tutorial-link.ts) and any other link would lead to its 404 page.
  test("a page outside tutorial/ links to a tutorial page by the header's Tutorial entry alone", () => {
    for (const p of real.files.filter((f) => f.endsWith('.html') && !f.startsWith('tutorial/'))) {
      const html = readFileSync(join(real.f.outDir, p), 'utf8');
      const hrefs = (h: string) => tagsIn(h).flatMap(([, attrs]) => attrs.filter(([k]) => k === 'href').map(([, v]) => v));
      expect([p, hrefs(html).filter((h) => h.startsWith(TUTORIAL_PATH))]).toEqual([p, [TUTORIAL_PATH]]);
      expect([p, hrefs(withoutTutorialLink(p, html)).filter((h) => h.startsWith(TUTORIAL_PATH))]).toEqual([p, []]);
    }
  });

  test("the route vectors serve /tutorial and /tutorial/<lesson> from the build's pages, and every other tutorial path is the 404 page or a file", () => {
    expect(vectors.files.filter((f) => f.startsWith(`${TUTORIAL_PATH}/`))).toEqual([
      '/tutorial/hello/index.html',
      '/tutorial/index.html',
      '/tutorial/structs/index.html',
      '/tutorial/tests/index.html',
    ]);
    const tutorial = vectors.vectors.filter((v) => v.path.startsWith(TUTORIAL_PATH));
    const served = tutorial.filter((v) => v.edge !== '/404.html' && v.edge !== 'pass').map((v) => [v.path, v.edge]);
    expect(served).toEqual([
      ['/tutorial', '/tutorial/index.html'],
      ['/tutorial/hello', '/tutorial/hello/index.html'],
    ]);
    for (const v of tutorial) expect([v.path, v.view]).toEqual([v.path, null]);
    // The pages' own files pass to the bucket as they are, and a trailing slash is no page.
    expect(tutorial.filter((v) => v.edge === 'pass').map((v) => v.path)).toEqual([
      '/tutorial/index.html',
      '/tutorial/hello/index.html',
      '/tutorial/structs/index.html',
      '/tutorial/tests/index.html',
    ]);
    for (const p of ['/tutorial/', '/tutorial/hello/']) expect(tutorial).toContainEqual({ path: p, edge: '/404.html', view: null });
  });

  test.each(['/tutorial', '/tutorial/', '/tutorial/hello', '/tutorial/hello/', '/tutorial/index.html', '/tutorial/hello/index.html'])(
    'parseRoute(%j) is no app route',
    (p) => {
      expect(parseRoute(p)).toBeNull();
    },
  );
});

describe('a lesson tree of the tests', () => {
  test('the index follows order, not directory name, and each page its place', () => {
    const t = lessonTree({ zeta: goodLesson(1), alpha: goodLesson(5), mid: goodLesson(3) });
    trees.push(t);
    const b = built(t);
    const main = mainOf(b.page('tutorial/index.html'));
    expect([...main.matchAll(/href="\/tutorial\/([a-z]+)"/g)].map((m) => m[1])).toEqual(['zeta', 'mid', 'alpha']);
    expect(mainOf(b.page('tutorial/alpha/index.html'))).toContain('Lesson 3 of 3');
    expect(mainOf(b.page('tutorial/zeta/index.html'))).toContain('Lesson 1 of 3');
  });

  test('title and summary are text: markup in them is escaped', () => {
    const t = lessonTree({ x: { ...goodLesson(1), json: lessonJson(1, { title: '<script>alert(1)</script>', summary: '"><img src=x onerror=alert(1)>' }) } });
    trees.push(t);
    const b = built(t);
    for (const p of b.pages) {
      const html = b.page(p);
      expect(html).not.toContain('<script>alert');
      expect(html).not.toContain('<img');
      expect(() => tagsIn(html)).not.toThrow();
    }
    expect(b.page('tutorial/x/index.html')).toContain('<h1>&lt;script&gt;alert(1)&lt;/script&gt;</h1>');
    expect(b.page('tutorial/x/index.html')).toContain('<meta name="description" content="&quot;&gt;&lt;img src=x onerror=alert(1)&gt;">');
  });

  test('a tutorial page that breaks a page rule, or a file under tutorial/ that is no page, is refused', () => {
    const t = lessonTree({ x: { ...goodLesson(1), md: 'plain text\n' } });
    trees.push(t);
    const b = built(t);
    const p = join(b.f.outDir, 'tutorial', 'x', 'index.html');
    const page = readFileSync(p, 'utf8');
    writeFileSync(p, page.replace('</main>', '<script>alert(1)</script><a href="/assets/gone.css">x</a></main>'));
    writeFileSync(join(b.f.outDir, 'tutorial', 'x', 'data.json'), '{}');
    expect(() => checkDist(b.f.outDir)).toThrow(DistError);
    expect(() => checkDist(b.f.outDir)).toThrow(
      'dist check failed:\n  tutorial/x/data.json: only .html, .js and .css files are published\n  tutorial/x/index.html: an inline <script>\n  tutorial/x/index.html: a <script> without one src under /assets/\n  tutorial/x/index.html: references /assets/gone.css, which is not in dist',
    );
  });
});

// Each lesson's page ends with a link to the lesson before it and the lesson after it, in the index's order (order, not
// directory name), in the prerendered HTML: no script builds them and nothing about them needs a session. The first
// lesson has only Next, the last only Previous, and a tutorial of one lesson has neither, so no empty <nav>.
describe("a lesson's Previous and Next links", () => {
  const PREV = (id: string, title: string): string => `<a class="button" href="/tutorial/${id}" rel="prev">← Previous: ${title}</a>`;
  const NEXT = (id: string, title: string): string => `<a class="button button-primary" href="/tutorial/${id}" rel="next">Next: ${title} →</a>`;
  const PAGER = (...links: string[]): string => `<nav class="pager" aria-label="Lessons">${links.join('')}</nav>`;
  const tree = (lessons: Parameters<typeof lessonTree>[0]) => {
    const t = lessonTree(lessons);
    trees.push(t);
    return built(t);
  };

  test('one lesson: its page has no Previous, no Next and no pager, and ends with the runner', () => {
    const b = tree({ only: goodLesson(1) });
    const main = mainOf(b.page('tutorial/only/index.html'));
    expect(main.endsWith('</section>')).toBe(true);
    expect(main).not.toMatch(/rel="(prev|next)"|class="pager"|Previous|Next/);
  });

  test('two lessons: the first has only Next, to the second; the second only Previous, to the first', () => {
    const b = tree({ second: goodLesson(2), first: goodLesson(1) });
    expect(mainOf(b.page('tutorial/first/index.html')).endsWith(`</section>${PAGER(NEXT('second', 'Lesson 2'))}`)).toBe(true);
    expect(mainOf(b.page('tutorial/second/index.html')).endsWith(`</section>${PAGER(PREV('first', 'Lesson 1'))}`)).toBe(true);
  });

  // The ids sort the other way from the order (zeta first), and the orders have gaps, so a page that took its
  // neighbours from the directory listing or from order ± 1 links the wrong lesson or none.
  test('three lessons: the middle one has both, each page links its neighbours in the order of the index', () => {
    const b = tree({ zeta: goodLesson(1), alpha: goodLesson(9), mid: goodLesson(4) });
    const index = mainOf(b.page('tutorial/index.html'));
    expect([...index.matchAll(/href="\/tutorial\/([a-z]+)"/g)].map((m) => m[1])).toEqual(['zeta', 'mid', 'alpha']);
    const pages = Object.fromEntries(['zeta', 'mid', 'alpha'].map((id) => [id, mainOf(b.page(`tutorial/${id}/index.html`))]));
    expect(pages.zeta.endsWith(`</section>${PAGER(NEXT('mid', 'Lesson 4'))}`)).toBe(true);
    expect(pages.mid.endsWith(`</section>${PAGER(PREV('zeta', 'Lesson 1'), NEXT('alpha', 'Lesson 9'))}`)).toBe(true);
    expect(pages.alpha.endsWith(`</section>${PAGER(PREV('mid', 'Lesson 4'))}`)).toBe(true);
    // One pager a page, and every link it holds is a page of this build.
    for (const [id, main] of Object.entries(pages)) {
      expect([id, main.split('<nav class="pager"').length]).toEqual([id, 2]);
      for (const m of main.matchAll(/href="\/tutorial\/([a-z]+)" rel=/g)) expect(b.pages).toContain(`tutorial/${m[1]}/index.html`);
    }
    expect(() => checkDist(b.f.outDir)).not.toThrow();
  });

  test("a neighbour's title is text in the link: markup in it is escaped", () => {
    const b = tree({ a: goodLesson(1), b: { ...goodLesson(2), json: lessonJson(2, { title: '<b>"&</b>' }) } });
    const main = mainOf(b.page('tutorial/a/index.html'));
    expect(main.endsWith(`</section>${PAGER(NEXT('b', '&lt;b&gt;"&amp;&lt;/b&gt;'))}`)).toBe(true);
    expect(() => tagsIn(b.page('tutorial/a/index.html'))).not.toThrow();
  });

  test("the repository's lessons: each page links the lessons before and after it in LESSONS, and the first and last only one", () => {
    LESSONS.forEach((l, i) => {
      const links = [i > 0 ? PREV(LESSONS[i - 1].id, escapeText(LESSONS[i - 1].title)) : null, i + 1 < LESSONS.length ? NEXT(LESSONS[i + 1].id, escapeText(LESSONS[i + 1].title)) : null].filter((x) => x !== null);
      const main = mainOf(real.page(`tutorial/${l.id}/index.html`));
      expect([l.id, main.endsWith(`</section>${links.length === 0 ? '' : PAGER(...links)}`)]).toEqual([l.id, true]);
    });
  });

  // The tutorial's pages load site.css alone (tools/layout.ts AREA_STYLESHEETS), so the pager's layout has to be there:
  // a .pager rule left in search.css would leave the links unstyled on every lesson page. A long title wraps inside its
  // button: .button is `flex: none; white-space: nowrap`, which on a 320px screen would push a long Next link past the
  // edge, so the pager's buttons may shrink and wrap, and the links wrap onto two rows rather than overflow.
  test("the pager's rules are in a stylesheet the tutorial's pages load, and a long title wraps", () => {
    const sheets = stylesheetsFor('tutorial').map((f) => readFileSync(join(__dirname, '..', 'static', f), 'utf8')).join('\n');
    expect(sheets).toContain('\n.pager { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 1rem; margin-top: 8px; }\n');
    expect(sheets).toContain('\n.pager a[rel="next"] { margin-left: auto; }\n');
    expect(sheets).toContain('\n.pager .button { flex: 0 1 auto; white-space: normal; }\n');
  });
});

describe('hostile Markdown in a lesson renders inert', () => {
  const corpus = readFileSync(join(__dirname, 'fixtures', 'attacks.md'), 'utf8');
  const cases = corpus
    .split(/^%%% /m)
    .slice(1)
    .map((chunk) => {
      const nl = chunk.indexOf('\n');
      return [chunk.slice(0, nl), chunk.slice(nl + 1)] as const;
    });
  // One lesson per case, and one holding the whole corpus, built as one tree: every page goes through the real build.
  const ids = cases.map((_c, i) => `attack-${i + 1}`);
  const t = lessonTree({
    ...Object.fromEntries(cases.map(([, src], i) => [ids[i], { ...goodLesson(i + 1), md: src }])),
    corpus: { ...goodLesson(cases.length + 1), md: corpus },
  });
  trees.push(t);
  const b = built(t);

  test('the corpus has its cases, and each is a page of the build', () => {
    expect(cases.length).toBeGreaterThanOrEqual(30);
    expect(b.pages).toHaveLength(cases.length + 2);
  });

  // A lesson's text is rendered as a docs page is (heading anchors, code blocks in a labelled copy box), so it may hold
  // the docs extras too: a span for a code block's language, and aria-hidden on it.
  const LESSON_TAGS = new Set([...MD_TAGS, 'span']);
  const LESSON_ATTRS = new Set([...MD_ATTRS, 'aria-hidden']);
  const check = (id: string): void => {
    const html = b.page(`tutorial/${id}/index.html`);
    const article = /<article class="prose lesson">([\s\S]*?)<\/article>\n?<section id="lesson-runner"/.exec(html);
    expect(article).not.toBeNull();
    // Only renderer markup inside the article, and every href a checked one: an in-page fragment of the lesson, a
    // published doc, or an http(s)/mailto URL. (tagsOf throws on any '<' that is not such a tag.)
    for (const { tag, attrs } of tagsOf((article as RegExpExecArray)[1], LESSON_TAGS)) {
      expect(LESSON_TAGS).toContain(tag);
      for (const [k, v] of attrs) {
        expect(LESSON_ATTRS).toContain(k);
        if (k !== 'href') continue;
        const href = unescapeAttr(v);
        if (href.startsWith('#')) expect(href.startsWith(`#${LESSON_ID_PREFIX}`)).toBe(true);
        else if (href.startsWith('/')) expect(href).toMatch(/^\/docs\/[a-z0-9-]+\/(#.*)?$/);
        else expect(['https:', 'http:', 'mailto:']).toContain(new URL(href).protocol);
      }
    }
    // The whole page as a browser reads it: no script, handler, style or script URL anywhere.
    for (const [tag, attrs] of tagsIn(html)) {
      expect(['img', 'svg', 'iframe', 'style', 'object', 'embed']).not.toContain(tag);
      for (const [k] of attrs) expect(k).not.toMatch(/^(on|style$)/i);
    }
    // main.js and the tutorial bundle, the layout's two module scripts, and nothing the lesson wrote.
    expect(scriptsOf(html)).toEqual([moduleScript(`/assets/${b.id}/main.js`), moduleScript(`/assets/${b.id}/${TUTORIAL_BUNDLE}`)]);
  };

  test.each(cases.map(([name], i) => [name, ids[i]] as const))('%s', (_name, id) => check(id));

  test('the whole corpus as one lesson', () => check('corpus'));

  test('raw HTML in a lesson is shown as text', () => {
    const html = b.page(`tutorial/${ids[cases.findIndex(([, src]) => src.includes('<script'))]}/index.html`);
    expect(html).toContain('&lt;script');
  });
});
