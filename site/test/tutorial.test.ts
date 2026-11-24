// The tutorial's prerendered pages (tools/tutorial.ts, written by tools/build.ts to the held tree): every lesson of the
// repository renders, with its title, its place and the runner's mount point, in the shell every page has and with no
// sign-in; the index lists the lessons in order; hostile Markdown in a lesson renders inert; and nothing serves them yet:
// dist/ holds no tutorial file, so the edge router (which serves the files of dist/ and the routes of src/routes.ts) has
// none to serve, the route vectors name none, parseRoute routes none, and no page links to one.
import vectors from './fixtures/routes.json';
import { readFileSync, rmSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { serialize } from '../src/doc';
import { parseRoute } from '../src/routes';
import { checkHeld, DistError, tagsIn } from '../tools/check-dist';
import { LESSON_SCHEMA, loadLessons, readLessonSchema } from '../tools/lessons';
import { LESSON_ID_PREFIX, lessonArticle, RUNNER_ID, TUTORIAL_PATH } from '../tools/tutorial';
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

function built(lessonsDir?: string): { f: Fixture; id: string; files: string[]; held: string[]; page: (p: string) => string } {
  const f = fixture({}, lessonsDir);
  made.push(f);
  const r = f.build();
  return { f, ...r, page: (p) => readFileSync(join(f.heldDir, p), 'utf8') };
}

const real = built();

/** <main>'s inner HTML. */
const mainOf = (html: string): string => {
  const m = /<main id="main" class="wrap" tabindex="-1">([\s\S]*)<\/main>/.exec(html);
  if (!m) throw new Error('no <main>');
  return m[1];
};

describe('the held tree of a build of the repository', () => {
  test('holds the index and one page per lesson, at the paths of their routes, and nothing else', () => {
    expect(real.held).toEqual(['tutorial/index.html', ...LESSONS.map((l) => `tutorial/${l.id}/index.html`)].sort());
  });

  test('every lesson renders: its title as the h1, its place, its text, and the empty runner mount', () => {
    LESSONS.forEach((l, i) => {
      const html = real.page(`tutorial/${l.id}/index.html`);
      const main = mainOf(html);
      expect(html).toContain(`<title>${l.title} (tutorial) · mopm</title>`);
      expect(main.match(/<h1>/g)).toHaveLength(1);
      expect(main).toContain(`<h1>${l.title}</h1>`);
      expect(main).toContain(`<p class="lesson-place muted small">Lesson ${i + 1} of ${LESSONS.length}</p>`);
      expect(main).toContain(`<section id="${RUNNER_ID}" class="lesson-runner" aria-label="Try it"></section>`);
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

  test('the pages are the shell every page has, with no sign-in, the shared stylesheet only and the page script', () => {
    for (const p of real.held) {
      const html = real.page(p);
      expect(html).toContain('<body data-page="tutorial">');
      expect(html).toContain(`<link rel="stylesheet" href="/assets/${real.id}/site.css">`);
      expect(html.match(/rel="stylesheet"/g)).toHaveLength(1);
      expect(html).toContain(`<script type="module" src="/assets/${real.id}/main.js"></script>`);
      expect(html).not.toMatch(/sign[ -]?in|sign out|log ?in|\/api\//i);
      expect(html).toContain('<nav class="site-nav" aria-label="Site"><ul><li><a href="/search">Packages</a></li><li><a href="/docs/">Docs</a></li>');
    }
  });

  test('the held pages pass the page rules of dist/', () => {
    expect(() => checkHeld(real.f.heldDir, real.f.outDir)).not.toThrow();
  });
});

describe('nothing serves the tutorial yet', () => {
  test('dist/ holds no tutorial file, and no page of it links to one', () => {
    expect(real.files.filter((f) => /^tutorial\b/.test(f))).toEqual([]);
    for (const p of real.files.filter((f) => f.endsWith('.html'))) {
      const hrefs = tagsIn(readFileSync(join(real.f.outDir, p), 'utf8')).flatMap(([, attrs]) => attrs.filter(([k]) => k === 'href').map(([, v]) => v));
      expect([p, hrefs.filter((h) => h.startsWith(TUTORIAL_PATH))]).toEqual([p, []]);
    }
  });

  test('the route vectors name no tutorial file and no tutorial path the router answers with a page', () => {
    expect(vectors.files.filter((f) => f.startsWith(TUTORIAL_PATH))).toEqual([]);
    const tutorial = vectors.vectors.filter((v) => v.path === TUTORIAL_PATH || v.path.startsWith(`${TUTORIAL_PATH}/`));
    expect(tutorial.length).toBeGreaterThan(0);
    for (const v of tutorial) expect([v.path, v.edge, v.view]).toEqual([v.path, '/404.html', null]);
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
    for (const p of b.held) {
      const html = b.page(p);
      expect(html).not.toContain('<script>alert');
      expect(html).not.toContain('<img');
      expect(() => tagsIn(html)).not.toThrow();
    }
    expect(b.page('tutorial/x/index.html')).toContain('<h1>&lt;script&gt;alert(1)&lt;/script&gt;</h1>');
    expect(b.page('tutorial/x/index.html')).toContain('<meta name="description" content="&quot;&gt;&lt;img src=x onerror=alert(1)&gt;">');
  });

  test('a held tree with a page that breaks a page rule, or a file that is no page, is refused', () => {
    const t = lessonTree({ x: { ...goodLesson(1), md: 'plain text\n' } });
    trees.push(t);
    const b = built(t);
    const p = join(b.f.heldDir, 'tutorial', 'x', 'index.html');
    const page = readFileSync(p, 'utf8');
    writeFileSync(p, page.replace('</main>', '<script>alert(1)</script><a href="/assets/gone.css">x</a></main>'));
    writeFileSync(join(b.f.heldDir, 'tutorial', 'x', 'data.json'), '{}');
    expect(() => checkHeld(b.f.heldDir, b.f.outDir)).toThrow(DistError);
    expect(() => checkHeld(b.f.heldDir, b.f.outDir)).toThrow(
      'dist check failed:\n  held/tutorial/x/data.json: only .html pages are held\n  held/tutorial/x/index.html: an inline <script>\n  held/tutorial/x/index.html: a <script> without one src under /assets/\n  held/tutorial/x/index.html: references /assets/gone.css, which is not in dist',
    );
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
    expect(b.held).toHaveLength(cases.length + 2);
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
    expect(html.match(/<script\b/g)).toHaveLength(1);
  };

  test.each(cases.map(([name], i) => [name, ids[i]] as const))('%s', (_name, id) => check(id));

  test('the whole corpus as one lesson', () => check('corpus'));

  test('raw HTML in a lesson is shown as text', () => {
    const html = b.page(`tutorial/${ids[cases.findIndex(([, src]) => src.includes('<script'))]}/index.html`);
    expect(html).toContain('&lt;script');
  });
});
