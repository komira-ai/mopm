import type { VersionRecord } from './types';

/**
 * The version rows exactly as stored. This is the only way to read the `versions` table, and it is not a reader of the
 * registry: a row of a group that has not committed is `pending` here, and one that has committed is still `pending`
 * until its flip. Only the store adapters and the group module (src/group.ts) may import this file; every other
 * reader goes through `Store.getVersion`, `Store.listVersions` or `Store.versionsOf`, which show the projection
 * (test/group-guards.test.ts scans for a file that does not).
 */
export interface RawVersionPort {
  /** One row by name and version (any spelling of the version), or undefined. A consistent read. */
  rawGet(name: string, version: string): Promise<VersionRecord | undefined>;
  /** Every row of one package, in no particular order. A consistent read. */
  rawQuery(name: string): Promise<VersionRecord[]>;
}
