//! Receives the output of a decompressor and stops it, by returning a failure, the moment it passes a cap or the
//! ratio guard (`validate/collector.ts`). This is the zip and tar bomb guard: nothing is ever held past `cap`
//! plus one chunk. The counters are what the verdict depends on, so a streaming decompressor that pushes in other
//! chunk sizes still stops at the same rule; only a bomb whose output passes two guards inside one chunk could
//! report the other one.

use mopm_core::limits::Limits;

use crate::codes::{fail, Checked, RuleCode};

pub struct Collector<'a> {
    out: Vec<u8>,
    cap: u64,
    compressed_bytes: u64,
    limits: &'a Limits,
    what: &'a str,
}

impl<'a> Collector<'a> {
    pub fn new(cap: u64, compressed_bytes: u64, limits: &'a Limits, what: &'a str) -> Self {
        Collector { out: Vec::new(), cap, compressed_bytes, limits, what }
    }

    pub fn push(&mut self, chunk: &[u8]) -> Checked<()> {
        if chunk.is_empty() {
            return Ok(());
        }
        let total = self.out.len() as u64 + chunk.len() as u64;
        if total > self.cap {
            return fail(RuleCode::UnpackedTooLarge, format!("{} unpacks past the {} byte limit", self.what, self.cap));
        }
        if total > self.limits.ratio_floor_bytes && total > self.limits.max_ratio.saturating_mul(self.compressed_bytes.max(1)) {
            return fail(RuleCode::CompressionRatio, format!("{} expands more than {} times", self.what, self.limits.max_ratio));
        }
        self.out.extend_from_slice(chunk);
        Ok(())
    }

    pub fn result(self) -> Vec<u8> {
        self.out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> Limits {
        Limits { max_ratio: 10, ratio_floor_bytes: 100, ..Limits::DEFAULT }
    }

    #[test]
    fn collects_chunks_in_order() {
        let l = limits();
        let mut c = Collector::new(1000, 1000, &l, "t");
        c.push(b"ab").unwrap();
        c.push(b"").unwrap();
        c.push(b"cd").unwrap();
        assert_eq!(c.result(), b"abcd");
    }

    #[test]
    fn stops_at_the_cap_naming_the_stream_and_the_limit() {
        let l = limits();
        let mut c = Collector::new(10, 1000, &l, "info-x.tar.zst");
        c.push(&[0; 10]).unwrap();
        let e = c.push(&[0; 1]).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::UnpackedTooLarge, "info-x.tar.zst unpacks past the 10 byte limit"));
    }

    #[test]
    fn the_ratio_guard_applies_only_past_the_floor() {
        let l = limits();
        // 100 bytes from 1 compressed byte is a ratio of 100, but it is not past the 100 byte floor.
        Collector::new(u64::MAX, 1, &l, "t").push(&[0; 100]).unwrap();
        let e = Collector::new(u64::MAX, 1, &l, "t").push(&[0; 101]).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::CompressionRatio, "t expands more than 10 times"));
        // 101 bytes from 11 compressed is a ratio under 10: fine.
        Collector::new(u64::MAX, 11, &l, "t").push(&[0; 101]).unwrap();
        // An empty compressed stream counts as one byte.
        assert!(Collector::new(u64::MAX, 0, &l, "t").push(&[0; 101]).is_err());
    }

    #[test]
    fn the_cap_is_checked_before_the_ratio() {
        let l = limits();
        let e = Collector::new(50, 1, &l, "t").push(&[0; 500]).unwrap_err();
        assert_eq!(e.rule, RuleCode::UnpackedTooLarge);
    }

    #[test]
    fn totals_accumulate_across_chunks() {
        let l = limits();
        let mut c = Collector::new(u64::MAX, 1, &l, "t");
        for _ in 0..100 {
            c.push(&[0; 1]).unwrap();
        }
        assert_eq!(c.push(&[0; 1]).unwrap_err().rule, RuleCode::CompressionRatio);
    }
}
