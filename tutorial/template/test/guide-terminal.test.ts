// guide/terminal.ts, the author's guide's terminal snippet (docs/tutorial-author-guide.md), against a fake of the
// SDK's pty module and a fake widget: what the shell is started with, output, input in order, resize, how the
// terminal ends (exit, a gone sandbox, a dropped connection reattached or not), and closing it.
import { CommandExitError, SandboxNotRunningError, SandboxUnreachableError, type Sandbox } from 'e2b';
import { openTerminal, type TerminalEnd, type TerminalWidget } from '../guide/terminal';

/** A promise the test settles by hand. */
function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Lets every pending promise callback run. */
const settle = () => new Promise<void>((done) => setImmediate(done));

interface FakeHandle {
  pid: number;
  wait: jest.Mock;
  kill: jest.Mock;
  ended: ReturnType<typeof deferred<{ exitCode: number }>>;
}

function fakeHandle(pid: number): FakeHandle {
  const ended = deferred<{ exitCode: number }>();
  return { pid, ended, wait: jest.fn(() => ended.promise), kill: jest.fn(async () => true) };
}

function fakePty() {
  const handles: FakeHandle[] = [];
  const onData: Array<(b: Uint8Array) => void> = [];
  const pty = {
    create: jest.fn(async (opts: { onData: (b: Uint8Array) => void }) => {
      onData.push(opts.onData);
      const h = fakeHandle(42);
      handles.push(h);
      return h;
    }),
    connect: jest.fn(async (pid: number, opts: { onData: (b: Uint8Array) => void }) => {
      onData.push(opts.onData);
      const h = fakeHandle(pid);
      handles.push(h);
      return h;
    }),
    sendInput: jest.fn(async (_pid: number, _data: Uint8Array) => undefined),
    resize: jest.fn(async (_pid: number, _size: { cols: number; rows: number }) => undefined),
  };
  return { sandbox: { pty } as unknown as Sandbox, pty, handles, onData };
}

function fakeWidget() {
  const dataListeners: Array<(d: string) => void> = [];
  const resizeListeners: Array<(s: { cols: number; rows: number }) => void> = [];
  const written: Array<string | Uint8Array> = [];
  let disposed = 0;
  const widget: TerminalWidget = {
    cols: 100,
    rows: 30,
    onData(l) {
      dataListeners.push(l);
      return { dispose: () => void (disposed += 1) };
    },
    onResize(l) {
      resizeListeners.push(l);
      return { dispose: () => void (disposed += 1) };
    },
    write(d) {
      written.push(d);
    },
  };
  return {
    widget,
    written,
    type: (d: string) => dataListeners.forEach((l) => l(d)),
    resize: (s: { cols: number; rows: number }) => resizeListeners.forEach((l) => l(s)),
    disposed: () => disposed,
  };
}

const exitError = (exitCode: number) => new CommandExitError({ exitCode, stdout: '', stderr: '', error: 'exit status' });
const decode = (b: Uint8Array) => new TextDecoder().decode(b);

async function start(maxReconnects?: number) {
  const p = fakePty();
  const w = fakeWidget();
  const ends: TerminalEnd[] = [];
  const session = await openTerminal(p.sandbox, w.widget, {
    cwd: '/home/user/lessons/hello',
    onEnd: (e) => ends.push(e),
    ...(maxReconnects === undefined ? {} : { maxReconnects }),
  });
  return { p, w, ends, session };
}

test('starts a shell of the widget size in the lesson directory, with no session timeout', async () => {
  const { p, session } = await start();
  expect(session.pid).toBe(42);
  expect(p.pty.create).toHaveBeenCalledTimes(1);
  expect(p.pty.create.mock.calls[0][0]).toMatchObject({ cols: 100, rows: 30, cwd: '/home/user/lessons/hello', timeoutMs: 0 });
});

test("the shell's output is written to the widget as bytes", async () => {
  const { p, w } = await start();
  p.onData[0](new TextEncoder().encode('$ '));
  expect(w.written.map((b) => decode(b as Uint8Array))).toEqual(['$ ']);
});

test('keystrokes are sent as UTF-8, one request at a time, in order', async () => {
  const { p, w } = await start();
  const first = deferred<undefined>();
  p.pty.sendInput.mockImplementationOnce(() => first.promise);
  w.type('l');
  w.type('é');
  await settle();
  expect(p.pty.sendInput).toHaveBeenCalledTimes(1);
  first.resolve(undefined);
  await settle();
  expect(p.pty.sendInput.mock.calls.map(([pid, bytes]) => [pid, decode(bytes)])).toEqual([
    [42, 'l'],
    [42, 'é'],
  ]);
});

test('a failed send is dropped and later keystrokes still go', async () => {
  const { p, w } = await start();
  p.pty.sendInput.mockImplementationOnce(async () => {
    throw new SandboxUnreachableError('no answer');
  });
  w.type('a');
  w.type('b');
  await settle();
  expect(p.pty.sendInput.mock.calls.map(([, bytes]) => decode(bytes))).toEqual(['a', 'b']);
});

test('a resize of the widget resizes the pty; a failed resize is ignored', async () => {
  const { p, w } = await start();
  p.pty.resize.mockImplementationOnce(async () => {
    throw new SandboxUnreachableError('no answer');
  });
  w.resize({ cols: 120, rows: 40 });
  w.resize({ cols: 80, rows: 24 });
  await settle();
  expect(p.pty.resize.mock.calls).toEqual([
    [42, { cols: 120, rows: 40 }],
    [42, { cols: 80, rows: 24 }],
  ]);
});

test('the shell exiting with 0 ends the terminal as exited 0 and stops listening to the widget', async () => {
  const { p, w, ends } = await start();
  p.handles[0].ended.resolve({ exitCode: 0 });
  await settle();
  expect(ends).toEqual([{ kind: 'exited', exitCode: 0 }]);
  expect(w.disposed()).toBe(2);
  w.type('x');
  w.resize({ cols: 1, rows: 1 });
  await settle();
  expect(p.pty.sendInput).not.toHaveBeenCalled();
  expect(p.pty.resize).not.toHaveBeenCalled();
});

test('a non-zero exit ends the terminal with its exit code', async () => {
  const { p, ends } = await start();
  p.handles[0].ended.reject(exitError(2));
  await settle();
  expect(ends).toEqual([{ kind: 'exited', exitCode: 2 }]);
});

test('a sandbox that is no longer running ends the terminal as sandbox-ended, without reattaching', async () => {
  const { p, ends } = await start();
  p.handles[0].ended.reject(new SandboxNotRunningError('the sandbox was killed or reached its timeout'));
  await settle();
  expect(ends).toEqual([{ kind: 'sandbox-ended' }]);
  expect(p.pty.connect).not.toHaveBeenCalled();
});

test('a dropped connection is reattached to the same shell, whose output keeps reaching the widget', async () => {
  const { p, w, ends } = await start();
  p.handles[0].ended.reject(new Error('connection terminated'));
  await settle();
  expect(p.pty.connect).toHaveBeenCalledTimes(1);
  expect(p.pty.connect.mock.calls[0][0]).toBe(42);
  expect(p.pty.connect.mock.calls[0][1]).toMatchObject({ timeoutMs: 0 });
  p.onData[1](new TextEncoder().encode('back'));
  expect(decode(w.written[0] as Uint8Array)).toBe('back');
  expect(ends).toEqual([]);
  p.handles[1].ended.resolve({ exitCode: 0 });
  await settle();
  expect(ends).toEqual([{ kind: 'exited', exitCode: 0 }]);
});

test('an unreachable sandbox is reattached, as E2B could not confirm it stopped', async () => {
  const { p, ends } = await start();
  p.handles[0].ended.reject(new SandboxUnreachableError('no answer'));
  await settle();
  expect(p.pty.connect).toHaveBeenCalledTimes(1);
  expect(ends).toEqual([]);
});

test('three drops are reattached by default; the fourth fails the terminal', async () => {
  const { p, ends } = await start();
  for (let i = 0; i < 3; i++) {
    p.handles[i].ended.reject(new Error(`drop ${i}`));
    await settle();
  }
  expect(p.pty.connect).toHaveBeenCalledTimes(3);
  const last = new Error('drop 3');
  p.handles[3].ended.reject(last);
  await settle();
  expect(p.pty.connect).toHaveBeenCalledTimes(3);
  expect(ends).toEqual([{ kind: 'failed', error: last }]);
});

test('maxReconnects 0 fails the terminal on the first drop', async () => {
  const { p, ends } = await start(0);
  const drop = new Error('drop');
  p.handles[0].ended.reject(drop);
  await settle();
  expect(p.pty.connect).not.toHaveBeenCalled();
  expect(ends).toEqual([{ kind: 'failed', error: drop }]);
});

test('a reattach that finds the sandbox gone ends the terminal as sandbox-ended', async () => {
  const { p, ends } = await start();
  p.pty.connect.mockImplementationOnce(async () => {
    throw new SandboxNotRunningError('gone');
  });
  p.handles[0].ended.reject(new Error('drop'));
  await settle();
  expect(ends).toEqual([{ kind: 'sandbox-ended' }]);
});

test('a reattach that fails otherwise ends the terminal as failed with that error', async () => {
  const { p, ends } = await start();
  const refused = new Error('refused');
  p.pty.connect.mockImplementationOnce(async () => {
    throw refused;
  });
  p.handles[0].ended.reject(new Error('drop'));
  await settle();
  expect(ends).toEqual([{ kind: 'failed', error: refused }]);
});

test('close kills the shell and stops listening, and the end that follows is not reported', async () => {
  const { p, w, ends, session } = await start();
  await session.close();
  expect(p.handles[0].kill).toHaveBeenCalledTimes(1);
  expect(w.disposed()).toBe(2);
  p.handles[0].ended.reject(new Error('killed'));
  await settle();
  expect(p.pty.connect).not.toHaveBeenCalled();
  expect(ends).toEqual([]);
  w.type('x');
  await settle();
  expect(p.pty.sendInput).not.toHaveBeenCalled();
});

test('close after the terminal ended does nothing', async () => {
  const { p, w, session } = await start();
  p.handles[0].ended.resolve({ exitCode: 0 });
  await settle();
  await session.close();
  expect(p.handles[0].kill).not.toHaveBeenCalled();
  expect(w.disposed()).toBe(2);
});

test('close succeeds when killing the shell fails', async () => {
  const { p, session } = await start();
  p.handles[0].kill.mockImplementationOnce(async () => {
    throw new SandboxNotRunningError('gone');
  });
  await expect(session.close()).resolves.toBeUndefined();
});
