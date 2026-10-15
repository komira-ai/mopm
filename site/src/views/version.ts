// /packages/<name>/<version>: one version (getVersion).
//
// One version has one spelling (spec Version), so the API answers only for the address's own spelling; the version it
// returns is the page's address (canonicalPath; mount.ts writes it without a reload, a no-op when they agree). A yanked version says why; a tombstoned one says its
// files were removed, and never gets a download link, even if a url came with it. A file links only to the conda
// channel of the site the page is served on, and only for a published or yanked version. A dependency links only when
// its name is a valid package name.
//
// The head band is the package page's (pageHead). A published or yanked version leads with the package page's one
// install command, pixi, with a line saying it installs the newest version (spec/channel.md documents no
// version-pinned spelling); the pinned mopm.toml lines (published only) and the channel sit under "Other ways". Each
// file's SHA-256 is a .copy-box, so the page script gives it a Copy button.

import { type Doc, h } from '../doc.js';
import { formatBytes, stateLabel } from '../format.js';
import { condaBase } from '../host.js';
import { anchorHref, channelFileHref, internalHref } from '../links.js';
import { isCanonicalName, isVersion, packagePath, versionPath } from '../routes.js';
import { pinnedSnippet, refusalSentence } from '../snippet.js';
import type { FileRef, VersionDetail } from '../types.js';
import { details, timeEl, type View } from './common.js';
import { inlineList, installCard, type PageContext, pageHead, readmeSection, webLink } from './package.js';

function stateBanner<N>(doc: Doc<N>, v: VersionDetail): N | null {
  switch (v.state) {
    case 'published':
      return null;
    case 'yanked':
      return h(
        doc,
        'div',
        { class: 'notice notice-warn', role: 'note' },
        h(doc, 'p', null, h(doc, 'strong', null, 'Yanked.'), ' New resolution skips this version; its files stay available.'),
        v.yank_reason ? h(doc, 'p', null, 'Reason: ', v.yank_reason) : null,
      );
    case 'tombstoned':
      return h(
        doc,
        'div',
        { class: 'notice notice-error', role: 'note' },
        h(doc, 'p', null, h(doc, 'strong', null, 'Tombstoned.'), ' An administrator removed the files of this version. The version number stays taken.'),
        v.tombstone ? h(doc, 'p', null, 'Reason: ', h(doc, 'code', null, v.tombstone.reason_code), ', on ', v.tombstone.date, '.') : null,
      );
    default:
      return h(doc, 'div', { class: 'notice', role: 'note' }, h(doc, 'p', null, `State: ${stateLabel(v.state, v.state_raw)}. Treat this version as not installable.`));
  }
}

/** Whether a file of this version may get a download link at all. */
function downloadable(v: VersionDetail): boolean {
  return v.state === 'published' || v.state === 'yanked';
}

function fileRow<N>(doc: Doc<N>, f: FileRef, channel: string | null, allow: boolean): N {
  const href = allow && f.url !== undefined ? channelFileHref(f.url, channel) : null;
  return h(
    doc,
    'tr',
    { role: 'row' },
    h(doc, 'th', { scope: 'row', role: 'rowheader' }, href ? h(doc, 'a', { href, class: 'file' }, f.filename) : h(doc, 'span', { class: 'file' }, f.filename)),
    h(doc, 'td', { role: 'cell' }, h(doc, 'span', { class: 'platform' }, f.subdir)),
    h(doc, 'td', { class: 'num', role: 'cell' }, formatBytes(f.size)),
    // A .copy-box: the page script adds a Copy button for the digest (copy.ts), named "Copy SHA-256 of <file>".
    h(
      doc,
      'td',
      { class: 'sha', role: 'cell' },
      h(doc, 'div', { class: 'hash-box copy-box' }, h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': `SHA-256 of ${f.filename}` }, h(doc, 'code', { class: 'hash' }, f.sha256))),
    ),
  );
}

/**
 * The files table. Its rows carry explicit table roles because on a narrow screen package.css lays each row out as a
 * small grid (file, then platform and size, then the digest), and a browser may drop a table's semantics when its
 * display changes; the roles keep it a table to a screen reader.
 */
function filesTable<N>(doc: Doc<N>, v: VersionDetail, ctx: PageContext): N {
  if (v.files.length === 0) return h(doc, 'p', { class: 'muted' }, 'No files.');
  const channel = condaBase(ctx.host);
  const allow = downloadable(v);
  return h(
    doc,
    'div',
    { class: 'scroll files', role: 'region', tabindex: '0', 'aria-label': 'Files' },
    h(
      doc,
      'table',
      { role: 'table' },
      h(doc, 'caption', { class: 'visually-hidden' }, `Files of ${v.name} ${v.version}`),
      h(
        doc,
        'thead',
        { role: 'rowgroup' },
        h(doc, 'tr', { role: 'row' }, ...['File', 'Platform', 'Size', 'SHA-256'].map((c) => h(doc, 'th', { scope: 'col', role: 'columnheader' }, c))),
      ),
      h(doc, 'tbody', { role: 'rowgroup' }, ...v.files.map((f) => fileRow(doc, f, channel, allow))),
    ),
  );
}

function depsList<N>(doc: Doc<N>, v: VersionDetail): N {
  if (v.deps.length === 0) return h(doc, 'p', { class: 'muted' }, 'None.');
  return h(
    doc,
    'ul',
    { class: 'deps' },
    ...v.deps.map((d) =>
      h(
        doc,
        'li',
        null,
        isCanonicalName(d.name) ? h(doc, 'a', { href: internalHref(packagePath(d.name)) }, d.name) : h(doc, 'span', null, d.name),
        d.range ? h(doc, 'code', { class: 'range' }, d.range) : null,
      ),
    ),
  );
}

function nativeList<N>(doc: Doc<N>, v: VersionDetail): N | null {
  if (v.native.length === 0) return null;
  return h(
    doc,
    'section',
    { 'aria-labelledby': 'native-heading' },
    h(doc, 'h2', { id: 'native-heading' }, 'Native libraries'),
    h(doc, 'ul', { class: 'deps' }, ...v.native.map((n) => h(doc, 'li', null, h(doc, 'span', null, n.id), h(doc, 'code', null, n.soname)))),
  );
}

/** The platforms of a version's files, each once, in their order. */
function platforms(v: VersionDetail): string[] {
  return [...new Set(v.files.map((f) => f.subdir))];
}

/** spec/channel.md documents no version-pinned pixi spelling, so the one command installs the newest version. */
export const CAVEAT_PUBLISHED = 'This installs the newest version, not necessarily this one.';
export const CAVEAT_YANKED = 'This installs the newest version, not this yanked one.';

export function versionView<N>(doc: Doc<N>, name: string, v: VersionDetail, ctx: PageContext): View<N> {
  // The address shows the version the registry returned, when it is in the grammar.
  const spelling = isVersion(v.version) ? v.version : null;
  const shown = spelling ?? v.version;
  const readme = readmeSection(doc, v.readme);

  const facts: N[] = [h(doc, 'li', null, 'Published ', h(doc, 'strong', null, timeEl(doc, v.published_at)))];
  if (v.license) facts.push(h(doc, 'li', null, 'License ', h(doc, 'strong', null, v.license)));
  if (v.requires_mojo) facts.push(h(doc, 'li', null, 'Mojo ', h(doc, 'strong', null, v.requires_mojo)));
  const plats = platforms(v);
  if (plats.length > 0) facts.push(h(doc, 'li', null, plats.length === 1 ? 'Platform ' : 'Platforms ', h(doc, 'strong', null, plats.join(' · '))));
  const tabs: N[] = [h(doc, 'a', { href: anchorHref('files-heading') }, 'Files ', h(doc, 'span', { class: 'count' }, String(v.files.length))), h(doc, 'a', { href: anchorHref('deps-heading') }, 'Dependencies ', h(doc, 'span', { class: 'count' }, String(v.deps.length)))];
  if (readme) tabs.push(h(doc, 'a', { href: anchorHref('section-readme') }, 'Readme'));
  const head = pageHead(doc, {
    name,
    version: shown,
    badges: [h(doc, 'span', { class: `tag state-${v.state}` }, v.state === 'unknown' ? 'unknown' : v.state)],
    description: v.description,
    facts,
    tabs,
  });

  const main = h(doc, 'div', { class: 'content' });
  const banner = stateBanner(doc, v);
  if (banner) doc.append(main, banner);
  if (spelling !== null && (v.state === 'published' || v.state === 'yanked')) {
    const pinned = pinnedSnippet(name, spelling, v.state);
    const why = pinned !== null || v.state !== 'published' ? null : refusalSentence(`Version ${spelling}`, spelling);
    doc.append(main, installCard(doc, name, pinned, ctx, why, v.state === 'yanked' ? CAVEAT_YANKED : CAVEAT_PUBLISHED));
  }
  doc.append(main, h(doc, 'section', { 'aria-labelledby': 'files-heading' }, h(doc, 'h2', { id: 'files-heading' }, 'Files'), filesTable(doc, v, ctx)));
  doc.append(main, h(doc, 'section', { 'aria-labelledby': 'deps-heading' }, h(doc, 'h2', { id: 'deps-heading' }, 'Dependencies'), depsList(doc, v)));
  const native = nativeList(doc, v);
  if (native) doc.append(main, native);
  if (readme) doc.append(main, readme);

  const prov =
    v.provenance.kind === 'oidc'
      ? [h(doc, 'span', null, 'built in CI (OIDC)'), v.provenance.repository ? h(doc, 'br') : null, webLink(doc, v.provenance.repository), v.provenance.workflow_ref ? h(doc, 'br') : null, v.provenance.workflow_ref ? h(doc, 'code', { class: 'hash' }, v.provenance.workflow_ref) : null]
      : v.provenance.kind === 'none'
        ? 'none recorded'
        : 'unknown';
  const aside = h(doc, 'aside', { class: 'side-panel', 'aria-label': 'Version details' });
  const meta = details(doc, [
    ['State', stateLabel(v.state, v.state_raw, v.yank_reason)],
    ['Published', [timeEl(doc, v.published_at), v.published_by ? ` by ${v.published_by}` : null]],
    ['Requires Mojo', h(doc, 'code', null, v.requires_mojo)],
    ['License', v.license],
    ['Repository', webLink(doc, v.repository)],
    ['Homepage', webLink(doc, v.homepage)],
    ['Keywords', inlineList(doc, v.keywords, 'keywords')],
    ['Provenance', prov],
    ['Manifest SHA-256', h(doc, 'code', { class: 'hash' }, v.manifest_sha256)],
  ]);
  if (meta) doc.append(aside, h(doc, 'section', { 'aria-labelledby': 'side-about' }, h(doc, 'h2', { id: 'side-about' }, 'About this version'), meta));
  if (isCanonicalName(name)) {
    doc.append(
      aside,
      h(
        doc,
        'section',
        { 'aria-labelledby': 'side-versions' },
        h(doc, 'h2', { id: 'side-versions' }, 'Other versions'),
        h(doc, 'p', { class: 'small' }, h(doc, 'a', { href: internalHref(`${packagePath(name)}#versions-heading`) }, `All versions of ${name}`)),
      ),
    );
  }

  return {
    title: `${name} ${shown}`,
    nodes: [head, h(doc, 'div', { class: 'layout' }, main, aside)],
    canonicalPath: spelling !== null ? versionPath(name, spelling) : undefined,
  };
}
