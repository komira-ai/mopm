//! Seeds: the contents of a store before a request, as one JSON document, so a scenario is data and
//! the same file can be loaded by the TypeScript tests and the Rust ones.
//!
//! ```json
//! { "packages": [PackageRecord], "versions": [VersionRecord], "owners": [OwnerRecord], "audit": [AuditEntry] }
//! ```
//!
//! Every member is optional. Rows are written as given: no audit entry is made, no state machine runs,
//! and a version's `canonical` is what the record says (so a seed can hold a record no request could create).

use mopm_core::types::{AuditEntry, OwnerRecord, PackageRecord, VersionRecord};
use serde::Deserialize;
use thiserror::Error;

use crate::memory_store::MemoryStore;

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Seed {
    #[serde(default)]
    pub packages: Vec<PackageRecord>,
    #[serde(default)]
    pub versions: Vec<VersionRecord>,
    #[serde(default)]
    pub owners: Vec<OwnerRecord>,
    #[serde(default)]
    pub audit: Vec<AuditEntry>,
}

#[derive(Debug, Error)]
pub enum SeedError {
    #[error("seed is not valid: {0}")]
    Invalid(#[from] serde_json::Error),
    #[error("seed holds {name} {version} twice")]
    DuplicateVersion { name: String, version: String },
    #[error("seed holds package {0} twice")]
    DuplicatePackage(String),
}

impl Seed {
    /// Parses a seed document. An unknown member is an error (a typo must not seed nothing).
    pub fn parse(text: &str) -> Result<Seed, SeedError> {
        let seed: Seed = serde_json::from_str(text)?;
        let mut packages = std::collections::BTreeSet::new();
        for p in &seed.packages {
            if !packages.insert(&p.name) {
                return Err(SeedError::DuplicatePackage(p.name.clone()));
            }
        }
        let mut versions = std::collections::BTreeSet::new();
        for v in &seed.versions {
            if !versions.insert((&v.name, &v.canonical)) {
                return Err(SeedError::DuplicateVersion { name: v.name.clone(), version: v.version.clone() });
            }
        }
        Ok(seed)
    }

    /// A store holding exactly this seed.
    pub fn into_store(self) -> MemoryStore {
        let store = MemoryStore::new();
        for p in self.packages {
            store.seed_package(p);
        }
        for v in self.versions {
            store.seed_version(v);
        }
        for o in self.owners {
            store.seed_owner(o);
        }
        for e in self.audit {
            store.seed_audit(e);
        }
        store
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::rec;
    use mopm_ports::store::Store;

    fn text() -> String {
        serde_json::json!({
            "packages": [{"name": "http", "state": "active", "created_at": "2026-10-13T12:00:00Z", "description": "d"}],
            "versions": [serde_json::to_value(rec("http", "1.0.0")).unwrap()],
            "owners": [{"name": "http", "github_id": 7, "handle": "octocat", "added_at": "2026-10-13T12:00:00Z"}],
            "audit": [{"name": "http", "ts": "2026-10-13T12:00:00Z", "id": "id1", "actor": "u:7", "action": "claim"}]
        })
        .to_string()
    }

    #[tokio::test]
    async fn a_seed_becomes_a_store_holding_exactly_it() {
        let s = Seed::parse(&text()).unwrap().into_store();
        assert_eq!(s.list_package_names().await.unwrap(), ["http"]);
        assert_eq!(s.get_version("http", "1.0.0").await.unwrap().unwrap().files.len(), 1);
        assert_eq!(s.list_owners("http").await.unwrap()[0].github_id, 7);
        assert_eq!(s.list_audit("http").await.unwrap().len(), 1, "seeding made no audit entry of its own");
    }

    #[test]
    fn an_empty_document_is_an_empty_seed() {
        let s = Seed::parse("{}").unwrap();
        assert!(s.packages.is_empty() && s.versions.is_empty() && s.owners.is_empty() && s.audit.is_empty());
    }

    #[test]
    fn a_typo_in_a_member_name_is_an_error_and_not_an_empty_seed() {
        assert!(matches!(Seed::parse(r#"{"package": []}"#), Err(SeedError::Invalid(_))));
    }

    #[test]
    fn a_malformed_record_is_an_error() {
        assert!(matches!(Seed::parse(r#"{"owners": [{"name": "p"}]}"#), Err(SeedError::Invalid(_))));
    }

    #[test]
    fn duplicates_are_refused() {
        let v = serde_json::to_value(rec("http", "1.0.0")).unwrap();
        let dup = serde_json::json!({"versions": [v.clone(), v]}).to_string();
        assert!(matches!(Seed::parse(&dup), Err(SeedError::DuplicateVersion { .. })));
        let p = serde_json::json!({"name": "a", "state": "active", "created_at": "t"});
        let dup = serde_json::json!({"packages": [p.clone(), p]}).to_string();
        assert!(matches!(Seed::parse(&dup), Err(SeedError::DuplicatePackage(_))));
    }
}
