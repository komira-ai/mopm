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

/** The codes of the namespaces (docs/design/namespaces.md section 8) besides `unavailable`. */
export type NamespaceErrorCode =
  | 'invalid_namespace'
  | 'namespace_reserved'
  | 'namespace_not_found'
  | 'namespace_taken'
  | 'not_namespace_member'
  | 'not_namespace_owner'
  | 'not_org_admin'
  | 'github_account_mismatch'
  | 'last_owner'
  | 'member_not_found'
  | 'user_not_found';

export const NAMESPACE_HTTP_STATUS: Record<NamespaceErrorCode, number> = {
  invalid_namespace: 400,
  namespace_reserved: 403,
  namespace_not_found: 404,
  namespace_taken: 409,
  not_namespace_member: 403,
  not_namespace_owner: 403,
  not_org_admin: 403,
  github_account_mismatch: 403,
  last_owner: 409,
  member_not_found: 404,
  user_not_found: 404,
};

/** A refused read, write or registration in a namespace. Same shape as AuthError (code, status, detail), so a router answers both alike. */
export class NamespaceError extends Error {
  readonly status: number;
  constructor(
    readonly code: NamespaceErrorCode,
    message: string,
    /** The values of the message template: `namespace`, and `user` where the message names one. */
    readonly detail: Record<string, string>,
  ) {
    super(message);
    this.name = 'NamespaceError';
    this.status = NAMESPACE_HTTP_STATUS[code];
  }
}
