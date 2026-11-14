import { AuthError, NamespaceError } from '../auth/errors';
import { RegistryError } from '../errors';
import { PUBLISH_CATALOGUE, PUBLISH_REASONS, type ErrorView } from '../publish/catalogue';
import { PublishError } from '../publish/errors';
import { AUTH_CATALOGUE } from './auth-catalogue';
import { render } from './catalogue';

type Entry = { status: number; message: string; hint: string };

/** The auth-only codes, with the status `x-mopm-errors` gives them (the auth catalogue holds no status). */
const AUTH_STATUS: Record<string, number> = { stale_session: 401, oidc_token_invalid: 401, oidc_not_trusted: 403, device_code_unknown: 404, token_not_found: 404 };

/** Codes only v1's claim answers: `createPackage` answers 200 for a package that exists, and compares no names. */
const V1_ONLY: ReadonlySet<string> = new Set(['name_taken', 'name_too_similar']);

/**
 * The error catalogue of `/api/v2` (`x-mopm-errors` of spec/api/openapi-v2.yaml): v1's, with `name_reserved` saying why
 * (`'{name}' is {what}.`: `reserved`, or a module of the Mojo standard library) and the codes of the namespaces.
 * test/http/v2-catalogue.test.ts compares every entry with the spec file, so a drift fails there.
 */
export const V2_CATALOGUE: Record<string, Entry> = {
  ...Object.fromEntries(
    Object.entries(AUTH_CATALOGUE)
      .filter(([code]) => AUTH_STATUS[code] !== undefined)
      .map(([code, e]) => [code, { status: AUTH_STATUS[code]!, ...e! }]),
  ),
  ...Object.fromEntries(Object.entries(PUBLISH_CATALOGUE).filter(([code]) => !V1_ONLY.has(code))),
  // v1's hints name its claim and its owners; under v2 a package is created by publishing it, and the namespace is the owner.
  package_not_found: { status: 404, message: "There is no package '{name}'.", hint: 'Check the spelling; a package is created by publishing it.' },
  not_owner: { status: 403, message: "You are not an owner of '{name}'.", hint: 'Use a token of an account that can write the namespace.' },
  name_reserved: { status: 403, message: "'{name}' is {what}.", hint: 'Choose another name.' },
  invalid_namespace: {
    status: 400,
    message: "'{namespace}' is not a valid namespace.",
    hint: 'A namespace is a GitHub login in lower case: letters, digits and single hyphens, at most 39 characters.',
  },
  not_namespace_member: { status: 403, message: "You cannot write in '{namespace}'.", hint: "Ask an owner of '{namespace}' to run 'mopm org add {namespace} <your mopm username>'." },
  not_namespace_owner: { status: 403, message: "You are not an owner of '{namespace}'.", hint: "Ask an owner of '{namespace}'; 'mopm org list {namespace}' shows them." },
  not_org_admin: {
    status: 403,
    message: "You are not an active admin of the GitHub organization '{namespace}'.",
    hint: "An admin of the GitHub organization runs 'mopm org create {namespace}'; an organization that restricts OAuth apps approves the mopm registry first.",
  },
  github_account_mismatch: {
    status: 403,
    message: 'The GitHub account that approved is not the one logged in to mopm.',
    hint: "Approve with the GitHub account you logged in with, or run 'mopm login' with the other one.",
  },
  namespace_taken: { status: 409, message: "'{namespace}' is taken.", hint: 'Choose the namespace of another GitHub organization.' },
  last_owner: { status: 409, message: "'{user}' is the last owner of '{namespace}'.", hint: 'Make another member an owner first.' },
  member_not_found: { status: 404, message: "'{user}' is not a member of '{namespace}'.", hint: "List the members with 'mopm org list {namespace}'." },
  user_not_found: { status: 404, message: "There is no mopm user '{user}'.", hint: "A user gets their name at their first 'mopm login'." },
  namespace_reserved: { status: 403, message: "'{namespace}' is reserved.", hint: "Publish in an organization's namespace." },
  namespace_not_found: {
    status: 404,
    message: "There is no namespace '{namespace}'.",
    hint: "A user's namespace is made at their first 'mopm login'; an organization's by one of its admins.",
  },
};

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
  const reason = err instanceof PublishError && err.reason !== undefined && PUBLISH_REASONS[code]?.includes(err.reason) ? err.reason : undefined;
  return {
    status: entry.status,
    body: { error: { code, message: render(entry.message, detail), hint: render(entry.hint, detail), ...(reason !== undefined ? { reason } : {}) } },
    ...(retryAfter !== undefined ? { retryAfter } : {}),
  };
}
