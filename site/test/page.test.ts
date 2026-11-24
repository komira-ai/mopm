// The tutorial page's controller (src/tutorial/page.ts) over the replaying gate, a fake runner and a manual clock:
// what each sign-in state shows, a run and its exit code, each code of the endpoint's error table as its message,
// the csrf_failed retry, replacing a sandbox that is gone or about to end, and one thing in flight at a time.
import { readFileSync } from 'fs';
import { join } from 'path';
import { SANDBOX_PATH, SESSION_PATH, LOGOUT_PATH } from '../src/tutorial/gate';
import { internalHref } from '../src/links';
import { MESSAGES, type PageView, RENEW_BEFORE_MS } from '../src/tutorial/page';
import {
  CSRF_FAILED, GRANT, GRANT_2, GRANT_2_ANSWER, GRANT_ANSWER, GRANT_END, HTML_504, INVALID, LESSON, LESSON_WITH_TEST, LOGIN,
  MAIN, OK, SANDBOX_SESSION_REQUIRED, SIGNED_IN, SIGNED_OUT, UNAVAILABLE, answer, fakeRunner, harness, heldRunner,
} from './page-fakes';

const GET_SESSION = `GET ${SESSION_PATH}`;
const POST_SANDBOX = `POST ${SANDBOX_PATH}`;
const POST_LOGOUT = `POST ${LOGOUT_PATH}`;
const SIGN_IN_HELLO = internalHref('/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello');
const EDITED = 'fn main():\n    print("edited")\n';

const signedInView = (over: Partial<Extract<PageView, { state: 'signed_in' | 'running' }>> = {}): PageView => ({
  state: 'signed_in',
  lesson: 'hello',
  login: LOGIN,
  files: [{ path: 'src/main.mojo', text: MAIN }],
  actions: ['run'],
  running: null,
  output: null,
  message: null,
  ...over,
});

const msg = (code: keyof typeof MESSAGES) => ({ code, text: MESSAGES[code] });

describe('the lesson', () => {
  test.each(['Hello', 'hello_world', '-hello', 'hello-', '../hello', ''])("an id that is not a lesson id ('%s') is refused", (id) => {
    expect(() => harness({}, { lesson: { ...LESSON, id } })).toThrow(`tutorialPage: '${id}' is not a lesson id`);
  });

  test('before load(): loading, and nothing asked', () => {
    const h = harness({ getWebSession: [SIGNED_IN] });
    expect(h.page.view()).toEqual({ state: 'loading', lesson: 'hello' });
    expect(h.requests()).toEqual([]);
  });
});

describe('signed out', () => {
  test("the lesson and the sign-in link back to the lesson's page; no editor, no sandbox asked", async () => {
    const h = harness({ getWebSession: [SIGNED_OUT] });
    await h.page.load();
    expect(h.page.view()).toEqual({ state: 'signed_out', lesson: 'hello', sign_in: SIGN_IN_HELLO, files: null, message: null });
    expect(h.views).toEqual([h.page.view()]);
    expect(h.requests()).toEqual([GET_SESSION]);
  });

  test('run, sign-out and edits do nothing: no request, no run, no draft of the files', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_OUT] }, { runner });
    await h.page.load();
    const before = h.page.view();
    await h.page.run('run');
    await h.page.signOut();
    h.page.edit('src/main.mojo', EDITED);
    expect(h.page.view()).toBe(before);
    expect(runner.calls).toEqual([]);
    expect(h.requests()).toEqual([GET_SESSION]);
    expect(h.storage.writes).toEqual([['mopm.tutorial.1', '{"last_lesson":"hello"}']]);
  });

  test('edit before load() does nothing', () => {
    const h = harness({ getWebSession: [SIGNED_IN] });
    h.page.edit('src/main.mojo', EDITED);
    expect(h.page.view()).toEqual({ state: 'loading', lesson: 'hello' });
    expect(h.storage.writes).toEqual([]);
  });
});

describe('the session cannot be read', () => {
  test.each([
    ['a 504 page', HTML_504, 'tutorial_unavailable'],
    ['invalid_request', answer('the session with an Authorization header is refused as invalid_request'), 'invalid_request'],
  ] as const)('%s: unavailable with its message, and load() again recovers', async (_, a, code) => {
    const h = harness({ getWebSession: [a, SIGNED_IN] });
    await h.page.load();
    expect(h.page.view()).toEqual({ state: 'unavailable', lesson: 'hello', message: msg(code) });
    await h.page.run('run');
    expect(h.requests()).toEqual([GET_SESSION]);
    await h.page.load();
    expect(h.page.view()).toEqual(signedInView());
  });
});

describe('signed in', () => {
  test("the login, the lesson's files and its one action", async () => {
    const h = harness({ getWebSession: [SIGNED_IN] });
    await h.page.load();
    expect(h.page.view()).toEqual(signedInView());
    expect(h.requests()).toEqual([GET_SESSION]);
  });

  test('a lesson with tests has both actions', async () => {
    const h = harness({ getWebSession: [SIGNED_IN] }, { lesson: LESSON_WITH_TEST });
    await h.page.load();
    const v = h.page.view();
    expect(v.state === 'signed_in' && v.actions).toEqual(['run', 'test']);
  });

  test('a view is a copy: changing it does not change the page', async () => {
    const h = harness({ getWebSession: [SIGNED_IN] });
    await h.page.load();
    const v = h.page.view() as Extract<PageView, { login: string }>;
    (v.files as { path: string; text: string }[])[0].text = 'changed';
    h.page.edit('src/main.mojo', EDITED);
    expect(h.page.view()).toEqual(signedInView({ files: [{ path: 'src/main.mojo', text: EDITED }] }));
    expect(h.views[0]).toEqual(signedInView({ files: [{ path: 'src/main.mojo', text: 'changed' }] }));
  });

  test('editing a path that is not an editable file of the lesson throws', async () => {
    const h = harness({ getWebSession: [SIGNED_IN] });
    await h.page.load();
    expect(() => h.page.edit('src/other.mojo', 'x')).toThrow("edit: 'src/other.mojo' is not an editable file of the lesson");
  });
});

describe('a run', () => {
  test('exit 0: running, then the output; the runner gets the grant, the edited files and the command', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await h.page.load();
    h.page.edit('src/main.mojo', EDITED);
    const done = h.page.run('run');
    expect(h.page.view()).toEqual(signedInView({ state: 'running', running: 'run', files: [{ path: 'src/main.mojo', text: EDITED }] }));
    await done;
    expect(runner.calls).toEqual([{ grant: GRANT, files: [{ path: 'src/main.mojo', text: EDITED }], command: 'mopm run src/main.mojo' }]);
    expect(h.page.view()).toEqual(
      signedInView({
        files: [{ path: 'src/main.mojo', text: EDITED }],
        output: { action: 'run', exit_code: 0, stdout: 'Hello, world\n', stderr: '', exit_note: null },
      }),
    );
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX]);
  });

  test.each([1, 2, 127, 255, -1])('exit %i: the output and the exit code, not a message', async (code) => {
    const h = harness(
      { getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] },
      { runner: fakeRunner({ exit_code: code, stdout: '', stderr: 'error: boom\n' }) },
    );
    await h.page.load();
    await h.page.run('run');
    expect(h.page.view()).toEqual(
      signedInView({ output: { action: 'run', exit_code: code, stdout: '', stderr: 'error: boom\n', exit_note: `The program exited with code ${code}.` } }),
    );
  });

  test('output shows control and bidi characters as markers', async () => {
    const h = harness(
      { getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] },
      { runner: fakeRunner({ exit_code: 0, stdout: 'ok‮cba\n', stderr: '\u001b[31mred\r\n' }) },
    );
    await h.page.load();
    await h.page.run('run');
    const v = h.page.view();
    expect(v.state === 'signed_in' && v.output).toEqual({ action: 'run', exit_code: 0, stdout: 'ok[U+202E]cba\n', stderr: '[U+001B][31mred\n', exit_note: null });
  });

  test("test runs the lesson's test command", async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner, lesson: LESSON_WITH_TEST });
    await h.page.load();
    await h.page.run('test');
    expect(runner.calls.map((c) => c.command)).toEqual(['mopm test']);
    const v = h.page.view();
    expect(v.state === 'signed_in' && v.output?.action).toBe('test');
  });

  test('test on a lesson without tests does nothing', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('test');
    expect(runner.calls).toEqual([]);
    expect(h.views).toHaveLength(1);
  });

  test('a new run clears the last output while it runs', async () => {
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] });
    await h.page.load();
    await h.page.run('run');
    const second = h.page.run('run');
    expect(h.page.view()).toEqual(signedInView({ state: 'running', running: 'run' }));
    await second;
  });

  test('a runner that throws: run_failed, and the page can run again', async () => {
    const runner = fakeRunner(new Error('NotFoundError: mopm'), OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(h.page.view()).toEqual(signedInView({ message: msg('run_failed') }));
    await h.page.run('run');
    expect(runner.calls).toHaveLength(2);
    // The grant was not the problem: it is kept.
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX]);
  });
});

describe('one thing at a time', () => {
  test('while a run is in flight, run, load and sign-out do nothing; edits go on', async () => {
    const runner = heldRunner();
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    await h.page.load();
    const first = h.page.run('run');
    // Let the run reach the runner.
    while (runner.calls === 0) await Promise.resolve();
    await h.page.run('run');
    await h.page.load();
    await h.page.signOut();
    h.page.edit('src/main.mojo', EDITED);
    expect(h.page.view()).toEqual(signedInView({ state: 'running', running: 'run', files: [{ path: 'src/main.mojo', text: EDITED }] }));
    runner.finish(OK);
    await first;
    expect(runner.calls).toBe(1);
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX]);
    const v = h.page.view();
    expect(v.state === 'signed_in' && v.files).toEqual([{ path: 'src/main.mojo', text: EDITED }]);
  });

  test('while a load is in flight, a second load and a run do nothing', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER] }, { runner });
    const first = h.page.load();
    await h.page.load();
    await h.page.run('run');
    await first;
    expect(h.requests()).toEqual([GET_SESSION]);
    expect(runner.calls).toEqual([]);
  });

  test('while a sign-out is in flight, a run does nothing', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], webLogout: [answer('sign out answers 204 and clears the session cookie')] }, { runner });
    await h.page.load();
    const out = h.page.signOut();
    await h.page.run('run');
    await out;
    expect(runner.calls).toEqual([]);
    expect(h.page.view().state).toBe('signed_out');
  });
});

describe('the sandbox', () => {
  test('is reused while its expires_at is more than RENEW_BEFORE_MS away', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER, GRANT_2_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('run');
    h.clock.now = GRANT_END - RENEW_BEFORE_MS - 1;
    await h.page.run('run');
    expect(runner.calls.map((c) => c.grant)).toEqual([GRANT, GRANT]);
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX]);
  });

  test.each([
    ['exactly RENEW_BEFORE_MS before', GRANT_END - RENEW_BEFORE_MS],
    ['after', GRANT_END + 1],
  ])('is replaced before a run %s its expires_at', async (_, at) => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER, GRANT_2_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('run');
    h.clock.now = at;
    await h.page.run('run');
    expect(runner.calls.map((c) => c.grant)).toEqual([GRANT, GRANT_2]);
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, POST_SANDBOX]);
  });

  test('RENEW_BEFORE_MS is a minute (design section 7)', () => {
    expect(RENEW_BEFORE_MS).toBe(60_000);
  });

  test.each(['SandboxNotRunning', 'SandboxUnreachable'] as const)(
    '%s: replaced once, and the same run repeated on the new one',
    async (kind) => {
      const runner = fakeRunner({ kind }, OK);
      const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER, GRANT_2_ANSWER] }, { runner });
      await h.page.load();
      h.page.edit('src/main.mojo', EDITED);
      await h.page.run('run');
      const sent = [{ path: 'src/main.mojo', text: EDITED }];
      expect(runner.calls).toEqual([
        { grant: GRANT, files: sent, command: 'mopm run src/main.mojo' },
        { grant: GRANT_2, files: sent, command: 'mopm run src/main.mojo' },
      ]);
      expect(h.page.view()).toEqual(
        signedInView({ files: sent, output: { action: 'run', exit_code: 0, stdout: 'Hello, world\n', stderr: '', exit_note: null } }),
      );
      // The new sandbox is the one held after.
      await h.page.run('run');
      expect(runner.calls[2].grant).toEqual(GRANT_2);
      expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, POST_SANDBOX]);
    },
  );

  test('gone twice: no third try, tutorial_unavailable, and the next run asks for a new sandbox', async () => {
    const runner = fakeRunner({ kind: 'SandboxNotRunning' }, { kind: 'SandboxUnreachable' }, OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER, GRANT_2_ANSWER, GRANT_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(runner.calls).toHaveLength(2);
    expect(h.page.view()).toEqual(signedInView({ message: msg('tutorial_unavailable') }));
    await h.page.run('run');
    expect(runner.calls.map((c) => c.grant)).toEqual([GRANT, GRANT_2, GRANT]);
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, POST_SANDBOX, POST_SANDBOX]);
  });

  test('gone, and the replacement refused: the refusal is the message', async () => {
    const runner = fakeRunner({ kind: 'SandboxNotRunning' });
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [GRANT_ANSWER, UNAVAILABLE] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(runner.calls).toHaveLength(1);
    expect(h.page.view()).toEqual(signedInView({ message: msg('tutorial_unavailable') }));
  });
});

describe("the endpoint's errors", () => {
  test.each([
    ['invalid_request', INVALID],
    ['tutorial_unavailable', UNAVAILABLE],
    ['tutorial_unavailable', HTML_504],
  ] as const)('%s: its message, signed in, no run', async (code, a) => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [a] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(h.page.view()).toEqual(signedInView({ message: msg(code) }));
    expect(runner.calls).toEqual([]);
  });

  test('the messages are the sentences of the endpoint table', () => {
    expect(MESSAGES).toEqual({
      session_required: 'Sign in with GitHub to run this lesson.',
      csrf_failed: 'Reload the page.',
      invalid_request: 'Something went wrong. Reload the page.',
      tutorial_unavailable: 'The sandbox service did not answer. Try again in a minute.',
      run_failed: 'The run stopped before it finished. Try again.',
    });
  });

  test('session_required: signed out with the sign-in link, the edited code kept and still editable', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN, SIGNED_IN], createTutorialSandbox: [SANDBOX_SESSION_REQUIRED, GRANT_ANSWER] }, { runner });
    await h.page.load();
    h.page.edit('src/main.mojo', EDITED);
    await h.page.run('run');
    expect(h.page.view()).toEqual({
      state: 'signed_out',
      lesson: 'hello',
      sign_in: SIGN_IN_HELLO,
      files: [{ path: 'src/main.mojo', text: EDITED }],
      message: msg('session_required'),
    });
    expect(runner.calls).toEqual([]);
    h.page.edit('src/main.mojo', `${EDITED}# more\n`);
    const v = h.page.view();
    expect(v.state === 'signed_out' && v.files).toEqual([{ path: 'src/main.mojo', text: `${EDITED}# more\n` }]);
    // Signed in again (another tab): the editor's files win over the lesson's.
    await h.page.load();
    expect(h.page.view()).toEqual(signedInView({ files: [{ path: 'src/main.mojo', text: `${EDITED}# more\n` }] }));
  });

  test('csrf_failed: the session asked again, and one retry with its value', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [CSRF_FAILED, GRANT_ANSWER] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, GET_SESSION, POST_SANDBOX]);
    expect(runner.calls.map((c) => c.grant)).toEqual([GRANT]);
    const v = h.page.view();
    expect(v.state === 'signed_in' && v.message).toBeNull();
  });

  test('csrf_failed twice: "Reload the page.", and no third request', async () => {
    const runner = fakeRunner(OK);
    const h = harness({ getWebSession: [SIGNED_IN], createTutorialSandbox: [CSRF_FAILED] }, { runner });
    await h.page.load();
    await h.page.run('run');
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, GET_SESSION, POST_SANDBOX]);
    expect(h.page.view()).toEqual(signedInView({ message: msg('csrf_failed') }));
    expect(runner.calls).toEqual([]);
  });

  test('csrf_failed, then the session is signed out: signed out with the code kept, no retry', async () => {
    const h = harness({ getWebSession: [SIGNED_IN, SIGNED_OUT], createTutorialSandbox: [CSRF_FAILED, GRANT_ANSWER] });
    await h.page.load();
    await h.page.run('run');
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, GET_SESSION]);
    expect(h.page.view()).toEqual({
      state: 'signed_out',
      lesson: 'hello',
      sign_in: SIGN_IN_HELLO,
      files: [{ path: 'src/main.mojo', text: MAIN }],
      message: msg('session_required'),
    });
  });

  test('csrf_failed, then the session cannot be read: tutorial_unavailable, no retry', async () => {
    const h = harness({ getWebSession: [SIGNED_IN, HTML_504], createTutorialSandbox: [CSRF_FAILED, GRANT_ANSWER] });
    await h.page.load();
    await h.page.run('run');
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, GET_SESSION]);
    expect(h.page.view()).toEqual(signedInView({ message: msg('tutorial_unavailable') }));
  });
});

describe('sign-out', () => {
  test('signed out, no editor, and the sandbox forgotten: signing in again asks for a new one', async () => {
    const runner = fakeRunner(OK);
    const h = harness(
      {
        getWebSession: [SIGNED_IN, SIGNED_IN],
        webLogout: [answer('sign out answers 204 and clears the session cookie')],
        createTutorialSandbox: [GRANT_ANSWER, GRANT_2_ANSWER],
      },
      { runner },
    );
    await h.page.load();
    await h.page.run('run');
    await h.page.signOut();
    expect(h.page.view()).toEqual({ state: 'signed_out', lesson: 'hello', sign_in: SIGN_IN_HELLO, files: null, message: null });
    await h.page.load();
    await h.page.run('run');
    expect(runner.calls.map((c) => c.grant)).toEqual([GRANT, GRANT_2]);
    expect(h.requests()).toEqual([GET_SESSION, POST_SANDBOX, POST_LOGOUT, GET_SESSION, POST_SANDBOX]);
  });

  test('refused: its message, still signed in, the last output kept', async () => {
    const h = harness({
      getWebSession: [SIGNED_IN],
      createTutorialSandbox: [GRANT_ANSWER],
      webLogout: [answer('sign out with a wrong CSRF value is refused as csrf_failed')],
    });
    await h.page.load();
    await h.page.run('run');
    await h.page.signOut();
    expect(h.page.view()).toEqual(
      signedInView({
        output: { action: 'run', exit_code: 0, stdout: 'Hello, world\n', stderr: '', exit_note: null },
        message: msg('csrf_failed'),
      }),
    );
  });
});

test('page.ts imports only the gate and the Doc types: no DOM module, no SDK', () => {
  const src = readFileSync(join(__dirname, '..', 'src', 'tutorial', 'page.ts'), 'utf8');
  expect([...src.matchAll(/^import .* from '([^']+)';$/gm)].map((m) => m[1])).toEqual(['../doc.js', './gate.js']);
  expect(src).not.toMatch(/\b(document|window|globalThis|localStorage)\s*[.[]|from 'e2b'/);
});
