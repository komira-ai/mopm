//! The fake's own behaviour over its HTTP surface: what it answers to a request it must refuse, and to a client that goes away mid-request.

use super::*;

const PKG: &str = "mopm-t-packages";
const VERSIONS: &str = "mopm-t-versions";

fn start() -> FakeDynamo {
    FakeDynamo::start(FakeConfig::registry("t"))
}

async fn raw(fake: &FakeDynamo, request: &str) -> String {
    let mut s = TcpStream::connect(fake.addr).await.unwrap();
    s.write_all(request.as_bytes()).await.unwrap();
    s.shutdown().await.unwrap();
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.unwrap();
    String::from_utf8(out).unwrap()
}

async fn call(fake: &FakeDynamo, op: &str, body: Value) -> (u16, Value) {
    let text = body.to_string();
    let reply = raw(fake, &format!("POST / HTTP/1.1\r\nHost: x\r\nX-Amz-Target: DynamoDB_20120810.{op}\r\nContent-Length: {}\r\n\r\n{text}", text.len())).await;
    let status = reply.split(' ').nth(1).unwrap().parse().unwrap();
    let json = reply.split_once("\r\n\r\n").unwrap().1;
    (status, serde_json::from_str(json).unwrap())
}

fn message(v: &Value) -> &str {
    v.get("message").or_else(|| v.get("Message")).and_then(Value::as_str).unwrap()
}

fn kind(v: &Value) -> &str {
    v["__type"].as_str().unwrap().rsplit('#').next().unwrap()
}

fn s(v: &str) -> Value {
    json!({"S": v})
}

async fn refused(fake: &FakeDynamo, op: &str, body: Value, want_kind: &str, want_message: &str) {
    let (status, v) = call(fake, op, body).await;
    assert_eq!(status, 400);
    assert_eq!(kind(&v), want_kind);
    assert_eq!(message(&v), want_message);
}

fn query_body(table: &str, names: Value, values: Value, kc: &str) -> Value {
    json!({"TableName": table, "KeyConditionExpression": kc, "ExpressionAttributeNames": names, "ExpressionAttributeValues": values})
}

#[tokio::test]
async fn a_client_that_closes_before_the_header_ends_is_dropped_unrecorded() {
    let fake = start();
    assert_eq!(raw(&fake, "POST / HTTP/1.1\r\nHost: x\r\n").await, "");
    assert!(fake.requests().is_empty());
    let (status, _) = call(&fake, "Scan", json!({"TableName": PKG})).await;
    assert_eq!(status, 200);
}

#[tokio::test]
async fn a_client_that_closes_before_the_body_ends_is_dropped_unrecorded() {
    let fake = start();
    assert_eq!(raw(&fake, "POST / HTTP/1.1\r\nContent-Length: 50\r\n\r\n{\"Table").await, "");
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn an_unsupported_operation_is_a_validation_exception_naming_it() {
    refused(&start(), "Frobnicate", json!({}), "ValidationException", "fake: unsupported operation Frobnicate").await;
}

#[tokio::test]
async fn an_expression_attribute_value_no_expression_uses_is_refused() {
    let body = json!({"TableName": PKG, "Item": {"name": s("a")}, "ConditionExpression": "attribute_not_exists(#a)", "ExpressionAttributeNames": {"#a": "name"}, "ExpressionAttributeValues": {":v": s("x")}});
    refused(&start(), "PutItem", body, "ValidationException", "Value provided in ExpressionAttributeValues unused in expressions: keys: {:v}").await;
}

#[tokio::test]
async fn an_expression_attribute_name_no_expression_uses_is_refused() {
    let body = json!({"TableName": PKG, "Item": {"name": s("a")}, "ExpressionAttributeNames": {"#a": "name"}});
    refused(&start(), "PutItem", body, "ValidationException", "Value provided in ExpressionAttributeNames unused in expressions: keys: {#a}").await;
}

#[tokio::test]
async fn an_expression_attribute_name_used_but_not_defined_is_refused() {
    let body = json!({"TableName": PKG, "Item": {"name": s("a")}, "ConditionExpression": "attribute_not_exists(#a_b)"});
    refused(&start(), "PutItem", body, "ValidationException", "An expression attribute name used in the document path is not defined; attribute name: #a_b").await;
}

#[tokio::test]
async fn an_expression_attribute_value_used_but_not_defined_is_refused() {
    let body = json!({"TableName": PKG, "Item": {"name": s("a")}, "ConditionExpression": "#a = :v", "ExpressionAttributeNames": {"#a": "name"}});
    refused(&start(), "PutItem", body, "ValidationException", "An expression attribute value used in expression is not defined; attribute value: :v").await;
}

#[tokio::test]
async fn a_query_on_an_index_the_grant_does_not_list_is_access_denied() {
    let grants = Grants::parse(r#"{"packages": {"actions": ["dynamodb:Query"], "indexes": []}}"#).unwrap();
    let fake = FakeDynamo::start(FakeConfig::registry("t").with_grants("mopm-t-", grants));
    let mut body = query_body(PKG, json!({"#p": "search_bucket"}), json!({":p": s("b")}), "#p = :p");
    body["IndexName"] = json!("by_search_bucket");
    refused(&fake, "Query", body, "AccessDeniedException", "User is not authorized to perform: dynamodb:Query on index by_search_bucket on resource: mopm-t-packages").await;
}

#[tokio::test]
async fn a_call_on_a_table_the_grants_do_not_list_is_access_denied() {
    let grants = Grants::parse(r#"{"packages": {"actions": ["dynamodb:GetItem"], "indexes": []}}"#).unwrap();
    let fake = FakeDynamo::start(FakeConfig::registry("t").with_grants("mopm-t-", grants));
    refused(
        &fake,
        "GetItem",
        json!({"TableName": VERSIONS, "Key": {"name": s("a"), "version": s("1")}}),
        "AccessDeniedException",
        "User is not authorized to perform: dynamodb:GetItem on resource: mopm-t-versions",
    )
    .await;
    refused(
        &fake,
        "DeleteItem",
        json!({"TableName": PKG, "Key": {"name": s("a")}}),
        "AccessDeniedException",
        "User is not authorized to perform: dynamodb:DeleteItem on resource: mopm-t-packages",
    )
    .await;
}

#[tokio::test]
async fn a_query_limit_that_is_not_a_positive_integer_is_refused() {
    let fake = start();
    for limit in [json!(0), json!("2"), json!(-1)] {
        let mut body = query_body(PKG, json!({"#p": "name"}), json!({":p": s("a")}), "#p = :p");
        body["Limit"] = limit;
        refused(&fake, "Query", body, "ValidationException", "Limit must be a positive integer").await;
    }
}

#[tokio::test]
async fn a_query_key_condition_on_the_wrong_partition_attribute_is_refused() {
    let body = query_body(PKG, json!({"#p": "other"}), json!({":p": s("a")}), "#p = :p");
    refused(&start(), "Query", body, "ValidationException", "Query condition missed key schema element: name").await;
}

#[tokio::test]
async fn a_query_begins_with_on_a_non_sort_attribute_is_refused() {
    let body = query_body(VERSIONS, json!({"#p": "name", "#s": "zzz"}), json!({":p": s("a"), ":v": s("1")}), "#p = :p AND begins_with(#s, :v)");
    refused(&start(), "Query", body, "ValidationException", "begins_with must be on the sort key Some(\"version\")").await;
}

#[tokio::test]
async fn a_query_begins_with_without_a_second_operand_is_unsupported() {
    let body = query_body(VERSIONS, json!({"#p": "name", "#s": "version"}), json!({":p": s("a")}), "#p = :p AND begins_with(#s)");
    refused(&start(), "Query", body, "ValidationException", "fake: unsupported key condition begins_with(#s)").await;
}

#[tokio::test]
async fn a_query_sort_equality_on_a_non_sort_attribute_is_refused() {
    let body = query_body(VERSIONS, json!({"#p": "name", "#s": "zzz"}), json!({":p": s("a"), ":v": s("1")}), "#p = :p AND #s = :v");
    refused(&start(), "Query", body, "ValidationException", "Query condition missed key schema element: Some(\"version\")").await;
}

#[tokio::test]
async fn a_query_sort_condition_other_than_begins_with_or_equals_is_unsupported() {
    let body = query_body(VERSIONS, json!({"#p": "name", "#s": "version"}), json!({":p": s("a"), ":v": s("1")}), "#p = :p AND #s > :v");
    refused(&start(), "Query", body, "ValidationException", "fake: unsupported key condition #s > :v").await;
}

#[tokio::test]
async fn a_query_page_of_zero_items_carries_no_last_evaluated_key() {
    let fake = FakeDynamo::start(FakeConfig { page_size: 0, ..FakeConfig::registry("t") });
    fake.seed(PKG, json!({"name": s("a")}));
    let (status, v) = call(&fake, "Query", query_body(PKG, json!({"#p": "name"}), json!({":p": s("a")}), "#p = :p")).await;
    assert_eq!(status, 200);
    assert_eq!(v, json!({"Items": [], "Count": 0, "ScannedCount": 0}));
}

#[tokio::test]
async fn a_scan_with_a_projection_returns_only_the_named_attributes() {
    let fake = start();
    fake.seed(PKG, json!({"name": s("a"), "state": s("x")}));
    let (status, v) = call(&fake, "Scan", json!({"TableName": PKG, "ProjectionExpression": "#n", "ExpressionAttributeNames": {"#n": "name"}})).await;
    assert_eq!(status, 200);
    assert_eq!(v["Items"], json!([{"name": s("a")}]));
}

#[tokio::test]
async fn a_transaction_with_no_items_or_too_many_is_refused() {
    let fake = start();
    refused(&fake, "TransactWriteItems", json!({"TransactItems": [], "ClientRequestToken": "t"}), "ValidationException", "TransactItems must hold 1 to 100 items").await;
    let many: Vec<Value> = (0..101).map(|i| json!({"Put": {"TableName": PKG, "Item": {"name": s(&i.to_string())}}})).collect();
    refused(&fake, "TransactWriteItems", json!({"TransactItems": many, "ClientRequestToken": "t"}), "ValidationException", "TransactItems must hold 1 to 100 items").await;
}

#[tokio::test]
async fn a_transaction_without_a_client_request_token_is_refused() {
    let one = json!({"Put": {"TableName": PKG, "Item": {"name": s("a")}}});
    let msg = "ClientRequestToken is required: a retry of the transaction must not apply it twice";
    refused(&start(), "TransactWriteItems", json!({"TransactItems": [one.clone()]}), "ValidationException", msg).await;
    refused(&start(), "TransactWriteItems", json!({"TransactItems": [one], "ClientRequestToken": ""}), "ValidationException", msg).await;
}

#[tokio::test]
async fn a_transaction_with_two_puts_to_one_item_is_refused_and_writes_nothing() {
    let fake = start();
    let put = json!({"Put": {"TableName": PKG, "Item": {"name": s("a")}}});
    refused(
        &fake,
        "TransactWriteItems",
        json!({"TransactItems": [put.clone(), put], "ClientRequestToken": "t"}),
        "ValidationException",
        "Transaction request cannot include multiple operations on one item",
    )
    .await;
    assert!(fake.dump(PKG).is_empty());
}

#[tokio::test]
async fn a_body_that_arrives_after_its_header_is_still_read_whole() {
    let fake = start();
    let body = json!({"TableName": PKG}).to_string();
    let mut s = TcpStream::connect(fake.addr).await.unwrap();
    s.write_all(format!("POST / HTTP/1.1\r\nX-Amz-Target: DynamoDB_20120810.Scan\r\nContent-Length: {}\r\n\r\n", body.len()).as_bytes()).await.unwrap();
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
    s.write_all(body.as_bytes()).await.unwrap();
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.unwrap();
    assert!(String::from_utf8(out).unwrap().starts_with("HTTP/1.1 200 OK\r\n"));
    assert_eq!(fake.requests()[0].body, json!({"TableName": PKG}));
}

#[tokio::test]
async fn a_request_counts_as_signed_only_with_an_aws4_authorization_naming_signed_headers() {
    let fake = start();
    for (authorization, signed) in [("AWS4-HMAC-SHA256 Credential=x, SignedHeaders=host, Signature=y", true), ("AWS4-HMAC-SHA256 Credential=x", false), ("Basic x", false)] {
        raw(&fake, &format!("POST / HTTP/1.1\r\nX-Amz-Target: DynamoDB_20120810.Scan\r\nAuthorization: {authorization}\r\nContent-Length: 0\r\n\r\n")).await;
        assert_eq!(fake.requests().last().unwrap().signed, signed, "{authorization}");
    }
}

const TOKENS: &str = "mopm-t-tokens";
const VALIDATION: &str = "ValidationException";
const CONDITION: &str = "ConditionalCheckFailedException";

async fn ok(fake: &FakeDynamo, op: &str, body: Value) -> Value {
    let (status, v) = call(fake, op, body).await;
    assert_eq!(status, 200, "{v}");
    v
}

fn put_body(table: &str, item: Value, condition: Option<(&str, Value, Value)>) -> Value {
    let mut b = json!({"TableName": table, "Item": item});
    if let Some((c, names, values)) = condition {
        b["ConditionExpression"] = json!(c);
        if !names.is_null() {
            b["ExpressionAttributeNames"] = names;
        }
        if !values.is_null() {
            b["ExpressionAttributeValues"] = values;
        }
    }
    b
}

#[tokio::test]
async fn an_item_put_is_read_back_by_key_and_a_missing_key_reads_as_empty() {
    let fake = start();
    ok(&fake, "PutItem", put_body(PKG, json!({"name": s("a"), "state": s("x")}), None)).await;
    assert_eq!(ok(&fake, "GetItem", json!({"TableName": PKG, "Key": {"name": s("a")}})).await, json!({"Item": {"name": s("a"), "state": s("x")}}));
    assert_eq!(ok(&fake, "GetItem", json!({"TableName": PKG, "Key": {"name": s("zz")}})).await, json!({}));
    assert_eq!(fake.dump(PKG), vec![json!({"name": s("a"), "state": s("x")})]);
}

#[tokio::test]
async fn a_delete_removes_the_item_and_a_failed_condition_leaves_it() {
    let fake = start();
    fake.seed(PKG, json!({"name": s("a"), "state": s("x")}));
    let names = json!({"#s": "state"});
    let wrong = json!({":v": s("y")});
    let (status, v) = call(
        &fake,
        "DeleteItem",
        json!({"TableName": PKG, "Key": {"name": s("a")}, "ConditionExpression": "#s = :v", "ExpressionAttributeNames": names, "ExpressionAttributeValues": wrong}),
    )
    .await;
    assert_eq!((status, kind(&v), message(&v)), (400, CONDITION, "The conditional request failed"));
    assert_eq!(fake.dump(PKG).len(), 1);
    let right = json!({":v": s("x")});
    ok(
        &fake,
        "DeleteItem",
        json!({"TableName": PKG, "Key": {"name": s("a")}, "ConditionExpression": "#s = :v", "ExpressionAttributeNames": names, "ExpressionAttributeValues": right}),
    )
    .await;
    assert!(fake.dump(PKG).is_empty());
}

#[tokio::test]
async fn put_conditions_are_evaluated_clause_by_clause_and_unknown_forms_are_refused() {
    let fake = start();
    fake.seed(PKG, json!({"name": s("a"), "state": s("x")}));
    let item = json!({"name": s("a"), "state": s("z")});
    let names = json!({"#n": "name", "#s": "state"});
    let put = |cond: &str, values: Value| put_body(PKG, item.clone(), Some((cond, names.clone(), values)));
    let (_, v) = call(&fake, "PutItem", put_body(PKG, item.clone(), Some(("attribute_not_exists(#n)", json!({"#n": "name"}), Value::Null)))).await;
    assert_eq!(kind(&v), CONDITION);
    let (_, v) = call(&fake, "PutItem", put("attribute_exists(#n) AND #s = :v", json!({":v": s("other")}))).await;
    assert_eq!(kind(&v), CONDITION);
    ok(&fake, "PutItem", put("attribute_exists(#n) AND #s = :v", json!({":v": s("x")}))).await;
    assert_eq!(fake.dump(PKG), vec![item.clone()]);
    refused(
        &fake,
        "PutItem",
        put_body(PKG, item.clone(), Some(("contains(#n, :v)", json!({"#n": "name"}), json!({":v": s("x")})))),
        VALIDATION,
        "fake: unsupported condition contains(#n, :v)",
    )
    .await;
    refused(
        &fake,
        "PutItem",
        put_body(PKG, item.clone(), Some(("attribute_exists(name)", Value::Null, Value::Null))),
        VALIDATION,
        "Attribute name is a reserved keyword or not a placeholder: name",
    )
    .await;
    refused(&fake, "PutItem", put_body(PKG, item.clone(), Some(("attribute_exists(#a.b)", json!({"#a": "name"}), Value::Null))), VALIDATION, "undefined name #a.b").await;
    refused(&fake, "PutItem", put_body(PKG, item, Some(("#n = :v.x", json!({"#n": "name"}), json!({":v": s("x")})))), VALIDATION, "undefined value :v.x").await;
}

#[tokio::test]
async fn a_condition_on_a_missing_item_sees_no_attributes() {
    let fake = start();
    let names = json!({"#n": "name"});
    let (_, v) = call(&fake, "PutItem", put_body(PKG, json!({"name": s("a")}), Some(("attribute_exists(#n)", names.clone(), Value::Null)))).await;
    assert_eq!(kind(&v), CONDITION);
    ok(&fake, "PutItem", put_body(PKG, json!({"name": s("a")}), Some(("attribute_not_exists(#n)", names, Value::Null)))).await;
    assert_eq!(fake.dump(PKG).len(), 1);
}

fn update(expr: &str, names: Value, values: Value) -> Value {
    let mut b = json!({"TableName": PKG, "Key": {"name": s("a")}, "UpdateExpression": expr, "ExpressionAttributeNames": names});
    if !values.is_null() {
        b["ExpressionAttributeValues"] = values;
    }
    b
}

#[tokio::test]
async fn an_update_creates_the_item_from_its_key_sets_and_removes_attributes() {
    let fake = start();
    ok(&fake, "UpdateItem", update("SET #s = :v, #d = :w", json!({"#s": "state", "#d": "description"}), json!({":v": s("x"), ":w": s("d")}))).await;
    assert_eq!(fake.dump(PKG), vec![json!({"name": s("a"), "state": s("x"), "description": s("d")})]);
    ok(&fake, "UpdateItem", update("SET #s = :v REMOVE #d", json!({"#s": "state", "#d": "description"}), json!({":v": s("y")}))).await;
    assert_eq!(fake.dump(PKG), vec![json!({"name": s("a"), "state": s("y")})]);
}

#[tokio::test]
async fn an_update_whose_condition_fails_changes_nothing() {
    let fake = start();
    let mut body = update("SET #s = :v", json!({"#s": "state", "#n": "name"}), json!({":v": s("x")}));
    body["ConditionExpression"] = json!("attribute_exists(#n)");
    let (_, v) = call(&fake, "UpdateItem", body).await;
    assert_eq!(kind(&v), CONDITION);
    assert!(fake.dump(PKG).is_empty());
}

#[tokio::test]
async fn update_forms_the_fake_does_not_know_are_refused() {
    let fake = start();
    refused(&fake, "UpdateItem", update("ADD #a :v", json!({"#a": "state"}), json!({":v": s("x")})), VALIDATION, "fake: unsupported update ADD #a :v").await;
    refused(&fake, "UpdateItem", update("SET #a", json!({"#a": "state"}), Value::Null), VALIDATION, "fake: unsupported update #a").await;
    let mut no_update = json!({"TableName": PKG, "Key": {"name": s("a")}});
    refused(&fake, "UpdateItem", no_update.clone(), VALIDATION, "UpdateExpression is required").await;
    no_update["Key"] = json!({"name": {"N": "1"}});
    refused(&fake, "UpdateItem", no_update, VALIDATION, "One or more parameter values were invalid: Type mismatch for key name expected: S").await;
}

#[tokio::test]
async fn an_update_that_breaks_a_key_or_ttl_type_is_refused_and_writes_nothing() {
    let fake = start();
    let body = json!({"TableName": TOKENS, "Key": {"token_hash": s("t")}, "UpdateExpression": "SET #e = :v", "ExpressionAttributeNames": {"#e": "expires_at"}, "ExpressionAttributeValues": {":v": s("soon")}});
    refused(&fake, "UpdateItem", body, VALIDATION, "TimeToLive attribute expires_at must be a number").await;
    assert!(fake.dump(TOKENS).is_empty());
}

#[tokio::test]
async fn a_written_item_must_have_string_keys_a_numeric_ttl_and_string_index_keys() {
    let fake = start();
    let mismatch = |k: &str| format!("One or more parameter values were invalid: Type mismatch for key {k} expected: S");
    refused(&fake, "PutItem", put_body(PKG, json!({"name": {"N": "1"}}), None), VALIDATION, &mismatch("name")).await;
    refused(&fake, "PutItem", put_body(VERSIONS, json!({"name": s("a")}), None), VALIDATION, &mismatch("version")).await;
    refused(
        &fake,
        "PutItem",
        put_body(PKG, json!({"name": s("a"), "search_bucket": {"N": "1"}}), None),
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for Index Key search_bucket Expected: S",
    )
    .await;
    refused(&fake, "PutItem", put_body(TOKENS, json!({"token_hash": s("t"), "expires_at": s("x")}), None), VALIDATION, "TimeToLive attribute expires_at must be a number").await;
    ok(&fake, "PutItem", put_body(TOKENS, json!({"token_hash": s("t"), "expires_at": {"N": "5"}}), None)).await;
    assert_eq!(fake.dump(TOKENS).len(), 1);
}

#[tokio::test]
async fn a_request_missing_its_table_key_or_item_or_naming_an_unknown_table_is_refused() {
    let fake = start();
    refused(&fake, "GetItem", json!({}), VALIDATION, "TableName is required").await;
    refused(&fake, "GetItem", json!({"TableName": "nope", "Key": {}}), VALIDATION, "Requested resource not found: table nope").await;
    refused(&fake, "GetItem", json!({"TableName": PKG}), VALIDATION, "Key is required").await;
    refused(&fake, "PutItem", json!({"TableName": PKG}), VALIDATION, "Item is required").await;
    refused(
        &fake,
        "GetItem",
        json!({"TableName": VERSIONS, "Key": {"name": s("a")}}),
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for key version expected: S",
    )
    .await;
}

fn seed_packages(fake: &FakeDynamo) {
    for n in ["c", "a", "b"] {
        fake.seed(PKG, json!({"name": s(n), "search_bucket": s("bk"), "description": s("d"), "secret": s("x")}));
    }
}

fn index_query(extra: Value) -> Value {
    let mut b = query_body(PKG, json!({"#p": "search_bucket"}), json!({":p": s("bk")}), "#p = :p");
    b["IndexName"] = json!("by_search_bucket");
    for (k, v) in extra.as_object().unwrap() {
        b[k] = v.clone();
    }
    b
}

#[tokio::test]
async fn an_index_query_is_ordered_by_sort_key_projected_and_paged_with_a_last_evaluated_key() {
    let fake = start();
    seed_packages(&fake);
    let keep = |n: &str| json!({"name": s(n), "search_bucket": s("bk"), "description": s("d")});
    let first = ok(&fake, "Query", index_query(json!({}))).await;
    assert_eq!(first, json!({"Items": [keep("a"), keep("b")], "Count": 2, "ScannedCount": 2, "LastEvaluatedKey": {"search_bucket": s("bk"), "name": s("b")}}));
    let second = ok(&fake, "Query", index_query(json!({"ExclusiveStartKey": first["LastEvaluatedKey"]}))).await;
    assert_eq!(second, json!({"Items": [keep("c")], "Count": 1, "ScannedCount": 1}));
    let limited = ok(&fake, "Query", index_query(json!({"Limit": 1}))).await;
    assert_eq!(limited["Items"], json!([keep("a")]));
    assert_eq!(limited["LastEvaluatedKey"], json!({"search_bucket": s("bk"), "name": s("a")}));
}

#[tokio::test]
async fn an_index_query_refuses_consistent_reads_an_unknown_index_and_a_start_key_outside_the_partition() {
    let fake = start();
    refused(&fake, "Query", index_query(json!({"ConsistentRead": true})), VALIDATION, "Consistent reads are not supported on global secondary indexes").await;
    refused(&fake, "Query", index_query(json!({"IndexName": "nope"})), VALIDATION, "The table does not have the specified index: nope").await;
    refused(
        &fake,
        "Query",
        index_query(json!({"ExclusiveStartKey": {"search_bucket": s("other"), "name": s("a")}})),
        VALIDATION,
        "The provided starting key is outside query boundaries based on provided conditions",
    )
    .await;
}

#[tokio::test]
async fn a_table_query_filters_by_sort_prefix_or_equality_and_checks_its_start_key_against_the_prefix() {
    let fake = start();
    for v in ["1", "2", "10"] {
        fake.seed(VERSIONS, json!({"name": s("a"), "version": s(v)}));
    }
    fake.seed(VERSIONS, json!({"name": s("b"), "version": s("1")}));
    let names = json!({"#p": "name", "#s": "version"});
    let q = |kc: &str, v: &str| query_body(VERSIONS, names.clone(), json!({":p": s("a"), ":v": s(v)}), kc);
    let versions = |r: &Value| r["Items"].as_array().unwrap().iter().map(|i| i["version"]["S"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(versions(&ok(&fake, "Query", q("#p = :p AND begins_with(#s, :v)", "1")).await), ["1", "10"]);
    assert_eq!(versions(&ok(&fake, "Query", q("#p = :p AND #s = :v", "2")).await), ["2"]);
    let mut all = query_body(VERSIONS, json!({"#p": "name"}), json!({":p": s("a")}), "#p = :p");
    let page = ok(&fake, "Query", all.clone()).await;
    assert_eq!(versions(&page), ["1", "10"]);
    assert_eq!(page["LastEvaluatedKey"], json!({"name": s("a"), "version": s("10")}));
    all["ExclusiveStartKey"] = page["LastEvaluatedKey"].clone();
    assert_eq!(versions(&ok(&fake, "Query", all).await), ["2"]);
    let mut outside = q("#p = :p AND begins_with(#s, :v)", "1");
    outside["ExclusiveStartKey"] = json!({"name": s("a"), "version": s("2")});
    refused(&fake, "Query", outside, VALIDATION, "The provided starting key is outside query boundaries based on provided conditions").await;
    refused(&fake, "Query", q("#p = :p AND begins_with(#s, :v)", ""), VALIDATION, "One or more parameter values are not valid: an empty or non-string begins_with operand").await;
}

#[tokio::test]
async fn a_query_without_an_equality_key_condition_is_unsupported() {
    let body = query_body(PKG, json!({"#p": "name"}), json!({}), "#p");
    refused(&start(), "Query", body, VALIDATION, "fake: unsupported key condition #p").await;
}

#[tokio::test]
async fn a_scan_pages_by_table_key_and_resumes_after_the_start_key() {
    let fake = start();
    seed_packages(&fake);
    let first = ok(&fake, "Scan", json!({"TableName": PKG})).await;
    assert_eq!(first["Count"], 2);
    assert_eq!(first["LastEvaluatedKey"], json!({"name": s("b")}));
    let second = ok(&fake, "Scan", json!({"TableName": PKG, "ExclusiveStartKey": first["LastEvaluatedKey"]})).await;
    assert_eq!(second["Items"].as_array().unwrap().len(), 1);
    assert!(second.get("LastEvaluatedKey").is_none());
    let unknown_start = ok(&fake, "Scan", json!({"TableName": PKG, "ExclusiveStartKey": {"name": s("zz")}})).await;
    assert_eq!(unknown_start["Count"], 2);
}

#[tokio::test]
async fn a_scan_projection_names_must_be_placeholders() {
    let fake = start();
    refused(&fake, "Scan", json!({"TableName": PKG, "ProjectionExpression": "name"}), VALIDATION, "Attribute name is a reserved keyword or not a placeholder: name").await;
}

fn transact_put(name: &str, condition: bool) -> Value {
    let mut put = json!({"TableName": PKG, "Item": {"name": s(name)}});
    if condition {
        put["ConditionExpression"] = json!("attribute_not_exists(#n)");
        put["ExpressionAttributeNames"] = json!({"#n": "name"});
    }
    json!({"Put": put})
}

#[tokio::test]
async fn a_transaction_writes_all_its_puts_or_none() {
    let fake = start();
    fake.seed(PKG, json!({"name": s("taken")}));
    ok(&fake, "TransactWriteItems", json!({"TransactItems": [transact_put("a", true), transact_put("b", false)], "ClientRequestToken": "t1"})).await;
    assert_eq!(fake.dump(PKG).len(), 3);
    let (status, v) = call(&fake, "TransactWriteItems", json!({"TransactItems": [transact_put("c", true), transact_put("taken", true)], "ClientRequestToken": "t2"})).await;
    assert_eq!(status, 400);
    assert_eq!(kind(&v), "TransactionCanceledException");
    assert_eq!(message(&v), "Transaction cancelled, please refer cancellation reasons for specific reasons [None, ConditionalCheckFailed]");
    assert_eq!(v["CancellationReasons"], json!([{"Code": "None"}, {"Code": "ConditionalCheckFailed", "Message": "The conditional request failed"}]));
    assert_eq!(fake.dump(PKG).len(), 3);
}

#[tokio::test]
async fn a_transaction_item_other_than_a_put_or_a_missing_list_is_refused() {
    let fake = start();
    refused(&fake, "TransactWriteItems", json!({"TransactItems": [{"Delete": {}}], "ClientRequestToken": "t"}), VALIDATION, "fake: a transaction item other than Put").await;
    refused(&fake, "TransactWriteItems", json!({"ClientRequestToken": "t"}), VALIDATION, "TransactItems is required").await;
}

#[tokio::test]
async fn grants_allow_exactly_the_listed_actions_and_indexes_and_malformed_text_is_an_error() {
    assert!(Grants::parse("not json").is_err());
    assert!(Grants::parse("[]").unwrap().0.is_empty());
    let grants = Grants::parse(r#"{"packages": {"actions": ["dynamodb:Query", "dynamodb:PutItem"], "indexes": ["by_search_bucket"]}}"#).unwrap();
    let fake = FakeDynamo::start(FakeConfig::registry("t").with_grants("mopm-t-", grants));
    ok(&fake, "Query", index_query(json!({}))).await;
    refused(&fake, "Scan", json!({"TableName": PKG}), "AccessDeniedException", "User is not authorized to perform: dynamodb:Scan on resource: mopm-t-packages").await;
}

#[tokio::test]
async fn requests_are_recorded_in_order_and_can_be_cleared() {
    let fake = start();
    assert!(fake.endpoint().starts_with("http://127.0.0.1:"));
    ok(&fake, "Scan", json!({"TableName": PKG})).await;
    call(&fake, "Frobnicate", json!({})).await;
    assert_eq!(fake.operations(), ["Scan", "Frobnicate"]);
    assert_eq!(fake.requests()[0].body, json!({"TableName": PKG}));
    fake.clear_requests();
    assert!(fake.operations().is_empty());
}

#[tokio::test]
async fn an_index_over_a_table_with_a_sort_key_orders_by_index_sort_then_table_key() {
    let fake = start();
    let owners = "mopm-t-owners";
    for (n, g) in [("b", "9"), ("a", "9"), ("a", "1")] {
        fake.seed(owners, json!({"name": s(n), "github_id": s(g)}));
    }
    let mut body = query_body(owners, json!({"#p": "github_id"}), json!({":p": s("9")}), "#p = :p");
    body["IndexName"] = json!("by_github_id");
    let r = ok(&fake, "Query", body).await;
    assert_eq!(r["Items"], json!([{"name": s("a"), "github_id": s("9")}, {"name": s("b"), "github_id": s("9")}]));
}
