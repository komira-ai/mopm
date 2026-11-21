//! The in-memory namespace store (`MemoryNamespaceStore` of `auth/namespaces.ts`, the part a login uses).

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use mopm_ports::error::PortResult;
use mopm_ports::namespaces::{
    user_namespace_for, NamespaceKind, NamespaceRecord, NamespaceStore, UserNamespace,
};

#[derive(Default)]
pub struct MemoryNamespaceStore {
    /// by namespace
    rows: Mutex<BTreeMap<String, NamespaceRecord>>,
}

impl MemoryNamespaceStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, NamespaceRecord>> {
        self.rows
            .lock()
            .expect("the store's lock is never held across a panic")
    }
}

impl NamespaceStore for MemoryNamespaceStore {
    async fn ensure_user_namespace(
        &self,
        github_id: u64,
        login: &str,
        now: &str,
    ) -> PortResult<Option<UserNamespace>> {
        let Some(namespace) = user_namespace_for(login) else {
            return Ok(None);
        };
        let mut rows = self.lock();
        if let Some(held) = rows.get(&namespace) {
            return Ok((held.github_id == github_id).then(|| UserNamespace::Held(held.clone())));
        }
        let rec = NamespaceRecord {
            namespace: namespace.clone(),
            kind: NamespaceKind::User,
            github_id,
            created_at: now.to_string(),
            created_by: None,
        };
        rows.insert(namespace, rec.clone());
        Ok(Some(UserNamespace::Created(rec)))
    }
}
