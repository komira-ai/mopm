//! Decompression of the zstd streams inside a `.conda` into a [`Collector`], which may stop it
//! (`validate/zstd-read.ts`, which reads them with fzstd). The decoder is `ruzstd`, pure Rust, so there is no C
//! build script; the framing policy is fzstd's, because the verdicts depend on it:
//!
//! * a stream must start with a zstd frame (a skippable frame first is refused), and its magic is checked
//!   before anything else, so "not a zstd stream" is the verdict for non-zstd bytes;
//! * after the first frame come any number of zstd frames and skippable frames; bytes that are neither (and
//!   fewer than five of them) are corrupt, nothing after the last frame is not;
//! * a frame that declares a content size smaller than what it holds is corrupt; one that declares more is
//!   not (the size is a hint);
//! * the content checksum is not verified;
//! * every error of the decoder is "is not valid zstd"; what the collector says is passed through.

use ruzstd::decoding::{BlockDecodingStrategy, FrameDecoder};

use crate::codes::{fail, Checked, Failure, RuleCode};
use crate::collector::Collector;

const MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];
const SKIPPABLE: u32 = 0x184d_2a50;
/// Decode this many bytes of blocks, then hand them to the collector.
const STEP: usize = 128 * 1024;
/// The largest window a frame may declare (fzstd's own bound is 2 GiB; a `.conda` is at most 100 MB).
const MAX_WINDOW: u64 = 1 << 30;

fn corrupt(what: &str) -> Failure {
    Failure { rule: RuleCode::ArchiveCorrupt, message: format!("{what} is not valid zstd"), path: None }
}

/// Decompress zstd `data` into `out`, which may stop it. A decode error is `archive_corrupt`.
pub fn unzstd(data: &[u8], out: &mut Collector<'_>, what: &str) -> Checked<()> {
    if data.len() < 4 || data[..4] != MAGIC {
        return fail(RuleCode::ArchiveCorrupt, format!("{what} is not a zstd stream"));
    }
    let mut dec = FrameDecoder::new();
    dec.set_max_window_size(MAX_WINDOW);
    let mut pos = 0usize;
    while pos < data.len() {
        let rest = &data[pos..];
        if rest.len() < 5 {
            return Err(corrupt(what));
        }
        let magic = u32::from_le_bytes([rest[0], rest[1], rest[2], rest[3]]);
        if magic & 0xffff_fff0 == SKIPPABLE {
            if rest.len() < 8 {
                return Err(corrupt(what));
            }
            let total = u64::from(u32::from_le_bytes([rest[4], rest[5], rest[6], rest[7]])) + 8;
            if total > rest.len() as u64 {
                return Err(corrupt(what));
            }
            pos += total as usize;
            continue;
        }
        if magic != u32::from_le_bytes(MAGIC) {
            return Err(corrupt(what));
        }
        let mut src: &[u8] = rest;
        dec.init(&mut src).map_err(|_| corrupt(what))?;
        let declared = dec.content_size();
        let mut produced: u64 = 0;
        loop {
            let finished = dec.decode_blocks(&mut src, BlockDecodingStrategy::UptoBytes(STEP)).map_err(|_| corrupt(what))?;
            while dec.can_collect() > 0 {
                let Some(chunk) = dec.collect() else { break };
                if chunk.is_empty() {
                    break;
                }
                produced += chunk.len() as u64;
                out.push(&chunk)?;
            }
            if finished {
                break;
            }
        }
        if let Some(chunk) = dec.collect() {
            produced += chunk.len() as u64;
            out.push(&chunk)?;
        }
        if declared > 0 && produced > declared {
            return Err(corrupt(what));
        }
        pos += rest.len() - src.len();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mopm_core::limits::Limits;

    /// A zstd frame of raw blocks of at most 128 KiB, written here (window 128 KiB, no size, no checksum).
    fn raw_frame(data: &[u8]) -> Vec<u8> {
        let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38];
        let blocks: Vec<&[u8]> = if data.is_empty() { vec![&[][..]] } else { data.chunks(128 * 1024).collect() };
        for (i, b) in blocks.iter().enumerate() {
            let header = u32::from(i == blocks.len() - 1) | ((b.len() as u32) << 3);
            out.extend_from_slice(&header.to_le_bytes()[..3]);
            out.extend_from_slice(b);
        }
        out
    }

    /// A frame of RLE blocks (4 bytes each, of at most 128 KiB) repeating `byte` `n` times in all.
    fn rle_frame(byte: u8, n: u32) -> Vec<u8> {
        let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38];
        let mut left = n;
        loop {
            let size = left.min(128 * 1024);
            left -= size;
            let header = u32::from(left == 0) | (1 << 1) | (size << 3);
            out.extend_from_slice(&header.to_le_bytes()[..3]);
            out.push(byte);
            if left == 0 {
                return out;
            }
        }
    }

    fn run(data: &[u8], limits: &Limits, cap: u64) -> Checked<Vec<u8>> {
        let mut c = Collector::new(cap, data.len() as u64, limits, "s.tar.zst");
        unzstd(data, &mut c, "s.tar.zst")?;
        Ok(c.result())
    }

    fn ok(data: &[u8]) -> Vec<u8> {
        run(data, &Limits::DEFAULT, u64::MAX).unwrap()
    }

    fn refusal(data: &[u8]) -> (RuleCode, String) {
        let e = run(data, &Limits::DEFAULT, u64::MAX).err().expect("a refusal");
        (e.rule, e.message)
    }

    const NOT_VALID: &str = "s.tar.zst is not valid zstd";

    #[test]
    fn decodes_one_frame_and_several() {
        assert_eq!(ok(&raw_frame(b"hello")), b"hello");
        assert_eq!(ok(&[raw_frame(b"hel"), raw_frame(b"lo")].concat()), b"hello");
        let big = vec![7u8; 300_000];
        assert_eq!(ok(&raw_frame(&big)), big);
    }

    #[test]
    fn a_stream_that_does_not_start_with_a_frame_is_not_a_zstd_stream() {
        for data in [&b""[..], b"PK", b"\x28\xb5\x2f", b"not zstd at all"] {
            assert_eq!(refusal(data), (RuleCode::ArchiveCorrupt, "s.tar.zst is not a zstd stream".into()), "{data:?}");
        }
        // A skippable frame first is not a zstd stream either: the magic is checked before any frame is read.
        let skip = [&[0x50u8, 0x2a, 0x4d, 0x18, 0, 0, 0, 0][..], &raw_frame(b"x")].concat();
        assert_eq!(refusal(&skip), (RuleCode::ArchiveCorrupt, "s.tar.zst is not a zstd stream".into()));
    }

    #[test]
    fn a_skippable_frame_after_the_real_one_is_skipped_and_garbage_after_it_is_not() {
        let skip = [0x50u8, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3];
        assert_eq!(ok(&[raw_frame(b"hi"), skip.to_vec()].concat()), b"hi");
        assert_eq!(refusal(&[raw_frame(b"hi"), b"garbage!".to_vec()].concat()), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
        assert_eq!(refusal(&[raw_frame(b"hi"), b"abcd".to_vec()].concat()), (RuleCode::ArchiveCorrupt, NOT_VALID.into()), "fewer than five bytes");
        let long_skip = [0x50u8, 0x2a, 0x4d, 0x18, 9, 0, 0, 0, 1, 2];
        assert_eq!(refusal(&[raw_frame(b"hi"), long_skip.to_vec()].concat()), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
    }

    #[test]
    fn a_truncated_frame_is_corrupt() {
        let f = raw_frame(b"hello world");
        assert_eq!(refusal(&f[..4]), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
        assert_eq!(refusal(&f[..f.len() - 3]), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
        // Cut at a block boundary, before the block marked last.
        let first = [0x28u8, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x00 | (2 << 3) as u8, 0, 0, b'a', b'b'];
        assert_eq!(refusal(&first), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
    }

    #[test]
    fn the_reserved_block_type_is_corrupt() {
        let f = [0x28u8, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x07, 0, 0];
        assert_eq!(refusal(&f), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
    }

    #[test]
    fn an_rle_frame_is_stopped_by_the_collector_not_expanded_in_full() {
        let limits = Limits::DEFAULT;
        // 3 MB from a frame of about 100 bytes is past the ratio floor and a ratio of 200.
        let e = run(&rle_frame(b'A', 3_000_000), &limits, u64::MAX).err().unwrap();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::CompressionRatio, "s.tar.zst expands more than 200 times"));
        // 200 000 bytes under a 100 000 byte cap.
        let e = run(&rle_frame(b'A', 200_000), &limits, 100_000).err().unwrap();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::UnpackedTooLarge, "s.tar.zst unpacks past the 100000 byte limit"));
        // 4000 bytes is under both guards.
        assert_eq!(ok(&rle_frame(b'A', 4000)), vec![b'A'; 4000]);
    }

    #[test]
    fn a_declared_content_size_smaller_than_the_content_is_corrupt_and_a_larger_one_is_not() {
        // Single-segment frame (descriptor 0x20), content size in one byte, one raw block of 5 bytes.
        let frame = |declared: u8| {
            let mut out = vec![0x28u8, 0xb5, 0x2f, 0xfd, 0x20, declared];
            let header = 1u32 | (5 << 3);
            out.extend_from_slice(&header.to_le_bytes()[..3]);
            out.extend_from_slice(b"hello");
            out
        };
        assert_eq!(ok(&frame(5)), b"hello");
        assert_eq!(ok(&frame(200)), b"hello");
        assert_eq!(refusal(&frame(3)), (RuleCode::ArchiveCorrupt, NOT_VALID.into()));
    }
}
