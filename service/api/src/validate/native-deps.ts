import type { ValidatorOptions } from './index';

/**
 * The native libraries a package may name in `depends` besides `mojo-*` packages: the conda packages that `mopm pack` maps
 * a native dependency to (`condaPackageFor` in src/core/conda.zig: lz4 -> lz4-c, z and zlib -> libzlib, bz2 -> bzip2,
 * lzma and xz -> liblzma, zstd -> zstd, snappy -> snappy, brotlidec -> libbrotlidec, sqlite3 and sqlite -> libsqlite),
 * so that what pack writes the registry accepts. The test test/validate/native-deps.test.ts reads conda.zig and holds
 * `NATIVE_DEP_CURRENT` equal to the map's outputs and to the roots of the pinned native catalog (toolchain/natives.txt),
 * so what the registry accepts and what `mopm lock` can pin cannot drift.
 */
export const NATIVE_DEP_CURRENT: readonly string[] = [
  'bzip2',
  'libbrotlidec',
  'liblzma',
  'libsqlite',
  'libzlib',
  'lz4-c',
  'snappy',
  'zstd',
];

/**
 * Names that earlier versions of `mopm pack` wrote and that are accepted still, because a package that is published
 * keeps its `depends`. They are neither an output of the map nor a root of the catalog (the test holds that): `xz` is
 * conda-forge's metapackage, which `mopm pack` used for lzma until it mapped lzma to `liblzma`, the package of the
 * runtime library. Remove a name from here only when no published package names it.
 */
export const NATIVE_DEP_LEGACY: readonly string[] = ['xz'];

export const NATIVE_DEP_ALLOWLIST: ReadonlySet<string> = new Set([...NATIVE_DEP_CURRENT, ...NATIVE_DEP_LEGACY]);

/** What the deployed validators (single and group, every stage) validate with. */
export const DEPLOYED_VALIDATOR_OPTIONS: ValidatorOptions = { allowedNativeDeps: NATIVE_DEP_ALLOWLIST };
