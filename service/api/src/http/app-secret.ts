import { createPrivateKey } from 'node:crypto';
import { GitHubUnavailable, HttpGitHubAppApi, type GitHubAppApi, type GitHubInstallation, type GitHubOrgMembershipOf } from '../auth';
import type { SecretReader } from './oauth-secret';

/**
 * The registry's GitHub App credentials are one JSON secret per stage, `mopm/<stage>/github-app`, stored by
 * service/infra/access/lib/app-secret.ts: {"app_id": "123456", "private_key": "-----BEGIN RSA PRIVATE KEY-----..."}.
 * The name is derived from the stage (the same rule as `appSecretName` in service/infra/stacks/lib/config.ts, whose IAM grant
 * names it); nothing configures it.
 */
export const appSecretName = (stage: string): string => `mopm/${stage}/github-app`;

export interface AppSecretOptions {
  secretId: string;
  read: SecretReader;
  now?: () => number;
  /** How long a good answer is reused. */
  okTtlMs?: number;
  /** How long a failure is remembered, so a missing secret is not asked for on every request. */
  failTtlMs?: number;
}

/**
 * A GitHubAppApi whose credentials come from Secrets Manager on first use. While the secret is absent, unreadable or
 * malformed every call throws GitHubUnavailable (which the membership check turns into `unavailable`), so a stage
 * without the secret serves everything else. Nothing about the secret's content is logged or put in an error. The
 * underlying client (and its installation-token cache) lives as long as the credentials stay the same.
 */
export class SecretGitHubAppApi implements GitHubAppApi {
  private cached: { until: number; api?: GitHubAppApi; creds?: string } | undefined;
  private readonly now: () => number;
  private readonly okTtl: number;
  private readonly failTtl: number;

  constructor(
    private readonly o: AppSecretOptions,
    private readonly build: (creds: { appId: string; privateKey: string }) => GitHubAppApi = (c) => new HttpGitHubAppApi(c),
  ) {
    this.now = o.now ?? Date.now;
    this.okTtl = o.okTtlMs ?? 5 * 60_000;
    this.failTtl = o.failTtlMs ?? 30_000;
  }

  private async api(): Promise<GitHubAppApi> {
    const t = this.now();
    if (!this.cached || this.cached.until <= t) this.cached = await this.load(t, this.cached);
    if (!this.cached.api) throw new GitHubUnavailable('The registry has no usable GitHub App credentials.');
    return this.cached.api;
  }

  private async load(t: number, prev: { api?: GitHubAppApi; creds?: string } | undefined): Promise<{ until: number; api?: GitHubAppApi; creds?: string }> {
    const fail = (reason: string) => {
      console.error(JSON.stringify({ level: 'error', message: 'GitHub App secret unavailable', reason }));
      return { until: t + this.failTtl };
    };
    let raw: string | undefined;
    try {
      raw = await this.o.read(this.o.secretId);
    } catch (err) {
      return fail(`read failed: ${(err as { name?: string })?.name ?? 'error'}`);
    }
    if (raw === undefined) return fail('not stored');
    let parsed: { app_id?: unknown; private_key?: unknown };
    try {
      parsed = JSON.parse(raw) as typeof parsed;
    } catch {
      return fail('not JSON');
    }
    const appId = typeof parsed?.app_id === 'number' ? String(parsed.app_id) : parsed?.app_id;
    if (typeof appId !== 'string' || !/^[1-9][0-9]*$/.test(appId)) return fail('no usable app_id');
    if (typeof parsed.private_key !== 'string') return fail('no private_key');
    // The same credentials keep the same client, and with it the installation tokens it holds.
    if (prev?.api && prev.creds === raw) return { until: t + this.okTtl, api: prev.api, creds: raw };
    try {
      createPrivateKey(parsed.private_key);
      return { until: t + this.okTtl, api: this.build({ appId, privateKey: parsed.private_key }), creds: raw };
    } catch {
      return fail('private_key is not a usable key');
    }
  }

  async getInstallation(id: number): Promise<GitHubInstallation | undefined> {
    return (await this.api()).getInstallation(id);
  }
  async getOrgInstallation(org: string): Promise<GitHubInstallation | undefined> {
    return (await this.api()).getOrgInstallation(org);
  }
  async getUserById(installation_id: number, account_id: number) {
    return (await this.api()).getUserById(installation_id, account_id);
  }
  async getOrgMembership(installation_id: number, org: string, user: string): Promise<GitHubOrgMembershipOf | undefined> {
    return (await this.api()).getOrgMembership(installation_id, org, user);
  }
}
