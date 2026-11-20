//! `DynamoConfigTable`: the item of a key as plain JSON (strings, booleans, numbers as numbers), a missing key as
//! `None`, the request it makes, and a refused read as a fault naming the call.

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::Client;
use mopm_ports::config::ConfigTable;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo};
use serde_json::json;

use crate::dynamo::DynamoConfigTable;

const CONFIG: &str = "mopm-t-config";

fn client(endpoint: &str) -> Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new("AKIDFAKE", "fakesecret", None, None, "static"))
        .build();
    Client::from_conf(config)
}

#[tokio::test]
async fn an_item_is_read_by_its_key_as_plain_json() {
    let fake = FakeDynamo::start(FakeConfig::web_session("t"));
    fake.seed(CONFIG, json!({"key": {"S": "stage_settings"}, "site_origin": {"S": "https://beta.mopm.dev"}, "require_2fa": {"BOOL": true}, "sandbox_timeout_s": {"N": "1800"}}));
    fake.seed(CONFIG, json!({"key": {"S": "read_only"}, "on": {"BOOL": true}}));
    let table = DynamoConfigTable::new(client(&fake.endpoint()), CONFIG);
    let got = table.get_item("stage_settings").await.unwrap();
    assert_eq!(got, Some(json!({"key": "stage_settings", "site_origin": "https://beta.mopm.dev", "require_2fa": true, "sandbox_timeout_s": 1800})));
    let requests = fake.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].operation, "GetItem");
    assert_eq!(requests[0].body, json!({"TableName": CONFIG, "Key": {"key": {"S": "stage_settings"}}, "ConsistentRead": true}));
}

#[tokio::test]
async fn a_missing_key_is_none() {
    let fake = FakeDynamo::start(FakeConfig::web_session("t"));
    let table = DynamoConfigTable::new(client(&fake.endpoint()), CONFIG);
    assert_eq!(table.get_item("stage_settings").await.unwrap(), None);
}

/// The web sign-in's grants have no `config` table: the read is refused, and the fault names the call.
#[tokio::test]
async fn a_refused_read_is_a_fault_naming_the_call() {
    let fake = FakeDynamo::start(FakeConfig::web_login("t"));
    let table = DynamoConfigTable::new(client(&fake.endpoint()), CONFIG);
    let e = table.get_item("stage_settings").await.unwrap_err().to_string();
    assert!(e.starts_with("infrastructure fault: get config item: ") && e.contains("AccessDenied"), "{e}");
}
