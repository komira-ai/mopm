//! `AuthStore` on DynamoDB (`auth/dynamo-auth-store.ts`). Deviations a reader needs to know:
//!
//! * No row is ever deleted by this adapter's normal paths: the tables deny `DeleteItem` to every role but
//!   the takedown/cleanup roles, and this Lambda's role is not one of them. A finished device login is
//!   marked consumed (its GitHub device code is removed from the row) and TTL removes the row later.
//! * `list_tokens` and `get_user_token` read the by-account index, which is eventually consistent: a token
//!   created a moment ago may be missing from a list for a short time.
//! * `remove_trusted_publisher` is a real delete and so needs a role the table policy exempts; no route in
//!   the Lambda registers or removes publishers yet.
//!
//! DynamoDB's time to live reads a NUMBER of epoch seconds from the table's TTL attribute, here
//! `expires_at`. The records carry ISO strings, so the item keeps both: `expires_at` (seconds, for
//! DynamoDB) and `expires_at_iso` (what the record said, millisecond exact). The code decides expiry on
//! every read from the record, so a row that is expired but not yet removed behaves as expired.

use std::sync::Arc;

use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::operation::update_item::UpdateItemError;
use aws_sdk_dynamodb::Client;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{iso_millis, Clock};
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::types::{DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord};
use serde_json::Value;

use super::items::{epoch_seconds, from_item, n, names, object, record, s, to_item, values, Item};
use super::{fault, TOKENS_BY_GITHUB_ID};

/// Table names (`mopm-<stage>-<table>`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthTables {
    pub users: String,
    pub tokens: String,
    pub device_logins: String,
    pub trusted_publishers: String,
}

impl AuthTables {
    pub fn for_stage(stage: &str) -> AuthTables {
        AuthTables {
            users: format!("mopm-{stage}-users"),
            tokens: format!("mopm-{stage}-tokens"),
            device_logins: format!("mopm-{stage}-device_logins"),
            trusted_publishers: format!("mopm-{stage}-trusted_publishers"),
        }
    }
}

pub struct DynamoAuthStore {
    client: Client,
    tables: AuthTables,
    clock: Arc<dyn Clock>,
}

fn update_condition_failed(e: &SdkError<UpdateItemError>) -> bool {
    e.as_service_error().is_some_and(UpdateItemError::is_conditional_check_failed_exception)
}

fn token_item(r: &TokenRecord) -> PortResult<Item> {
    let mut m = object(r)?;
    let hash = m.remove("hash").ok_or_else(|| PortError::fault("a token without a hash"))?;
    m.insert("token_hash".into(), hash);
    m.remove("expires_at");
    m.insert("expires_at".into(), Value::from(epoch_seconds(&r.expires_at)?));
    m.insert("expires_at_iso".into(), Value::String(r.expires_at.clone()));
    if let Some(id) = r.github_id {
        // Index keys are strings (like the owners table); the number is kept for reading back.
        m.insert("github_id".into(), Value::String(id.to_string()));
        m.insert("github_id_num".into(), Value::from(id));
    }
    to_item(m)
}

fn token_from_item(i: Item) -> PortResult<TokenRecord> {
    let mut m = from_item(i)?;
    let hash = m.remove("token_hash").ok_or_else(|| PortError::fault("a token row without token_hash"))?;
    m.insert("hash".into(), hash);
    m.remove("expires_at");
    let iso = m.remove("expires_at_iso").ok_or_else(|| PortError::fault("a token row without expires_at_iso"))?;
    m.insert("expires_at".into(), iso);
    m.remove("github_id");
    if let Some(id) = m.remove("github_id_num") {
        m.insert("github_id".into(), id);
    }
    record(m)
}

impl DynamoAuthStore {
    pub fn new(client: Client, tables: AuthTables, clock: Arc<dyn Clock>) -> Self {
        DynamoAuthStore { client, tables, clock }
    }

    async fn update(
        &self,
        table: &str,
        key: Item,
        update: &str,
        cond: &str,
        names: std::collections::HashMap<String, String>,
        values: Item,
        what: &str,
    ) -> PortResult<()> {
        let r = self
            .client
            .update_item()
            .table_name(table)
            .set_key(Some(key))
            .update_expression(update)
            .condition_expression(cond)
            .set_expression_attribute_names(Some(names))
            .set_expression_attribute_values(Some(values))
            .send()
            .await;
        match r {
            Ok(_) => Ok(()),
            // A condition that fails means there is nothing to change: no such row, already revoked, consumed.
            Err(e) if update_condition_failed(&e) => Ok(()),
            Err(e) => Err(fault(what, e)),
        }
    }
}

impl AuthStore for DynamoAuthStore {
    async fn upsert_user(&self, github_id: u64, handle: &str, now: &str, two_factor: Option<bool>) -> PortResult<UserRecord> {
        let old = self.get_user(github_id).await?;
        let rec = UserRecord {
            github_id,
            handle: handle.to_string(),
            created_at: old.map_or_else(|| now.to_string(), |u| u.created_at),
            last_login_at: now.to_string(),
            two_factor,
        };
        let mut m = object(&rec)?;
        m.insert("github_id".into(), Value::String(github_id.to_string()));
        m.insert("github_id_num".into(), Value::from(github_id));
        self.client
            .put_item()
            .table_name(&self.tables.users)
            .set_item(Some(to_item(m)?))
            .send()
            .await
            .map_err(|e| fault("put user", e))?;
        Ok(rec)
    }

    async fn get_user(&self, github_id: u64) -> PortResult<Option<UserRecord>> {
        let r = self
            .client
            .get_item()
            .table_name(&self.tables.users)
            .set_key(Some(values([("github_id", s(github_id.to_string()))])))
            .send()
            .await
            .map_err(|e| fault("get user", e))?;
        let Some(item) = r.item else { return Ok(None) };
        let mut m = from_item(item)?;
        m.remove("github_id");
        if let Some(id) = m.remove("github_id_num") {
            m.insert("github_id".into(), id);
        }
        Ok(Some(record(m)?))
    }

    async fn put_token(&self, rec: &TokenRecord) -> PortResult<()> {
        self.client
            .put_item()
            .table_name(&self.tables.tokens)
            .set_item(Some(token_item(rec)?))
            // A token hash is 256 bits of a random secret: a collision is a bug, never overwrite.
            .condition_expression("attribute_not_exists(#h)")
            .set_expression_attribute_names(Some(names([("#h", "token_hash")])))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("put token", e))
    }

    async fn get_token_by_hash(&self, hash: &str) -> PortResult<Option<TokenRecord>> {
        let r = self
            .client
            .get_item()
            .table_name(&self.tables.tokens)
            .set_key(Some(values([("token_hash", s(hash))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get token", e))?;
        r.item.map(token_from_item).transpose()
    }

    async fn get_user_token(&self, github_id: u64, id: &str) -> PortResult<Option<TokenRecord>> {
        let r = self
            .client
            .query()
            .table_name(&self.tables.tokens)
            .index_name(TOKENS_BY_GITHUB_ID)
            .key_condition_expression("#g = :g AND #i = :i")
            .set_expression_attribute_names(Some(names([("#g", "github_id"), ("#i", "id")])))
            .set_expression_attribute_values(Some(values([(":g", s(github_id.to_string())), (":i", s(id))])))
            .send()
            .await
            .map_err(|e| fault("query tokens", e))?;
        r.items.unwrap_or_default().into_iter().next().map(token_from_item).transpose()
    }

    async fn list_tokens(&self, github_id: u64) -> PortResult<Vec<TokenRecord>> {
        let mut out = Vec::new();
        let mut start: Option<Item> = None;
        loop {
            let r = self
                .client
                .query()
                .table_name(&self.tables.tokens)
                .index_name(TOKENS_BY_GITHUB_ID)
                .key_condition_expression("#g = :g")
                .set_expression_attribute_names(Some(names([("#g", "github_id")])))
                .set_expression_attribute_values(Some(values([(":g", s(github_id.to_string()))])))
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("query tokens", e))?;
            for i in r.items.unwrap_or_default() {
                out.push(token_from_item(i)?);
            }
            start = r.last_evaluated_key;
            if start.is_none() {
                return Ok(out);
            }
        }
    }

    async fn revoke_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.update(
            &self.tables.tokens,
            values([("token_hash", s(hash))]),
            "SET #r = :at",
            // The first revocation time stays; a missing row is nothing to revoke.
            "attribute_exists(#h) AND attribute_not_exists(#r)",
            names([("#r", "revoked_at"), ("#h", "token_hash")]),
            values([(":at", s(at))]),
            "revoke token",
        )
        .await
    }

    async fn touch_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.update(
            &self.tables.tokens,
            values([("token_hash", s(hash))]),
            "SET #u = :at",
            "attribute_exists(#h)",
            names([("#u", "last_used_at"), ("#h", "token_hash")]),
            values([(":at", s(at))]),
            "touch token",
        )
        .await
    }

    async fn put_device_login(&self, rec: &DeviceLoginRecord) -> PortResult<()> {
        let mut m = object(rec)?;
        m.remove("expires_at");
        m.insert("expires_at".into(), Value::from(epoch_seconds(&rec.expires_at)?));
        m.insert("expires_at_iso".into(), Value::String(rec.expires_at.clone()));
        self.client
            .put_item()
            .table_name(&self.tables.device_logins)
            .set_item(Some(to_item(m)?))
            .condition_expression("attribute_not_exists(#id)")
            .set_expression_attribute_names(Some(names([("#id", "id")])))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("put device login", e))
    }

    async fn get_device_login(&self, id: &str) -> PortResult<Option<DeviceLoginRecord>> {
        let r = self
            .client
            .get_item()
            .table_name(&self.tables.device_logins)
            .set_key(Some(values([("id", s(id))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get device login", e))?;
        let Some(item) = r.item else { return Ok(None) };
        let mut m = from_item(item)?;
        if m.contains_key("consumed_at") {
            return Ok(None);
        }
        m.remove("expires_at");
        if let Some(iso) = m.remove("expires_at_iso") {
            m.insert("expires_at".into(), iso);
        }
        Ok(Some(record(m)?))
    }

    async fn set_device_polled(&self, id: &str, at: &str, interval: u64) -> PortResult<()> {
        self.update(
            &self.tables.device_logins,
            values([("id", s(id))]),
            "SET #p = :at, #n = :n",
            "attribute_exists(#id) AND attribute_not_exists(#c)",
            names([("#p", "last_polled_at"), ("#n", "interval"), ("#id", "id"), ("#c", "consumed_at")]),
            values([(":at", s(at)), (":n", n(interval))]),
            "set device polled",
        )
        .await
    }

    async fn delete_device_login(&self, id: &str) -> PortResult<()> {
        self.update(
            &self.tables.device_logins,
            values([("id", s(id))]),
            // Consumed: no longer pollable, and GitHub's device code leaves the row now. TTL removes the row.
            "SET #c = :t REMOVE #g",
            "attribute_exists(#id)",
            names([("#c", "consumed_at"), ("#g", "github_device_code"), ("#id", "id")]),
            values([(":t", s(iso_millis(self.clock.now())))]),
            "consume device login",
        )
        .await
    }

    async fn add_trusted_publisher(&self, tp: &TrustedPublisher) -> PortResult<()> {
        let mut m = object(tp)?;
        m.insert("publisher".into(), Value::String(tp.id.clone()));
        self.client
            .put_item()
            .table_name(&self.tables.trusted_publishers)
            .set_item(Some(to_item(m)?))
            .condition_expression("attribute_not_exists(#p)")
            .set_expression_attribute_names(Some(names([("#p", "publisher")])))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("put trusted publisher", e))
    }

    async fn list_trusted_publishers(&self, name: &str) -> PortResult<Vec<TrustedPublisher>> {
        let mut out = Vec::new();
        let mut start: Option<Item> = None;
        loop {
            let r = self
                .client
                .query()
                .table_name(&self.tables.trusted_publishers)
                .key_condition_expression("#n = :n")
                .set_expression_attribute_names(Some(names([("#n", "name")])))
                .set_expression_attribute_values(Some(values([(":n", s(name))])))
                .consistent_read(true)
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("query trusted publishers", e))?;
            for i in r.items.unwrap_or_default() {
                let mut m = from_item(i)?;
                m.remove("publisher");
                out.push(record(m)?);
            }
            start = r.last_evaluated_key;
            if start.is_none() {
                return Ok(out);
            }
        }
    }

    async fn remove_trusted_publisher(&self, name: &str, id: &str) -> PortResult<()> {
        self.client
            .delete_item()
            .table_name(&self.tables.trusted_publishers)
            .set_key(Some(values([("name", s(name)), ("publisher", s(id))])))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("delete trusted publisher", e))
    }
}
