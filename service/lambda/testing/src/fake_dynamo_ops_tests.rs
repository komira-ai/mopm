//! What the registry's adapters get from the fake DynamoDB's operations: the items stored, returned and
//! removed, the conditional-check and transaction answers, the key and index checks, the paging keys of Query
//! and Scan, and the grants that let a call through.

use serde_json::{json, Value};

use super::more_tests::{
    assert_refused, call, fake, fake_with_grants, pkg, put, put_cond, tput, transact_body, DENIED,
    PACKAGES, VALIDATION, VERSIONS,
};
use super::*;

const OWNERS: &str = "mopm-t-owners";
const TOKENS: &str = "mopm-t-tokens";
const CONDITION_FAILED: &str = "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException";
const CANCELLED: &str = "com.amazonaws.dynamodb.v20120810#TransactionCanceledException";

fn ver(name: &str, version: &str) -> Value {
    json!({"name": {"S": name}, "version": {"S": version}})
}

fn s(v: &str) -> Value {
    json!({"S": v})
}

fn names(pairs: &[(&str, &str)]) -> Value {
    Value::Object(
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), json!(v)))
            .collect(),
    )
}

fn values(pairs: &[(&str, &str)]) -> Value {
    Value::Object(pairs.iter().map(|(k, v)| (k.to_string(), s(v))).collect())
}

fn vquery(kc: &str, n: &[(&str, &str)], v: &[(&str, &str)]) -> Value {
    super::more_tests::query_with(kc, names(n), values(v))
}

async fn seed_versions(fake: &FakeDynamo) {
    for (n, v) in [("a", "1"), ("a", "2"), ("a", "3"), ("b", "1")] {
        put(fake, VERSIONS, ver(n, v)).await;
    }
}

const NAME_AND_VERSION: &[(&str, &str)] = &[("#p", "name"), ("#s", "version")];

// ---- GetItem, PutItem, DeleteItem ----

#[tokio::test]
async fn a_stored_item_is_returned_whole_and_a_missing_one_as_an_empty_answer() {
    let fake = fake();
    let item = json!({"name": s("a"), "state": s("live")});
    put(&fake, PACKAGES, item.clone()).await;
    let hit = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_eq!((hit.status, hit.json()), (200, json!({"Item": item})));
    let miss = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("b")}),
    )
    .await;
    assert_eq!((miss.status, miss.json()), (200, json!({})));
}

#[tokio::test]
async fn clearing_the_requests_forgets_them_and_keeps_the_items() {
    let fake = fake();
    put(&fake, PACKAGES, pkg("a")).await;
    assert_eq!(fake.operations(), vec!["PutItem"]);
    fake.clear_requests();
    assert!(fake.requests().is_empty());
    assert_eq!(fake.dump(PACKAGES), vec![pkg("a")]);
}

#[tokio::test]
async fn a_put_replaces_the_item_with_the_same_key() {
    let fake = fake();
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("old")})).await;
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("new")})).await;
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("new")})]
    );
}

#[tokio::test]
async fn a_request_without_a_table_name_or_an_item_is_refused_by_what_is_missing() {
    let fake = fake();
    let got = call(&fake, "PutItem", &json!({"Item": pkg("a")})).await;
    assert_refused(&got, VALIDATION, "TableName is required");
    let got = call(&fake, "PutItem", &json!({"TableName": PACKAGES})).await;
    assert_refused(&got, VALIDATION, "Item is required");
    let got = call(&fake, "GetItem", &json!({"TableName": PACKAGES})).await;
    assert_refused(&got, VALIDATION, "Key is required");
}

#[tokio::test]
async fn a_table_the_fake_does_not_have_is_refused_by_name() {
    let got = call(
        &fake(),
        "GetItem",
        &json!({"TableName": "nope", "Key": pkg("a")}),
    )
    .await;
    assert_refused(&got, VALIDATION, "Requested resource not found: table nope");
}

#[tokio::test]
async fn a_key_that_is_not_a_string_is_refused_for_the_partition_and_for_the_sort_key() {
    let fake = fake();
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": {"name": {"N": "1"}}}),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for key name expected: S",
    );
    let got = call(
        &fake,
        "GetItem",
        &json!({"TableName": VERSIONS, "Key": {"name": s("a")}}),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for key version expected: S",
    );
}

#[tokio::test]
async fn an_index_key_that_is_not_a_string_is_refused_and_nothing_is_stored() {
    let fake = fake();
    let got = call(
        &fake,
        "PutItem",
        &json!({"TableName": PACKAGES, "Item": {"name": s("a"), "search_bucket": {"N": "1"}}}),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for Index Key search_bucket Expected: S",
    );
    assert!(fake.dump(PACKAGES).is_empty());
}

#[tokio::test]
async fn a_ttl_attribute_must_be_a_number_when_present_and_may_be_absent() {
    let fake = fake();
    let bad = json!({"token_hash": s("h"), "expires_at": s("soon")});
    let got = call(&fake, "PutItem", &json!({"TableName": TOKENS, "Item": bad})).await;
    assert_refused(
        &got,
        VALIDATION,
        "TimeToLive attribute expires_at must be a number",
    );
    let good = json!({"token_hash": s("h"), "expires_at": {"N": "9"}});
    put(&fake, TOKENS, good.clone()).await;
    let without = json!({"token_hash": s("g")});
    put(&fake, TOKENS, without.clone()).await;
    assert_eq!(fake.dump(TOKENS), vec![without, good]);
}

#[tokio::test]
async fn a_put_whose_condition_fails_answers_a_conditional_check_failure_and_keeps_the_old_item() {
    let fake = fake();
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("old")})).await;
    let body = json!({"TableName": PACKAGES, "Item": json!({"name": s("a"), "state": s("new")}),
                      "ConditionExpression": "attribute_not_exists(#n)",
                      "ExpressionAttributeNames": {"#n": "name"}});
    let got = call(&fake, "PutItem", &body).await;
    assert_refused(&got, CONDITION_FAILED, "The conditional request failed");
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("old")})]
    );
}

#[tokio::test]
async fn a_put_whose_condition_holds_is_stored() {
    let fake = fake();
    let body = put_cond(
        "attribute_not_exists(#n)",
        names(&[("#n", "name")]),
        json!({}),
    );
    let got = call(&fake, "PutItem", &body).await;
    assert_eq!((got.status, got.json()), (200, json!({})));
    assert_eq!(fake.dump(PACKAGES), vec![pkg("a")]);
}

#[tokio::test]
async fn a_condition_checks_existence_and_equality_of_attributes_joined_by_and() {
    let fake = fake();
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("live")})).await;
    let cond = "attribute_exists(#n) AND #st = :live";
    let n = names(&[("#n", "name"), ("#st", "state")]);
    let held = call(
        &fake,
        "PutItem",
        &put_cond(cond, n.clone(), values(&[(":live", "live")])),
    )
    .await;
    assert_eq!(held.status, 200);
    let broken = call(
        &fake,
        "PutItem",
        &put_cond(cond, n, values(&[(":live", "gone")])),
    )
    .await;
    assert_refused(&broken, CONDITION_FAILED, "The conditional request failed");
    let missing = call(
        &fake,
        "PutItem",
        &json!({"TableName": PACKAGES, "Item": pkg("zz"), "ConditionExpression": "attribute_exists(#n)",
                "ExpressionAttributeNames": {"#n": "name"}}),
    )
    .await;
    assert_refused(&missing, CONDITION_FAILED, "The conditional request failed");
}

#[tokio::test]
async fn an_equality_on_an_item_that_does_not_exist_fails_the_condition() {
    let got = call(
        &fake(),
        "PutItem",
        &put_cond("#n = :v", names(&[("#n", "name")]), values(&[(":v", "a")])),
    )
    .await;
    assert_refused(&got, CONDITION_FAILED, "The conditional request failed");
}

#[tokio::test]
async fn a_condition_form_the_fake_does_not_know_is_refused_naming_it() {
    let got = call(
        &fake(),
        "PutItem",
        &put_cond(
            "size(#n) > :v",
            names(&[("#n", "name")]),
            values(&[(":v", "1")]),
        ),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "fake: unsupported condition size(#n) > :v",
    );
}

#[tokio::test]
async fn a_raw_attribute_name_in_a_condition_is_refused_as_a_reserved_word() {
    let got = call(
        &fake(),
        "PutItem",
        &put_cond("name = :v", json!({}), values(&[(":v", "a")])),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "Attribute name is a reserved keyword or not a placeholder: name",
    );
}

#[tokio::test]
async fn an_attribute_name_placeholder_bound_to_a_non_string_is_refused_as_undefined() {
    let body = json!({"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "attribute_exists(#n)",
                      "ExpressionAttributeNames": {"#n": 5}});
    assert_refused(
        &call(&fake(), "PutItem", &body).await,
        VALIDATION,
        "undefined name #n",
    );
}

#[tokio::test]
async fn a_delete_removes_the_item_and_a_failed_condition_keeps_it() {
    let fake = fake();
    put(&fake, PACKAGES, pkg("a")).await;
    put(&fake, PACKAGES, pkg("b")).await;
    let guarded = json!({"TableName": PACKAGES, "Key": pkg("a"), "ConditionExpression": "attribute_not_exists(#n)",
                         "ExpressionAttributeNames": {"#n": "name"}});
    assert_refused(
        &call(&fake, "DeleteItem", &guarded).await,
        CONDITION_FAILED,
        "The conditional request failed",
    );
    assert_eq!(fake.dump(PACKAGES), vec![pkg("a"), pkg("b")]);
    let plain = call(
        &fake,
        "DeleteItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_eq!((plain.status, plain.json()), (200, json!({})));
    assert_eq!(fake.dump(PACKAGES), vec![pkg("b")]);
}

// ---- UpdateItem ----

fn update(key: Value, expr: &str, n: &[(&str, &str)], v: &[(&str, &str)]) -> Value {
    let mut b = json!({"TableName": PACKAGES, "Key": key, "UpdateExpression": expr});
    if !n.is_empty() {
        b["ExpressionAttributeNames"] = names(n);
    }
    if !v.is_empty() {
        b["ExpressionAttributeValues"] = values(v);
    }
    b
}

#[tokio::test]
async fn an_update_of_a_missing_item_creates_it_from_its_key_and_the_assignments() {
    let fake = fake();
    let body = update(
        pkg("a"),
        "SET #st = :v, #d = :w",
        &[("#st", "state"), ("#d", "description")],
        &[(":v", "live"), (":w", "text")],
    );
    let got = call(&fake, "UpdateItem", &body).await;
    assert_eq!((got.status, got.json()), (200, json!({})));
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("live"), "description": s("text")})]
    );
}

#[tokio::test]
async fn an_update_sets_some_attributes_and_removes_others_of_an_existing_item() {
    let fake = fake();
    put(
        &fake,
        PACKAGES,
        json!({"name": s("a"), "state": s("old"), "description": s("d"), "extra": s("x")}),
    )
    .await;
    let body = update(
        pkg("a"),
        "SET #st = :v REMOVE #d, #e",
        &[("#st", "state"), ("#d", "description"), ("#e", "extra")],
        &[(":v", "new")],
    );
    assert_eq!(call(&fake, "UpdateItem", &body).await.status, 200);
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("new")})]
    );
}

#[tokio::test]
async fn an_update_whose_condition_fails_changes_nothing() {
    let fake = fake();
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("old")})).await;
    let mut body = update(
        pkg("a"),
        "SET #st = :v",
        &[("#st", "state")],
        &[(":v", "new"), (":old", "other")],
    );
    body["ConditionExpression"] = json!("#st = :old");
    let got = call(&fake, "UpdateItem", &body).await;
    assert_refused(&got, CONDITION_FAILED, "The conditional request failed");
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("old")})]
    );
}

#[tokio::test]
async fn an_update_without_an_expression_is_refused() {
    let body = json!({"TableName": PACKAGES, "Key": pkg("a")});
    assert_refused(
        &call(&fake(), "UpdateItem", &body).await,
        VALIDATION,
        "UpdateExpression is required",
    );
}

#[tokio::test]
async fn an_update_other_than_set_with_remove_is_refused_naming_it() {
    let fake = fake();
    let body = update(pkg("a"), "ADD #n :v", &[("#n", "n")], &[(":v", "1")]);
    assert_refused(
        &call(&fake, "UpdateItem", &body).await,
        VALIDATION,
        "fake: unsupported update ADD #n :v",
    );
    let body = update(pkg("a"), "SET #n", &[("#n", "n")], &[]);
    assert_refused(
        &call(&fake, "UpdateItem", &body).await,
        VALIDATION,
        "fake: unsupported update #n",
    );
    assert!(fake.dump(PACKAGES).is_empty());
}

#[tokio::test]
async fn an_update_that_breaks_an_index_key_is_refused_and_leaves_the_item() {
    let fake = fake();
    put(&fake, PACKAGES, pkg("a")).await;
    let mut body = update(pkg("a"), "SET #b = :v", &[("#b", "search_bucket")], &[]);
    body["ExpressionAttributeValues"] = json!({":v": {"N": "1"}});
    assert_refused(
        &call(&fake, "UpdateItem", &body).await,
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for Index Key search_bucket Expected: S",
    );
    assert_eq!(fake.dump(PACKAGES), vec![pkg("a")]);
}

// ---- Query ----

#[tokio::test]
async fn a_query_by_partition_key_pages_by_the_page_size_and_resumes_after_the_key() {
    let fake = fake();
    seed_versions(&fake).await;
    let b = vquery("#p = :p", &[("#p", "name")], &[(":p", "a")]);
    let first = call(&fake, "Query", &b).await;
    assert_eq!(
        first.json(),
        json!({"Items": [ver("a", "1"), ver("a", "2")], "Count": 2, "ScannedCount": 2,
               "LastEvaluatedKey": ver("a", "2")})
    );
    let mut next = b.clone();
    next["ExclusiveStartKey"] = ver("a", "2");
    let second = call(&fake, "Query", &next).await;
    assert_eq!(
        second.json(),
        json!({"Items": [ver("a", "3")], "Count": 1, "ScannedCount": 1})
    );
}

#[tokio::test]
async fn a_query_limit_smaller_than_the_page_cuts_the_page_and_gives_a_resume_key() {
    let fake = fake();
    seed_versions(&fake).await;
    let mut b = vquery("#p = :p", &[("#p", "name")], &[(":p", "a")]);
    b["Limit"] = json!(1);
    let got = call(&fake, "Query", &b).await;
    assert_eq!(
        got.json(),
        json!({"Items": [ver("a", "1")], "Count": 1, "ScannedCount": 1, "LastEvaluatedKey": ver("a", "1")})
    );
    b["Limit"] = json!(100);
    let all = call(&fake, "Query", &b).await.json();
    assert_eq!(all["Count"], 2, "the page size still caps a larger limit");
}

#[tokio::test]
async fn a_resume_key_that_is_not_in_the_results_restarts_from_the_first_item() {
    let fake = fake();
    seed_versions(&fake).await;
    let mut b = vquery("#p = :p", &[("#p", "name")], &[(":p", "a")]);
    b["ExclusiveStartKey"] = ver("a", "0");
    let got = call(&fake, "Query", &b).await.json();
    assert_eq!(got["Items"], json!([ver("a", "1"), ver("a", "2")]));
}

#[tokio::test]
async fn a_sort_key_prefix_selects_the_items_starting_with_it() {
    let fake = fake();
    for v in ["1.0", "1.1", "2.0"] {
        put(&fake, VERSIONS, ver("a", v)).await;
    }
    let b = vquery(
        "#p = :p AND begins_with(#s, :v)",
        NAME_AND_VERSION,
        &[(":p", "a"), (":v", "1.")],
    );
    let got = call(&fake, "Query", &b).await.json();
    assert_eq!(got["Items"], json!([ver("a", "1.0"), ver("a", "1.1")]));
    assert!(got.get("LastEvaluatedKey").is_none());
}

#[tokio::test]
async fn a_sort_key_equality_selects_exactly_that_item() {
    let fake = fake();
    seed_versions(&fake).await;
    let b = vquery(
        "#p = :p AND #s = :v",
        NAME_AND_VERSION,
        &[(":p", "a"), (":v", "2")],
    );
    let got = call(&fake, "Query", &b).await.json();
    assert_eq!(got["Items"], json!([ver("a", "2")]));
}

#[tokio::test]
async fn a_begins_with_operand_that_is_empty_or_not_a_string_is_refused() {
    let want =
        "One or more parameter values are not valid: an empty or non-string begins_with operand";
    let kc = "#p = :p AND begins_with(#s, :v)";
    let empty = vquery(kc, NAME_AND_VERSION, &[(":p", "a"), (":v", "")]);
    assert_refused(&call(&fake(), "Query", &empty).await, VALIDATION, want);
    let mut number = vquery(kc, NAME_AND_VERSION, &[(":p", "a")]);
    number["ExpressionAttributeValues"][":v"] = json!({"N": "1"});
    assert_refused(&call(&fake(), "Query", &number).await, VALIDATION, want);
}

#[tokio::test]
async fn a_begins_with_without_two_operands_is_refused_naming_it() {
    let b = vquery(
        "#p = :p AND begins_with(#s)",
        NAME_AND_VERSION,
        &[(":p", "a")],
    );
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "fake: unsupported key condition begins_with(#s)",
    );
}

#[tokio::test]
async fn a_key_condition_without_an_equality_is_refused_naming_it() {
    let b = vquery("#p > :p", &[("#p", "name")], &[(":p", "a")]);
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "fake: unsupported key condition #p > :p",
    );
}

#[tokio::test]
async fn a_query_without_a_key_condition_is_refused() {
    let b = json!({"TableName": VERSIONS});
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "KeyConditionExpression is required",
    );
}

#[tokio::test]
async fn a_resume_key_outside_the_partition_or_the_prefix_is_refused() {
    let want = "The provided starting key is outside query boundaries based on provided conditions";
    let mut other = vquery("#p = :p", &[("#p", "name")], &[(":p", "a")]);
    other["ExclusiveStartKey"] = ver("b", "1");
    assert_refused(&call(&fake(), "Query", &other).await, VALIDATION, want);
    let mut prefixed = vquery(
        "#p = :p AND begins_with(#s, :v)",
        NAME_AND_VERSION,
        &[(":p", "a"), (":v", "1")],
    );
    prefixed["ExclusiveStartKey"] = ver("a", "2");
    assert_refused(&call(&fake(), "Query", &prefixed).await, VALIDATION, want);
}

#[tokio::test]
async fn a_resume_key_inside_an_equality_condition_is_accepted() {
    let fake = fake();
    seed_versions(&fake).await;
    let mut b = vquery(
        "#p = :p AND #s = :v",
        NAME_AND_VERSION,
        &[(":p", "a"), (":v", "2")],
    );
    b["ExclusiveStartKey"] = ver("a", "2");
    let got = call(&fake, "Query", &b).await;
    assert_eq!(got.status, 200);
}

#[tokio::test]
async fn an_index_query_returns_items_in_sort_key_order_with_only_the_projected_attributes() {
    let fake = fake();
    for n in ["c", "a", "b"] {
        put(
            &fake,
            PACKAGES,
            json!({"name": s(n), "search_bucket": s("x"), "description": s("d"), "state": s("live"),
                   "created_at": {"N": "1"}, "readme": s("big")}),
        )
        .await;
    }
    put(
        &fake,
        PACKAGES,
        json!({"name": s("z"), "search_bucket": s("y")}),
    )
    .await;
    put(&fake, PACKAGES, json!({"name": s("w")})).await;
    let mut b = json!({"TableName": PACKAGES, "IndexName": "by_search_bucket", "KeyConditionExpression": "#p = :p",
                       "ExpressionAttributeNames": {"#p": "search_bucket"}, "ExpressionAttributeValues": {":p": s("x")}});
    let row = |n: &str| json!({"name": s(n), "search_bucket": s("x"), "description": s("d"), "state": s("live"), "created_at": {"N": "1"}});
    let first = call(&fake, "Query", &b).await;
    assert_eq!(
        first.json(),
        json!({"Items": [row("a"), row("b")], "Count": 2, "ScannedCount": 2,
               "LastEvaluatedKey": {"name": s("b"), "search_bucket": s("x")}})
    );
    b["ExclusiveStartKey"] = json!({"name": s("b"), "search_bucket": s("x")});
    let second = call(&fake, "Query", &b).await;
    assert_eq!(
        second.json(),
        json!({"Items": [row("c")], "Count": 1, "ScannedCount": 1})
    );
}

#[tokio::test]
async fn an_index_that_projects_everything_returns_whole_items_ordered_by_sort_then_table_key() {
    let fake = fake();
    let owner = |n: &str, g: &str| json!({"name": s(n), "github_id": s(g), "role": s("owner")});
    fake.seed(OWNERS, owner("b", "1"));
    fake.seed(OWNERS, owner("a", "1"));
    fake.seed(OWNERS, owner("a", "0"));
    let b = json!({"TableName": OWNERS, "IndexName": "by_github_id", "KeyConditionExpression": "#p = :p",
                   "ExpressionAttributeNames": {"#p": "github_id"}, "ExpressionAttributeValues": {":p": s("1")}});
    let got = call(&fake, "Query", &b).await;
    assert_eq!(
        got.json(),
        json!({"Items": [owner("a", "1"), owner("b", "1")], "Count": 2, "ScannedCount": 2})
    );
}

#[tokio::test]
async fn an_index_that_the_table_lacks_or_a_consistent_read_of_one_is_refused() {
    let fake = fake();
    let mut b = json!({"TableName": PACKAGES, "IndexName": "nope", "KeyConditionExpression": "#p = :p",
                       "ExpressionAttributeNames": {"#p": "search_bucket"}, "ExpressionAttributeValues": {":p": s("x")}});
    assert_refused(
        &call(&fake, "Query", &b).await,
        VALIDATION,
        "The table does not have the specified index: nope",
    );
    b["IndexName"] = json!("by_search_bucket");
    b["ConsistentRead"] = json!(true);
    assert_refused(
        &call(&fake, "Query", &b).await,
        VALIDATION,
        "Consistent reads are not supported on global secondary indexes",
    );
    b["ConsistentRead"] = json!(false);
    assert_eq!(call(&fake, "Query", &b).await.status, 200);
}

#[tokio::test]
async fn a_query_on_a_key_other_than_the_partition_key_is_refused_naming_the_key() {
    let b = vquery("#p = :p", &[("#p", "version")], &[(":p", "a")]);
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "Query condition missed key schema element: name",
    );
}

#[tokio::test]
async fn a_sort_key_equality_on_another_attribute_is_refused_naming_the_sort_key() {
    let b = vquery(
        "#p = :p AND #s = :v",
        &[("#p", "name"), ("#s", "other")],
        &[(":p", "a"), (":v", "1")],
    );
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "Query condition missed key schema element: Some(\"version\")",
    );
}

#[tokio::test]
async fn a_begins_with_on_another_attribute_is_refused_naming_the_sort_key() {
    let b = vquery(
        "#p = :p AND begins_with(#s, :v)",
        &[("#p", "name"), ("#s", "other")],
        &[(":p", "a"), (":v", "1")],
    );
    assert_refused(
        &call(&fake(), "Query", &b).await,
        VALIDATION,
        "begins_with must be on the sort key Some(\"version\")",
    );
}

// ---- Scan ----

#[tokio::test]
async fn a_scan_pages_through_every_item_and_ends_without_a_resume_key() {
    let fake = fake();
    for n in ["a", "b", "c"] {
        put(&fake, PACKAGES, pkg(n)).await;
    }
    let mut b = json!({"TableName": PACKAGES, "ExclusiveStartKey": pkg("b")});
    let last = call(&fake, "Scan", &b).await;
    assert_eq!(
        last.json(),
        json!({"Items": [pkg("c")], "Count": 1, "ScannedCount": 1})
    );
    b["ExclusiveStartKey"] = pkg("nobody");
    let restarted = call(&fake, "Scan", &b).await.json();
    assert_eq!(restarted["Items"], json!([pkg("a"), pkg("b")]));
    b["ExclusiveStartKey"] = pkg("c");
    let beyond = call(&fake, "Scan", &b).await;
    assert_eq!(
        beyond.json(),
        json!({"Items": [], "Count": 0, "ScannedCount": 0})
    );
}

#[tokio::test]
async fn a_scan_of_a_table_with_a_sort_key_resumes_by_both_key_attributes() {
    let fake = fake();
    seed_versions(&fake).await;
    let first = call(&fake, "Scan", &json!({"TableName": VERSIONS}))
        .await
        .json();
    assert_eq!(first["LastEvaluatedKey"], ver("a", "2"));
    let second = call(
        &fake,
        "Scan",
        &json!({"TableName": VERSIONS, "ExclusiveStartKey": ver("a", "2")}),
    )
    .await
    .json();
    assert_eq!(second["Items"], json!([ver("a", "3"), ver("b", "1")]));
    assert!(second.get("LastEvaluatedKey").is_none());
}

#[tokio::test]
async fn a_scan_projection_keeps_only_the_named_attributes_and_still_pages_by_the_key() {
    let fake = fake();
    for n in ["a", "b", "c"] {
        put(
            &fake,
            PACKAGES,
            json!({"name": s(n), "state": s("live"), "readme": s("big")}),
        )
        .await;
    }
    let b = json!({"TableName": PACKAGES, "ProjectionExpression": "#s, #r",
                   "ExpressionAttributeNames": {"#s": "state", "#r": "readme"}});
    let got = call(&fake, "Scan", &b).await;
    assert_eq!(
        got.json(),
        json!({"Items": [{"state": s("live"), "readme": s("big")}, {"state": s("live"), "readme": s("big")}],
               "Count": 2, "ScannedCount": 2, "LastEvaluatedKey": {"name": s("b")}})
    );
}

#[tokio::test]
async fn a_scan_projection_with_a_raw_attribute_name_is_refused() {
    let b = json!({"TableName": PACKAGES, "ProjectionExpression": "state"});
    assert_refused(
        &call(&fake(), "Scan", &b).await,
        VALIDATION,
        "Attribute name is a reserved keyword or not a placeholder: state",
    );
}

// ---- grants ----

const GRANTS: &str = r#"{
  "packages": {"actions": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem", "dynamodb:Scan", "dynamodb:Query"], "indexes": ["by_search_bucket"]},
  "versions": {"actions": ["dynamodb:Query"], "indexes": []}
}"#;

#[tokio::test]
async fn calls_the_grants_list_are_served_and_the_others_are_denied_by_action() {
    let fake = fake_with_grants(GRANTS);
    put(&fake, PACKAGES, pkg("a")).await;
    let ok = call(
        &fake,
        "GetItem",
        &json!({"TableName": PACKAGES, "Key": pkg("a")}),
    )
    .await;
    assert_eq!(ok.json(), json!({"Item": pkg("a")}));
    assert_eq!(
        call(&fake, "Scan", &json!({"TableName": PACKAGES}))
            .await
            .status,
        200
    );
    let denied = call(
        &fake,
        "PutItem",
        &json!({"TableName": VERSIONS, "Item": ver("a", "1")}),
    )
    .await;
    assert_refused_denied(&denied, "dynamodb:PutItem", VERSIONS);
    let scan = call(&fake, "Scan", &json!({"TableName": VERSIONS})).await;
    assert_refused_denied(&scan, "dynamodb:Scan", VERSIONS);
    let del = call(
        &fake,
        "DeleteItem",
        &json!({"TableName": VERSIONS, "Key": ver("a", "1")}),
    )
    .await;
    assert_refused_denied(&del, "dynamodb:DeleteItem", VERSIONS);
    let upd = call(
        &fake,
        "UpdateItem",
        &update(ver("a", "1"), "SET #a = :v", &[("#a", "x")], &[(":v", "1")]),
    )
    .await;
    assert_eq!(upd.status, 200);
}

fn assert_refused_denied(
    got: &super::super::fake_http::client::Answered,
    action: &str,
    table: &str,
) {
    assert_eq!(got.status, 400);
    assert_eq!(got.json()["__type"], DENIED);
    assert_eq!(
        got.json()["Message"],
        json!(format!(
            "User is not authorized to perform: {action} on resource: {table}"
        ))
    );
}

#[tokio::test]
async fn a_granted_index_query_is_served_and_an_ungranted_index_names_the_index_in_the_denial() {
    let fake = fake_with_grants(GRANTS);
    let q = |table: &str, index: &str, attr: &str| {
        json!({"TableName": table, "IndexName": index, "KeyConditionExpression": "#p = :p",
               "ExpressionAttributeNames": {"#p": attr}, "ExpressionAttributeValues": {":p": s("x")}})
    };
    assert_eq!(
        call(
            &fake,
            "Query",
            &q(PACKAGES, "by_search_bucket", "search_bucket")
        )
        .await
        .status,
        200
    );
    let denied = call(
        &fake,
        "Query",
        &q(VERSIONS, "by_search_bucket", "search_bucket"),
    )
    .await;
    assert_refused_denied(
        &denied,
        "dynamodb:Query on index by_search_bucket",
        VERSIONS,
    );
}

#[tokio::test]
async fn a_transaction_is_denied_when_any_put_lacks_the_put_grant() {
    let fake = fake_with_grants(GRANTS);
    let body = transact_body(
        vec![
            tput("a"),
            json!({"Put": {"TableName": VERSIONS, "Item": ver("a", "1")}}),
        ],
        Some("t"),
    );
    let got = call(&fake, "TransactWriteItems", &body).await;
    assert_refused_denied(&got, "dynamodb:PutItem", VERSIONS);
    assert!(fake.dump(PACKAGES).is_empty());
}

// ---- transactions ----

#[tokio::test]
async fn a_transaction_writes_all_its_puts() {
    let fake = fake();
    let body = transact_body(
        vec![
            tput("a"),
            tput("b"),
            json!({"Put": {"TableName": VERSIONS, "Item": ver("a", "1")}}),
        ],
        Some("t"),
    );
    let got = call(&fake, "TransactWriteItems", &body).await;
    assert_eq!((got.status, got.json()), (200, json!({})));
    assert_eq!(fake.dump(PACKAGES), vec![pkg("a"), pkg("b")]);
    assert_eq!(fake.dump(VERSIONS), vec![ver("a", "1")]);
}

#[tokio::test]
async fn a_transaction_with_one_failed_condition_is_cancelled_naming_it_and_writes_nothing() {
    let fake = fake();
    put(&fake, PACKAGES, json!({"name": s("a"), "state": s("old")})).await;
    let guarded = json!({"Put": {"TableName": PACKAGES, "Item": pkg("a"), "ConditionExpression": "attribute_not_exists(#n)",
                                 "ExpressionAttributeNames": {"#n": "name"}}});
    let body = transact_body(vec![tput("b"), guarded], Some("t"));
    let got = call(&fake, "TransactWriteItems", &body).await;
    assert_eq!(got.status, 400);
    assert_eq!(
        got.json(),
        json!({"__type": CANCELLED,
               "message": "Transaction cancelled, please refer cancellation reasons for specific reasons [None, ConditionalCheckFailed]",
               "CancellationReasons": [{"Code": "None"},
                                       {"Code": "ConditionalCheckFailed", "Message": "The conditional request failed"}]})
    );
    assert_eq!(
        fake.dump(PACKAGES),
        vec![json!({"name": s("a"), "state": s("old")})]
    );
}

#[tokio::test]
async fn a_transaction_without_items_or_with_another_kind_of_write_is_refused() {
    let fake = fake();
    let got = call(
        &fake,
        "TransactWriteItems",
        &json!({"ClientRequestToken": "t"}),
    )
    .await;
    assert_refused(&got, VALIDATION, "TransactItems is required");
    let delete = json!({"Delete": {"TableName": PACKAGES, "Key": pkg("a")}});
    let got = call(
        &fake,
        "TransactWriteItems",
        &transact_body(vec![delete], Some("t")),
    )
    .await;
    assert_refused(&got, VALIDATION, "fake: a transaction item other than Put");
}

#[tokio::test]
async fn a_transaction_put_that_breaks_a_table_rule_is_refused_and_writes_nothing() {
    let fake = fake();
    let bad_ttl = json!({"Put": {"TableName": TOKENS, "Item": {"token_hash": s("h"), "expires_at": s("soon")}}});
    let got = call(
        &fake,
        "TransactWriteItems",
        &transact_body(vec![tput("a"), bad_ttl], Some("t")),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "TimeToLive attribute expires_at must be a number",
    );
    let no_key = json!({"Put": {"TableName": VERSIONS, "Item": {"name": s("a")}}});
    let got = call(
        &fake,
        "TransactWriteItems",
        &transact_body(vec![no_key], Some("t")),
    )
    .await;
    assert_refused(
        &got,
        VALIDATION,
        "One or more parameter values were invalid: Type mismatch for key version expected: S",
    );
    let unknown = json!({"Put": {"TableName": "nope", "Item": pkg("a")}});
    let got = call(
        &fake,
        "TransactWriteItems",
        &transact_body(vec![unknown], Some("t")),
    )
    .await;
    assert_refused(&got, VALIDATION, "Requested resource not found: table nope");
    assert!(fake.dump(PACKAGES).is_empty());
}
