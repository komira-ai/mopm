// The token vectors the Rust core (service/lambda/core, mopm_core::token and mopm_core::csrf) is held to: for each 25
// random bytes of service/lambda/core/tests/fixtures/token_vectors.json, generateTokenSecret makes the vector's token,
// hashToken its hash and mintToken its row's prefix; the CSRF value is SHA-256("mopm-csrf\0" + token) in base64url,
// computed here with Node's own crypto, independently of the Rust.
import { createHash } from 'node:crypto';
import * as fs from 'node:fs';
import * as path from 'node:path';

const mockRandom: { next: Buffer | null } = { next: null };
jest.mock('node:crypto', () => {
  const actual = jest.requireActual<typeof import('node:crypto')>('node:crypto');
  return {
    ...actual,
    // The 25 bytes of a secret come from the vector; any other draw (a token id) is the real source.
    randomBytes: (n: number) => (n === 25 && mockRandom.next ? mockRandom.next : actual.randomBytes(n)),
  };
});

import { generateTokenSecret, hashToken, mintToken, MemoryAuthStore, TOKEN_PATTERN, TOKEN_PREFIX } from '../../src/auth';

interface Vector {
  random_hex: string;
  token: string;
  hash: string;
  prefix: string;
  csrf: string;
}

const FIXTURE = path.join(__dirname, '../../../lambda/core/tests/fixtures/token_vectors.json');
const VECTORS = (JSON.parse(fs.readFileSync(FIXTURE, 'utf8')) as { vectors: Vector[] }).vectors;

afterEach(() => {
  mockRandom.next = null;
});

test('the fixture has the four vectors, each of 25 bytes', () => {
  expect(VECTORS.map((v) => Buffer.from(v.random_hex, 'hex').length)).toEqual([25, 25, 25, 25]);
});

test.each(VECTORS.map((v) => [v.random_hex, v] as const))('bytes %s give the vector', async (_hex, v) => {
  mockRandom.next = Buffer.from(v.random_hex, 'hex');
  expect(generateTokenSecret()).toBe(v.token);
  expect(TOKEN_PATTERN.test(v.token)).toBe(true);
  expect(v.token.length).toBe(TOKEN_PREFIX.length + 40);
  expect(hashToken(v.token)).toBe(v.hash);

  const m = await mintToken(new MemoryAuthStore(), {
    kind: 'session', github_id: 1, name: 'web login', scopes: [], packages: [], all_current: false,
    fresh_until: '2026-11-20T10:00:00.000Z', created_at: '2026-11-20T10:00:00.000Z', expires_at: '2026-11-27T10:00:00.000Z',
  });
  expect([m.secret, m.record.hash, m.record.prefix]).toEqual([v.token, v.hash, v.prefix]);

  expect(createHash('sha256').update(`mopm-csrf\0${v.token}`).digest('base64url')).toBe(v.csrf);
});
