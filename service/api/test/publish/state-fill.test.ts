import { applyEvent, type PublishFill } from '../../src/state';
import { MemoryStore } from '../../src/memory-store';
import { audit, rec } from '../helpers';

const pending = () => rec({ name: 'p', version: '1.0.0', state: 'pending', build: '', requires_mojo: '', files: [], manifest_sha256: 'a'.repeat(64) });
const fill: PublishFill = {
  version: '1.0.0',
  build: 'mojo1.0.0_0',
  requires_mojo: '==1.0.0',
  deps: [{ name: 'json', range: '>=1' }],
  native: [{ id: 'openssl', soname: 'libssl.so.3' }],
  files: [{ subdir: 'noarch', filename: 'mojo-p-1.0.0-mojo1.0.0_0.conda', sha256: 'b'.repeat(64), size: 5, url: 'https://c.invalid/x' }],
  manifest_sha256: 'c'.repeat(64),
  published_at: '2026-10-14T12:30:00Z',
  published_by: 'octo',
};

describe('pending -> published carries what the validator learned', () => {
  test('the fill replaces the placeholders of the reserved number; the number, spelling and canonical key are kept as given by the fill', () => {
    const out = applyEvent(pending(), { type: 'publish', fill });
    expect(out).toMatchObject({ ...fill, state: 'published', rev: 1, name: 'p', canonical: '1.0.0' });
  });

  test('without a fill the event changes only the state, as before', () => {
    const out = applyEvent(pending(), { type: 'publish' });
    expect(out).toMatchObject({ state: 'published', build: '', files: [], rev: 1 });
  });

  test('publishing a published version is a no-op even with a different fill: the first publish wins', () => {
    const once = applyEvent(pending(), { type: 'publish', fill });
    const twice = applyEvent(once, { type: 'publish', fill: { ...fill, build: 'mojo9.9.9_0' } });
    expect(twice).toBe(once);
    expect(twice.build).toBe('mojo1.0.0_0');
  });

  test('through the store: the fill is persisted with its audit entry, and it is found by its version', async () => {
    const s = new MemoryStore();
    await s.createVersion(pending(), audit('p', 'publish_begin', '1.0.0'));
    const out = await s.updateVersion('p', '1.0.0', { type: 'publish', fill }, audit('p', 'publish', '1.0.0'));
    expect(out).toMatchObject({ state: 'published', version: '1.0.0', build: 'mojo1.0.0_0' });
    expect((await s.getVersion('p', '1.0.0'))?.files[0]?.sha256).toBe('b'.repeat(64));
    expect(await s.listAudit('p')).toHaveLength(2);
  });
});

describe('pending -> tombstoned for a rejected publish', () => {
  const tomb = { type: 'tombstone' as const, reason_code: 'archive_invalid', date: '2026-10-14' };
  const declared = () => ({ ...pending(), files: [{ subdir: 'noarch', filename: 'f.conda', sha256: 'd'.repeat(64), size: 3 }] });

  test('unpublished: no file was ever published, so none is kept; the number is burned', () => {
    const out = applyEvent(declared(), { ...tomb, unpublished: true });
    expect(out.state).toBe('tombstoned');
    expect(out.files).toEqual([]);
    expect(out.tombstone).toEqual({ reason_code: 'archive_invalid', date: '2026-10-14' });
  });

  test('without the flag a tombstone keeps the file hashes, as a takedown does (the existing rule)', () => {
    const out = applyEvent(declared(), tomb);
    expect(out.files).toEqual([{ subdir: 'noarch', filename: 'f.conda', sha256: 'd'.repeat(64), size: 3 }]);
  });

  test('the flag does not clear the files of a version that was published', () => {
    const published = applyEvent(pending(), { type: 'publish', fill });
    const out = applyEvent(published, { ...tomb, unpublished: true });
    expect(out.files).toHaveLength(1);
    expect(out.files[0]).not.toHaveProperty('url');
  });
});
