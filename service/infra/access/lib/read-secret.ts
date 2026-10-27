import * as fs from 'fs';
import { firstLine } from './oauth-secret';

/** The operating-system touch points of readSecret, injectable so the tests need no terminal. */
export interface SecretIo {
  stdinIsTty: boolean;
  /** Reads all of stdin as text (the non-terminal path). */
  readAllStdin(): string;
  /** Opens the controlling terminal for blocking reads; returns undefined when there is none. */
  openTty(): number | undefined;
  closeFd(fd: number): void;
  /** Reads up to buf.length bytes from fd; returns 0 at end of input; may throw EAGAIN on a non-blocking fd. */
  readFd(fd: number, buf: Buffer): number;
  /** Blocks the thread (no CPU) until a non-blocking fd may have data again. */
  waitForInput(): void;
  setRawMode(on: boolean): void;
  writeErr(text: string): void;
}

const STDIN_FD = 0;

/** A real wait: parks the thread on a futex for a short slice instead of spinning. */
function parkBriefly(): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
}

/** Opens a terminal device for blocking reads, or undefined when it cannot be opened (no controlling terminal). */
export function openTerminal(device: string): number | undefined {
  try {
    return fs.openSync(device, 'r');
  } catch {
    return undefined;
  }
}

export const realSecretIo: SecretIo = {
  stdinIsTty: !!process.stdin.isTTY,
  readAllStdin: () => fs.readFileSync(STDIN_FD, 'utf8'),
  openTty: () => openTerminal('/dev/tty'),
  closeFd: (fd) => fs.closeSync(fd),
  readFd: (fd, buf) => fs.readSync(fd, buf, 0, buf.length, null),
  waitForInput: parkBriefly,
  setRawMode: (on) => process.stdin.setRawMode(on),
  writeErr: (t) => void process.stderr.write(t),
};

function isEagain(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { code?: string }).code === 'EAGAIN';
}

/**
 * The client secret from the terminal (input hidden) or, when stdin is not a terminal, the first line of stdin.
 * On a terminal the secret is read from /dev/tty (a blocking descriptor), falling back to fd 0; under `npm run`
 * fd 0 can be non-blocking, so a read that reports EAGAIN is retried after a blocking wait.
 */
export function readSecret(stage: string, io: SecretIo = realSecretIo): string {
  if (!io.stdinIsTty) return firstLine(io.readAllStdin());
  io.writeErr(`GitHub OAuth app client secret for ${stage} (input hidden): `);
  const tty = io.openTty();
  const fd = tty ?? STDIN_FD;
  const buf = Buffer.alloc(1);
  let s = '';
  let raw = false;
  try {
    io.setRawMode(true);
    raw = true;
    for (;;) {
      let n: number;
      try {
        n = io.readFd(fd, buf);
      } catch (e) {
        if (isEagain(e)) {
          io.waitForInput();
          continue;
        }
        throw new Error('could not read the secret from the terminal');
      }
      if (n === 0) break;
      const ch = buf.toString('utf8');
      if (ch === '\n' || ch === '\r' || ch === '\x04') break;
      if (ch === '\x03') throw new Error('interrupted');
      if (ch === '\x7f' || ch === '\b') s = s.slice(0, -1);
      else s += ch;
    }
  } finally {
    if (raw) io.setRawMode(false);
    if (tty !== undefined) io.closeFd(tty);
    io.writeErr('\n');
  }
  return s;
}
