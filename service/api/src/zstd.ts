/**
 * A valid zstd frame made only of raw (stored) blocks.
 *
 * Why not compress: the Node runtimes this code targets have no zstd in zlib, and a native or WASM compressor's output is not
 * promised stable across library versions, which would break "same records, same bytes" for the
 * `.zst` file. A raw-block frame is deterministic by construction, needs no dependency, and every
 * conformant decoder (libzstd, fzstd, the conda tools) reads it. The cost is size: the file is the
 * JSON plus 3 bytes per 128 KiB, and CloudFront still compresses on the wire. A real encoder can
 * replace this function without touching callers; the tests pin only that the frame decodes to the input.
 *
 * Frame: magic, descriptor 0x00 (no single-segment, no checksum, no dictionary, no content size),
 * window descriptor for a 128 KiB window, then blocks of at most 128 KiB, the last flagged.
 * No content checksum is written; integrity rests on TLS and the sha256 the index pins.
 */
const MAGIC = [0x28, 0xb5, 0x2f, 0xfd];
const WINDOW_DESCRIPTOR = 0x38; // exponent 7, mantissa 0: window = 2^(10+7) = 128 KiB
const MAX_BLOCK = 128 * 1024;

export function zstdFrame(data: Uint8Array): Buffer {
  const blocks = Math.max(1, Math.ceil(data.length / MAX_BLOCK));
  const out = Buffer.alloc(MAGIC.length + 2 + blocks * 3 + data.length);
  let o = 0;
  for (const b of MAGIC) out[o++] = b;
  out[o++] = 0x00;
  out[o++] = WINDOW_DESCRIPTOR;
  for (let i = 0; i < blocks; i++) {
    const start = i * MAX_BLOCK;
    const size = Math.min(MAX_BLOCK, data.length - start);
    const header = (i === blocks - 1 ? 1 : 0) | (0 << 1) | (size << 3); // last bit, type 0 = raw, size
    out[o++] = header & 0xff;
    out[o++] = (header >>> 8) & 0xff;
    out[o++] = (header >>> 16) & 0xff;
    out.set(data.subarray(start, start + size), o);
    o += size;
  }
  return out;
}
