//! A clock a test sets and a random source that repeats.

use std::sync::{Mutex, MutexGuard};

use jiff::Timestamp;
use mopm_ports::env::{Clock, Rng};

/// A clock that stands still until the test moves it.
pub struct FixedClock(Mutex<Timestamp>);

impl FixedClock {
    pub fn at_millis(ms: i64) -> Self {
        FixedClock(Mutex::new(Timestamp::from_millisecond(ms).expect("a representable time")))
    }

    fn lock(&self) -> MutexGuard<'_, Timestamp> {
        self.0.lock().expect("a lock is never held across a panic")
    }

    pub fn advance_millis(&self, ms: i64) {
        let mut g = self.lock();
        *g = Timestamp::from_millisecond(g.as_millisecond() + ms).expect("a representable time");
    }
}

impl Clock for FixedClock {
    fn now(&self) -> Timestamp {
        *self.lock()
    }
}

/// xorshift64*: the same seed gives the same bytes. Not for secrets.
pub struct SeededRng(Mutex<u64>);

impl SeededRng {
    pub fn new(seed: u64) -> Self {
        SeededRng(Mutex::new(seed.max(1)))
    }
}

impl Rng for SeededRng {
    fn fill(&self, buf: &mut [u8]) {
        let mut s = self.0.lock().expect("a lock is never held across a panic");
        for chunk in buf.chunks_mut(8) {
            *s ^= *s >> 12;
            *s ^= *s << 25;
            *s ^= *s >> 27;
            let word = s.wrapping_mul(0x2545_f491_4f6c_dd1d).to_le_bytes();
            chunk.copy_from_slice(&word[..chunk.len()]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mopm_ports::env::iso_millis;

    #[test]
    fn the_clock_stands_still_until_advanced() {
        let c = FixedClock::at_millis(1_760_356_800_000);
        assert_eq!(iso_millis(c.now()), "2025-10-13T12:00:00.000Z");
        assert_eq!(iso_millis(c.now()), "2025-10-13T12:00:00.000Z");
        c.advance_millis(1_500);
        assert_eq!(iso_millis(c.now()), "2025-10-13T12:00:01.500Z");
    }

    #[test]
    fn the_same_seed_repeats_and_another_differs() {
        let (a, b, c) = (SeededRng::new(7), SeededRng::new(7), SeededRng::new(8));
        let (mut x, mut y, mut z) = ([0u8; 20], [0u8; 20], [0u8; 20]);
        a.fill(&mut x);
        b.fill(&mut y);
        c.fill(&mut z);
        assert_eq!(x, y);
        assert_ne!(x, z);
        assert_ne!(x, [0u8; 20]);
        // Successive fills continue the stream.
        let mut x2 = [0u8; 20];
        a.fill(&mut x2);
        assert_ne!(x, x2);
    }
}
