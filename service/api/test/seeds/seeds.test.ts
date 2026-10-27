import * as fs from 'fs';
import * as path from 'path';
import { MemoryStore } from '../../src/memory-store';
import { applySeed, readSeed, registrySeedOf, SEED_DIR, seedNames } from './load';
import { LEGACY } from './legacy-recipes';

/**
 * The seed files are the replay recipes' states, as data. Two claims, both checked here:
 *
 * 1. Every seed that was made from a TypeScript builder (seeds/legacy-recipes.ts) holds exactly the contents that
 *    builder produced: loaded into a fresh store and read back through the Store port, the two are equal (audit
 *    row ids aside: the builders number them with a counter that depends on which test ran first).
 * 2. Every seed file is one the tests use, and every name a test uses has a file (no dead seed, no missing one).
 *
 * A failing seed prints what the builder produced in seed form (`ACTUAL`); that is how a seed file is made.
 */
/** Seeds written for the transcript scenarios; they have no TypeScript builder. */
const SCENARIO_SEEDS: string[] = ['auth_accounts', 'auth_fifty_tokens', 'bulk_1001_claimed', 'version_detail_group_published'];

const noIds = <T extends { versions: Array<{ audit: { id: string } }> }>(s: T): T => ({
  ...s,
  versions: s.versions.map((v) => ({ ...v, audit: { ...v.audit, id: '<id>' } })),
});

describe('seeds', () => {
  test.each(Object.keys(LEGACY))('%s equals the builder it was made from', async (name) => {
    const built = new MemoryStore();
    await LEGACY[name]!(built);
    const want = await registrySeedOf(built);
    if (!fs.existsSync(path.join(SEED_DIR, `${name}.json`))) {
      throw new Error(`no seed file for ${name}\n\nACTUAL ${name}:\n${JSON.stringify({ description: '', ...want }, null, 2)}\nEND ACTUAL ${name}`);
    }
    const loaded = new MemoryStore();
    await applySeed(readSeed(name), { registry: loaded });
    expect(noIds(await registrySeedOf(loaded))).toEqual(noIds(want));
  });

  test('the seed files are the legacy-built ones plus the scenario seeds listed here', () => {
    expect(seedNames()).toEqual([...Object.keys(LEGACY), ...SCENARIO_SEEDS].sort());
  });
});
