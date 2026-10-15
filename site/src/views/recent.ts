// The home page's "Recently published" list, filled at runtime from one searchPackages call.
//
// The prerendered home page holds only an empty slot (#recent-list) with a loading line and a line for readers
// without scripts; main.ts makes the call and puts these nodes in the slot. Nothing about the registry's contents is
// baked into a page at build time. A name that is only claimed (latest null) has published nothing, so it is left
// out. With no q every package matches, and the API refuses sort=updated once more than 1000 packages match: that
// answer gets its own sentence and a link to the name-sorted list.

import type { Result, SearchQuery } from '../api.js';
import { type Doc, h } from '../doc.js';
import { formatDate } from '../format.js';
import { internalHref } from '../links.js';
import { isCanonicalName, packagePath, searchPath } from '../routes.js';
import type { PackageList, PackageSummary } from '../types.js';

export const RECENT_LIMIT = 8;

/** The one call the list makes. */
export function recentQuery(): SearchQuery {
  return { sort: 'updated', limit: RECENT_LIMIT };
}

/** Two letters for a package's decorative glyph: the first letters of its first two words, else its first two. */
export function initials(name: string): string {
  const words = name.split('_').filter((w) => w !== '');
  const s = words.length >= 2 ? words[0][0] + words[1][0] : name.slice(0, 2);
  return s.toLowerCase();
}

/** One of three glyph colours, the same for a name everywhere. */
export function glyphClass(name: string): string {
  let n = 0;
  for (let i = 0; i < name.length; i++) n = (n * 31 + name.charCodeAt(i)) >>> 0;
  return `glyph g${n % 3}`;
}

function browseLink<N>(doc: Doc<N>, text: string): N {
  return h(doc, 'a', { href: internalHref(searchPath()) }, text);
}

function item<N>(doc: Doc<N>, p: PackageSummary & { latest: string }): N {
  const name = isCanonicalName(p.name)
    ? h(doc, 'a', { href: internalHref(packagePath(p.name)), class: 'recent-name' }, p.name)
    : h(doc, 'span', { class: 'recent-name' }, p.name);
  return h(
    doc,
    'li',
    null,
    h(doc, 'span', { class: glyphClass(p.name), 'aria-hidden': 'true' }, initials(p.name)),
    h(doc, 'p', { class: 'recent-head' }, name, ' ', h(doc, 'span', { class: 'recent-ver' }, h(doc, 'span', { class: 'visually-hidden' }, 'version '), p.latest)),
    p.description ? h(doc, 'p', { class: 'recent-sum' }, p.description) : null,
    h(doc, 'time', { datetime: p.updated_at }, formatDate(p.updated_at)),
  );
}

/** The slot's content for the answer of recentQuery. */
export function recentList<N>(doc: Doc<N>, r: Result<PackageList>): N[] {
  if (r.kind === 'ok') {
    const published = r.value.packages.filter((p): p is PackageSummary & { latest: string } => p.latest !== null);
    if (published.length === 0) return [h(doc, 'p', { class: 'recent-note' }, 'Nothing has been published yet.')];
    return [h(doc, 'ol', { class: 'recent' }, ...published.map((p) => item(doc, p)))];
  }
  if (r.kind === 'invalid') {
    return [h(doc, 'p', { class: 'recent-note' }, 'The registry has too many packages to list by update time here. ', browseLink(doc, 'Browse all packages'), '.')];
  }
  return [h(doc, 'p', { class: 'recent-note' }, 'Recently published packages could not be loaded. ', browseLink(doc, 'Browse all packages'), '.')];
}

/** The slot's content on a host outside host.ts's table, which never calls an API. */
export function recentUnavailable<N>(doc: Doc<N>): N[] {
  return [h(doc, 'p', { class: 'recent-note' }, 'This copy of the site is not served from mopm.dev, so it does not call the registry.')];
}
