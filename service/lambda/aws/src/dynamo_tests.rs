//! The DynamoDB adapters against the fake DynamoDB on loopback.

use std::sync::Arc;

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::Client;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo};

use crate::dynamo::{AuthTables, DynamoAuthStore, DynamoPublishStore, DynamoStore, PublishTables, Tables};

fn client(endpoint: &str) -> Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new("AKIDFAKE", "fakesecret", None, None, "static"))
        .build();
    Client::from_conf(config)
}

/// A fake DynamoDB that outlives the call (it stops with the test's runtime).
fn fake(cfg: FakeConfig) -> String {
    let f = FakeDynamo::start(cfg);
    let endpoint = f.endpoint();
    std::mem::forget(f);
    endpoint
}

fn store() -> DynamoStore {
    DynamoStore::new(client(&fake(FakeConfig::registry("t"))), Tables::for_stage("t"))
}

fn auth_store() -> DynamoAuthStore {
    DynamoAuthStore::new(client(&fake(FakeConfig::registry("t"))), AuthTables::for_stage("t"), Arc::new(mopm_testing::env::FixedClock::at_millis(1_760_356_800_000)))
}

fn publish_store() -> DynamoPublishStore {
    DynamoPublishStore::new(client(&fake(FakeConfig::registry("t"))), &PublishTables::for_stage("t"))
}

mod store_contract {
    use super::*;
    mopm_testing::store_contract_tests!(store);
}

mod auth_contract {
    use super::*;
    mopm_testing::auth_contract_tests!(auth_store);
}

mod publish_contract {
    use super::*;
    mopm_testing::publish_contract_tests!(publish_store);
}
