//! The records of the auth and publish layers (`auth/types.ts`, `publish/types.ts`) and the
//! messages the queues carry. Shapes are the TypeScript registry's: a record written by one
//! implementation is read by the other, so an optional field is absent, never `null`.

use mopm_core::display::DisplayMeta;
use mopm_core::rejection::RejectionCode;
use serde::{Deserialize, Serialize};

/// What a package search needs from a package: the search index projects exactly these attributes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackageSummary {
    pub name: String,
    pub state: mopm_core::types::PackageState,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

// ---- auth ------------------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserRecord {
    /// Numeric GitHub account id: the identity. The handle can change; the id cannot.
    pub github_id: u64,
    pub handle: String,
    pub created_at: String,
    pub last_login_at: String,
    /// What GitHub said at the last login: absent when GitHub did not show it for the granted scope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub two_factor: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenKind {
    Session,
    Api,
    Oidc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenScope {
    Publish,
    Yank,
}

/// Only the SHA-256 of the secret and a short display prefix are stored; the secret itself exists once,
/// in the response that creates it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenRecord {
    pub id: String,
    pub kind: TokenKind,
    /// The owning account; absent for an `oidc` token, which belongs to a CI identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_id: Option<u64>,
    pub name: String,
    /// SHA-256 of the whole token, lowercase hex.
    pub hash: String,
    /// First characters of the token, for lists and for support; never enough to use it.
    pub prefix: String,
    pub scopes: Vec<TokenScope>,
    /// Packages the scopes apply to. For `all_current` this is the snapshot taken at creation.
    pub packages: Vec<String>,
    pub all_current: bool,
    /// An `oidc` token is good for exactly this version of its single package.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Session tokens only: full-strength actions need a login newer than this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fresh_until: Option<String>,
    pub created_at: String,
    pub expires_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
    /// For an `oidc` token: the repository whose workflow earned it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issued_to: Option<String>,
}

/// A login that was started and not yet finished. The caller's device_code is never stored, only its hash.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceLoginRecord {
    /// SHA-256 of the device code handed to the CLI.
    pub id: String,
    /// GitHub's own device code: server side only.
    pub github_device_code: String,
    pub client: String,
    pub created_at: String,
    pub expires_at: String,
    pub interval: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_polled_at: Option<String>,
}

/// Registered by a package owner: this CI identity may publish this package. Matching is on GitHub's
/// numeric ids (a repository renamed or re-created under the same name does not match), never on names alone.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustedPublisher {
    /// Unique within the package.
    pub id: String,
    pub name: String,
    pub repository_id: String,
    pub repository_owner_id: String,
    /// Workflow file path in the repository, e.g. `.github/workflows/release.yml`.
    pub workflow: String,
    /// When set, the job must run in this deployment environment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    pub added_by: u64,
    pub added_at: String,
}

// ---- publish -----------------------------------------------------------------------------------

/// `u:<github id>` for an account's token, `ci:<token id>` for a CI identity's token.
pub type Actor = String;

/// One file of a version, announced by begin-upload. The presigned URL points at `key` in quarantine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadRecord {
    pub upload_id: String,
    pub name: String,
    /// The spelling the caller used; commit must use the same one.
    pub version: String,
    pub canonical: String,
    pub subdir: String,
    pub filename: String,
    pub sha256: String,
    pub size: u64,
    /// `quarantine/<upload id>/<filename>`
    pub key: String,
    pub actor: Actor,
    pub created_at: String,
    pub url_expires_at: String,
    /// Epoch seconds: the table's TTL attribute (lazy cleanup) and the end of the commit window.
    pub expires_at: i64,
    /// Set when a commit takes the upload; single use.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_by: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PublishStatus {
    Pending,
    Validating,
    Indexing,
    Published,
    Rejected,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishFile {
    pub upload_id: String,
    pub subdir: String,
    pub filename: String,
    pub sha256: String,
    pub size: u64,
    pub key: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishRecord {
    pub publish_id: String,
    pub name: String,
    pub version: String,
    pub canonical: String,
    pub actor: Actor,
    pub published_by: String,
    pub status: PublishStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection_code: Option<RejectionCode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub manifest_sha256: String,
    /// Display metadata from the commit request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display: Option<DisplayMeta>,
    pub files: Vec<PublishFile>,
    /// Subdirs whose repodata does not yet list this publish (set when the version is published).
    pub remaining_subdirs: Vec<String>,
    pub created_at: String,
    pub updated_at: String,
    /// Optimistic-concurrency counter, +1 per change.
    pub rev: u64,
}

/// What the two queues carry, tagged by `type` as the TypeScript registry writes them: `validate` goes
/// to the validator queue, `index` to the index queue (without a publish id it is a plain rebuild: init,
/// a later yank). A worker refuses the other kind, which is what a tagged enum does on read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum QueueBody {
    Validate {
        publish_id: String,
    },
    Index {
        subdir: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        publish_id: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token() -> TokenRecord {
        TokenRecord {
            id: "t1".into(),
            kind: TokenKind::Api,
            github_id: Some(7),
            name: "ci".into(),
            hash: "a".repeat(64),
            prefix: "mopm_ab".into(),
            scopes: vec![TokenScope::Publish, TokenScope::Yank],
            packages: vec!["p".into()],
            all_current: false,
            version: None,
            fresh_until: None,
            created_at: "2026-10-13T12:00:00.000Z".into(),
            expires_at: "2026-11-13T12:00:00.000Z".into(),
            revoked_at: None,
            last_used_at: None,
            issued_to: None,
        }
    }

    #[test]
    fn a_token_serialises_with_the_typescript_names_and_no_nulls() {
        let v: serde_json::Value = serde_json::to_value(token()).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["all_current", "created_at", "expires_at", "github_id", "hash", "id", "kind", "name", "packages", "prefix", "scopes"]);
        assert_eq!(v["kind"], "api");
        assert_eq!(v["scopes"], serde_json::json!(["publish", "yank"]));
    }

    #[test]
    fn an_oidc_token_has_no_account() {
        let mut t = token();
        t.kind = TokenKind::Oidc;
        t.github_id = None;
        t.version = Some("1.0.0".into());
        let back: TokenRecord = serde_json::from_str(&serde_json::to_string(&t).unwrap()).unwrap();
        assert_eq!(back, t);
        assert!(serde_json::to_value(&t).unwrap().get("github_id").is_none());
    }

    #[test]
    fn queue_messages_carry_their_type_tag() {
        let v = QueueBody::Validate { publish_id: "p1".into() };
        assert_eq!(serde_json::to_string(&v).unwrap(), r#"{"type":"validate","publish_id":"p1"}"#);
        let i = QueueBody::Index { subdir: "linux-64".into(), publish_id: None };
        assert_eq!(serde_json::to_string(&i).unwrap(), r#"{"type":"index","subdir":"linux-64"}"#);
        let i = QueueBody::Index { subdir: "noarch".into(), publish_id: Some("p1".into()) };
        assert_eq!(serde_json::to_string(&i).unwrap(), r#"{"type":"index","subdir":"noarch","publish_id":"p1"}"#);
        assert_eq!(serde_json::from_str::<QueueBody>(r#"{"type":"index","subdir":"noarch"}"#).unwrap(), QueueBody::Index { subdir: "noarch".into(), publish_id: None });
        // An unknown type, or a body of the other type's shape, is refused.
        assert!(serde_json::from_str::<QueueBody>(r#"{"type":"nope","publish_id":"p"}"#).is_err());
        assert!(serde_json::from_str::<QueueBody>(r#"{"type":"validate","subdir":"x"}"#).is_err());
    }

    #[test]
    fn a_publish_record_round_trips_with_display_and_rejection() {
        let r = PublishRecord {
            publish_id: "p1".into(),
            name: "http".into(),
            version: "1.0.0".into(),
            canonical: "1.0.0".into(),
            actor: "u:7".into(),
            published_by: "octocat".into(),
            status: PublishStatus::Rejected,
            rejection_code: Some(RejectionCode::LimitExceeded),
            message: Some("too big".into()),
            manifest_sha256: "f".repeat(64),
            display: Some(DisplayMeta { description: Some("d".into()), ..DisplayMeta::default() }),
            files: vec![],
            remaining_subdirs: vec!["linux-64".into()],
            created_at: "t".into(),
            updated_at: "t".into(),
            rev: 2,
        };
        let text = serde_json::to_string(&r).unwrap();
        assert!(text.contains(r#""rejection_code":"limit_exceeded""#), "{text}");
        assert!(text.contains(r#""status":"rejected""#));
        assert_eq!(serde_json::from_str::<PublishRecord>(&text).unwrap(), r);
    }
}
