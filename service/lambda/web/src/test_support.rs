//! What this crate's tests share: an `AuthStore` that records the name of every call it gets, can fail one
//! named call with a fault, can answer every token lookup with one fixed row (a store that matched on something
//! other than the hash), and otherwise passes the call to the memory store.

use std::sync::{Arc, Mutex};

use mopm_ports::auth::AuthStore;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::types::{DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord};
use mopm_testing::memory_auth::MemoryAuthStore;

pub type Calls = Arc<Mutex<Vec<&'static str>>>;

/// The memory store, with each call's name recorded in order (`get_token_by_hash`, `touch_token`, ...).
pub struct Recording {
    inner: MemoryAuthStore,
    calls: Calls,
    fail: Option<&'static str>,
    token_answer: Option<TokenRecord>,
}

impl Recording {
    /// `inner`, recorded; the call named `fail` answers a fault.
    pub fn new(inner: MemoryAuthStore, fail: Option<&'static str>) -> (Recording, Calls) {
        let calls = Calls::default();
        (Recording { inner, calls: calls.clone(), fail, token_answer: None }, calls)
    }

    /// The store, except that `get_token_by_hash` answers `row` whatever hash it is asked for.
    pub fn answering_tokens_with(mut self, row: TokenRecord) -> Recording {
        self.token_answer = Some(row);
        self
    }

    fn note(&self, call: &'static str) -> PortResult<()> {
        self.calls.lock().unwrap().push(call);
        match self.fail {
            Some(f) if f == call => Err(PortError::fault("the store is unreachable")),
            _ => Ok(()),
        }
    }
}

impl AuthStore for Recording {
    async fn upsert_user(&self, github_id: u64, handle: &str, now: &str, two_factor: Option<bool>) -> PortResult<UserRecord> {
        self.note("upsert_user")?;
        self.inner.upsert_user(github_id, handle, now, two_factor).await
    }
    async fn get_user(&self, github_id: u64) -> PortResult<Option<UserRecord>> {
        self.note("get_user")?;
        self.inner.get_user(github_id).await
    }
    async fn put_token(&self, rec: &TokenRecord) -> PortResult<()> {
        self.note("put_token")?;
        self.inner.put_token(rec).await
    }
    async fn get_token_by_hash(&self, hash: &str) -> PortResult<Option<TokenRecord>> {
        self.note("get_token_by_hash")?;
        match &self.token_answer {
            Some(row) => Ok(Some(row.clone())),
            None => self.inner.get_token_by_hash(hash).await,
        }
    }
    async fn get_user_token(&self, github_id: u64, id: &str) -> PortResult<Option<TokenRecord>> {
        self.note("get_user_token")?;
        self.inner.get_user_token(github_id, id).await
    }
    async fn list_tokens(&self, github_id: u64) -> PortResult<Vec<TokenRecord>> {
        self.note("list_tokens")?;
        self.inner.list_tokens(github_id).await
    }
    async fn revoke_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.note("revoke_token")?;
        self.inner.revoke_token(hash, at).await
    }
    async fn touch_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.note("touch_token")?;
        self.inner.touch_token(hash, at).await
    }
    async fn put_device_login(&self, rec: &DeviceLoginRecord) -> PortResult<()> {
        self.note("put_device_login")?;
        self.inner.put_device_login(rec).await
    }
    async fn get_device_login(&self, id: &str) -> PortResult<Option<DeviceLoginRecord>> {
        self.note("get_device_login")?;
        self.inner.get_device_login(id).await
    }
    async fn set_device_polled(&self, id: &str, at: &str, interval: u64) -> PortResult<()> {
        self.note("set_device_polled")?;
        self.inner.set_device_polled(id, at, interval).await
    }
    async fn delete_device_login(&self, id: &str) -> PortResult<()> {
        self.note("delete_device_login")?;
        self.inner.delete_device_login(id).await
    }
    async fn add_trusted_publisher(&self, tp: &TrustedPublisher) -> PortResult<()> {
        self.note("add_trusted_publisher")?;
        self.inner.add_trusted_publisher(tp).await
    }
    async fn list_trusted_publishers(&self, name: &str) -> PortResult<Vec<TrustedPublisher>> {
        self.note("list_trusted_publishers")?;
        self.inner.list_trusted_publishers(name).await
    }
    async fn remove_trusted_publisher(&self, name: &str, id: &str) -> PortResult<()> {
        self.note("remove_trusted_publisher")?;
        self.inner.remove_trusted_publisher(name, id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [&str; 15] = [
        "upsert_user",
        "get_user",
        "put_token",
        "get_token_by_hash",
        "get_user_token",
        "list_tokens",
        "revoke_token",
        "touch_token",
        "put_device_login",
        "get_device_login",
        "set_device_polled",
        "delete_device_login",
        "add_trusted_publisher",
        "list_trusted_publishers",
        "remove_trusted_publisher",
    ];

    /// Calls every method once, in `ALL`'s order, and answers which failed.
    async fn call_all(s: &Recording) -> Vec<bool> {
        let tok: TokenRecord = serde_json::from_value(serde_json::json!({
            "id": "t", "kind": "session", "name": "n", "hash": "h", "prefix": "p", "scopes": [], "packages": [],
            "all_current": false, "created_at": "c", "expires_at": "e"
        }))
        .unwrap();
        let dl = DeviceLoginRecord {
            id: "d".into(),
            github_device_code: "g".into(),
            client: "c".into(),
            created_at: "c".into(),
            expires_at: "e".into(),
            interval: 5,
            last_polled_at: None,
        };
        let tp: TrustedPublisher = serde_json::from_value(serde_json::json!({
            "id": "1", "name": "pkg", "repository_id": "r", "repository_owner_id": "o", "workflow": "w", "added_by": 1, "added_at": "a"
        }))
        .unwrap();
        vec![
            s.upsert_user(1, "a", "n", None).await.is_err(),
            s.get_user(1).await.is_err(),
            s.put_token(&tok).await.is_err(),
            s.get_token_by_hash("h").await.is_err(),
            s.get_user_token(1, "t").await.is_err(),
            s.list_tokens(1).await.is_err(),
            s.revoke_token("h", "n").await.is_err(),
            s.touch_token("h", "n").await.is_err(),
            s.put_device_login(&dl).await.is_err(),
            s.get_device_login("d").await.is_err(),
            s.set_device_polled("d", "n", 5).await.is_err(),
            s.delete_device_login("d").await.is_err(),
            s.add_trusted_publisher(&tp).await.is_err(),
            s.list_trusted_publishers("pkg").await.is_err(),
            s.remove_trusted_publisher("pkg", "1").await.is_err(),
        ]
    }

    #[tokio::test]
    async fn every_call_is_recorded_in_order_and_passed_on() {
        let (s, calls) = Recording::new(MemoryAuthStore::new(), None);
        assert_eq!(call_all(&s).await, vec![false; 15]);
        assert_eq!(*calls.lock().unwrap(), ALL.to_vec());
        assert_eq!(s.inner.dump_tokens().len(), 1);
    }

    #[tokio::test]
    async fn a_fixed_token_answer_is_given_for_any_hash() {
        let (s, _) = Recording::new(MemoryAuthStore::new(), None);
        let row: TokenRecord = serde_json::from_value(serde_json::json!({
            "id": "t", "kind": "session", "name": "n", "hash": "h", "prefix": "p", "scopes": [], "packages": [],
            "all_current": false, "created_at": "c", "expires_at": "e"
        }))
        .unwrap();
        let s = s.answering_tokens_with(row.clone());
        assert_eq!(s.get_token_by_hash("other").await.unwrap(), Some(row));
    }

    #[tokio::test]
    async fn the_named_call_and_only_it_fails() {
        for (i, name) in ALL.iter().enumerate() {
            let (s, _) = Recording::new(MemoryAuthStore::new(), Some(name));
            let failed = call_all(&s).await;
            let expected: Vec<bool> = (0..15).map(|j| j == i).collect();
            assert_eq!(failed, expected, "{name}");
        }
    }
}
