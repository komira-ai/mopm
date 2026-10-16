//! A valid zstd frame made only of raw (stored) blocks, byte for byte what `zstdFrame` of the
//! TypeScript registry writes.
//!
//! Why not compress: a compressor's output is not promised stable across library versions, which
//! would break "same records, same bytes" for the `.zst` file. A raw-block frame is deterministic by
//! construction and every conformant decoder (libzstd, fzstd, the conda tools) reads it. The cost is
//! size: the file is the JSON plus 3 bytes per 128 KiB, and CloudFront still compresses on the wire.
//!
//! Frame: magic, descriptor `0x00` (no single-segment, no checksum, no dictionary, no content size),
//! window descriptor for a 128 KiB window, then blocks of at most 128 KiB, the last flagged. No
//! content checksum is written; integrity rests on TLS and the sha256 the index pins.

const MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];
/// exponent 7, mantissa 0: window = 2^(10+7) = 128 KiB
const WINDOW_DESCRIPTOR: u8 = 0x38;
const MAX_BLOCK: usize = 128 * 1024;

/// `data` as a zstd frame of raw blocks.
pub fn zstd_frame(data: &[u8]) -> Vec<u8> {
    let blocks = data.len().div_ceil(MAX_BLOCK).max(1);
    let mut out = Vec::with_capacity(MAGIC.len() + 2 + blocks * 3 + data.len());
    out.extend_from_slice(&MAGIC);
    out.push(0x00);
    out.push(WINDOW_DESCRIPTOR);
    for i in 0..blocks {
        let start = i * MAX_BLOCK;
        let size = MAX_BLOCK.min(data.len() - start);
        // last-block bit, block type 0 (raw) in bits 1..3, the size from bit 3: three bytes, little endian
        let header = u32::from(i == blocks - 1) | ((size as u32) << 3);
        out.extend_from_slice(&header.to_le_bytes()[..3]);
        out.extend_from_slice(&data[start..start + size]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruzstd::decoding::StreamingDecoder;
    use std::io::Read;

    fn decode(frame: &[u8]) -> Vec<u8> {
        let mut dec = StreamingDecoder::new(frame).expect("a frame header");
        let mut out = Vec::new();
        dec.read_to_end(&mut out).expect("a frame");
        out
    }

    fn pattern(n: usize) -> Vec<u8> {
        // service/api/test/repodata.test.ts: Array.from({ length: n }, (_, i) => (i * 31 + 7) & 0xff)
        (0..n).map(|i| ((i * 31 + 7) & 0xff) as u8).collect()
    }

    #[test]
    fn the_empty_input_is_one_empty_last_block() {
        // magic, descriptor 00, window 38, block header: last=1, raw, size 0 -> 01 00 00
        assert_eq!(zstd_frame(b""), [0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38, 0x01, 0x00, 0x00]);
    }

    #[test]
    fn a_short_input_is_one_last_raw_block() {
        // size 5: header = 1 | (5 << 3) = 41 = 0x29
        assert_eq!(zstd_frame(b"hello"), [&[0x28u8, 0xb5, 0x2f, 0xfd, 0x00, 0x38, 0x29, 0x00, 0x00][..], &b"hello"[..]].concat());
    }

    #[test]
    fn a_full_block_and_one_byte_are_two_blocks_the_second_last() {
        let data = pattern(131_073);
        let frame = zstd_frame(&data);
        // block 1: not last, raw, size 131072 << 3 = 0x100000 -> 00 00 10
        assert_eq!(&frame[6..9], &[0x00, 0x00, 0x10]);
        assert_eq!(&frame[9..9 + 131_072], &data[..131_072]);
        // block 2: last, size 1 -> 1 | (1 << 3) = 9
        let second = 9 + 131_072;
        assert_eq!(&frame[second..second + 3], &[0x09, 0x00, 0x00]);
        assert_eq!(frame.len(), 6 + 3 + 131_072 + 3 + 1);
    }

    #[test]
    fn exactly_one_block_is_one_last_block() {
        let frame = zstd_frame(&pattern(131_072));
        // last=1 | (131072 << 3) = 0x100001 -> 01 00 10
        assert_eq!(&frame[6..9], &[0x01, 0x00, 0x10]);
        assert_eq!(frame.len(), 6 + 3 + 131_072);
    }

    #[test]
    fn round_trips_through_an_independent_decoder() {
        for n in [0usize, 1, 100, 131_071, 131_072, 131_073, 300_000] {
            let data = pattern(n);
            let frame = zstd_frame(&data);
            assert_eq!(&frame[..4], &[0x28, 0xb5, 0x2f, 0xfd]);
            assert_eq!(decode(&frame), data, "{n} bytes");
        }
    }

    #[test]
    fn is_a_pure_function_of_its_input() {
        assert_eq!(zstd_frame(b"hello"), zstd_frame(&b"hello".to_vec()));
    }
}
