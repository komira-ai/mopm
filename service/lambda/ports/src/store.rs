//! The registry's persistence port (`store.ts`). Two adapters implement it: memory (tests, in
//! `mopm_testing`) and DynamoDB (`mopm_aws`); `mopm_testing::store_contract` is the one suite both run.
//!
//! Rules every adapter keeps:
//!
//! * A (name, version) is created at most once, ever: a second `create_version` of `1.0.0` fails with
//!   `version_exists`, whatever state the first one is in (a tombstone keeps the number burned). Two
//!   concurrent creates: exactly one wins.
//! * Every change to a version also appends its audit entry, atomically with it.
//! * Version rows are never deleted.

use std::cmp::Ordering;
use std::future::Future;

use mopm_core::state::VersionEvent;
use mopm_core::types::{AuditEntry, OwnerRecord, PackageRecord, VersionRecord};
use mopm_core::version::compare_versions;

use crate::error::PortResult;
use crate::types::PackageSummary;

pub trait Store: Send + Sync {
    /// Create-once. `name_taken` when the package exists.
    fn create_package(&self, pkg: &PackageRecord) -> impl Future<Output = PortResult<()>> + Send;
    fn get_package(&self, name: &str) -> impl Future<Output = PortResult<Option<PackageRecord>>> + Send;
    fn list_package_names(&self) -> impl Future<Output = PortResult<Vec<String>>> + Send;
    /// Packages whose name starts with `prefix` (empty matches all), ordered by name, strictly after
    /// `after`, at most `limit`. This is the read path of search: the DynamoDB adapter answers it with
    /// one Query on the name index (never a Scan), so it can only return the attributes that index projects.
    fn search_packages(&self, prefix: &str, after: Option<&str>, limit: usize) -> impl Future<Output = PortResult<Vec<PackageSummary>>> + Send;

    /// Create-once, with its audit entry. `invalid_version`, `version_exists`.
    fn create_version(&self, rec: &VersionRecord, audit: &AuditEntry) -> impl Future<Output = PortResult<()>> + Send;
    /// `invalid_version` for anything that is not MAJOR.MINOR.PATCH.
    fn get_version(&self, name: &str, version: &str) -> impl Future<Output = PortResult<Option<VersionRecord>>> + Send;
    /// Apply an event through the state machine and persist it with its audit entry, retrying on a
    /// concurrent change. `version_not_found` when the version is missing; the state machine's error
    /// (`invalid_transition`, `invalid_request`) when it refuses the event.
    fn update_version(&self, name: &str, version: &str, event: &VersionEvent, audit: &AuditEntry) -> impl Future<Output = PortResult<VersionRecord>> + Send;
    /// Oldest to newest by version order.
    fn list_versions(&self, name: &str) -> impl Future<Output = PortResult<Vec<VersionRecord>>> + Send;

    /// `already_owner`.
    fn add_owner(&self, owner: &OwnerRecord) -> impl Future<Output = PortResult<()>> + Send;
    /// `owner_not_found`.
    fn remove_owner(&self, name: &str, github_id: u64) -> impl Future<Output = PortResult<()>> + Send;
    /// By github_id.
    fn list_owners(&self, name: &str) -> impl Future<Output = PortResult<Vec<OwnerRecord>>> + Send;
    /// The names of the packages the account owns, ascending (`auth/owned-packages.ts`). The DynamoDB adapter
    /// reads the owners table's index by account, one Query and never a Scan.
    fn owned_packages(&self, github_id: u64) -> impl Future<Output = PortResult<Vec<String>>> + Send;

    fn append_audit(&self, entry: &AuditEntry) -> impl Future<Output = PortResult<()>> + Send;
    /// Oldest first.
    fn list_audit(&self, name: &str) -> impl Future<Output = PortResult<Vec<AuditEntry>>> + Send;
}

/// Version order of two records (both versions are valid: a stored record always is). Equal for an
/// invalid version rather than a panic: such a record cannot have been created.
pub fn by_version(a: &VersionRecord, b: &VersionRecord) -> Ordering {
    compare_versions(&a.version, &b.version).unwrap_or(Ordering::Equal)
}

/// Audit rows are keyed by time then id, so they sort oldest first and never collide.
pub fn audit_sort_key(e: &AuditEntry) -> String {
    format!("{}#{}", e.ts, e.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(ts: &str, id: &str) -> AuditEntry {
        AuditEntry { name: "p".into(), ts: ts.into(), id: id.into(), actor: "a".into(), action: "x".into(), version: None, detail: None }
    }

    #[test]
    fn the_audit_key_is_time_then_id() {
        assert_eq!(audit_sort_key(&entry("2026-10-13T12:00:00Z", "id000001")), "2026-10-13T12:00:00Z#id000001");
        assert!(audit_sort_key(&entry("2026-10-13T12:00:00Z", "id000002")) > audit_sort_key(&entry("2026-10-13T12:00:00Z", "id000001")));
        assert!(audit_sort_key(&entry("2026-10-13T12:00:01Z", "a")) > audit_sort_key(&entry("2026-10-13T12:00:00Z", "z")));
    }
}
