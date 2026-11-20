//! `WebLoginStore` on DynamoDB: table `mopm-<stage>-web_logins`, partition key `id`, TTL attribute `expires_at`
//! (`docs/design/tutorial-sign-in.md`, sections 1 and 6).
//!
//! The row is the record as it is: `expires_at` is already epoch seconds (a NUMBER, as DynamoDB's TTL reads it and
//! as the tokens and device logins tables store theirs), `consumed_at` absent until a consume sets it. No path
//! deletes a row: the sign-in function's role has no `DeleteItem` on the table, and TTL removes rows later.
//! `consume` is one conditional `UpdateItem` that answers the row as written, so of two consumes at once
//! DynamoDB lets exactly one through, and the expiry it checks is the same second `WebLoginRecord::is_expired`
//! reads.

use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::operation::update_item::UpdateItemError;
use aws_sdk_dynamodb::types::ReturnValue;
use aws_sdk_dynamodb::Client;
use jiff::Timestamp;
use mopm_ports::env::iso_millis;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::web_login::{WebLoginRecord, WebLoginStore};

use super::fault;
use super::items::{from_item, n, names, object, record, s, to_item, values};

pub struct DynamoWebLoginStore {
    client: Client,
    table: String,
}

fn condition_failed(e: &SdkError<UpdateItemError>) -> bool {
    e.as_service_error()
        .is_some_and(UpdateItemError::is_conditional_check_failed_exception)
}

impl DynamoWebLoginStore {
    /// The store on `table`; [`DynamoWebLoginStore::table_for_stage`] names a stage's.
    pub fn new(client: Client, table: String) -> Self {
        DynamoWebLoginStore { client, table }
    }

    /// `mopm-<stage>-web_logins`.
    pub fn table_for_stage(stage: &str) -> String {
        format!("mopm-{stage}-web_logins")
    }
}

impl WebLoginStore for DynamoWebLoginStore {
    async fn put(&self, row: &WebLoginRecord) -> PortResult<()> {
        self.client
            .put_item()
            .table_name(&self.table)
            .set_item(Some(to_item(object(row)?)?))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("put web login", e))
    }

    async fn consume(&self, id: &str, now: Timestamp) -> PortResult<Option<WebLoginRecord>> {
        let r = self
            .client
            .update_item()
            .table_name(&self.table)
            .set_key(Some(values([("id", s(id))])))
            .update_expression("SET #c = :at")
            // A stored row, never consumed, and not expired at `now`: `expires_at > now` is `!is_expired(now)`.
            .condition_expression(
                "attribute_exists(#id) AND attribute_not_exists(#c) AND #e > :now",
            )
            .set_expression_attribute_names(Some(names([
                ("#id", "id"),
                ("#c", "consumed_at"),
                ("#e", "expires_at"),
            ])))
            .set_expression_attribute_values(Some(values([
                (":at", s(iso_millis(now))),
                (":now", n(now.as_second())),
            ])))
            .return_values(ReturnValue::AllNew)
            .send()
            .await;
        match r {
            Ok(out) => match out.attributes {
                Some(item) => Ok(Some(record(from_item(item)?)?)),
                None => Err(PortError::fault(
                    "consume web login: the update answered no row",
                )),
            },
            // Unknown, consumed before, or expired: nothing to take, and nothing was written.
            Err(e) if condition_failed(&e) => Ok(None),
            Err(e) => Err(fault("consume web login", e)),
        }
    }
}
