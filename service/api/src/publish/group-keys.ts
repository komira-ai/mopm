import { createHash } from 'node:crypto';

/**
 * The names a group derives from what it declares, so that a resumed create, the commit and the validator all find the
 * same upload record and the same quarantine object without storing them anywhere else.
 */

/** A group id: `grp_` and 32 hex digits (`groupIdFor`, src/publish/group-service.ts). */
export const GROUP_ID = /^grp_[0-9a-f]{32}$/;

/** Id of the upload record of one declared file of a member of a group. */
export const uploadIdFor = (gid: string, m: { name: string; canonical: string }, f: { subdir: string; filename: string; sha256: string }): string =>
  `upl_g${createHash('sha256').update(JSON.stringify([gid, m.name, m.canonical, f.subdir, f.filename, f.sha256])).digest('hex').slice(0, 31)}`;

/** Where the bytes of that upload are put: the quarantine prefix, which the channel's lifecycle empties after a day. */
export const quarantineKeyFor = (uploadId: string, filename: string): string => `quarantine/${uploadId}/${filename}`;
