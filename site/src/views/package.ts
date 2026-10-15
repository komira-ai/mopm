// /packages/<name>: one package (getPackage).
//
// The shapes: a claimed name with nothing published; a package state this page does not know, or an active package
// with no published version (every one yanked or tombstoned), with no install lines; an active package whose
// latest the page cannot show (null, or a string outside the version grammar: no mopm.toml line, and the page says
// why); and the normal page. Every value from the API is shown as text; the repository
// and homepage are links only when links.ts accepts them as http(s); versions link only when they match the grammar.
// The readme is untrusted Markdown, rendered by the restricted renderer with 'readme-' ids (the page's own ids never
// start with 'readme-', so no readme heading can take one), its headings two levels down: a readme '# Title' is an h3
// under the section's 'Readme' h2.

import { type Doc, h } from '../doc.js';
import { formatDate, stateLabel } from '../format.js';
import { condaBase } from '../host.js';
import { internalHref, webHref } from '../links.js';
import { renderMarkdown } from '../markdown/render.js';
import { isVersion, versionPath } from '../routes.js';
import { manifestSnippet, pixiCommand, refusalSentence } from '../snippet.js';
import type { PackageInfo, VersionSummary } from '../types.js';
import { details, snippetBlock, timeEl, type View } from './common.js';

/** The API drops a readme over this many UTF-8 bytes; the page refuses one too, in case another server does not. */
export const README_MAX_BYTES = 65_536;

export interface PageContext {
  /** location.hostname: picks the conda channel shown and accepted for downloads. */
  host: string;
}

/** A URL from the API as a link, or as text when links.ts refuses it. */
export function webLink<N>(doc: Doc<N>, raw: string | null | undefined): N | null {
  if (!raw) return null;
  const href = webHref(raw);
  return href ? h(doc, 'a', { href, rel: 'nofollow noopener noreferrer ugc' }, raw) : h(doc, 'span', null, raw);
}

/** The readme section, or a note when it is too large; null when there is none. */
export function readmeSection<N>(doc: Doc<N>, readme: string | undefined): N | null {
  if (readme === undefined || readme.trim() === '') return null;
  const section = h(doc, 'section', { class: 'readme', 'aria-labelledby': 'section-readme' }, h(doc, 'h2', { id: 'section-readme' }, 'Readme'));
  if (new TextEncoder().encode(readme).length > README_MAX_BYTES) {
    doc.append(section, h(doc, 'p', { class: 'muted' }, 'The readme is larger than 64 KiB and is not shown.'));
    return section;
  }
  const body = h(doc, 'div', { class: 'prose' });
  renderMarkdown(doc, body, readme, { idPrefix: 'readme-', headingShift: 2, links: { mode: 'readme' } });
  doc.append(section, body);
  return section;
}

/** Keywords and owners: short lists of plain text. */
export function inlineList<N>(doc: Doc<N>, items: readonly string[] | undefined, cls: string): N | null {
  if (!items || items.length === 0) return null;
  return h(doc, 'ul', { class: `inline-list ${cls}` }, ...items.map((t) => h(doc, 'li', null, t)));
}

function versionCell<N>(doc: Doc<N>, name: string, v: VersionSummary): N {
  return isVersion(v.version) ? h(doc, 'a', { href: internalHref(versionPath(name, v.version)) }, v.version) : h(doc, 'span', null, v.version);
}

function versionsTable<N>(doc: Doc<N>, name: string, versions: readonly VersionSummary[]): N {
  if (versions.length === 0) return h(doc, 'p', { class: 'muted' }, 'No versions are published.');
  const rows = versions.map((v) =>
    h(
      doc,
      'tr',
      { class: `state-${v.state}` },
      h(doc, 'th', { scope: 'row' }, versionCell(doc, name, v)),
      h(doc, 'td', null, stateLabel(v.state, v.state_raw, v.yank_reason)),
      h(doc, 'td', null, timeEl(doc, v.published_at)),
    ),
  );
  return h(
    doc,
    'div',
    { class: 'scroll', role: 'region', tabindex: '0', 'aria-label': 'Versions' },
    h(
      doc,
      'table',
      null,
      h(doc, 'caption', null, `Versions of ${name}, newest first`),
      h(doc, 'thead', null, h(doc, 'tr', null, h(doc, 'th', { scope: 'col' }, 'Version'), h(doc, 'th', { scope: 'col' }, 'State'), h(doc, 'th', { scope: 'col' }, 'Published'))),
      h(doc, 'tbody', null, ...rows),
    ),
  );
}

export const PIXI_LABEL = 'pixi, in a project that lists the channel';

/**
 * How to use a package: the conda channel and pixi command always (for a known host), and the mopm.toml line when
 * there is a version mopm can name. `manifest` is the snippet or null. The pixi command names no version, so a version
 * page passes a label saying which version it installs.
 */
export function installSection<N>(
  doc: Doc<N>,
  name: string,
  manifest: string | null,
  ctx: PageContext,
  noManifestWhy: string | null,
  pixiLabel: string = PIXI_LABEL,
): N {
  const channel = condaBase(ctx.host);
  const pixi = pixiCommand(name);
  const section = h(doc, 'section', { class: 'install', 'aria-labelledby': 'install-heading' }, h(doc, 'h2', { id: 'install-heading' }, 'Install'));
  if (manifest !== null) {
    doc.append(section, snippetBlock(doc, 'mopm.toml', manifest, 'snippet-manifest'));
    doc.append(
      section,
      h(doc, 'p', { class: 'muted small' }, h(doc, 'code', null, 'mopm metadata'), ' checks this table today; ', h(doc, 'code', null, 'mopm add'), ' is planned.'),
    );
  } else if (noManifestWhy !== null) {
    doc.append(section, h(doc, 'p', { class: 'muted' }, noManifestWhy));
  }
  if (channel !== null) {
    doc.append(section, snippetBlock(doc, 'conda channel', channel, 'snippet-channel'));
    if (pixi !== null) {
      doc.append(section, snippetBlock(doc, pixiLabel, pixi, 'snippet-pixi'));
    }
  }
  return section;
}

export function packageView<N>(doc: Doc<N>, name: string, info: PackageInfo, ctx: PageContext): View<N> {
  const nodes: N[] = [];
  const latest = info.latest !== null && isVersion(info.latest) ? info.latest : null;
  nodes.push(
    h(
      doc,
      'header',
      { class: 'page-head' },
      h(
        doc,
        'div',
        { class: 'title-row' },
        h(doc, 'h1', null, name),
        latest !== null ? h(doc, 'span', { class: 'tag tag-version' }, h(doc, 'span', { class: 'visually-hidden' }, 'latest version '), latest) : null,
      ),
      info.description ? h(doc, 'p', { class: 'lede' }, info.description) : null,
    ),
  );

  const main = h(doc, 'div', { class: 'content' });
  if (info.state === 'claimed') {
    doc.append(main, h(doc, 'p', { class: 'notice' }, 'This name is claimed. Nothing has been published under it yet.'));
  } else {
    if (info.state === 'unknown') {
      // As the version page treats a version state it does not know: nothing to install.
      doc.append(main, h(doc, 'p', { class: 'notice' }, 'The registry reports a package state this page does not know. Treat this package as not installable.'));
    } else if (!info.versions.some((v) => v.state === 'published')) {
      // spec/channel.md: a yanked version leaves packages.conda and a tombstoned one loses its files, so neither the
      // channel nor `pixi add` has anything to install.
      const why = info.versions.length === 0 ? 'Nothing can be installed: no version is published.' : 'Nothing can be installed: every version is yanked or its files were removed.';
      doc.append(main, h(doc, 'p', { class: 'notice' }, why));
    } else {
      const manifest = manifestSnippet(name, latest);
      const why =
        manifest !== null
          ? null
          : latest === null
            ? 'The registry names no latest version this page can show, so there is no mopm.toml line.'
            : refusalSentence(`The latest version, ${latest},`, latest);
      doc.append(main, installSection(doc, name, manifest, ctx, why));
    }
    doc.append(main, h(doc, 'section', { 'aria-labelledby': 'versions-heading' }, h(doc, 'h2', { id: 'versions-heading' }, 'Versions'), versionsTable(doc, name, info.versions)));
  }
  const readme = readmeSection(doc, info.readme);
  if (readme) doc.append(main, readme);

  const aside = h(doc, 'aside', { class: 'sidebar', 'aria-label': 'Package details' });
  const meta = details(doc, [
    ['Repository', webLink(doc, info.repository)],
    ['Homepage', webLink(doc, info.homepage)],
    ['License', info.license],
    ['Owners', inlineList(doc, info.owners.map((o) => o.handle), 'owners')],
    ['Keywords', inlineList(doc, info.keywords, 'keywords')],
    ['Created', h(doc, 'time', { datetime: info.created_at }, formatDate(info.created_at))],
  ]);
  if (meta) doc.append(aside, meta);

  nodes.push(h(doc, 'div', { class: 'layout' }, main, aside));
  return { title: name, nodes };
}
