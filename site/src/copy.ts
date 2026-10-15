// Copy buttons for command blocks.
//
// A block a reader may copy is a `.copy-box` holding one <pre>. The page script adds the button (main.ts calls
// addCopyButton for each box once the page or a view is on it), so a page without scripts never shows a button that
// does nothing: the command stays plain, selectable text. The button is built through the Doc port like any markup;
// the click writes the <pre>'s text with the Clipboard API and says so twice: the button reads "Copied" for a moment,
// and a polite live region announces it to screen readers (the button's own name stays "Copy <label>"). A browser with
// no clipboard (an insecure context, an old engine) gets no button.

import { type Doc, h } from './doc.js';

/** navigator.clipboard, as the button uses it. */
export interface Clipboard {
  writeText(text: string): Promise<void>;
}

/** The DOM work a button needs beyond building nodes: a click handler, replacing a node's text, reading it. */
export interface CopyPort<N> extends Doc<N> {
  onClick(node: N, fn: () => void): void;
  setText(node: N, text: string): void;
  textOf(node: N): string;
}

export type Later = (fn: () => void, ms: number) => unknown;

export const COPY = 'Copy';
export const COPIED = 'Copied';
export const FAILED = 'Copy failed. Select the text and copy it.';
/** How long the button reads "Copied" before it reads "Copy" again. */
export const RESET_MS = 2000;

/**
 * Appends a Copy button and its live status to `box`; a click copies the text of `source`. `label` names what is
 * copied ("Install command"). Returns the button, or null when there is no clipboard (nothing is added).
 */
export function addCopyButton<N>(port: CopyPort<N>, box: N, source: N, label: string, clipboard: Clipboard | null, later: Later): N | null {
  if (clipboard === null) return null;
  const button = h(port, 'button', { type: 'button', class: 'copy', 'aria-label': `${COPY} ${label}` }, COPY);
  const status = h(port, 'span', { class: 'visually-hidden', role: 'status', 'aria-live': 'polite' });
  // Each click starts a new round; a reset timer from an earlier round does not cut a later "Copied" short.
  let round = 0;
  const reset = (mine: number): void => {
    if (mine !== round) return;
    port.setText(button, COPY);
    port.setAttr(button, 'class', 'copy');
    port.setText(status, '');
  };
  port.onClick(button, () => {
    const mine = ++round;
    let p: Promise<void>;
    try {
      p = clipboard.writeText(port.textOf(source));
    } catch (e) {
      p = Promise.reject(e);
    }
    p.then(
      () => {
        if (mine !== round) return;
        port.setText(button, COPIED);
        port.setAttr(button, 'class', 'copy done');
        port.setText(status, `${COPIED}: ${label}`);
        later(() => reset(mine), RESET_MS);
      },
      () => {
        if (mine !== round) return;
        port.setText(button, COPY);
        port.setAttr(button, 'class', 'copy');
        port.setText(status, FAILED);
      },
    );
  });
  port.append(box, button);
  port.append(box, status);
  return button;
}

/** The name of a command block for its button: its <pre>'s aria-label, else the text of its labelling element. */
export function copyLabel(ariaLabel: string | null, labelledByText: string | null): string {
  const s = (ariaLabel ?? labelledByText ?? '').trim();
  return s === '' ? 'command' : s;
}
