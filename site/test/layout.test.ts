// T15: every built page is a complete, accessible document with nothing inline: lang, a title, exactly one h1, a skip
// link to <main id="main">, the header, nav, main and footer landmarks, and no inline script, style or event handler.
// And the home page says only what the repository says: README.md's opening sentence word for word, its list of the
// commands that work today, src/cli/main.zig's planned commands, and a quickstart of working commands only. And its
// install story is the installer's and the release's: the command, the targets, the asset names, the verification
// commands and the version series are held to site/static/install.sh, README.md and VERSION.
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { TAGS } from '../src/doc';
import { DOC_PAGES } from '../src/links';
import { tagsIn } from '../tools/check-dist';
import { ASSET_PATTERN, INSTALL_COMMAND, OPENING_SENTENCE, PLANNED, RELEASE_SERIES, TARGETS, VERIFY, WORKING_TODAY } from '../tools/pages';
import { cleanup, type Fixture, fixture, REPO_ROOT } from './build-fixture';

let f: Fixture;
let pages: string[];
const read = (p: string) => readFileSync(join(f.outDir, p), 'utf8');

beforeAll(() => {
  f = fixture();
  pages = f.build().files.filter((p) => p.endsWith('.html'));
});
afterAll(() => cleanup(f));

/** Tags only the page shell may hold (layout.ts writes them; views cannot build them). */
const SHELL_TAGS = new Set(['html', 'head', 'body', 'title', 'link', 'script', 'meta', 'noscript']);
const ALL_TAGS = new Set<string>([...TAGS, ...SHELL_TAGS]);

function textOf(html: string): string {
  return html
    .replace(/<[^>]*>/g, '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
}

/** The inner HTML of the element with this id (no nested element of the same tag inside it, as here). */
function byId(html: string, id: string): string {
  const m = new RegExp(`<([a-z0-9]+)[^>]* id="${id}"[^>]*>`).exec(html);
  if (!m) throw new Error(`no element #${id}`);
  const start = m.index + m[0].length;
  return html.slice(start, html.indexOf(`</${m[1]}>`, start));
}

// The pages the build writes: the home page, the 404, the app shell, the docs index and one page per doc.
const DOC_HTML = ['docs/why/index.html', 'docs/getting-started/index.html', 'docs/configuration/index.html', 'docs/examples/index.html', 'docs/mopm-toml/index.html', 'docs/mopm-test/index.html', 'docs/publish-workspace/index.html'];
const ALL_PAGES = ['404.html', 'app.html', 'docs/index.html', ...DOC_HTML, 'index.html'];

test('the eleven pages are built', () => {
  expect([...pages].sort()).toEqual([...ALL_PAGES].sort());
});

describe.each(ALL_PAGES)('%s', (page) => {
  let html: string;
  let tags: ReturnType<typeof tagsIn>;
  beforeAll(() => {
    html = read(page);
    tags = tagsIn(html);
  });
  const count = (tag: string) => tags.filter(([t]) => t === tag).length;

  test('a doctype, lang="en", utf-8, a viewport', () => {
    expect(html.startsWith('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')).toBe(true);
    expect(html).toContain('<meta name="viewport" content="width=device-width, initial-scale=1">');
  });

  test('one non-empty title ending in the site name', () => {
    expect(count('title')).toBe(1);
    expect(html).toMatch(/<title>(?:mopm|[^<]+ · mopm)<\/title>/);
  });

  test('exactly one h1', () => {
    expect(count('h1')).toBe(1);
  });

  test('a skip link first in the body, to <main id="main">', () => {
    expect(html).toMatch(/<body data-page="[a-z]+">\n<a class="skip" href="#main">Skip to content<\/a>/);
    // The home page's bands run the full width, each with its own wrap; every other page's <main> is one wrap.
    expect(html).toContain(page === 'index.html' ? '<main id="main" class="home" tabindex="-1">' : '<main id="main" class="wrap" tabindex="-1">');
    expect(count('main')).toBe(1);
  });

  test('header, nav (with a label), main and footer landmarks', () => {
    expect(count('header')).toBeGreaterThanOrEqual(1);
    expect(count('footer')).toBe(1);
    expect(html).toContain('<nav class="site-nav" aria-label="Site">');
    expect(html).toContain('<nav aria-label="Footer">');
  });

  // copy.ts finds a .copy-box's one <pre> and adds the button at runtime; a prerendered button would do nothing
  // without scripts, and a box with two blocks would copy the wrong one.
  test('every copy box holds exactly one named <pre> and no button', () => {
    const boxes = html.split(/<div class="[^"]*\bcopy-box\b[^"]*">/).slice(1).map((b) => b.slice(0, b.indexOf('</div>')));
    for (const b of boxes) {
      expect(b.match(/<pre /g)).toHaveLength(1);
      expect(b).toMatch(/<pre tabindex="0" role="region" aria-label(?:ledby)?="[^"]+"/);
      expect(b).not.toContain('<button');
    }
    if (page === 'index.html') expect(boxes.length).toBeGreaterThanOrEqual(3);
    // Every docs code block is a copy box (every published doc has code). Defect caught: the renderer's docs option off.
    if (DOC_HTML.includes(page)) {
      expect(boxes.length).toBeGreaterThanOrEqual(1);
      expect(boxes.length).toBe(html.split('<pre ').length - 1);
    }
  });

  // Each page links the shared sheet first, then only its own area's (layout.ts AREA_STYLESHEETS). Defect caught: the docs
  // pages loading home.css; the app shell dropping search.css (the search view unstyled); site.css not first.
  test('the shared stylesheet first, then only the area stylesheets this page uses', () => {
    const want: Record<string, string[]> = {
      'index.html': ['site.css', 'home.css'],
      'app.html': ['site.css', 'package.css', 'search.css'],
      '404.html': ['site.css'],
    };
    const sheets = tags.filter(([t, a]) => t === 'link' && a.some(([k, v]) => k === 'rel' && v === 'stylesheet')).map(([, a]) => (a.find(([k]) => k === 'href') as [string, string])[1]);
    expect(sheets.map((h) => h.replace(/^\/assets\/[0-9a-f]{16}\//, ''))).toEqual(want[page] ?? ['site.css', 'docs.css']);
  });

  test('one search field with id q (the "/" key focuses it), in a named search form that submits to /search', () => {
    expect(tags.filter(([, a]) => a.some(([k, v]) => k === 'id' && v === 'q'))).toHaveLength(1);
    if (page === 'index.html') {
      // The home page's own search is its first control; the header has none.
      expect(html).not.toContain('class="site-search"');
      expect(html).toContain('<form class="hero-search" role="search" action="/search" method="get" aria-label="Search the registry"><label for="q" class="visually-hidden">Find a package by name</label>');
    } else {
      expect(html).toContain('<form class="site-search" role="search" action="/search" method="get" aria-label="Site search"><label for="q" class="visually-hidden">Search packages</label><input id="q" name="q"');
    }
  });

  test('every search landmark has its own name', () => {
    const names = tags.filter(([, a]) => a.some(([k, v]) => k === 'role' && v === 'search')).map(([, a]) => a.find(([k]) => k === 'aria-label')?.[1]);
    expect(names.every((n) => n !== undefined && n !== '')).toBe(true);
    expect(new Set(names).size).toBe(names.length);
  });

  test('a named code block has a role (ARIA does not name a bare <pre>)', () => {
    for (const [, a] of tags.filter(([t, a2]) => t === 'pre' && a2.some(([k]) => k === 'aria-label' || k === 'aria-labelledby'))) {
      expect(a.find(([k]) => k === 'role')?.[1]).toBe('region');
    }
  });

  test('nothing inline: scripts have a src, no style element or attribute, no event handler', () => {
    for (const [tag, attrs] of tags) {
      expect(ALL_TAGS).toContain(tag);
      const names = attrs.map(([k]) => k);
      if (tag === 'script') expect(names).toContain('src');
      expect(names.filter((k) => k === 'style' || k.startsWith('on'))).toEqual([]);
    }
    expect(count('style')).toBe(0);
    expect(count('script')).toBe(1);
  });

  test('every id is unique', () => {
    const ids = tags.flatMap(([, a]) => a.filter(([k]) => k === 'id').map(([, v]) => v));
    expect(new Set(ids).size).toBe(ids.length);
  });

  test('every label names a control that exists', () => {
    const ids = new Set(tags.flatMap(([, a]) => a.filter(([k]) => k === 'id').map(([, v]) => v)));
    for (const [, a] of tags.filter(([t]) => t === 'label')) {
      const forId = a.find(([k]) => k === 'for')?.[1];
      expect(forId && ids.has(forId)).toBe(true);
    }
  });
});

describe('the docs pages', () => {
  const firstHeading = (source: string) => (/^# +(.+)$/m.exec(readFileSync(join(REPO_ROOT, source), 'utf8')) as RegExpExecArray)[1].replace(/`/g, '');

  test.each([
    ['docs/why/index.html', 'docs/why-and-design.md'],
    ['docs/getting-started/index.html', 'docs/getting-started.md'],
    ['docs/configuration/index.html', 'docs/configuration.md'],
    ['docs/examples/index.html', 'docs/examples.md'],
    ['docs/mopm-toml/index.html', 'spec/mopm-toml.md'],
    ['docs/mopm-test/index.html', 'docs/mopm-test.md'],
    ['docs/publish-workspace/index.html', 'docs/publishing-a-workspace.md'],
  ])('%s: the title is the first heading of %s, and the Source link is that file on GitHub', (page, source) => {
    const html = read(page);
    expect(html).toContain(`<title>${firstHeading(source)} · mopm</title>`);
    expect(html).toContain(`<a href="https://github.com/komira-ai/mopm/blob/main/${source}"><code>${source}</code> on GitHub</a>`);
  });

  test('the Docs nav entry is the current page on /docs/ and its parent on a doc page', () => {
    expect(read('docs/index.html')).toContain('<a href="/docs/" aria-current="page">Docs</a>');
    expect(read('docs/mopm-test/index.html')).toContain('<a href="/docs/" aria-current="true">Docs</a>');
    expect(read('docs/mopm-test/index.html')).toContain('<nav class="crumb" aria-label="Breadcrumb"><a href="/docs/">Docs</a><span class="sep" aria-hidden="true">/</span><span aria-current="page">');
    expect(read('index.html')).not.toContain('aria-current');
  });

  // The docs nav lists the index and every published doc, each by its title, and marks the page shown. Defect caught: a doc
  // left out of the nav; aria-current on the wrong entry, or on none; a link reading as its slug ('mopm-toml') instead
  // of the doc's title, or the index entry not reading 'Overview'.
  test.each([
    ['docs/index.html', '/docs/'],
    ['docs/why/index.html', '/docs/why/'],
    ['docs/getting-started/index.html', '/docs/getting-started/'],
    ['docs/configuration/index.html', '/docs/configuration/'],
    ['docs/examples/index.html', '/docs/examples/'],
    ['docs/mopm-toml/index.html', '/docs/mopm-toml/'],
    ['docs/mopm-test/index.html', '/docs/mopm-test/'],
    ['docs/publish-workspace/index.html', '/docs/publish-workspace/'],
  ])('%s: the docs nav lists every docs page and marks this one', (page, self) => {
    const html = read(page);
    const nav = html.slice(html.indexOf('<nav class="docs-nav" aria-label="Docs pages">'));
    const list = nav.slice(0, nav.indexOf('</nav>'));
    expect([...list.matchAll(/<a href="([^"]+)"/g)].map((m) => m[1])).toEqual(['/docs/', '/docs/why/', '/docs/getting-started/', '/docs/configuration/', '/docs/examples/', '/docs/mopm-toml/', '/docs/mopm-test/', '/docs/publish-workspace/']);
    expect([...list.matchAll(/<a href="([^"]+)" aria-current="page">/g)].map((m) => m[1])).toEqual([self]);
    // Each doc's title read here from its source's first '# ' heading, not through docTitle.
    const titles = DOC_PAGES.map((d) => {
      const line = readFileSync(join(REPO_ROOT, d.source), 'utf8').split('\n').find((l) => l.startsWith('# '));
      if (!line) throw new Error(`${d.source}: no '# ' heading`);
      return line.slice(2).replace(/`|\*\*/g, '').trim();
    });
    const pairs = [...list.matchAll(/<a href="([^"]+)"[^>]*>([^<]*)<\/a>/g)].map((m) => [m[1], textOf(m[2])]);
    expect(pairs).toEqual([['/docs/', 'Overview'], ...DOC_PAGES.map((d, i) => [`/docs/${d.slug}/`, titles[i]])]);
    expect(pairs.filter(([href, label]) => DOC_PAGES.some((d) => href === `/docs/${d.slug}/` && label === d.slug))).toEqual([]);
  });

  // The on-this-page list holds the page's h2 and h3 headings, in order, each linked to its own id and reading as the
  // heading reads. Defect caught: a link to an id the page does not have (a prefix lost); h4 headings listed; the list out of
  // order; a link reading as the id ('doc-retries-and-flaky') instead of the heading's text.
  test.each(DOC_HTML)('%s: the on-this-page list is the h2 and h3 headings, in order, by their text', (page) => {
    const html = read(page);
    const toc = html.slice(html.indexOf('<nav class="toc" aria-label="On this page">'));
    const links = [...toc.slice(0, toc.indexOf('</nav>')).matchAll(/<li class="toc-([23])"><a href="#([^"]+)">([^<]*)<\/a>/g)].map((m) => [`h${m[1]}`, m[2], textOf(m[3])]);
    const headings = [...html.matchAll(/<(h[23]) id="([^"]+)">([\s\S]*?)<\/\1>/g)].map((m) => [m[1], m[2], textOf(m[3])]);
    expect(links.length).toBeGreaterThan(2);
    expect(links).toEqual(headings);
    expect(links.filter(([, id, label]) => label === id || label === '')).toEqual([]);
  });

  // Below the widest layout the on-this-page list is not a side column but a block between the breadcrumb and the
  // article, so a phone reader gets it too (docs.css shows it at every width). Defect caught: the toc after the article (it
  // would sit under a long page on a phone).
  test.each(DOC_HTML)('%s: the on-this-page list comes after the breadcrumb and before the article', (page) => {
    const html = read(page);
    const crumb = html.indexOf('<nav class="crumb" aria-label="Breadcrumb">');
    const toc = html.indexOf('<nav class="toc" aria-label="On this page">');
    const article = html.indexOf('<article class="prose doc">');
    expect(crumb).toBeGreaterThan(0);
    expect(toc).toBeGreaterThan(crumb);
    expect(article).toBeGreaterThan(toc);
  });

  // Each heading of a doc is a link to its own anchor, so a reader can copy a section's address. Defect caught: the anchor
  // pointing at another id; a heading holding a link getting an anchor around it (a link in a link).
  test.each(DOC_HTML)('%s: every heading links to its own anchor', (page) => {
    const html = read(page);
    const heads = [...html.matchAll(/<(h[1-6]) id="(doc-[^"]+)">([\s\S]*?)<\/\1>/g)];
    expect(heads.length).toBeGreaterThan(2);
    for (const [, , id, inner] of heads) {
      expect(inner.match(/<a /g)?.length ?? 0).toBeLessThanOrEqual(1);
      if (inner.includes('class="anchor"')) expect(inner).toMatch(new RegExp(`^<a href="#${id}" class="anchor">`));
    }
    expect(heads.filter(([, , id, inner]) => inner.startsWith(`<a href="#${id}" class="anchor">`)).length).toBeGreaterThan(2);
  });

  test('a doc summary on /docs/ is its first sentence', () => {
    const index = textOf(read('docs/index.html'));
    expect(index).toContain('mopm test finds the tests of a Mojo package, builds each test file once, and runs every test in a process of its own under a supervisor.');
    expect(index).not.toContain('test_cmd.zig');
    expect(index).toContain('mopm.toml sits at the root of a package.');
    // The two new docs, by their first sentences. Defect caught: a doc whose summary is not its first paragraph.
    expect(index).toContain('This is part one of the mopm documentation: the reasons and the design.');
    expect(index).toContain('This is part two of the mopm documentation: how to install it and use it.');
    // The HOW part continues with the reference and the examples, by their first sentences.
    expect(index).toContain('This page lists every setting mopm reads, in mopm.toml, in mopm.lock and in the configuration of the user, with its type, its default, the values it allows and an example.');
    expect(index).toContain('This page walks through six complete examples, from a library with a test to a package that pins its compiler, and every file in them is quoted from the examples/ directory of the repository.');
  });

  // The two parts of the plan: WHY and design first, then HOW. Defect caught: the docs in another order, or the second part
  // not linking back to the first (and the first forward).
  test('the why page links forward to getting started and the getting-started page back to why, on the site', () => {
    expect(read('docs/why/index.html')).toContain('<a href="/docs/getting-started/">getting-started.md</a>');
    expect(read('docs/getting-started/index.html')).toContain('<a href="/docs/why/">why-and-design.md</a>');
    expect(DOC_PAGES.slice(0, 2).map((d) => d.slug)).toEqual(['why', 'getting-started']);
  });

  // Every thing a doc says is not built is marked planned, as the home page marks its planned commands: the two new docs
  // name each planned command of src/cli/main.zig as planned and none as working. Defect caught: a planned command shown in a
  // working example.
  test.each(['docs/why-and-design.md', 'docs/getting-started.md'])('%s never shows a planned command as one that works', (source) => {
    const md = readFileSync(join(REPO_ROOT, source), 'utf8');
    const fenced = [...md.matchAll(/```[a-z]*\n([\s\S]*?)```/g)].map((m) => m[1]).join('\n');
    for (const cmd of PLANNED) expect(fenced).not.toMatch(new RegExp(`^\\s*mopm ${cmd}\\b`, 'm'));
    expect(md).toContain('**planned**');
  });
});

test('404.html and app.html: the 404 is not indexed; the app shell tells a reader without scripts what to do', () => {
  expect(read('404.html')).toContain('<meta name="robots" content="noindex">');
  // On-brand and a way on: a search box with its own id and name, Home, the package list and the docs. Defect caught: the
  // search box or the way-on row dropped.
  expect(read('404.html')).toContain('<form class="lost-search" role="search" action="/search" method="get" aria-label="Search the registry"><label for="lost-q" class="visually-hidden">');
  expect(read('404.html')).toContain('<ul class="way-on"><li><a href="/">Home</a></li><li><a href="/search">Browse packages</a></li><li><a href="/docs/">Docs</a></li></ul>');
  expect(read('app.html')).toMatch(/<noscript><div class="notice"><p>This page reads the registry API and needs JavaScript\./);
  expect(read('app.html')).toContain('<body data-page="app">');
});

describe('the home page says what the repository says', () => {
  const readme = readFileSync(join(REPO_ROOT, 'README.md'), 'utf8');
  const paragraphs = readme.split(/\n\s*\n/).map((p) => p.replace(/\s*\n\s*/g, ' ').trim());
  const plain = (md: string) => md.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');

  test("the opening sentence is README.md's, word for word", () => {
    const first = paragraphs.find((p) => p.startsWith('mopm is'));
    expect(first).toBeDefined();
    expect(plain(first as string)).toBe(OPENING_SENTENCE);
    expect(textOf(byId(read('index.html'), 'opening'))).toBe(OPENING_SENTENCE);
  });

  test("the commands that work today are README.md's Status list, in order", () => {
    const status = paragraphs.find((p) => p.startsWith('**Status: early.**')) as string;
    expect(status).toBeDefined();
    const listed = status.slice(0, status.indexOf(' work today')).match(/`mopm ([^`]+)`/g)?.map((s) => s.slice(6, -1));
    expect(listed).toEqual(WORKING_TODAY);
    const shown = textOf(byId(read('index.html'), 'status'));
    expect(shown).toBe(`Status: early. ${WORKING_TODAY.slice(0, -1).map((c) => `mopm ${c}`).join(', ')} and mopm ${WORKING_TODAY.at(-1)} work today. Everything else is a plan, and the design may change.`);
  });

  test("the planned commands are src/cli/main.zig's planned array, in order", () => {
    const zig = readFileSync(join(REPO_ROOT, 'src', 'cli', 'main.zig'), 'utf8');
    const block = /const planned = \[_\]\[\]const u8\{([^}]*)\}/.exec(zig);
    expect(block).not.toBeNull();
    expect([...(block as RegExpExecArray)[1].matchAll(/"([a-z-]+)"/g)].map((m) => m[1])).toEqual(PLANNED);
    const home = textOf(read('index.html'));
    expect(home).toContain(`Not implemented yet: ${PLANNED.slice(0, -1).join(', ')} and ${PLANNED.at(-1)}.`);
  });

  test('every mopm command the home page shows runs a command that works today', () => {
    const code = [...read('index.html').matchAll(/<code>([\s\S]*?)<\/code>/g)].map((m) => textOf(m[1]).replace(/^\$ /gm, '')).join('\n');
    const used = [...code.matchAll(/(?:^|\n|`)mopm ([a-z-]+)/g)].map((m) => m[1]);
    expect(used.length).toBeGreaterThan(5);
    for (const cmd of used) {
      if (!WORKING_TODAY.includes(cmd)) expect(PLANNED).toContain(cmd); // named only as planned, and main.zig still plans it
    }
    // In the command blocks (the build and the quickstart), every mopm line is a working command.
    // The terminal card's lines carry a '$ ' prompt (a span); it is not part of the command.
    const blocks = [...read('index.html').matchAll(/<pre[^>]*><code>([\s\S]*?)<\/code><\/pre>/g)].map((m) => textOf(m[1]).replace(/^\$ /gm, ''));
    const lines = blocks.flatMap((b) => b.split('\n')).filter((l) => l.startsWith('mopm '));
    expect(lines.length).toBeGreaterThanOrEqual(5);
    for (const l of lines) expect(WORKING_TODAY).toContain(l.split(/\s+/)[1]);
  });

  test('the scaffold block names only files mopm new makes; build and run are a separate block about your own file', () => {
    const home = read('index.html');
    const blocks = [...home.matchAll(/<pre[^>]*aria-label="([^"]*)"[^>]*><code>([^<]*)<\/code><\/pre>/g)].map((m) => [m[1], textOf(m[2])]);
    const quick = blocks.find(([label]) => label === 'Quickstart commands')?.[1] as string;
    expect(quick.split('\n')[0]).toMatch(/^mopm new my_package --lib\b/);
    expect(quick.split('\n')[1]).toBe('cd my_package');
    // Every file a scaffold-block command names exists in the scaffold golden (tests/new/lib).
    const files = quick.split('\n').flatMap((l) => l.replace(/#.*$/, '').split(/\s+/)).filter((w) => /\.(?:mojo|toml)$/.test(w));
    for (const file of files) expect(existsSync(join(REPO_ROOT, 'tests', 'new', 'lib', file))).toBe(true);
    expect(quick).not.toMatch(/mopm (?:build|run)\b/);
    const buildRun = blocks.find(([label]) => label === 'Build and run commands')?.[1] as string;
    expect(buildRun).toContain('mopm build hello.mojo -o hello');
    expect(textOf(byId(home, 'build-run'))).toBe('Build and run take a Mojo file with a main (hello.mojo here is your own file):');
  });

  test('the quickstart says it needs a Mojo environment before the first command block, as README.md names it', () => {
    const home = read('index.html');
    const env = textOf(byId(home, 'mojo-env'));
    expect(env).toBe('mopm runs the mojo of a Mojo environment: --prefix <dir>, else CONDA_PREFIX, else MODULAR_HOME without its /share/max. test, repl, build and run need one.');
    const readme = readFileSync(join(REPO_ROOT, 'README.md'), 'utf8').replace(/\s*\n\s*/g, ' ');
    expect(readme).toContain('The environment is `--prefix <dir>`, else `CONDA_PREFIX`, else `MODULAR_HOME` without its `/share/max`.');
    expect(home.indexOf('id="mojo-env"')).toBeGreaterThan(home.indexOf('id="quickstart"'));
    expect(home.indexOf('id="mojo-env"')).toBeLessThan(home.indexOf('aria-label="Quickstart commands"'));
    // Only build, run and repl replace mopm with mojo (an exec); test starts one mojo process per test.
    expect(textOf(byId(home, 'mojo-exec'))).toMatch(/^build, run and repl each run <env>\/bin\/mojo in place of mopm\b.* test starts one mojo process per test\./);
  });

  // The hero, stepper and registry columns are narrow: at 1440 pixels a stepper column holds about 40 characters of
  // 0.875rem monospace and the hero's install block about 60. Only the full-width "What mopm does now" band
  // (.home-wide) holds the long quickstart lines, so their comments are not cut off behind a scroll on a desktop.
  test('a home code block with a line over 46 characters is in the full-width band; stepper blocks are 40 or less', () => {
    const sections = read('index.html').split('<section class="').slice(1);
    let wide = 0;
    for (const sec of sections) {
      const cls = sec.slice(0, sec.indexOf('"'));
      for (const m of sec.matchAll(/<pre[^>]*><code>([\s\S]*?)<\/code><\/pre>/g)) {
        const longest = Math.max(...textOf(m[1]).split('\n').map((l) => l.length));
        if (longest > 46) {
          expect([cls, longest]).toEqual([expect.stringMatching(/\bhome-wide\b/), longest]);
          wide++;
        }
      }
    }
    expect(wide).toBeGreaterThan(0);
    const stepper = read('index.html').slice(read('index.html').indexOf('<ol class="stepper">'));
    for (const m of stepper.slice(0, stepper.indexOf('</ol>')).matchAll(/<code>([^<]*)<\/code><\/pre>/g)) {
      expect(textOf(m[1]).length).toBeLessThanOrEqual(40);
    }
  });

  // The commands that work today are the ones main.zig dispatches, both ways. Defect caught: a command added to main.zig's
  // dispatch (or removed from its usage) without the README and this page following.
  test("the working commands are the ones main.zig's usage lists and its dispatch handles", () => {
    const zig = readFileSync(join(REPO_ROOT, 'src', 'cli', 'main.zig'), 'utf8');
    const usage = zig.slice(zig.indexOf('working today:'), zig.indexOf('planned (not implemented yet)'));
    expect(usage.length).toBeGreaterThan(500);
    for (const c of WORKING_TODAY) expect(usage).toMatch(new RegExp(`(?:^|[^a-z-])${c}(?![a-z-])`, 'm'));
    const help = new Set(['-h', '--help', 'help']);
    const dispatched = [...zig.matchAll(/std\.mem\.eql\(u8, cmd, "(-?-?[A-Za-z-]+)"\)/g)].map((m) => m[1]).filter((c) => !help.has(c) && c !== '-V');
    expect(dispatched.length).toBeGreaterThan(15);
    for (const c of dispatched) expect(WORKING_TODAY).toContain(c);
    // build, run and repl are dispatched through mojo_cmd.Tool, not by name.
    for (const c of ['build', 'run', 'repl']) expect(WORKING_TODAY).toContain(c);
  });

  // The install story. Each fact is held to the file that makes it true, not to a second copy of the words:
  // site/static/install.sh (the command, the targets, the asset names, the verification commands), README.md (the
  // command again) and VERSION (the series). Variants are named at each test.
  describe('the install story', () => {
    const installSh = readFileSync(join(REPO_ROOT, 'site', 'static', 'install.sh'), 'utf8');
    const installHeader = installSh.split('\n').filter((l) => l.startsWith('#'));
    const readmeInstall = readme.slice(readme.indexOf('\n## Install'), readme.indexOf('\n## Goals'));
    const oneLine = (s: string) => s.replace(/\\\n/g, ' ').replace(/\s+/g, ' ').trim();

    // Defect caught: the page's command with another host, another flag, or no `| sh`; README.md and install.sh's header
    // changed without the page.
    test("the install command is README.md's and install.sh's, shown first in a copy box", () => {
      const home = read('index.html');
      const readmeCmd = /```sh\n([^\n]*)\n```/.exec(readmeInstall)?.[1];
      const headerCmd = installHeader.find((l) => /^#\s+curl\b/.test(l))?.replace(/^#\s+/, '');
      expect(readmeCmd).toBe(INSTALL_COMMAND);
      expect(headerCmd).toBe(INSTALL_COMMAND);
      expect(home).toContain('<p class="install-label"><strong>Install the mopm CLI</strong> with one command</p>');
      expect(home).toContain(`aria-label="install command"><code>${INSTALL_COMMAND}</code>`);
      // It is the first command block on the page.
      expect(home.indexOf('<pre')).toBe(home.indexOf('<pre tabindex="0" role="region" aria-label="install command">'));
    });

    // The command fetches https://mopm.dev/install.sh: the build must serve that file, byte for byte.
    // Defect caught: the installer not copied to dist/, or copied changed.
    test('the build serves /install.sh as the script in site/static', () => {
      expect(existsSync(join(f.outDir, 'install.sh'))).toBe(true);
      expect(read('install.sh')).toBe(installSh);
      expect(installSh.startsWith('#!/bin/sh\n')).toBe(true);
      expect(INSTALL_COMMAND).toContain('https://mopm.dev/install.sh');
    });

    // Defect caught: a target dropped from or added to the page; the order changed; install.sh gaining a target the page lacks.
    test("the release targets are install.sh's, in its order, and the page and README.md name exactly them", () => {
      const fromScript = [...installSh.matchAll(/\btarget=([a-z0-9]+-[a-z0-9_]+) ;;/g)].map((m) => m[1]);
      expect([...new Set(fromScript)]).toEqual(TARGETS);
      expect(textOf(byId(read('index.html'), 'release-files'))).toContain(` for ${TARGETS.slice(0, -1).join(', ')} and ${TARGETS.at(-1)}, `);
      const flatReadme = readme.replace(/\s*\n\s*/g, ' ');
      const list = `${TARGETS.slice(0, -1).map((t) => `\`${t}\``).join(', ')} and \`${TARGETS.at(-1)}\``;
      expect(flatReadme).toContain(`for ${list}, and a \`SHA256SUMS\` file`);
    });

    // Defect caught: the page naming the asset another way (mopm_<version>..., a .zip, no version); install.sh renaming the file.
    test('the asset names are install.sh\'s: mopm-<version>-<target>.tar.gz, SHA256SUMS and a .sigstore.json bundle per file', () => {
      const name = /\bname=(mopm-\$version-\$target)\n/.exec(installSh)?.[1];
      expect(name).toBeDefined();
      expect(/\basset=\$name\.tar\.gz\n/.test(installSh)).toBe(true);
      expect(`${name}.tar.gz`.replace('$version', '<version>').replace('$target', '<target>')).toBe(ASSET_PATTERN);
      expect(installSh).toContain('SHA256SUMS');
      expect(installHeader.join('\n')).toContain('F.sigstore.json');
      const files = textOf(byId(read('index.html'), 'release-files'));
      expect(files).toContain(` lists ${ASSET_PATTERN} for `);
      expect(files).toContain(', a SHA256SUMS file, and a .sigstore.json signature bundle for each of those files.');
      expect(oneLine(readme)).toContain(`\`${ASSET_PATTERN}\``);
    });

    // The page shows the series, never a patch number: a release is cut on every merge, so a patch number written
    // here would be wrong at the next one. Defect caught: 'Versions are 0.0.2'; VERSION bumped (0.1) with the page not.
    test("the version shown is VERSION's series, with no patch number anywhere on the page", () => {
      const series = readFileSync(join(REPO_ROOT, 'VERSION'), 'utf8').trim();
      expect(series).toMatch(/^\d+\.\d+$/);
      expect(RELEASE_SERIES).toBe(series);
      const home = read('index.html');
      expect(textOf(byId(home, 'release-files'))).toContain(` Versions are ${series}.x and are released automatically on every merge; the installer takes the latest.`);
      // Zig's own pinned version is the only other dotted triple on the page.
      expect(textOf(home).replace(/Zig 0\.12\.0/g, '')).not.toMatch(/\bv?\d+\.\d+\.\d+\b/);
    });

    // Defect caught: a changed identity, issuer or workflow (a command that verifies nothing, or fails every time); the
    // commands written differently from install.sh's header, which the release notes repeat.
    test("the verification commands are install.sh's header: the attestation and the cosign signature", () => {
      const start = installHeader.findIndex((l) => /^#\s+gh attestation verify F\b/.test(l));
      const end = installHeader.findIndex((l) => /^#\s+--certificate-oidc-issuer .* F$/.test(l));
      expect(start).toBeGreaterThan(0);
      expect(end).toBeGreaterThan(start);
      const fromScript = oneLine(installHeader.slice(start, end + 1).map((l) => l.replace(/^#\s+/, '')).join('\n'));
      expect(oneLine(VERIFY)).toBe(fromScript);
      const home = read('index.html');
      const shown = /<pre[^>]*aria-label="Verify a download commands"[^>]*><code>([^<]*)<\/code>/.exec(home)?.[1];
      expect(shown).toBeDefined();
      expect(oneLine(textOf(shown as string))).toBe(fromScript);
      expect(fromScript).toContain('--signer-workflow komira-ai/mopm/.github/workflows/release.yml');
      expect(fromScript).toContain('--certificate-oidc-issuer https://token.actions.githubusercontent.com');
      expect(textOf(byId(home, 'macos-unsigned'))).toBe('macOS binaries are not signed or notarized by Apple yet.');
    });

    // No Homebrew tap or apt repository exists: the page says planned, in a plain line, and shows no command for either.
    // Defect caught: `brew install mopm` or `apt install mopm` on the page; the planned tags dropped.
    test('Homebrew and apt are marked planned and never shown as a command', () => {
      const home = read('index.html');
      expect(textOf(byId(home, 'packaging-planned'))).toBe('Homebrew: planned · apt: planned');
      expect(home).toContain('<p class="installer-planned" id="packaging-planned">');
      expect(home.match(/class="tag tag-planned"/g)).toHaveLength(2);
      expect(home).not.toMatch(/brew\s+(?:install|tap)|apt(?:-get)?\s+install/);
      expect(home).not.toContain('class="seg');
    });

    // The audit's defect: the page said there were no release binaries and no installer. Defect caught: that copy back.
    test('the old no-installer copy is gone, and build from source is still shown after the install', () => {
      const home = read('index.html');
      expect(textOf(home)).not.toMatch(/no release binaries|no one-line installer|One-line installer: planned/);
      expect(home).not.toContain('id="installer-planned"');
      expect(textOf(byId(home, 'build'))).toMatch(/^To build from source instead you need Zig 0\.12\.0/);
      expect(home).toContain('aria-label="build from source commands"><code>git clone https://github.com/komira-ai/mopm\ncd mopm\nzig build');
      expect(home.indexOf('id="build"')).toBeGreaterThan(home.indexOf(INSTALL_COMMAND));
      expect(oneLine(readme)).toContain('You need [Zig](https://ziglang.org) 0.12.0');
    });
  });

  // The quickstart's third step is the registry: the command block is pixi's (spec/channel.md); the text names
  // `mopm add`, which main.zig implements, and never calls it planned.
  test('the three quickstart steps: install, start a package, add one with pixi or mopm add', () => {
    const home = read('index.html');
    const steps = home.slice(home.indexOf('<ol class="stepper">'), home.indexOf('</ol>', home.indexOf('<ol class="stepper">')));
    expect(steps.match(/<li>/g)).toHaveLength(3);
    expect([...steps.matchAll(/<h3>([^<]*)<\/h3>/g)].map((m) => m[1])).toEqual(['Install mopm', 'Start a package', 'Add a package']);
    const cmds = [...steps.matchAll(/<code>([^<]*)<\/code><\/pre>/g)].map((m) => textOf(m[1]));
    expect(cmds).toEqual(['mopm --version', 'mopm new my_package --lib', 'pixi add mojo-<name>']);
    expect(PLANNED).not.toContain('add');
    expect(WORKING_TODAY).toContain('add');
    expect(textOf(steps)).toContain('In a mopm project, mopm add <name> adds it to mopm.toml and writes mopm.lock.');
    expect(textOf(steps)).not.toContain('planned');
    // One artifact serves every stage: a static step must not name prod's channel (the channel shown below follows
    // the host at runtime).
    expect(textOf(steps)).toContain('In a pixi project that lists the registry’s conda channel.');
    expect(textOf(steps)).not.toContain('mopm.dev channel');
  });

  // Recently published is fetched at runtime (src/views/recent.ts); a list baked in at build time would go stale and
  // could show packages that do not exist. There is no featured list: the API has no source for one.
  // The slot is not a live region: filling it would read out up to 8 rows unprompted below the fold; aria-busy covers
  // the loading state.
  test('the recently updated slot holds no package, only the loading and no-script lines; no featured section', () => {
    const home = read('index.html');
    const slot = byId(home, 'recent-list');
    expect(textOf(slot)).toBe('Loading recently updated packages…The list of recent packages needs JavaScript. Browse all packages instead.');
    expect(slot).not.toContain('<li');
    expect(home).toContain('<div class="recent-slot" id="recent-list" aria-busy="true">');
    expect(textOf(home)).toContain('Recently updated');
    expect(textOf(home)).not.toContain('Recently published');
    expect(home).not.toMatch(/featured/i);
    expect(home).not.toContain('/packages/');
  });

  test('the home page search comes before the status note, and its browse link is name-sorted', () => {
    const home = read('index.html');
    expect(home.indexOf('class="hero-search"')).toBeGreaterThan(home.indexOf('id="opening"'));
    expect(home.indexOf('class="hero-search"')).toBeLessThan(home.indexOf('id="status"'));
    expect(home).toContain('<a href="/search">browse all packages</a>');
    expect(home).not.toContain('sort=updated');
  });

  test('the pixi command is the one spec/channel.md documents, and the channel is the prod default', () => {
    const channel = readFileSync(join(REPO_ROOT, 'spec', 'channel.md'), 'utf8').replace(/\s*\n\s*/g, ' ');
    expect(channel).toContain('`pixi add mojo-json` installs the package whose import name is `json`');
    const home = read('index.html');
    expect(home).toContain('<code>pixi add mojo-&lt;name&gt;</code>');
    expect(home).toContain('<code id="conda-channel">https://conda.mopm.dev/</code>');
  });
});
