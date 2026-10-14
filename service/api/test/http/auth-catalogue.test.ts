import * as fs from 'fs';
import * as path from 'path';
import { AUTH_HTTP_STATUS } from '../../src/auth/errors';
import { AUTH_CATALOGUE } from '../../src/http/auth-catalogue';
import { CATALOGUE } from '../../src/http/catalogue';

// The error text of the auth operations is the contract's: compare every template with the `x-mopm-errors` table of
// spec/api/openapi.yaml, line by line. What it catches: a reworded message or hint, a changed status, a code that is in
// the code but not in the spec. What it cannot: a code the spec lists that the code never raises.

const SPEC = path.resolve(__dirname, '../../../../spec/api/openapi.yaml');

function specErrors(): Record<string, { status: number; message: string; hint: string }> {
  const text = fs.readFileSync(SPEC, 'utf8');
  const block = text.slice(text.indexOf('\nx-mopm-errors:'));
  const out: Record<string, { status: number; message: string; hint: string }> = {};
  for (const line of block.split('\n').slice(1)) {
    const m = /^  (\w+):\s+\{ status: (\d+), message: ("(?:[^"\\]|\\.)*"), hint: ("(?:[^"\\]|\\.)*") \}\s*$/.exec(line);
    if (m) out[m[1]!] = { status: Number(m[2]), message: JSON.parse(m[3]!), hint: JSON.parse(m[4]!) };
  }
  return out;
}

const mismatch = (entry: { message: string; hint: string }, want: { message: string; hint: string }) =>
  entry.message !== want.message || entry.hint !== want.hint;

describe('auth error catalogue against spec/api/openapi.yaml', () => {
  const spec = specErrors();

  test('the parser sees the table', () => {
    expect(Object.keys(spec).length).toBeGreaterThan(30);
    expect(spec.token_missing).toEqual({ status: 401, message: 'This request needs a token.', hint: "Run 'mopm login' or pass a token." });
  });

  test.each(Object.entries(AUTH_CATALOGUE))('%s has the spec text and status', (code, entry) => {
    expect(spec[code]).toBeDefined();
    expect(mismatch(entry!, spec[code]!)).toBe(false);
    expect(AUTH_HTTP_STATUS[code as keyof typeof AUTH_HTTP_STATUS]).toBe(spec[code]!.status);
  });

  test('every auth error code the code can raise has a template (except those the read catalogue holds)', () => {
    const codes = Object.keys(AUTH_HTTP_STATUS);
    const missing = codes.filter((c) => !(c in AUTH_CATALOGUE) && !(c in CATALOGUE));
    expect(missing).toEqual([]);
  });

  test('the comparison goes red on a reworded message or hint', () => {
    const real = AUTH_CATALOGUE.token_expired!;
    expect(mismatch(real, spec.token_expired!)).toBe(false);
    expect(mismatch({ ...real, hint: 'Make a new one.' }, spec.token_expired!)).toBe(true);
    expect(mismatch({ ...real, message: real.message.replace('expired at', 'ended at') }, spec.token_expired!)).toBe(true);
  });
});
