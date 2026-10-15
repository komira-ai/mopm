// /packages/<name>/<version>: one version (getVersion).
//
// One version has one spelling (spec Version), so the API answers only for the address's own spelling; the version it
// returns is the page's address (canonicalPath; mount.ts writes it without a reload, a no-op when they agree). A yanked version says why; a tombstoned one says its
// files were removed, and never gets a download link, even if a url came with it. A file links only to the conda
// channel of the site the page is served on, and only for a published or yanked version. A dependency links only when
// its name is a valid package name.

import { type Doc, h } from '../doc.js';
import { formatBytes, stateLabel } from '../format.js';
import { condaBase } from '../host.js';
import { channelFileHref, internalHref } from '../links.js';
import { isCanonicalName, isVersion, packagePath, versionPath } from '../routes.js';
import { pinnedSnippet, refusalSentence } from '../snippet.js';
import type { FileRef, VersionDetail } from '../types.js';
import { details, timeEl, type View } from './common.js';
import { inlineList, installSection, type PageContext, PIXI_LABEL, readmeSection, webLink } from './package.js';

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
    null,
    h(doc, 'th', { scope: 'row' }, href ? h(doc, 'a', { href, class: 'file' }, f.filename) : h(doc, 'span', { class: 'file' }, f.filename)),
    h(doc, 'td', null, f.subdir),
    h(doc, 'td', { class: 'num' }, formatBytes(f.size)),
    h(doc, 'td', null, h(doc, 'code', { class: 'hash' }, f.sha256)),
  );
}

function filesTable<N>(doc: Doc<N>, v: VersionDetail, ctx: PageContext): N {
  const channel = condaBase(ctx.host);
  const allow = downloadable(v);
  return h(
    doc,
    'div',
    { class: 'scroll', role: 'region', tabindex: '0', 'aria-label': 'Files' },
    h(
      doc,
      'table',
      null,
      h(doc, 'caption', null, `Files of ${v.name} ${v.version}`),
      h(
        doc,
        'thead',
        null,
        h(doc, 'tr', null, ...['File', 'Platform', 'Size', 'SHA-256'].map((c) => h(doc, 'th', { scope: 'col' }, c))),
      ),
      h(doc, 'tbody', null, ...v.files.map((f) => fileRow(doc, f, channel, allow))),
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

export function versionView<N>(doc: Doc<N>, name: string, v: VersionDetail, ctx: PageContext): View<N> {
  // The address shows the version the registry returned, when it is in the grammar.
  const spelling = isVersion(v.version) ? v.version : null;
  const shown = spelling ?? v.version;
  const head = h(
    doc,
    'header',
    { class: 'page-head' },
    h(doc, 'p', { class: 'crumb' }, h(doc, 'a', { href: internalHref(packagePath(name)) }, name)),
    h(doc, 'div', { class: 'title-row' }, h(doc, 'h1', null, `${name} ${shown}`), h(doc, 'span', { class: `tag state-${v.state}` }, v.state === 'unknown' ? 'unknown' : v.state)),
    v.description ? h(doc, 'p', { class: 'lede' }, v.description) : null,
  );

  const main = h(doc, 'div', { class: 'content' });
  const banner = stateBanner(doc, v);
  if (banner) doc.append(main, banner);
  if (spelling !== null) {
    const pinned = pinnedSnippet(name, spelling, v.state);
    const why = pinned !== null || v.state !== 'published' ? null : refusalSentence(`Version ${spelling}`, spelling);
    // spec/channel.md documents no version-pinned pixi spelling, so the command installs the newest version.
    const pixiLabel =
      v.state === 'yanked'
        ? `${PIXI_LABEL} (installs the newest version, not this yanked one)`
        : `${PIXI_LABEL} (installs the newest version, not necessarily this one)`;
    if (v.state === 'published' || v.state === 'yanked') doc.append(main, installSection(doc, name, pinned, ctx, why, pixiLabel));
  }
  doc.append(main, h(doc, 'section', { 'aria-labelledby': 'files-heading' }, h(doc, 'h2', { id: 'files-heading' }, 'Files'), filesTable(doc, v, ctx)));
  doc.append(main, h(doc, 'section', { 'aria-labelledby': 'deps-heading' }, h(doc, 'h2', { id: 'deps-heading' }, 'Dependencies'), depsList(doc, v)));
  const native = nativeList(doc, v);
  if (native) doc.append(main, native);
  const readme = readmeSection(doc, v.readme);
  if (readme) doc.append(main, readme);

  const prov =
    v.provenance.kind === 'oidc'
      ? [h(doc, 'span', null, 'built in CI (OIDC)'), v.provenance.repository ? h(doc, 'br') : null, webLink(doc, v.provenance.repository), v.provenance.workflow_ref ? h(doc, 'br') : null, v.provenance.workflow_ref ? h(doc, 'code', { class: 'hash' }, v.provenance.workflow_ref) : null]
      : v.provenance.kind === 'none'
        ? 'none recorded'
        : 'unknown';
  const aside = h(doc, 'aside', { class: 'sidebar', 'aria-label': 'Version details' });
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
  if (meta) doc.append(aside, meta);

  return {
    title: `${name} ${shown}`,
    nodes: [head, h(doc, 'div', { class: 'layout' }, main, aside)],
    canonicalPath: spelling !== null ? versionPath(name, spelling) : undefined,
  };
}
