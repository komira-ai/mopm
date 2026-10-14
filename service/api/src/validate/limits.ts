/** Size and shape caps. All are enforced while reading, so a hostile archive cannot make us allocate past them. */
export interface Limits {
  /** Bytes of the uploaded archive (the contract allows 50 MiB). */
  maxArchiveBytes: number;
  /** Bytes of any one unpacked file. */
  maxFileBytes: number;
  /** Bytes of all unpacked files together (both tars of a .conda). */
  maxUnpackedBytes: number;
  /** Entries (files and directories) over the whole package. */
  maxFiles: number;
  /** Unpacked bytes over compressed bytes of one compressed stream, applied once it is past `ratioFloorBytes`. */
  maxRatio: number;
  /** A stream below this many unpacked bytes is never judged by ratio (small, highly regular files are normal). */
  ratioFloorBytes: number;
  /** Bytes of `<name>.mopm.json` and `info/index.json`. */
  maxMetadataBytes: number;
}

export const DEFAULT_LIMITS: Limits = {
  maxArchiveBytes: 50 * 1024 * 1024,
  maxFileBytes: 128 * 1024 * 1024,
  maxUnpackedBytes: 200 * 1024 * 1024,
  maxFiles: 2000,
  maxRatio: 200,
  ratioFloorBytes: 1024 * 1024,
  maxMetadataBytes: 1024 * 1024,
};
