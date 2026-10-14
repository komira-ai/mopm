import { AuthError } from '../auth/errors';
import { RegistryError } from '../errors';
import { render } from '../http/catalogue';
import { PublishError } from './errors';

/**
 * The templates of every error the publish routes can answer with, copied from `x-mopm-errors` in
 * spec/api/openapi.yaml. test/publish/catalogue.test.ts compares each entry with the spec text, so a drift fails.
 */
export const PUBLISH_CATALOGUE: Record<string, { status: number; message: string; hint: string }> = {
  invalid_request: { status: 400, message: 'The request is not valid: {detail}.', hint: 'Check the request against the API documentation; update mopm if it is old.' },
  invalid_name: { status: 400, message: "'{name}' is not a valid package name.", hint: 'Names are lowercase letters, digits and underscores, 2 to 64 characters, starting with a letter.' },
  invalid_version: { status: 400, message: "'{version}' is not a valid version.", hint: 'A version is MAJOR.MINOR.PATCH: three numbers separated by dots, such as 1.2.3. Suffixes such as rc1 are not supported.' },
  upload_invalid: { status: 400, message: 'The upload does not match what was declared: {detail}.', hint: 'Begin a new upload with the real file name, sha256 and size.' },
  token_missing: { status: 401, message: 'This request needs a token.', hint: "Run 'mopm login' or pass a token." },
  token_unknown: { status: 401, message: 'The token is not recognised.', hint: "Create a new token with 'mopm token create', or run 'mopm login'." },
  token_expired: { status: 401, message: 'The token expired at {expires_at}.', hint: 'Create a new token.' },
  token_revoked: { status: 401, message: 'The token was revoked.', hint: 'Create a new token.' },
  scope_missing: { status: 403, message: "The token does not have the '{scope}' scope for '{name}'.", hint: 'Create a token with that scope and that package.' },
  not_owner: { status: 403, message: "You are not an owner of '{name}'.", hint: 'Ask an owner to invite you.' },
  limit_exceeded: { status: 403, message: "Adding this file would put '{name}' over its storage limit of {limit} bytes; {remaining} bytes are left.", hint: 'Yanked versions still count toward the limit; only a takedown frees space. Reduce the package size.' },
  package_not_found: { status: 404, message: "There is no package '{name}'.", hint: 'Check the spelling, or claim the name.' },
  version_not_found: { status: 404, message: "'{name}' has no version '{version}'.", hint: "List the versions with 'mopm info {name}'." },
  publish_not_found: { status: 404, message: 'There is no such publish.', hint: 'Publish ids are only valid for the caller who made them.' },
  version_exists: { status: 409, message: "'{name}' {version} already exists (sha256 {sha256}); versions are immutable.", hint: 'Publish a new version.' },
  invalid_transition: {
    status: 409,
    message: "Cannot {action} '{name}' {version}: it is {state}.",
    hint: 'Only a published version can be yanked, only a yanked version can be unyanked, and a tombstoned version never changes.',
  },
  upload_used: { status: 409, message: "The upload '{upload_id}' was already used.", hint: 'Begin a new upload.' },
  payload_too_large: { status: 413, message: 'The file is larger than the limit of {limit} bytes.', hint: 'Reduce the package size.' },
  rate_limited: { status: 429, message: 'Too many requests.', hint: 'Wait {retry_after} seconds; the Retry-After header says how long.' },
  internal_error: { status: 500, message: 'Something went wrong on our side.', hint: 'Try again; report the request id if it persists.' },
  read_only_mode: { status: 503, message: 'The registry is read-only right now; new uploads are refused.', hint: 'Installs still work. Try again later.' },
  unavailable: { status: 503, message: 'The registry is temporarily unavailable.', hint: 'Try again shortly.' },
};

export interface ErrorView {
  status: number;
  body: { error: { code: string; message: string; hint: string } };
  retryAfter?: number;
}

/** The contract's error body for an error thrown anywhere in the publish path. Unknown errors are internal_error. */
export function errorView(err: unknown): ErrorView {
  let code = 'internal_error';
  let detail: Record<string, string> = {};
  let retryAfter: number | undefined;
  if (err instanceof PublishError || err instanceof AuthError || err instanceof RegistryError) {
    code = err.code;
    detail = err.detail;
    if (err instanceof PublishError) retryAfter = err.retryAfter;
  }
  const entry = PUBLISH_CATALOGUE[code] ?? PUBLISH_CATALOGUE.internal_error!;
  if (!PUBLISH_CATALOGUE[code]) code = 'internal_error';
  return {
    status: entry.status,
    body: { error: { code, message: render(entry.message, detail), hint: render(entry.hint, detail) } },
    ...(retryAfter !== undefined ? { retryAfter } : {}),
  };
}
