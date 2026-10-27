import type { ValidatorOptions } from './index';

/**
 * The native libraries a package may name in `depends` besides `mojo-*` packages: the conda packages that `mopm pack` maps
 * a native dependency to (`condaPackageFor` in src/core/conda.zig: lz4 -> lz4-c, z and zlib -> libzlib, bz2 -> bzip2,
 * lzma and xz -> xz, zstd -> zstd, snappy -> snappy, brotlidec -> libbrotlidec, sqlite3 and sqlite -> libsqlite). Exactly those names, so that what pack writes the registry accepts. The test
 * test/validate/native-deps.test.ts reads conda.zig and holds this list equal to the map's outputs and to the roots of the pinned native catalog (toolchain/natives.txt), so what the registry accepts and what `mopm lock` can pin cannot drift.
 */
export const NATIVE_DEP_ALLOWLIST: ReadonlySet<string> = new Set([
  'bzip2',
  'libbrotlidec',
  'libsqlite',
  'libzlib',
  'lz4-c',
  'snappy',
  'xz',
  'zstd',
]);

/** What the deployed validators (single and group, every stage) validate with. */
export const DEPLOYED_VALIDATOR_OPTIONS: ValidatorOptions = { allowedNativeDeps: NATIVE_DEP_ALLOWLIST };
