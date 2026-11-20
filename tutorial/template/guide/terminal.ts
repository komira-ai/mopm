// tutorial/template/guide/terminal.ts
// A terminal in the page: a pseudo-terminal (bash) in the sandbox, wired to a terminal widget. Output goes to the
// widget, keystrokes and size changes go to the sandbox, and the page hears once how the terminal ended.
import { CommandExitError, SandboxNotRunningError, type CommandHandle, type Sandbox } from 'e2b';

export interface Disposable {
  dispose(): void;
}

/** What the terminal needs of a widget: the members of xterm.js's `Terminal` it uses. */
export interface TerminalWidget {
  readonly cols: number;
  readonly rows: number;
  onData(listener: (data: string) => void): Disposable;
  onResize(listener: (size: { cols: number; rows: number }) => void): Disposable;
  write(data: string | Uint8Array): void;
}

/** How a terminal ended; the page shows it and offers a new terminal. */
export type TerminalEnd =
  /** The shell exited (the user typed `exit`). The sandbox is still there. */
  | { kind: 'exited'; exitCode: number }
  /** The sandbox is gone (past its expires_at): a new terminal needs a new sandbox. */
  | { kind: 'sandbox-ended' }
  /** The connection could not be brought back. */
  | { kind: 'failed'; error: unknown };

export interface TerminalOptions {
  /** The shell's working directory, e.g. the lesson's directory. */
  cwd: string;
  /** Called once, unless the page closed the terminal itself. */
  onEnd(end: TerminalEnd): void;
  /** How many times a dropped connection is reattached before the terminal counts as failed. */
  maxReconnects?: number;
}

export interface TerminalSession {
  readonly pid: number;
  /** Stops listening to the widget and kills the shell. */
  close(): Promise<void>;
}

export async function openTerminal(s: Sandbox, term: TerminalWidget, o: TerminalOptions): Promise<TerminalSession> {
  const onData = (bytes: Uint8Array) => term.write(bytes);
  // timeoutMs 0: no limit on the session; the default would end the shell after 60 s.
  let handle: CommandHandle = await s.pty.create({ cols: term.cols, rows: term.rows, cwd: o.cwd, timeoutMs: 0, onData });
  const pid = handle.pid;
  const utf8 = new TextEncoder();
  let ended = false;
  let reconnects = o.maxReconnects ?? 3;

  // Each sendInput is its own request: chain them so keystrokes arrive in order. A failed send is dropped; if the
  // sandbox is gone, the end of the stream below says so.
  let input: Promise<void> = Promise.resolve();
  const listeners = [
    term.onData((data) => {
      if (ended) return;
      input = input.then(() => s.pty.sendInput(pid, utf8.encode(data))).catch(() => undefined);
    }),
    term.onResize((size) => {
      if (!ended) s.pty.resize(pid, size).catch(() => undefined);
    }),
  ];

  const finish = (end: TerminalEnd): void => {
    if (ended) return;
    ended = true;
    for (const l of listeners) l.dispose();
    o.onEnd(end);
  };

  const follow = async (): Promise<void> => {
    for (;;) {
      let dropped: unknown;
      try {
        await handle.wait(); // rejects with CommandExitError on a non-zero exit
        finish({ kind: 'exited', exitCode: 0 });
        return;
      } catch (e) {
        dropped = e;
      }
      if (dropped instanceof CommandExitError) {
        finish({ kind: 'exited', exitCode: dropped.exitCode });
        return;
      }
      if (dropped instanceof SandboxNotRunningError) {
        finish({ kind: 'sandbox-ended' });
        return;
      }
      // Anything else: the connection dropped, and the sandbox may still be running the shell. Reattach to it.
      if (ended || reconnects === 0) {
        finish({ kind: 'failed', error: dropped });
        return;
      }
      reconnects -= 1;
      try {
        handle = await s.pty.connect(pid, { onData, timeoutMs: 0 });
      } catch (again) {
        finish(again instanceof SandboxNotRunningError ? { kind: 'sandbox-ended' } : { kind: 'failed', error: again });
        return;
      }
    }
  };
  void follow();

  return {
    pid,
    async close() {
      if (ended) return;
      ended = true;
      for (const l of listeners) l.dispose();
      await handle.kill().catch(() => false);
    },
  };
}
