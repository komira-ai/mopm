// The docs pages: each repo doc in DOC_PAGES (src/links.ts) rendered at build time by the same restricted Markdown
// renderer the browser uses for readmes, through StringDoc; and /docs/, the list of them.
//
// A doc's page title is its first '# ' heading. Heading ids carry a 'doc-' prefix so a heading can never take an id
// the page itself uses ('main', 'q'). Relative links resolve as links.ts says: a published doc stays on the site,
// anything else goes to the file on GitHub.

import { readFileSync } from 'fs';
import { join } from 'path';
import { h, type SElement, type SNode } from '../src/doc';
import { DOC_PAGES, internalHref, REPO_URL, webHref } from '../src/links';
import { renderMarkdown } from '../src/markdown/render';
import { doc, type PageSpec } from './layout';

export const DOC_ID_PREFIX = 'doc-';

export interface DocPage {
  slug: string;
  source: string;
  title: string;
  spec: PageSpec;
  /** Markdown the renderer showed as literal text (test/docs-render.test.ts keeps this at zero). */
  fallbacks: number;
}

/** The text of the first '# ' heading, without inline markup characters; the slug when there is none. */
export function docTitle(src: string, fallback: string): string {
  const m = /^# +(.+?)\s*#*\s*$/m.exec(src);
  return m ? m[1].replace(/`|\*\*/g, '').trim() : fallback;
}

/** The first sentence after the title, as plain text, for the page description and the docs index. */
export function docSummary(src: string): string {
  const lines = src.split('\n');
  let i = lines.findIndex((l) => /^# /.test(l));
  i = i < 0 ? 0 : i + 1;
  while (i < lines.length && lines[i].trim() === '') i++;
  const para: string[] = [];
  for (; i < lines.length && lines[i].trim() !== '' && !/^(?:#|```|\||[-*] |\d+\. )/.test(lines[i]); i++) para.push(lines[i].trim());
  const plain = para.join(' ').replace(/`|\*\*/g, '').replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
  // A sentence ends at '.', '!' or '?' before a space ('mopm.toml' does not end one).
  const end = /[.!?](?=\s|$)/.exec(plain);
  return end ? plain.slice(0, end.index + 1) : plain;
}

export function buildDocPage(repoRoot: string, d: { slug: string; source: string }): DocPage {
  const src = readFileSync(join(repoRoot, d.source), 'utf8');
  const title = docTitle(src, d.slug);
  const article = h(doc, 'article', { class: 'prose doc' }) as SElement;
  const fallbacks = renderMarkdown(doc, article, src, {
    idPrefix: DOC_ID_PREFIX,
    headingShift: 0,
    links: { mode: 'docs', source: d.source },
  });
  const sourceLink = h(
    doc,
    'p',
    { class: 'doc-source muted small' },
    'Source: ',
    h(doc, 'a', { href: webHref(`${REPO_URL}/blob/main/${d.source}`) ?? undefined }, h(doc, 'code', null, d.source), ' on GitHub'),
  );
  const crumb = h(doc, 'nav', { class: 'crumb', 'aria-label': 'Breadcrumb' }, h(doc, 'a', { href: internalHref('/docs/') }, 'Docs'));
  const main: SNode[] = [crumb, article, sourceLink];
  return {
    slug: d.slug,
    source: d.source,
    title,
    fallbacks,
    spec: { title, description: docSummary(src) || title, kind: 'docs', current: 'docs', main },
  };
}

export function buildDocPages(repoRoot: string): DocPage[] {
  return DOC_PAGES.map((d) => buildDocPage(repoRoot, d));
}

export function docsIndexPage(pages: readonly DocPage[], repoRoot: string): PageSpec {
  const items = pages.map((p) => {
    const summary = docSummary(readFileSync(join(repoRoot, p.source), 'utf8'));
    return h(
      doc,
      'li',
      { class: 'doc-card' },
      h(doc, 'h2', null, h(doc, 'a', { href: internalHref(`/docs/${p.slug}/`) }, p.title)),
      summary ? h(doc, 'p', null, summary) : null,
      h(doc, 'p', { class: 'muted small' }, h(doc, 'code', null, p.source)),
    );
  });
  return {
    title: 'Docs',
    description: 'mopm documentation: the mopm.toml manifest and the mopm test runner.',
    kind: 'docs',
    current: 'docs',
    currentIsTarget: true,
    main: [
      h(doc, 'h1', null, 'Docs'),
      h(doc, 'p', { class: 'lede' }, 'Reference pages from the mopm repository, rendered from its Markdown.'),
      h(doc, 'ul', { class: 'doc-list' }, ...items),
    ],
  };
}
