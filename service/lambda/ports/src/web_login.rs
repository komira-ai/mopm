//! The web sign-in's login transaction (`docs/design/tutorial-sign-in.md`, sections 1 and 6): `start`
//! stores a row, `callback` consumes it once.
//!
//! Table `mopm-<stage>-web_logins`, partition key `id`, DynamoDB TTL attribute `expires_at`. TTL deletion is
//! lazy cleanup only: `consume` decides expiry itself, so an expired row that is still stored is refused.

use std::future::Future;

use jiff::Timestamp;
use serde::{Deserialize, Serialize};

use crate::error::PortResult;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebLoginRecord {
    /// SHA-256 of the transaction id (the `__Host-mopm_login` cookie's value), lowercase hex.
    pub id: String,
    /// SHA-256 of the `state` sent to GitHub, lowercase hex.
    pub state_hash: String,
    /// The PKCE verifier of the S256 challenge sent to GitHub.
    pub code_verifier: String,
    /// The site path to return to after the callback, already checked against the `return_to` grammar.
    pub return_to: String,
    /// Epoch seconds: DynamoDB's TTL reads a number of seconds. The row is not consumable from this second on.
    pub expires_at: i64,
    /// When `consume` took the row (`iso_millis`); absent until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_at: Option<String>,
}

impl WebLoginRecord {
    /// Expired at `now`: `now` is at or past `expires_at`.
    pub fn is_expired(&self, now: Timestamp) -> bool {
        now.as_second() >= self.expires_at
    }
}

pub trait WebLoginStore: Send + Sync {
    /// Store the row as given. Ids are hashes of 256 random bits, so a new row never meets an old one.
    fn put(&self, row: &WebLoginRecord) -> impl Future<Output = PortResult<()>> + Send;

    /// Take the row once: when it exists, has no `consumed_at` and is not expired at `now`, set `consumed_at`
    /// to `iso_millis(now)` and answer the row as stored now. Otherwise `None` and nothing written: an unknown
    /// id, a row consumed before (a second `consume` of a row is always `None`), or an expired row. Atomic: of
    /// two consumes at the same time at most one gets the row. (The DynamoDB adapter is one conditional
    /// update that returns the new row.)
    fn consume(
        &self,
        id: &str,
        now: Timestamp,
    ) -> impl Future<Output = PortResult<Option<WebLoginRecord>>> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row() -> WebLoginRecord {
        WebLoginRecord {
            id: "1".repeat(64),
            state_hash: "2".repeat(64),
            code_verifier: "verifier".into(),
            return_to: "/tutorial".into(),
            expires_at: 1_795_608_600,
            consumed_at: None,
        }
    }

    #[test]
    fn a_row_expires_at_its_second_and_not_a_millisecond_before() {
        let r = row();
        let at = |ms: i64| Timestamp::from_millisecond(ms).unwrap();
        assert!(!r.is_expired(at(1_795_608_599_999)));
        assert!(r.is_expired(at(1_795_608_600_000)));
        assert!(r.is_expired(at(1_795_608_600_001)));
    }

    #[test]
    fn a_row_is_stored_with_expires_at_a_number_and_consumed_at_absent_until_set() {
        let fresh = row();
        let json = serde_json::to_value(&fresh).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"id": "1".repeat(64), "state_hash": "2".repeat(64), "code_verifier": "verifier", "return_to": "/tutorial", "expires_at": 1_795_608_600})
        );
        assert_eq!(
            serde_json::from_value::<WebLoginRecord>(json).unwrap(),
            fresh
        );
        let taken = WebLoginRecord {
            consumed_at: Some("2026-11-19T12:00:01.000Z".into()),
            ..row()
        };
        let json = serde_json::to_value(&taken).unwrap();
        assert_eq!(json["consumed_at"], "2026-11-19T12:00:01.000Z");
        assert_eq!(
            serde_json::from_value::<WebLoginRecord>(json).unwrap(),
            taken
        );
    }
}
