import { channelFileUrl } from '../../src/channel-paths';
import { condaNameOf } from '../../src/names';
import type { Dep, VersionRecord } from '../../src/types';
import { CHANNEL, FIXTURE_PACKAGES } from './index-registry';

/**
 * The registry of index-registry.ts again, with every package in the namespace `komira-ai` and every dependency a full
 * name: the version rows the service holds once packages are named `<namespace>/<name>`. A file is named by the conda
 * name (`mojo-komira-ai.<name>-...`) and lives in its namespace's channel (`<channel>/komira-ai/<subdir>/...`).
 */
export const NS = 'komira-ai';

const full = (name: string) => `${NS}/${name}`;

function inNamespace(r: VersionRecord): VersionRecord {
  const name = full(r.name);
  const deps: Dep[] = r.deps.map((d) => ({ ...d, name: full(d.name) }));
  const files = r.files.map((f) => {
    const filename = `${condaNameOf(name)}-${r.version}-${r.build}.conda`;
    return { ...f, filename, url: channelFileUrl(`${CHANNEL}/`, name, f.subdir as 'linux-64', filename) };
  });
  return { ...r, name, deps, files };
}

export const FIXTURE_PACKAGES_V2: Record<string, VersionRecord[]> = Object.fromEntries(
  Object.entries(FIXTURE_PACKAGES).map(([name, rs]) => [full(name), rs.map(inNamespace)]),
);

export const ALL_FIXTURE_ROWS_V2: VersionRecord[] = Object.values(FIXTURE_PACKAGES_V2).flat();

