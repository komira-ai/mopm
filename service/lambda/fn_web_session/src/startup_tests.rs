//! The cold start: the stage settings item as the API stack writes it, read through the DynamoDB adapter; and the
//! failures it names.

use mopm_aws::dynamo::DynamoConfigTable;
use mopm_testing::env::FixedClock;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo};
use mopm_testing::memory_auth::MemoryAuthStore;
use mopm_testing::memory_publish::MemorySecrets;
use mopm_web::settings::{parse_function_name, ConfigTable, FunctionName, SetupError, StageSettings};
use serde_json::{json, Value};
use std::collections::BTreeMap;

use crate::cold_start;
use crate::test_support::*;

/// The item the API stack writes for `beta` (`service/lambda/web/tests/fixtures/stage_settings_item.json`).
const STAGE_SETTINGS_ITEM: &str = include_str!("../../web/tests/fixtures/stage_settings_item.json");

fn name() -> FunctionName {
    parse_function_name(Some(std::ffi::OsStr::new("mopm-beta-web-session"))).unwrap()
}

fn table_with_item() -> BTreeMap<String, Value> {
    BTreeMap::from([(
        "stage_settings".to_string(),
        json!({
            "key": "stage_settings", "redirect_uri": "https://mopm.dev/api/v2/auth/web/callback", "site_origin": SITE,
            "require_2fa": true, "e2b_domain": "e2b.app", "sandbox_timeout_s": 1800
        }),
    )])
}

async fn start(config: &impl ConfigTable, secrets: &MemorySecrets) -> Result<(), SetupError> {
    cold_start(&name(), config, secrets, MemoryAuthStore::new(), FixedClock::at_millis(NOW_MS)).await.map(|_| ())
}

fn secrets_with(value: Option<&str>) -> MemorySecrets {
    let secrets = MemorySecrets::new();
    if let Some(v) = value {
        secrets.set("mopm/beta/edge-origin", v);
    }
    secrets
}

#[tokio::test]
async fn the_item_the_stack_writes_is_read_through_dynamodb_into_exactly_its_settings() {
    let fake = FakeDynamo::start(FakeConfig::web_session("beta"));
    fake.seed("mopm-beta-config", serde_json::from_str(STAGE_SETTINGS_ITEM).unwrap());
    let table = DynamoConfigTable::new(dynamo_client(&fake.endpoint()), name().stage.table("config"));
    let settings = StageSettings::load(&table).await.unwrap();
    assert_eq!(
        settings,
        StageSettings {
            redirect_uri: "https://beta.mopm.dev/api/v2/auth/web/callback".to_string(),
            site_origin: "https://beta.mopm.dev".to_string(),
            require_two_factor: false,
            e2b_template_id: Some("tpl-abc_1".to_string()),
            e2b_domain: "e2b.example".to_string(),
            sandbox_timeout_seconds: 600,
        }
    );
}

#[tokio::test]
async fn a_stage_with_its_item_and_its_secret_starts() {
    assert!(start(&table_with_item(), &secrets_with(Some(EDGE))).await.is_ok());
}

#[tokio::test]
async fn a_started_handler_checks_csrf_against_the_items_site_origin() {
    let handler = cold_start(&name(), &table_with_item(), &secrets_with(Some(EDGE)), MemoryAuthStore::new(), FixedClock::at_millis(NOW_MS)).await.ok().unwrap();
    // No such session, but the origin passes, so the answer is the lookup's 401 and not the CSRF check's 403.
    assert_eq!(handler.answer(&post(&secret(1))).await.response.status, 401);
    let foreign = without(post(&secret(1)), "origin").with_header("Origin", "https://other.example");
    assert_eq!(handler.answer(&foreign).await.response.status, 403);
}

#[tokio::test]
async fn a_missing_settings_item_is_refused_by_name() {
    let e = start(&BTreeMap::<String, Value>::new(), &secrets_with(Some(EDGE))).await.unwrap_err();
    assert_eq!(e.to_string(), "the config table has no stage_settings item");
}

#[tokio::test]
async fn a_missing_secret_is_refused_by_name() {
    let e = start(&table_with_item(), &secrets_with(None)).await.unwrap_err();
    assert_eq!(e.to_string(), "the secret mopm/beta/edge-origin does not exist");
}

#[tokio::test]
async fn an_empty_secret_is_refused_by_name() {
    let e = start(&table_with_item(), &secrets_with(Some(""))).await.unwrap_err();
    assert_eq!(e.to_string(), "the secret mopm/beta/edge-origin is empty");
}

#[tokio::test]
async fn an_invalid_settings_item_is_refused_before_the_secret_is_read() {
    let mut table = table_with_item();
    table.insert("stage_settings".to_string(), json!({"key": "stage_settings", "site_origin": "http://mopm.dev"}));
    let e = start(&table, &secrets_with(None)).await.unwrap_err();
    assert!(e.to_string().starts_with("the stage_settings item is not valid: "), "{e}");
}
