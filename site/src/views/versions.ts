// /packages/<namespace>/<name>/versions: every version of one package (getPackage), the full table the package page
// links to from its release lines. The head band is the package's, its crumb ending at "Versions"; then the table of
// every version in the API's order (newest first) with its state and publish time, and a link back to the package. A
// claimed name has no versions and says so, as the package page does.

import { type Doc, h } from '../doc.js';
import { internalHref } from '../links.js';
import { type FullName, fullName, packagePath } from '../routes.js';
import type { PackageInfo } from '../types.js';
import type { View } from './common.js';
import { pageHead, versionsTable } from './package.js';

export function versionsView<N>(doc: Doc<N>, name: FullName, info: PackageInfo): View<N> {
  const n = info.versions.length;
  const main = h(doc, 'div', { class: 'content' });
  const section = h(doc, 'section', { class: 'versions', 'aria-labelledby': 'versions-heading' }, h(doc, 'h2', { id: 'versions-heading' }, 'All versions'));
  if (info.state === 'claimed') {
    doc.append(section, h(doc, 'p', { class: 'notice' }, 'This name is claimed. Nothing has been published under it yet.'));
  } else {
    doc.append(section, versionsTable(doc, name, info.versions));
  }
  doc.append(section, h(doc, 'p', { class: 'small' }, h(doc, 'a', { href: internalHref(packagePath(name)) }, `The package page of ${fullName(name)}`)));
  doc.append(main, section);
  const facts = info.state === 'claimed' ? [] : [h(doc, 'li', null, h(doc, 'strong', null, String(n)), n === 1 ? ' version' : ' versions')];
  return {
    title: `Versions of ${fullName(name)}`,
    nodes: [pageHead(doc, { name, section: 'Versions', badges: [], description: info.description, facts, tabs: [] }), h(doc, 'div', { class: 'layout' }, main)],
  };
}
