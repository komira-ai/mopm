import { splitFullName } from '../names';
import { AuthError } from './errors';
import type { NamespaceAccess } from './namespace-access';
import { mintToken, type Clock, type CreateTokenInput, type TokenMeta } from './tokens';
import type { AuthStore } from './types';

import type { MeV2 } from '../gen/registry-v2';

export type { MeV2 };

export interface TokenServiceV2Deps {
  store: AuthStore;
  access: NamespaceAccess;
  /** The full names of the packages in a namespace, sorted. */
  packagesIn: (namespace: string) => Promise<string[]>;
  now?: Clock;
}

const MAX_TOKENS_PER_USER = 50;
const bad = (detail: string) => new AuthError('invalid_request', `The request is not valid: ${detail}.`, { detail });

/** `GET /api/v2/me` and `POST /api/v2/me/tokens` (docs/design/namespaces.md 2.4 and 8). */
export class TokenServiceV2 {
  private readonly now: Clock;

  constructor(readonly d: TokenServiceV2Deps) {
    this.now = d.now ?? (() => new Date());
  }

  /** The account behind a token and the namespaces it can write in now. A token whose account has no user row is not recognised. */
  async me(github_id: number): Promise<MeV2> {
    const user = await this.d.store.getUser(github_id);
    if (!user) throw new AuthError('token_unknown', 'The token is not recognised.');
    const namespaces = [];
    for (const w of await this.d.access.writable(user)) {
      namespaces.push({ namespace: w.record.namespace, kind: w.record.kind, role: w.role, packages: await this.d.packagesIn(w.record.namespace) });
    }
    const unavailable = await this.d.access.unavailableNamespace(user);
    return { github_id: user.github_id, handle: user.handle, namespaces, ...(unavailable === undefined ? {} : { unavailable_namespace: unavailable }) };
  }

  /** Needs a fresh session (the caller checks). The secret is returned once. */
  async create(github_id: number, input: unknown): Promise<TokenMeta & { token: string }> {
    const i = (typeof input === 'object' && input !== null ? input : {}) as Partial<CreateTokenInput>;
    if (typeof i.name !== 'string' || i.name.length < 1 || i.name.length > 80) throw bad('name must be 1 to 80 characters');
    if (!Array.isArray(i.scopes) || i.scopes.length < 1) throw bad('scopes must not be empty');
    for (const s of i.scopes) if (s !== 'publish' && s !== 'yank' && s !== 'stage') throw bad(`unknown scope '${String(s)}'`);
    const days = i.expires_in_days;
    if (typeof days !== 'number' || !Number.isInteger(days) || days < 1 || days > 90) {
      throw bad('expires_in_days must be an integer from 1 to 90');
    }
    const now = this.now();
    const live = (await this.d.store.listTokens(github_id)).filter((t) => t.kind === 'api' && !t.revoked_at && Date.parse(t.expires_at) > now.getTime());
    if (live.length >= MAX_TOKENS_PER_USER) throw bad(`at most ${MAX_TOKENS_PER_USER} live tokens per account`);

    let packages: string[];
    const all_current = i.packages === 'all_current';
    if (i.packages === 'all_current') {
      const user = await this.d.store.getUser(github_id);
      if (!user) throw new AuthError('token_unknown', 'The token is not recognised.');
      const lists = await Promise.all((await this.d.access.writable(user)).map((w) => this.d.packagesIn(w.record.namespace)));
      packages = [...new Set(lists.flat())].sort();
      if (packages.length === 0) throw bad('you own no packages yet');
    } else {
      if (!Array.isArray(i.packages) || i.packages.length < 1) throw bad('packages must be a non-empty list or all_current');
      packages = [...new Set(i.packages)].sort();
      for (const p of packages) {
        if (typeof p !== 'string' || splitFullName(p) === undefined) throw new AuthError('invalid_name', `'${String(p)}' is not a valid package name.`, { name: String(p) });
      }
      // Each namespace is checked once, in order; a package need not exist yet.
      for (const ns of [...new Set(packages.map((p) => splitFullName(p)!.namespace))]) await this.d.access.require(ns, github_id);
    }

    const m = await mintToken(this.d.store, {
      kind: 'api',
      github_id,
      name: i.name,
      scopes: [...new Set(i.scopes)].sort(),
      packages,
      all_current,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + days * 86_400_000).toISOString(),
    });
    const r = m.record;
    return {
      id: r.id,
      name: r.name,
      scopes: r.scopes,
      packages: all_current ? 'all_current' : r.packages,
      created_at: r.created_at,
      expires_at: r.expires_at,
      last_used_at: null,
      token: m.secret,
    };
  }
}
