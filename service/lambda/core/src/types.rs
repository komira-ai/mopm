//! The records the registry stores and serves. Field names and JSON shapes are the TypeScript
//! registry's (`service/api/src/types.ts`): a record written by one implementation is read by the
//! other, so an optional field is absent, never `null`.

use serde::{Deserialize, Serialize};

/// A conda subdir. New values may be added (spec), so this is a string, with the four v1 values listed.
pub type Subdir = String;

pub const SUBDIRS_V1: [&str; 4] = ["linux-64", "linux-aarch64", "noarch", "osx-arm64"];

/// The most readme text, in UTF-8 bytes, the API serves.
pub const README_MAX_BYTES: usize = 65536;

/// `pending` exists only inside the registry: a reserved number whose files are not yet committed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VersionState {
    Pending,
    Published,
    Yanked,
    Tombstoned,
}

impl VersionState {
    pub const fn as_str(self) -> &'static str {
        match self {
            VersionState::Pending => "pending",
            VersionState::Published => "published",
            VersionState::Yanked => "yanked",
            VersionState::Tombstoned => "tombstoned",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileRef {
    pub subdir: Subdir,
    pub filename: String,
    pub sha256: String,
    pub size: u64,
    /// Absent once tombstoned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dep {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeRef {
    pub id: String,
    pub soname: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tombstone {
    pub reason_code: String,
    /// YYYY-MM-DD
    pub date: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProvenanceKind {
    None,
    Oidc,
}

/// Where the files were built, when a CI identity vouched for it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provenance {
    pub kind: ProvenanceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_ref: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionRecord {
    pub name: String,
    /// The spelling that was published (and is in the file name).
    pub version: String,
    /// The key create-once is enforced on (the version itself: a version has one spelling).
    pub canonical: String,
    pub build: String,
    pub state: VersionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub yank_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tombstone: Option<Tombstone>,
    pub published_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published_by: Option<String>,
    pub requires_mojo: String,
    pub deps: Vec<Dep>,
    pub native: Vec<NativeRef>,
    pub files: Vec<FileRef>,
    pub manifest_sha256: String,
    /// Absent means no provenance (`kind: none`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Provenance>,
    /// Display metadata from the package's mopm.toml `[package]` table (spec/mopm-toml.md), as of this
    /// version. Stored and served when present; the publish pipeline populates them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    /// Markdown, at most [`README_MAX_BYTES`] of UTF-8.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readme: Option<String>,
    /// The group publish that reserved this row. Absent on every row a single publish wrote. A `pending`
    /// row that has one belongs to its group: only the group's own steps may publish it, so a single publish
    /// refuses it ([`crate::state::apply_event`]) and it is not served as a version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
    /// The attempt of the group at which the validator staged this row (filled it in). A staged row is shown
    /// only once its group has committed at that same attempt; until then it stays `pending`. The Rust port
    /// reads no group header, so it never shows one. It keeps both fields when it rewrites a row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub staged_attempt: Option<u64>,
    /// Optimistic-concurrency counter: starts at 0, +1 on every state change.
    pub rev: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PackageState {
    Claimed,
    Active,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackageRecord {
    pub name: String,
    pub state: PackageState,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerRecord {
    pub name: String,
    pub github_id: u64,
    pub handle: String,
    pub added_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEntry {
    pub name: String,
    /// RFC 3339
    pub ts: String,
    /// Unique within the package; with `ts` it forms the append-only key.
    pub id: String,
    pub actor: String,
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<std::collections::BTreeMap<String, String>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::rec;

    #[test]
    fn a_version_record_round_trips_and_omits_absent_fields() {
        let r = rec("http_core", "1.2.0");
        let text = serde_json::to_string(&r).unwrap();
        let back: VersionRecord = serde_json::from_str(&text).unwrap();
        assert_eq!(back, r);
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        for absent in ["yank_reason", "tombstone", "published_by", "provenance", "description", "license", "repository", "homepage", "keywords", "readme", "group_id", "staged_attempt"] {
            assert!(!keys.contains(&absent), "{absent} must be absent, not null: {text}");
        }
        assert_eq!(v["state"], "published");
    }

    #[test]
    fn reads_a_record_the_typescript_registry_wrote() {
        // The shape of test/helpers.ts `rec`, as JSON.stringify writes it.
        let text = r#"{"name":"p","version":"1.0.0","canonical":"1.0.0","build":"mojo1.0.0_0","state":"yanked","yank_reason":"bad","published_at":"2026-10-13T12:00:00Z","requires_mojo":"==1.0.0","deps":[{"name":"q","range":">=1"},{"name":"r"}],"native":[{"id":"openssl","soname":"libssl.so.3"}],"files":[{"subdir":"linux-64","filename":"f.conda","sha256":"aa","size":1000}],"manifest_sha256":"ff","provenance":{"kind":"oidc","repository":"o/r","workflow_ref":"w"},"keywords":["a"],"rev":3}"#;
        let r: VersionRecord = serde_json::from_str(text).unwrap();
        assert_eq!(r.state, VersionState::Yanked);
        assert_eq!(r.yank_reason.as_deref(), Some("bad"));
        assert_eq!(r.deps[1].range, None);
        assert_eq!(r.provenance.as_ref().unwrap().kind, ProvenanceKind::Oidc);
        assert_eq!(r.files[0].url, None);
        assert_eq!(r.rev, 3);
    }

    #[test]
    fn a_row_staged_by_a_group_keeps_its_group_fields_through_a_round_trip() {
        let text = r#"{"name":"p","version":"1.0.0","canonical":"1.0.0","build":"b","state":"pending","published_at":"t","requires_mojo":"==1","deps":[],"native":[],"files":[],"manifest_sha256":"f","group_id":"g1","staged_attempt":2,"rev":1}"#;
        let r: VersionRecord = serde_json::from_str(text).unwrap();
        assert_eq!((r.group_id.as_deref(), r.staged_attempt, r.state), (Some("g1"), Some(2), VersionState::Pending));
        let v: serde_json::Value = serde_json::to_value(&r).unwrap();
        assert_eq!((v["group_id"].as_str(), v["staged_attempt"].as_u64()), (Some("g1"), Some(2)));
        // A reserved row has the tag and no stamp yet: the stamp is absent, not null.
        let reserved = text.replace(r#""staged_attempt":2,"#, "");
        let r: VersionRecord = serde_json::from_str(&reserved).unwrap();
        assert_eq!((r.group_id.as_deref(), r.staged_attempt), (Some("g1"), None));
        assert!(serde_json::to_value(&r).unwrap().get("staged_attempt").is_none());
    }

    #[test]
    fn a_null_where_a_field_is_absent_is_refused_as_the_wrong_type_only_for_required_fields() {
        // An optional field may be null on read (DynamoDB writers differ); a required one may not.
        let ok = r#"{"name":"p","version":"1.0.0","canonical":"1.0.0","build":"b","state":"published","yank_reason":null,"published_at":"t","requires_mojo":"==1","deps":[],"native":[],"files":[],"manifest_sha256":"f","rev":0}"#;
        assert!(serde_json::from_str::<VersionRecord>(ok).is_ok());
        let bad = ok.replace("\"rev\":0", "\"rev\":null");
        assert!(serde_json::from_str::<VersionRecord>(&bad).is_err());
    }
}
