import { DEPLOYED_VALIDATOR_OPTIONS } from '../../src/validate/native-deps';
import { Harness, pkg } from './harness';

/**
 * What repodata says a package depends on, after the whole publish: the validator reads the package, the row is written,
 * the indexer writes repodata. A package ships native libraries (static archives, which are not conda packages) and may
 * load system libraries (which are); only the second kind is a conda dependency.
 */
async function publish(over: Parameters<typeof pkg>[0]) {
  const h = new Harness();
  h.validatorDeps.validatorOptions = DEPLOYED_VALIDATOR_OPTIONS;
  const me = await h.account(1, 'a', [over?.name ?? 'demo']);
  const p = pkg(over);
  const u = await h.upload(me.token, p);
  const res = await h.commit(me.token, p.name, p.version, [u.upload_id!], p.manifest, {});
  expect(res.statusCode).toBe(202);
  await h.runValidator();
  await h.runIndexer();
  const row = (await h.registry.getVersion(p.name, p.version))!;
  expect(row.state).toBe('published');
  const entries = Object.values(h.repodata(p.subdir)['packages.conda']) as unknown as Array<{ depends: string[] }>;
  expect(entries).toHaveLength(1);
  return { row, depends: entries[0]!.depends };
}

const STATIC = {
  mopm: { native: [{ id: 'komira_libc_posix', soname: 'libkomira_libc_posix.a', kind: 'static', mode: 'link', needs: [], static_file: '../libkomira_libc_posix.a' }] },
  pkgExtra: [{ path: 'lib/libkomira_libc_posix.a', data: '!<arch>\n' }],
};

describe('repodata depends of a package with native libraries', () => {
  test('a package that ships a static archive depends on the compiler alone: the archive is not a conda package', async () => {
    const { row, depends } = await publish({ name: 'demo', ...STATIC });
    expect(row.native.map((n) => n.id)).toEqual(['komira_libc_posix']);
    expect(depends).toEqual(['mojo-compiler ==1.0.0']);
  });

  test('a package that loads a system library depends on that conda package, with its range, as its index.json says', async () => {
    const { depends } = await publish({ name: 'demo', index: { depends: ['mojo-compiler ==1.0.0', 'lz4-c >=1.9.3,<2'] } });
    expect(depends).toEqual(['lz4-c >=1.9.3,<2', 'mojo-compiler ==1.0.0']);
  });

  test('a package that does both lists the loaded library only', async () => {
    const { depends } = await publish({ name: 'demo', ...STATIC, index: { depends: ['mojo-compiler ==1.0.0', 'zstd'] } });
    expect(depends).toEqual(['mojo-compiler ==1.0.0', 'zstd']);
  });
});
