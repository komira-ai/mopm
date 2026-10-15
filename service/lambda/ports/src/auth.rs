//! Persistence for the auth layer (`AuthStore` of `auth/types.ts`). The memory adapter defines the
//! rules; the DynamoDB adapter keeps them (`mopm_testing::auth_store_contract` runs one suite over both).

use std::future::Future;

use crate::error::PortResult;
use crate::types::{DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord};

pub trait AuthStore: Send + Sync {
    /// Insert or update by github_id, keeping created_at; returns the stored row.
    fn upsert_user(&self, github_id: u64, handle: &str, now: &str, two_factor: Option<bool>) -> impl Future<Output = PortResult<UserRecord>> + Send;
    fn get_user(&self, github_id: u64) -> impl Future<Output = PortResult<Option<UserRecord>>> + Send;

    fn put_token(&self, rec: &TokenRecord) -> impl Future<Output = PortResult<()>> + Send;
    fn get_token_by_hash(&self, hash: &str) -> impl Future<Output = PortResult<Option<TokenRecord>>> + Send;
    /// One token of one account by id; another account's token is not found. (The DynamoDB adapter reads
    /// its by-account index.)
    fn get_user_token(&self, github_id: u64, id: &str) -> impl Future<Output = PortResult<Option<TokenRecord>>> + Send;
    /// Every token of the account, any kind or state.
    fn list_tokens(&self, github_id: u64) -> impl Future<Output = PortResult<Vec<TokenRecord>>> + Send;
    /// By the token's hash (the key). Idempotent: a token that is already revoked keeps its first `revoked_at`.
    fn revoke_token(&self, hash: &str, at: &str) -> impl Future<Output = PortResult<()>> + Send;
    fn touch_token(&self, hash: &str, at: &str) -> impl Future<Output = PortResult<()>> + Send;

    fn put_device_login(&self, rec: &DeviceLoginRecord) -> impl Future<Output = PortResult<()>> + Send;
    fn get_device_login(&self, id: &str) -> impl Future<Output = PortResult<Option<DeviceLoginRecord>>> + Send;
    fn set_device_polled(&self, id: &str, at: &str, interval: u64) -> impl Future<Output = PortResult<()>> + Send;
    fn delete_device_login(&self, id: &str) -> impl Future<Output = PortResult<()>> + Send;

    fn add_trusted_publisher(&self, tp: &TrustedPublisher) -> impl Future<Output = PortResult<()>> + Send;
    fn list_trusted_publishers(&self, name: &str) -> impl Future<Output = PortResult<Vec<TrustedPublisher>>> + Send;
    fn remove_trusted_publisher(&self, name: &str, id: &str) -> impl Future<Output = PortResult<()>> + Send;
}
