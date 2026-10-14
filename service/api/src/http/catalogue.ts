import type { ErrorCode } from '../errors';

/**
 * The message and hint templates of the error codes the read API answers with. They are copied from the
 * `x-mopm-errors` table of spec/api/openapi.yaml; the contract fixtures in tests/contract/api carry the
 * rendered text and service/api/test/http/replay.test.ts compares byte for byte, so a drift fails there.
 */
export const CATALOGUE: Partial<Record<ErrorCode, { message: string; hint: string }>> = {
  invalid_request: {
    message: 'The request is not valid: {detail}.',
    hint: 'Check the request against the API documentation; update mopm if it is old.',
  },
  invalid_name: {
    message: "'{name}' is not a valid package name.",
    hint: 'Names are lowercase letters, digits and underscores, 2 to 64 characters, starting with a letter.',
  },
  invalid_version: {
    message: "'{version}' is not a valid version.",
    hint: 'A version is MAJOR.MINOR.PATCH: three numbers separated by dots, such as 1.2.3. Suffixes such as rc1 are not supported.',
  },
  package_not_found: {
    message: "There is no package '{name}'.",
    hint: 'Check the spelling, or claim the name.',
  },
  version_not_found: {
    message: "'{name}' has no version '{version}'.",
    hint: "List the versions with 'mopm info {name}'.",
  },
  internal_error: {
    message: 'Something went wrong on our side.',
    hint: 'Try again; report the request id if it persists.',
  },
  unavailable: {
    message: 'The registry is temporarily unavailable.',
    hint: 'Try again shortly.',
  },
  route_not_found: {
    message: 'There is no such operation.',
    hint: 'Check the request against the API documentation; update mopm if it is old.',
  },
};

export function render(template: string, detail: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (_m, k: string) => detail[k] ?? '');
}
