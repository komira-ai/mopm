// Pinned from the release v0.0.104 (komira-ai/mopm d0b9020), service/api/src/publish/group-commit.ts lines 29, 31 and 40-67: SHA256,
// isObject and parseGroupCommit, copied byte for byte after this header (see README.md here; the sha256 of this file is in
// SHA256SUMS). The imports are the only lines written here: they name the modules of the current tree that the released code
// imports by the same names, none of which has changed since the tag.
import type { GroupMembers } from '../../../src/group';
import { commitRequestHash, type CommitInput } from '../../../src/group-store';
import { parseDisplay } from '../../../src/publish/display';
import { invalidRequest } from '../../../src/publish/errors';
import { parseSourceCommit } from '../../../src/publish/source-commit';

const SHA256 = /^[0-9a-f]{64}$/;
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** The members' inputs of a commit request in the group's member order, and the hash that names them. Throws invalid_request. */
export function parseGroupCommit(members: GroupMembers, body: unknown): { inputs: CommitInput[]; hash: string } {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const list = body.members;
  if (!Array.isArray(list)) throw invalidRequest("'members' lists the manifest of each member of the group");
  const byName = new Map<string, CommitInput>();
  for (const m of list) {
    if (!isObject(m)) throw invalidRequest('a member is not a JSON object');
    const { name, manifest_sha256 } = m;
    if (typeof name !== 'string') throw invalidRequest("a member needs a 'name'");
    if (byName.has(name)) throw invalidRequest(`'${name}' appears twice`);
    if (manifest_sha256 !== undefined && (typeof manifest_sha256 !== 'string' || !SHA256.test(manifest_sha256))) throw invalidRequest(`'manifest_sha256' of '${name}' is 64 lowercase hex digits`);
    const display = parseDisplay(m);
    const source_commit = parseSourceCommit(m, ` of '${name}'`);
    byName.set(name, { name, ...(manifest_sha256 !== undefined ? { manifest_sha256 } : {}), ...(Object.keys(display).length > 0 ? { display } : {}), ...(source_commit !== undefined ? { source_commit } : {}) });
  }
  const inputs: CommitInput[] = [];
  for (const m of members.members) {
    const got = byName.get(m.name);
    if (!got) throw invalidRequest(`'members' has no entry for '${m.name}', a member of the group`);
    inputs.push(got);
    byName.delete(m.name);
  }
  const extra = [...byName.keys()][0];
  if (extra !== undefined) throw invalidRequest(`'${extra}' is not a member of the group`);
  return { inputs, hash: commitRequestHash(JSON.stringify(inputs)) };
}

