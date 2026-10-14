import type { AuthStore, DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord } from './types';

const copy = <T>(v: T): T => structuredClone(v);

export class MemoryAuthStore implements AuthStore {
  private users = new Map<number, UserRecord>();
  private tokens = new Map<string, TokenRecord>(); // by id
  private logins = new Map<string, DeviceLoginRecord>();
  private trusted = new Map<string, TrustedPublisher[]>();

  async upsertUser(github_id: number, handle: string, now: string, two_factor?: boolean) {
    const old = this.users.get(github_id);
    const rec: UserRecord = { github_id, handle, created_at: old?.created_at ?? now, last_login_at: now };
    if (two_factor !== undefined) rec.two_factor = two_factor;
    this.users.set(github_id, rec);
    return copy(rec);
  }
  async getUser(github_id: number) {
    const u = this.users.get(github_id);
    return u && copy(u);
  }

  async putToken(rec: TokenRecord) {
    this.tokens.set(rec.id, copy(rec));
  }
  async getTokenByHash(hash: string) {
    for (const t of this.tokens.values()) if (t.hash === hash) return copy(t);
    return undefined;
  }
  async getToken(id: string) {
    const t = this.tokens.get(id);
    return t && copy(t);
  }
  async listTokens(github_id: number) {
    return [...this.tokens.values()].filter((t) => t.github_id === github_id).map(copy);
  }
  async revokeToken(id: string, at: string) {
    const t = this.tokens.get(id);
    if (t && !t.revoked_at) t.revoked_at = at;
  }
  async touchToken(id: string, at: string) {
    const t = this.tokens.get(id);
    if (t) t.last_used_at = at;
  }

  async putDeviceLogin(rec: DeviceLoginRecord) {
    this.logins.set(rec.id, copy(rec));
  }
  async getDeviceLogin(id: string) {
    const l = this.logins.get(id);
    return l && copy(l);
  }
  async setDevicePolled(id: string, at: string, interval: number) {
    const l = this.logins.get(id);
    if (l) {
      l.last_polled_at = at;
      l.interval = interval;
    }
  }
  async deleteDeviceLogin(id: string) {
    this.logins.delete(id);
  }

  async addTrustedPublisher(tp: TrustedPublisher) {
    const list = this.trusted.get(tp.name) ?? [];
    list.push(copy(tp));
    this.trusted.set(tp.name, list);
  }
  async listTrustedPublishers(name: string) {
    return (this.trusted.get(name) ?? []).map(copy);
  }
  async removeTrustedPublisher(name: string, id: string) {
    this.trusted.set(name, (this.trusted.get(name) ?? []).filter((t) => t.id !== id));
  }

  /** Test aid: every stored token row, to assert what is and is not persisted. */
  dumpTokens(): TokenRecord[] {
    return [...this.tokens.values()].map(copy);
  }
}
