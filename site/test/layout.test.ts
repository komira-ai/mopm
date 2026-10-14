// T15: every built page is a complete, accessible document with nothing inline: lang, a title, exactly one h1, a skip
// link to <main id="main">, the header, nav, main and footer landmarks, and no inline script, style or event handler.
// And the home page says only what the repository says: README.md's opening sentence word for word, its list of the
// commands that work today, src/cli/main.zig's planned commands, and a quickstart of working commands only.
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { TAGS } from '../src/doc';
import { tagsIn } from '../tools/check-dist';
import { OPENING_SENTENCE, PLANNED, WORKING_TODAY } from '../tools/pages';
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

test('the six pages are built', () => {
  expect(pages.sort()).toEqual(['404.html', 'app.html', 'docs/index.html', 'docs/mopm-test/index.html', 'docs/mopm-toml/index.html', 'index.html']);
});

describe.each(['404.html', 'app.html', 'docs/index.html', 'docs/mopm-test/index.html', 'docs/mopm-toml/index.html', 'index.html'])('%s', (page) => {
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
    expect(html).toContain('<main id="main" class="wrap" tabindex="-1">');
    expect(count('main')).toBe(1);
  });

  test('header, nav (with a label), main and footer landmarks', () => {
    expect(count('header')).toBeGreaterThanOrEqual(1);
    expect(count('footer')).toBe(1);
    expect(html).toContain('<nav class="site-nav" aria-label="Site">');
  });

  test('one search field with id q (the "/" key focuses it), in a named search form that submits to /search', () => {
    expect(tags.filter(([, a]) => a.some(([k, v]) => k === 'id' && v === 'q'))).toHaveLength(1);
    if (page === 'index.html') {
      // The home page's own search is its first control; the header has none.
      expect(html).not.toContain('class="site-search"');
      expect(html).toContain('<form class="hero-search" role="search" action="/search" method="get" aria-label="Search the registry"><label for="q">');
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
    expect(tags.filter(([t, a]) => t === 'link' && a.some(([k, v]) => k === 'rel' && v === 'stylesheet'))).toHaveLength(1);
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
    ['docs/mopm-toml/index.html', 'spec/mopm-toml.md'],
    ['docs/mopm-test/index.html', 'docs/mopm-test.md'],
  ])('%s: the title is the first heading of %s, and the Source link is that file on GitHub', (page, source) => {
    const html = read(page);
    expect(html).toContain(`<title>${firstHeading(source)} · mopm</title>`);
    expect(html).toContain(`<a href="https://github.com/komira-ai/mopm/blob/main/${source}"><code>${source}</code> on GitHub</a>`);
  });

  test('the Docs nav entry is the current page on /docs/ and its parent on a doc page', () => {
    expect(read('docs/index.html')).toContain('<a href="/docs/" aria-current="page">Docs</a>');
    expect(read('docs/mopm-test/index.html')).toContain('<a href="/docs/" aria-current="true">Docs</a>');
    expect(read('docs/mopm-test/index.html')).toContain('<nav class="crumb" aria-label="Breadcrumb"><a href="/docs/">Docs</a></nav>');
    expect(read('index.html')).not.toContain('aria-current');
  });

  test('a doc summary on /docs/ is its first sentence', () => {
    const index = textOf(read('docs/index.html'));
    expect(index).toContain('mopm test finds the tests of a Mojo package, builds each test file once, and runs every test in a process of its own under a supervisor.');
    expect(index).not.toContain('test_cmd.zig');
    expect(index).toContain('mopm.toml sits at the root of a package.');
  });
});

test('404.html and app.html: the 404 is not indexed; the app shell tells a reader without scripts what to do', () => {
  expect(read('404.html')).toContain('<meta name="robots" content="noindex">');
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
    const code = [...read('index.html').matchAll(/<code>([^<]*)<\/code>/g)].map((m) => textOf(m[1])).join('\n');
    const used = [...code.matchAll(/(?:^|\n|`)mopm ([a-z-]+)/g)].map((m) => m[1]);
    expect(used.length).toBeGreaterThan(5);
    for (const cmd of used) {
      if (!WORKING_TODAY.includes(cmd)) expect(PLANNED).toContain(cmd); // named only as planned, and main.zig still plans it
    }
    // In the command blocks (the build and the quickstart), every mopm line is a working command.
    const blocks = [...read('index.html').matchAll(/<pre[^>]*><code>([^<]*)<\/code><\/pre>/g)].map((m) => textOf(m[1]));
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
