//! `NamespaceStore` on DynamoDB, on the rows of `dynamo-namespace-store.ts`: table `mopm-<stage>-namespaces`, key
//! `namespace`. A row is the record with `github_id` as a string (the key of the `by_github_id` index) and the number
//! beside it as `github_id_num`, which is what `toItem` writes. Only the login's part of the port is here: no members
//! and no organization namespaces.
//!
//! Create-once is a `PutItem` conditional on the key being absent, never a read first. The loser of a create (the
//! string was held already, or another create got there first) reads the row with a strongly consistent read and
//! answers from it. Rows are never deleted or overwritten, so a refused create always finds a row to read.

use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::operation::put_item::PutItemError;
use aws_sdk_dynamodb::Client;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::namespaces::{
    user_namespace_for, NamespaceKind, NamespaceRecord, NamespaceStore, UserNamespace,
};
use serde_json::Value;

use super::fault;
use super::items::{from_item, names, object, record, s, to_item, values, Item};

pub struct DynamoNamespaceStore {
    client: Client,
    table: String,
}

fn condition_failed(e: &SdkError<PutItemError>) -> bool {
    e.as_service_error()
        .is_some_and(PutItemError::is_conditional_check_failed_exception)
}

/// The row of a record: `toItem` of `dynamo-namespace-store.ts`.
fn namespace_item(r: &NamespaceRecord) -> PortResult<Item> {
    let mut m = object(r)?;
    m.insert("github_id".into(), Value::String(r.github_id.to_string()));
    m.insert("github_id_num".into(), Value::from(r.github_id));
    to_item(m)
}

/// The record of a row: `fromItem` of `dynamo-namespace-store.ts` (the number is the id; `members_rev`, which an
/// organization row carries, is not part of the record).
fn namespace_from_item(i: Item) -> PortResult<NamespaceRecord> {
    let mut m = from_item(i)?;
    m.remove("github_id");
    m.remove("members_rev");
    if let Some(id) = m.remove("github_id_num") {
        m.insert("github_id".into(), id);
    }
    record(m)
}

impl DynamoNamespaceStore {
    /// The store on `table`; [`DynamoNamespaceStore::table_for_stage`] names a stage's.
    pub fn new(client: Client, table: String) -> Self {
        DynamoNamespaceStore { client, table }
    }

    /// `mopm-<stage>-namespaces`.
    pub fn table_for_stage(stage: &str) -> String {
        format!("mopm-{stage}-namespaces")
    }

    /// The stored row of `namespace`, read strongly consistent: it sees every create that finished before.
    async fn held(&self, namespace: &str) -> PortResult<NamespaceRecord> {
        let r = self
            .client
            .get_item()
            .table_name(&self.table)
            .set_key(Some(values([("namespace", s(namespace))])))
            .consistent_read(true)
            .send()
            .await
            .map_err(|e| fault("get namespace", e))?;
        // The create was refused, so a row existed; rows are never deleted, so it is still there.
        let item = r.item.ok_or_else(|| {
            PortError::fault(format!(
                "namespace {namespace}: the create was refused but no row is stored"
            ))
        })?;
        namespace_from_item(item)
    }
}

impl NamespaceStore for DynamoNamespaceStore {
    async fn ensure_user_namespace(
        &self,
        github_id: u64,
        login: &str,
        now: &str,
    ) -> PortResult<Option<UserNamespace>> {
        let Some(namespace) = user_namespace_for(login) else {
            return Ok(None);
        };
        let rec = NamespaceRecord {
            namespace,
            kind: NamespaceKind::User,
            github_id,
            created_at: now.to_string(),
            created_by: None,
        };
        let put = self
            .client
            .put_item()
            .table_name(&self.table)
            .set_item(Some(namespace_item(&rec)?))
            .condition_expression("attribute_not_exists(#n)")
            .set_expression_attribute_names(Some(names([("#n", "namespace")])))
            .send()
            .await;
        match put {
            Ok(_) => Ok(Some(UserNamespace::Created(rec))),
            Err(e) if condition_failed(&e) => {
                let held = self.held(&rec.namespace).await?;
                Ok((held.github_id == github_id).then_some(UserNamespace::Held(held)))
            }
            Err(e) => Err(fault("put namespace", e)),
        }
    }
}
