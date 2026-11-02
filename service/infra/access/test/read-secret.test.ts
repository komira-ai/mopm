// Tests readSecret (lib/read-secret.ts) through injected terminal seams: no real terminal, no timing.
// Proves: EAGAIN reads are retried via the blocking wait and the secret still comes back; /dev/tty is preferred and
// closed, with fd 0 as the fallback; raw mode is restored after success, after a read error and after ctrl-C; the
// non-terminal path is the first line of stdin and never touches the terminal; the secret is never echoed or
// put in an error.
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { SecretIo, openTerminal, readSecret, realSecretIo } from '../lib/read-secret';

const SECRET = 's3ntinel-client-secret-0123456789abcdef';
const eagain = () => Object.assign(new Error('EAGAIN: resource temporarily unavailable, read'), { code: 'EAGAIN' });

type Step = string | Error; // a byte string to deliver one byte at a time, or an error to throw

function fake(script: Step[], opts: { tty?: number; isTty?: boolean; stdin?: string } = {}) {
  const queue: Step[] = script.flatMap<Step>((st) => (typeof st === 'string' ? [...Buffer.from(st)].map((b) => String.fromCharCode(b)) : [st]));
  const log: string[] = [];
  const err: string[] = [];
  const io: SecretIo = {
    stdinIsTty: opts.isTty ?? true,
    readAllStdin: () => { log.push('readAll'); return opts.stdin ?? ''; },
    openTty: () => { log.push('openTty'); return opts.tty; },
    closeFd: (fd) => { log.push(`close:${fd}`); },
    readFd: (fd, buf) => {
      log.push(`read:${fd}`);
      const next = queue.shift();
      if (next === undefined) return 0;
      if (next instanceof Error) throw next;
      buf.write(next, 0, 1, 'latin1');
      return 1;
    },
    waitForInput: () => { log.push('wait'); },
    setRawMode: (on) => { log.push(`raw:${on}`); },
    writeErr: (t) => { err.push(t); },
  };
  return { io, log, err };
}

test('EAGAIN on the first reads, then data: the secret is returned and each EAGAIN waited once', () => {
  const { io, log } = fake([eagain(), eagain(), `${SECRET}\n`]);
  expect(readSecret('gamma', io)).toBe(SECRET);
  expect(log.filter((l) => l === 'wait')).toHaveLength(2);
});

test('EAGAIN in the middle of the secret loses nothing', () => {
  const { io } = fake(['abc', eagain(), 'def\r']);
  expect(readSecret('gamma', io)).toBe('abcdef');
});

test('prefers /dev/tty when it opens, reads from it, and closes it', () => {
  const { io, log } = fake([`${SECRET}\n`], { tty: 7 });
  expect(readSecret('gamma', io)).toBe(SECRET);
  expect(log.filter((l) => l.startsWith('read:')).every((l) => l === 'read:7')).toBe(true);
  expect(log).toContain('close:7');
});

test('falls back to fd 0 when there is no /dev/tty, and closes nothing', () => {
  const { io, log } = fake([`${SECRET}\n`]);
  expect(readSecret('gamma', io)).toBe(SECRET);
  expect(log.filter((l) => l.startsWith('read:')).every((l) => l === 'read:0')).toBe(true);
  expect(log.some((l) => l.startsWith('close:'))).toBe(false);
});

test('raw mode is on while reading and restored after success', () => {
  const { io, log } = fake([`${SECRET}\n`], { tty: 5 });
  readSecret('gamma', io);
  expect(log.filter((l) => l.startsWith('raw:'))).toEqual(['raw:true', 'raw:false']);
  expect(log.indexOf('raw:true')).toBeLessThan(log.findIndex((l) => l.startsWith('read:')));
});

test('raw mode is restored and the tty closed after a read error, and the error does not carry the secret', () => {
  const { io, log, err } = fake([`${SECRET.slice(0, 10)}`, Object.assign(new Error(`EIO ${SECRET}`), { code: 'EIO' })], { tty: 5 });
  let thrown: Error | undefined;
  try { readSecret('gamma', io); } catch (e) { thrown = e as Error; }
  expect(thrown).toBeDefined();
  expect(thrown!.message).not.toContain(SECRET.slice(0, 10));
  expect(thrown!.message).not.toContain(SECRET);
  expect(log.filter((l) => l.startsWith('raw:'))).toEqual(['raw:true', 'raw:false']);
  expect(log).toContain('close:5');
  expect(err.join('')).not.toContain(SECRET.slice(0, 10));
});

test('ctrl-C throws "interrupted" and restores the terminal', () => {
  const { io, log } = fake(['ab\x03'], { tty: 5 });
  expect(() => readSecret('gamma', io)).toThrow('interrupted');
  expect(log.filter((l) => l.startsWith('raw:'))).toEqual(['raw:true', 'raw:false']);
  expect(log).toContain('close:5');
});

test('raw mode is not "restored" when turning it on failed', () => {
  const { io, log } = fake([`${SECRET}\n`], { tty: 5 });
  io.setRawMode = (on) => { log.push(`raw:${on}`); if (on) throw new Error('no raw'); };
  expect(() => readSecret('gamma', io)).toThrow('no raw');
  expect(log.filter((l) => l.startsWith('raw:'))).toEqual(['raw:true']);
  expect(log).toContain('close:5');
});

test('backspace and ^H edit the secret; end of input ends it', () => {
  const { io } = fake(['abx\x7fc\b\b', 'z']);
  expect(readSecret('gamma', io)).toBe('az');
});

test('non-terminal: the first line of stdin, no terminal touched', () => {
  const { io, log, err } = fake([], { isTty: false, stdin: `${SECRET}\nsecond line\n` });
  expect(readSecret('gamma', io)).toBe(SECRET);
  expect(log).toEqual(['readAll']);
  expect(err).toEqual([]);
});

test('the secret is never written to the output: only the prompt and a newline', () => {
  const { io, err } = fake([`${SECRET}\n`], { tty: 5 });
  readSecret('gamma', io);
  expect(err.join('')).toBe('GitHub OAuth app client secret for gamma (input hidden): \n');
});

describe('the real seams (no terminal needed)', () => {
  test('readFd and closeFd read one byte at a time from a descriptor and report end of input as 0', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'read-secret-'));
    const file = path.join(dir, 'in');
    fs.writeFileSync(file, 'ab');
    const fd = fs.openSync(file, 'r');
    try {
      const buf = Buffer.alloc(1);
      expect(realSecretIo.readFd(fd, buf)).toBe(1);
      expect(buf.toString()).toBe('a');
      expect(realSecretIo.readFd(fd, buf)).toBe(1);
      expect(realSecretIo.readFd(fd, buf)).toBe(0);
    } finally {
      realSecretIo.closeFd(fd);
      fs.rmSync(dir, { recursive: true });
    }
  });

  test('waitForInput returns (a blocking park, not a spin)', () => {
    expect(() => realSecretIo.waitForInput()).not.toThrow();
  });

  test('openTty yields a descriptor or undefined, never throws', () => {
    const fd = realSecretIo.openTty();
    if (fd !== undefined) realSecretIo.closeFd(fd);
    expect(fd === undefined || typeof fd === 'number').toBe(true);
  });

  test('writeErr writes to stderr and setRawMode forwards to stdin', () => {
    const w = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const calls: boolean[] = [];
    const stdin = process.stdin as unknown as { setRawMode?: (on: boolean) => void };
    const saved = stdin.setRawMode;
    stdin.setRawMode = (on: boolean) => { calls.push(on); };
    try {
      realSecretIo.writeErr('x');
      realSecretIo.setRawMode(true);
      realSecretIo.setRawMode(false);
      expect(w).toHaveBeenCalledWith('x');
      expect(calls).toEqual([true, false]);
    } finally {
      w.mockRestore();
      stdin.setRawMode = saved;
    }
  });

  test('openTerminal is undefined when the device cannot be opened', () => {
    expect(openTerminal(path.join(os.tmpdir(), 'read-secret-no-such-device'))).toBeUndefined();
  });
});
