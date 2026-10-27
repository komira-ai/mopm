import {
  AuthError,
  type Authenticator,
  type DeviceLogin,
  type OidcExchange,
  type OidcExchangeInput,
  type Principal,
  type TokenService,
} from '../auth';
import { RegistryError } from '../errors';

/** The services behind the auth routes. */
export interface AuthServices {
  authn: Authenticator;
  tokens: TokenService;
  oidc: OidcExchange;
  /**
   * Device login needs the GitHub OAuth app's client id, which is read from Secrets Manager the first time it is
   * needed. Rejects with AuthError('unavailable') while the secret is not there.
   */
  devices(): Promise<DeviceLogin>;
}

/** What the router needs of a request, and what an auth operation answers with. */
export interface AuthRequest {
  method: string;
  /** The segments after /api/v1. */
  seg: string[];
  authorization?: string;
  body?: string;
}
export interface AuthResult {
  status: number;
  body?: unknown;
}

const MAX_BODY_BYTES = 64 * 1024;
/**
 * The CI exchange's body: 500 packages of the longest name (64) and version (128) the grammar allows are about 109 KB, and the
 * identity token comes with them, so a set of the most a group may hold is never refused for its size.
 */
export const MAX_EXCHANGE_BODY_BYTES = 128 * 1024;
const unavailable = () => new AuthError('unavailable', 'The registry is temporarily unavailable.');

function jsonBody(raw: string | undefined, maxBytes = MAX_BODY_BYTES): Record<string, unknown> {
  const bad = (detail: string) => new RegistryError('invalid_request', `The request is not valid: ${detail}.`, { detail });
  if (raw === undefined || raw === '') throw bad('a JSON body is required');
  if (raw.length > maxBytes) throw bad('the body is too large');
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    throw bad('the body is not valid JSON');
  }
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw bad('the body must be a JSON object');
  return v as Record<string, unknown>;
}

/** Errors that mean the tables are not there (yet) or not reachable by this role: the auth routes are unavailable, the read API is not. */
const STORE_NOT_READY = new Set(['ResourceNotFoundException', 'AccessDeniedException', 'UnrecognizedClientException']);

/**
 * The operations of spec/api/openapi.yaml for login, tokens and CI exchange. Returns undefined for a request that is
 * not one of them. `services` is undefined when the deployment has no auth wiring: every auth path then answers
 * `unavailable`, and nothing else is affected.
 */
export async function routeAuth(req: AuthRequest, services: AuthServices | undefined): Promise<AuthResult | undefined> {
  const { method, seg } = req;
  const post = method === 'POST';
  let op: (s: AuthServices) => Promise<AuthResult>;

  if (post && seg.length === 2 && seg[0] === 'auth' && seg[1] === 'device') {
    op = async (s) => ({ status: 200, body: await (await s.devices()).start(jsonBody(req.body) as { client: string }) });
  } else if (post && seg.length === 3 && seg[0] === 'auth' && seg[1] === 'device' && seg[2] === 'poll') {
    op = async (s) => ({ status: 200, body: await (await s.devices()).poll(jsonBody(req.body) as { device_code: string }) });
  } else if (post && seg.length === 3 && seg[0] === 'auth' && seg[1] === 'oidc' && seg[2] === 'exchange') {
    op = async (s) => ({ status: 200, body: await s.oidc.exchange(jsonBody(req.body, MAX_EXCHANGE_BODY_BYTES) as OidcExchangeInput) });
  } else if (seg.length === 2 && seg[0] === 'me' && seg[1] === 'tokens' && (post || method === 'GET')) {
    op = async (s) => {
      const github_id = s.authn.freshSession(await s.authn.authenticate(req.authorization));
      if (post) {
        const t = await s.tokens.create(github_id, jsonBody(req.body) as never);
        // The one response that carries the secret.
        return { status: 201, body: { id: t.id, name: t.name, token: t.token, scopes: t.scopes, packages: t.packages, expires_at: t.expires_at } };
      }
      return { status: 200, body: { tokens: await s.tokens.list(github_id) } };
    };
  } else if (method === 'DELETE' && seg.length === 3 && seg[0] === 'me' && seg[1] === 'tokens') {
    op = async (s) => {
      const p: Principal = await s.authn.authenticate(req.authorization);
      await s.tokens.revoke(s.authn.freshSession(p), seg[2]!);
      return { status: 204 };
    };
  } else {
    return undefined;
  }

  if (!services) throw unavailable();
  try {
    return await op(services);
  } catch (err) {
    const name = (err as { name?: string })?.name ?? '';
    if (STORE_NOT_READY.has(name)) {
      console.error(JSON.stringify({ level: 'error', message: 'auth store not ready', error: name }));
      throw unavailable();
    }
    throw err;
  }
}
