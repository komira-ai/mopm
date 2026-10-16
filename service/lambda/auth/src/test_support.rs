//! What the tests of this crate share: a clock, a random source, an auth store and a registry store, and the
//! shape of the answers.

use std::sync::Arc;

use mopm_core::error::ErrorCode;
use mopm_core::types::OwnerRecord;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::store::Store;
use mopm_testing::env::{FixedClock, SeededRng};
use mopm_testing::memory_auth::MemoryAuthStore;
use mopm_testing::memory_store::MemoryStore;

pub const ALICE: u64 = 1001;
pub const BOB: u64 = 1002;

pub struct Rig {
    pub clock: Arc<FixedClock>,
    pub rng: Arc<SeededRng>,
    pub auth: Arc<MemoryAuthStore>,
    pub store: Arc<MemoryStore>,
}

/// 2026-10-14T12:00:00Z.
pub fn start_ms() -> i64 {
    "2026-10-14T12:00:00Z".parse::<jiff::Timestamp>().unwrap().as_millisecond()
}

pub async fn rig() -> Rig {
    let r = Rig { clock: Arc::new(FixedClock::at_millis(start_ms())), rng: Arc::new(SeededRng::new(42)), auth: Arc::new(MemoryAuthStore::new()), store: Arc::new(MemoryStore::new()) };
    for (name, id) in [("alpha", ALICE), ("beta", ALICE), ("gamma", BOB)] {
        r.store.add_owner(&OwnerRecord { name: name.into(), github_id: id, handle: format!("u{id}"), added_at: "2026-10-01T00:00:00Z".into() }).await.unwrap();
    }
    r
}

/// The domain error code of a refusal; a fault is a failure of the test.
pub fn code_of<T: std::fmt::Debug>(r: PortResult<T>) -> ErrorCode {
    match r {
        Err(PortError::Registry(e)) => e.code,
        other => panic!("expected a domain refusal, got {other:?}"),
    }
}

/// The whole refusal.
pub fn refusal<T: std::fmt::Debug>(r: PortResult<T>) -> mopm_core::error::RegistryError {
    match r {
        Err(PortError::Registry(e)) => e,
        other => panic!("expected a domain refusal, got {other:?}"),
    }
}
