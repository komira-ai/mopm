//! The whole session and logout flow on real SDK calls: a fake DynamoDB that enforces the function's role (the grants
//! of `mopm_testing::fake_dynamo::WEB_SESSION_GRANTS`) and a fake Secrets Manager, the cold start included.

use std::collections::BTreeSet;
use std::sync::Arc;

use mopm_aws::dynamo::{AuthTables, DynamoAuthStore, DynamoConfigTable};
use mopm_aws::services::SecretsManagerReader;
use mopm_core::csrf::csrf_value;
use mopm_ports::auth::AuthStore;
use mopm_testing::env::FixedClock;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, WEB_SESSION_GRANTS};
use mopm_testing::fake_http::{FakeHttp, Reply};
use mopm_web::settings::parse_function_name;
use mopm_web::WebRequest;
use serde_json::{json, Value};

use crate::cold_start;
use crate::handler::WebSessionHandler;
use crate::test_support::*;

const STAGE_SETTINGS_ITEM: &str = include_str!("../../web/tests/fixtures/stage_settings_item.json");
const TOKENS: &str = include_str!("../tests/fixtures/web_session_tokens.json");
const USERS: &str = include_str!("../tests/fixtures/web_session_users.json");
/// The `site_origin` of the stage settings item.
const BETA: &str = "https://beta.mopm.dev";

struct Flow {
    fake: FakeDynamo,
    handler: WebSessionHandler<DynamoAuthStore, FixedClock>,
}

fn items(text: &str) -> Vec<Value> {
    serde_json::from_str(text).unwrap()
}

/// The function started over a fake DynamoDB holding the stage's settings item, alice and her three token rows.
async fn flow() -> Flow {
    let fake = FakeDynamo::start(FakeConfig::web_session("t"));
    fake.seed("mopm-t-config", serde_json::from_str(STAGE_SETTINGS_ITEM).unwrap());
    for item in items(USERS) {
        fake.seed("mopm-t-users", item);
    }
    for item in items(TOKENS) {
        fake.seed("mopm-t-tokens", item);
    }
    let http =
        FakeHttp::start(vec![Reply::new(200).header("content-type", "application/x-amz-json-1.1").body(json!({"Name": "mopm/t/edge-origin", "SecretString": EDGE}).to_string())]);
    let client = dynamo_client(&fake.endpoint());
    let name = parse_function_name(Some(std::ffi::OsStr::new("mopm-t-web-session"))).unwrap();
    let config = DynamoConfigTable::new(client.clone(), name.stage.table("config"));
    let secrets = SecretsManagerReader::new(secrets_client(&http.endpoint()));
    let store = DynamoAuthStore::new(client, AuthTables::for_stage("t"), Arc::new(FixedClock::at_millis(NOW_MS)));
    let handler = cold_start(&name, &config, &secrets, store, FixedClock::at_millis(NOW_MS)).await.ok().unwrap();
    assert_eq!(http.requests()[0].header("x-amz-target"), Some("secretsmanager.GetSecretValue"));
    Flow { fake, handler }
}

/// The logout the site sends: from the stage's own origin.
fn logout(s: &mopm_core::token::TokenSecret) -> WebRequest {
    without(post(s), "origin").with_header("Origin", BETA)
}

fn token_row(fake: &FakeDynamo, id: &str) -> Value {
    fake.dump("mopm-t-tokens").into_iter().find(|i| i["id"]["S"] == id).unwrap()
}

#[tokio::test]
async fn a_session_is_answered_over_the_sdk_with_the_rows_the_role_may_read() {
    let flow = flow().await;
    let a = flow.handler.answer(&get(&cookie(&secret(1)))).await;
    assert_eq!(a.response.status, 200);
    assert_eq!(a.response.body, format!(r#"{{"csrf":"{}","expires_at":"{EXPIRES_AT}","login":"alice"}}"#, csrf_value(&secret(1))));
    let ops: Vec<(String, String)> = flow.fake.requests().iter().map(|r| (r.operation.clone(), r.body["TableName"].as_str().unwrap().to_string())).collect();
    let expected = [("GetItem", "mopm-t-config"), ("GetItem", "mopm-t-tokens"), ("GetItem", "mopm-t-users"), ("UpdateItem", "mopm-t-tokens")];
    assert_eq!(ops, expected.iter().map(|(o, t)| (o.to_string(), t.to_string())).collect::<Vec<_>>());
    assert!(flow.fake.requests().iter().all(|r| r.signed));
}

#[tokio::test]
async fn a_logout_revokes_its_own_row_only_and_the_other_session_still_answers() {
    let flow = flow().await;
    let before: Vec<Value> = flow.fake.dump("mopm-t-tokens");
    let a = flow.handler.answer(&logout(&secret(1))).await;
    assert_eq!((a.response.status, a.response.body.as_str()), (204, ""));
    assert_eq!(a.response.set_cookies.len(), 1);

    let after = flow.fake.dump("mopm-t-tokens");
    let changed: Vec<&str> = before.iter().zip(&after).filter(|(b, a)| b != a).map(|(_, a)| a["id"]["S"].as_str().unwrap()).collect();
    assert_eq!(changed, vec!["tok-1"]);
    let mut expected = before.iter().find(|i| i["id"]["S"] == "tok-1").unwrap().clone();
    // The logout's own session check marks the row used, then the revocation stamps it.
    expected["last_used_at"] = json!({"S": "2026-11-18T12:06:40.000Z"});
    expected["revoked_at"] = json!({"S": "2026-11-18T12:06:40.000Z"});
    assert_eq!(token_row(&flow.fake, "tok-1"), expected);

    // The same account's other session and its API token are untouched, and the other session is still valid.
    let other = flow.handler.answer(&get(&cookie(&secret(2)))).await;
    assert_eq!(other.response.status, 200);
    assert!(token_row(&flow.fake, "tok-api").get("revoked_at").is_none());

    let again = flow.handler.answer(&logout(&secret(1))).await;
    assert_eq!(again.response.status, 401);
    assert!(again.response.body.contains("session_required"));
}

#[tokio::test]
async fn a_logout_from_another_origin_is_refused_before_the_table_is_read() {
    let flow = flow().await;
    flow.fake.clear_requests();
    let a = flow.handler.answer(&post(&secret(1))).await;
    assert_eq!(a.response.status, 403);
    assert!(flow.fake.requests().is_empty());
    assert!(token_row(&flow.fake, "tok-1").get("revoked_at").is_none());
}

#[tokio::test]
async fn every_call_of_the_flow_is_one_the_roles_grants_allow() {
    let flow = flow().await;
    flow.handler.answer(&get(&cookie(&secret(1)))).await;
    flow.handler.answer(&logout(&secret(1))).await;
    flow.handler.answer(&get(&cookie(&secret(1)))).await;
    let grants: Value = serde_json::from_str(WEB_SESSION_GRANTS).unwrap();
    let used: BTreeSet<(String, String)> =
        flow.fake.requests().iter().map(|r| (r.body["TableName"].as_str().unwrap().strip_prefix("mopm-t-").unwrap().to_string(), format!("dynamodb:{}", r.operation))).collect();
    assert!(!used.is_empty());
    for (table, action) in &used {
        let allowed: Vec<&str> = grants[table]["actions"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()).collect();
        assert!(allowed.contains(&action.as_str()), "{action} on {table} is not granted");
    }
    let used_actions: BTreeSet<&str> = used.iter().map(|(_, a)| a.as_str()).collect();
    assert_eq!(used_actions, BTreeSet::from(["dynamodb:GetItem", "dynamodb:UpdateItem"]));
}

/// The fixture rows are what the DynamoDB adapter writes for the rows they stand for, so a change of the adapter's
/// row shape fails here rather than at the function.
#[tokio::test]
async fn the_fixture_rows_are_what_the_adapter_writes() {
    let fake = FakeDynamo::start(FakeConfig::registry("t"));
    let store = DynamoAuthStore::new(dynamo_client(&fake.endpoint()), AuthTables::for_stage("t"), Arc::new(FixedClock::at_millis(NOW_MS)));
    store.upsert_user(GITHUB_ID, "alice", "2026-11-18T11:06:40.000Z", Some(true)).await.unwrap();
    let mut api = session_row(&secret(3), "tok-api", GITHUB_ID);
    api.kind = mopm_ports::types::TokenKind::Api;
    api.name = "cli".to_string();
    for row in [session_row(&secret(1), "tok-1", GITHUB_ID), session_row(&secret(2), "tok-2", GITHUB_ID), api] {
        store.put_token(&row).await.unwrap();
    }
    assert_eq!(fake.dump("mopm-t-tokens"), items(TOKENS));
    assert_eq!(fake.dump("mopm-t-users"), items(USERS));
}

#[tokio::test]
async fn a_cold_start_reads_the_settings_item_and_the_secret_through_the_sdk() {
    let flow = flow().await;
    // The settings' origin is the CSRF check's: the site's own origin passes, the other fails.
    assert_eq!(flow.handler.answer(&logout(&secret(2))).await.response.status, 204);
    assert_eq!(flow.handler.answer(&post(&secret(1))).await.response.status, 403);
}
