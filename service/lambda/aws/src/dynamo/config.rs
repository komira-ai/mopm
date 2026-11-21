//! `ConfigTable` on DynamoDB: one strongly consistent `GetItem` of the stage's `config` table (partition key `key`)
//! per read. The item comes back as plain JSON, its numbers as numbers, the way `serde_dynamo` reads every row here.
//! The website's functions read the `stage_settings` item through it once, at cold start; their role may read only
//! that key (`dynamodb:LeadingKeys` in the RustFunction construct).

use aws_sdk_dynamodb::Client;
use mopm_ports::config::ConfigTable;
use mopm_ports::error::PortResult;
use serde_json::Value;

use super::fault;
use super::items::{from_item, s, values};

pub struct DynamoConfigTable {
    client: Client,
    table: String,
}

impl DynamoConfigTable {
    /// The table `table` (`mopm-<stage>-config`).
    pub fn new(client: Client, table: impl Into<String>) -> Self {
        DynamoConfigTable {
            client,
            table: table.into(),
        }
    }
}

impl ConfigTable for DynamoConfigTable {
    async fn get_item(&self, key: &str) -> PortResult<Option<Value>> {
        let r = self
            .client
            .get_item()
            .table_name(&self.table)
            .set_key(Some(values([("key", s(key))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get config item", e))?;
        r.item.map(|i| from_item(i).map(Value::Object)).transpose()
    }
}
