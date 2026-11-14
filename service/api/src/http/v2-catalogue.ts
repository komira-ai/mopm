import { AuthError, NamespaceError } from '../auth/errors';
import { RegistryError } from '../errors';
import { ERRORS, ERROR_REASONS, type ErrorCode, type ErrorEntry } from '../gen/registry-v2';
import type { ErrorView } from '../publish/catalogue';
import { PublishError } from '../publish/errors';
import { render } from './catalogue';

/**
 * The error catalogue of `/api/v2`: `ERRORS` of src/gen/registry-v2.ts, generated from the protos (`x-mopm-errors` of
 * spec/api/openapi-v2.yaml). test/http/v2-catalogue.test.ts compares every entry with the spec file.
 */
export const V2_CATALOGUE: Readonly<Record<string, ErrorEntry>> = ERRORS;

/**
 * The contract's error body for any error thrown under `/api/v2`, rendered from V2_CATALOGUE. An error of a code the
 * catalogue does not hold, or of no known class, is `internal_error`. A `name_reserved` error states `what` in its
 * detail; one that does not (a flat reserved name) says `reserved`.
 */
export function errorViewV2(err: unknown): ErrorView {
  let code = 'internal_error';
  let detail: Record<string, string> = {};
  let retryAfter: number | undefined;
  if (err instanceof PublishError || err instanceof AuthError || err instanceof RegistryError || err instanceof NamespaceError) {
    code = err.code;
    detail = err.detail;
    if (err instanceof PublishError) retryAfter = err.retryAfter;
  }
  if (!V2_CATALOGUE[code]) code = 'internal_error';
  const entry = V2_CATALOGUE[code]!;
  if (code === 'name_reserved' && detail.what === undefined) detail = { ...detail, what: 'reserved' };
  const reason = err instanceof PublishError && err.reason !== undefined && ERROR_REASONS[code as ErrorCode]?.includes(err.reason) ? err.reason : undefined;
  return {
    status: entry.status,
    body: { error: { code, message: render(entry.message, detail), hint: render(entry.hint, detail), ...(reason !== undefined ? { reason } : {}) } },
    ...(retryAfter !== undefined ? { retryAfter } : {}),
  };
}
