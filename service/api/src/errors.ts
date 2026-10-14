/** The subset of the API's stable error codes (spec/api/openapi.yaml, x-mopm-errors) this package raises. */
export type ErrorCode =
  | 'invalid_version'
  | 'version_exists'
  | 'version_not_found'
  | 'package_not_found'
  | 'name_taken'
  | 'owner_not_found'
  | 'already_owner'
  | 'internal_error';

export const HTTP_STATUS: Record<ErrorCode, number> = {
  invalid_version: 400,
  version_exists: 409,
  version_not_found: 404,
  package_not_found: 404,
  name_taken: 409,
  owner_not_found: 404,
  already_owner: 409,
  internal_error: 500,
};

export class RegistryError extends Error {
  readonly status: number;
  constructor(
    readonly code: ErrorCode,
    message: string,
    /** Values for the message template, e.g. name, version, sha256. */
    readonly detail: Record<string, string> = {},
  ) {
    super(message);
    this.name = 'RegistryError';
    this.status = HTTP_STATUS[code];
  }
}

export const versionExists = (name: string, version: string, sha256: string) =>
  new RegistryError('version_exists', `'${name}' ${version} already exists (sha256 ${sha256}); versions are immutable.`, {
    name,
    version,
    sha256,
  });
