//! The team's E2B key: the secret `mopm/<stage>/e2b`, a JSON object `{"api_key": "<key>"}`.
//!
//! The function reads it at cold start. A key that is there is kept for the life of the process. A key that is not
//! (the operator has not written it yet, it is malformed, Secrets Manager failed) is NOT kept: the function still
//! starts, and the next request that passes the gate reads it again, so writing the key takes effect without a
//! redeploy. Until then that request is `tutorial_unavailable`. A reason is a class (`secret_missing`, ...), never
//! any of the secret's text.

use mopm_e2b::ApiKey;
use mopm_ports::error::PortResult;
use mopm_ports::secrets::SecretReader;
use serde_json::Value;
use tokio::sync::OnceCell;

/// The key, once it has been read.
pub struct KeyCache {
    secret_id: String,
    key: OnceCell<ApiKey>,
}

impl KeyCache {
    /// A cache of the secret named `secret_id`, empty.
    pub fn new(secret_id: String) -> KeyCache {
        KeyCache {
            secret_id,
            key: OnceCell::new(),
        }
    }

    /// The key: the one kept, or what `reader` gives now. Several calls at once read once.
    pub async fn get<R: SecretReader>(&self, reader: &R) -> Result<&ApiKey, &'static str> {
        self.key
            .get_or_try_init(|| async { parse(reader.read(&self.secret_id).await) })
            .await
    }
}

/// The class of what the secret read gave, or the key.
pub fn parse(found: PortResult<Option<String>>) -> Result<ApiKey, &'static str> {
    let text = found
        .map_err(|_| "secret_read_failed")?
        .ok_or("secret_missing")?;
    if text.is_empty() {
        return Err("secret_empty");
    }
    let value: Value = serde_json::from_str(&text).map_err(|_| "secret_malformed")?;
    let key = value
        .get("api_key")
        .and_then(Value::as_str)
        .ok_or("secret_malformed")?;
    if key.is_empty() {
        return Err("secret_empty");
    }
    Ok(ApiKey::new(key))
}
