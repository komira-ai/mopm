//! What is true of the DynamoDB adapters and not of the port: the rows they write, the requests they make,
//! and the permissions they need. The expected rows and requests are what the TypeScript adapters write
//! (`service/api/test/store.test.ts`, `auth-store.test.ts`, `publish/dynamo.test.ts`), as DynamoDB JSON.

use std::sync::Arc;

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::Client;
use mopm_core::state::VersionEvent;
use mopm_core::types::{OwnerRecord, PackageRecord, PackageState, VersionRecord, VersionState};
use mopm_ports::auth::AuthStore;
use mopm_ports::publish::PublishStore;
use mopm_ports::store::Store;
use mopm_ports::types::{DeviceLoginRecord, TokenKind, TokenRecord, TokenScope, TrustedPublisher};
use mopm_testing::env::FixedClock;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, Grants};
use mopm_testing::records::{audit, group_row, rec, with_state};
use serde_json::{json, Value};

use crate::dynamo::{AuthTables, DynamoAuthStore, DynamoPublishStore, DynamoStore, PublishTables, Tables, SEARCH_INDEX};

const LAMBDA_GRANTS: &str = include_str!("../../../api/test/fixtures/lambda-auth-grants.json");

fn client(endpoint: &str) -> Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new("AKIDFAKE", "fakesecret", None, None, "static"))
        .build();
    Client::from_conf(config)
}

fn rig() -> (DynamoStore, FakeDynamo) {
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    (DynamoStore::new(client(&fake.endpoint()), Tables::for_stage("t")), fake)
}

fn clock() -> Arc<FixedClock> {
    Arc::new(FixedClock::at_millis(1_760_356_800_000))
}

fn auth_rig(cfg: FakeConfig) -> (DynamoAuthStore, FakeDynamo) {
    let fake = FakeDynamo::start(cfg);
    (DynamoAuthStore::new(client(&fake.endpoint()), AuthTables::for_stage("t"), clock()), fake)
}

fn pkg(name: &str) -> PackageRecord {
    PackageRecord { name: name.into(), state: PackageState::Active, created_at: "2026-10-13T12:00:00Z".into(), repository: None, license: None, description: None, homepage: None, keywords: None }
}

fn hash(n: u32) -> String {
    format!("{n:064}")
}

fn tok(id: &str, hash: &str) -> TokenRecord {
    TokenRecord {
        id: id.into(),
        kind: TokenKind::Api,
        github_id: Some(1),
        name: "t".into(),
        hash: hash.into(),
        prefix: "mopm_abcdef".into(),
        scopes: vec![TokenScope::Publish],
        packages: vec!["alpha".into()],
        all_current: false,
        version: None,
        fresh_until: None,
        created_at: "2026-10-14T12:00:00.000Z".into(),
        expires_at: "2026-11-13T12:00:00.123Z".into(),
        revoked_at: None,
        last_used_at: None,
        issued_to: None,
    }
}

fn login() -> DeviceLoginRecord {
    DeviceLoginRecord {
        id: hash(9),
        github_device_code: "gh-device-code-0123456789".into(),
        client: "mopm 0.1.0".into(),
        created_at: "2026-10-14T12:00:00.000Z".into(),
        expires_at: "2026-10-14T12:10:00.000Z".into(),
        interval: 5,
        last_polled_at: None,
    }
}

/// The body of the requests of one operation, in order.
fn bodies(fake: &FakeDynamo, op: &str) -> Vec<Value> {
    fake.requests().into_iter().filter(|r| r.operation == op).map(|r| r.body).collect()
}

// ---- rows: the wire form of the TypeScript adapters ----------------------------------------------

#[tokio::test]
async fn a_version_is_one_row_keyed_by_the_version_with_the_spelling_beside_it() {
    let (s, fake) = rig();
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    let rows = fake.dump("mopm-t-versions");
    assert_eq!(rows.len(), 1);
    let url = "https://conda.example.invalid/linux-64/mojo-p-1.0.0-mojo1.0.0_0.conda";
    assert_eq!(
        rows[0],
        json!({
            "name": {"S": "p"},
            "version": {"S": "1.0.0"},
            "version_spelling": {"S": "1.0.0"},
            "build": {"S": "mojo1.0.0_0"},
            "state": {"S": "published"},
            "published_at": {"S": "2026-10-13T12:00:00Z"},
            "requires_mojo": {"S": "==1.0.0"},
            "deps": {"L": []},
            "native": {"L": []},
            "files": {"L": [{"M": {
                "subdir": {"S": "linux-64"},
                "filename": {"S": "mojo-p-1.0.0-mojo1.0.0_0.conda"},
                "sha256": {"S": "a".repeat(64)},
                "size": {"N": "1000"},
                "url": {"S": url}
            }}]},
            "manifest_sha256": {"S": "f".repeat(64)},
            "rev": {"N": "0"}
        })
    );
    assert!(rows[0].get("canonical").is_none());
}

#[tokio::test]
async fn the_version_row_reads_back_to_the_record() {
    let (s, _fake) = rig();
    let r = rec("p", "1.2.3");
    s.create_version(&r, &audit("p", "publish", None)).await.unwrap();
    assert_eq!(s.get_version("p", "1.2.3").await.unwrap(), Some(r));
}

#[tokio::test]
async fn an_audit_row_has_the_time_then_id_sort_key() {
    let (s, fake) = rig();
    let a = audit("p", "claim", None);
    s.append_audit(&a).await.unwrap();
    let rows = fake.dump("mopm-t-audit");
    assert_eq!(rows[0]["ts_seq"], json!({"S": format!("{}#{}", a.ts, a.id)}));
    assert_eq!(rows[0]["action"], json!({"S": "claim"}));
    assert_eq!(s.list_audit("p").await.unwrap(), vec![a]);
}

#[tokio::test]
async fn a_package_row_carries_the_index_attribute_and_reads_do_not_show_it() {
    let (s, fake) = rig();
    s.create_package(&pkg("pkg")).await.unwrap();
    assert_eq!(
        fake.dump("mopm-t-packages")[0],
        json!({"name": {"S": "pkg"}, "state": {"S": "active"}, "created_at": {"S": "2026-10-13T12:00:00Z"}, "search_bucket": {"S": "all"}})
    );
    assert_eq!(s.get_package("pkg").await.unwrap(), Some(pkg("pkg")));
}

#[tokio::test]
async fn the_index_is_sparse_a_row_without_the_attribute_is_gettable_but_not_searchable() {
    let (s, fake) = rig();
    fake.seed("mopm-t-packages", json!({"name": {"S": "legacy"}, "state": {"S": "claimed"}, "created_at": {"S": "2026-10-13T12:00:00Z"}}));
    assert_eq!(s.get_package("legacy").await.unwrap().map(|p| p.name), Some("legacy".to_string()));
    assert!(s.search_packages("", None, 10).await.unwrap().is_empty());
}

#[tokio::test]
async fn an_owner_has_a_string_key_and_the_number_beside_it() {
    let (s, fake) = rig();
    s.add_owner(&OwnerRecord { name: "p".into(), github_id: 4, handle: "u4".into(), added_at: "2026-10-13T12:00:00Z".into() }).await.unwrap();
    assert_eq!(
        fake.dump("mopm-t-owners")[0],
        json!({"name": {"S": "p"}, "github_id": {"S": "4"}, "github_id_num": {"N": "4"}, "handle": {"S": "u4"}, "added_at": {"S": "2026-10-13T12:00:00Z"}})
    );
}

#[test]
fn the_search_index_constants_and_table_names_are_the_stacks() {
    // service/infra/stacks/lib/data-stack.ts defines the index; store.test.ts pins the adapter's constants.
    assert_eq!((SEARCH_INDEX.name, SEARCH_INDEX.bucket_attribute, SEARCH_INDEX.bucket), ("by_search_bucket", "search_bucket", "all"));
    assert_eq!(SEARCH_INDEX.projected, ["description", "state", "created_at"]);
    assert_eq!(
        Tables::for_stage("beta"),
        Tables { packages: "mopm-beta-packages".into(), versions: "mopm-beta-versions".into(), owners: "mopm-beta-owners".into(), audit: "mopm-beta-audit".into() }
    );
}

// ---- requests ---------------------------------------------------------------------------------------

#[tokio::test]
async fn creating_a_version_never_reads_first_the_condition_is_the_only_guard() {
    let (s, fake) = rig();
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    assert_eq!(fake.operations(), ["TransactWriteItems"]);
    assert!(fake.requests().iter().all(|r| r.signed), "every request is SigV4-signed");
}

#[tokio::test]
async fn every_transaction_carries_a_client_request_token_and_the_conditions() {
    let (s, fake) = rig();
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    s.update_version("p", "1.0.0", &VersionEvent::Yank { reason: "bad".into() }, &audit("p", "yank", None)).await.unwrap();
    let txs = bodies(&fake, "TransactWriteItems");
    assert_eq!(txs.len(), 2);
    for t in &txs {
        let token = t["ClientRequestToken"].as_str().expect("a token");
        assert!(!token.is_empty());
        assert_eq!(t["TransactItems"].as_array().unwrap().len(), 2);
    }
    assert_ne!(txs[0]["ClientRequestToken"], txs[1]["ClientRequestToken"], "a token per transaction");
    let create = &txs[0]["TransactItems"];
    assert_eq!(create[0]["Put"]["TableName"], "mopm-t-versions");
    assert_eq!(create[0]["Put"]["ConditionExpression"], "attribute_not_exists(#n)");
    assert_eq!(create[0]["Put"]["ExpressionAttributeNames"], json!({"#n": "name"}));
    assert_eq!(create[1]["Put"]["TableName"], "mopm-t-audit");
    let update = &txs[1]["TransactItems"];
    assert_eq!(update[0]["Put"]["ConditionExpression"], "#r = :r");
    assert_eq!(update[0]["Put"]["ExpressionAttributeValues"], json!({":r": {"N": "0"}}));
}

#[tokio::test]
async fn an_idempotent_update_reads_and_writes_nothing() {
    let (s, fake) = rig();
    s.create_version(&rec("p", "1.0.0"), &audit("p", "publish", None)).await.unwrap();
    s.update_version("p", "1.0.0", &VersionEvent::Publish(None), &audit("p", "publish-again", None)).await.unwrap();
    assert_eq!(fake.operations(), ["TransactWriteItems", "GetItem"]);
}

fn search_base(prefix: Option<&str>) -> Value {
    match prefix {
        Some(p) => json!({
            "TableName": "mopm-t-packages",
            "IndexName": "by_search_bucket",
            "KeyConditionExpression": "#b = :b AND begins_with(#n, :p)",
            "ExpressionAttributeNames": {"#b": "search_bucket", "#n": "name"},
            "ExpressionAttributeValues": {":b": {"S": "all"}, ":p": {"S": p}}
        }),
        None => json!({
            "TableName": "mopm-t-packages",
            "IndexName": "by_search_bucket",
            "KeyConditionExpression": "#b = :b",
            "ExpressionAttributeNames": {"#b": "search_bucket"},
            "ExpressionAttributeValues": {":b": {"S": "all"}}
        }),
    }
}

fn with(mut base: Value, extra: Value) -> Value {
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

async fn seeded() -> (DynamoStore, FakeDynamo) {
    let (s, fake) = rig();
    for n in ["http_a", "http_b", "http_c", "httpx", "zlib"] {
        let mut p = pkg(n);
        p.description = Some(n.into());
        p.license = Some("MIT".into());
        s.create_package(&p).await.unwrap();
    }
    fake.clear_requests();
    (s, fake)
}

#[tokio::test]
async fn a_prefix_search_is_one_query_on_the_index_resumed_with_the_starting_key() {
    let (s, fake) = seeded().await; // the fake returns at most two items a page
    let got = s.search_packages("http_", Some("http_a"), 3).await.unwrap();
    assert_eq!(got.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["http_b", "http_c"]);
    // Starts after 'http_a'. Only 'http_b' and 'http_c' match after it, so the first page ends the search.
    let q = bodies(&fake, "Query");
    assert_eq!(q.len(), 1);
    let start = json!({"search_bucket": {"S": "all"}, "name": {"S": "http_a"}});
    assert_eq!(q[0], with(search_base(Some("http_")), json!({"Limit": 3, "ExclusiveStartKey": start})));
}

#[tokio::test]
async fn a_search_that_spans_index_pages_continues_from_the_last_evaluated_key_with_a_shrinking_limit() {
    let (s, fake) = seeded().await;
    let got = s.search_packages("http", None, 3).await.unwrap();
    assert_eq!(got.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["http_a", "http_b", "http_c"]);
    let q = bodies(&fake, "Query");
    assert_eq!(q.len(), 2, "pages of two: two queries for three names");
    assert_eq!(q[0], with(search_base(Some("http")), json!({"Limit": 3})));
    let next = &q[1];
    assert_eq!(next["Limit"], 1);
    assert_eq!(next["ExclusiveStartKey"]["name"], json!({"S": "http_b"}));
    assert_eq!(next["ExclusiveStartKey"]["search_bucket"], json!({"S": "all"}));
}

#[tokio::test]
async fn no_prefix_means_the_key_condition_is_the_bucket_alone() {
    let (s, fake) = seeded().await;
    let got = s.search_packages("", None, 10).await.unwrap();
    assert_eq!(got.len(), 5);
    let q = bodies(&fake, "Query");
    assert_eq!(q[0], with(search_base(None), json!({"Limit": 10})));
}

#[tokio::test]
async fn search_never_scans_and_a_zero_limit_asks_nothing() {
    let (s, fake) = seeded().await;
    s.search_packages("http", None, 2).await.unwrap();
    assert_eq!(fake.operations(), ["Query"]);
    assert!(s.search_packages("http", None, 0).await.unwrap().is_empty());
    assert_eq!(fake.operations().len(), 1);
}

#[tokio::test]
async fn the_search_index_returns_only_what_it_projects() {
    let (s, _fake) = seeded().await;
    let one = s.search_packages("zlib", None, 1).await.unwrap().remove(0);
    assert_eq!(serde_json::to_value(&one).unwrap(), json!({"name": "zlib", "state": "active", "created_at": "2026-10-13T12:00:00Z", "description": "zlib"}));
}

// ---- the fake is strict where DynamoDB is -------------------------------------------------------------

#[tokio::test]
async fn the_fake_refuses_what_a_real_table_refuses() {
    use aws_sdk_dynamodb::error::{DisplayErrorContext, SdkError};
    use aws_sdk_dynamodb::operation::query::{QueryError, QueryOutput};
    use aws_sdk_dynamodb::types::AttributeValue::S;
    let (_s, fake) = rig();
    let c = client(&fake.endpoint());
    let refused = |r: Result<QueryOutput, SdkError<QueryError>>, needle: &str| {
        let e = r.map(|_| ()).unwrap_err();
        let text = DisplayErrorContext(&e).to_string();
        assert!(text.contains(needle), "{needle} not in {text}");
    };
    let base = || c.query().table_name("mopm-t-packages").index_name("by_search_bucket").limit(5);
    // an empty begins_with operand
    refused(
        base()
            .key_condition_expression("#b = :b AND begins_with(#n, :p)")
            .expression_attribute_names("#b", "search_bucket")
            .expression_attribute_names("#n", "name")
            .expression_attribute_values(":b", S("all".into()))
            .expression_attribute_values(":p", S(String::new()))
            .send()
            .await,
        "begins_with",
    );
    // a reserved word used raw
    refused(base().key_condition_expression("search_bucket = :b").expression_attribute_values(":b", S("all".into())).send().await, "placeholder");
    // a name nothing uses
    refused(
        base()
            .key_condition_expression("#b = :b")
            .expression_attribute_names("#b", "search_bucket")
            .expression_attribute_names("#x", "unused")
            .expression_attribute_values(":b", S("all".into()))
            .send()
            .await,
        "unused",
    );
    // a starting key outside the query
    refused(
        base()
            .key_condition_expression("#b = :b")
            .expression_attribute_names("#b", "search_bucket")
            .expression_attribute_values(":b", S("all".into()))
            .exclusive_start_key("search_bucket", S("other".into()))
            .exclusive_start_key("name", S("a".into()))
            .send()
            .await,
        "outside query",
    );
}

// ---- auth: rows, secrets, and the Lambda's grants ----------------------------------------------------

#[tokio::test]
async fn a_token_row_has_the_hash_and_the_prefix_and_no_secret_and_numeric_ttl() {
    let (s, fake) = auth_rig(FakeConfig::registry("t"));
    s.put_token(&tok("tok_a", &hash(1))).await.unwrap();
    let row = &fake.dump("mopm-t-tokens")[0];
    assert_eq!(row["token_hash"], json!({"S": hash(1)}));
    assert!(row.get("hash").is_none());
    let keys: Vec<&String> = row.as_object().unwrap().keys().collect();
    assert!(keys.iter().all(|k| !k.contains("secret") && k.as_str() != "token"), "{keys:?}");
    assert_eq!(row["expires_at"], json!({"N": "1794571200"}), "epoch seconds of 2026-11-13T12:00:00.123Z, floored");
    assert_eq!(row["expires_at_iso"], json!({"S": "2026-11-13T12:00:00.123Z"}));
    assert_eq!(row["github_id"], json!({"S": "1"}), "index keys are strings");
    assert_eq!(row["github_id_num"], json!({"N": "1"}));
    assert_eq!(row["scopes"], json!({"L": [{"S": "publish"}]}));
    assert_eq!(row["all_current"], json!({"BOOL": false}));
}

#[tokio::test]
async fn a_token_hash_is_never_overwritten() {
    let (s, _fake) = auth_rig(FakeConfig::registry("t"));
    s.put_token(&tok("tok_a", &hash(1))).await.unwrap();
    assert!(s.put_token(&tok("tok_b", &hash(1))).await.is_err());
}

#[tokio::test]
async fn a_user_row_has_the_string_key_and_the_number() {
    let (s, fake) = auth_rig(FakeConfig::registry("t"));
    s.upsert_user(7, "octocat", "2026-10-01T00:00:00.000Z", Some(true)).await.unwrap();
    assert_eq!(
        fake.dump("mopm-t-users")[0],
        json!({"github_id": {"S": "7"}, "github_id_num": {"N": "7"}, "handle": {"S": "octocat"}, "created_at": {"S": "2026-10-01T00:00:00.000Z"}, "last_login_at": {"S": "2026-10-01T00:00:00.000Z"}, "two_factor": {"BOOL": true}})
    );
}

fn lambda_grants() -> FakeConfig {
    FakeConfig::registry("t").with_grants("mopm-t-", Grants::parse(LAMBDA_GRANTS).unwrap())
}

#[tokio::test]
async fn the_adapter_needs_no_permission_the_lambda_role_lacks() {
    let (s, fake) = auth_rig(lambda_grants());
    s.upsert_user(7, "octocat", "2026-10-01T00:00:00.000Z", None).await.unwrap();
    s.put_token(&tok("tok_a", &hash(1))).await.unwrap();
    s.revoke_token(&hash(1), "2026-10-14T13:00:00.000Z").await.unwrap();
    s.touch_token(&hash(1), "2026-10-14T13:00:00.000Z").await.unwrap();
    assert_eq!(s.list_tokens(1).await.unwrap().len(), 1);
    assert!(s.get_user_token(1, "tok_a").await.unwrap().is_some());
    s.put_device_login(&login()).await.unwrap();
    s.set_device_polled(&login().id, "2026-10-14T12:00:07.000Z", 10).await.unwrap();
    s.delete_device_login(&login().id).await.unwrap();
    assert!(!fake.operations().iter().any(|o| o == "DeleteItem"), "the role is never granted DeleteItem");
}

#[tokio::test]
async fn trusted_publishers_can_be_read_and_not_written_with_the_lambda_grants() {
    let (s, fake) = auth_rig(lambda_grants());
    fake.seed(
        "mopm-t-trusted_publishers",
        json!({"name": {"S": "alpha"}, "publisher": {"S": "tp1"}, "id": {"S": "tp1"}, "repository_id": {"S": "111"}, "repository_owner_id": {"S": "222"}, "workflow": {"S": ".github/workflows/release.yml"}, "added_by": {"N": "1"}, "added_at": {"S": "2026-10-14T12:00:00.000Z"}}),
    );
    assert_eq!(s.list_trusted_publishers("alpha").await.unwrap().iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["tp1"]);
    let tp = TrustedPublisher {
        id: "tp9".into(),
        name: "alpha".into(),
        repository_id: "1".into(),
        repository_owner_id: "2".into(),
        workflow: "w".into(),
        environment: None,
        added_by: 1,
        added_at: "t".into(),
    };
    assert!(s.add_trusted_publisher(&tp).await.is_err());
    assert!(s.remove_trusted_publisher("alpha", "tp1").await.is_err());
}

#[tokio::test]
async fn no_row_is_ever_deleted_a_consumed_login_keeps_the_row_drops_githubs_code_and_keeps_the_ttl() {
    let (s, fake) = auth_rig(lambda_grants());
    s.put_device_login(&login()).await.unwrap();
    s.delete_device_login(&login().id).await.unwrap();
    let rows = fake.dump("mopm-t-device_logins");
    assert_eq!(rows.len(), 1);
    assert!(rows[0].get("github_device_code").is_none());
    assert!(!rows.iter().any(|r| r.to_string().contains("gh-device-code")));
    assert_eq!(rows[0]["expires_at"], json!({"N": "1791979800"}), "the TTL attribute is a number");
    assert_eq!(rows[0]["consumed_at"], json!({"S": "2025-10-13T12:00:00.000Z"}));
    assert!(!fake.operations().iter().any(|o| o == "DeleteItem"));
}

#[tokio::test]
async fn the_by_account_index_is_read_without_a_consistent_read() {
    let (s, fake) = auth_rig(FakeConfig::registry("t"));
    s.put_token(&tok("tok_a", &hash(1))).await.unwrap();
    s.list_tokens(1).await.unwrap();
    s.get_user_token(1, "tok_a").await.unwrap();
    for q in bodies(&fake, "Query") {
        assert!(q.get("ConsistentRead").is_none_or(|c| c == &Value::Bool(false)), "{q}");
        assert_eq!(q["IndexName"], "by_github_id");
    }
}

// ---- publish: only GetItem and PutItem, and the row kinds ------------------------------------------------

#[tokio::test]
async fn publish_uses_only_get_item_and_put_item_which_is_what_the_role_is_granted() {
    use mopm_ports::types::{PublishRecord, PublishStatus, UploadRecord};
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let s = DynamoPublishStore::new(client(&fake.endpoint()), &PublishTables::for_stage("t"));
    let up = UploadRecord {
        upload_id: "u1".into(),
        name: "demo".into(),
        version: "1.0.0".into(),
        canonical: "1".into(),
        subdir: "noarch".into(),
        filename: "f".into(),
        sha256: "a".repeat(64),
        size: 10,
        key: "quarantine/u1/f".into(),
        actor: "u:1".into(),
        created_at: "t".into(),
        url_expires_at: "t".into(),
        expires_at: 1_792_000_000,
        used_by: None,
    };
    let pr = PublishRecord {
        publish_id: "p".into(),
        name: "demo".into(),
        version: "1.0.0".into(),
        canonical: "1".into(),
        actor: "u:1".into(),
        published_by: "octo".into(),
        status: PublishStatus::Pending,
        rejection_code: None,
        message: None,
        manifest_sha256: "b".repeat(64),
        display: None,
        files: vec![],
        remaining_subdirs: vec![],
        created_at: "t".into(),
        updated_at: "t".into(),
        rev: 0,
    };
    s.put_upload(&up).await.unwrap();
    s.use_upload("u1", "p").await.unwrap();
    s.claim_version("demo", "1", "p").await.unwrap();
    s.create_publish(&pr).await.unwrap();
    s.update_publish("p", |c| Some(PublishRecord { status: PublishStatus::Validating, ..c.clone() })).await.unwrap();
    s.hit("rl#t#tok#2026-10-14", 5, 1_792_000_000).await.unwrap();
    let ops: std::collections::BTreeSet<String> = fake.operations().into_iter().collect();
    assert_eq!(ops, ["GetItem", "PutItem"].into_iter().map(String::from).collect());
    // Locks and counters share the publishes table under prefixed keys; the TTL attribute of a counter is a number.
    let keys: Vec<String> = fake.dump("mopm-t-publishes").iter().map(|r| r["publish_id"]["S"].as_str().unwrap().to_string()).collect();
    assert_eq!(keys, ["p", "rl#t#tok#2026-10-14", "ver#demo#1"]);
    assert_eq!(fake.dump("mopm-t-publishes")[1]["expires_at"], json!({"N": "1792000000"}));
    assert_eq!(fake.dump("mopm-t-uploads")[0]["expires_at"], json!({"N": "1792000000"}));
    assert_eq!(fake.dump("mopm-t-uploads")[0]["used_by"], json!({"S": "p"}));
}

// ---- more of the fake's strictness: the defects the TypeScript fakes faulty -----------------------------

async fn put_raw(c: &Client, table: &str, item: Value) -> Result<(), String> {
    use aws_sdk_dynamodb::types::AttributeValue;
    let item: std::collections::HashMap<String, AttributeValue> = item
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| {
            let av = if let Some(x) = v.get("S") { AttributeValue::S(x.as_str().unwrap().into()) } else { AttributeValue::N(v["N"].as_str().unwrap().into()) };
            (k.clone(), av)
        })
        .collect();
    c.put_item().table_name(table).set_item(Some(item)).send().await.map(|_| ()).map_err(|e| aws_sdk_dynamodb::error::DisplayErrorContext(&e).to_string())
}

#[tokio::test]
async fn a_ttl_attribute_stored_as_the_iso_string_is_refused_as_dynamodb_would() {
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let c = client(&fake.endpoint());
    let row = |ttl: Value| json!({"token_hash": {"S": hash(1)}, "expires_at": ttl});
    let e = put_raw(&c, "mopm-t-tokens", row(json!({"S": "2026-11-13T12:00:00.123Z"}))).await.unwrap_err();
    assert!(e.contains("TimeToLive"), "{e}");
    put_raw(&c, "mopm-t-tokens", row(json!({"N": "1794571200"}))).await.unwrap();
}

#[tokio::test]
async fn a_numeric_key_or_index_key_is_refused() {
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let c = client(&fake.endpoint());
    let e = put_raw(&c, "mopm-t-users", json!({"github_id": {"N": "7"}})).await.unwrap_err();
    assert!(e.contains("Type mismatch for key"), "{e}");
    let e = put_raw(&c, "mopm-t-tokens", json!({"token_hash": {"S": hash(2)}, "github_id": {"N": "1"}, "id": {"S": "t"}})).await.unwrap_err();
    assert!(e.contains("Type mismatch for Index Key"), "{e}");
}

#[tokio::test]
async fn a_consistent_read_of_an_index_is_refused() {
    use aws_sdk_dynamodb::types::AttributeValue::S;
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let c = client(&fake.endpoint());
    let r = c
        .query()
        .table_name("mopm-t-tokens")
        .index_name("by_github_id")
        .key_condition_expression("#g = :g")
        .expression_attribute_names("#g", "github_id")
        .expression_attribute_values(":g", S("1".into()))
        .consistent_read(true)
        .send()
        .await;
    let e = aws_sdk_dynamodb::error::DisplayErrorContext(&r.unwrap_err()).to_string();
    assert!(e.contains("Consistent reads"), "{e}");
}

// ---- rows that belong to a group publish ---------------------------------------------------------------

#[tokio::test]
async fn a_group_member_row_carries_its_group_and_stamp_as_attributes_and_a_reserved_one_has_no_stamp() {
    let (s, fake) = rig();
    s.create_version(&group_row(rec("p", "1.0.0"), "g1", Some(2)), &audit("p", "stage", None)).await.unwrap();
    s.create_version(&group_row(rec("p", "1.1.0"), "g1", None), &audit("p", "reserve", None)).await.unwrap();
    let rows = fake.dump("mopm-t-versions");
    let row = |spelling: &str| rows.iter().find(|r| r["version_spelling"] == json!({"S": spelling})).unwrap().clone();
    let (staged, reserved) = (row("1.0.0"), row("1.1.0"));
    assert_eq!((&staged["state"], &staged["group_id"], &staged["staged_attempt"]), (&json!({"S": "pending"}), &json!({"S": "g1"}), &json!({"N": "2"})));
    assert_eq!((&reserved["state"], &reserved["group_id"]), (&json!({"S": "pending"}), &json!({"S": "g1"})));
    assert!(reserved.get("staged_attempt").is_none(), "absent, not null");
    assert_eq!(s.get_version("p", "1.0.0").await.unwrap().unwrap().staged_attempt, Some(2));
    assert_eq!(s.get_version("p", "1.1.0").await.unwrap().unwrap().staged_attempt, None);
}

#[tokio::test]
async fn a_row_with_no_group_is_written_with_no_group_attribute_and_a_single_publish_of_a_group_row_writes_nothing() {
    let (s, fake) = rig();
    s.create_version(&with_state(rec("p", "1.0.0"), VersionState::Pending), &audit("p", "begin", None)).await.unwrap();
    s.create_version(&group_row(rec("p", "2.0.0"), "g1", Some(1)), &audit("p", "stage", None)).await.unwrap();
    s.update_version("p", "1.0.0", &VersionEvent::Publish(None), &audit("p", "publish", None)).await.unwrap();
    let writes = bodies(&fake, "TransactWriteItems").len();
    assert_eq!(writes, 3, "two creates and one publish");
    assert!(s.update_version("p", "2.0.0", &VersionEvent::Publish(None), &audit("p", "publish", None)).await.is_err());
    assert_eq!(bodies(&fake, "TransactWriteItems").len(), writes, "the refusal happened before any write");
    for r in fake.dump("mopm-t-versions") {
        let own_group = r["version_spelling"] == json!({"S": "2.0.0"});
        assert_eq!((r.get("group_id").is_some(), r.get("staged_attempt").is_some()), (own_group, own_group), "{r}");
    }
}

#[tokio::test]
async fn a_yank_by_the_rust_port_keeps_the_group_attributes_of_a_flipped_row() {
    let (s, fake) = rig();
    let flipped = VersionRecord { state: VersionState::Published, ..group_row(rec("p", "1.0.0"), "g1", Some(3)) };
    s.create_version(&flipped, &audit("p", "flip", None)).await.unwrap();
    s.update_version("p", "1.0.0", &VersionEvent::Yank { reason: "bad".into() }, &audit("p", "yank", None)).await.unwrap();
    let rows = fake.dump("mopm-t-versions");
    assert_eq!((&rows[0]["state"], &rows[0]["group_id"], &rows[0]["staged_attempt"], &rows[0]["rev"]), (&json!({"S": "yanked"}), &json!({"S": "g1"}), &json!({"N": "3"}), &json!({"N": "1"})));
}

#[tokio::test]
async fn a_condition_the_fake_does_not_know_fails_loudly() {
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let c = client(&fake.endpoint());
    let r = c
        .put_item()
        .table_name("mopm-t-users")
        .item("github_id", aws_sdk_dynamodb::types::AttributeValue::S("7".into()))
        .condition_expression("size(#a) > :v")
        .expression_attribute_names("#a", "github_id")
        .expression_attribute_values(":v", aws_sdk_dynamodb::types::AttributeValue::N("1".into()))
        .send()
        .await;
    let e = aws_sdk_dynamodb::error::DisplayErrorContext(&r.unwrap_err()).to_string();
    assert!(e.contains("unsupported condition"), "{e}");
}
