//! The ports of the publish pipeline (`publish/ports.ts`): the channel bucket, presigning, CDN
//! invalidation, the queues, the read-only switch, and the persistence of uploads, publishes, the
//! per-version commit lock and the rate counters.

use std::collections::BTreeMap;
use std::future::Future;

use crate::error::PortResult;
use crate::types::{PublishRecord, UploadRecord};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObjectInfo {
    pub size: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PutOptions {
    pub content_type: String,
    pub cache_control: Option<String>,
    /// Refuse to replace an existing object (S3 `If-None-Match: *`) and answer [`PutOutcome::Exists`].
    pub create_only: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PutOutcome {
    Created,
    Exists,
}

/// The channel bucket: `quarantine/`, `<subdir>/<file>.conda` and `<subdir>/repodata.json(.zst)`.
pub trait ObjectStore: Send + Sync {
    /// Size of the object, or `None` when it is absent.
    fn head(&self, key: &str) -> impl Future<Output = PortResult<Option<ObjectInfo>>> + Send;
    /// The bytes, or `None` when absent.
    fn get(&self, key: &str) -> impl Future<Output = PortResult<Option<Vec<u8>>>> + Send;
    fn put(&self, key: &str, body: &[u8], opts: &PutOptions) -> impl Future<Output = PortResult<PutOutcome>> + Send;
    fn delete(&self, key: &str) -> impl Future<Output = PortResult<()>> + Send;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PresignedPut {
    pub url: String,
    /// The caller must send these exactly: they are part of the signature.
    pub headers: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PresignRequest<'a> {
    pub size: u64,
    /// Lowercase hex.
    pub sha256: &'a str,
    pub expires_in_seconds: u64,
}

/// A presigned PUT pinned to one exact length and sha256. No I/O beyond reading the clock the signer holds.
pub trait Presigner: Send + Sync {
    fn presign_put(&self, key: &str, req: &PresignRequest<'_>) -> impl Future<Output = PortResult<PresignedPut>> + Send;
}

pub trait Invalidator: Send + Sync {
    /// Paths start with `/`. The reference makes a retry of the same batch idempotent.
    fn invalidate(&self, paths: &[String], reference: &str) -> impl Future<Output = PortResult<()>> + Send;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueMessage {
    pub body: String,
    /// FIFO `MessageGroupId`: messages of one group are delivered one at a time, in order.
    pub group_id: String,
    /// FIFO `MessageDeduplicationId`.
    pub dedup_id: String,
}

pub trait Queue: Send + Sync {
    fn send(&self, m: &QueueMessage) -> impl Future<Output = PortResult<()>> + Send;
}

/// Whether new uploads are refused. Reads never consult it.
pub trait Flags: Send + Sync {
    fn read_only(&self) -> impl Future<Output = PortResult<bool>> + Send;
}

/// The result of counting one hit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hit {
    pub ok: bool,
    pub count: u64,
}

/// Persistence of the publish pipeline: upload records, publish records, the per-version commit lock and
/// the rate counters. Every method is atomic (a conditional write in DynamoDB).
pub trait PublishStore: Send + Sync {
    fn put_upload(&self, u: &UploadRecord) -> impl Future<Output = PortResult<()>> + Send;
    fn get_upload(&self, id: &str) -> impl Future<Output = PortResult<Option<UploadRecord>>> + Send;
    /// Mark the upload as taken by a publish. `false` when another publish took it (or it does not exist);
    /// `true` again for the same one.
    fn use_upload(&self, id: &str, publish_id: &str) -> impl Future<Output = PortResult<bool>> + Send;

    /// Create-once lock on (name, canonical version): the publish id that holds it (the caller's when it won).
    fn claim_version(&self, name: &str, canonical: &str, publish_id: &str) -> impl Future<Output = PortResult<String>> + Send;
    fn version_holder(&self, name: &str, canonical: &str) -> impl Future<Output = PortResult<Option<String>>> + Send;

    /// Create-once. Returns the stored record: the argument when created, the existing one otherwise.
    fn create_publish(&self, rec: &PublishRecord) -> impl Future<Output = PortResult<PublishRecord>> + Send;
    fn get_publish(&self, id: &str) -> impl Future<Output = PortResult<Option<PublishRecord>>> + Send;
    /// Read, apply `f`, write back only if nothing changed in between (retrying, so `f` may run more than
    /// once). `f` returns the new record, or `None` to leave it. Returns the record as it is afterwards, or
    /// `None` when there is none. The stored `rev` is the previous one plus one, whatever `f` put in it.
    fn update_publish<F>(&self, id: &str, f: F) -> impl Future<Output = PortResult<Option<PublishRecord>>> + Send
    where
        F: FnMut(&PublishRecord) -> Option<PublishRecord> + Send;

    /// Count one hit on `key` unless it already has `limit`. `expires_at` is epoch seconds (TTL cleanup).
    fn hit(&self, key: &str, limit: u64, expires_at: i64) -> impl Future<Output = PortResult<Hit>> + Send;
}
