import type { ValidatorOptions } from './index';

/**
 * The native libraries a package may name in `depends` besides `mojo-*` packages: the conda packages that `mopm pack` maps
 * a native dependency to (`condaPackageFor` in src/core/conda.zig: lz4 -> lz4-c, z and zlib -> libzlib, bz2 -> bzip2,
 * lzma and xz -> xz, zstd -> zstd). Exactly those names, so that what pack writes the registry accepts. The test
 * test/validate/native-deps.test.ts reads conda.zig and holds this list equal to the map's outputs.
 */
export const NATIVE_DEP_ALLOWLIST: ReadonlySet<string> = new Set(['bzip2', 'libzlib', 'lz4-c', 'xz', 'zstd']);

/** What the deployed validators (single and group, every stage) validate with. */
export const DEPLOYED_VALIDATOR_OPTIONS: ValidatorOptions = { allowedNativeDeps: NATIVE_DEP_ALLOWLIST };
