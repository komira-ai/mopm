/**
 * Verdict codes of the package validator.
 *
 * `RejectionCode` is the contract's catalogue (spec/api/openapi.yaml, `RejectionCode`): what a client sees
 * in `PublishStatus.rejection_code`. `RuleCode` is finer and also stable: the exact rule that fired, for
 * logs, the `message` field and tests. Every RuleCode maps to exactly one RejectionCode.
 */
export type RejectionCode =
  | 'archive_invalid'
  | 'path_not_allowed'
  | 'limit_exceeded'
  | 'manifest_invalid'
  | 'filename_mismatch'
  | 'sha256_mismatch'
  | 'dependency_not_allowed';

export const RULE_TO_REJECTION = {
  // archive_invalid: not a package archive we can read
  not_an_archive: 'archive_invalid',
  archive_corrupt: 'archive_invalid',
  format_not_allowed: 'archive_invalid',
  conda_layout: 'archive_invalid',
  tar_header: 'archive_invalid',
  mojoc_missing: 'archive_invalid',
  // path_not_allowed: a path or entry type the registry never accepts
  path_absolute: 'path_not_allowed',
  path_traversal: 'path_not_allowed',
  path_unsafe: 'path_not_allowed',
  symlink: 'path_not_allowed',
  hardlink: 'path_not_allowed',
  special_file: 'path_not_allowed',
  duplicate_path: 'path_not_allowed',
  unicode_collision: 'path_not_allowed',
  bin_dir: 'path_not_allowed',
  link_script: 'path_not_allowed',
  layout_not_allowed: 'path_not_allowed',
  native_undeclared: 'path_not_allowed',
  // limit_exceeded
  archive_too_large: 'limit_exceeded',
  file_too_large: 'limit_exceeded',
  unpacked_too_large: 'limit_exceeded',
  too_many_files: 'limit_exceeded',
  compression_ratio: 'limit_exceeded',
  manifest_too_large: 'limit_exceeded',
  // manifest_invalid: metadata missing, malformed or inconsistent
  manifest_missing: 'manifest_invalid',
  manifest_json: 'manifest_invalid',
  manifest_schema: 'manifest_invalid',
  index_missing: 'manifest_invalid',
  index_invalid: 'manifest_invalid',
  name_mismatch: 'manifest_invalid',
  version_mismatch: 'manifest_invalid',
  subdir_mismatch: 'manifest_invalid',
  compiler_missing: 'manifest_invalid',
  compiler_mismatch: 'manifest_invalid',
  deps_mismatch: 'manifest_invalid',
  native_missing: 'manifest_invalid',
  native_path: 'manifest_invalid',
  // others
  filename_mismatch: 'filename_mismatch',
  sha256_mismatch: 'sha256_mismatch',
  manifest_sha256_mismatch: 'sha256_mismatch',
  dependency_not_allowed: 'dependency_not_allowed',
} as const satisfies Record<string, RejectionCode>;

export type RuleCode = keyof typeof RULE_TO_REJECTION;

/** Thrown inside the validator; `validatePackage` turns it into a verdict and never lets it escape. */
export class ValidationFailure extends Error {
  constructor(
    readonly rule: RuleCode,
    message: string,
    readonly path?: string,
  ) {
    super(message);
    this.name = 'ValidationFailure';
  }
  get rejection(): RejectionCode {
    return RULE_TO_REJECTION[this.rule];
  }
}

export function fail(rule: RuleCode, message: string, path?: string): never {
  throw new ValidationFailure(rule, message, path);
}
