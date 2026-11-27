// The header's "Tutorial" entry, and its removal from a page. Every stage deploys the same build (README, rule 4), so
// tools/layout.ts puts the entry in the header of every page; the site stack (service/infra/stacks/lib/site-stack.ts)
// uploads the pages without it on a stage that does not serve the tutorial, where /tutorial is the 404 page.
// The stack reads this module as it is (site/BUCK exports it), so it imports only the route grammar the stack reads too.

import { TUTORIAL_PATH } from '../src/routes';

/** The id of the header's Tutorial entry, an <li> of the site nav. */
export const TUTORIAL_NAV_ID = 'nav-tutorial';

/**
 * The entry as every page outside the tutorial holds it, byte for byte (test/layout.test.ts holds the layout to it). A
 * tutorial page marks its link aria-current, but no stage that strips the entry serves a tutorial page.
 */
export const TUTORIAL_NAV_ITEM = `<li id="${TUTORIAL_NAV_ID}"><a href="${TUTORIAL_PATH}">Tutorial</a></li>`;

/** A link to /tutorial or a page under it, as the layout and the views write one (an internalHref). */
const TUTORIAL_HREF = new RegExp(`\\shref="${TUTORIAL_PATH}(?:[/?#"])`);

/**
 * `html`, the page `page` of the build, without the header's Tutorial entry. Throws, naming the page, when the page does
 * not hold the entry exactly once, or when it still links to the tutorial without it: a page of a stage that does not
 * serve the tutorial must not link to its 404 page, and a page the layout did not write as expected is refused rather
 * than uploaded with the link.
 */
export function withoutTutorialLink(page: string, html: string): string {
  const parts = html.split(TUTORIAL_NAV_ITEM);
  if (parts.length !== 2) {
    throw new Error(`${page}: expected the header's Tutorial entry exactly once, found it ${parts.length - 1} times`);
  }
  const out = parts.join('');
  if (TUTORIAL_HREF.test(out)) throw new Error(`${page}: links to ${TUTORIAL_PATH} outside the header's Tutorial entry`);
  return out;
}
