//! The part of the probe the test also compiles: a DynamoDB client aimed at an endpoint with
//! static credentials, and one GetItem.

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::types::AttributeValue;
use aws_sdk_dynamodb::{Client, Config};

/// A client for `endpoint` (a plain `http://host:port` URL) that signs with fixed credentials.
pub fn client(endpoint: &str) -> Client {
    let config = Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new("AKIDFAKE", "fakesecret", None, None, "static"))
        .build();
    Client::from_conf(config)
}

/// The `title` attribute of the item whose string key `id` is given, if the item exists.
pub async fn get_title(client: &Client, table: &str, id: &str) -> Result<Option<String>, aws_sdk_dynamodb::Error> {
    let out = client
        .get_item()
        .table_name(table)
        .key("id", AttributeValue::S(id.to_string()))
        .send()
        .await?;
    Ok(out.item().and_then(|item| item.get("title")).and_then(|v| v.as_s().ok()).cloned())
}
