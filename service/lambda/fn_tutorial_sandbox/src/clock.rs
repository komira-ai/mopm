//! The clock the function runs on: the system's, behind a shared handle, because the session check, the DynamoDB
//! adapter and the E2B call each take one.

use std::sync::Arc;

use jiff::Timestamp;
use mopm_ports::env::Clock;

/// The system's time.
#[derive(Clone, Copy, Debug)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        Timestamp::now()
    }
}

/// A clock shared by everything that needs one.
#[derive(Clone)]
pub struct SharedClock(pub Arc<dyn Clock>);

impl Clock for SharedClock {
    fn now(&self) -> Timestamp {
        self.0.now()
    }
}
