import { packageRev } from '../index-files';
import type { Store } from '../store';
import { sendIndexPkg } from './indexer';
import type { Queue } from './ports';
import type { IndexMessage, IndexTakedownsMessage } from './types';

/**
 * After an operator has tombstoned a published version (a takedown), ask the index writer to bring everything
 * that shows it up to date: repodata of every subdir the package has files in (the file moves to `removed`),
 * the package's sparse-index file (state `tombstoned`, sha256 kept, no url) and `index/takedowns.json`.
 *
 * The tombstone itself comes first and is the truth; this only queues the rebuilds, and sending it again after a
 * crash is safe (every job re-reads the rows). Like a yank, a takedown needs no gate: an index that says
 * `tombstoned` while repodata still lists the file is not picked by the CLI.
 */
export async function queueTakedownIndex(d: { registry: Store; indexQueue: Queue }, name: string): Promise<void> {
  const rows = await d.registry.listVersions(name);
  const rev = packageRev(rows);
  const subdirs = [...new Set(rows.filter((r) => r.state === 'tombstoned').flatMap((r) => r.files.map((f) => f.subdir)))].sort();
  for (const subdir of subdirs) {
    const msg: IndexMessage = { type: 'index', subdir };
    await d.indexQueue.send({ body: JSON.stringify(msg), groupId: subdir, dedupId: `rebuild:takedown:${name}:${rev}:${subdir}` });
  }
  await sendIndexPkg(d, { name, rev });
  const all: IndexTakedownsMessage = { type: 'index_takedowns' };
  await d.indexQueue.send({ body: JSON.stringify(all), groupId: 'takedowns', dedupId: `takedowns:${name}:${rev}` });
}
