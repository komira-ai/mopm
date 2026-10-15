// What the page script adds to a page once it is on screen: a Copy button on each command block, and the home page's
// "Recently updated" list. Written against a small DOM port (EnhancePort), as mount.ts is, so test/enhance.test.ts
// drives it with StringDoc; main.ts hands in the real document.

import type { Client } from './api.js';
import { addCopyButton, type Clipboard, copyLabel, type CopyPort, type Later } from './copy.js';
import { recentList, recentQuery, recentUnavailable } from './views/recent.js';

/** The DOM reads and writes beyond CopyPort that the two need. */
export interface EnhancePort<N> extends CopyPort<N> {
  /** Every element with class copy-box under root, in document order. */
  copyBoxes(root: N): N[];
  /** The first <pre> under box, or null. */
  firstPre(box: N): N | null;
  /** Whether box already holds a button.copy. */
  hasCopyButton(box: N): boolean;
  getAttr(node: N, name: string): string | null;
  /** The text of the element with this id, or null when there is none. */
  textById(id: string): string | null;
  replaceChildren(node: N, nodes: N[]): void;
}

/**
 * A Copy button for each .copy-box under root that has a <pre> and no button yet, named from the <pre>'s aria-label
 * or the text of the element its aria-labelledby names. With no clipboard nothing is added. Returns how many were added.
 */
export function addCopyButtons<N>(port: EnhancePort<N>, root: N, clipboard: Clipboard | null, later: Later): number {
  let added = 0;
  for (const box of port.copyBoxes(root)) {
    const pre = port.firstPre(box);
    if (pre === null || port.hasCopyButton(box)) continue;
    const by = port.getAttr(pre, 'aria-labelledby');
    const label = copyLabel(port.getAttr(pre, 'aria-label'), by ? port.textById(by) : null);
    if (addCopyButton(port, box, pre, label, clipboard, later) !== null) added++;
  }
  return added;
}

/**
 * The search field '/' focuses: the search page's big box (#search-q) when the page has one, else the header's (#q),
 * else none. The header search stays on every app-shell view (the shell paints it before it knows the view, so hiding
 * it later would move the page), so on /search both exist and the page's own box, which holds the query, wins.
 */
export function searchFieldId(has: (id: string) => boolean): 'search-q' | 'q' | null {
  if (has('search-q')) return 'search-q';
  return has('q') ? 'q' : null;
}

/**
 * Fills the home page's #recent-list slot from one searchPackages call, and marks it no longer busy whatever the
 * answer: a rejected call is shown as a network failure, and a host with no API (api null) says why it calls nothing.
 */
export async function showRecent<N>(port: EnhancePort<N>, slot: N | null, api: Pick<Client, 'searchPackages'> | null): Promise<void> {
  if (slot === null) return;
  let nodes: N[];
  if (api === null) {
    nodes = recentUnavailable(port);
  } else {
    try {
      nodes = recentList(port, await api.searchPackages(recentQuery()));
    } catch {
      nodes = recentList(port, { kind: 'network', message: '', requestId: null });
    }
  }
  port.replaceChildren(slot, nodes);
  port.setAttr(slot, 'aria-busy', 'false');
}
