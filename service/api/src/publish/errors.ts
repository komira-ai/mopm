/** Codes this module raises besides RegistryError and AuthError ones (all are in spec/api/openapi.yaml, x-mopm-errors). */
export type PublishErrorCode =
  | 'invalid_request'
  | 'upload_invalid'
  | 'package_not_found'
  | 'publish_not_found'
  | 'not_owner'
  | 'upload_used'
  | 'payload_too_large'
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
