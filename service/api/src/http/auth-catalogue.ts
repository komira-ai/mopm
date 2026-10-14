import type { AuthErrorCode } from '../auth/errors';
import type { ErrorCode } from '../errors';
import { CATALOGUE } from './catalogue';

/**
 * Message and hint templates of the error codes only the auth routes answer with. Copied from the
 * `x-mopm-errors` table of spec/api/openapi.yaml; test/http/auth-catalogue.test.ts compares them with the spec
 * file itself, so a drift fails there.
 */
export const AUTH_CATALOGUE: Partial<Record<AuthErrorCode, { message: string; hint: string }>> = {
  invalid_version: {
    message: "'{version}' is not a valid version.",
    hint: 'Use digits separated by dots, with an optional a, b, rc or dev suffix.',
  },
  token_missing: { message: 'This request needs a token.', hint: "Run 'mopm login' or pass a token." },
  token_unknown: {
    message: 'The token is not recognised.',
    hint: "Create a new token with 'mopm token create', or run 'mopm login'.",
  },
  token_expired: { message: 'The token expired at {expires_at}.', hint: 'Create a new token.' },
  token_revoked: { message: 'The token was revoked.', hint: 'Create a new token.' },
  stale_session: { message: 'This action needs a login from the last 15 minutes.', hint: "Run 'mopm login' again." },
  oidc_token_invalid: {
    message: 'The CI identity token was rejected: {detail}.',
    hint: 'Check the audience and that the job has permission to request an identity token.',
  },
  scope_missing: {
    message: "The token does not have the '{scope}' scope for '{name}'.",
    hint: 'Create a token with that scope and that package.',
  },
  not_owner: { message: "You are not an owner of '{name}'.", hint: 'Ask an owner to invite you.' },
  oidc_not_trusted: {
    message: "No trusted publisher of '{name}' matches this CI identity.",
    hint: 'Register the repository, workflow and environment as a trusted publisher of the package.',
  },
  device_code_unknown: { message: 'The device code is not recognised.', hint: 'Start the login again.' },
  token_not_found: { message: 'There is no such token.', hint: "List yours with 'mopm token list'." },
};

/** The template for a code, from the read API's catalogue or the auth one. */
export const templateFor = (code: string): { message: string; hint: string } | undefined =>
  CATALOGUE[code as ErrorCode] ?? AUTH_CATALOGUE[code as AuthErrorCode];
