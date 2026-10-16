// Runtime guards for read API responses: JSON from the network becomes a typed value or a DecodeError.
//
// Rules (the API is additive-only, spec/api/openapi.yaml):
//  - an unknown field is ignored (and not copied);
//  - an enum value this build does not know becomes 'unknown' (the raw string is kept for display where useful);
//  - a missing or mistyped required field is an error;
//  - an optional field of the wrong type is treated as absent;
//  - a file's subdir may be any string.

import type {
  Dep, FileRef, Health, Native, Owner, PackageInfo, PackageList, PackageSummary, Provenance, Tombstone,
  VersionDetail, VersionState, VersionSummary,
} from './types.js';

export class DecodeError extends Error {
  constructor(path: string, what: string) {
    super(`${path}: ${what}`);
    this.name = 'DecodeError';
  }
}

type Obj = Record<string, unknown>;

function obj(v: unknown, path: string): Obj {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new DecodeError(path, 'expected an object');
  return v as Obj;
}

function str(o: Obj, k: string, path: string): string {
  const v = o[k];
  if (typeof v !== 'string') throw new DecodeError(`${path}.${k}`, 'expected a string');
  return v;
}

function strOrNull(o: Obj, k: string, path: string): string | null {
  const v = o[k];
  if (v === null) return null;
  if (typeof v !== 'string') throw new DecodeError(`${path}.${k}`, 'expected a string or null');
  return v;
}

function num(o: Obj, k: string, path: string): number {
  const v = o[k];
  if (typeof v !== 'number' || !Number.isFinite(v)) throw new DecodeError(`${path}.${k}`, 'expected a number');
  return v;
}

function bool(o: Obj, k: string, path: string): boolean {
  const v = o[k];
  if (typeof v !== 'boolean') throw new DecodeError(`${path}.${k}`, 'expected a boolean');
  return v;
}

function arr<T>(o: Obj, k: string, path: string, each: (v: unknown, path: string) => T): T[] {
  const v = o[k];
  if (!Array.isArray(v)) throw new DecodeError(`${path}.${k}`, 'expected an array');
  return v.map((x, i) => each(x, `${path}.${k}[${i}]`));
}

function optStr(o: Obj, k: string): string | undefined {
  const v = o[k];
  return typeof v === 'string' ? v : undefined;
}

function optStrings(o: Obj, k: string): string[] | undefined {
  const v = o[k];
  return Array.isArray(v) && v.every((x) => typeof x === 'string') ? (v as string[]) : undefined;
}

function enumOf<T extends string>(o: Obj, k: string, path: string, known: readonly T[]): T | 'unknown' {
  const v = str(o, k, path);
  return (known as readonly string[]).includes(v) ? (v as T) : 'unknown';
}

/** Copies the optional keys that are present with the right type; absent and mistyped ones stay absent. */
function withOptional<T extends object>(base: T, extra: Partial<T>): T {
  for (const [k, v] of Object.entries(extra)) {
    if (v !== undefined) (base as Record<string, unknown>)[k] = v;
  }
  return base;
}

const VERSION_STATES = ['published', 'yanked', 'tombstoned'] as const;

function versionState(o: Obj, path: string): { state: VersionState; state_raw?: string } {
  const state = enumOf(o, 'state', path, VERSION_STATES);
  return state === 'unknown' ? { state, state_raw: str(o, 'state', path) } : { state };
}

/** Optional and nullable: a string or null is kept (null means yanked without a reason); anything else is absent. */
function yankReason(o: Obj): string | null | undefined {
  const v = o.yank_reason;
  return v === null || typeof v === 'string' ? v : undefined;
}

export function decodeHealth(v: unknown): Health {
  const o = obj(v, 'health');
  return {
    status: enumOf(o, 'status', 'health', ['ok'] as const),
    stage: enumOf(o, 'stage', 'health', ['beta', 'gamma', 'prod'] as const),
    api_version: str(o, 'api_version', 'health'),
    read_only: bool(o, 'read_only', 'health'),
  };
}

function decodeSummary(v: unknown, path: string): PackageSummary {
  const o = obj(v, path);
  return {
    name: str(o, 'name', path),
    latest: strOrNull(o, 'latest', path),
    description: strOrNull(o, 'description', path),
    updated_at: str(o, 'updated_at', path),
  };
}

export function decodePackageList(v: unknown): PackageList {
  const o = obj(v, 'list');
  return {
    packages: arr(o, 'packages', 'list', decodeSummary),
    next_cursor: strOrNull(o, 'next_cursor', 'list'),
  };
}

function decodeOwner(v: unknown, path: string): Owner {
  const o = obj(v, path);
  return { github_id: num(o, 'github_id', path), handle: str(o, 'handle', path) };
}

function decodeVersionSummary(v: unknown, path: string): VersionSummary {
  const o = obj(v, path);
  return withOptional<VersionSummary>(
    { version: str(o, 'version', path), ...versionState(o, path), published_at: str(o, 'published_at', path) },
    { yank_reason: yankReason(o) },
  );
}

export function decodePackageInfo(v: unknown): PackageInfo {
  const p = 'package';
  const o = obj(v, p);
  return withOptional<PackageInfo>(
    {
      name: str(o, 'name', p),
      state: enumOf(o, 'state', p, ['claimed', 'active'] as const),
      owners: arr(o, 'owners', p, decodeOwner),
      latest: strOrNull(o, 'latest', p),
      repository: strOrNull(o, 'repository', p),
      license: strOrNull(o, 'license', p),
      description: strOrNull(o, 'description', p),
      created_at: str(o, 'created_at', p),
      versions: arr(o, 'versions', p, decodeVersionSummary),
    },
    {
      display_name: optStr(o, 'display_name'),
      homepage: optStr(o, 'homepage'),
      keywords: optStrings(o, 'keywords'),
      readme: optStr(o, 'readme'),
    },
  );
}

function decodeDep(v: unknown, path: string): Dep {
  const o = obj(v, path);
  return withOptional<Dep>({ name: str(o, 'name', path) }, { range: optStr(o, 'range') });
}

function decodeNative(v: unknown, path: string): Native {
  const o = obj(v, path);
  return { id: str(o, 'id', path), soname: str(o, 'soname', path) };
}

function decodeFile(v: unknown, path: string): FileRef {
  const o = obj(v, path);
  return withOptional<FileRef>(
    {
      subdir: str(o, 'subdir', path),
      filename: str(o, 'filename', path),
      sha256: str(o, 'sha256', path),
      size: num(o, 'size', path),
    },
    { url: optStr(o, 'url') },
  );
}

function decodeProvenance(v: unknown, path: string): Provenance {
  const o = obj(v, path);
  return withOptional<Provenance>(
    { kind: enumOf(o, 'kind', path, ['none', 'oidc'] as const) },
    { repository: optStr(o, 'repository'), workflow_ref: optStr(o, 'workflow_ref') },
  );
}

function decodeTombstone(o: Obj): Tombstone | undefined {
  const t = o.tombstone;
  if (typeof t !== 'object' || t === null) return undefined;
  const r = (t as Obj).reason_code;
  const d = (t as Obj).date;
  return typeof r === 'string' && typeof d === 'string' ? { reason_code: r, date: d } : undefined;
}

export function decodeVersionDetail(v: unknown): VersionDetail {
  const p = 'version';
  const o = obj(v, p);
  return withOptional<VersionDetail>(
    {
      name: str(o, 'name', p),
      version: str(o, 'version', p),
      ...versionState(o, p),
      published_at: str(o, 'published_at', p),
      requires_mojo: str(o, 'requires_mojo', p),
      deps: arr(o, 'deps', p, decodeDep),
      native: arr(o, 'native', p, decodeNative),
      files: arr(o, 'files', p, decodeFile),
      manifest_sha256: str(o, 'manifest_sha256', p),
      provenance: decodeProvenance(o.provenance, `${p}.provenance`),
    },
    {
      yank_reason: yankReason(o),
      tombstone: decodeTombstone(o),
      published_by: optStr(o, 'published_by'),
      description: optStr(o, 'description'),
      license: optStr(o, 'license'),
      repository: optStr(o, 'repository'),
      homepage: optStr(o, 'homepage'),
      keywords: optStrings(o, 'keywords'),
      readme: optStr(o, 'readme'),
    },
  );
}
