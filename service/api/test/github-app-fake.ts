import { generateKeyPairSync, verify } from 'node:crypto';
import type { FetchLike } from '../src/auth';

/** One RSA key for the fake App, made once per test file (key generation is the slow part). */
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
export const APP_ID = '424242';
export const APP_PRIVATE_KEY = privateKey.export({ format: 'pem', type: 'pkcs8' }).toString();
export const APP_PUBLIC_KEY = publicKey;

export interface FakeInstallation {
  account: { id: number; login: string };
  suspended?: boolean;
}
export interface FakeMembership {
  /** The id GitHub shows as the membership's user: the holder of the login now. */
  user_id: number;
  state: string;
  role: string;
}
/** A failure the fake answers instead of the real reply, for every call whose path matches. */
export interface FakeFault {
  path: RegExp;
  status?: number;
  /** The fetch rejects, as when GitHub cannot be reached. */
  reject?: boolean;
  /** Answer this body with status 200 instead (an unusable answer). */
  body?: unknown;
  /** The body is not JSON. */
  badJson?: boolean;
}

export interface FakeGitHubAppState {
  installations: Map<number, FakeInstallation>;
  /** Current login by account id. */
  users: Map<number, string>;
  /** By `<org login>/<user login>`, in lower case, as GitHub matches logins. */
  memberships: Map<string, FakeMembership>;
  faults: FakeFault[];
  calls: Array<{ method: string; path: string; auth: string }>;
  /** Installation tokens handed out: token -> installation and expiry (ms). */
  tokens: Map<string, { installation: number; expires: number }>;
}

const b64json = (s: string) => JSON.parse(Buffer.from(s, 'base64url').toString('utf8'));

/**
 * A fake of the GitHub REST endpoints the registry's App uses, over FetchLike, no network. It holds GitHub's own rules
 * where the check depends on them: the App's JWT is verified (RS256 signature with the App's key, issuer, times); an
 * installation token works only for its installation's organization and until it expires; logins match without case;
 * a suspended installation gets no token.
 */
export function fakeGitHubApp(now: () => Date) {
  const state: FakeGitHubAppState = {
    installations: new Map(),
    users: new Map(),
    memberships: new Map(),
    faults: [],
    calls: [],
    tokens: new Map(),
  };
  let minted = 0;
  const reply = (status: number, body: unknown, badJson = false) => ({
    ok: status >= 200 && status < 300,
    status,
    json: async () => {
      if (badJson) throw new SyntaxError('Unexpected token < in JSON');
      return body;
    },
  });
  const secs = () => Math.floor(now().getTime() / 1000);

  const appJwtOk = (auth: string) => {
    const m = /^Bearer ([^.]+)\.([^.]+)\.([^.]+)$/.exec(auth);
    if (!m) return false;
    const head = b64json(m[1]!);
    const claims = b64json(m[2]!);
    if (head.alg !== 'RS256' || claims.iss !== APP_ID) return false;
    if (!verify('RSA-SHA256', Buffer.from(`${m[1]}.${m[2]}`), APP_PUBLIC_KEY, Buffer.from(m[3]!, 'base64url'))) return false;
    // GitHub: issued no later than now, expiring after now and at most 10 minutes after it was issued.
    return claims.iat <= secs() && claims.exp > secs() && claims.exp - claims.iat <= 600;
  };
  const tokenOf = (auth: string) => {
    const t = state.tokens.get(auth.replace(/^Bearer /, ''));
    return t && t.expires > now().getTime() ? t : undefined;
  };
  const installationBody = (id: number, i: FakeInstallation) => ({
    id,
    account: { id: i.account.id, login: i.account.login, type: 'Organization' },
    permissions: { members: 'read' },
    suspended_at: i.suspended ? '2026-10-01T00:00:00Z' : null,
  });

  const fetchFn: FetchLike = async (url, init) => {
    const u = new URL(url);
    const path = decodeURIComponent(u.pathname);
    const auth = init.headers.authorization ?? '';
    state.calls.push({ method: init.method, path, auth });
    if (u.origin !== 'https://api.github.com') return reply(404, {});
    for (const f of state.faults) {
      if (!f.path.test(path)) continue;
      if (f.reject) throw new TypeError('fetch failed');
      if (f.badJson) return reply(200, undefined, true);
      if (f.body !== undefined) return reply(200, f.body);
      return reply(f.status ?? 500, { message: 'fault' });
    }
    let m = /^\/app\/installations\/(\d+)$/.exec(path);
    if (m && init.method === 'GET') {
      if (!appJwtOk(auth)) return reply(401, { message: 'A JSON web token could not be decoded' });
      const i = state.installations.get(Number(m[1]));
      return i ? reply(200, installationBody(Number(m[1]), i)) : reply(404, { message: 'Not Found' });
    }
    m = /^\/orgs\/([^/]+)\/installation$/.exec(path);
    if (m && init.method === 'GET') {
      if (!appJwtOk(auth)) return reply(401, { message: 'A JSON web token could not be decoded' });
      for (const [id, i] of state.installations) if (i.account.login.toLowerCase() === m[1]!.toLowerCase()) return reply(200, installationBody(id, i));
      return reply(404, { message: 'Not Found' });
    }
    m = /^\/app\/installations\/(\d+)\/access_tokens$/.exec(path);
    if (m && init.method === 'POST') {
      if (!appJwtOk(auth)) return reply(401, { message: 'A JSON web token could not be decoded' });
      const i = state.installations.get(Number(m[1]));
      if (!i) return reply(404, { message: 'Not Found' });
      if (i.suspended) return reply(403, { message: 'This installation has been suspended' });
      const token = `ghs_fake${++minted}`;
      const expires = now().getTime() + 3600 * 1000;
      state.tokens.set(token, { installation: Number(m[1]), expires });
      return reply(201, { token, expires_at: new Date(expires).toISOString().replace(/\.\d{3}Z$/, 'Z'), permissions: { members: 'read' } });
    }
    m = /^\/user\/(\d+)$/.exec(path);
    if (m && init.method === 'GET') {
      if (!tokenOf(auth)) return reply(401, { message: 'Bad credentials' });
      const login = state.users.get(Number(m[1]));
      return login ? reply(200, { id: Number(m[1]), login, type: 'User' }) : reply(404, { message: 'Not Found' });
    }
    m = /^\/orgs\/([^/]+)\/memberships\/([^/]+)$/.exec(path);
    if (m && init.method === 'GET') {
      const t = tokenOf(auth);
      if (!t) return reply(401, { message: 'Bad credentials' });
      // An installation token reads its own organization only.
      if (state.installations.get(t.installation)?.account.login.toLowerCase() !== m[1]!.toLowerCase()) {
        return reply(403, { message: 'Resource not accessible by integration' });
      }
      const ms = state.memberships.get(`${m[1]!.toLowerCase()}/${m[2]!.toLowerCase()}`);
      if (!ms) return reply(404, { message: 'Not Found' });
      return reply(200, {
        url: `https://api.github.com/orgs/${m[1]}/memberships/${m[2]}`,
        state: ms.state,
        role: ms.role,
        organization: { login: m[1] },
        user: { login: state.users.get(ms.user_id) ?? m[2], id: ms.user_id },
      });
    }
    return reply(404, { message: 'Not Found' });
  };

  const gh = {
    state,
    fetchFn,
    install(id: number, account: { id: number; login: string }) {
      state.installations.set(id, { account });
      return gh;
    },
    user(id: number, login: string) {
      state.users.set(id, login);
      return gh;
    },
    member(org: string, login: string, user_id: number, role = 'member', st = 'active') {
      state.memberships.set(`${org.toLowerCase()}/${login.toLowerCase()}`, { user_id, state: st, role });
      return gh;
    },
    removeMember(org: string, login: string) {
      state.memberships.delete(`${org.toLowerCase()}/${login.toLowerCase()}`);
      return gh;
    },
    /** Calls other than token minting, as `<METHOD> <path>`. */
    reads() {
      return state.calls.filter((c) => !c.path.endsWith('/access_tokens')).map((c) => `${c.method} ${c.path}`);
    },
  };
  return gh;
}
