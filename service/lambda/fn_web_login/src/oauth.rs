//! The GitHub OAuth app of the stage: the secret `mopm/<stage>/github-oauth`, JSON
//! `{"client_id": "...", "client_secret": "..."}` (`service/infra/access/lib/oauth-secret.ts` stores it; the TypeScript
//! `http/oauth-secret.ts` reads the client id of it for the device flow). This function is the only reader of the
//! `client_secret`, and only at cold start: a stored secret that cannot be read, is not that JSON, or has no usable
//! `client_id` or `client_secret` fails the start by name. No error here repeats a character of the secret.

use std::fmt;

use mopm_ports::error::{PortError, PortResult};
use mopm_ports::secrets::SecretReader;
use mopm_web::settings::Stage;
use thiserror::Error;

/// The name of the stage's secret that holds the app (`mopm/<stage>/github-oauth`).
pub const OAUTH_SECRET: &str = "github-oauth";

/// Why the OAuth app could not be read. The secret's id is in every message; its content is in none.
#[derive(Debug, Error)]
pub enum OAuthError {
    #[error("the GitHub OAuth secret {0} does not exist")]
    Missing(String),
    #[error("reading the GitHub OAuth secret {id}: {source}")]
    Unreadable {
        id: String,
        #[source]
        source: PortError,
    },
    #[error("the GitHub OAuth secret {0} is not JSON")]
    NotJson(String),
    #[error("the GitHub OAuth secret {0} has no usable client_id")]
    NoClientId(String),
    #[error("the GitHub OAuth secret {0} has no client_secret")]
    NoClientSecret(String),
}

/// The app's client id and client secret. `Debug` never shows the secret.
#[derive(Clone, PartialEq, Eq)]
pub struct OAuthApp {
    client_id: String,
    client_secret: String,
}

impl fmt::Debug for OAuthApp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuthApp")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .finish()
    }
}

/// `^[A-Za-z0-9._-]{4,100}$`, as `oauth-secret.ts` checks it.
fn is_client_id(s: &str) -> bool {
    (4..=100).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

impl OAuthApp {
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub fn client_secret(&self) -> &str {
        &self.client_secret
    }

    /// Reads `mopm/<stage>/github-oauth` through `secrets`, once.
    pub async fn load(secrets: &impl SecretReader, stage: &Stage) -> Result<OAuthApp, OAuthError> {
        let id = stage.secret_id(OAUTH_SECRET);
        let found = secrets.read(&id).await;
        OAuthApp::from_secret(id, found)
    }

    /// What [`OAuthApp::load`] makes of the secret `id`'s answer (not generic, so one instantiation covers it).
    fn from_secret(id: String, found: PortResult<Option<String>>) -> Result<OAuthApp, OAuthError> {
        let raw = match found {
            Ok(Some(raw)) => raw,
            Ok(None) => return Err(OAuthError::Missing(id)),
            Err(source) => return Err(OAuthError::Unreadable { id, source }),
        };
        let json: serde_json::Value =
            serde_json::from_str(&raw).map_err(|_| OAuthError::NotJson(id.clone()))?;
        let field = |name: &str| json.get(name).and_then(serde_json::Value::as_str);
        let client_id = field("client_id")
            .filter(|c| is_client_id(c))
            .ok_or_else(|| OAuthError::NoClientId(id.clone()))?;
        let client_secret = field("client_secret")
            .filter(|c| !c.is_empty())
            .ok_or(OAuthError::NoClientSecret(id))?;
        Ok(OAuthApp {
            client_id: client_id.to_string(),
            client_secret: client_secret.to_string(),
        })
    }
}

#[cfg(test)]
#[path = "oauth_tests.rs"]
mod tests;
