//! Secrets (`SecretReader` of `http/oauth-secret.ts`).

use std::future::Future;

use crate::error::PortResult;

/// Reads a secret's string value; `None` when the secret does not exist. Any other failure is an error.
pub trait SecretReader: Send + Sync {
    fn read(&self, secret_id: &str) -> impl Future<Output = PortResult<Option<String>>> + Send;
}
