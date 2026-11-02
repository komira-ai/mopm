import { invalidRequest } from './errors';

/**
 * `source_commit` of a commit request (spec/api/openapi.yaml CommitPublishRequest and the group commit member): the git commit
 * the version was built from, as the publisher states it. Optional; exactly 40 (SHA-1) or 64 (SHA-256) lowercase hex digits;
 * anything else (uppercase, another length, a non-hex character, a value that is not a string, `null`) is `invalid_request`.
 *
 * It is informational. The registry stores it once with the version and serves it back from `getVersion`; it does not verify
 * it against the archive or the publisher's identity, and never compares or orders versions by it.
 */
const SOURCE_COMMIT = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

/** The validated value of `body.source_commit`, or undefined when the field is absent. `what` names the owner in the error. */
export function parseSourceCommit(body: Record<string, unknown>, what = ''): string | undefined {
  const v = body.source_commit;
  if (v === undefined) return undefined;
  if (typeof v !== 'string' || !SOURCE_COMMIT.test(v)) {
    throw invalidRequest(`'source_commit'${what} is a git commit id: 40 or 64 lowercase hex digits`);
  }
  return v;
}
