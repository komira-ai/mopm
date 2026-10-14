import { Decompress } from 'fzstd';
import { fail, ValidationFailure } from './codes';
import type { Collector } from './collector';

const MAGIC = [0x28, 0xb5, 0x2f, 0xfd];

/** Decompress zstd `data` into `out`, which may stop it by throwing. A decode error is `archive_corrupt`. */
export function unzstd(data: Uint8Array, out: Collector, what: string): void {
  if (!MAGIC.every((m, i) => data[i] === m)) fail('archive_corrupt', `${what} is not a zstd stream`);
  try {
    const d = new Decompress((chunk) => out.push(chunk.slice()));
    d.push(data, true);
  } catch (e) {
    if (e instanceof ValidationFailure) throw e;
    fail('archive_corrupt', `${what} is not valid zstd`);
  }
}
