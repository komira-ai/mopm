// /packages/<namespace>/<name>: one package (getPackage).
//
// The page reads top to bottom: the full name, latest version, description and a line of facts; then the install
// card, mopm first, as cargo's pages lead with cargo: 'mopm add <namespace>/<name>' and the mopm.toml line with its
// quoted full-name key, a Copy button each, and a link to install mopm itself; then the readme and the versions
// section: one row per release line (src/versions.ts), its newest version with its state and date, the number of
// versions in total and a link to the full list on its own page (views/versions.ts). A side panel holds the links,
// license, keywords, the namespace (the package's owner) with its GitHub account, and the same release lines, newest
// first, with their state. The GitHub link is what tells a look-alike namespace from the real one
// (docs/design/namespaces.md, section 1), so the panel shows the account's login as GitHub has it now.
//
// The shapes: a claimed name with nothing published; a package state this page does not know, or an active package
// with no published version (every one yanked or tombstoned), with no install lines; an active package whose latest
// the page cannot show (null, or a string outside the version grammar: 'mopm add' still picks the newest version that
// fits, but there is no mopm.toml line, and the page says why); and the normal page. Every value from the API is shown
// as text; the repository and homepage are links only when links.ts accepts them as http(s); versions link only when
// they match the grammar.
// The readme is untrusted Markdown, rendered by the restricted renderer with 'readme-' ids (the page's own ids never
// start with 'readme-', so no readme heading can take one), its headings two levels down: a readme '# Title' is an h3
// under the section's 'Readme' h2.

import { type Doc, h, type SafeHref } from '../doc.js';
import { formatDate, stateLabel } from '../format.js';
import { registryFlag } from '../host.js';
import { anchorHref, internalHref, webHref } from '../links.js';
import { renderMarkdown } from '../markdown/render.js';
import { type FullName, fullName, isNamespace, isVersion, namespaceSearchPath, packagePath, searchPath, versionPath, versionsPath } from '../routes.js';
import { addCommand, manifestSnippet, refusalSentence } from '../snippet.js';
import type { NamespaceInfo, PackageInfo, VersionSummary } from '../types.js';
import { type ReleaseLine, releaseLines } from '../versions.js';
import { details, snippetBlock, timeEl, type View } from './common.js';
import { glyphClass, initials } from './recent.js';

/** The API drops a readme over this many UTF-8 bytes; the page refuses one too, in case another server does not. */
export const README_MAX_BYTES = 65_536;

export interface PageContext {
  /** location.hostname: picks the `--registry` the commands name, and (version page) the channel of download links. */
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

/** Keywords: a short list of plain text. */
export function inlineList<N>(doc: Doc<N>, items: readonly string[] | undefined, cls: string): N | null {
  if (!items || items.length === 0) return null;
  return h(doc, 'ul', { class: `inline-list ${cls}` }, ...items.map((t) => h(doc, 'li', null, t)));
}

function versionCell<N>(doc: Doc<N>, f: FullName, v: VersionSummary): N {
  return isVersion(v.version) ? h(doc, 'a', { href: internalHref(versionPath(f, v.version)) }, v.version) : h(doc, 'span', null, v.version);
}

/** Every version in the order the API gives (newest first), with its state and publish time: the full list's page. */
export function versionsTable<N>(doc: Doc<N>, f: FullName, versions: readonly VersionSummary[]): N {
  if (versions.length === 0) return h(doc, 'p', { class: 'muted' }, 'No versions are published.');
  const rows = versions.map((v) =>
    h(
      doc,
      'tr',
      { class: `state-${v.state}` },
      h(doc, 'th', { scope: 'row' }, versionCell(doc, f, v)),
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
      h(doc, 'caption', null, `Versions of ${fullName(f)}, newest first`),
      h(doc, 'thead', null, h(doc, 'tr', null, h(doc, 'th', { scope: 'col' }, 'Version'), h(doc, 'th', { scope: 'col' }, 'State'), h(doc, 'th', { scope: 'col' }, 'Published'))),
      h(doc, 'tbody', null, ...rows),
    ),
  );
}

/** The words for a row's release line: '2.x', '0.4.x', or 'other' for a version outside the grammar. */
function lineLabel(l: ReleaseLine): string {
  return l.line ?? 'other';
}

/** The link to the full version list, by its count. */
export function allVersionsLink<N>(doc: Doc<N>, f: FullName, total: number): N {
  return h(doc, 'a', { href: internalHref(versionsPath(f)) }, total === 1 ? 'The version list' : `All ${total} versions`);
}

/** One row per release line: the line, the version that shows it, its state and publish time, and the line's size. */
function linesTable<N>(doc: Doc<N>, f: FullName, lines: readonly ReleaseLine[]): N {
  const rows = lines.map((l) =>
    h(
      doc,
      'tr',
      { class: `state-${l.shown.state}` },
      h(doc, 'th', { scope: 'row' }, lineLabel(l)),
      h(doc, 'td', null, versionCell(doc, f, l.shown)),
      h(doc, 'td', null, stateLabel(l.shown.state, l.shown.state_raw, l.shown.yank_reason)),
      h(doc, 'td', null, timeEl(doc, l.shown.published_at)),
      h(doc, 'td', null, String(l.count)),
    ),
  );
  return h(
    doc,
    'div',
    { class: 'scroll', role: 'region', tabindex: '0', 'aria-label': 'Release lines' },
    h(
      doc,
      'table',
      null,
      h(doc, 'caption', null, `Release lines of ${fullName(f)}, newest first`),
      h(
        doc,
        'thead',
        null,
        h(
          doc,
          'tr',
          null,
          h(doc, 'th', { scope: 'col' }, 'Line'),
          h(doc, 'th', { scope: 'col' }, 'Newest'),
          h(doc, 'th', { scope: 'col' }, 'State'),
          h(doc, 'th', { scope: 'col' }, 'Published'),
          h(doc, 'th', { scope: 'col' }, 'Versions'),
        ),
      ),
      h(doc, 'tbody', null, ...rows),
    ),
  );
}

/** The package page's versions section: the release lines, the number of versions and the link to all of them. */
function versionsSection<N>(doc: Doc<N>, f: FullName, versions: readonly VersionSummary[]): N {
  const section = h(doc, 'section', { class: 'versions', 'aria-labelledby': 'versions-heading' }, h(doc, 'h2', { id: 'versions-heading' }, 'Versions'));
  if (versions.length === 0) {
    doc.append(section, h(doc, 'p', { class: 'muted' }, 'No versions are published.'));
    return section;
  }
  const lines = releaseLines(versions);
  const count = `${versions.length} ${versions.length === 1 ? 'version' : 'versions'} in ${lines.length} ${lines.length === 1 ? 'release line' : 'release lines'}; each line shows its newest published version.`;
  doc.append(section, h(doc, 'p', { class: 'muted small' }, count));
  doc.append(section, linesTable(doc, f, lines));
  doc.append(section, h(doc, 'p', { class: 'small' }, allVersionsLink(doc, f, versions.length)));
  return section;
}

/** What the mopm command does: the first line of the install card, beside its heading. */
export const INSTALL_NOTE = 'in a project with a mopm.toml: writes the dependency into it and locks it, as cargo add does';
/** Where the mopm command line itself is installed from: the home page's install block (tools/pages.ts, id 'install'). */
export const MOPM_INSTALL_PATH = '/#install';
/** How many release lines the side panel lists, newest first; the versions section has them all. */
export const SIDE_LINES = 5;

/** One command row: a prompt, the command in a <pre> and (from the page script) a Copy button named by `label`. */
function commandRow<N>(doc: Doc<N>, cmd: string, label: string, describedBy: string): N {
  return h(
    doc,
    'div',
    { class: 'cmd cmd-lg copy-box' },
    h(doc, 'span', { class: 'prompt', 'aria-hidden': 'true' }, '$'),
    h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-label': label, 'aria-describedby': describedBy }, h(doc, 'code', null, cmd)),
  );
}

/** What an install card shows besides the package's name. */
export interface InstallParts {
  /** The version `mopm add` pins with '=' (a published version's page), or null: mopm picks the newest that fits. */
  pin: string | null;
  /** The mopm.toml lines, or null when there are none. */
  manifest: string | null;
  /** Why there is no mopm.toml line, when the reader should be told. */
  noManifestWhy: string | null;
  /** A line under the mopm command (a yanked version's page: it adds the newest version, not that one). */
  addCaveat?: string | null;
}

/**
 * The install card, as cargo's own pages lead with cargo: `mopm add` with a Copy button (the version-pinned spelling on a
 * version page); the mopm.toml lines with a Copy button and "then run mopm sync" (or why there are none); a link to
 * install mopm itself. A name outside the grammar gets no command (snippet.ts refuses it), only the reason. On a stage
 * other than prod both commands name its `--registry`.
 */
export function installCard<N>(doc: Doc<N>, f: FullName, ctx: PageContext, parts: InstallParts): N {
  const registry = registryFlag(ctx.host);
  const add = addCommand(f, parts.pin === null ? null : { pin: parts.pin }, registry);
  const card = h(doc, 'section', { class: 'install-card', 'aria-labelledby': 'install-heading' });
  const headRow = h(doc, 'div', { class: 'install-head' }, h(doc, 'h2', { id: 'install-heading' }, 'Install'));
  doc.append(card, headRow);
  if (add !== null) {
    doc.append(headRow, h(doc, 'p', { class: 'install-note', id: 'install-note' }, INSTALL_NOTE));
    doc.append(card, commandRow(doc, add, 'install command', parts.addCaveat ? 'install-note install-caveat' : 'install-note'));
    if (parts.addCaveat) doc.append(card, h(doc, 'p', { class: 'install-caveat', id: 'install-caveat' }, parts.addCaveat));
  }
  if (parts.manifest !== null) {
    const sync = registry === null ? 'mopm sync' : `mopm sync --registry ${registry}`;
    doc.append(card, snippetBlock(doc, 'mopm.toml', parts.manifest, 'snippet-manifest'));
    doc.append(card, h(doc, 'p', { class: 'muted small' }, 'Or write this line into mopm.toml yourself, then run ', h(doc, 'code', null, sync), '.'));
  } else if (parts.noManifestWhy !== null) {
    doc.append(card, h(doc, 'p', { class: 'muted small' }, parts.noManifestWhy));
  }
  doc.append(card, h(doc, 'p', { class: 'small install-mopm' }, 'New to mopm? ', h(doc, 'a', { href: internalHref(MOPM_INSTALL_PATH) }, 'Install it'), ' with one command.'));
  return card;
}

/** A version's state in the side panel: the date for a published one, else the state in a word. */
function sideState(v: VersionSummary): string {
  switch (v.state) {
    case 'published':
      return formatDate(v.published_at);
    case 'yanked':
      return 'yanked';
    case 'tombstoned':
      return 'tombstoned';
    default:
      return 'unknown state';
  }
}

function sideVersions<N>(doc: Doc<N>, f: FullName, versions: readonly VersionSummary[]): N | null {
  if (versions.length === 0) return null;
  const shown = releaseLines(versions).slice(0, SIDE_LINES);
  return h(
    doc,
    'section',
    { 'aria-labelledby': 'side-versions' },
    h(doc, 'h2', { id: 'side-versions' }, 'Release lines'),
    h(doc, 'ul', { class: 'vers' }, ...shown.map((l) => h(doc, 'li', { class: `state-${l.shown.state}` }, versionCell(doc, f, l.shown), h(doc, 'span', null, sideState(l.shown))))),
    h(doc, 'p', { class: 'small' }, allVersionsLink(doc, f, versions.length)),
  );
}

/**
 * A GitHub login as GitHub spells it: letters, digits, single hyphens, and '_' for an enterprise-managed account, at most
 * 39 characters. Only such a login gets a link to its GitHub page; anything else from the API is shown as text.
 */
export const GITHUB_LOGIN = /^[A-Za-z0-9_](?:[A-Za-z0-9_]|-(?=[A-Za-z0-9_])){0,38}$/;

/** The account's page on GitHub, or null when `login` is not a GitHub login. */
export function githubHref(login: string): SafeHref | null {
  return GITHUB_LOGIN.test(login) ? webHref(`https://github.com/${login}`) : null;
}

function kindLabel(kind: NamespaceInfo['kind']): string {
  switch (kind) {
    case 'org':
      return 'GitHub organization';
    case 'user':
      return 'GitHub user';
    default:
      return 'unknown';
  }
}

/**
 * The namespace section of the side panel: the namespace (a link to its packages), its kind, and its GitHub account,
 * linked by its current login. A login that is no longer the namespace's spelling (the account was renamed on GitHub)
 * says so.
 */
export function namespaceSection<N>(doc: Doc<N>, ns: NamespaceInfo): N {
  const href = githubHref(ns.login);
  const account = href !== null ? h(doc, 'a', { href, rel: 'nofollow noopener noreferrer ugc' }, `@${ns.login}`) : h(doc, 'span', null, ns.login);
  const meta = details(doc, [
    ['Namespace', isNamespace(ns.namespace) ? h(doc, 'a', { href: internalHref(namespaceSearchPath(ns.namespace)), class: 'crumb-pkg' }, ns.namespace) : ns.namespace],
    ['Kind', kindLabel(ns.kind)],
    ['GitHub', account],
  ]);
  return h(
    doc,
    'section',
    { 'aria-labelledby': 'side-namespace' },
    h(doc, 'h2', { id: 'side-namespace' }, 'Namespace'),
    meta,
    ns.login.toLowerCase() !== ns.namespace ? h(doc, 'p', { class: 'muted small' }, `The GitHub account is now ${ns.login}; the namespace keeps the name ${ns.namespace}.`) : null,
  );
}

function sidePanel<N>(doc: Doc<N>, f: FullName, info: PackageInfo): N {
  const aside = h(doc, 'aside', { class: 'side-panel', 'aria-label': 'Package details' });
  const meta = details(doc, [
    ['Repository', webLink(doc, info.repository)],
    ['Homepage', webLink(doc, info.homepage)],
    ['License', info.license],
    ['Keywords', inlineList(doc, info.keywords, 'keywords')],
    ['Created', h(doc, 'time', { datetime: info.created_at }, formatDate(info.created_at))],
  ]);
  if (meta) doc.append(aside, h(doc, 'section', { 'aria-labelledby': 'side-about' }, h(doc, 'h2', { id: 'side-about' }, 'About'), meta));
  doc.append(aside, namespaceSection(doc, info.namespace));
  const vers = sideVersions(doc, f, info.versions);
  if (vers) doc.append(aside, vers);
  return aside;
}

/** The parts of a package or version page's head band. */
export interface HeadParts<N> {
  name: FullName;
  /** The version a version page is about; the crumb then links the package and ends at the version. */
  version?: string;
  /** A page of the package that is not a version (its version list): the crumb links the package and ends at this. */
  section?: string;
  /** After the h1: the latest version and its tag, or the version's state tag. */
  badges: (N | null)[];
  description?: string | null;
  facts: N[];
  /** In-page jump links; shown when there are two or more. */
  tabs: N[];
}

/**
 * The head band a package and a version page share: crumb, glyph and full name, description, facts, jump links. The
 * crumb is Packages / namespace (its packages) / name, then the version on a version page or the section on another page
 * of the package (its version list); the h1 is the full name, its namespace part muted.
 */
export function pageHead<N>(doc: Doc<N>, p: HeadParts<N>): N {
  const sep = (): N => h(doc, 'span', { class: 'sep', 'aria-hidden': 'true' }, '/');
  const crumbs: N[] = [
    h(doc, 'a', { href: internalHref(searchPath()) }, 'Packages'),
    sep(),
    h(doc, 'a', { href: internalHref(namespaceSearchPath(p.name.namespace)), class: 'crumb-pkg' }, p.name.namespace),
    sep(),
  ];
  const tail = p.version ?? p.section;
  if (tail === undefined) {
    crumbs.push(h(doc, 'span', { 'aria-current': 'page' }, p.name.name));
  } else {
    crumbs.push(h(doc, 'a', { href: internalHref(packagePath(p.name)), class: 'crumb-pkg' }, p.name.name), sep(), h(doc, 'span', { 'aria-current': 'page' }, tail));
  }
  const title: N[] = [h(doc, 'span', { class: 'ns' }, `${p.name.namespace}/`), h(doc, 'span', null, p.name.name)];
  const h1 = p.version === undefined ? h(doc, 'h1', null, ...title) : h(doc, 'h1', null, ...title, ' ', h(doc, 'span', { class: 'ver' }, p.version));
  return h(
    doc,
    'header',
    { class: 'page-band pkg-head' },
    h(doc, 'nav', { class: 'crumb', 'aria-label': 'Breadcrumb' }, ...crumbs),
    h(doc, 'div', { class: 'title-row' }, h(doc, 'span', { class: `${glyphClass(fullName(p.name))} glyph-lg`, 'aria-hidden': 'true' }, initials(p.name.name)), h1, ...p.badges),
    p.description ? h(doc, 'p', { class: 'lede' }, p.description) : null,
    p.facts.length > 0 ? h(doc, 'ul', { class: 'metarow' }, ...p.facts) : null,
    p.tabs.length > 1 ? h(doc, 'nav', { class: 'tabs', 'aria-label': 'On this page' }, ...p.tabs) : null,
  );
}

function head<N>(doc: Doc<N>, name: FullName, info: PackageInfo, latest: string | null, hasReadme: boolean): N {
  const latestRow = latest === null ? undefined : info.versions.find((v) => v.version === latest);
  const facts: N[] = [];
  if (latestRow) facts.push(h(doc, 'li', null, 'Published ', h(doc, 'strong', null, timeEl(doc, latestRow.published_at))));
  if (info.license) facts.push(h(doc, 'li', null, 'License ', h(doc, 'strong', null, info.license)));
  if (info.state !== 'claimed') facts.push(h(doc, 'li', null, h(doc, 'strong', null, String(info.versions.length)), info.versions.length === 1 ? ' version' : ' versions'));
  const tabs: N[] = [];
  // Jump links within the page, so none is marked as the selected one.
  if (hasReadme) tabs.push(h(doc, 'a', { href: anchorHref('section-readme') }, 'Readme'));
  if (info.state !== 'claimed') tabs.push(h(doc, 'a', { href: anchorHref('versions-heading') }, 'Versions ', h(doc, 'span', { class: 'count' }, String(info.versions.length))));
  return pageHead(doc, {
    name,
    badges: [
      latest !== null ? h(doc, 'span', { class: 'ver' }, h(doc, 'span', { class: 'visually-hidden' }, 'latest version '), latest) : null,
      latest !== null ? h(doc, 'span', { class: 'tag tag-ok', 'aria-hidden': 'true' }, 'latest') : null,
    ],
    description: info.description,
    facts,
    tabs,
  });
}

export function packageView<N>(doc: Doc<N>, name: FullName, info: PackageInfo, ctx: PageContext): View<N> {
  const latest = info.latest !== null && isVersion(info.latest) ? info.latest : null;
  const readme = readmeSection(doc, info.readme);

  const main = h(doc, 'div', { class: 'content' });
  if (info.state === 'claimed') {
    doc.append(main, h(doc, 'p', { class: 'notice' }, 'This name is claimed. Nothing has been published under it yet.'));
  } else if (info.state === 'unknown') {
    // As the version page treats a version state it does not know: nothing to install.
    doc.append(main, h(doc, 'p', { class: 'notice' }, 'The registry reports a package state this page does not know. Treat this package as not installable.'));
  } else if (!info.versions.some((v) => v.state === 'published')) {
    // New resolution skips a yanked version (src/core/resolve.zig) and a tombstoned one has no files, so mopm has
    // nothing to add.
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
    doc.append(main, installCard(doc, name, ctx, { pin: null, manifest, noManifestWhy: why }));
  }
  if (readme) doc.append(main, readme);
  if (info.state !== 'claimed') {
    doc.append(main, versionsSection(doc, name, info.versions));
  }

  return { title: fullName(name), nodes: [head(doc, name, info, latest, readme !== null), h(doc, 'div', { class: 'layout' }, main, sidePanel(doc, name, info))] };
}
