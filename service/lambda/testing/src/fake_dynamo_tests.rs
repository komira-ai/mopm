//! More of the fake DynamoDB, beside `fake_dynamo/tests.rs`: a request head over several reads, expression
//! tokens, a grant without the action, and Scan paging (a page size of 0 included).

use serde_json::{json, Value};

use super::*;
use crate::fake_http::client::{exchange, request, Answered};

pub(super) const PACKAGES: &str = "mopm-t-packages";
pub(super) const VERSIONS: &str = "mopm-t-versions";
pub(super) const VALIDATION: &str = "com.amazon.coral.validate#ValidationException";
pub(super) const DENIED: &str = "com.amazon.coral.service#AccessDeniedException";

pub(super) fn fake() -> FakeDynamo {
    FakeDynamo::start(FakeConfig::registry("t"))
}

pub(super) fn fake_with_grants(grants: &str) -> FakeDynamo {
    FakeDynamo::start(
        FakeConfig::registry("t").with_grants("mopm-t-", Grants::parse(grants).expect("grants")),
    )
}

pub(super) async fn call(fake: &FakeDynamo, op: &str, body: &Value) -> Answered {
    let target = format!("DynamoDB_20120810.{op}");
    let raw = request(
        "POST",
        "/",
        &[
            ("X-Amz-Target", target.as_str()),
            ("Content-Type", "application/x-amz-json-1.0"),
        ],
        body.to_string().as_bytes(),
    );
    exchange(&fake.endpoint(), &raw).await.expect("an answer")
}

/// The answer must be a 400 with exactly this type and message.
pub(super) fn assert_refused(got: &Answered, type_: &str, message: &str) {
    assert_eq!(got.status, 400);
    let body = got.json();
    assert_eq!(body["__type"], type_);
    assert_eq!(
        body.get("message").or_else(|| body.get("Message")),
        Some(&json!(message))
    );
}

pub(super) fn pkg(name: &str) -> Value {
    json!({"name": {"S": name}})
}

pub(super) async fn put(fake: &FakeDynamo, table: &str, item: Value) {
    let got = call(fake, "PutItem", &json!({"TableName": table, "Item": item})).await;
    assert_eq!(got.status, 200);
}

// ---- transport ----

#[tokio::test]
async fn a_request_head_larger_than_one_read_is_reassembled() {
    let fake = fake();
    let big = "x".repeat(20_000);
    let body = json!({"TableName": PACKAGES, "Key": pkg("a")}).to_string();
    let raw = request(
        "POST",
        "/",
        &[
            ("X-Amz-Target", "DynamoDB_20120810.GetItem"),
            ("X-Pad", big.as_str()),
        ],
        body.as_bytes(),
    );
    let got = exchange(&fake.endpoint(), &raw).await.expect("an answer");
    assert_eq!((got.status, got.json()), (200, json!({})));
    assert_eq!(fake.operations(), vec!["GetItem"]);
}

// ---- expressions ----

pub(super) fn put_cond(cond: &str, names: Value, values: Value) -> Value {
    json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": cond,
           "ExpressionAttributeNames": names, "ExpressionAttributeValues": values})
}

#[tokio::test]
async fn a_name_with_an_underscore_is_one_token_of_the_expression() {
    let body = json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "attribute_not_exists(#a_b)",
                      "ExpressionAttributeNames": {"#a_b": "name"}});
    assert_eq!(call(&fake(), "PutItem", &body).await.status, 200);
}

// ---- grants ----

const GRANTS: &str = r#"{"packages": {"actions": ["dynamodb:Query", "dynamodb:Scan"], "indexes": ["by_search_bucket"]}}"#;

#[tokio::test]
async fn an_action_the_table_grant_lacks_is_denied() {
    let fake = fake_with_grants(GRANTS);
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_refused(
        &got,
        DENIED,
        "User is not authorized to perform: dynamodb:GetItem on resource: mopm-t-packages",
    );
}

// ---- query ----

pub(super) fn query_with(kc: &str, names: Value, values: Value) -> Value {
    json!({"TableName": VERSIONS, "KeyConditionExpression": kc,
           "ExpressionAttributeNames": names, "ExpressionAttributeValues": values})
}

// ---- paging ----

#[tokio::test]
async fn a_scan_without_a_projection_returns_whole_items_in_pages_with_a_resume_key() {
    let fake = fake();
    for n in ["a", "b", "c"] {
        put(
            &fake,
            PACKAGES,
            json!({"name": {"S": n}, "state": {"S": "x"}}),
        )
        .await;
    }
    let got = call(&fake, "Scan", &json!({"TableName": PACKAGES})).await;
    assert_eq!(
        got.json(),
        json!({"Items": [{"name": {"S": "a"}, "state": {"S": "x"}}, {"name": {"S": "b"}, "state": {"S": "x"}}],
               "Count": 2, "ScannedCount": 2, "LastEvaluatedKey": {"name": {"S": "b"}}})
    );
}

#[tokio::test]
async fn a_scan_with_a_page_size_of_zero_returns_no_items_and_no_resume_key() {
    let mut cfg = FakeConfig::registry("t");
    cfg.page_size = 0;
    let fake = FakeDynamo::start(cfg);
    fake.seed(PACKAGES, pkg("a"));
    let got = call(&fake, "Scan", &json!({"TableName": PACKAGES})).await;
    assert_eq!(
        got.json(),
        json!({"Items": [], "Count": 0, "ScannedCount": 0})
    );
}

// ---- transactions ----

pub(super) fn transact_body(items: Vec<Value>, token: Option<&str>) -> Value {
    let mut b = json!({"TransactItems": items});
    if let Some(t) = token {
        b["ClientRequestToken"] = json!(t);
    }
    b
}

pub(super) fn tput(name: &str) -> Value {
    json!({"Put": {"TableName": PACKAGES, "Item": pkg(name)}})
}
