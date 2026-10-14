import { hex, rec } from '../helpers';
import type { VersionRecord } from '../../src/types';

const B = 'mojo1.0.0_0';
const f = (subdir: string, name: string, version: string, sha: string, size: number) => ({
  subdir,
  filename: `mojo-${name}-${version}-${B}.conda`,
  sha256: hex(sha),
  size,
});

/** Input of the golden repodata files in this directory. */
export const GOLDEN_RECORDS: VersionRecord[] = [
  rec({ name: 'http_core', version: '1.2.0', files: [f('linux-64', 'http_core', '1.2.0', 'a', 1000), f('osx-arm64', 'http_core', '1.2.0', '9', 1001)] }),
  rec({
    name: 'http_client',
    version: '0.4.0',
    deps: [{ name: 'http_core', range: '>=1.2,<2' }],
    native: [{ id: 'openssl', soname: 'libssl.so.3' }],
    files: [f('linux-64', 'http_client', '0.4.0', 'b', 2048)],
  }),
  rec({ name: 'http_client', version: '0.3.0', state: 'yanked', yank_reason: 'broken', files: [f('linux-64', 'http_client', '0.3.0', 'c', 1500)] }),
  rec({
    name: 'tls',
    version: '1.0.0',
    state: 'tombstoned',
    tombstone: { reason_code: 'malware', date: '2026-10-12' },
    files: [f('linux-64', 'tls', '1.0.0', 'd', 700)],
  }),
  rec({ name: 'fresh', version: '2.0.0', state: 'pending', files: [f('linux-64', 'fresh', '2.0.0', 'e', 10)] }),
];
