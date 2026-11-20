//! What is true of the web sign-in's DynamoDB adapters (`DynamoWebLoginStore`, `DynamoNamespaceStore`) and not of
//! their ports: the rows as DynamoDB JSON (the namespace row against the golden the TypeScript adapter's test reads,
//! `service/api/test/auth/namespace-row.test.ts`), the requests, the grants they need, and the failures that are
//! faults rather than answers.

use std::collections::BTreeSet;

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_dynamodb::error::ProvideErrorMetadata;
use aws_sdk_dynamodb::types::AttributeValue;
use aws_sdk_dynamodb::Client;
use jiff::Timestamp;
use mopm_ports::env::Clock;
use mopm_ports::namespaces::{NamespaceKind, NamespaceRecord, NamespaceStore, UserNamespace};
use mopm_ports::web_login::{WebLoginRecord, WebLoginStore};
use mopm_testing::env::FixedClock;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, Grants, WEB_LOGIN_GRANTS};
use mopm_testing::fake_http::{FakeHttp, Reply};
use serde_json::{json, Value};

use crate::dynamo::{DynamoNamespaceStore, DynamoWebLoginStore};

const WEB_LOGINS: &str = "mopm-t-web_logins";
const NAMESPACES: &str = "mopm-t-namespaces";
/// The user namespace row `toItem` of `dynamo-namespace-store.ts` writes for one login, as DynamoDB JSON.
const NAMESPACE_GOLDEN: &str = include_str!("../tests/fixtures/namespace_user_row.json");

/// 2026-11-19T12:00:00.000Z
const START_MS: i64 = 1_795_089_600_000;
/// Ten minutes after `START_MS`, in epoch seconds.
const EXPIRES_AT: i64 = 1_795_090_200;
const NOW: &str = "2026-11-19T12:00:00.000Z";

fn client(endpoint: &str) -> Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new(
            "AKIDFAKE",
            "fakesecret",
            None,
            None,
            "static",
        ))
        .build();
    Client::from_conf(config)
}

struct Rig {
    logins: DynamoWebLoginStore,
    namespaces: DynamoNamespaceStore,
    client: Client,
    fake: FakeDynamo,
}

fn rig(cfg: FakeConfig) -> Rig {
    let fake = FakeDynamo::start(cfg);
    let c = client(&fake.endpoint());
    Rig {
        logins: DynamoWebLoginStore::new(c.clone(), DynamoWebLoginStore::table_for_stage("t")),
        namespaces: DynamoNamespaceStore::new(
            c.clone(),
            DynamoNamespaceStore::table_for_stage("t"),
        ),
        client: c,
        fake,
    }
}

fn h(n: u32) -> String {
    format!("{n:064}")
}

fn login(n: u32) -> WebLoginRecord {
    WebLoginRecord {
        id: h(n),
        state_hash: h(100 + n),
        code_verifier: format!("verifier-{n}"),
        return_to: "/tutorial?lesson=2".into(),
        expires_at: EXPIRES_AT,
        consumed_at: None,
    }
}

fn login_row(n: u32) -> Value {
    json!({"id": {"S": h(n)}, "state_hash": {"S": h(100 + n)}, "code_verifier": {"S": format!("verifier-{n}")}, "return_to": {"S": "/tutorial?lesson=2"}, "expires_at": {"N": EXPIRES_AT.to_string()}})
}

fn at(ms: i64) -> Timestamp {
    Timestamp::from_millisecond(ms).unwrap()
}

fn bodies(fake: &FakeDynamo, op: &str) -> Vec<Value> {
    fake.requests()
        .into_iter()
        .filter(|r| r.operation == op)
        .map(|r| r.body)
        .collect()
}

fn user(namespace: &str, github_id: u64) -> NamespaceRecord {
    NamespaceRecord {
        namespace: namespace.into(),
        kind: NamespaceKind::User,
        github_id,
        created_at: NOW.into(),
        created_by: None,
    }
}

// ---- web_logins ----------------------------------------------------------------------------------------

#[tokio::test]
async fn a_login_row_is_the_record_with_expires_at_a_number_and_gains_consumed_at_when_taken() {
    let r = rig(FakeConfig::web_login("t"));
    r.logins.put(&login(1)).await.unwrap();
    assert_eq!(r.fake.dump(WEB_LOGINS), vec![login_row(1)]);
    let taken = r.logins.consume(&h(1), at(START_MS + 1_250)).await.unwrap();
    assert_eq!(
        taken,
        Some(WebLoginRecord {
            consumed_at: Some("2026-11-19T12:00:01.250Z".into()),
            ..login(1)
        })
    );
    let mut row = login_row(1);
    row["consumed_at"] = json!({"S": "2026-11-19T12:00:01.250Z"});
    assert_eq!(r.fake.dump(WEB_LOGINS), vec![row]);
}

#[tokio::test]
async fn a_put_is_one_unconditional_put_item_of_the_row() {
    let r = rig(FakeConfig::web_login("t"));
    r.logins.put(&login(1)).await.unwrap();
    assert_eq!(r.fake.operations(), ["PutItem"]);
    assert_eq!(
        bodies(&r.fake, "PutItem"),
        vec![json!({"TableName": WEB_LOGINS, "Item": login_row(1)})]
    );
}

#[tokio::test]
async fn consume_is_one_conditional_update_item_that_answers_the_new_row() {
    let r = rig(FakeConfig::web_login("t"));
    r.logins.put(&login(1)).await.unwrap();
    r.fake.clear_requests();
    r.logins.consume(&h(1), at(START_MS)).await.unwrap();
    assert_eq!(r.fake.operations(), ["UpdateItem"]);
    assert_eq!(
        bodies(&r.fake, "UpdateItem"),
        vec![json!({
            "TableName": WEB_LOGINS,
            "Key": {"id": {"S": h(1)}},
            "UpdateExpression": "SET #c = :at",
            "ConditionExpression": "attribute_exists(#id) AND attribute_not_exists(#c) AND #e > :now",
            "ExpressionAttributeNames": {"#id": "id", "#c": "consumed_at", "#e": "expires_at"},
            "ExpressionAttributeValues": {":at": {"S": NOW}, ":now": {"N": "1795089600"}},
            "ReturnValues": "ALL_NEW"
        })]
    );
}

#[tokio::test]
async fn a_second_consume_is_none_and_the_first_consumed_at_stays() {
    let r = rig(FakeConfig::web_login("t"));
    r.logins.put(&login(1)).await.unwrap();
    assert!(r
        .logins
        .consume(&h(1), at(START_MS))
        .await
        .unwrap()
        .is_some());
    let after_first = r.fake.dump(WEB_LOGINS);
    assert_eq!(
        r.logins.consume(&h(1), at(START_MS + 5_000)).await.unwrap(),
        None
    );
    assert_eq!(
        r.fake.dump(WEB_LOGINS),
        after_first,
        "a refused consume writes nothing"
    );
    assert_eq!(after_first[0]["consumed_at"], json!({"S": NOW}));
}

#[tokio::test]
async fn an_expired_row_cannot_be_consumed_and_is_left_as_stored() {
    let r = rig(FakeConfig::web_login("t"));
    r.logins.put(&login(1)).await.unwrap();
    let clock = FixedClock::at_millis(EXPIRES_AT * 1000);
    assert_eq!(
        r.logins.consume(&h(1), clock.now()).await.unwrap(),
        None,
        "expired at expires_at"
    );
    clock.advance_millis(86_400_000);
    assert_eq!(
        r.logins.consume(&h(1), clock.now()).await.unwrap(),
        None,
        "and a day later"
    );
    assert_eq!(
        r.fake.dump(WEB_LOGINS),
        vec![login_row(1)],
        "no consumed_at was written"
    );
    let before = FixedClock::at_millis(EXPIRES_AT * 1000 - 1);
    assert!(
        r.logins
            .consume(&h(1), before.now())
            .await
            .unwrap()
            .is_some(),
        "a millisecond before, it is consumable"
    );
}

#[tokio::test]
async fn an_unknown_id_is_none_and_creates_no_row() {
    let r = rig(FakeConfig::web_login("t"));
    assert_eq!(r.logins.consume(&h(9), at(START_MS)).await.unwrap(), None);
    assert!(
        r.fake.dump(WEB_LOGINS).is_empty(),
        "the update's condition kept it from creating the item"
    );
}

// ---- namespaces ----------------------------------------------------------------------------------------

#[tokio::test]
async fn the_user_namespace_row_equals_the_golden_the_typescript_adapter_writes() {
    let golden: Value = serde_json::from_str(NAMESPACE_GOLDEN).unwrap();
    let github_id = golden["github_id"].as_u64().unwrap();
    let r = rig(FakeConfig::web_login("t"));
    let got = r
        .namespaces
        .ensure_user_namespace(
            github_id,
            golden["login"].as_str().unwrap(),
            golden["now"].as_str().unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(got, Some(UserNamespace::Created(user("alice-dev", 4242))));
    assert_eq!(r.fake.dump(NAMESPACES), vec![golden["item"].clone()]);
    assert_eq!(
        bodies(&r.fake, "PutItem"),
        vec![
            json!({"TableName": NAMESPACES, "Item": golden["item"], "ConditionExpression": "attribute_not_exists(#n)", "ExpressionAttributeNames": {"#n": "namespace"}})
        ]
    );
    assert_eq!(
        r.fake.operations(),
        ["PutItem"],
        "create-once is a conditional put, never a read first"
    );
}

#[tokio::test]
async fn a_create_that_loses_reads_the_held_row_strongly_consistent() {
    let r = rig(FakeConfig::web_login("t"));
    r.namespaces
        .ensure_user_namespace(7, "alice", NOW)
        .await
        .unwrap();
    r.fake.clear_requests();
    let again = r
        .namespaces
        .ensure_user_namespace(7, "Alice", "2026-11-20T08:00:00.000Z")
        .await
        .unwrap();
    assert_eq!(again, Some(UserNamespace::Held(user("alice", 7))));
    assert_eq!(r.fake.operations(), ["PutItem", "GetItem"]);
    assert_eq!(
        bodies(&r.fake, "GetItem"),
        vec![
            json!({"TableName": NAMESPACES, "Key": {"namespace": {"S": "alice"}}, "ConsistentRead": true})
        ]
    );
    assert_eq!(
        r.fake.dump(NAMESPACES).len(),
        1,
        "the held row is not overwritten"
    );
    assert_eq!(r.fake.dump(NAMESPACES)[0]["created_at"], json!({"S": NOW}));
}

#[tokio::test]
async fn an_organization_row_the_typescript_adapter_wrote_reads_back_without_members_rev() {
    let r = rig(FakeConfig::web_login("t"));
    r.fake.seed(
        NAMESPACES,
        json!({"namespace": {"S": "komira-ai"}, "kind": {"S": "org"}, "github_id": {"S": "77"}, "github_id_num": {"N": "77"}, "created_at": {"S": NOW}, "created_by": {"N": "4242"}, "members_rev": {"N": "3"}}),
    );
    let org = NamespaceRecord {
        namespace: "komira-ai".into(),
        kind: NamespaceKind::Org,
        github_id: 77,
        created_at: NOW.into(),
        created_by: Some(4242),
    };
    assert_eq!(
        r.namespaces
            .ensure_user_namespace(77, "komira-ai", NOW)
            .await
            .unwrap(),
        Some(UserNamespace::Held(org))
    );
    assert_eq!(
        r.namespaces
            .ensure_user_namespace(4242, "Komira-AI", NOW)
            .await
            .unwrap(),
        None,
        "held by another GitHub id"
    );
}

#[tokio::test]
async fn a_login_without_a_namespace_makes_no_request() {
    let r = rig(FakeConfig::web_login("t"));
    assert_eq!(
        r.namespaces
            .ensure_user_namespace(7, "linux-64", NOW)
            .await
            .unwrap(),
        None
    );
    assert_eq!(
        r.namespaces
            .ensure_user_namespace(7, "a_b", NOW)
            .await
            .unwrap(),
        None
    );
    assert!(r.fake.operations().is_empty());
}

// ---- grants --------------------------------------------------------------------------------------------

/// Every path of both adapters: a put, a consume taken, refused and unknown, a create, a held and a taken namespace.
async fn every_path(r: &Rig) {
    r.logins.put(&login(1)).await.unwrap();
    r.logins.consume(&h(1), at(START_MS)).await.unwrap();
    r.logins.consume(&h(1), at(START_MS)).await.unwrap();
    r.logins.consume(&h(2), at(START_MS)).await.unwrap();
    r.namespaces
        .ensure_user_namespace(7, "alice", NOW)
        .await
        .unwrap();
    r.namespaces
        .ensure_user_namespace(7, "alice", NOW)
        .await
        .unwrap();
    r.namespaces
        .ensure_user_namespace(8, "alice", NOW)
        .await
        .unwrap();
}

#[tokio::test]
async fn the_sign_in_grants_are_exactly_the_calls_the_adapters_make() {
    let r = rig(FakeConfig::web_login("t"));
    every_path(&r).await;
    let made: BTreeSet<(String, String)> = r
        .fake
        .requests()
        .into_iter()
        .map(|q| {
            (
                q.body["TableName"]
                    .as_str()
                    .unwrap()
                    .trim_start_matches("mopm-t-")
                    .to_string(),
                format!("dynamodb:{}", q.operation),
            )
        })
        .collect();
    let grants: Value = serde_json::from_str(WEB_LOGIN_GRANTS).unwrap();
    let granted: BTreeSet<(String, String)> = grants
        .as_object()
        .unwrap()
        .iter()
        .flat_map(|(table, g)| {
            g["actions"]
                .as_array()
                .unwrap()
                .iter()
                .map(move |a| (table.clone(), a.as_str().unwrap().to_string()))
        })
        .collect();
    assert_eq!(made, granted);
    assert!(
        grants
            .as_object()
            .unwrap()
            .values()
            .all(|g| g.get("indexes").is_none()),
        "no index is read"
    );
}

#[tokio::test]
async fn no_path_deletes_a_row_and_the_role_cannot() {
    let r = rig(FakeConfig::web_login("t"));
    every_path(&r).await;
    assert!(!r.fake.operations().iter().any(|o| o == "DeleteItem"));
    for (table, key) in [
        (WEB_LOGINS, ("id", h(1))),
        (NAMESPACES, ("namespace", "alice".to_string())),
    ] {
        let e = r
            .client
            .delete_item()
            .table_name(table)
            .key(key.0, AttributeValue::S(key.1))
            .send()
            .await
            .unwrap_err();
        assert_eq!(
            e.as_service_error().and_then(ProvideErrorMetadata::code),
            Some("AccessDeniedException"),
            "{table}"
        );
    }
    assert_eq!(r.fake.dump(WEB_LOGINS).len(), 1);
    assert_eq!(r.fake.dump(NAMESPACES).len(), 1);
}

// ---- faults --------------------------------------------------------------------------------------------

fn fault_text(e: mopm_ports::error::PortError) -> String {
    e.to_string()
}

#[tokio::test]
async fn a_call_the_role_may_not_make_is_a_fault_not_an_answer() {
    let r = rig(FakeConfig::registry("t").with_grants("mopm-t-", Grants::parse("{}").unwrap()));
    let put = fault_text(r.logins.put(&login(1)).await.unwrap_err());
    assert!(
        put.starts_with("infrastructure fault: put web login: ") && put.contains("AccessDenied"),
        "{put}"
    );
    let consume = fault_text(r.logins.consume(&h(1), at(START_MS)).await.unwrap_err());
    assert!(
        consume.starts_with("infrastructure fault: consume web login: ")
            && consume.contains("AccessDenied"),
        "{consume}"
    );
    let create = fault_text(
        r.namespaces
            .ensure_user_namespace(7, "alice", NOW)
            .await
            .unwrap_err(),
    );
    assert!(
        create.starts_with("infrastructure fault: put namespace: ")
            && create.contains("AccessDenied"),
        "{create}"
    );
}

#[tokio::test]
async fn a_refused_create_whose_read_is_denied_is_a_fault() {
    let put_only = Grants::parse(r#"{"namespaces": {"actions": ["dynamodb:PutItem"]}}"#).unwrap();
    let r = rig(FakeConfig::registry("t").with_grants("mopm-t-", put_only));
    r.namespaces
        .ensure_user_namespace(7, "alice", NOW)
        .await
        .unwrap();
    let read = fault_text(
        r.namespaces
            .ensure_user_namespace(7, "alice", NOW)
            .await
            .unwrap_err(),
    );
    assert!(
        read.starts_with("infrastructure fault: get namespace: ") && read.contains("AccessDenied"),
        "{read}"
    );
}

fn scripted(replies: Vec<Reply>) -> (FakeHttp, Client) {
    let fake = FakeHttp::start(replies);
    let c = client(&fake.endpoint());
    (fake, c)
}

fn dynamo_reply(status: u16, body: Value) -> Reply {
    Reply::new(status)
        .header("content-type", "application/x-amz-json-1.0")
        .body(body.to_string())
}

#[tokio::test]
async fn a_consume_answered_without_the_row_or_with_a_row_that_is_not_a_record_is_a_fault() {
    let (_fake, c) = scripted(vec![dynamo_reply(200, json!({}))]);
    let s = DynamoWebLoginStore::new(c, WEB_LOGINS.into());
    assert_eq!(
        fault_text(s.consume(&h(1), at(START_MS)).await.unwrap_err()),
        "infrastructure fault: consume web login: the update answered no row"
    );
    let (_fake, c) = scripted(vec![dynamo_reply(
        200,
        json!({"Attributes": {"id": {"S": h(1)}}}),
    )]);
    let s = DynamoWebLoginStore::new(c, WEB_LOGINS.into());
    let e = fault_text(s.consume(&h(1), at(START_MS)).await.unwrap_err());
    assert!(e.starts_with("infrastructure fault: missing field"), "{e}");
}

fn condition_failed() -> Reply {
    dynamo_reply(
        400,
        json!({"__type": "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException", "message": "The conditional request failed"}),
    )
}

#[tokio::test]
async fn a_refused_create_with_no_row_to_read_is_a_fault() {
    let (fake, c) = scripted(vec![condition_failed(), dynamo_reply(200, json!({}))]);
    let s = DynamoNamespaceStore::new(c, NAMESPACES.into());
    assert_eq!(
        fault_text(s.ensure_user_namespace(7, "alice", NOW).await.unwrap_err()),
        "infrastructure fault: namespace alice: the create was refused but no row is stored"
    );
    assert_eq!(fake.requests().len(), 2);
}

#[tokio::test]
async fn a_held_row_without_its_numeric_id_is_a_fault() {
    let r = rig(FakeConfig::web_login("t"));
    r.fake.seed(NAMESPACES, json!({"namespace": {"S": "alice"}, "kind": {"S": "user"}, "github_id": {"S": "7"}, "created_at": {"S": NOW}}));
    let e = fault_text(
        r.namespaces
            .ensure_user_namespace(7, "alice", NOW)
            .await
            .unwrap_err(),
    );
    assert_eq!(e, "infrastructure fault: missing field `github_id`");
}
