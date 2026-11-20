//! The stage's `config` table read by item key (docs/design/tutorial-sign-in.md, section 5): the website's functions
//! read its `stage_settings` item at cold start. `mopm_aws::dynamo::DynamoConfigTable` is the DynamoDB adapter; a
//! `BTreeMap` of items is the one in memory.

use std::collections::BTreeMap;
use std::future::Future;

use crate::error::PortResult;

/// The stage's `config` table, by item key. Each item comes back as JSON, its numbers as numbers.
pub trait ConfigTable: Send + Sync {
    fn get_item(&self, key: &str) -> impl Future<Output = PortResult<Option<serde_json::Value>>> + Send;
}

/// A table in memory, for tests.
impl ConfigTable for BTreeMap<String, serde_json::Value> {
    async fn get_item(&self, key: &str) -> PortResult<Option<serde_json::Value>> {
        Ok(self.get(key).cloned())
    }
}
