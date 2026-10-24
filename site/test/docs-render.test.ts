// T11: the repo docs the site publishes render completely: no construct falls back to literal text, GFM tables come
// out as tables with a header, markup in code is escaped, and heading ids are unique.
import { readFileSync } from 'fs';
import { join } from 'path';
import { serialize } from '../src/doc';
import { DOC_PAGES } from '../src/links';
import { tocNav } from '../tools/docs';
import { expectSafe, mdFull, tagsOf } from './md';

const REPO = join(__dirname, '..', '..');

function render(source: string) {
  const src = readFileSync(join(REPO, source), 'utf8');
  return mdFull(src, { idPrefix: '', headingShift: 0, links: { mode: 'docs', source } });
}

test('the published docs are the seven the plan names: why and design, getting started, configuration, examples, mopm.toml, mopm test, publishing a workspace', () => {
  expect(DOC_PAGES.map((d) => d.source)).toEqual(['docs/why-and-design.md', 'docs/getting-started.md', 'docs/configuration.md', 'docs/examples.md', 'spec/mopm-toml.md', 'docs/mopm-test.md', 'docs/publishing-a-workspace.md']);
  expect(DOC_PAGES.map((d) => d.slug)).toEqual(['why', 'getting-started', 'configuration', 'examples', 'mopm-toml', 'mopm-test', 'publish-workspace']);
});

test.each(DOC_PAGES.map((d) => [d.source] as const))('%s renders with no literal fallback and unique ids', (source) => {
  const r = render(source);
  expect(r.fallbacks).toBe(0);
  expectSafe(r.html);
  const tags = tagsOf(r.html);
  expect(tags.filter((t) => t.tag === 'h1')).toHaveLength(1);
  const ids = tags.flatMap((t) => t.attrs.filter(([k]) => k === 'id').map(([, v]) => v));
  expect(ids.length).toBeGreaterThan(2);
  expect(new Set(ids).size).toBe(ids.length);
});

test('mopm-test.md: every GFM table is a table with a header row; JUnit markup in code is escaped', () => {
  const { html } = render('docs/mopm-test.md');
  // As many tables as the source has delimiter rows (so an edit to the doc does not need an edit here).
  const source = readFileSync(join(REPO, 'docs/mopm-test.md'), 'utf8');
  const delimiterRows = source.split('\n').filter((l) => /^\|(?: *:?-+:? *\|)+$/.test(l)).length;
  expect(delimiterRows).toBeGreaterThanOrEqual(3);
  expect(html.split('<table>').length - 1).toBe(delimiterRows);
  // Each in its own named scroll region, so a wide table scrolls by itself at 320px.
  expect(html.split('<div class="scroll" role="region" tabindex="0" aria-label="Table: ').length - 1).toBe(delimiterRows);
  expect(html.split('"><table><thead><tr><th scope="col">').length - 1).toBe(delimiterRows);
  expect(html).toContain('<code>&lt;testcase classname="&lt;file&gt;" name="&lt;test&gt;" time="&lt;s&gt;"&gt;</code>');
  expect(html).toContain('<h2 id="retries-and-flaky">Retries and FLAKY</h2>');
  expect(html).toContain('<pre tabindex="0"><code class="language-json">{');
  expect(html).toContain('<ol><li><strong>Discovery.</strong>');
});

test('mopm-toml.md: the toml example, the sections list, and escaped placeholders', () => {
  const { html } = render('spec/mopm-toml.md');
  expect(html).toContain('<h1 id="mopmtoml-draft">mopm.toml (draft)</h1>');
  expect(html).toContain('<pre tabindex="0"><code class="language-toml">[package]');
  expect(html).toContain('<li><code>[native.&lt;id&gt;]</code>');
  expect(html).toContain('<code>&gt;=1.2.0, &lt;2.0.0</code>');
});

// tocNav renders each heading's text as its link, at its level, to its id; an id outside the anchor grammar is left
// out. Mutants: the link text taken from the id; the level class dropped; an unsafe id linked.
test('tocNav: one link per heading, reading as the heading, to its anchor', () => {
  const nav = tocNav([
    { level: 2, id: 'doc-a', text: 'A <b> & c' },
    { level: 3, id: 'doc-a-1', text: 'One' },
    { level: 2, id: '1bad', text: 'Skipped' },
  ]);
  expect(nav).not.toBeNull();
  expect(serialize(nav!)).toBe(
    '<nav class="toc" aria-label="On this page"><p class="side-title">On this page</p><ul>'
      + '<li class="toc-2"><a href="#doc-a">A &lt;b&gt; &amp; c</a></li><li class="toc-3"><a href="#doc-a-1">One</a></li></ul></nav>',
  );
  expect(tocNav([])).toBeNull();
});
