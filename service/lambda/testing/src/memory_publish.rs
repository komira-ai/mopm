//! The in-memory publish pipeline (`publish/memory.ts`): publish store, channel bucket, presigner, queue,
//! invalidator and flags, plus the one thing S3 does with a presigned PUT that the tests need.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, MutexGuard};

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::publish::{
    Flags, Hit, Invalidator, ObjectInfo, ObjectStore, PresignRequest, PresignedPut, Presigner, PublishStore, PutOptions, PutOutcome, Queue, QueueMessage,
};
use mopm_ports::secrets::SecretReader;
use mopm_ports::types::{PublishRecord, UploadRecord};
use sha2::{Digest, Sha256};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().expect("a lock is never held across a panic")
}

#[derive(Default)]
struct PublishInner {
    uploads: BTreeMap<String, UploadRecord>,
    publishes: BTreeMap<String, PublishRecord>,
    locks: BTreeMap<(String, String), String>,
    counters: BTreeMap<String, u64>,
}

#[derive(Default)]
pub struct MemoryPublishStore {
    inner: Mutex<PublishInner>,
}

impl MemoryPublishStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl PublishStore for MemoryPublishStore {
    async fn put_upload(&self, u: &UploadRecord) -> PortResult<()> {
        lock(&self.inner).uploads.insert(u.upload_id.clone(), u.clone());
        Ok(())
    }

    async fn get_upload(&self, id: &str) -> PortResult<Option<UploadRecord>> {
        Ok(lock(&self.inner).uploads.get(id).cloned())
    }

    async fn use_upload(&self, id: &str, publish_id: &str) -> PortResult<bool> {
        let mut g = lock(&self.inner);
        let Some(u) = g.uploads.get_mut(id) else { return Ok(false) };
        match &u.used_by {
            Some(by) => Ok(by == publish_id),
            None => {
                u.used_by = Some(publish_id.to_string());
                Ok(true)
            }
        }
    }

    async fn claim_version(&self, name: &str, canonical: &str, publish_id: &str) -> PortResult<String> {
        let mut g = lock(&self.inner);
        let held = g.locks.entry((name.to_string(), canonical.to_string())).or_insert_with(|| publish_id.to_string());
        Ok(held.clone())
    }

    async fn version_holder(&self, name: &str, canonical: &str) -> PortResult<Option<String>> {
        Ok(lock(&self.inner).locks.get(&(name.to_string(), canonical.to_string())).cloned())
    }

    async fn create_publish(&self, rec: &PublishRecord) -> PortResult<PublishRecord> {
        let mut g = lock(&self.inner);
        Ok(g.publishes.entry(rec.publish_id.clone()).or_insert_with(|| rec.clone()).clone())
    }

    async fn get_publish(&self, id: &str) -> PortResult<Option<PublishRecord>> {
        Ok(lock(&self.inner).publishes.get(id).cloned())
    }

    async fn update_publish<F>(&self, id: &str, mut f: F) -> PortResult<Option<PublishRecord>>
    where
        F: FnMut(&PublishRecord) -> Option<PublishRecord> + Send,
    {
        let mut g = lock(&self.inner);
        let Some(cur) = g.publishes.get(id).cloned() else { return Ok(None) };
        match f(&cur) {
            None => Ok(Some(cur)),
            Some(next) => {
                let stored = PublishRecord { rev: cur.rev + 1, ..next };
                g.publishes.insert(id.to_string(), stored.clone());
                Ok(Some(stored))
            }
        }
    }

    async fn hit(&self, key: &str, limit: u64, _expires_at: i64) -> PortResult<Hit> {
        let mut g = lock(&self.inner);
        let n = g.counters.entry(key.to_string()).or_insert(0);
        if *n >= limit {
            return Ok(Hit { ok: false, count: *n });
        }
        *n += 1;
        Ok(Hit { ok: true, count: *n })
    }
}

struct Object {
    body: Vec<u8>,
    content_type: String,
    cache_control: Option<String>,
}

#[derive(Default)]
struct ObjectInner {
    objects: BTreeMap<String, Object>,
    log: Vec<String>,
}

/// The channel bucket in memory. `log` records every put and delete in order.
#[derive(Default)]
pub struct MemoryObjectStore {
    inner: Mutex<ObjectInner>,
}

impl MemoryObjectStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Keys starting with `prefix`, sorted.
    pub fn keys(&self, prefix: &str) -> Vec<String> {
        lock(&self.inner).objects.keys().filter(|k| k.starts_with(prefix)).cloned().collect()
    }

    /// `put <key>` and `delete <key>`, in the order they happened.
    pub fn log(&self) -> Vec<String> {
        lock(&self.inner).log.clone()
    }

    /// The content type and cache control an object was written with.
    pub fn headers_of(&self, key: &str) -> Option<(String, Option<String>)> {
        lock(&self.inner).objects.get(key).map(|o| (o.content_type.clone(), o.cache_control.clone()))
    }
}

impl ObjectStore for MemoryObjectStore {
    async fn head(&self, key: &str) -> PortResult<Option<ObjectInfo>> {
        Ok(lock(&self.inner).objects.get(key).map(|o| ObjectInfo { size: o.body.len() as u64 }))
    }

    async fn get(&self, key: &str) -> PortResult<Option<Vec<u8>>> {
        Ok(lock(&self.inner).objects.get(key).map(|o| o.body.clone()))
    }

    async fn put(&self, key: &str, body: &[u8], opts: &PutOptions) -> PortResult<PutOutcome> {
        let mut g = lock(&self.inner);
        g.log.push(format!("put {key}"));
        if opts.create_only && g.objects.contains_key(key) {
            return Ok(PutOutcome::Exists);
        }
        g.objects.insert(key.to_string(), Object { body: body.to_vec(), content_type: opts.content_type.clone(), cache_control: opts.cache_control.clone() });
        Ok(PutOutcome::Created)
    }

    async fn delete(&self, key: &str) -> PortResult<()> {
        let mut g = lock(&self.inner);
        g.log.push(format!("delete {key}"));
        g.objects.remove(key);
        Ok(())
    }
}

/// What S3 does with a presigned PUT, as far as the tests need: the bytes must have exactly the signed length
/// and the signed sha256, and the URL must not be expired. It reads back what `presign_put` returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UploadVerdict {
    Ok,
    Expired,
    BadLength,
    BadChecksum,
}

pub struct FakeS3Upload<'a> {
    store: &'a MemoryObjectStore,
}

impl<'a> FakeS3Upload<'a> {
    pub fn new(store: &'a MemoryObjectStore) -> Self {
        FakeS3Upload { store }
    }

    /// `now` and `expires_at` are epoch milliseconds.
    pub async fn put(&self, key: &str, signed: &PresignedPut, body: &[u8], now: i64, expires_at: i64) -> PortResult<UploadVerdict> {
        if now > expires_at {
            return Ok(UploadVerdict::Expired);
        }
        if signed.headers.get("content-length").map(String::as_str) != Some(body.len().to_string().as_str()) {
            return Ok(UploadVerdict::BadLength);
        }
        let sum = STANDARD.encode(Sha256::digest(body));
        if signed.headers.get("x-amz-checksum-sha256") != Some(&sum) {
            return Ok(UploadVerdict::BadChecksum);
        }
        self.store.put(key, body, &PutOptions { content_type: "application/octet-stream".to_string(), ..PutOptions::default() }).await?;
        Ok(UploadVerdict::Ok)
    }
}

/// Signs nothing: the URL names the key, and the headers are the ones a real signature would pin.
#[derive(Default)]
pub struct MemoryPresigner;

impl Presigner for MemoryPresigner {
    async fn presign_put(&self, key: &str, req: &PresignRequest<'_>) -> PortResult<PresignedPut> {
        let digest = hex::decode(req.sha256).map_err(|e| PortError::fault(format!("sha256 is not hex: {e}")))?;
        Ok(PresignedPut {
            url: format!("https://bucket.invalid/{key}?expires={}", req.expires_in_seconds),
            headers: BTreeMap::from([
                ("content-length".to_string(), req.size.to_string()),
                ("x-amz-checksum-sha256".to_string(), STANDARD.encode(digest)),
            ]),
        })
    }
}

#[derive(Default)]
struct QueueInner {
    sent: Vec<QueueMessage>,
    /// Dedup ids seen: FIFO drops a repeat within its window.
    seen: BTreeSet<String>,
}

#[derive(Default)]
pub struct MemoryQueue {
    inner: Mutex<QueueInner>,
}

impl MemoryQueue {
    pub fn new() -> Self {
        Self::default()
    }

    /// The next message, oldest first.
    pub fn take(&self) -> Option<QueueMessage> {
        let mut g = lock(&self.inner);
        (!g.sent.is_empty()).then(|| g.sent.remove(0))
    }

    /// Everything sent and not taken.
    pub fn sent(&self) -> Vec<QueueMessage> {
        lock(&self.inner).sent.clone()
    }
}

impl Queue for MemoryQueue {
    async fn send(&self, m: &QueueMessage) -> PortResult<()> {
        let mut g = lock(&self.inner);
        if g.seen.insert(m.dedup_id.clone()) {
            g.sent.push(m.clone());
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct MemoryInvalidator {
    batches: Mutex<Vec<(Vec<String>, String)>>,
}

impl MemoryInvalidator {
    pub fn new() -> Self {
        Self::default()
    }

    /// (paths, reference) of every call.
    pub fn batches(&self) -> Vec<(Vec<String>, String)> {
        lock(&self.batches).clone()
    }
}

impl Invalidator for MemoryInvalidator {
    async fn invalidate(&self, paths: &[String], reference: &str) -> PortResult<()> {
        lock(&self.batches).push((paths.to_vec(), reference.to_string()));
        Ok(())
    }
}

/// Secrets by id; an absent id is `None`, as in Secrets Manager.
#[derive(Default)]
pub struct MemorySecrets(Mutex<BTreeMap<String, String>>);

impl MemorySecrets {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&self, id: &str, value: &str) {
        lock(&self.0).insert(id.to_string(), value.to_string());
    }
}

impl SecretReader for MemorySecrets {
    async fn read(&self, secret_id: &str) -> PortResult<Option<String>> {
        Ok(lock(&self.0).get(secret_id).cloned())
    }
}

/// A switch the test flips.
#[derive(Default)]
pub struct StaticFlags(Mutex<bool>);

impl StaticFlags {
    pub fn new(read_only: bool) -> Self {
        StaticFlags(Mutex::new(read_only))
    }

    pub fn set(&self, read_only: bool) {
        *lock(&self.0) = read_only;
    }
}

impl Flags for StaticFlags {
    async fn read_only(&self) -> PortResult<bool> {
        Ok(*lock(&self.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put_opts(create_only: bool) -> PutOptions {
        PutOptions { content_type: "application/json".to_string(), cache_control: Some("max-age=60".to_string()), create_only }
    }

    #[tokio::test]
    async fn objects_are_put_read_headed_and_deleted_and_the_log_keeps_the_order() {
        let s = MemoryObjectStore::new();
        assert_eq!(s.head("a").await.unwrap(), None);
        assert_eq!(s.put("a", b"hello", &put_opts(false)).await.unwrap(), PutOutcome::Created);
        assert_eq!(s.head("a").await.unwrap(), Some(ObjectInfo { size: 5 }));
        assert_eq!(s.get("a").await.unwrap().as_deref(), Some(&b"hello"[..]));
        assert_eq!(s.headers_of("a"), Some(("application/json".to_string(), Some("max-age=60".to_string()))));
        s.put("a", b"hi", &put_opts(false)).await.unwrap();
        assert_eq!(s.get("a").await.unwrap().as_deref(), Some(&b"hi"[..]), "an ordinary put replaces");
        s.delete("a").await.unwrap();
        assert_eq!(s.get("a").await.unwrap(), None);
        assert_eq!(s.log(), ["put a", "put a", "delete a"]);
    }

    #[tokio::test]
    async fn create_only_refuses_to_replace_and_says_so() {
        let s = MemoryObjectStore::new();
        assert_eq!(s.put("k", b"one", &put_opts(true)).await.unwrap(), PutOutcome::Created);
        assert_eq!(s.put("k", b"two", &put_opts(true)).await.unwrap(), PutOutcome::Exists);
        assert_eq!(s.get("k").await.unwrap().as_deref(), Some(&b"one"[..]));
    }

    #[tokio::test]
    async fn keys_lists_by_prefix_in_order() {
        let s = MemoryObjectStore::new();
        for k in ["quarantine/b", "linux-64/x", "quarantine/a"] {
            s.put(k, b"", &put_opts(false)).await.unwrap();
        }
        assert_eq!(s.keys("quarantine/"), ["quarantine/a", "quarantine/b"]);
        assert_eq!(s.keys("").len(), 3);
    }

    const HELLO_SHA256: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

    async fn signed(size: u64, sha: &str) -> PresignedPut {
        MemoryPresigner.presign_put("quarantine/u1/f", &PresignRequest { size, sha256: sha, expires_in_seconds: 300 }).await.unwrap()
    }

    #[tokio::test]
    async fn the_presigner_pins_length_and_checksum_as_s3_wants_them() {
        let p = signed(5, HELLO_SHA256).await;
        assert_eq!(p.url, "https://bucket.invalid/quarantine/u1/f?expires=300");
        assert_eq!(p.headers["content-length"], "5");
        // base64 of the digest's bytes, as the x-amz-checksum-sha256 header carries it (printf hello | openssl dgst -sha256 -binary | base64)
        assert_eq!(p.headers["x-amz-checksum-sha256"], "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=");
    }

    #[tokio::test]
    async fn a_sha256_that_is_not_hex_is_a_fault_not_a_panic() {
        let e = MemoryPresigner.presign_put("k", &PresignRequest { size: 1, sha256: "zz", expires_in_seconds: 1 }).await.unwrap_err();
        assert!(e.registry().is_none());
    }

    #[tokio::test]
    async fn the_fake_s3_accepts_exact_bytes_and_refuses_the_rest() {
        let bucket = MemoryObjectStore::new();
        let s3 = FakeS3Upload::new(&bucket);
        let p = signed(5, HELLO_SHA256).await;
        assert_eq!(s3.put("quarantine/u1/f", &p, b"hello", 1_000, 2_000).await.unwrap(), UploadVerdict::Ok);
        assert_eq!(bucket.get("quarantine/u1/f").await.unwrap().as_deref(), Some(&b"hello"[..]));
        let other = MemoryObjectStore::new();
        let s3 = FakeS3Upload::new(&other);
        assert_eq!(s3.put("k", &p, b"hello", 2_001, 2_000).await.unwrap(), UploadVerdict::Expired);
        assert_eq!(s3.put("k", &p, b"hell", 1_000, 2_000).await.unwrap(), UploadVerdict::BadLength);
        assert_eq!(s3.put("k", &p, b"hellp", 1_000, 2_000).await.unwrap(), UploadVerdict::BadChecksum);
        assert!(other.keys("").is_empty(), "nothing was stored by a refused upload");
        // the last millisecond of validity still counts
        assert_eq!(s3.put("k", &p, b"hello", 2_000, 2_000).await.unwrap(), UploadVerdict::Ok);
    }

    fn msg(body: &str, group: &str, dedup: &str) -> QueueMessage {
        QueueMessage { body: body.to_string(), group_id: group.to_string(), dedup_id: dedup.to_string() }
    }

    #[tokio::test]
    async fn the_fifo_queue_drops_a_repeated_dedup_id_and_delivers_oldest_first() {
        let q = MemoryQueue::new();
        q.send(&msg("one", "g", "d1")).await.unwrap();
        q.send(&msg("two", "g", "d2")).await.unwrap();
        q.send(&msg("one again", "g", "d1")).await.unwrap();
        assert_eq!(q.sent().len(), 2);
        assert_eq!(q.take().unwrap().body, "one");
        assert_eq!(q.take().unwrap().body, "two");
        assert!(q.take().is_none());
        q.send(&msg("one once more", "g", "d1")).await.unwrap();
        assert!(q.take().is_none(), "a taken message's dedup id is still remembered");
    }

    #[tokio::test]
    async fn the_invalidator_records_each_batch_with_its_reference() {
        let i = MemoryInvalidator::new();
        i.invalidate(&["/linux-64/repodata.json".to_string()], "ref-1").await.unwrap();
        i.invalidate(&["/noarch/repodata.json".to_string(), "/noarch/repodata.json.zst".to_string()], "ref-2").await.unwrap();
        assert_eq!(i.batches().len(), 2);
        assert_eq!(i.batches()[1], (vec!["/noarch/repodata.json".to_string(), "/noarch/repodata.json.zst".to_string()], "ref-2".to_string()));
    }

    #[tokio::test]
    async fn the_flag_is_what_the_test_set() {
        let f = StaticFlags::new(false);
        assert!(!f.read_only().await.unwrap());
        f.set(true);
        assert!(f.read_only().await.unwrap());
    }
}
