//! `Store` on DynamoDB (`dynamo-store.ts`).
//!
//! Create-once is a conditional put (`attribute_not_exists`), never a read first; a version and its audit
//! row are one transaction; an update is read, state machine, then a transaction conditional on `rev`,
//! retried when it loses.

use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::operation::put_item::PutItemError;
use aws_sdk_dynamodb::operation::transact_write_items::TransactWriteItemsError;
use aws_sdk_dynamodb::types::{AttributeValue, Put, TransactWriteItem};
use aws_sdk_dynamodb::Client;
use mopm_core::error::{already_owner, name_taken, owner_not_found, version_exists, version_not_found, ErrorCode, RegistryError};
use mopm_core::state::{apply_event, Applied, VersionEvent};
use mopm_core::types::{AuditEntry, OwnerRecord, PackageRecord, VersionRecord};
use mopm_core::version::canonical_version;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::store::{audit_sort_key, by_version, Store};
use mopm_ports::types::PackageSummary;
use serde_json::Value;

use super::items::{from_item, n, names, object, record, s, to_item, values, Item};
use super::fault;

const MAX_UPDATE_ATTEMPTS: usize = 5;

/// Table names (`mopm-<stage>-<table>`, service/infra/stacks/lib/config.ts).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tables {
    pub packages: String,
    pub versions: String,
    pub owners: String,
    pub audit: String,
}

impl Tables {
    pub fn for_stage(stage: &str) -> Tables {
        Tables {
            packages: format!("mopm-{stage}-packages"),
            versions: format!("mopm-{stage}-versions"),
            owners: format!("mopm-{stage}-owners"),
            audit: format!("mopm-{stage}-audit"),
        }
    }
}

/// The name-search index of the packages table (service/infra/stacks/lib/data-stack.ts creates it: keep the
/// two in step; both sides are pinned by tests). Partition key `search_bucket`, sort key `name`, so a prefix
/// search is one Query with `begins_with` on the sort key, in name order, with no Scan. Every package row
/// carries the same bucket value: one partition, deliberately (see the TypeScript adapter's note).
pub struct SearchIndex {
    pub name: &'static str,
    pub bucket_attribute: &'static str,
    pub bucket: &'static str,
    /// Non-key attributes the index projects (the keys, `search_bucket` and `name`, always are).
    pub projected: [&'static str; 3],
}

pub const SEARCH_INDEX: SearchIndex = SearchIndex {
    name: "by_search_bucket",
    bucket_attribute: "search_bucket",
    bucket: "all",
    projected: ["description", "state", "created_at"],
};

pub struct DynamoStore {
    client: Client,
    tables: Tables,
}

fn condition_failed(e: &SdkError<PutItemError>) -> bool {
    e.as_service_error().is_some_and(PutItemError::is_conditional_check_failed_exception)
}

/// Whether the transaction was cancelled because the condition of item `index` failed.
fn cancelled_by_condition(e: &SdkError<TransactWriteItemsError>, index: usize) -> bool {
    match e.as_service_error() {
        Some(TransactWriteItemsError::TransactionCanceledException(t)) => {
            t.cancellation_reasons().get(index).and_then(|r| r.code()) == Some("ConditionalCheckFailed")
        }
        _ => false,
    }
}

fn version_item(r: &VersionRecord) -> PortResult<Item> {
    let mut m = object(r)?;
    m.remove("canonical");
    m.remove("version");
    m.insert("version".into(), Value::String(r.canonical.clone()));
    m.insert("version_spelling".into(), Value::String(r.version.clone()));
    to_item(m)
}

fn version_from_item(i: Item) -> PortResult<VersionRecord> {
    let mut m = from_item(i)?;
    let canonical = m.remove("version").ok_or_else(|| PortError::fault("a version row without `version`"))?;
    let spelling = m.remove("version_spelling").ok_or_else(|| PortError::fault("a version row without `version_spelling`"))?;
    m.insert("version".into(), spelling);
    m.insert("canonical".into(), canonical);
    record(m)
}

fn package_item(p: &PackageRecord) -> PortResult<Item> {
    let mut m = object(p)?;
    m.insert(SEARCH_INDEX.bucket_attribute.into(), Value::String(SEARCH_INDEX.bucket.into()));
    to_item(m)
}

fn package_from_item(i: Item) -> PortResult<PackageRecord> {
    let mut m = from_item(i)?;
    m.remove(SEARCH_INDEX.bucket_attribute);
    record(m)
}

fn audit_item(e: &AuditEntry) -> PortResult<Item> {
    let mut m = object(e)?;
    m.insert("ts_seq".into(), Value::String(audit_sort_key(e)));
    to_item(m)
}

fn audit_from_item(i: Item) -> PortResult<AuditEntry> {
    let mut m = from_item(i)?;
    m.remove("ts_seq");
    record(m)
}

fn owner_item(o: &OwnerRecord) -> PortResult<Item> {
    let mut m = object(o)?;
    m.insert("github_id".into(), Value::String(o.github_id.to_string()));
    m.insert("github_id_num".into(), Value::from(o.github_id));
    to_item(m)
}

fn owner_from_item(i: Item) -> PortResult<OwnerRecord> {
    let mut m = from_item(i)?;
    let id = m.remove("github_id_num").ok_or_else(|| PortError::fault("an owner row without `github_id_num`"))?;
    m.insert("github_id".into(), id);
    record(m)
}

impl DynamoStore {
    pub fn new(client: Client, tables: Tables) -> Self {
        DynamoStore { client, tables }
    }

    fn put(&self, table: &str, item: Item, cond: Option<(&str, &str)>) -> aws_sdk_dynamodb::operation::put_item::builders::PutItemFluentBuilder {
        let b = self.client.put_item().table_name(table).set_item(Some(item));
        match cond {
            Some((expr, attr)) => b.condition_expression(expr).set_expression_attribute_names(Some(names([("#n", attr)]))),
            None => b,
        }
    }

    /// Put with `attribute_not_exists(#n)` on the key attribute `name`.
    fn put_new(&self, table: &str, item: Item) -> aws_sdk_dynamodb::operation::put_item::builders::PutItemFluentBuilder {
        self.put(table, item, Some(("attribute_not_exists(#n)", "name")))
    }

    fn transact_put(table: &str, item: Item, cond: &str, names: std::collections::HashMap<String, String>, values: Option<Item>) -> PortResult<TransactWriteItem> {
        let put = Put::builder()
            .table_name(table)
            .set_item(Some(item))
            .condition_expression(cond)
            .set_expression_attribute_names(Some(names))
            .set_expression_attribute_values(values)
            .build()
            .map_err(PortError::fault)?;
        Ok(TransactWriteItem::builder().put(put).build())
    }

    async fn query_all(&self, table: &str, name: &str) -> PortResult<Vec<Item>> {
        let mut out = Vec::new();
        let mut start: Option<Item> = None;
        loop {
            let r = self
                .client
                .query()
                .table_name(table)
                .key_condition_expression("#n = :n")
                .set_expression_attribute_names(Some(names([("#n", "name")])))
                .set_expression_attribute_values(Some(values([(":n", s(name))])))
                .consistent_read(true)
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("query", e))?;
            out.extend(r.items.unwrap_or_default());
            start = r.last_evaluated_key;
            if start.is_none() {
                return Ok(out);
            }
        }
    }
}

impl Store for DynamoStore {
    async fn create_package(&self, pkg: &PackageRecord) -> PortResult<()> {
        match self.put_new(&self.tables.packages, package_item(pkg)?).send().await {
            Ok(_) => Ok(()),
            Err(e) if condition_failed(&e) => Err(name_taken(&pkg.name).into()),
            Err(e) => Err(fault("put package", e)),
        }
    }

    async fn get_package(&self, name: &str) -> PortResult<Option<PackageRecord>> {
        let r = self
            .client
            .get_item()
            .table_name(&self.tables.packages)
            .set_key(Some(values([("name", s(name))])))
            .send()
            .await
            .map_err(|e| fault("get package", e))?;
        r.item.map(package_from_item).transpose()
    }

    async fn list_package_names(&self) -> PortResult<Vec<String>> {
        let mut out = Vec::new();
        let mut start: Option<Item> = None;
        loop {
            let r = self
                .client
                .scan()
                .table_name(&self.tables.packages)
                .projection_expression("#n")
                .set_expression_attribute_names(Some(names([("#n", "name")])))
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("scan packages", e))?;
            for i in r.items.unwrap_or_default() {
                if let Some(AttributeValue::S(name)) = i.get("name") {
                    out.push(name.clone());
                }
            }
            start = r.last_evaluated_key;
            if start.is_none() {
                out.sort();
                return Ok(out);
            }
        }
    }

    async fn search_packages(&self, prefix: &str, after: Option<&str>, limit: usize) -> PortResult<Vec<PackageSummary>> {
        let mut out: Vec<PackageSummary> = Vec::new();
        if limit < 1 {
            return Ok(out);
        }
        // The index is eventually consistent (a GSI cannot be read consistently): a package claimed a moment ago
        // may not be listed yet. get_package reads the table and is consistent.
        let mut start: Option<Item> = after.map(|a| values([(SEARCH_INDEX.bucket_attribute, s(SEARCH_INDEX.bucket)), ("name", s(a))]));
        loop {
            let q = self.client.query().table_name(&self.tables.packages).index_name(SEARCH_INDEX.name);
            // DynamoDB refuses an empty string in a key condition, so "everything" has no begins_with.
            let q = if prefix.is_empty() {
                q.key_condition_expression("#b = :b")
                    .set_expression_attribute_names(Some(names([("#b", SEARCH_INDEX.bucket_attribute)])))
                    .set_expression_attribute_values(Some(values([(":b", s(SEARCH_INDEX.bucket))])))
            } else {
                q.key_condition_expression("#b = :b AND begins_with(#n, :p)")
                    .set_expression_attribute_names(Some(names([("#b", SEARCH_INDEX.bucket_attribute), ("#n", "name")])))
                    .set_expression_attribute_values(Some(values([(":b", s(SEARCH_INDEX.bucket)), (":p", s(prefix))])))
            };
            let r = q
                .limit(i32::try_from(limit - out.len()).unwrap_or(i32::MAX))
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("query search index", e))?;
            for i in r.items.unwrap_or_default() {
                let m = from_item(i)?;
                out.push(record(summary_json(m))?);
            }
            start = r.last_evaluated_key;
            if start.is_none() || out.len() >= limit {
                return Ok(out);
            }
        }
    }

    async fn create_version(&self, rec: &VersionRecord, audit: &AuditEntry) -> PortResult<()> {
        let canonical = canonical_version(&rec.version)?;
        let rec = VersionRecord { canonical, ..rec.clone() };
        let cond_names = || names([("#n", "name")]);
        let tx = self
            .client
            .transact_write_items()
            .transact_items(Self::transact_put(&self.tables.versions, version_item(&rec)?, "attribute_not_exists(#n)", cond_names(), None)?)
            .transact_items(Self::transact_put(&self.tables.audit, audit_item(audit)?, "attribute_not_exists(#n)", cond_names(), None)?);
        match tx.send().await {
            Ok(_) => Ok(()),
            Err(e) if cancelled_by_condition(&e, 0) => {
                let existing = self.get_version(&rec.name, &rec.version).await?;
                let sha = existing
                    .as_ref()
                    .map_or("unknown", |x| x.files.first().map_or(x.manifest_sha256.as_str(), |f| f.sha256.as_str()));
                Err(version_exists(&rec.name, &rec.version, sha).into())
            }
            Err(e) => Err(fault("create version", e)),
        }
    }

    async fn get_version(&self, name: &str, version: &str) -> PortResult<Option<VersionRecord>> {
        let canonical = canonical_version(version)?;
        let r = self
            .client
            .get_item()
            .table_name(&self.tables.versions)
            .set_key(Some(values([("name", s(name)), ("version", s(canonical))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get version", e))?;
        r.item.map(version_from_item).transpose()
    }

    async fn update_version(&self, name: &str, version: &str, event: &VersionEvent, audit: &AuditEntry) -> PortResult<VersionRecord> {
        for _ in 0..MAX_UPDATE_ATTEMPTS {
            let cur = self.get_version(name, version).await?.ok_or_else(|| version_not_found(name, version))?;
            let next = match apply_event(&cur, event)? {
                Applied::Unchanged => return Ok(cur),
                Applied::Changed(next) => next,
            };
            let tx = self
                .client
                .transact_write_items()
                .transact_items(Self::transact_put(
                    &self.tables.versions,
                    version_item(&next)?,
                    "#r = :r",
                    names([("#r", "rev")]),
                    Some(values([(":r", n(cur.rev))])),
                )?)
                .transact_items(Self::transact_put(&self.tables.audit, audit_item(audit)?, "attribute_not_exists(#n)", names([("#n", "name")]), None)?);
            match tx.send().await {
                Ok(_) => return Ok(next),
                Err(e) if cancelled_by_condition(&e, 0) => continue,
                Err(e) => return Err(fault("update version", e)),
            }
        }
        let mut detail = mopm_core::error::Detail::new();
        detail.insert("name".into(), name.into());
        detail.insert("version".into(), version.into());
        Err(RegistryError::new(ErrorCode::InternalError, format!("'{name}' {version} changed too often while updating."), detail).into())
    }

    async fn list_versions(&self, name: &str) -> PortResult<Vec<VersionRecord>> {
        let mut out = self.query_all(&self.tables.versions, name).await?.into_iter().map(version_from_item).collect::<PortResult<Vec<_>>>()?;
        out.sort_by(by_version);
        Ok(out)
    }

    async fn add_owner(&self, owner: &OwnerRecord) -> PortResult<()> {
        match self.put_new(&self.tables.owners, owner_item(owner)?).send().await {
            Ok(_) => Ok(()),
            Err(e) if condition_failed(&e) => Err(already_owner(&owner.handle, &owner.name).into()),
            Err(e) => Err(fault("put owner", e)),
        }
    }

    async fn remove_owner(&self, name: &str, github_id: u64) -> PortResult<()> {
        let r = self
            .client
            .delete_item()
            .table_name(&self.tables.owners)
            .set_key(Some(values([("name", s(name)), ("github_id", s(github_id.to_string()))])))
            .condition_expression("attribute_exists(#n)")
            .set_expression_attribute_names(Some(names([("#n", "name")])))
            .send()
            .await;
        match r {
            Ok(_) => Ok(()),
            Err(e) if e.as_service_error().is_some_and(|se| se.is_conditional_check_failed_exception()) => Err(owner_not_found(name).into()),
            Err(e) => Err(fault("delete owner", e)),
        }
    }

    async fn list_owners(&self, name: &str) -> PortResult<Vec<OwnerRecord>> {
        let mut out = self.query_all(&self.tables.owners, name).await?.into_iter().map(owner_from_item).collect::<PortResult<Vec<_>>>()?;
        out.sort_by_key(|o| o.github_id);
        Ok(out)
    }

    async fn owned_packages(&self, github_id: u64) -> PortResult<Vec<String>> {
        let mut found = Vec::new();
        let mut start: Option<Item> = None;
        loop {
            let r = self
                .client
                .query()
                .table_name(&self.tables.owners)
                .index_name(super::OWNERS_BY_GITHUB_ID)
                .key_condition_expression("#g = :g")
                .set_expression_attribute_names(Some(names([("#g", "github_id")])))
                .set_expression_attribute_values(Some(values([(":g", s(github_id.to_string()))])))
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| fault("query owners by account", e))?;
            for mut item in r.items.unwrap_or_default() {
                match item.remove("name") {
                    Some(AttributeValue::S(name)) => found.push(name),
                    _ => return Err(PortError::fault("an owner row without a string `name`")),
                }
            }
            start = r.last_evaluated_key;
            if start.is_none() {
                found.sort();
                return Ok(found);
            }
        }
    }

    async fn append_audit(&self, entry: &AuditEntry) -> PortResult<()> {
        self.put_new(&self.tables.audit, audit_item(entry)?).send().await.map(|_| ()).map_err(|e| fault("put audit", e))
    }

    async fn list_audit(&self, name: &str) -> PortResult<Vec<AuditEntry>> {
        // The sort key is `<ts>#<id>`, so the query already returns them oldest first.
        self.query_all(&self.tables.audit, name).await?.into_iter().map(audit_from_item).collect()
    }
}

/// A search index row as a summary: its keys and projected attributes, without the bucket.
fn summary_json(mut m: serde_json::Map<String, Value>) -> serde_json::Map<String, Value> {
    m.remove(SEARCH_INDEX.bucket_attribute);
    m
}

