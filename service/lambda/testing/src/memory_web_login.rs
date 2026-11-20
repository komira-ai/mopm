//! The in-memory store of the web sign-in's login transactions.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use jiff::Timestamp;
use mopm_ports::env::iso_millis;
use mopm_ports::error::PortResult;
use mopm_ports::web_login::{WebLoginRecord, WebLoginStore};

#[derive(Default)]
pub struct MemoryWebLoginStore {
    /// by id
    rows: Mutex<BTreeMap<String, WebLoginRecord>>,
}

impl MemoryWebLoginStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, WebLoginRecord>> {
        self.rows.lock().expect("the store's lock is never held across a panic")
    }
}

impl WebLoginStore for MemoryWebLoginStore {
    async fn put(&self, row: &WebLoginRecord) -> PortResult<()> {
        self.lock().insert(row.id.clone(), row.clone());
        Ok(())
    }

    async fn consume(&self, id: &str, now: Timestamp) -> PortResult<Option<WebLoginRecord>> {
        let mut rows = self.lock();
        let Some(row) = rows.get_mut(id).filter(|r| r.consumed_at.is_none() && !r.is_expired(now)) else {
            return Ok(None);
        };
        row.consumed_at = Some(iso_millis(now));
        Ok(Some(row.clone()))
    }
}
