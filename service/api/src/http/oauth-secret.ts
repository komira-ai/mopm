import { AuthError } from '../auth/errors';

/** Reads a secret's string value; undefined when the secret does not exist. Rejects on any other failure. */
export type SecretReader = (secretId: string) => Promise<string | undefined>;

/**
 * The secret is JSON: {"client_id": "...", "client_secret": "..."}, stored by service/infra/access/lib/oauth-secret.ts,
 * one per stage (`mopm/<stage>/github-oauth`). The device flow needs only the client id; the client secret is stored
 * with it because GitHub issues them together, and is never read into memory here.
 */
export const oauthSecretName = (stage: string) => `mopm/${stage}/github-oauth`;

// The AWS SDK v3 is part of the Node.js 22 Lambda runtime (see api-stack.ts), so it is loaded by name at the moment it
// is first needed: the package takes no dependency on it, and a process that never reads the secret never loads it.
const SECRETS_MODULE: string = '@aws-sdk/client-secrets-manager';

export const readSecretFromAws: SecretReader = async (secretId) => {
  const sdk = await import(SECRETS_MODULE);
  const client = new sdk.SecretsManagerClient({});
  try {
    const out = await client.send(new sdk.GetSecretValueCommand({ SecretId: secretId }));
    return typeof out.SecretString === 'string' ? out.SecretString : undefined;
  } catch (err) {
    if ((err as { name?: string })?.name === 'ResourceNotFoundException') return undefined;
    throw err;
  }
};

export interface OAuthSecretOptions {
  secretId: string;
  read: SecretReader;
  now?: () => number;
  /** How long a good answer is reused. */
  okTtlMs?: number;
  /** How long a failure is remembered, so a missing secret is not asked for on every request. */
  failTtlMs?: number;
}

const CLIENT_ID = /^[A-Za-z0-9._-]{4,100}$/;

/**
 * Hands out the GitHub OAuth app's client id, or AuthError('unavailable') while it cannot (the secret is not stored
 * yet, is malformed, or cannot be read). Nothing about the secret's content is ever logged or put in an error.
 */
export class OAuthSecretSource {
  private cached: { until: number; id?: string } | undefined;
  private readonly now: () => number;
  private readonly okTtl: number;
  private readonly failTtl: number;

  constructor(private readonly o: OAuthSecretOptions) {
    this.now = o.now ?? Date.now;
    this.okTtl = o.okTtlMs ?? 5 * 60_000;
    this.failTtl = o.failTtlMs ?? 30_000;
  }

  async clientId(): Promise<string> {
    const t = this.now();
    if (!this.cached || this.cached.until <= t) this.cached = await this.load(t);
    if (this.cached.id === undefined) throw new AuthError('unavailable', 'The registry is temporarily unavailable.');
    return this.cached.id;
  }

  private async load(t: number): Promise<{ until: number; id?: string }> {
    const fail = (reason: string) => {
      console.error(JSON.stringify({ level: 'error', message: 'GitHub OAuth secret unavailable', reason }));
      return { until: t + this.failTtl };
    };
    let raw: string | undefined;
    try {
      raw = await this.o.read(this.o.secretId);
    } catch (err) {
      return fail(`read failed: ${(err as { name?: string })?.name ?? 'error'}`);
    }
    if (raw === undefined) return fail('not stored');
    let id: unknown;
    try {
      id = (JSON.parse(raw) as { client_id?: unknown }).client_id;
    } catch {
      return fail('not JSON');
    }
    if (typeof id !== 'string' || !CLIENT_ID.test(id)) return fail('no usable client_id');
    return { until: t + this.okTtl, id };
  }
}
