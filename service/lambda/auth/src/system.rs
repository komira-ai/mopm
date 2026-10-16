//! The real clock and the real random source: what the Lambda hands to the types that take a
//! [`Clock`] and an [`Rng`]. Tests use `mopm_testing`'s.

use jiff::Timestamp;
use mopm_ports::env::{Clock, Rng};

/// The system clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        Timestamp::now()
    }
}

/// The operating system's random source, which is what token secrets and ids are made of. If it fails the
/// process cannot make a secret safely, so it stops.
pub struct OsRng;

impl Rng for OsRng {
    fn fill(&self, buf: &mut [u8]) {
        getrandom::fill(buf).expect("the operating system's random source answers");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_is_now() {
        let before = Timestamp::now();
        let t = SystemClock.now();
        assert!(t >= before && t.as_second() > 1_700_000_000);
    }

    #[test]
    fn the_random_source_fills_the_whole_buffer_differently_each_time() {
        let (mut a, mut b) = ([0u8; 32], [0u8; 32]);
        OsRng.fill(&mut a);
        OsRng.fill(&mut b);
        assert_ne!(a, b);
        assert!(a.iter().any(|x| *x != 0) && b.iter().any(|x| *x != 0));
        let mut empty: [u8; 0] = [];
        OsRng.fill(&mut empty);
    }
}
