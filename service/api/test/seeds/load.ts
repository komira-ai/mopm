import * as fs from 'fs';
import * as path from 'path';
import { hashToken, TOKEN_PREFIX } from '../../src/auth/tokens';
import type { AuthStore, TokenRecord, TrustedPublisher, UserRecord } from '../../src/auth';
import type { PublishStore } from '../../src/publish/ports';
import type { PublishRecord, UploadRecord } from '../../src/publish/types';
import type { Store } from '../../src/store';
import type { AuditEntry, OwnerRecord, PackageRecord, VersionRecord } from '../../src/types';

/**
 * Seeds: the contents of the stores before a request, as JSON files in `fixtures/seeds/`. A seed holds no code, so
 * another implementation of the registry loads the same files (see test/transcripts/README.md). The sections are
 * applied in this order: packages, owners, versions (each with the audit row written with it), users, tokens,
 * trusted publishers, uploads, publishes.
 *
 * A token is written with its secret, not its hash: `hash` and `prefix` are derived (SHA-256 of the secret, hex; the
 * first six characters after `mopm_` plus the prefix), so a scenario can send the bearer value it names.
 */
export interface Seed {
  description?: string;
  packages?: PackageRecord[];
  owners?: OwnerRecord[];
  versions?: Array<{ record: VersionRecord; audit: AuditEntry }>;
  users?: UserRecord[];
  tokens?: Array<{ secret: string; record: Omit<TokenRecord, 'hash' | 'prefix'> }>;
  trusted_publishers?: TrustedPublisher[];
  uploads?: UploadRecord[];
  publishes?: PublishRecord[];
}

export const SEED_DIR = path.join(__dirname, '..', 'fixtures', 'seeds');
export const readSeed = (name: string): Seed => JSON.parse(fs.readFileSync(path.join(SEED_DIR, `${name}.json`), 'utf8'));
export const seedNames = () => fs.readdirSync(SEED_DIR).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort();

export interface SeedTargets {
  registry?: Store;
  auth?: AuthStore;
  publishes?: PublishStore;
}

export async function applySeed(seed: Seed, t: SeedTargets): Promise<void> {
  const need = <T>(v: T | undefined, what: string): T => {
    if (v === undefined) throw new Error(`seed has ${what} but the world has no such store`);
    return v;
  };
  for (const p of seed.packages ?? []) await need(t.registry, 'packages').createPackage(p);
  for (const o of seed.owners ?? []) await need(t.registry, 'owners').addOwner(o);
  for (const v of seed.versions ?? []) await need(t.registry, 'versions').createVersion(v.record, v.audit);
  for (const u of seed.users ?? []) await need(t.auth, 'users').upsertUser(u.github_id, u.handle, u.created_at, u.two_factor);
  for (const tok of seed.tokens ?? []) {
    const hash = hashToken(tok.secret);
    await need(t.auth, 'tokens').putToken({ ...tok.record, hash, prefix: tok.secret.slice(0, TOKEN_PREFIX.length + 6) });
  }
  for (const tp of seed.trusted_publishers ?? []) await need(t.auth, 'trusted publishers').addTrustedPublisher(tp);
  for (const u of seed.uploads ?? []) await need(t.publishes, 'uploads').putUpload(u);
  for (const p of seed.publishes ?? []) await need(t.publishes, 'publishes').createPublish(p);
}

/** The registry part of a store as a seed (what `applySeed` was given, read back through the Store port). */
export async function registrySeedOf(registry: Store): Promise<Required<Pick<Seed, 'packages' | 'owners' | 'versions'>>> {
  const packages: PackageRecord[] = [];
  const owners: OwnerRecord[] = [];
  const pairs: Array<{ record: VersionRecord; audit: AuditEntry }> = [];
  for (const name of await registry.listPackageNames()) {
    packages.push((await registry.getPackage(name))!);
    owners.push(...(await registry.listOwners(name)));
    const audit = await registry.listAudit(name);
    for (const record of await registry.listVersions(name)) {
      const a = audit.find((e) => e.version === record.version);
      if (!a) throw new Error(`no audit row for ${name} ${record.version}`);
      pairs.push({ record, audit: a });
    }
  }
  // Audit rows are written in this order; the loader keeps it.
  pairs.sort((x, y) => (x.audit.id < y.audit.id ? -1 : 1));
  return { packages, owners, versions: pairs };
}
