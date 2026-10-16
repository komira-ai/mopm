//! The in-memory registry store (`memory-store.ts`). It defines the rules the DynamoDB adapter must keep:
//! every method does its read-check-write inside one lock acquisition and never awaits while holding it,
//! so each is atomic, which is what DynamoDB gives the other adapter with conditions.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use mopm_core::error::{already_owner, name_taken, owner_not_found, version_exists, version_not_found};
use mopm_core::state::{apply_event, Applied, VersionEvent};
use mopm_core::types::{AuditEntry, OwnerRecord, PackageRecord, VersionRecord};
use mopm_core::version::canonical_version;
use mopm_ports::error::PortResult;
use mopm_ports::store::{audit_sort_key, by_version, Store};
use mopm_ports::types::PackageSummary;

#[derive(Default)]
struct Inner {
    packages: BTreeMap<String, PackageRecord>,
    /// (name, canonical version)
    versions: BTreeMap<(String, String), VersionRecord>,
    /// (name, github id)
    owners: BTreeMap<(String, u64), OwnerRecord>,
    audit: Vec<AuditEntry>,
}

#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<Inner>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().expect("the store's lock is never held across a panic")
    }

    /// Seeding writes rows as they are, with no audit entry and no check (see [`crate::seed`]).
    pub(crate) fn seed_package(&self, p: PackageRecord) {
        self.lock().packages.insert(p.name.clone(), p);
    }

    pub(crate) fn seed_version(&self, v: VersionRecord) {
        self.lock().versions.insert((v.name.clone(), v.canonical.clone()), v);
    }

    pub(crate) fn seed_owner(&self, o: OwnerRecord) {
        self.lock().owners.insert((o.name.clone(), o.github_id), o);
    }

    pub(crate) fn seed_audit(&self, e: AuditEntry) {
        self.lock().audit.push(e);
    }
}

impl Store for MemoryStore {
    async fn create_package(&self, pkg: &PackageRecord) -> PortResult<()> {
        let mut g = self.lock();
        if g.packages.contains_key(&pkg.name) {
            return Err(name_taken(&pkg.name).into());
        }
        g.packages.insert(pkg.name.clone(), pkg.clone());
        Ok(())
    }

    async fn get_package(&self, name: &str) -> PortResult<Option<PackageRecord>> {
        Ok(self.lock().packages.get(name).cloned())
    }

    async fn list_package_names(&self) -> PortResult<Vec<String>> {
        Ok(self.lock().packages.keys().cloned().collect())
    }

    async fn search_packages(&self, prefix: &str, after: Option<&str>, limit: usize) -> PortResult<Vec<PackageSummary>> {
        let g = self.lock();
        Ok(g.packages
            .values()
            .filter(|p| p.name.starts_with(prefix) && after.is_none_or(|a| p.name.as_str() > a))
            .take(limit)
            .map(|p| PackageSummary { name: p.name.clone(), state: p.state, created_at: p.created_at.clone(), description: p.description.clone() })
            .collect())
    }

    async fn create_version(&self, rec: &VersionRecord, audit: &AuditEntry) -> PortResult<()> {
        let canonical = canonical_version(&rec.version)?;
        let mut g = self.lock();
        let key = (rec.name.clone(), canonical.clone());
        if let Some(existing) = g.versions.get(&key) {
            let sha = existing.files.first().map_or(existing.manifest_sha256.as_str(), |f| f.sha256.as_str());
            return Err(version_exists(&rec.name, &rec.version, sha).into());
        }
        g.versions.insert(key, VersionRecord { canonical, ..rec.clone() });
        g.audit.push(audit.clone());
        Ok(())
    }

    async fn get_version(&self, name: &str, version: &str) -> PortResult<Option<VersionRecord>> {
        let canonical = canonical_version(version)?;
        Ok(self.lock().versions.get(&(name.to_string(), canonical)).cloned())
    }

    async fn update_version(&self, name: &str, version: &str, event: &VersionEvent, audit: &AuditEntry) -> PortResult<VersionRecord> {
        let canonical = canonical_version(version)?;
        let mut g = self.lock();
        let key = (name.to_string(), canonical);
        let cur = g.versions.get(&key).cloned().ok_or_else(|| version_not_found(name, version))?;
        match apply_event(&cur, event)? {
            Applied::Unchanged => Ok(cur),
            Applied::Changed(next) => {
                g.versions.insert(key, next.clone());
                g.audit.push(audit.clone());
                Ok(next)
            }
        }
    }

    async fn list_versions(&self, name: &str) -> PortResult<Vec<VersionRecord>> {
        let g = self.lock();
        let mut out: Vec<VersionRecord> = g.versions.iter().filter(|((n, _), _)| n == name).map(|(_, v)| v.clone()).collect();
        out.sort_by(by_version);
        Ok(out)
    }

    async fn add_owner(&self, owner: &OwnerRecord) -> PortResult<()> {
        let mut g = self.lock();
        let key = (owner.name.clone(), owner.github_id);
        if g.owners.contains_key(&key) {
            return Err(already_owner(&owner.handle, &owner.name).into());
        }
        g.owners.insert(key, owner.clone());
        Ok(())
    }

    async fn remove_owner(&self, name: &str, github_id: u64) -> PortResult<()> {
        match self.lock().owners.remove(&(name.to_string(), github_id)) {
            Some(_) => Ok(()),
            None => Err(owner_not_found(name).into()),
        }
    }

    async fn list_owners(&self, name: &str) -> PortResult<Vec<OwnerRecord>> {
        // The map is keyed (name, github id), so its order is by id.
        Ok(self.lock().owners.iter().filter(|((n, _), _)| n == name).map(|(_, o)| o.clone()).collect())
    }

    async fn owned_packages(&self, github_id: u64) -> PortResult<Vec<String>> {
        // `owners` is keyed by (name, id), so the names come out ascending.
        Ok(self.lock().owners.keys().filter(|(_, id)| *id == github_id).map(|(n, _)| n.clone()).collect())
    }

    async fn append_audit(&self, entry: &AuditEntry) -> PortResult<()> {
        self.lock().audit.push(entry.clone());
        Ok(())
    }

    async fn list_audit(&self, name: &str) -> PortResult<Vec<AuditEntry>> {
        let mut out: Vec<AuditEntry> = self.lock().audit.iter().filter(|e| e.name == name).cloned().collect();
        out.sort_by_key(audit_sort_key);
        Ok(out)
    }
}
