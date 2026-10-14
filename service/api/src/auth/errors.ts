/** The subset of the API's stable error codes (spec/api/openapi.yaml, x-mopm-errors) the auth layer raises. */
export type AuthErrorCode =
  | 'invalid_request'
  | 'invalid_name'
  | 'invalid_version'
  | 'token_missing'
  | 'token_unknown'
  | 'token_expired'
  | 'token_revoked'
  | 'stale_session'
  | 'oidc_token_invalid'
  | 'scope_missing'
  | 'not_owner'
  | 'oidc_not_trusted'
  | 'device_code_unknown'
  | 'token_not_found'
  | 'unavailable';

export const AUTH_HTTP_STATUS: Record<AuthErrorCode, number> = {
  invalid_request: 400,
  invalid_name: 400,
  invalid_version: 400,
  token_missing: 401,
  token_unknown: 401,
  token_expired: 401,
  token_revoked: 401,
  stale_session: 401,
  oidc_token_invalid: 401,
  scope_missing: 403,
  not_owner: 403,
  oidc_not_trusted: 403,
  device_code_unknown: 404,
  token_not_found: 404,
  unavailable: 503,
};

/** Same shape as RegistryError (code, status, detail) so the router can answer both the same way. */
export class AuthError extends Error {
  readonly status: number;
  constructor(
    readonly code: AuthErrorCode,
    message: string,
    /** Values for the message template, e.g. scope, name, expires_at, detail. */
    readonly detail: Record<string, string> = {},
  ) {
    super(message);
    this.name = 'AuthError';
    this.status = AUTH_HTTP_STATUS[code];
  }
}

export const oidcInvalid = (detail: string) =>
  new AuthError('oidc_token_invalid', `The CI identity token was rejected: ${detail}.`, { detail });
