import { API_VIEW, type GroupMembers } from '../group';
import type { GroupRecord, GroupStore } from '../group-store';
import type { Store } from '../store';
import type { VersionRecord } from '../types';
import { quarantineKeyFor, uploadIdFor } from './group-keys';
import type { ObjectStore } from './ports';

/**
 * The files of each member of a group, for GET /groups/{group_id} (spec/api/openapi.yaml: getGroup, `Group.members[].files`).
 *
 * The declared facts (subdir, filename, sha256, size) are those of the member's version row while the row is the group's
 * (`group_id` is the group, whatever its state): the row the create reserved holds exactly what the caller declared. A member
 * whose row is no longer the group's, because the group ended and another group or publish took the number, or whose row
 * does not exist yet, has no files here; its list is empty.
 *
 * `uploaded` says whether the declared bytes are in quarantine at the declared size (the stat a create makes). It is read only
 * while the group is `open`, and only for the first `limits.members` members and `limits.files` files of each, the caps
 * a create enforces: the read costs at most one stat per declared file of a group that was admitted under those caps. For any other status it is
 * omitted, because the bytes have been or will be moved and the answer would mean something else.
 */

export interface GroupFileFact {
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
  uploaded?: boolean;
}

export interface GroupReadDeps {
  registry: Store & GroupStore;
  /** Only `head` is used. */
  objects: Pick<ObjectStore, 'head'>;
}

export interface GroupReadLimits {
  members: number;
  files: number;
}

const BATCH = 16;

/** One list per member of `members`, in their order. */
export async function readMemberFiles(d: GroupReadDeps, header: GroupRecord, members: GroupMembers, limits: GroupReadLimits): Promise<GroupFileFact[][]> {
  const gid = header.group_id;
  const capped = members.members.slice(0, limits.members);
  const rows = await d.registry.versionsOf(
    capped.map((m) => m.name),
    API_VIEW,
  );
  const open = header.status === 'open';
  const facts = capped.map((m) => {
    const row = rows.get(m.name)?.find((r: VersionRecord) => r.canonical === m.canonical && r.group_id === gid);
    return (row?.files ?? []).slice(0, limits.files).map((f): GroupFileFact => ({ subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.size }));
  });
  if (open) {
    const todo = capped.flatMap((m, i) => facts[i]!.map((f) => ({ f, key: quarantineKeyFor(uploadIdFor(gid, m, f), f.filename) })));
    for (let i = 0; i < todo.length; i += BATCH) {
      const batch = todo.slice(i, i + BATCH);
      const stats = await Promise.all(batch.map((t) => d.objects.head(t.key)));
      batch.forEach((t, j) => {
        t.f.uploaded = stats[j]?.size === t.f.size;
      });
    }
  }
  // Members past the cap (none, for a group the create admitted) get an empty list.
  return members.members.map((_m, i) => facts[i] ?? []);
}
