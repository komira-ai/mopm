// Fakes for the tutorial page's tests (test/page.test.ts, test/page-draft.test.ts): the gate replays the contract
// examples (replayGate), the runner answers from a script and records each call, the storage records every write and
// can be made to throw, and the clock is a number the test sets.
import { type RecordedAnswer, type ReplayScript, type SandboxGrant, replayGate } from '../src/tutorial/gate';
import {
  type DraftStorage, type Lesson, type LessonFile, type PageView, type RunResult, type Runner, type RunnerError,
  type TutorialPage, tutorialPage,
} from '../src/tutorial/page';
import { type ContractCase, load } from './fixtures';

const CASES = [...load('web-auth'), ...load('tutorial-sandbox')];

export function named(name: string): ContractCase {
  const c = CASES.find((x) => x.name === name && x.expect === undefined);
  if (c === undefined) throw new Error(`no contract case '${name}'`);
  return c;
}

export const answer = (name: string): RecordedAnswer => {
  const c = named(name);
  return { status: c.response.status, headers: c.response.headers, body: c.response.body };
};

export const SIGNED_IN = answer('the signed-in user, with the CSRF value of the session');
export const SIGNED_OUT = answer('the session of a signed-out browser is refused as session_required');
export const LOGIN = (SIGNED_IN.body as { login: string }).login;
export const GRANT_ANSWER = answer('a signed-in user gets a sandbox and what the browser needs to reach it');
export const GRANT = GRANT_ANSWER.body as SandboxGrant;
/** A second grant, for a replaced sandbox: another id and token. */
export const GRANT_2: SandboxGrant = { ...GRANT, sandbox_id: 'z9y8x7w6v5u4t3s2r1q0', access_token: 'second-sandbox-token' };
export const GRANT_2_ANSWER: RecordedAnswer = { ...GRANT_ANSWER, body: GRANT_2 };
export const CSRF_FAILED = answer('a sandbox request with a wrong CSRF value is refused as csrf_failed');
export const SANDBOX_SESSION_REQUIRED = answer('a sandbox request from a signed-out browser is refused as session_required');
export const INVALID = answer('a sandbox request with a body is refused as invalid_request');
export const UNAVAILABLE = answer('a sandbox request while E2B does not answer is refused as tutorial_unavailable with Retry-After');
export const HTML_504: RecordedAnswer = { status: 504, headers: { 'content-type': 'text/html' }, text: '<html><body>504 Gateway Timeout</body></html>' };

/** When GRANT ends, in milliseconds since the epoch. */
export const GRANT_END = Date.parse(GRANT.expires_at);

export const MAIN = 'fn main():\n    print("Hello, world")\n';
export const LESSON: Lesson = {
  id: 'hello',
  files: [{ path: 'src/main.mojo', text: MAIN }],
  actions: { run: 'mopm run src/main.mojo' },
};
export const LESSON_WITH_TEST: Lesson = {
  id: 'testing',
  files: [
    { path: 'src/lib.mojo', text: 'fn add(a: Int, b: Int) -> Int:\n    return a + b\n' },
    { path: 'test/test_lib.mojo', text: 'fn test_add():\n    pass\n' },
  ],
  actions: { run: 'mopm run src/main.mojo', test: 'mopm test' },
};

export interface RunCall {
  grant: SandboxGrant;
  files: LessonFile[];
  command: string;
}

/** One scripted answer of the fake runner: what `run` resolves to, or an Error it throws. */
export type Scripted = RunResult | RunnerError | Error;

export const OK: RunResult = { exit_code: 0, stdout: 'Hello, world\n', stderr: '' };

/** A runner that answers from `script` in order (the last one repeats) and records each call. */
export function fakeRunner(...script: Scripted[]): Runner & { calls: RunCall[] } {
  const calls: RunCall[] = [];
  return {
    calls,
    async run(grant, files, command) {
      calls.push({ grant, files: files.map((f) => ({ ...f })), command });
      const a = script[Math.min(calls.length - 1, script.length - 1)];
      if (a instanceof Error) throw a;
      return a;
    },
  };
}

/** A runner whose one run waits until the test calls `finish`. */
export function heldRunner(): Runner & { calls: number; finish(r: RunResult): void } {
  let resolve: (r: RunResult) => void = () => undefined;
  const r = {
    calls: 0,
    run(): Promise<RunResult> {
      r.calls += 1;
      return new Promise<RunResult>((res) => {
        resolve = res;
      });
    },
    finish(x: RunResult) {
      resolve(x);
    },
  };
  return r;
}

/** An in-memory localStorage that records every write; `throws` makes each call throw as a blocked one does. */
export function memoryStorage(initial: Record<string, string> = {}, throws = false): DraftStorage & {
  items: Map<string, string>;
  writes: [string, string][];
} {
  const items = new Map(Object.entries(initial));
  const writes: [string, string][] = [];
  return {
    items,
    writes,
    getItem(key) {
      if (throws) throw new DOMException('The operation is insecure.', 'SecurityError');
      return items.get(key) ?? null;
    },
    setItem(key, value) {
      writes.push([key, value]);
      if (throws) throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
      items.set(key, value);
    },
  };
}

export interface Harness {
  page: TutorialPage;
  gate: ReturnType<typeof replayGate>;
  runner: Runner;
  storage: ReturnType<typeof memoryStorage>;
  views: PageView[];
  clock: { now: number };
  /** The gate's requests as `<method> <path>`. */
  requests(): string[];
}

export interface HarnessOptions {
  lesson?: Lesson;
  /** The runner; `fakeRunner(OK)` when none is given. */
  runner?: Runner;
  storage?: ReturnType<typeof memoryStorage>;
  /** The clock's start; well before GRANT ends unless a test says otherwise. */
  now?: number;
}

/** A page over a replaying gate, a fake runner (OK by default), a recording storage and a manual clock. */
export function harness(script: ReplayScript, o: HarnessOptions = {}): Harness {
  const gate = replayGate(script);
  const runner = o.runner ?? fakeRunner(OK);
  const storage = o.storage ?? memoryStorage();
  const views: PageView[] = [];
  const clock = { now: o.now ?? GRANT_END - 20 * 60_000 };
  const page = tutorialPage({ lesson: o.lesson ?? LESSON, gate, runner, storage, now: () => clock.now, onChange: (v) => views.push(v) });
  return { page, gate, runner, storage, views, clock, requests: () => gate.requests.map((r) => `${r.method} ${r.url}`) };
}
