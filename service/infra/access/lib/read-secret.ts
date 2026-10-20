import * as fs from 'fs';
import { firstLine } from './oauth-secret';

/** The client secret from the terminal (input hidden) or, when stdin is not a terminal, the first line of stdin. */
export function readSecret(stage: string): string {
  if (!process.stdin.isTTY) return firstLine(fs.readFileSync(0, 'utf8'));
  process.stderr.write(`GitHub OAuth app client secret for ${stage} (input hidden): `);
  const stdin = process.stdin;
  stdin.setRawMode(true);
  const buf = Buffer.alloc(1);
  let s = '';
  try {
    for (;;) {
      if (fs.readSync(0, buf, 0, 1, null) === 0) break;
      const ch = buf.toString('utf8');
      if (ch === '\n' || ch === '\r' || ch === '\x04') break;
      if (ch === '\x03') throw new Error('interrupted');
      if (ch === '\x7f' || ch === '\b') s = s.slice(0, -1);
      else s += ch;
    }
  } finally {
    stdin.setRawMode(false);
    process.stderr.write('\n');
  }
  return s;
}
