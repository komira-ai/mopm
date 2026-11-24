// Starting the tutorial page (docs/design/tutorial-sign-in.md, section 7): reads the lesson from the mount point's
// prerendered source, starts the controller (page.ts) over the gate, a runner for the lesson, the draft storage and
// the clock, puts each new view into the mount point (view.ts), and forwards the clicks and the editors' input to the
// controller. Written against a small DOM port (TutorialDom), as enhance.ts is, so test/tutorial-start.test.ts drives
// it with StringDoc, the replaying gate and a fake runner; main.ts hands in the real document, `fetch`, the e2b runner
// and `localStorage`.
//
// - A view that differs from the one on screen only in its files (the reader typed) is not put on the page again, so
//   the editor keeps its caret and focus. Any other view replaces the mount point's nodes.
// - Focus inside the mount point stays on the control of the same id across a render; on a control the render
//   disables (Run while running) it moves there again once it is enabled, unless the reader has moved it elsewhere.
// - A click on a disabled button is not forwarded, and the controller starts one run at a time whatever it is sent.
// - The grant is the controller's, in memory; nothing here writes anything but the draft, which the controller does.

import type { Doc } from '../doc.js';
import type { TutorialGate } from './gate.js';
import { type DraftStorage, type PageView, type Runner, type TutorialPage, tutorialPage } from './page.js';
import { CONTROL, editorIndex, readLesson, type SourcePort, tutorialView } from './view.js';

/** The DOM reads and writes the page script needs beyond the Doc and SourcePort. */
export interface TutorialDom<N> extends Doc<N>, SourcePort<N> {
  replaceChildren(node: N, nodes: N[]): void;
  /** The id of the focused element when it is inside `root` and has one, else null. */
  focusedId(root: N): string | null;
  /** Whether nothing is focused (the document's body is). */
  focusIsLost(): boolean;
  /** Focuses the element with this id inside `root`, unless there is none or it is disabled; whether it did. */
  focusById(root: N, id: string): boolean;
  /** `fn` with the id of each enabled button inside `root` that is clicked. */
  onClick(root: N, fn: (id: string) => void): void;
  /** `fn` with the id and the value of each <textarea> inside `root` whose text the reader changes. */
  onInput(root: N, fn: (id: string, value: string) => void): void;
}

export interface TutorialDeps {
  gate: TutorialGate;
  /** The runner for a lesson, by its id (main.ts: e2bRunner). */
  runner: (lesson: string) => Runner;
  storage: DraftStorage;
  /** Milliseconds since the epoch. */
  now: () => number;
}

/**
 * The draft storage over a Storage that is looked up on each call (main.ts: `() => localStorage`): reading
 * `window.localStorage` itself throws where storage is blocked, and the controller treats a throwing call as no draft.
 */
export function lazyStorage(get: () => Pick<Storage, 'getItem' | 'setItem'>): DraftStorage {
  return {
    getItem: (key) => get().getItem(key),
    setItem: (key, value) => get().setItem(key, value),
  };
}

/** Whether `b` shows what `a` shows but for its files: every other field is the same value. */
export function onlyFilesDiffer(a: PageView, b: PageView): boolean {
  const ka = Object.keys(a).filter((k) => k !== 'files');
  const kb = Object.keys(b).filter((k) => k !== 'files');
  const ra = a as unknown as Record<string, unknown>;
  const rb = b as unknown as Record<string, unknown>;
  return ka.length === kb.length && ka.every((k) => Object.hasOwn(rb, k) && ra[k] === rb[k]);
}

/**
 * Starts the tutorial page in `mount`, the lesson page's #lesson-runner: the controller, and its first load(). Returns
 * the controller, or null, leaving the page as it is, when the mount point holds no lesson (view.ts readLesson).
 */
export function startTutorial<N>(dom: TutorialDom<N>, mount: N, deps: TutorialDeps): TutorialPage | null {
  const found = readLesson(dom, mount);
  if (found === null) return null;
  const lesson = found;
  let shown: PageView | null = null;
  /** The control to focus once the render allows it: the one focused before a render that replaced or disabled it. */
  let refocus: string | null = null;

  function render(v: PageView): void {
    if (shown !== null && onlyFilesDiffer(shown, v)) {
      shown = v;
      return;
    }
    const focused = dom.focusedId(mount);
    if (focused !== null) refocus = focused;
    else if (!dom.focusIsLost()) refocus = null;
    dom.replaceChildren(mount, tutorialView(dom, v, lesson));
    if (refocus !== null && dom.focusById(mount, refocus)) refocus = null;
    shown = v;
  }

  const page = tutorialPage({ lesson, gate: deps.gate, runner: deps.runner(lesson.id), storage: deps.storage, now: deps.now, onChange: render });

  dom.onClick(mount, (id) => {
    if (id === CONTROL.run) void page.run('run');
    else if (id === CONTROL.test) void page.run('test');
    else if (id === CONTROL.signOut) void page.signOut();
    else if (id === CONTROL.retry) void page.load();
  });
  dom.onInput(mount, (id, value) => {
    const i = editorIndex(id);
    if (i !== null && i < lesson.files.length) page.edit(lesson.files[i].path, value);
  });

  render(page.view());
  void page.load();
  return page;
}
