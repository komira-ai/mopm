//! `mopm_web`'s [`ConfigTable`] on DynamoDB: the stage's `config` table, read with `GetItem` (the one call the
//! function's role has on it).

use aws_sdk_dynamodb::error::DisplayErrorContext;
use aws_sdk_dynamodb::types::AttributeValue;
use aws_sdk_dynamodb::Client;
use mopm_ports::error::{PortError, PortResult};
use mopm_web::settings::ConfigTable;
use serde_json::Value;

/// The `config` table of one stage, `mopm-<stage>-config`, whose key attribute is `key`.
pub struct DynamoConfigTable {
    client: Client,
    table: String,
}

impl DynamoConfigTable {
    /// The table named `table`, read through `client`.
    pub fn new(client: Client, table: String) -> DynamoConfigTable {
        DynamoConfigTable { client, table }
    }
}

impl ConfigTable for DynamoConfigTable {
    async fn get_item(&self, key: &str) -> PortResult<Option<Value>> {
        let out = self
            .client
            .get_item()
            .table_name(&self.table)
            .key("key", AttributeValue::S(key.to_string()))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| {
                PortError::fault(format!(
                    "dynamodb GetItem {}: {}",
                    self.table,
                    DisplayErrorContext(e)
                ))
            })?;
        out.item
            .map(|item| {
                serde_dynamo::from_item(item).map_err(|e| {
                    PortError::fault(format!("the item of {} is not JSON: {e}", self.table))
                })
            })
            .transpose()
    }
}
