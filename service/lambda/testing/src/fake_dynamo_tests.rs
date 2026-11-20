//! What the adapters' tests rely on from the fake DynamoDB: the transport edge cases of its HTTP reader, the
//! exact errors for malformed expressions, queries, scans and transactions, and the grant enforcement.

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::*;
use crate::fake_http::client::{exchange, request, Answered};

const PACKAGES: &str = "mopm-t-packages";
const VERSIONS: &str = "mopm-t-versions";
const VALIDATION: &str = "com.amazon.coral.validate#ValidationException";
const DENIED: &str = "com.amazon.coral.service#AccessDeniedException";

fn fake() -> FakeDynamo {
    FakeDynamo::start(FakeConfig::registry("t"))
}

fn fake_with_grants(grants: &str) -> FakeDynamo {
    FakeDynamo::start(
        FakeConfig::registry("t").with_grants("mopm-t-", Grants::parse(grants).expect("grants")),
    )
}

async fn call(fake: &FakeDynamo, op: &str, body: &Value) -> Answered {
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
fn assert_refused(got: &Answered, type_: &str, message: &str) {
    assert_eq!(got.status, 400);
    let body = got.json();
    assert_eq!(body["__type"], type_);
    assert_eq!(
        body.get("message").or_else(|| body.get("Message")),
        Some(&json!(message))
    );
}

fn pkg(name: &str) -> Value {
    json!({"name": {"S": name}})
}

async fn put(fake: &FakeDynamo, table: &str, item: Value) {
    let got = call(fake, "PutItem", &json!({"TableName": table, "Item": item})).await;
    assert_eq!(got.status, 200);
}

async fn connect(fake: &FakeDynamo) -> TcpStream {
    TcpStream::connect(fake.endpoint().trim_start_matches("http://"))
        .await
        .expect("a connection")
}

async fn read_to_end(stream: &mut TcpStream) -> Vec<u8> {
    let mut out = Vec::new();
    let _ = stream.read_to_end(&mut out).await;
    out
}

/// Closes with a reset instead of a FIN, so the server's read fails instead of returning 0.
fn reset(s: TcpStream) {
    // Tokio deprecates `set_linger` over its blocking close; here the zero linger is the point: it makes the
    // kernel send a reset, the only way a loopback read fails.
    #[allow(deprecated)]
    s.set_linger(Some(std::time::Duration::ZERO))
        .expect("linger");
    drop(s);
}

// ---- transport ----

#[tokio::test]
async fn a_connection_reset_before_any_request_records_nothing() {
    let fake = fake();
    reset(connect(&fake).await);
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_eq!(got.status, 200);
    assert_eq!(fake.operations(), vec!["GetItem"]);
}

#[tokio::test]
async fn a_body_cut_short_by_a_reset_records_nothing() {
    let fake = fake();
    let mut s = connect(&fake).await;
    s.write_all(b"POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"a\":")
        .await
        .unwrap();
    reset(s);
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_eq!(got.status, 200);
    assert_eq!(fake.operations(), vec!["GetItem"]);
}

#[tokio::test]
async fn a_connection_closed_before_any_request_gets_no_answer_and_records_nothing() {
    let fake = fake();
    let mut s = connect(&fake).await;
    s.shutdown().await.unwrap();
    assert!(read_to_end(&mut s).await.is_empty());
    assert!(fake.requests().is_empty());
}

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

#[tokio::test]
async fn a_request_body_larger_than_one_read_is_reassembled() {
    let fake = fake();
    let item = json!({"name": {"S": "a"}, "blob": {"S": "y".repeat(50_000)}});
    put(&fake, PACKAGES, item.clone()).await;
    assert_eq!(fake.dump(PACKAGES), vec![item]);
}

#[tokio::test]
async fn a_body_cut_short_by_a_close_gets_no_answer_and_records_nothing() {
    let fake = fake();
    let mut s = connect(&fake).await;
    s.write_all(b"POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"a\":")
        .await
        .unwrap();
    s.shutdown().await.unwrap();
    assert!(read_to_end(&mut s).await.is_empty());
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn an_authorization_without_signed_headers_is_recorded_as_unsigned() {
    let fake = fake();
    let body = json!({"TableName": PACKAGES, "Key": pkg("a")}).to_string();
    let signed = "AWS4-HMAC-SHA256 Credential=k/20260101/r/dynamodb/aws4_request, SignedHeaders=host, Signature=00";
    for auth in [
        signed,
        "Bearer SignedHeaders=host",
        "AWS4-HMAC-SHA256 Credential=k/20260101/r/dynamodb/aws4_request",
    ] {
        let raw = request(
            "POST",
            "/",
            &[
                ("X-Amz-Target", "DynamoDB_20120810.GetItem"),
                ("Authorization", auth),
            ],
            body.as_bytes(),
        );
        exchange(&fake.endpoint(), &raw).await.expect("an answer");
    }
    let seen: Vec<bool> = fake.requests().iter().map(|r| r.signed).collect();
    assert_eq!(seen, vec![true, false, false]);
}

#[tokio::test]
async fn an_unknown_operation_is_a_validation_error_naming_it() {
    let got = call(&fake(), "BatchGetItem", &json!({})).await;
    assert_refused(&got, VALIDATION, "fake: unsupported operation BatchGetItem");
}

// ---- expressions ----

fn put_cond(cond: &str, names: Value, values: Value) -> Value {
    json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": cond,
           "ExpressionAttributeNames": names, "ExpressionAttributeValues": values})
}

#[tokio::test]
async fn a_name_with_an_underscore_is_one_token_of_the_expression() {
    let body = json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "attribute_not_exists(#a_b)",
                      "ExpressionAttributeNames": {"#a_b": "name"}});
    assert_eq!(call(&fake(), "PutItem", &body).await.status, 200);
}

#[tokio::test]
async fn an_unused_expression_attribute_value_is_refused() {
    let body = put_cond(
        "attribute_exists(#n)",
        json!({"#n": "name"}),
        json!({":v": {"S": "x"}}),
    );
    let got = call(&fake(), "PutItem", &body).await;
    assert_refused(
        &got,
        VALIDATION,
        "Value provided in ExpressionAttributeValues unused in expressions: keys: {:v}",
    );
}

#[tokio::test]
async fn an_unused_expression_attribute_name_is_refused() {
    let body = put_cond(
        "attribute_exists(#n)",
        json!({"#n": "name", "#m": "x"}),
        json!({}),
    );
    let got = call(&fake(), "PutItem", &body).await;
    assert_refused(
        &got,
        VALIDATION,
        "Value provided in ExpressionAttributeNames unused in expressions: keys: {#m}",
    );
}

#[tokio::test]
async fn an_undefined_expression_attribute_name_is_refused() {
    let body = json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "attribute_exists(#n)"});
    let got = call(&fake(), "PutItem", &body).await;
    assert_refused(
        &got,
        VALIDATION,
        "An expression attribute name used in the document path is not defined; attribute name: #n",
    );
}

#[tokio::test]
async fn an_undefined_expression_attribute_value_is_refused() {
    let body = json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "#n = :v",
                      "ExpressionAttributeNames": {"#n": "name"}});
    let got = call(&fake(), "PutItem", &body).await;
    assert_refused(
        &got,
        VALIDATION,
        "An expression attribute value used in expression is not defined; attribute value: :v",
    );
}

// ---- grants ----

const GRANTS: &str = r#"{"packages": {"actions": ["dynamodb:Query", "dynamodb:Scan"], "indexes": ["by_search_bucket"]}}"#;

#[tokio::test]
async fn a_table_the_grants_do_not_list_is_denied() {
    let fake = fake_with_grants(GRANTS);
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": VERSIONS, "Key": pkg("a")}),
    )
    .await;
    assert_refused(
        &got,
        DENIED,
        "User is not authorized to perform: dynamodb:GetItem on resource: mopm-t-versions",
    );
}

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

fn query_body(index: Option<&str>) -> Value {
    let mut b = json!({"TableName": PACKAGES, "KeyConditionExpression": "#p = :p",
                       "ExpressionAttributeNames": {"#p": "search_bucket"},
                       "ExpressionAttributeValues": {":p": {"S": "b"}}});
    if let Some(i) = index {
        b["IndexName"] = json!(i);
    }
    b
}

#[tokio::test]
async fn an_index_the_grant_does_not_list_is_denied_while_a_listed_one_is_served() {
    let fake = fake_with_grants(GRANTS);
    let got = call(&fake, "Query", &query_body(Some("by_other"))).await;
    assert_refused(&got, DENIED, "User is not authorized to perform: dynamodb:Query on index by_other on resource: mopm-t-packages");
    let got = call(&fake, "Query", &query_body(Some("by_search_bucket"))).await;
    assert_eq!((got.status, got.json()["Count"].clone()), (200, json!(0)));
}

// ---- query ----

fn query_with(kc: &str, names: Value, values: Value) -> Value {
    json!({"TableName": VERSIONS, "KeyConditionExpression": kc,
           "ExpressionAttributeNames": names, "ExpressionAttributeValues": values})
}

#[tokio::test]
async fn a_limit_below_one_is_refused() {
    let mut b = query_body(None);
    b["ExpressionAttributeNames"] = json!({"#p": "name"});
    b["Limit"] = json!(0);
    let got = call(&fake(), "Query", &b).await;
    assert_refused(&got, VALIDATION, "Limit must be a positive integer");
}

#[tokio::test]
async fn a_key_condition_on_a_non_key_attribute_is_refused() {
    let b = query_with("#p = :p", json!({"#p": "other"}), json!({":p": {"S": "a"}}));
    let got = call(&fake(), "Query", &b).await;
    assert_refused(
        &got,
        VALIDATION,
        "Query condition missed key schema element: name",
    );
}

#[tokio::test]
async fn begins_with_on_the_partition_key_is_refused() {
    let b = query_with(
        "#p = :p AND begins_with(#p, :v)",
        json!({"#p": "name"}),
        json!({":p": {"S": "a"}, ":v": {"S": "1"}}),
    );
    let got = call(&fake(), "Query", &b).await;
    assert_refused(
        &got,
        VALIDATION,
        "begins_with must be on the sort key Some(\"version\")",
    );
}

#[tokio::test]
async fn an_equality_on_a_non_sort_attribute_is_refused() {
    let b = query_with(
        "#p = :p AND #s = :v",
        json!({"#p": "name", "#s": "other"}),
        json!({":p": {"S": "a"}, ":v": {"S": "1"}}),
    );
    let got = call(&fake(), "Query", &b).await;
    assert_refused(
        &got,
        VALIDATION,
        "Query condition missed key schema element: Some(\"version\")",
    );
}

#[tokio::test]
async fn a_sort_condition_that_is_neither_begins_with_nor_equality_is_refused() {
    let b = query_with(
        "#p = :p AND #s > :v",
        json!({"#p": "name", "#s": "version"}),
        json!({":p": {"S": "a"}, ":v": {"S": "1"}}),
    );
    let got = call(&fake(), "Query", &b).await;
    assert_refused(&got, VALIDATION, "fake: unsupported key condition #s > :v");
}

// ---- paging ----

#[tokio::test]
async fn a_page_size_of_zero_returns_no_items_and_no_resume_key() {
    let mut cfg = FakeConfig::registry("t");
    cfg.page_size = 0;
    let fake = FakeDynamo::start(cfg);
    fake.seed(
        PACKAGES,
        json!({"name": {"S": "a"}, "search_bucket": {"S": "b"}}),
    );
    let b = json!({"TableName": PACKAGES, "KeyConditionExpression": "#p = :p",
                   "ExpressionAttributeNames": {"#p": "name"},
                   "ExpressionAttributeValues": {":p": {"S": "a"}}});
    let got = call(&fake, "Query", &b).await;
    assert_eq!(
        got.json(),
        json!({"Items": [], "Count": 0, "ScannedCount": 0})
    );
}

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

// ---- transactions ----

fn transact_body(items: Vec<Value>, token: Option<&str>) -> Value {
    let mut b = json!({"TransactItems": items});
    if let Some(t) = token {
        b["ClientRequestToken"] = json!(t);
    }
    b
}

fn tput(name: &str) -> Value {
    json!({"Put": {"TableName": PACKAGES, "Item": pkg(name)}})
}

#[tokio::test]
async fn a_transaction_with_no_items_is_refused() {
    let got = call(
        &fake(),
        "TransactWriteItems",
        &transact_body(vec![], Some("t")),
    )
    .await;
    assert_refused(&got, VALIDATION, "TransactItems must hold 1 to 100 items");
}

#[tokio::test]
async fn a_transaction_of_more_than_a_hundred_items_is_refused() {
    let items = (0..101).map(|i| tput(&format!("p{i}"))).collect();
    let got = call(
        &fake(),
        "TransactWriteItems",
        &transact_body(items, Some("t")),
    )
    .await;
    assert_refused(&got, VALIDATION, "TransactItems must hold 1 to 100 items");
}

#[tokio::test]
async fn a_transaction_without_a_client_request_token_is_refused() {
    let fake = fake();
    let want = "ClientRequestToken is required: a retry of the transaction must not apply it twice";
    for token in [None, Some("")] {
        let got = call(
            &fake,
            "TransactWriteItems",
            &transact_body(vec![tput("a")], token),
        )
        .await;
        assert_refused(&got, VALIDATION, want);
    }
    assert!(fake.dump(PACKAGES).is_empty());
}

#[tokio::test]
async fn two_puts_to_one_item_in_a_transaction_are_refused_and_write_nothing() {
    let fake = fake();
    let got = call(
        &fake,
        "TransactWriteItems",
        &transact_body(vec![tput("a"), tput("a")], Some("t")),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "Transaction request cannot include multiple operations on one item",
    );
    assert!(fake.dump(PACKAGES).is_empty());
}
