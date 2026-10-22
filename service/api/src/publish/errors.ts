/** Codes this module raises besides RegistryError and AuthError ones (all are in spec/api/openapi.yaml, x-mopm-errors). */
export type PublishErrorCode =
  | 'invalid_request'
  | 'upload_invalid'
  | 'package_not_found'
  | 'publish_not_found'
  | 'group_not_found'
  | 'group_not_open'
  | 'group_conflict'
  | 'group_commit_refused'
  | 'not_owner'
  | 'upload_used'
  | 'payload_too_large'
  | 'limit_exceeded'
  | 'rate_limited'
  | 'read_only_mode'
  | 'unavailable'
  | 'internal_error';

export class PublishError extends Error {
  constructor(
    readonly code: PublishErrorCode,
    message: string,
    /** Values for the message template. */
    readonly detail: Record<string, string> = {},
    /** Seconds, for `rate_limited` (the Retry-After header). */
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = 'PublishError';
  }
}

export const invalidRequest = (detail: string) => new PublishError('invalid_request', `The request is not valid: ${detail}.`, { detail });
export const uploadInvalid = (detail: string) => new PublishError('upload_invalid', `The upload does not match what was declared: ${detail}.`, { detail });
export const groupNotFound = () => new PublishError('group_not_found', 'There is no such group.');
export const groupNotOpen = (groupId: string, status: string) =>
  new PublishError('group_not_open', `Group ${groupId} is ${status}; only an open group can be aborted.`, { group_id: groupId, status });
export const groupConflict = (detail: string) => new PublishError('group_conflict', `The group cannot be created: ${detail}.`, { detail });
export const groupCommitRefused = (detail: string) => new PublishError('group_commit_refused', `The group cannot be committed: ${detail}.`, { detail });
