import { canonicalJson } from './canonical-json';
import { condaNameOf } from './names';
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

/**
 * Conda MatchSpec text for a dependency: its conda name (`mojo-<name>` for a flat name, `mojo-<namespace>.<name>` for a
 * full one, spec/channel.md "Package naming") with the range, or the conda name alone.
 */
const depSpec = (d: { name: string; range?: string }) => (d.range ? `${condaNameOf(d.name)} ${d.range}` : condaNameOf(d.name));

function dependsOf(r: VersionRecord): string[] {
  const specs = [
    `${COMPILER_PACKAGE} ${r.requires_mojo}`,
    ...r.deps.map(depSpec),
    // The system libraries the package loads, exactly as its index.json requires them. The libraries it ships (`native`) are
    // not conda packages and are never named here.
    ...(r.native_depends ?? []),  ];
  return [...new Set(specs)].sort();
}

/**
 * repodata.json text for one subdir of one channel (spec/channel.md). The caller passes the records of that channel
 * only (src/channel-paths.ts): a namespace's packages, or the flat names at the root. A pure function of the records: `published`
 * records of the subdir are listed under `packages.conda`; `yanked` ones leave it and are listed under
 * `removed` (the files stay downloadable), and so do `tombstoned` ones (their bytes are gone; the name
 * tells a client the file was withdrawn); `pending` records appear nowhere. The
 * input order does not matter and nothing time-dependent is written.
 */
export function buildRepodataJson(subdir: Subdir, records: readonly VersionRecord[]): string {
  const conda = new Map<string, Entry>();
  const removed: string[] = [];
  const seen = new Set<string>();
  for (const r of records) {
    if (r.state === 'pending') continue;
    for (const f of r.files) {
      if (f.subdir !== subdir) continue;
      if (seen.has(f.filename)) throw new Error(`repodata: file ${f.filename} appears twice`);
      seen.add(f.filename);
      if (r.state === 'yanked' || r.state === 'tombstoned') {
        removed.push(f.filename);
        continue;
      }
      conda.set(f.filename, {
        build: r.build,
        build_number: 0,
        depends: dependsOf(r),
        name: condaNameOf(r.name),
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
