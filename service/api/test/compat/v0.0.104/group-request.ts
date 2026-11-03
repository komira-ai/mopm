// Pinned from the release v0.0.104 (komira-ai/mopm d0b9020), service/api/src/publish/group-service.ts lines 63-131: the request
// types, MAX_FILES_PER_MEMBER, isObject, fileKey, parseGroupRequest and groupIdFor, copied byte for byte after this header (see
// README.md here; the sha256 of this file is in SHA256SUMS). The imports are the only lines written here: they name the modules
// of the current tree that the released code imports by the same names, none of which has changed since the tag
// (`git diff v0.0.104 -- service/api/src` lists only the group service, the commit, the keys, the router and the new readme module).
import { createHash } from 'node:crypto';
import { NAME_PATTERN } from '../../../src/auth';
import { RegistryError } from '../../../src/errors';
import { canonicalVersion } from '../../../src/version';
import type { PublishConfig } from '../../../src/publish/config';
import { invalidRequest } from '../../../src/publish/errors';
import { parseFileFacts } from '../../../src/publish/service';

export interface GroupFileRequest {
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
}
export interface GroupMemberRequest {
  name: string;
  version: string;
  canonical: string;
  /** Sorted by subdir and file name. */
  files: GroupFileRequest[];
}
/** What a create does when the caller's own open groups share a version with the new set. */
export type OnOverlap = 'supersede' | 'refuse';

/** The declared set, members sorted by package name. `onOverlap` is an option of the call, not part of the set: it is not in the group id. */
export interface GroupRequest {
  members: GroupMemberRequest[];
  onOverlap?: OnOverlap;
}

const MAX_FILES_PER_MEMBER = 20;
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const fileKey = (f: Pick<GroupFileRequest, 'subdir' | 'filename'>) => `${f.subdir}/${f.filename}`;

/** The request body as a GroupRequest, or invalid_request (and the errors a single begin raises for a file). */
export function parseGroupRequest(config: PublishConfig, body: unknown): GroupRequest {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { members, on_overlap: onOverlap } = body;
  if (onOverlap !== undefined && onOverlap !== 'supersede' && onOverlap !== 'refuse') throw invalidRequest("'on_overlap' is 'supersede' or 'refuse'");
  if (!Array.isArray(members) || members.length < 1) throw invalidRequest("'members' lists at least one member");
  if (members.length > config.groupMaxMembers) throw invalidRequest(`a group has at most ${config.groupMaxMembers} members`);
  const names = new Set<string>();
  const out: GroupMemberRequest[] = [];
  let bytes = 0;
  for (const m of members) {
    if (!isObject(m)) throw invalidRequest('a member is not a JSON object');
    const { name, version, files } = m;
    if (typeof name !== 'string' || typeof version !== 'string') throw invalidRequest("a member needs a 'name' and a 'version', both strings");
    if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    const canonical = canonicalVersion(version); // throws invalid_version
    if (names.has(name)) throw invalidRequest(`'${name}' appears twice: a group has one version of each package`);
    names.add(name);
    if (!Array.isArray(files) || files.length < 1 || files.length > MAX_FILES_PER_MEMBER) {
      throw invalidRequest(`'files' of '${name}' holds 1 to ${MAX_FILES_PER_MEMBER} files`);
    }
    const seen = new Set<string>();
    const facts = files.map((f) => {
      const one = parseFileFacts(config, name, version, f);
      if (seen.has(fileKey(one))) throw invalidRequest(`'${name}' lists the file ${fileKey(one)} twice`);
      seen.add(fileKey(one));
      bytes += one.size;
      return one;
    });
    out.push({ name, version, canonical, files: facts.sort((a, b) => (fileKey(a) < fileKey(b) ? -1 : 1)) });
  }
  if (bytes > config.groupMaxBytes) throw invalidRequest(`the files total ${bytes} bytes; a group holds at most ${config.groupMaxBytes}`);
  return { members: out.sort((a, b) => (a.name < b.name ? -1 : 1)), ...(onOverlap !== undefined ? { onOverlap } : {}) };
}

/**
 * Deterministic: the same actor declaring the same set gets the same id, whatever the order of the members and files in
 * the request. A different set, or another actor, is another group.
 */
export function groupIdFor(actor: string, req: GroupRequest): string {
  const set = req.members.map((m) => [m.name, m.canonical, m.files.map((f) => [f.subdir, f.filename, f.sha256, f.size])]);
  return `grp_${createHash('sha256').update(JSON.stringify([actor, set])).digest('hex').slice(0, 32)}`;
}
