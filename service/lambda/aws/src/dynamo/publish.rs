//! `PublishStore` on DynamoDB (`publish/dynamo-publish-store.ts`). Every mutation is a conditional
//! `PutItem` (create-once, or compare-and-swap on `rev`), so the role needs `GetItem` and `PutItem` only.
//! `publishes` is keyed by `publish_id` and holds three kinds of row, told apart by the key's prefix:
//! `pub_...` publish records, `ver#<name>#<canonical>` commit locks, `rl#...` counters.

use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::operation::put_item::PutItemError;
use aws_sdk_dynamodb::Client;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::publish::{Hit, PublishStore};
use mopm_ports::types::{PublishRecord, UploadRecord};
use serde_json::{json, Map, Value};

use super::items::{from_item, n, names, object, record, s, to_item, values};
use super::fault;

const MAX_ATTEMPTS: usize = 8;
/// A counter is hit by every begin of an account or token: a CLI uploading 20 files in parallel contends on it.
const MAX_HIT_ATTEMPTS: usize = 40;

/// Table names (`mopm-<stage>-<table>`) the publish path uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublishTables {
    pub uploads: String,
    pub publishes: String,
    pub config: String,
    pub tokens: String,
}

impl PublishTables {
    pub fn for_stage(stage: &str) -> PublishTables {
        PublishTables {
            uploads: format!("mopm-{stage}-uploads"),
            publishes: format!("mopm-{stage}-publishes"),
            config: format!("mopm-{stage}-config"),
            tokens: format!("mopm-{stage}-tokens"),
        }
    }
}

pub struct DynamoPublishStore {
    client: Client,
    uploads: String,
    publishes: String,
}

fn condition_failed(e: &SdkError<PutItemError>) -> bool {
    e.as_service_error().is_some_and(PutItemError::is_conditional_check_failed_exception)
}

impl DynamoPublishStore {
    pub fn new(client: Client, tables: &PublishTables) -> Self {
        DynamoPublishStore { client, uploads: tables.uploads.clone(), publishes: tables.publishes.clone() }
    }

    async fn get(&self, table: &str, key_attr: &str, key: &str) -> PortResult<Option<Map<String, Value>>> {
        let r = self
            .client
            .get_item()
            .table_name(table)
            .set_key(Some(values([(key_attr, s(key))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get item", e))?;
        r.item.map(from_item).transpose()
    }

    async fn put_if_absent(&self, table: &str, key_attr: &str, item: Map<String, Value>) -> PortResult<bool> {
        let r = self
            .client
            .put_item()
            .table_name(table)
            .set_item(Some(to_item(item)?))
            .condition_expression("attribute_not_exists(#k)")
            .set_expression_attribute_names(Some(names([("#k", key_attr)])))
            .send()
            .await;
        match r {
            Ok(_) => Ok(true),
            Err(e) if condition_failed(&e) => Ok(false),
            Err(e) => Err(fault("put item", e)),
        }
    }

    /// Replace the item only if its `rev` is still `rev`.
    async fn swap(&self, table: &str, item: Map<String, Value>, rev: u64) -> PortResult<bool> {
        let r = self
            .client
            .put_item()
            .table_name(table)
            .set_item(Some(to_item(item)?))
            .condition_expression("#r = :r")
            .set_expression_attribute_names(Some(names([("#r", "rev")])))
            .set_expression_attribute_values(Some(values([(":r", n(rev))])))
            .send()
            .await;
        match r {
            Ok(_) => Ok(true),
            Err(e) if condition_failed(&e) => Ok(false),
            Err(e) => Err(fault("swap item", e)),
        }
    }

    fn lock_key(name: &str, canonical: &str) -> String {
        format!("ver#{name}#{canonical}")
    }
}

impl PublishStore for DynamoPublishStore {
    async fn put_upload(&self, u: &UploadRecord) -> PortResult<()> {
        if self.put_if_absent(&self.uploads, "upload_id", object(u)?).await? {
            Ok(())
        } else {
            Err(PortError::fault(format!("upload {} already exists", u.upload_id)))
        }
    }

    async fn get_upload(&self, id: &str) -> PortResult<Option<UploadRecord>> {
        self.get(&self.uploads, "upload_id", id).await?.map(record).transpose()
    }

    async fn use_upload(&self, id: &str, publish_id: &str) -> PortResult<bool> {
        for _ in 0..MAX_ATTEMPTS {
            let Some(mut cur) = self.get(&self.uploads, "upload_id", id).await? else { return Ok(false) };
            if let Some(by) = cur.get("used_by").and_then(Value::as_str) {
                return Ok(by == publish_id);
            }
            cur.insert("used_by".into(), Value::String(publish_id.to_string()));
            let r = self
                .client
                .put_item()
                .table_name(&self.uploads)
                .set_item(Some(to_item(cur)?))
                .condition_expression("attribute_not_exists(#u)")
                .set_expression_attribute_names(Some(names([("#u", "used_by")])))
                .send()
                .await;
            match r {
                Ok(_) => return Ok(true),
                Err(e) if condition_failed(&e) => {}
                Err(e) => return Err(fault("take upload", e)),
            }
        }
        Err(PortError::fault(format!("upload {id} changed too often while being taken")))
    }

    async fn claim_version(&self, name: &str, canonical: &str, publish_id: &str) -> PortResult<String> {
        let key = Self::lock_key(name, canonical);
        let row = json!({"publish_id": key, "winner": publish_id}).as_object().cloned().unwrap_or_default();
        if self.put_if_absent(&self.publishes, "publish_id", row).await? {
            return Ok(publish_id.to_string());
        }
        let held = self.get(&self.publishes, "publish_id", &key).await?.ok_or_else(|| PortError::fault("the version lock vanished"))?;
        held.get("winner").and_then(Value::as_str).map(str::to_string).ok_or_else(|| PortError::fault("a version lock without a winner"))
    }

    async fn version_holder(&self, name: &str, canonical: &str) -> PortResult<Option<String>> {
        let held = self.get(&self.publishes, "publish_id", &Self::lock_key(name, canonical)).await?;
        Ok(held.and_then(|h| h.get("winner").and_then(Value::as_str).map(str::to_string)))
    }

    async fn create_publish(&self, rec: &PublishRecord) -> PortResult<PublishRecord> {
        if self.put_if_absent(&self.publishes, "publish_id", object(rec)?).await? {
            return Ok(rec.clone());
        }
        self.get_publish(&rec.publish_id).await?.ok_or_else(|| PortError::fault("the publish vanished"))
    }

    async fn get_publish(&self, id: &str) -> PortResult<Option<PublishRecord>> {
        self.get(&self.publishes, "publish_id", id).await?.map(record).transpose()
    }

    async fn update_publish<F>(&self, id: &str, mut f: F) -> PortResult<Option<PublishRecord>>
    where
        F: FnMut(&PublishRecord) -> Option<PublishRecord> + Send,
    {
        for _ in 0..MAX_ATTEMPTS {
            let Some(cur) = self.get_publish(id).await? else { return Ok(None) };
            let Some(next) = f(&cur) else { return Ok(Some(cur)) };
            let written = PublishRecord { rev: cur.rev + 1, ..next };
            if self.swap(&self.publishes, object(&written)?, cur.rev).await? {
                return Ok(Some(written));
            }
        }
        Err(PortError::fault(format!("publish {id} changed too often while updating")))
    }

    async fn hit(&self, key: &str, limit: u64, expires_at: i64) -> PortResult<Hit> {
        for _ in 0..MAX_HIT_ATTEMPTS {
            let Some(mut cur) = self.get(&self.publishes, "publish_id", key).await? else {
                let row = json!({"publish_id": key, "count": 1, "rev": 0, "expires_at": expires_at}).as_object().cloned().unwrap_or_default();
                if self.put_if_absent(&self.publishes, "publish_id", row).await? {
                    return Ok(Hit { ok: true, count: 1 });
                }
                continue;
            };
            let count = cur.get("count").and_then(Value::as_u64).ok_or_else(|| PortError::fault("a counter without a count"))?;
            let rev = cur.get("rev").and_then(Value::as_u64).ok_or_else(|| PortError::fault("a counter without a rev"))?;
            if count >= limit {
                return Ok(Hit { ok: false, count });
            }
            cur.insert("count".into(), Value::from(count + 1));
            cur.insert("rev".into(), Value::from(rev + 1));
            if self.swap(&self.publishes, cur, rev).await? {
                return Ok(Hit { ok: true, count: count + 1 });
            }
        }
        Err(PortError::fault(format!("counter {key} changed too often")))
    }
}

