// The tutorial page's real script, src/tutorial/main.ts (the entry of tutorial.js), run under Node against a small DOM
// (test/mini-dom.ts) holding a lesson page's prerendered mount point, with a `fetch` that replays the contract's
// recorded answers and a fake in place of the e2b runner: no network, no SDK. Each test loads the module afresh, as a
// page load does, then types and clicks through DOM events. What each test proves is its name; the defect it catches
// is beside it.
import { browserDoc, h } from '../src/doc';
import type { RecordedAnswer } from '../src/tutorial/gate';
import { DRAFT_KEY, type LessonFile, type Runner, type RunResult } from '../src/tutorial/page';
import { CONTROL, editorId, lessonSource, RUNNER_ID } from '../src/tutorial/view';
import { dispatch, MiniButton, MiniDocument, type MiniElement, miniGlobals, MiniTextArea } from './mini-dom';
import { GRANT, GRANT_ANSWER, LESSON, MAIN, SIGNED_IN, SIGNED_OUT } from './page-fakes';

// The runner main.ts builds (e2bRunner) is this test's: each test sets mockRunner.
let mockRunner: Runner & { lessons: string[] } = { lessons: [], run: async () => ({ exit_code: 0, stdout: '', stderr: '' }) };
jest.mock('../src/tutorial/runner', () => ({
  e2bRunner: (lesson: string) => {
    mockRunner.lessons.push(lesson);
    return mockRunner;
  },
}));

const EDITED = 'fn main():\n    print("edited")\n';

/** Lets the replayed answers and the runner's promises settle (no clock involved). */
async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
}

function recordingRunner(...results: RunResult[]): Runner & { lessons: string[]; calls: { files: LessonFile[]; command: string; token: string }[] } {
  const r = {
    lessons: [] as string[],
    calls: [] as { files: LessonFile[]; command: string; token: string }[],
    async run(grant: { access_token: string }, files: readonly LessonFile[], command: string): Promise<RunResult> {
      r.calls.push({ files: files.map((f) => ({ ...f })), command, token: grant.access_token });
      return results[Math.min(r.calls.length - 1, results.length - 1)];
    },
  };
  return r;
}

function heldRunner(): Runner & { lessons: string[]; calls: number; finish(x: RunResult): void } {
  let resolve: (x: RunResult) => void = () => undefined;
  const r = {
    lessons: [] as string[],
    calls: 0,
    run(): Promise<RunResult> {
      r.calls += 1;
      return new Promise<RunResult>((res) => {
        resolve = res;
      });
    },
    finish: (x: RunResult) => resolve(x),
  };
  return r;
}

const SAVED = ['document', 'Node', 'Element', 'HTMLElement', 'HTMLTextAreaElement', 'fetch', 'localStorage'];
let saved: [string, PropertyDescriptor | undefined][] = [];
beforeEach(() => {
  saved = SAVED.map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)]);
});
afterEach(() => {
  for (const [k, d] of saved) {
    if (d === undefined) delete (globalThis as Record<string, unknown>)[k];
    else Object.defineProperty(globalThis, k, d);
  }
});

interface Loaded {
  doc: MiniDocument;
  mount: MiniElement;
  requests: { method: string; url: string; credentials: string | undefined; mode: string | undefined }[];
  items: Map<string, string>;
  byId(id: string): MiniElement | null;
  /** The mount point's <pre> texts. */
  pres(): string[];
  textareas(): MiniTextArea[];
}

/**
 * Installs a document holding a lesson page (an article and the prerendered #lesson-runner, unless `mount` is false),
 * a replaying fetch, and a localStorage (`storage` 'throws' makes reading it throw, as a blocked one does), then loads
 * main.ts.
 */
function load(answers: Record<string, RecordedAnswer[]>, o: { storage?: 'memory' | 'throws'; mount?: boolean } = {}): Loaded {
  const doc = new MiniDocument();
  const requests: Loaded['requests'] = [];
  const next = new Map<string, number>();
  const fetchFn = async (url: string, init: RequestInit): Promise<Response> => {
    const key = `${String(init.method)} ${url}`;
    requests.push({ method: String(init.method), url, credentials: init.credentials, mode: init.mode });
    const list = answers[key];
    if (list === undefined) return new Response('no recorded answer', { status: 501 });
    const i = next.get(key) ?? 0;
    next.set(key, i + 1);
    const a = list[Math.min(i, list.length - 1)];
    return new Response(a.body === undefined ? null : JSON.stringify(a.body), { status: a.status, headers: a.headers });
  };
  const items = new Map<string, string>();
  const storage = { getItem: (k: string) => items.get(k) ?? null, setItem: (k: string, v: string) => void items.set(k, v) };
  for (const [k, v] of Object.entries({ ...miniGlobals(doc), fetch: fetchFn })) Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    get: () => {
      if (o.storage === 'throws') throw new DOMException('The operation is insecure.', 'SecurityError');
      return storage;
    },
  });
  const article = h(browserDoc, 'article', { class: 'prose lesson' }, h(browserDoc, 'p', null, 'Press Run.'));
  const mount = h(browserDoc, 'section', { id: RUNNER_ID, class: 'lesson-runner', 'data-lesson': LESSON.id }, ...lessonSource(browserDoc, LESSON));
  const main = h(browserDoc, 'main', { id: 'main' }, article, o.mount === false ? null : mount);
  (doc.body as unknown as Node).appendChild(main);
  jest.isolateModules(() => {
    require('../src/tutorial/main');
  });
  const m = mount as unknown as MiniElement;
  const all = (tag: string): MiniElement[] => {
    const out: MiniElement[] = [];
    const walk = (e: MiniElement): void => {
      for (const c of e.childNodes) {
        if (!('tagName' in c)) continue;
        const el = c as MiniElement;
        if (el.tagName === tag) out.push(el);
        walk(el);
      }
    };
    walk(m);
    return out;
  };
  return {
    doc,
    mount: m,
    requests,
    items,
    byId: (id) => doc.getElementById(id),
    pres: () => all('PRE').map((p) => p.textContent),
    textareas: () => all('TEXTAREA') as MiniTextArea[],
  };
}

/** The reader types `text` into the editor `id`: its value changes and an input event bubbles from it. */
function type(l: Loaded, id: string, text: string): void {
  const t = l.byId(id) as MiniTextArea;
  t.focus();
  t.value = text;
  dispatch('input', t);
}

/** The reader clicks the button `id`: it takes focus and a click event bubbles from it. */
function click(l: Loaded, id: string): void {
  const b = l.byId(id) as MiniElement;
  b.focus();
  dispatch('click', b);
}

// Defect caught: the entry wiring the controller to the wrong events, the wrong element, a gate that does not send the
// session cookie, a runner of another lesson, or a view that never reaches the document.
test('signed in: typing and Run through DOM events send the edited files to the runner, and its output appears in the page', async () => {
  const runner = recordingRunner({ exit_code: 0, stdout: 'Hello, edited\n', stderr: '' });
  mockRunner = runner;
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] });
  await settle();
  expect(l.textareas().map((t) => [t.id, t.value])).toEqual([[editorId(0), MAIN]]);
  type(l, editorId(0), EDITED);
  click(l, CONTROL.run);
  await settle();
  expect(runner.lessons).toEqual(['hello']);
  expect(runner.calls).toEqual([{ files: [{ path: 'src/main.mojo', text: EDITED }], command: 'mopm run src/main.mojo', token: GRANT.access_token }]);
  expect(l.pres()).toEqual(['Hello, edited\n']);
  expect(l.mount.textContent).toContain('The program exited with code 0.');
  // Every call of the real gate is same-origin, with the session cookie.
  expect(l.requests.map((r) => [r.method, r.url, r.mode, r.credentials])).toEqual([
    ['GET', '/api/v2/auth/web/session', 'same-origin', 'same-origin'],
    ['POST', '/api/v2/tutorial/sandbox', 'same-origin', 'same-origin'],
  ]);
  // The editor rebuilt after the run holds the edited text, and focus is back on Run.
  expect(l.textareas().map((t) => t.value)).toEqual([EDITED]);
  expect(l.doc.activeElement.id).toBe(CONTROL.run);
});

// Defect caught: the sandbox grant persisted in localStorage by the page script.
test("localStorage holds the draft only: the draft key, the edited text, and no field of the grant", async () => {
  mockRunner = recordingRunner({ exit_code: 0, stdout: 'ok\n', stderr: '' });
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] });
  await settle();
  type(l, editorId(0), EDITED);
  click(l, CONTROL.run);
  await settle();
  expect([...l.items.keys()]).toEqual([DRAFT_KEY]);
  expect(JSON.parse(l.items.get(DRAFT_KEY) as string)).toEqual({ last_lesson: 'hello', files: { hello: { 'src/main.mojo': EDITED } } });
  for (const v of Object.values(GRANT)) expect(l.items.get(DRAFT_KEY)).not.toContain(v);
});

test("signed out: the sign-in link back to this lesson, and no textarea", async () => {
  mockRunner = recordingRunner({ exit_code: 0, stdout: '', stderr: '' });
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_OUT] });
  await settle();
  expect(l.textareas()).toEqual([]);
  const links = l.mount.getElementsByClassName('button-primary');
  expect(links.map((a) => [a.tagName, a.getAttribute('href')])).toEqual([['A', '/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello']]);
});

// Defect caught: a click on a disabled button, on no button, or on a button the page did not make, starting a run.
test('a disabled Run, a click beside the buttons, a button without an id and input from no editor reach nothing', async () => {
  const runner = heldRunner();
  mockRunner = runner;
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] });
  await settle();
  click(l, CONTROL.run);
  await settle();
  const run = l.byId(CONTROL.run) as MiniButton;
  expect(run.disabled).toBe(true);
  dispatch('click', run);
  // A click whose target is a text node (not an Element), and one on the mount point itself (no button).
  dispatch('click', run.childNodes[0]);
  dispatch('click', l.mount);
  // A button inside the mount point with no id, and input from an element that is no textarea, or a textarea with none.
  const stray = l.doc.createElement('button');
  l.mount.appendChild(stray);
  dispatch('click', stray);
  const area = l.doc.createElement('textarea') as MiniTextArea;
  l.mount.appendChild(area);
  area.value = 'x';
  dispatch('input', area);
  dispatch('input', stray);
  await settle();
  expect(runner.calls).toBe(1);
  expect(l.items.get(DRAFT_KEY)).toBe('{"last_lesson":"hello"}');
  runner.finish({ exit_code: 0, stdout: 'done\n', stderr: '' });
  await settle();
  expect(l.pres()).toEqual(['done\n']);
  expect(runner.calls).toBe(1);
});

test('a click inside the mount point whose nearest button is outside it is not forwarded', async () => {
  const runner = heldRunner();
  mockRunner = runner;
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] });
  await settle();
  // Move the mount point into a button with Run's id: closest('button') from inside the mount finds that button.
  const outer = l.doc.createElement('button');
  outer.setAttribute('id', CONTROL.run);
  l.doc.body.appendChild(outer);
  outer.appendChild(l.mount);
  dispatch('click', l.textareas()[0]);
  await settle();
  expect(runner.calls).toBe(0);
});

// Defect caught: a blocked localStorage (reading it throws) stopping the page script.
test('a localStorage that throws when read does not stop the page: it signs in, takes input and runs', async () => {
  const runner = recordingRunner({ exit_code: 0, stdout: 'ok\n', stderr: '' });
  mockRunner = runner;
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] }, { storage: 'throws' });
  await settle();
  type(l, editorId(0), EDITED);
  click(l, CONTROL.run);
  await settle();
  expect(runner.calls.map((c) => c.files)).toEqual([[{ path: 'src/main.mojo', text: EDITED }]]);
  expect(l.pres()).toEqual(['ok\n']);
});

test('focus the reader moved out of the mount point stays there when the run ends', async () => {
  const runner = heldRunner();
  mockRunner = runner;
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN], [`POST /api/v2/tutorial/sandbox`]: [GRANT_ANSWER] });
  await settle();
  click(l, CONTROL.run);
  await settle();
  const elsewhere = l.doc.createElement('a');
  elsewhere.setAttribute('id', 'elsewhere');
  l.doc.body.appendChild(elsewhere);
  elsewhere.focus();
  runner.finish({ exit_code: 0, stdout: '', stderr: '' });
  await settle();
  expect(l.doc.activeElement).toBe(elsewhere);
  // An element with no id focused inside the mount point is no control to come back to: after the render that removes
  // it, focus is on the body, not on a control.
  const plain = l.doc.createElement('p');
  l.mount.appendChild(plain);
  plain.focus();
  dispatch('click', l.byId(CONTROL.run) as MiniElement);
  await settle();
  expect(runner.calls).toBe(2);
  expect(l.doc.activeElement).toBe(l.doc.body);
});

test('a page without the mount point: the script does nothing and asks nothing', async () => {
  mockRunner = recordingRunner({ exit_code: 0, stdout: '', stderr: '' });
  const l = load({ [`GET /api/v2/auth/web/session`]: [SIGNED_IN] }, { mount: false });
  await settle();
  expect(l.requests).toEqual([]);
  expect(mockRunner.lessons).toEqual([]);
});

test('the mini DOM: a textarea reads its text until typed into, and the active element is the body once removed', () => {
  const doc = new MiniDocument();
  const t = doc.createElement('textarea') as MiniTextArea;
  t.appendChild(doc.createTextNode('abc'));
  expect(t.value).toBe('abc');
  t.value = 'typed';
  expect(t.value).toBe('typed');
  doc.body.appendChild(t);
  t.focus();
  expect(doc.activeElement).toBe(t);
  doc.body.replaceChildren();
  expect(doc.activeElement).toBe(doc.body);
});
