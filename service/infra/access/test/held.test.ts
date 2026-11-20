// Tests the real Host of the held commands (lib/held.ts, realHost) and the flag parser's edge. The host is driven with
// this test's own node binary (process.execPath) running inline scripts, so no network, no AWS and no fixed path is
// involved. Proves: capture returns the exit status and stdout followed by stderr; a command that cannot be started
// is status 1 with the spawn error in the output; inherit returns the exit status, and 1 when the command cannot be
// started; a value flag at the end of the line gets ''.
import * as os from 'os';
import * as path from 'path';
import { parseFlags, realHost } from '../lib/held';

const NODE = process.execPath;
const MISSING = path.join(os.tmpdir(), 'held-test-no-such-command');

describe('realHost', () => {
  const host = realHost(os.tmpdir());

  test('capture: status 0 and stdout', () => {
    expect(host.capture([NODE, '-e', 'process.stdout.write("out")'])).toEqual({ status: 0, output: 'out' });
  });

  test('capture: a nonzero status, stdout then stderr', () => {
    expect(host.capture([NODE, '-e', 'process.stdout.write("a");process.stderr.write("b");process.exit(3)'])).toEqual({ status: 3, output: 'ab' });
  });

  test('capture: a command that cannot be started is status 1 with the spawn error', () => {
    expect(host.capture([MISSING])).toEqual({ status: 1, output: `Error: spawnSync ${MISSING} ENOENT` });
  });

  test('inherit: returns the exit status', () => {
    expect(host.inherit([NODE, '-e', ''])).toBe(0);
    expect(host.inherit([NODE, '-e', 'process.exit(4)'])).toBe(4);
  });

  test('inherit: a command that cannot be started is status 1', () => {
    expect(host.inherit([MISSING])).toBe(1);
  });

  test('out and err write one line to stdout and stderr', () => {
    const o = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const e = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      host.out('to out');
      host.err('to err');
      expect(o).toHaveBeenCalledWith('to out\n');
      expect(e).toHaveBeenCalledWith('to err\n');
    } finally {
      o.mockRestore();
      e.mockRestore();
    }
  });
});

test('parseFlags: a value flag at the end of the line gets the empty value', () => {
  expect(parseFlags(['--apply', '--stage'], ['--stage'], ['--apply']).values).toEqual({ '--stage': '' });
});
