// Read API response shapes as the site sees them (spec/api/openapi.yaml, read operations).
//
// The API is additive-only: unknown fields are ignored and an enum value this build does not know decodes as
// 'unknown'. Fields the spec defines but the server never sends (display_name, manifest, readme_html), and the
// optional display metadata (homepage, keywords, readme), are optional here. readme_html is never read.

export type Unknown = 'unknown';

export interface Health {
  status: 'ok' | Unknown;
  stage: 'beta' | 'gamma' | 'prod' | Unknown;
  api_version: string;
  read_only: boolean;
}

export interface PackageSummary {
  name: string;
  latest: string | null;
  description: string | null;
  updated_at: string;
}

export interface PackageList {
  packages: PackageSummary[];
  next_cursor: string | null;
}

export interface Owner {
  github_id: number;
  handle: string;
}

export type VersionState = 'published' | 'yanked' | 'tombstoned' | Unknown;

export interface VersionSummary {
  version: string;
  state: VersionState;
  /** The raw state string when state is 'unknown', for display. */
  state_raw?: string;
  published_at: string;
  yank_reason?: string | null;
}

export interface PackageInfo {
  name: string;
  display_name?: string;
  state: 'claimed' | 'active' | Unknown;
  owners: Owner[];
  latest: string | null;
  repository: string | null;
  license: string | null;
  description: string | null;
  created_at: string;
  versions: VersionSummary[];
  homepage?: string;
  keywords?: string[];
  readme?: string;
}

export interface Dep {
  name: string;
  range?: string;
}

export interface Native {
  id: string;
  soname: string;
}

export interface FileRef {
  /** Any string: new subdirs may be added without a new API version. */
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
  url?: string;
}

export interface Provenance {
  kind: 'none' | 'oidc' | Unknown;
  repository?: string;
  workflow_ref?: string;
}

export interface Tombstone {
  reason_code: string;
  date: string;
}

export interface VersionDetail {
  name: string;
  version: string;
  state: VersionState;
  state_raw?: string;
  yank_reason?: string | null;
  tombstone?: Tombstone;
  published_at: string;
  published_by?: string;
  requires_mojo: string;
  deps: Dep[];
  native: Native[];
  files: FileRef[];
  manifest_sha256: string;
  provenance: Provenance;
  description?: string;
  license?: string;
  repository?: string;
  homepage?: string;
  keywords?: string[];
  readme?: string;
}
