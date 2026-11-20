//! The stage's `config` table read by item key (docs/design/tutorial-sign-in.md, section 5): the website's functions
//! read its `stage_settings` item at cold start. `mopm_aws::dynamo::DynamoConfigTable` is the DynamoDB adapter; a
//! `BTreeMap` of items is the one in memory.

use std::collections::BTreeMap;
use std::future::Future;

use crate::error::PortResult;

/// The stage's `config` table, by item key. Each item comes back as JSON, its numbers as numbers.
pub trait ConfigTable: Send + Sync {
    fn get_item(
        &self,
        key: &str,
    ) -> impl Future<Output = PortResult<Option<serde_json::Value>>> + Send;
}

/// A table in memory, for tests.
impl ConfigTable for BTreeMap<String, serde_json::Value> {
    async fn get_item(&self, key: &str) -> PortResult<Option<serde_json::Value>> {
        Ok(self.get(key).cloned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;
    use std::task::{Context, Poll, Waker};

    /// The memory table never waits: its answer is ready at the first poll.
    fn first_poll(
        table: &BTreeMap<String, serde_json::Value>,
        key: &str,
    ) -> Poll<Option<serde_json::Value>> {
        std::pin::pin!(table.get_item(key))
            .poll(&mut Context::from_waker(Waker::noop()))
            .map(|r| r.unwrap())
    }

    #[test]
    fn the_memory_table_answers_the_item_of_a_key_and_none_for_another() {
        let item = serde_json::json!({"key": "stage_settings", "n": 1});
        let table: BTreeMap<String, serde_json::Value> =
            [("stage_settings".to_string(), item.clone())]
                .into_iter()
                .collect();
        assert_eq!(
            first_poll(&table, "stage_settings"),
            Poll::Ready(Some(item))
        );
        assert_eq!(first_poll(&table, "read_only"), Poll::Ready(None));
    }
}
