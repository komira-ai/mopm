// The tutorial page's nodes (docs/design/tutorial-sign-in.md, section 7): a pure function from the controller's
// `PageView` (page.ts) to nodes through a Doc, so tests render it with StringDoc and need no DOM, and the lesson's
// source as the build prerenders it into the runner's mount point and the page script reads it back.
//
// - The mount point (#lesson-runner, data-lesson="<lesson>") holds the lesson's editable files, each a path and a
//   <pre>, and its commands (`lessonSource`): what a reader without scripts sees, and where the page script reads the
//   lesson from (`readLesson`; a page cannot carry JSON, since every <script> must be empty, tools/check-dist.ts).
// - Signed out: the sign-in card with the gate's SafeHref; the files read-only, or, when the session ended while the
//   page was in use, the edited files still in their editors with the sign-in message.
// - Signed in: who is signed in and Sign out, a <textarea> per editable file, Run (and Test), disabled while a run is
//   in flight, the message of an error code, and the last run's exit code and output.
// - Output is text nodes in a <pre>, never markup: the controller has already turned control, bidi and invisible
//   characters into `[U+XXXX]` markers (page.ts `visible`).
// Every element is built through h(), so no attribute outside the Doc allowlist (and none Trusted Types guards) is set.
// Controls carry the ids of CONTROL; the page script (start.ts) finds them there and attaches no handler per node.

import { type Doc, h } from '../doc.js';
import { LESSON } from './gate.js';
import type { Action, Lesson, LessonFile, Message, Output, PageView } from './page.js';

/** The id of the element the page script fills (the lesson page's mount point, tools/tutorial.ts). */
export const RUNNER_ID = 'lesson-runner';

/** The ids of the page's controls. A file's editor is `lesson-file-<i>`, i its index in the lesson's files. */
export const CONTROL = {
  run: 'lesson-run',
  test: 'lesson-test',
  signOut: 'lesson-sign-out',
  retry: 'lesson-retry',
} as const;

export const editorId = (i: number): string => `lesson-file-${i}`;

/** The index of the file whose editor has id `id`, or null when `id` is no editor's. */
export function editorIndex(id: string): number | null {
  const m = /^lesson-file-(0|[1-9][0-9]{0,3})$/.exec(id);
  return m === null ? null : Number(m[1]);
}

/** The classes lessonSource writes and readLesson reads. */
export const SOURCE_CLASS = {
  file: 'lesson-file',
  path: 'lesson-path',
  text: 'lesson-text',
  run: 'lesson-command-run',
  test: 'lesson-command-test',
} as const;

const ACTION_LABEL: Readonly<Record<Action, string>> = { run: 'Run', test: 'Test' };

/** An editor's height: the file's lines and one more, between 4 and 30. */
export function rowsFor(text: string): number {
  return Math.min(30, Math.max(4, text.split('\n').length + 1));
}

function fileBlock<N>(doc: Doc<N>, f: LessonFile): N {
  return h(
    doc,
    'div',
    { class: SOURCE_CLASS.file },
    h(doc, 'p', { class: SOURCE_CLASS.path }, h(doc, 'code', null, f.path)),
    // The text inside <code>, not directly in <pre>: a browser drops a newline that starts a <pre>.
    h(doc, 'pre', { class: SOURCE_CLASS.text }, h(doc, 'code', null, f.text)),
  );
}

function commands<N>(doc: Doc<N>, lesson: Lesson): N {
  const row = (a: Action, cmd: string): N[] => [h(doc, 'dt', null, ACTION_LABEL[a]), h(doc, 'dd', { class: SOURCE_CLASS[a] }, h(doc, 'code', null, cmd))];
  return h(
    doc,
    'dl',
    { class: 'lesson-commands' },
    ...row('run', lesson.actions.run),
    ...(lesson.actions.test === undefined ? [] : row('test', lesson.actions.test)),
  );
}

/** The lesson's files, read-only, and its commands: the prerendered mount point's content. */
export function lessonSource<N>(doc: Doc<N>, lesson: Lesson): N[] {
  return [h(doc, 'div', { class: 'lesson-files' }, ...lesson.files.map((f) => fileBlock(doc, f))), commands(doc, lesson)];
}

/** What readLesson needs of the page: the elements of a class under a node, an element's text and attributes. */
export interface SourcePort<N> {
  /** The elements under `root` (not `root` itself) whose class list holds `className`, in document order. */
  byClass(root: N, className: string): N[];
  textOf(node: N): string;
  attr(node: N, name: string): string | null;
}

/**
 * The lesson the mount point's prerendered source holds (lessonSource, with the mount's data-lesson as the id), or null
 * when it holds none the page can run: no lesson id, an id outside the grammar, no file, a file without its path or its
 * text, a path given twice, or no run command.
 */
export function readLesson<N>(port: SourcePort<N>, mount: N): Lesson | null {
  const id = port.attr(mount, 'data-lesson');
  if (id === null || !LESSON.test(id)) return null;
  const files: LessonFile[] = [];
  for (const el of port.byClass(mount, SOURCE_CLASS.file)) {
    const [path] = port.byClass(el, SOURCE_CLASS.path);
    const [text] = port.byClass(el, SOURCE_CLASS.text);
    if (path === undefined || text === undefined) return null;
    const p = port.textOf(path);
    if (p === '' || files.some((f) => f.path === p)) return null;
    files.push({ path: p, text: port.textOf(text) });
  }
  const command = (a: Action): string | undefined => {
    const [el] = port.byClass(mount, SOURCE_CLASS[a]);
    return el === undefined ? undefined : port.textOf(el);
  };
  const run = command('run');
  const test = command('test');
  if (files.length === 0 || run === undefined || run === '') return null;
  return { id, files, actions: test === undefined ? { run } : { run, test } };
}

// ---- the views --------------------------------------------------------------------------------------------------

function messageEl<N>(doc: Doc<N>, m: Message): N {
  return h(doc, 'p', { class: 'notice notice-error lesson-message', role: 'alert' }, m.text);
}

function signInCard<N>(doc: Doc<N>, v: Extract<PageView, { state: 'signed_out' }>): N {
  return h(
    doc,
    'div',
    { class: 'notice lesson-sign-in' },
    v.message === null ? h(doc, 'p', null, 'Sign in with GitHub to edit this lesson and run it in a sandbox.') : messageEl(doc, v.message),
    h(doc, 'p', null, h(doc, 'a', { class: 'button button-primary', href: v.sign_in }, 'Sign in with GitHub')),
  );
}

function editors<N>(doc: Doc<N>, files: readonly LessonFile[]): N {
  return h(
    doc,
    'div',
    { class: 'lesson-files' },
    ...files.map((f, i) =>
      h(
        doc,
        'div',
        { class: 'lesson-editor' },
        h(doc, 'label', { for: editorId(i) }, h(doc, 'code', null, f.path)),
        h(
          doc,
          'textarea',
          { id: editorId(i), name: f.path, class: 'lesson-code', rows: String(rowsFor(f.text)), spellcheck: 'false', autocomplete: 'off' },
          f.text,
        ),
      ),
    ),
  );
}

function outputEl<N>(doc: Doc<N>, o: Output): N {
  const printed = [o.stdout, o.stderr].filter((s) => s !== '');
  return h(
    doc,
    'section',
    { class: 'lesson-output', 'aria-label': 'Output' },
    h(doc, 'p', { class: 'lesson-exit' }, o.exit_note ?? 'The program exited with code 0.'),
    printed.length === 0 ? h(doc, 'p', { class: 'muted' }, 'The program printed nothing.') : h(doc, 'pre', { class: 'lesson-out' }, ...printed),
  );
}

/**
 * The mount point's nodes for `v`. `lesson` gives the read-only files before the session's answer and when signed out
 * with no editor.
 */
export function tutorialView<N>(doc: Doc<N>, v: PageView, lesson: Lesson): N[] {
  switch (v.state) {
    case 'loading':
      return [h(doc, 'p', { class: 'lesson-status muted', role: 'status' }, 'Checking whether you are signed in…'), ...lessonSource(doc, lesson)];
    case 'unavailable':
      return [
        messageEl(doc, v.message),
        h(doc, 'p', null, h(doc, 'button', { type: 'button', id: CONTROL.retry, class: 'button' }, 'Try again')),
        ...lessonSource(doc, lesson),
      ];
    case 'signed_out':
      return [signInCard(doc, v), ...(v.files === null ? lessonSource(doc, lesson) : [editors(doc, v.files)])];
    default: {
      const running = v.state === 'running';
      const disabled = running ? '' : undefined;
      return [
        h(
          doc,
          'p',
          { class: 'lesson-login' },
          'Signed in as ',
          h(doc, 'strong', null, v.login),
          '. ',
          h(doc, 'button', { type: 'button', id: CONTROL.signOut, class: 'button', disabled }, 'Sign out'),
        ),
        editors(doc, v.files),
        h(
          doc,
          'p',
          { class: 'lesson-buttons' },
          ...v.actions.map((a, i) =>
            h(doc, 'button', { type: 'button', id: CONTROL[a], class: i === 0 ? 'button button-primary' : 'button', disabled }, ACTION_LABEL[a]),
          ),
        ),
        h(doc, 'p', { class: 'lesson-status muted', role: 'status' }, v.running === null ? '' : `${v.running === 'test' ? 'Testing' : 'Running'}…`),
        v.message === null ? null : messageEl(doc, v.message),
        v.output === null ? null : outputEl(doc, v.output),
      ].filter((n): n is N => n !== null);
    }
  }
}
