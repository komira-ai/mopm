// Putting a view on the page, and the home page's conda channel: the DOM work main.ts does, written against the few
// DOM members it uses so a test can pass fakes (test/mount.test.ts). main.ts hands in the real document, location and
// history; nothing here builds markup from strings.

import { condaBase } from './host.js';
import { titleOf, type View } from './views/common.js';

/** The click target a view marks for retrying (button.retry). */
export interface RetryButton {
  addEventListener(type: 'click', listener: () => void, options: { once: boolean }): void;
}

/** <main id="main"> (tabindex=-1), as mount uses it. */
export interface MainElement<N> {
  contains(node: unknown): boolean;
  replaceChildren(...nodes: N[]): void;
  focus(options: { preventScroll: boolean }): void;
  querySelector(selector: 'button.retry'): RetryButton | null;
}

export interface MountTarget<N> {
  main: MainElement<N>;
  /** The header search field (#q), or null on a page without one. */
  headerQ: { value: string } | null;
  activeElement(): unknown;
  setTitle(title: string): void;
  /** Whether the page already has a robots meta (a prerendered noindex page does). */
  hasRobotsMeta(): boolean;
  addNoindex(): void;
  /** The address now: read at mount time, after any earlier replaceState. */
  location: { readonly pathname: string; readonly search: string; readonly hash: string };
  replaceState(url: string): void;
}

/**
 * Shows `view` in <main>: the title, the nodes, focus kept on <main> when it was inside (a keyboard reader stays where
 * the new content is, though the focused Retry button is replaced), a noindex meta when the view asks and the page has
 * none, the canonical address (keeping the hash) when it differs, the header search's text, and `retry` on a click of
 * the view's Retry button.
 */
export function mount<N>(t: MountTarget<N>, view: View<N>, retry: () => void): void {
  const hadFocus = t.main.contains(t.activeElement());
  t.setTitle(titleOf(view.title));
  t.main.replaceChildren(...view.nodes);
  if (hadFocus) t.main.focus({ preventScroll: true });
  if (view.noindex && !t.hasRobotsMeta()) t.addNoindex();
  if (view.canonicalPath && view.canonicalPath !== t.location.pathname + t.location.search) {
    t.replaceState(view.canonicalPath + t.location.hash);
  }
  if (view.searchQ !== undefined && t.headerQ !== null) t.headerQ.value = view.searchQ;
  const button = t.main.querySelector('button.retry');
  if (button) button.addEventListener('click', retry, { once: true });
}

/** Puts this host's conda channel in the home page's #conda-channel (prerendered with prod's); leaves it otherwise. */
export function showChannel(el: { textContent: string | null } | null, host: string): void {
  const channel = condaBase(host);
  if (el && channel !== null) el.textContent = channel;
}
