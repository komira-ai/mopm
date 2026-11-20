//! DynamoDB adapters of the stores, on the official SDK: the registry's three, the web sign-in's namespaces and
//! login transactions, and the stage's `config` table read by key. What the TypeScript adapters write is the contract: the item shapes (a version row is keyed by
//! the canonical version and keeps the spelling beside it, an owner's id is a string key plus a number, a token's
//! expiry is epoch seconds for the TTL plus the ISO text), the conditions (create-once is a conditional put, never a
//! read first), and the grants (what the Lambda's role may call). `wire_goldens` holds the requests, as JSON, to the
//! TS adapters' bytes.

mod auth;
mod config;
mod items;
mod namespaces;
mod publish;
mod store;
mod web_login;

use aws_sdk_dynamodb::error::DisplayErrorContext;
use mopm_ports::error::PortError;

pub use auth::{AuthTables, DynamoAuthStore};
pub use config::DynamoConfigTable;
pub use namespaces::DynamoNamespaceStore;
pub use publish::{DynamoPublishStore, PublishTables};
pub use store::{DynamoStore, Tables, SEARCH_INDEX};
pub use web_login::DynamoWebLoginStore;

/// The tokens table's index by account: partition `github_id`, sort `id`.
pub const TOKENS_BY_GITHUB_ID: &str = "by_github_id";

/// An SDK failure that is not a condition the port models: an infrastructure fault.
pub(crate) fn fault<E: std::error::Error + 'static>(what: &str, e: E) -> PortError {
    PortError::fault(format!("{what}: {}", DisplayErrorContext(e)))
}
