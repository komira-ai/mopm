// The tutorial page in its mount point (src/tutorial/start.ts and view.ts) over a fake DOM (test/tutorial-dom.ts), the
// replaying gate (the contract examples), a fake runner and a recording storage: no network, no SDK. What each test
// proves is its name; the defect each catches is beside it.
import { type SElement, serialize } from '../src/doc';
import { internalHref } from '../src/links';
import { type SandboxGrant, signInHref } from '../src/tutorial/gate';
import { DRAFT_KEY, type Lesson, MESSAGES, type MessageCode, type PageView, type Runner } from '../src/tutorial/page';
import { lazyStorage, onlyFilesDiffer, startTutorial, type TutorialDeps } from '../src/tutorial/start';
import { CONTROL, editorId } from '../src/tutorial/view';
import {
  CSRF_FAILED, GRANT, GRANT_ANSWER, HTML_504, INVALID, LESSON, LESSON_WITH_TEST, LOGIN, MAIN, OK, SANDBOX_SESSION_REQUIRED,
  SIGNED_IN, SIGNED_OUT, UNAVAILABLE, fakeRunner, heldRunner, memoryStorage,
} from './page-fakes';
import { type ReplayScript, replayGate } from '../src/tutorial/gate';
import { lessonPageDom, type Page, tags } from './tutorial-dom';
import { text } from './view-helpers';

const EDITED = 'fn main():\n    print("edited")\n';

/** Lets the replaying gate's answers and the fake runner's promises settle (no clock involved). */
async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
}

interface Started extends Page {
  gate: ReturnType<typeof replayGate>;
  runnerFor: string[];
  html(): string;
  /** The mount point's text, tags removed. */
  shown(): string;
  textareas(): SElement[];
  button(id: string): SElement | null;
}

function start(script: ReplayScript, o: { lesson?: Lesson; runner?: Runner; storage?: TutorialDeps['storage']; now?: number } = {}): Started {
  const lesson = o.lesson ?? LESSON;
  const p = lessonPageDom(lesson);
  const gate = replayGate(script);
  const runnerFor: string[] = [];
  const runner = o.runner ?? fakeRunner(OK);
  const page = startTutorial(p.dom, p.mount, {
    gate,
    runner: (id) => {
      runnerFor.push(id);
      return runner;
    },
    storage: o.storage ?? memoryStorage(),
    now: () => o.now ?? Date.parse(GRANT.expires_at) - 20 * 60_000,
  });
  expect(page).not.toBeNull();
  return {
    ...p,
    gate,
    runnerFor,
    html: () => serialize(p.mount),
    shown: () => text(serialize(p.mount)),
    textareas: () => tags(p.dom, p.mount, 'textarea'),
    button: (id) => {
      const b = p.dom.byId(p.mount, id);
      return b !== null && b.tag === 'button' ? b : null;
    },
  };
}

const editorText = (s: Started, i: number): string => s.dom.textOf(s.dom.byId(s.mount, editorId(i)) as SElement);
const disabled = (b: SElement | null): boolean => b !== null && b.attrs.some(([k]) => k === 'disabled');

describe('signed out', () => {
  // Defect caught: a page that shows the editor (or asks for a sandbox) without a session; a sign-in link that returns
  // somewhere other than this lesson; a script that drops the lesson's text.
  test("shows the lesson's text, its files read-only and the sign-in link back to this lesson; no textarea", async () => {
    const s = start({ getWebSession: [SIGNED_OUT] });
    await settle();
    expect(s.main.children).toContain(s.article);
    expect(s.dom.textOf(s.article)).toBe('Press Run: mopm builds the program and runs it.');
    expect(s.textareas()).toEqual([]);
    const links = tags(s.dom, s.mount, 'a');
    expect(links.map((a) => s.dom.attr(a, 'href'))).toEqual(['/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello']);
    expect(s.dom.textOf(links[0])).toBe('Sign in with GitHub');
    expect(s.shown()).toContain('Sign in with GitHub to edit this lesson and run it in a sandbox.');
    expect(s.html()).toContain(`<pre class="lesson-text"><code>${MAIN}</code></pre>`);
    expect(s.button(CONTROL.run)).toBeNull();
    expect(s.gate.requests.map((r) => r.url)).toEqual(['/api/v2/auth/web/session']);
    expect(s.runnerFor).toEqual(['hello']);
  });

  test("another lesson's page returns to that lesson", async () => {
    const lesson: Lesson = { ...LESSON, id: 'second-steps' };
    const s = start({ getWebSession: [SIGNED_OUT] }, { lesson });
    await settle();
    expect(tags(s.dom, s.mount, 'a').map((a) => s.dom.attr(a, 'href'))).toEqual([signInHref('/tutorial/second-steps')]);
    expect(s.runnerFor).toEqual(['second-steps']);
  });

  test('before the session answers: a status line and the read-only files', () => {
    const s = start({ getWebSession: [SIGNED_OUT] });
    expect(s.shown()).toContain('Checking whether you are signed in…');
    expect(s.html()).toContain('role="status"');
    expect(s.textareas()).toEqual([]);
  });
});

describe('signed in', () => {
  // Defect caught: the editor filled from the lesson when the browser holds a draft, or the draft of one file applied
  // to another; the login missing.
  test("shows the login and one textarea per editable file, holding the draft over the lesson's text", async () => {
    const draft = { last_lesson: 'testing', files: { testing: { 'src/lib.mojo': EDITED } } };
    const s = start({ getWebSession: [SIGNED_IN] }, { lesson: LESSON_WITH_TEST, storage: memoryStorage({ [DRAFT_KEY]: JSON.stringify(draft) }) });
    await settle();
    expect(s.shown()).toContain(`Signed in as ${LOGIN}.`);
    expect(s.textareas().map((t) => [s.dom.attr(t, 'id'), s.dom.attr(t, 'name'), s.dom.textOf(t)])).toEqual([
      ['lesson-file-0', 'src/lib.mojo', EDITED],
      ['lesson-file-1', 'test/test_lib.mojo', LESSON_WITH_TEST.files[1].text],
    ]);
    // Each editor is labelled with its path.
    expect(s.html()).toContain('<label for="lesson-file-0"><code>src/lib.mojo</code></label>');
    expect(tags(s.dom, s.mount, 'a')).toEqual([]);
    expect([s.button(CONTROL.run), s.button(CONTROL.test), s.button(CONTROL.signOut)].map((b) => b !== null && !disabled(b))).toEqual([true, true, true]);
  });

  test('a lesson with no test action has Run and no Test', async () => {
    const s = start({ getWebSession: [SIGNED_IN] });
    await settle();
    expect(s.button(CONTROL.run)).not.toBeNull();
    expect(s.button(CONTROL.test)).toBeNull();
  });

  test('typing goes to the controller and the draft, and does not rebuild the editor (the caret stays)', async () => {
    const storage = memoryStorage();
    const s = start({ getWebSession: [SIGNED_IN] }, { storage });
    await settle();
    const editor = s.textareas()[0];
    const renders = s.dom.renders;
    s.dom.type(editorId(0), EDITED);
    expect(s.dom.renders).toBe(renders);
    expect(s.textareas()[0]).toBe(editor);
    expect(s.dom.focused).toBe(editor);
    expect(JSON.parse(storage.items.get(DRAFT_KEY) as string)).toEqual({ last_lesson: 'hello', files: { hello: { 'src/main.mojo': EDITED } } });
  });

  test('input from an element that is no editor of the lesson is ignored', async () => {
    const storage = memoryStorage();
    const s = start({ getWebSession: [SIGNED_IN] }, { storage });
    await settle();
    const writes = storage.writes.length;
    for (const id of ['lesson-file-1', 'lesson-file-01', 'q', 'lesson-file-']) s.dom.input(id, 'x');
    expect(storage.writes.length).toBe(writes);
    expect(editorText(s, 0)).toBe(MAIN);
  });

  test('Run sends the edited files and the lesson command; the output, its exit code, and Run enabled again', async () => {
    const runner = fakeRunner({ exit_code: 0, stdout: 'Hello, edited\n', stderr: '' });
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    expect(runner.calls).toEqual([{ grant: GRANT, files: [{ path: 'src/main.mojo', text: EDITED }], command: 'mopm run src/main.mojo' }]);
    expect(s.shown()).toContain('The program exited with code 0.');
    expect(tags(s.dom, s.mount, 'pre').map((p) => s.dom.textOf(p))).toEqual(['Hello, edited\n']);
    expect(disabled(s.button(CONTROL.run))).toBe(false);
    // The editor holds the edited text after the render that showed the output.
    expect(editorText(s, 0)).toBe(EDITED);
  });

  test('Test runs the test command', async () => {
    const runner = fakeRunner(OK);
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { lesson: LESSON_WITH_TEST, runner });
    await settle();
    s.dom.click(CONTROL.test);
    expect(s.shown()).toContain('Testing…');
    await settle();
    expect(runner.calls.map((c) => c.command)).toEqual(['mopm test']);
  });

  test('a non-zero exit shows its code with the output; nothing printed says so', async () => {
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner: fakeRunner({ exit_code: 3, stdout: '', stderr: 'error: x\n' }, { exit_code: 1, stdout: '', stderr: '' }) });
    await settle();
    s.dom.click(CONTROL.run);
    await settle();
    expect(s.shown()).toContain('The program exited with code 3.');
    expect(tags(s.dom, s.mount, 'pre').map((p) => s.dom.textOf(p))).toEqual(['error: x\n']);
    s.dom.click(CONTROL.run);
    await settle();
    expect(s.shown()).toContain('The program exited with code 1.');
    expect(s.shown()).toContain('The program printed nothing.');
    expect(tags(s.dom, s.mount, 'pre')).toEqual([]);
  });

  test('Sign out: the sign-in link, no editor', async () => {
    const s = start({ getWebSession: [SIGNED_IN], webLogout: [{ status: 204 }] });
    await settle();
    s.dom.click(CONTROL.signOut);
    await settle();
    expect(s.textareas()).toEqual([]);
    expect(tags(s.dom, s.mount, 'a').map((a) => s.dom.attr(a, 'href'))).toEqual(['/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello']);
  });
});

describe('one run at a time', () => {
  // Defect caught: a double click (or a click on a button the page has not disabled yet) starting a second sandbox run.
  test('Run twice quickly starts one run; Run, Test and Sign out are disabled while it runs', async () => {
    const runner = heldRunner();
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { lesson: LESSON_WITH_TEST, runner });
    await settle();
    s.dom.click(CONTROL.run);
    s.dom.click(CONTROL.run);
    s.dom.click(CONTROL.test);
    expect([CONTROL.run, CONTROL.test, CONTROL.signOut].map((id) => disabled(s.button(id)))).toEqual([true, true, true]);
    expect(s.shown()).toContain('Running…');
    await settle();
    // The click events themselves, past the disabled buttons: the controller still starts no second run.
    s.dom.press(CONTROL.run);
    s.dom.press(CONTROL.test);
    await settle();
    expect(runner.calls).toBe(1);
    runner.finish(OK);
    await settle();
    expect([CONTROL.run, CONTROL.test, CONTROL.signOut].map((id) => disabled(s.button(id)))).toEqual([false, false, false]);
    expect(runner.calls).toBe(1);
  });

  test('focus on Run comes back to it when the run ends; focus the reader moved elsewhere stays there', async () => {
    const runner = heldRunner();
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await settle();
    s.dom.click(CONTROL.run);
    await settle();
    runner.finish(OK);
    await settle();
    expect(s.dom.focused).toBe(s.button(CONTROL.run));

    s.dom.click(CONTROL.run);
    await settle();
    s.dom.focused = s.outside;
    runner.finish(OK);
    await settle();
    expect(s.dom.focused).toBe(s.outside);
  });

  test('focus in an editor stays in the editor of the same file across a render', async () => {
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] });
    await settle();
    s.dom.type(editorId(0), EDITED);
    // A run started from the keyboard elsewhere (the page's own call): the editor is rebuilt and keeps focus.
    s.dom.press(CONTROL.run);
    await settle();
    expect(s.dom.focused).toBe(s.dom.byId(s.mount, editorId(0)));
  });
});

describe("each code of the endpoint's table renders its message", () => {
  // Every row names its runner: jest reads a parameter past a row's length as a `done` callback.
  const codes: [MessageCode, ReplayScript, Runner][] = [
    ['csrf_failed', { getWebSession: [SIGNED_IN], createTutorialSandbox: [CSRF_FAILED] }, fakeRunner(OK)],
    ['invalid_request', { getWebSession: [SIGNED_IN], createTutorialSandbox: [INVALID] }, fakeRunner(OK)],
    ['tutorial_unavailable', { getWebSession: [SIGNED_IN], createTutorialSandbox: [UNAVAILABLE] }, fakeRunner(OK)],
    ['tutorial_unavailable', { getWebSession: [SIGNED_IN], createTutorialSandbox: [HTML_504] }, fakeRunner(OK)],
    ['run_failed', { getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, fakeRunner(new Error('agent refused the token'))],
  ];
  // Defect caught: a code shown as another's sentence, or not at all, or the editor lost with it.
  test.each(codes)('%s after Run: its sentence as an alert, and the editor keeps the edited text', async (code, script, runner) => {
    const s = start(script, { runner });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    expect(s.html()).toContain(`<p class="notice notice-error lesson-message" role="alert">${MESSAGES[code]}</p>`);
    expect(editorText(s, 0)).toBe(EDITED);
  });

  // Defect caught: the session's end throwing away what the reader typed.
  test('session_required after Run: signed out with the sign-in link and its message, and the edited text kept in the editor', async () => {
    const storage = memoryStorage();
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [SANDBOX_SESSION_REQUIRED] }, { storage });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    expect(s.html()).toContain(`<p class="notice notice-error lesson-message" role="alert">${MESSAGES.session_required}</p>`);
    expect(tags(s.dom, s.mount, 'a').map((a) => s.dom.attr(a, 'href'))).toEqual([signInHref('/tutorial/hello')]);
    expect(s.textareas().map((t) => s.dom.textOf(t))).toEqual([EDITED]);
    expect(s.button(CONTROL.run)).toBeNull();
    // Typing still reaches the draft while signed out.
    s.dom.type(editorId(0), `${EDITED}# more\n`);
    expect(JSON.parse(storage.items.get(DRAFT_KEY) as string).files.hello).toEqual({ 'src/main.mojo': `${EDITED}# more\n` });
  });

  test.each([
    ['tutorial_unavailable', HTML_504],
    ['invalid_request', { status: 400, body: { error: { code: 'invalid_request', message: 'x' } } }],
  ] as const)('the session unreadable (%s): its message and Try again, which asks again', async (code, first) => {
    const s = start({ getWebSession: [first, SIGNED_IN] });
    await settle();
    expect(s.html()).toContain(`<p class="notice notice-error lesson-message" role="alert">${MESSAGES[code]}</p>`);
    expect(s.textareas()).toEqual([]);
    s.dom.click(CONTROL.retry);
    await settle();
    expect(s.textareas()).toHaveLength(1);
  });
});

describe('hostile output', () => {
  const HOSTILE = '\u001b[31mred\u001b[0m ‮evil⁦ <script>alert(1)</script><img src=x onerror=alert(1)>&amp;\u0000\n';
  // Defect caught: output put on the page as markup (an element made of what the program printed), or with a control
  // or bidi character left to hide or reorder the text around it.
  test('control, bidi and markup in stdout and stderr appear as visible markers and text, never as nodes', async () => {
    const s = start(
      { getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] },
      { runner: fakeRunner({ exit_code: 0, stdout: HOSTILE, stderr: `err ${HOSTILE}` }) },
    );
    await settle();
    s.dom.click(CONTROL.run);
    await settle();
    const [pre] = tags(s.dom, s.mount, 'pre');
    const marked = '[U+001B][31mred[U+001B][0m [U+202E]evil[U+2066] <script>alert(1)</script><img src=x onerror=alert(1)>&amp;[U+0000]\n';
    // Exactly two text nodes, stdout then stderr: no element was made of the output.
    expect(pre.children).toEqual([{ text: marked }, { text: `err ${marked}` }]);
    // Nowhere in the mount point is there an element the page does not build itself.
    expect(new Set(s.dom.all(s.mount).map((e) => e.tag))).toEqual(new Set(['section', 'p', 'strong', 'button', 'div', 'label', 'code', 'textarea', 'pre']));
    expect(s.html()).toContain('&lt;script&gt;alert(1)&lt;/script&gt;&lt;img src=x onerror=alert(1)&gt;&amp;amp;');
    expect(s.html()).not.toMatch(/[\u0000-\u0008\u000b-\u001f\u007f‪-‮⁦-⁩]/);
  });
});

describe('storage', () => {
  // Defect caught: a blocked localStorage (a throwing getter, as in some private windows) stopping the page script.
  test('a localStorage that throws on every access does not stop the page: it signs in, edits and runs', async () => {
    const storage = lazyStorage(() => {
      throw new DOMException('The operation is insecure.', 'SecurityError');
    });
    const runner = fakeRunner(OK);
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { storage, runner });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    expect(runner.calls.map((c) => c.files)).toEqual([[{ path: 'src/main.mojo', text: EDITED }]]);
    expect(s.shown()).toContain('Hello, world');
  });

  test('a storage whose calls throw (full, or blocked) does not stop the page either', async () => {
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { storage: memoryStorage({}, true) });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    expect(s.shown()).toContain('The program exited with code 0.');
  });

  // Defect caught: the sandbox grant (its access token) persisted where another script or a later reader of the
  // machine's profile could take it.
  test('the grant is never written: after sign-in, edits and two runs, nothing stored holds a field of it', async () => {
    const items = new Map<string, string>();
    const writes: string[] = [];
    const real = {
      getItem: (k: string) => items.get(k) ?? null,
      setItem: (k: string, v: string) => {
        writes.push(`${k}=${v}`);
        items.set(k, v);
      },
    };
    const s = start({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { storage: lazyStorage(() => real) });
    await settle();
    s.dom.type(editorId(0), EDITED);
    s.dom.click(CONTROL.run);
    await settle();
    s.dom.click(CONTROL.run);
    await settle();
    expect(writes.length).toBeGreaterThan(0);
    expect([...items.keys()]).toEqual([DRAFT_KEY]);
    const grant: SandboxGrant = GRANT;
    for (const w of writes) for (const v of [grant.access_token, grant.sandbox_id, grant.envd_version, grant.domain, grant.expires_at]) expect(w).not.toContain(v);
    expect(JSON.parse(items.get(DRAFT_KEY) as string)).toEqual({ last_lesson: 'hello', files: { hello: { 'src/main.mojo': EDITED } } });
  });
});

describe('a page with no lesson in its mount point', () => {
  test.each<[string, (p: Page) => void]>([
    ['no data-lesson', (p) => (p.mount.attrs = p.mount.attrs.filter(([k]) => k !== 'data-lesson'))],
    ['a data-lesson outside the grammar', (p) => (p.mount.attrs = p.mount.attrs.map(([k, v]) => [k, k === 'data-lesson' ? '../x' : v]))],
    ['no file', (p) => (p.mount.children = p.mount.children.slice(1))],
  ])('%s: nothing starts and the page is left as it is', (_name, spoil) => {
    const p = lessonPageDom(LESSON);
    spoil(p);
    const before = serialize(p.main);
    let asked = 0;
    const page = startTutorial(p.dom, p.mount, {
      gate: replayGate({}),
      runner: () => {
        asked++;
        return fakeRunner(OK);
      },
      storage: memoryStorage(),
      now: () => 0,
    });
    expect(page).toBeNull();
    expect(asked).toBe(0);
    expect(serialize(p.main)).toBe(before);
  });
});

describe('lazyStorage', () => {
  test('looks the storage up on each call, so a lookup that throws throws from that call only', () => {
    let blocked = true;
    const items = new Map<string, string>();
    const st = lazyStorage(() => {
      if (blocked) throw new DOMException('blocked', 'SecurityError');
      return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => void items.set(k, v) };
    });
    expect(() => st.getItem('k')).toThrow('blocked');
    expect(() => st.setItem('k', 'v')).toThrow('blocked');
    blocked = false;
    st.setItem('k', 'v');
    expect(st.getItem('k')).toBe('v');
  });
});

describe('onlyFilesDiffer', () => {
  const base: PageView = { state: 'signed_in', lesson: 'hello', login: 'x', files: [], actions: ['run'], running: null, output: null, message: null };
  test('true when only the files differ; false for any other field, or a field more or less', () => {
    expect(onlyFilesDiffer(base, { ...base, files: [{ path: 'a', text: 'b' }] })).toBe(true);
    expect(onlyFilesDiffer(base, { ...base, state: 'running', running: 'run' })).toBe(false);
    expect(onlyFilesDiffer(base, { ...base, message: { code: 'csrf_failed', text: MESSAGES.csrf_failed } })).toBe(false);
    expect(onlyFilesDiffer(base, { state: 'loading', lesson: 'hello' })).toBe(false);
    expect(onlyFilesDiffer({ state: 'loading', lesson: 'hello' }, { state: 'loading', lesson: 'other' })).toBe(false);
    expect(onlyFilesDiffer({ state: 'loading', lesson: 'hello' }, { state: 'unavailable', lesson: 'hello', message: { code: 'csrf_failed', text: '' } })).toBe(false);
  });
});

test('the sign-in href is the gate\'s own SafeHref', () => {
  expect(signInHref('/tutorial/hello')).toBe(internalHref('/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello'));
});
