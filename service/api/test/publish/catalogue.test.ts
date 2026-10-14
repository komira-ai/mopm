import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { AUTH_HTTP_STATUS, AuthError } from '../../src/auth/errors';
import { HTTP_STATUS, RegistryError } from '../../src/errors';
import { PUBLISH_CATALOGUE, errorView } from '../../src/publish/catalogue';
import { PublishError } from '../../src/publish/errors';

const SPEC = resolve(__dirname, '../../../../spec/api/openapi.yaml');

/** The `x-mopm-errors` table of the contract: code -> status, message, hint. */
function specCatalogue(): Record<string, { status: number; message: string; hint: string }> {
  const out: Record<string, { status: number; message: string; hint: string }> = {};
  const line = /^ {2}(\w+):\s+\{ status: (\d+), message: ("(?:[^"\\]|\\.)*"), hint: ("(?:[^"\\]|\\.)*") \}\s*$/;
  for (const l of readFileSync(SPEC, 'utf8').split('\n')) {
    const m = line.exec(l);
    if (m) out[m[1]!] = { status: Number(m[2]), message: JSON.parse(m[3]!), hint: JSON.parse(m[4]!) };
  }
  return out;
}

describe('the publish error catalogue is the contract\'s', () => {
  const spec = specCatalogue();

  test('the spec table was found (the parser reads what the test thinks it reads)', () => {
    expect(Object.keys(spec).length).toBeGreaterThan(30);
    expect(spec.version_exists).toBeDefined();
  });

  test.each(Object.keys(PUBLISH_CATALOGUE))('%s: status, message and hint equal the spec text', (code) => {
    expect(spec[code]).toBeDefined();
    expect(PUBLISH_CATALOGUE[code]).toEqual(spec[code]);
  });

  test('every status the code raises agrees with the catalogue', () => {
    for (const [code, status] of Object.entries(HTTP_STATUS)) if (PUBLISH_CATALOGUE[code]) expect(PUBLISH_CATALOGUE[code]!.status).toBe(status);
    for (const [code, status] of Object.entries(AUTH_HTTP_STATUS)) if (PUBLISH_CATALOGUE[code]) expect(PUBLISH_CATALOGUE[code]!.status).toBe(status);
  });

  test('the auth errors the publish routes can raise are all catalogued', () => {
    for (const code of ['token_missing', 'token_unknown', 'token_expired', 'token_revoked', 'scope_missing']) expect(PUBLISH_CATALOGUE[code]).toBeDefined();
  });
});

describe('errorView', () => {
  test('renders templates from the error\'s detail, whichever class raised it', () => {
    expect(errorView(new RegistryError('version_exists', 'x', { name: 'p', version: '1.0.0', sha256: 'ab' })).body.error.message).toBe(
      "'p' 1.0.0 already exists (sha256 ab); versions are immutable.",
    );
    expect(errorView(new AuthError('token_expired', 'x', { expires_at: 'T' })).body.error.message).toBe('The token expired at T.');
    const rl = errorView(new PublishError('rate_limited', 'x', { retry_after: '9' }, 9));
    expect(rl).toMatchObject({ status: 429, retryAfter: 9 });
    expect(rl.body.error.hint).toBe('Wait 9 seconds; the Retry-After header says how long.');
  });

  test('an error that is not ours, or a code the table lacks, is internal_error', () => {
    expect(errorView(new Error('boom')).body.error.code).toBe('internal_error');
    expect(errorView(new AuthError('stale_session', 'x')).body.error.code).toBe('internal_error');
    expect(errorView('text').status).toBe(500);
  });
});
