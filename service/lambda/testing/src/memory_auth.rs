//! The in-memory auth store (`memory-auth-store.ts`): the rules the DynamoDB adapter keeps.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use mopm_ports::auth::AuthStore;
use mopm_ports::error::PortResult;
use mopm_ports::types::{DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord};

#[derive(Default)]
struct Inner {
    users: BTreeMap<u64, UserRecord>,
    /// by id
    tokens: BTreeMap<String, TokenRecord>,
    logins: BTreeMap<String, DeviceLoginRecord>,
    /// by package name, in the order added
    trusted: BTreeMap<String, Vec<TrustedPublisher>>,
}

#[derive(Default)]
pub struct MemoryAuthStore {
    inner: Mutex<Inner>,
}

impl MemoryAuthStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().expect("the store's lock is never held across a panic")
    }

    /// Every stored token row, to assert what is and is not persisted.
    pub fn dump_tokens(&self) -> Vec<TokenRecord> {
        self.lock().tokens.values().cloned().collect()
    }
}

impl Inner {
    fn token_by_hash(&mut self, hash: &str) -> Option<&mut TokenRecord> {
        self.tokens.values_mut().find(|t| t.hash == hash)
    }
}

impl AuthStore for MemoryAuthStore {
    async fn upsert_user(&self, github_id: u64, handle: &str, now: &str, two_factor: Option<bool>) -> PortResult<UserRecord> {
        let mut g = self.lock();
        let created_at = g.users.get(&github_id).map_or_else(|| now.to_string(), |u| u.created_at.clone());
        let rec = UserRecord { github_id, handle: handle.to_string(), created_at, last_login_at: now.to_string(), two_factor };
        g.users.insert(github_id, rec.clone());
        Ok(rec)
    }

    async fn get_user(&self, github_id: u64) -> PortResult<Option<UserRecord>> {
        Ok(self.lock().users.get(&github_id).cloned())
    }

    async fn put_token(&self, rec: &TokenRecord) -> PortResult<()> {
        self.lock().tokens.insert(rec.id.clone(), rec.clone());
        Ok(())
    }

    async fn get_token_by_hash(&self, hash: &str) -> PortResult<Option<TokenRecord>> {
        Ok(self.lock().tokens.values().find(|t| t.hash == hash).cloned())
    }

    async fn get_user_token(&self, github_id: u64, id: &str) -> PortResult<Option<TokenRecord>> {
        Ok(self.lock().tokens.get(id).filter(|t| t.github_id == Some(github_id)).cloned())
    }

    async fn list_tokens(&self, github_id: u64) -> PortResult<Vec<TokenRecord>> {
        Ok(self.lock().tokens.values().filter(|t| t.github_id == Some(github_id)).cloned().collect())
    }

    async fn revoke_token(&self, hash: &str, at: &str) -> PortResult<()> {
        if let Some(t) = self.lock().token_by_hash(hash) {
            if t.revoked_at.is_none() {
                t.revoked_at = Some(at.to_string());
            }
        }
        Ok(())
    }

    async fn touch_token(&self, hash: &str, at: &str) -> PortResult<()> {
        if let Some(t) = self.lock().token_by_hash(hash) {
            t.last_used_at = Some(at.to_string());
        }
        Ok(())
    }

    async fn put_device_login(&self, rec: &DeviceLoginRecord) -> PortResult<()> {
        self.lock().logins.insert(rec.id.clone(), rec.clone());
        Ok(())
    }

    async fn get_device_login(&self, id: &str) -> PortResult<Option<DeviceLoginRecord>> {
        Ok(self.lock().logins.get(id).cloned())
    }

    async fn set_device_polled(&self, id: &str, at: &str, interval: u64) -> PortResult<()> {
        if let Some(l) = self.lock().logins.get_mut(id) {
            l.last_polled_at = Some(at.to_string());
            l.interval = interval;
        }
        Ok(())
    }

    async fn delete_device_login(&self, id: &str) -> PortResult<()> {
        self.lock().logins.remove(id);
        Ok(())
    }

    async fn add_trusted_publisher(&self, tp: &TrustedPublisher) -> PortResult<()> {
        self.lock().trusted.entry(tp.name.clone()).or_default().push(tp.clone());
        Ok(())
    }

    async fn list_trusted_publishers(&self, name: &str) -> PortResult<Vec<TrustedPublisher>> {
        Ok(self.lock().trusted.get(name).cloned().unwrap_or_default())
    }

    async fn remove_trusted_publisher(&self, name: &str, id: &str) -> PortResult<()> {
        if let Some(list) = self.lock().trusted.get_mut(name) {
            list.retain(|t| t.id != id);
        }
        Ok(())
    }
}
