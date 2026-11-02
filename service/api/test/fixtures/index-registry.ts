import { createHash } from 'crypto';
import { applyEvent } from '../../src/state';
import type { Dep, FileRef, NativeRef, VersionRecord } from '../../src/types';
import { rec } from '../helpers';

/**
 * The registry the CLI's end-to-end resolve test serves (tests/drivers/resolve_e2e_test.zig, its `packages`
 * table), as the version rows the service would hold. Versions the CLI ignores for their spelling
 * (`2.1.0b1`, `1.2.3.4`, `2.0.0-rc1`, `1.0`) are left out: the service refuses to store them.
 */
export const CHANNEL = 'https://conda.beta.mopm.dev';

const sha = (subdir: string, filename: string) => createHash('sha256').update(`${subdir}/${filename}`).digest('hex');

export function fileOf(name: string, version: string, subdir: string, mojo = '1.0.0'): FileRef {
  const filename = `mojo-${name}-${version}-mojo${mojo}_0.conda`;
  return { subdir, filename, sha256: sha(subdir, filename), size: 4096, url: `${CHANNEL}/${subdir}/${filename}` };
}

interface V {
  ver: string;
  deps?: Dep[];
  mojo?: string;
  subdirs?: string[];
  native?: NativeRef[];
  yank?: string;
  tombstone?: boolean;
}

export function rows(name: string, versions: V[]): VersionRecord[] {
  return versions.map((v) => {
    const mojo = v.mojo ?? '1.0.0';
    let r = rec({
      name,
      version: v.ver,
      build: `mojo${mojo}_0`,
      requires_mojo: `==${mojo}`,
      deps: v.deps ?? [],
      native: v.native ?? [],
      files: (v.subdirs ?? ['linux-64']).map((s) => fileOf(name, v.ver, s, mojo)),
      manifest_sha256: sha('manifest', `${name}-${v.ver}`),
    });
    if (v.yank) r = applyEvent(r, { type: 'yank', reason: v.yank });
    if (v.tombstone) r = applyEvent(r, { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' });
    return r;
  });
}

const clientDeps: Dep[] = [
  { name: 'http_core', range: '>=1.2,<2' },
  { name: 'crypto', range: '2' },
];

export const FIXTURE_PACKAGES: Record<string, VersionRecord[]> = {
  http_client: rows('http_client', [
    { ver: '0.3.0', deps: clientDeps, yank: 'crashes on empty body' },
    { ver: '0.4.0', deps: clientDeps },
    { ver: '0.4.1', deps: clientDeps, mojo: '1.1.0' },
    { ver: '0.5.0', deps: clientDeps },
  ]),
  http_core: rows('http_core', [
    { ver: '1.2.4' },
    { ver: '1.2.5' },
    { ver: '1.2.6', yank: 'breaks keep-alive' },
    { ver: '1.4.0' },
    { ver: '2.0.0' },
  ]),
  // Files listed osx-first on purpose: the index orders them.
  crypto: rows('crypto', [{ ver: '2.0.1', subdirs: ['osx-arm64', 'linux-64'], native: [{ id: 'crypto', soname: 'libcrypto_native.a' }] }]),
  tls: rows('tls', [
    { ver: '1.0.0', tombstone: true },
    { ver: '1.1.0', deps: [{ name: 'http_core', range: '~1.2' }] },
    { ver: '1.2.0', tombstone: true },
  ]),
};

export const ALL_FIXTURE_ROWS: VersionRecord[] = Object.values(FIXTURE_PACKAGES).flat();
