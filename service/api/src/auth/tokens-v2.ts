import type { NamespaceAccess } from './namespace-access';
import type { TokenMeta, TokenService } from './tokens';
import type { AuthStore } from './types';

/** `MeV2` of spec/api/openapi-v2.yaml. */
export interface MeV2 {
  github_id: number;
  handle: string;
  namespaces: Array<{ namespace: string; kind: 'user' | 'org'; role: 'owner' | 'admin' | 'member'; packages: string[] }>;
  unavailable_namespace?: string;
}

export interface TokenServiceV2Deps {
  tokens: TokenService;
  store: AuthStore;
  access: NamespaceAccess;
  /** The full names of the packages in a namespace, sorted. */
  packagesIn: (namespace: string) => Promise<string[]>;
}

/** `GET /api/v2/me` and `POST /api/v2/me/tokens` (docs/design/namespaces.md 2.4 and 8). */
export class TokenServiceV2 {
  constructor(readonly d: TokenServiceV2Deps) {}

  async me(_github_id: number): Promise<MeV2> {
    throw new Error('TokenServiceV2.me: not implemented');
  }

  async create(_github_id: number, _input: unknown): Promise<TokenMeta & { token: string }> {
    throw new Error('TokenServiceV2.create: not implemented');
  }
}
