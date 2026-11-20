//! The wall clock.

use jiff::Timestamp;
use mopm_ports::env::Clock;

/// The system's time, the one the function's expiry check and its revocation time read.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        Timestamp::now()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-11-01T00:00:00Z: the clock is the system's, not the epoch.
    const AFTER_THIS_WAS_WRITTEN_MS: i64 = 1_793_491_200_000;

    #[test]
    fn the_system_clock_reads_a_current_time() {
        assert!(SystemClock.now().as_millisecond() > AFTER_THIS_WAS_WRITTEN_MS);
    }
}
