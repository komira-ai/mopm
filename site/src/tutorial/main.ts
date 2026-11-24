// The tutorial page's script: the entry of the bundle tutorial.js (tools/build.ts, TUTORIAL_ENTRY), which only the
// tutorial's pages load, beside the site's main.js. It connects start.ts to the real document: the gate over the site's
// own routes (same-origin, with the session cookie), the e2b runner of the lesson, `localStorage` for the draft (looked
// up on each call, so a blocked one leaves the page working without a draft), and the system clock. The sandbox grant
// stays in the controller's memory. Nothing here builds markup from strings: the nodes are browserDoc's, and the only
// DOM writes are start.ts's replaceChildren and focus.

import { browserDoc } from '../doc.js';
import { httpGate } from './gate.js';
import { e2bRunner } from './runner.js';
import { lazyStorage, startTutorial, type TutorialDom } from './start.js';
import { RUNNER_ID } from './view.js';

const dom: TutorialDom<Node> = {
  ...browserDoc,
  byClass: (root, className) => Array.from((root as Element).getElementsByClassName(className)),
  textOf: (node) => node.textContent ?? '',
  attr: (node, name) => (node as Element).getAttribute(name),
  replaceChildren: (node, nodes) => (node as ParentNode).replaceChildren(...nodes),
  focusedId: (root) => {
    const a = document.activeElement;
    return a instanceof HTMLElement && a.id !== '' && root.contains(a) ? a.id : null;
  },
  focusIsLost: () => document.activeElement === null || document.activeElement === document.body,
  focusById: (root, id) => {
    const e = document.getElementById(id);
    if (!(e instanceof HTMLElement) || !root.contains(e) || e.hasAttribute('disabled')) return false;
    e.focus({ preventScroll: true });
    return true;
  },
  onClick: (root, fn) =>
    root.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('button') : null;
      if (b !== null && root.contains(b) && !b.disabled && b.id !== '') fn(b.id);
    }),
  onInput: (root, fn) =>
    root.addEventListener('input', (e) => {
      const t = e.target;
      if (t instanceof HTMLTextAreaElement && t.id !== '') fn(t.id, t.value);
    }),
};

const mount = document.getElementById(RUNNER_ID);
if (mount !== null) {
  startTutorial(dom, mount, {
    gate: httpGate((url, init) => fetch(url, init)),
    runner: e2bRunner,
    storage: lazyStorage(() => localStorage),
    now: () => Date.now(),
  });
}
