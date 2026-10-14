import { canonicalJson } from './canonical-json';
import type { Subdir, VersionRecord } from './types';
import { zstdFrame } from './zstd';

/**
 * The conda package that pins the compiler. The spec says "the exact compiler requirement" but not the
 * conda name (listed as a spec question in the PR); one constant to change.
 */
export const COMPILER_PACKAGE = 'mojo-compiler';

export interface RepodataFiles {
  /** repodata.json */
  json: Buffer;
  /** repodata.json.zst: the same bytes in a zstd frame */
  zst: Buffer;
}

interface Entry {
  build: string;
  build_number: 0;
  depends: string[];
  name: string;
  sha256: string;
  size: number;
  subdir: string;
  version: string;
}

/** Conda MatchSpec text for a dependency: `mojo-<name> <range>` or just `mojo-<name>`. */
const depSpec = (d: { name: string; range?: string }) => (d.range ? `mojo-${d.name} ${d.range}` : `mojo-${d.name}`);

function dependsOf(r: VersionRecord): string[] {
  const specs = [
    `${COMPILER_PACKAGE} ${r.requires_mojo}`,
    ...r.deps.map(depSpec),
    // Native libraries are named by their allow-list id, which is the conda package that provides them.
    ...r.native.map((n) => n.id),
  ];
  return [...new Set(specs)].sort();
}

/**
 * repodata.json text for one subdir (spec/channel.md). A pure function of the records: `published`
 * records of the subdir are listed under `packages.conda`; `yanked` ones leave it and are listed under
 * `removed` (the files stay downloadable); `pending` and `tombstoned` records appear nowhere. The
 * input order does not matter and nothing time-dependent is written.
 */
export function buildRepodataJson(subdir: Subdir, records: readonly VersionRecord[]): string {
  const conda = new Map<string, Entry>();
  const removed: string[] = [];
  const seen = new Set<string>();
  for (const r of records) {
    if (r.state !== 'published' && r.state !== 'yanked') continue;
    for (const f of r.files) {
      if (f.subdir !== subdir) continue;
      if (seen.has(f.filename)) throw new Error(`repodata: file ${f.filename} appears twice`);
      seen.add(f.filename);
      if (r.state === 'yanked') {
        removed.push(f.filename);
        continue;
      }
      conda.set(f.filename, {
        build: r.build,
        build_number: 0,
        depends: dependsOf(r),
        name: `mojo-${r.name}`,
        sha256: f.sha256,
        size: f.size,
        subdir: f.subdir,
        version: r.version,
      });
    }
  }
  return canonicalJson({
    info: { subdir },
    packages: {},
    'packages.conda': Object.fromEntries(conda),
    removed: removed.sort(),
  });
}

export function buildRepodata(subdir: Subdir, records: readonly VersionRecord[]): RepodataFiles {
  const json = Buffer.from(buildRepodataJson(subdir, records), 'utf8');
  return { json, zst: zstdFrame(json) };
}
