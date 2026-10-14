import { generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import type { FetchLike, Jwk } from '../src/auth';

/** A clock the tests move by hand. */
export class TestClock {
  constructor(public t = Date.parse('2026-10-14T12:00:00Z')) {}
  now = () => new Date(this.t);
  advance(ms: number) {
    this.t += ms;
  }
  get seconds() {
    return Math.floor(this.t / 1000);
  }
}

export interface FakeGitHubState {
  /** What the next poll(s) answer: shift()ed in order; the last repeats. */
  pollScript: Array<Record<string, unknown>>;
  user: Record<string, unknown>;
  userStatus: number;
  calls: Array<{ url: string; method: string; headers: Record<string, string>; body?: string }>;
}

/** A fake of the three GitHub endpoints login uses. No network. */
export function fakeGitHub(over: Partial<FakeGitHubState> = {}) {
  const state: FakeGitHubState = {
    pollScript: [{ access_token: 'gho_faketoken', token_type: 'bearer', scope: 'read:user' }],
    user: { id: 4242, login: 'octo', two_factor_authentication: true },
    userStatus: 200,
    calls: [],
    ...over,
  };
  const fetchFn: FetchLike = async (url, init) => {
    state.calls.push({ url, ...init });
    const reply = (status: number, body: unknown) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
    if (url === 'https://github.com/login/device/code') {
      return reply(200, {
        device_code: 'gh-device-code-0123456789',
        user_code: 'WDJB-MJHT',
        verification_uri: 'https://github.com/login/device',
        expires_in: 900,
        interval: 5,
      });
    }
    if (url === 'https://github.com/login/oauth/access_token') {
      const next = state.pollScript.length > 1 ? state.pollScript.shift()! : state.pollScript[0]!;
      return reply(200, next);
    }
    if (url === 'https://api.github.com/user') return reply(state.userStatus, state.user);
    return reply(404, {});
  };
  return { state, fetchFn };
}

const b64u = (v: unknown) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');

export interface TestKey {
  kid: string;
  privateKey: KeyObject;
  jwk: Jwk;
}
export function newKey(kid: string): TestKey {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' }) as unknown as Jwk;
  return { kid, privateKey, jwk: { ...jwk, kid, use: 'sig', alg: 'RS256' } };
}

export function signJwt(key: TestKey, claims: Record<string, unknown>, header: Record<string, unknown> = {}): string {
  const h = b64u({ alg: 'RS256', typ: 'JWT', kid: key.kid, ...header });
  const p = b64u(claims);
  const sig = sign('RSA-SHA256', Buffer.from(`${h}.${p}`), key.privateKey).toString('base64url');
  return `${h}.${p}.${sig}`;
}

/** Hand-assembled token, for algorithm and tamper cases. */
export const rawJwt = (header: unknown, claims: unknown, sig = randomBytes(32).toString('base64url')) => `${b64u(header)}.${b64u(claims)}.${sig}`;

export const ISSUER = 'https://token.actions.githubusercontent.com';

export function goodClaims(clock: TestClock, over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: ISSUER,
    aud: 'mopm.dev',
    sub: 'repo:acme/widgets:ref:refs/tags/v1.0.0',
    iat: clock.seconds - 5,
    nbf: clock.seconds - 5,
    exp: clock.seconds + 300,
    repository: 'acme/widgets',
    repository_id: '111',
    repository_owner_id: '222',
    workflow_ref: 'acme/widgets/.github/workflows/release.yml@refs/tags/v1.0.0',
    ...over,
  };
}
