//! The two things the core must not reach for itself: the clock and randomness. A function takes them
//! as arguments, so a test fixes them.

use jiff::Timestamp;

pub trait Clock: Send + Sync {
    fn now(&self) -> Timestamp;
}

/// Unpredictable bytes for tokens, codes and ids. The real one reads the operating system's source.
pub trait Rng: Send + Sync {
    fn fill(&self, buf: &mut [u8]);
}

/// `Date.prototype.toISOString`: `YYYY-MM-DDTHH:MM:SS.mmmZ`, always three decimals and `Z`.
pub fn iso_millis(ts: Timestamp) -> String {
    ts.strftime("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(ms: i64) -> Timestamp {
        Timestamp::from_millisecond(ms).unwrap()
    }

    #[test]
    fn matches_to_iso_string() {
        // new Date(1760356800000).toISOString() === '2025-10-13T12:00:00.000Z'
        assert_eq!(iso_millis(at(1_760_356_800_000)), "2025-10-13T12:00:00.000Z");
        assert_eq!(iso_millis(at(1_760_356_800_007)), "2025-10-13T12:00:00.007Z");
        assert_eq!(iso_millis(at(1_760_356_800_120)), "2025-10-13T12:00:00.120Z");
        assert_eq!(iso_millis(at(0)), "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn truncates_below_a_millisecond_as_javascript_does() {
        let ts = Timestamp::from_nanosecond(1_760_356_800_123_999_999).unwrap();
        assert_eq!(iso_millis(ts), "2025-10-13T12:00:00.123Z");
    }

    #[test]
    fn handles_dates_before_the_epoch() {
        assert_eq!(iso_millis(at(-1)), "1969-12-31T23:59:59.999Z");
    }
}
