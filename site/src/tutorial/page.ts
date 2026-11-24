// The tutorial page's logic, with no DOM and no SDK (docs/design/tutorial-sign-in.md, sections 4 and 7).
//
// A controller over the gate (gate.ts) and a `Runner` port: what the page shows is a `PageView` value, and the page
// script turns it into nodes. The runner over the E2B SDK is a separate module; this one only knows the port, so it
// type-checks and runs in tests without `e2b`. The clock and the storage are injected too.
//
// - Signed out: the lesson and the sign-in link, whose return_to is this lesson's page; no editor.
// - Signed in: the editor's files (the lesson's, or the browser's draft of them), Run (and Test), the last output.
// - Running: the same, while a run is in flight; a second run is not started.
// - Each code of the endpoint's error table is a message. `session_required` turns the page to signed out and keeps
//   the edited files in the editor; `csrf_failed` asks the session again and retries once first.
// - One sandbox per page, held in memory only: replaced when its `expires_at` is less than RENEW_BEFORE_MS away, and
//   once when the runner says the sandbox is gone (not running or unreachable), after which the run is repeated.
// - A non-zero exit is the program's own result: its code is shown with its output, not as an error of the page.
// - Output shows control, bidi and invisible characters as visible markers (`visible`).
// - The draft (the edited files and the last lesson opened) lives in the browser's storage under DRAFT_KEY. A storage
//   that throws (blocked, full, a private window) leaves the page working without one. The grant is never written.

import type { SafeHref } from '../doc.js';
import { type GateErrorCode, LESSON, type SandboxGrant, type TutorialGate } from './gate.js';

/** One editable file of the lesson: its path in the lesson's project (lesson.json `editable`) and its text. */
export interface LessonFile {
  path: string;
  text: string;
}

/** The lesson the page shows, as the site build wrote it into the page. */
export interface Lesson {
  /** The lesson's id (`LESSON`), the `<lesson>` of `/tutorial/<lesson>`. */
  id: string;
  /** The editable files with the project's text, in lesson.json's order. */
  files: readonly LessonFile[];
  /** lesson.json `actions`: the command of each button. */
  actions: { run: string; test?: string };
}

export type Action = 'run' | 'test';

/** A run that finished: the program's exit code and its output, as the sandbox gave them. */
export interface RunResult {
  exit_code: number;
  stdout: string;
  stderr: string;
}

/** The sandbox is gone (`SandboxNotRunningError`, `SandboxUnreachableError` of the SDK): ask for a new one. */
export type RunnerError = { kind: 'SandboxNotRunning' } | { kind: 'SandboxUnreachable' };

/**
 * Runs a command of the lesson in the grant's sandbox: writes `files` into the lesson's directory, then runs
 * `command` there. A runner is built for one lesson's directory. Any other failure it throws.
 */
export interface Runner {
  run(grant: SandboxGrant, files: readonly LessonFile[], command: string): Promise<RunResult | RunnerError>;
}

/** The two calls of `localStorage` the draft uses. Each call may throw; the page then works without a draft. */
export interface DraftStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** The draft's key (design section 6). The `1` is the format's version. */
export const DRAFT_KEY = 'mopm.tutorial.1';

/** A grant closer than this to its `expires_at` is replaced before a run, so no run starts on a sandbox about to end. */
export const RENEW_BEFORE_MS = 60_000;

/** What the page says: a code of the endpoint's table, or `run_failed` (the runner failed in a way it did not name). */
export type MessageCode = GateErrorCode | 'run_failed';

export interface Message {
  code: MessageCode;
  text: string;
}

/** The endpoint's table's sentences (design, "The endpoint"). */
export const MESSAGES: Readonly<Record<MessageCode, string>> = {
  session_required: 'Sign in with GitHub to run this lesson.',
  csrf_failed: 'Reload the page.',
  invalid_request: 'Something went wrong. Reload the page.',
  tutorial_unavailable: 'The sandbox service did not answer. Try again in a minute.',
  run_failed: 'The run stopped before it finished. Try again.',
};

/** A finished run as the page shows it: the output with markers, and a note when the exit code is not 0. */
export interface Output {
  action: Action;
  exit_code: number;
  stdout: string;
  stderr: string;
  /** "The program exited with code <n>." for a non-zero exit, else null. */
  exit_note: string | null;
}

export type PageView =
  /** Before the session's answer. */
  | { state: 'loading'; lesson: string }
  /** The session could not be read: the message, and `load()` again to retry. */
  | { state: 'unavailable'; lesson: string; message: Message }
  /**
   * Signed out: the sign-in link. `files` is null on a page opened signed out (no editor), and the edited files when
   * the session ended while the page was in use (they stay in the editor).
   */
  | { state: 'signed_out'; lesson: string; sign_in: SafeHref; files: readonly LessonFile[] | null; message: Message | null }
  | {
      state: 'signed_in' | 'running';
      lesson: string;
      login: string;
      files: readonly LessonFile[];
      actions: readonly Action[];
      /** The action in flight when `running`, else null. */
      running: Action | null;
      output: Output | null;
      message: Message | null;
    };

export interface PageOptions {
  lesson: Lesson;
  gate: TutorialGate;
  runner: Runner;
  storage: DraftStorage;
  /** Milliseconds since the epoch. */
  now: () => number;
  /** Called with each new view. */
  onChange: (view: PageView) => void;
}

export interface TutorialPage {
  view(): PageView;
  /** Asks for the session and shows the page for it. Does nothing while a load, run or sign-out is in flight. */
  load(): Promise<void>;
  /** Replaces one editable file's text and saves the draft. Throws for a path that is not one of the lesson's. */
  edit(path: string, text: string): void;
  /** Runs the action's command. Does nothing unless signed in and idle, or when the lesson has no such action. */
  run(action: Action): Promise<void>;
  /** Signs out. Does nothing unless signed in and idle. */
  signOut(): Promise<void>;
}

// ---- output -------------------------------------------------------------------------------------------------------

/**
 * Every character `visible` replaces: C0 and C1 controls and DEL (Cc), format characters (Cf: the bidi embeddings,
 * overrides and isolates, zero-width characters, the BOM, tag characters), the line and paragraph separators (Zl, Zp),
 * a lone surrogate (Cs), and the invisible letters that are default-ignorable (the combining grapheme joiner, the
 * Hangul fillers, the Khmer inherent vowels). Newline and tab are not replaced. Variation selectors stay, since emoji
 * need them.
 */
const INVISIBLE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}͏ᅟᅠ឴឵ㅤﾠ]/gu;

/**
 * Output text as the page shows it, so nothing a program prints can hide or reorder what is shown (the copied-example
 * rule of the site design, appendix C.2). Each character of INVISIBLE except newline and tab becomes the marker
 * `[U+XXXX]`, its code point in upper-case hex of at least four digits: `‮` is `[U+202E]`, ESC is `[U+001B]`,
 * the tag character `\u{E0041}` is `[U+E0041]`. A CR before an LF is dropped, so Windows line ends read as newlines.
 */
export function visible(s: string): string {
  return s.replace(/\r\n/g, '\n').replace(INVISIBLE, (c) => {
    if (c === '\n' || c === '\t') return c;
    return `[U+${(c.codePointAt(0) as number).toString(16).toUpperCase().padStart(4, '0')}]`;
  });
}

/** The note beside the output of a non-zero exit, or null for 0. */
export function exitNote(code: number): string | null {
  return code === 0 ? null : `The program exited with code ${code}.`;
}

// ---- the draft ----------------------------------------------------------------------------------------------------

type Obj = Record<string, unknown>;

function object(v: unknown): Obj | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : null;
}

function own(o: Obj | null, k: string): unknown {
  return o !== null && Object.hasOwn(o, k) ? o[k] : undefined;
}

/** The stored draft as an object, or an empty one when there is none, it does not parse, or the storage throws. */
function readRaw(storage: DraftStorage): Obj {
  try {
    const s = storage.getItem(DRAFT_KEY);
    return (s === null ? null : object(JSON.parse(s))) ?? {};
  } catch {
    return {};
  }
}

/** Writes the draft; a storage that throws (blocked, or over its quota) leaves the page without one. */
function writeRaw(storage: DraftStorage, raw: Obj): void {
  try {
    storage.setItem(DRAFT_KEY, JSON.stringify(raw));
  } catch {
    // The page works without a draft.
  }
}

/** The last lesson the browser opened, from the draft; null when there is none or it is not a lesson id. */
export function lastLesson(storage: DraftStorage): string | null {
  const v = own(readRaw(storage), 'last_lesson');
  return typeof v === 'string' && LESSON.test(v) ? v : null;
}

/**
 * The draft's format, version 1: `{"last_lesson": "<lesson>", "files": {"<lesson>": {"<path>": "<text>"}}}`. A
 * write keeps every other field and every other lesson's files as it found them, so a later page that adds a field
 * does not lose it to an earlier one.
 */
function saveDraft(storage: DraftStorage, lesson: string, files: readonly LessonFile[] | null): void {
  const raw = readRaw(storage);
  raw.last_lesson = lesson;
  if (files !== null) {
    raw.files = { ...object(own(raw, 'files')), [lesson]: Object.fromEntries(files.map((f) => [f.path, f.text])) };
  }
  writeRaw(storage, raw);
}

/** The lesson's files with the draft's text for each path the draft holds as a string. */
function draftFiles(storage: DraftStorage, lesson: Lesson): LessonFile[] {
  const mine = object(own(object(own(readRaw(storage), 'files')), lesson.id));
  return lesson.files.map((f) => {
    const t = own(mine, f.path);
    return { path: f.path, text: typeof t === 'string' ? t : f.text };
  });
}

// ---- the controller -----------------------------------------------------------------------------------------------

/** What a run came to: a result, the sandbox gone, a code of the gate's table, or `run_failed` (the runner threw). */
type Attempt = RunResult | RunnerError | { error: MessageCode };

/** The page's controller. Throws when the lesson's id is not a lesson id. */
export function tutorialPage(opts: PageOptions): TutorialPage {
  const { lesson, gate, runner, storage, now, onChange } = opts;
  if (!LESSON.test(lesson.id)) throw new Error(`tutorialPage: '${lesson.id}' is not a lesson id`);
  const signIn = gate.signInHref(`/tutorial/${lesson.id}`);
  const actions: readonly Action[] = lesson.actions.test === undefined ? ['run'] : ['run', 'test'];

  let current: PageView = { state: 'loading', lesson: lesson.id };
  /** The editor's files; null until a signed-in page has shown them. */
  let files: LessonFile[] | null = null;
  let login = '';
  /** The page's one sandbox, in memory only. */
  let grant: SandboxGrant | null = null;
  /** A load, run or sign-out is in flight: another one is not started. */
  let busy = false;

  function show(v: PageView): void {
    current = v;
    onChange(v);
  }

  function message(code: MessageCode): Message {
    return { code, text: MESSAGES[code] };
  }

  function copy(fs: readonly LessonFile[]): LessonFile[] {
    return fs.map((f) => ({ path: f.path, text: f.text }));
  }

  function signedIn(state: 'signed_in' | 'running', running: Action | null, output: Output | null, msg: Message | null): PageView {
    return { state, lesson: lesson.id, login, files: copy(files as LessonFile[]), actions, running, output, message: msg };
  }

  function signedOut(kept: readonly LessonFile[] | null, msg: Message | null): PageView {
    grant = null;
    return { state: 'signed_out', lesson: lesson.id, sign_in: signIn, files: kept === null ? null : copy(kept), message: msg };
  }

  /** The held grant, or a new one when none is held, it ends within RENEW_BEFORE_MS, or `fresh` asks for one. */
  async function sandbox(fresh: boolean): Promise<SandboxGrant | { error: GateErrorCode }> {
    if (!fresh && grant !== null && now() < Date.parse(grant.expires_at) - RENEW_BEFORE_MS) return grant;
    grant = null;
    let a = await gate.sandbox();
    if ('error' in a && a.error === 'csrf_failed') {
      // Another tab may have signed in again: the session's new CSRF value, and one more try.
      const s = await gate.session();
      if ('error' in s) return s;
      if (!s.signed_in) return { error: 'session_required' };
      a = await gate.sandbox();
    }
    if ('error' in a) return a;
    grant = a;
    return a;
  }

  async function attempt(sent: readonly LessonFile[], command: string, fresh: boolean): Promise<Attempt> {
    const g = await sandbox(fresh);
    if ('error' in g) return g;
    return runner.run(g, sent, command);
  }

  return {
    view: () => current,

    async load() {
      if (busy) return;
      busy = true;
      saveDraft(storage, lesson.id, null);
      const s = await gate.session();
      busy = false;
      if ('error' in s) {
        show({ state: 'unavailable', lesson: lesson.id, message: message(s.error) });
      } else if (!s.signed_in) {
        show(signedOut(null, null));
      } else {
        login = s.login;
        // Files the editor already holds (the session ended and came back) win over the draft.
        files ??= draftFiles(storage, lesson);
        show(signedIn('signed_in', null, null, null));
      }
    },

    edit(path, text) {
      const i = lesson.files.findIndex((f) => f.path === path);
      if (i < 0) throw new Error(`edit: '${path}' is not an editable file of the lesson`);
      const v = current;
      // The editor shows when signed in, and stays when the session ended while the page was in use.
      if (files === null || v.state === 'loading' || v.state === 'unavailable' || (v.state === 'signed_out' && v.files === null)) return;
      files[i] = { path, text };
      saveDraft(storage, lesson.id, files);
      show({ ...v, files: copy(files) });
    },

    async run(action) {
      const command = lesson.actions[action];
      const v = current;
      if (busy || v.state !== 'signed_in' || command === undefined) return;
      busy = true;
      const sent = copy(v.files);
      show(signedIn('running', action, null, null));
      let a: Attempt;
      try {
        a = await attempt(sent, command, false);
        // The sandbox is gone: a new one, and the same run once more.
        if ('kind' in a) a = await attempt(sent, command, true);
      } catch {
        a = { error: 'run_failed' };
      } finally {
        busy = false;
      }
      if ('kind' in a) {
        grant = null;
        show(signedIn('signed_in', null, null, message('tutorial_unavailable')));
      } else if ('error' in a) {
        if (a.error === 'session_required') show(signedOut(files, message('session_required')));
        else show(signedIn('signed_in', null, null, message(a.error)));
      } else {
        const output: Output = {
          action,
          exit_code: a.exit_code,
          stdout: visible(a.stdout),
          stderr: visible(a.stderr),
          exit_note: exitNote(a.exit_code),
        };
        show(signedIn('signed_in', null, output, null));
      }
    },

    async signOut() {
      const v = current;
      if (busy || v.state !== 'signed_in') return;
      busy = true;
      const r = await gate.signOut();
      busy = false;
      if ('error' in r) {
        show(signedIn('signed_in', null, v.output, message(r.error)));
        return;
      }
      files = null;
      show(signedOut(null, null));
    },
  };
}
