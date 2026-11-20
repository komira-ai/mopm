//! What runs the function: the clock and randomness, the stage's config table over DynamoDB, the cold start against a
//! fake DynamoDB and a fake Secrets Manager, and the messages of a start that fails.

use aws_config::SdkConfig;
use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region, SharedCredentialsProvider};
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, Grants};
use mopm_testing::fake_http::{Answer, FakeHttp, Reply, Seen};
use mopm_web::settings::parse_function_name;
use serde_json::{json, Value};

use super::*;
use crate::test_support::*;

#[test]
fn the_system_clock_reads_the_wall_clock() {
    // 2026-01-01 and 2100-01-01: the real time is between them on any machine that runs this.
    let now = SystemClock.now().as_second();
    assert!((1_767_225_600..4_102_444_800).contains(&now), "{now}");
}

#[test]
fn the_os_random_source_fills_the_whole_buffer_differently_each_time() {
    let (mut a, mut b) = ([0u8; 64], [0u8; 64]);
    OsRng.fill(&mut a);
    OsRng.fill(&mut b);
    assert_ne!(a, b);
    assert_ne!(a, [0u8; 64]);
    assert!(a.iter().any(|&x| x != 0) && b.iter().any(|&x| x != 0));
}

#[test]
#[should_panic(
    expected = "the operating system's random source failed: getrandom: this target is not supported"
)]
fn a_random_source_that_fails_stops_the_invocation_instead_of_returning_bytes_that_are_not_random()
{
    fill_with(&mut [0u8; 8], &mut |_| Err(getrandom::Error::UNSUPPORTED));
}

#[test]
fn a_random_source_that_works_fills_the_buffer() {
    let mut buf = [0u8; 4];
    fill_with(&mut buf, &mut |b| {
        b.copy_from_slice(&[1, 2, 3, 4]);
        Ok(())
    });
    assert_eq!(buf, [1, 2, 3, 4]);
}

fn settings_item() -> Value {
    json!({
        "key": {"S": "stage_settings"},
        "redirect_uri": {"S": "https://mopm.test/api/v2/auth/web/callback"},
        "site_origin": {"S": "https://mopm.test"},
        "require_two_factor": {"BOOL": true},
        "e2b_template_id": {"S": "tpl-test"},
        "e2b_domain": {"S": "e2b.test"},
        "sandbox_timeout_seconds": {"N": "1800"},
    })
}

fn dynamo_with(grants: &str) -> FakeDynamo {
    FakeDynamo::start(
        FakeConfig::registry("t").with_grants("mopm-t-", Grants::parse(grants).unwrap()),
    )
}

#[tokio::test]
async fn the_config_table_gives_an_item_as_json_with_its_numbers_as_numbers() {
    let dynamo = dynamo_with(ROLE_GRANTS);
    dynamo.seed("mopm-t-config", settings_item());
    let table = DynamoConfigTable::new(
        dynamo_client(&dynamo.endpoint()),
        "mopm-t-config".to_string(),
    );
    let item = table.get_item("stage_settings").await.unwrap().unwrap();
    assert_eq!(
        item,
        json!({
            "key": "stage_settings",
            "redirect_uri": "https://mopm.test/api/v2/auth/web/callback",
            "site_origin": "https://mopm.test",
            "require_two_factor": true,
            "e2b_template_id": "tpl-test",
            "e2b_domain": "e2b.test",
            "sandbox_timeout_seconds": 1800,
        })
    );
    assert_eq!(table.get_item("other").await.unwrap(), None);
    assert_eq!(dynamo.operations(), vec!["GetItem", "GetItem"]);
}

#[tokio::test]
async fn a_config_table_that_cannot_be_read_is_a_fault_naming_the_table() {
    let dynamo = dynamo_with(&grants_without("config", "dynamodb:GetItem"));
    let table = DynamoConfigTable::new(
        dynamo_client(&dynamo.endpoint()),
        "mopm-t-config".to_string(),
    );
    let err = table.get_item("stage_settings").await.unwrap_err();
    assert!(
        err.to_string()
            .starts_with("infrastructure fault: dynamodb GetItem on mopm-t-config: "),
        "{err}"
    );
}

#[tokio::test]
async fn a_config_item_with_an_attribute_json_cannot_hold_is_a_fault() {
    let dynamo = dynamo_with(ROLE_GRANTS);
    dynamo.seed(
        "mopm-t-config",
        json!({"key": {"S": "stage_settings"}, "blob": {"B": "AAEC"}}),
    );
    let table = DynamoConfigTable::new(
        dynamo_client(&dynamo.endpoint()),
        "mopm-t-config".to_string(),
    );
    assert!(table
        .get_item("stage_settings")
        .await
        .unwrap_err()
        .to_string()
        .starts_with("infrastructure fault: "));
}

/// A Secrets Manager (and, for `cold_start`, a DynamoDB) on one loopback server: `secrets` by id, `settings` for the
/// config table's GetItem. Anything else is a 404.
fn aws_fake(secrets: Vec<(&'static str, &'static str)>, settings: Option<Value>) -> FakeHttp {
    FakeHttp::with_handler(move |seen: &Seen| match seen.header("x-amz-target") {
        Some("secretsmanager.GetSecretValue") => {
            let id = seen
                .json()
                .and_then(|j| j["SecretId"].as_str().map(str::to_string))
                .unwrap_or_default();
            match secrets.iter().find(|(k, _)| *k == id) {
                Some((name, value)) => Answer::Reply(
                    Reply::new(200)
                        .header("content-type", "application/x-amz-json-1.1")
                        .body(json!({"Name": name, "SecretString": value}).to_string()),
                ),
                None => Answer::Reply(
                    Reply::new(400)
                        .header("content-type", "application/x-amz-json-1.1")
                        .body(
                            r#"{"__type":"ResourceNotFoundException","Message":"no such secret"}"#,
                        ),
                ),
            }
        }
        Some("DynamoDB_20120810.GetItem") => {
            let body = settings
                .as_ref()
                .map_or(json!({}), |item| json!({"Item": item}));
            Answer::Reply(
                Reply::new(200)
                    .header("content-type", "application/x-amz-json-1.0")
                    .body(body.to_string()),
            )
        }
        _ => Answer::Reply(Reply::new(404)),
    })
}

const OAUTH: &str =
    r#"{"client_id":"Ov23liFakeClientId00","client_secret":"fake-client-secret-0123456789"}"#;

fn sdk_config(endpoint: &str) -> SdkConfig {
    SdkConfig::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(SharedCredentialsProvider::new(Credentials::new(
            "AKIDFAKE",
            "fakesecret",
            None,
            None,
            "static",
        )))
        .build()
}

fn secrets_reader(endpoint: &str) -> SecretsManagerReader {
    SecretsManagerReader::new(aws_sdk_secretsmanager::Client::new(&sdk_config(endpoint)))
}

fn function() -> FunctionName {
    parse_function_name(Some(std::ffi::OsStr::new("mopm-t-web-login"))).unwrap()
}

fn no_roots_client() -> HyperHttpClient {
    HyperHttpClient::with_roots(rustls::RootCertStore::empty(), MAX_RESPONSE_BYTES).unwrap()
}

#[tokio::test]
async fn a_cold_start_reads_the_settings_the_edge_secret_and_the_oauth_app_and_answers_a_start() {
    let dynamo = dynamo_with(ROLE_GRANTS);
    dynamo.seed("mopm-t-config", settings_item());
    let aws = aws_fake(
        vec![("mopm/t/edge-origin", EDGE), ("mopm/t/github-oauth", OAUTH)],
        None,
    );
    let app = build(
        dynamo_client(&dynamo.endpoint()),
        secrets_reader(&aws.endpoint()),
        &function(),
        no_roots_client(),
    )
    .await
    .unwrap();
    assert_eq!(app.settings.site_origin, "https://mopm.test");
    assert_eq!(app.app.client_id(), "Ov23liFakeClientId00");

    let before = SystemClock.now().as_second();
    let resp = app.handle(&start_request(Some("/tutorial/hello"))).await;
    let after = SystemClock.now().as_second();
    assert_eq!(resp.status, 302);
    let location = resp.header("location").unwrap();
    assert!(location.starts_with("https://github.com/login/oauth/authorize?client_id=Ov23liFakeClientId00&redirect_uri=https%3A%2F%2Fmopm.test%2Fapi%2Fv2%2Fauth%2Fweb%2Fcallback&"), "{location}");
    let rows = dynamo.dump(WEB_LOGINS);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["return_to"]["S"], "/tutorial/hello");
    // The row expires ten minutes after the wall clock's now (read between the two readings above).
    let expires: i64 = rows[0]["expires_at"]["N"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        (before + 600..=after + 600).contains(&expires),
        "{expires} not in {before}+600..={after}+600"
    );

    // The edge secret it read is the one it enforces.
    let no_edge = WebRequest::new(Method::Get, crate::login::START_PATH, "r");
    assert_eq!(app.handle(&no_edge).await.status, 401);
    // The two secrets were read once each, at the start, and not again by the requests.
    let targets: Vec<String> = aws
        .requests()
        .iter()
        .filter_map(|r| r.header("x-amz-target").map(str::to_string))
        .collect();
    assert_eq!(
        targets,
        vec![
            "secretsmanager.GetSecretValue",
            "secretsmanager.GetSecretValue"
        ]
    );
}

use mopm_web::request::{Method, WebRequest};

async fn start_failure(
    settings: Option<Value>,
    secrets: Vec<(&'static str, &'static str)>,
) -> String {
    let dynamo = dynamo_with(ROLE_GRANTS);
    if let Some(item) = settings {
        dynamo.seed("mopm-t-config", item);
    }
    let aws = aws_fake(secrets, None);
    let err = build(
        dynamo_client(&dynamo.endpoint()),
        secrets_reader(&aws.endpoint()),
        &function(),
        no_roots_client(),
    )
    .await
    .err()
    .expect("the start fails");
    err.to_string()
}

#[tokio::test]
async fn a_start_without_its_settings_or_secrets_fails_by_name() {
    let both = vec![("mopm/t/edge-origin", EDGE), ("mopm/t/github-oauth", OAUTH)];
    assert_eq!(
        start_failure(None, both.clone()).await,
        "the config table has no stage_settings item"
    );
    let mut broken = settings_item();
    broken.as_object_mut().unwrap().remove("require_two_factor");
    assert_eq!(
        start_failure(Some(broken), both.clone()).await,
        "the stage_settings item is not valid: missing field `require_two_factor`"
    );
    assert_eq!(
        start_failure(Some(settings_item()), vec![("mopm/t/github-oauth", OAUTH)]).await,
        "the secret mopm/t/edge-origin does not exist"
    );
    assert_eq!(
        start_failure(Some(settings_item()), vec![("mopm/t/edge-origin", EDGE)]).await,
        "the GitHub OAuth secret mopm/t/github-oauth does not exist"
    );
    assert_eq!(
        start_failure(Some(settings_item()), vec![("mopm/t/edge-origin", "")]).await,
        "the secret mopm/t/edge-origin is empty"
    );
    assert_eq!(
        start_failure(
            Some(settings_item()),
            vec![
                ("mopm/t/edge-origin", EDGE),
                (
                    "mopm/t/github-oauth",
                    r#"{"client_id":"Ov23liFakeClientId00"}"#
                )
            ]
        )
        .await,
        "the GitHub OAuth secret mopm/t/github-oauth has no client_secret"
    );
}

#[tokio::test]
async fn a_cold_start_builds_the_https_client_from_the_systems_roots_or_fails_naming_them() {
    // Whether the machine has root certificates is not the test's to decide: with them the start finishes against the
    // fakes below, without them it stops at the client, by name.
    let aws = aws_fake(
        vec![("mopm/t/edge-origin", EDGE), ("mopm/t/github-oauth", OAUTH)],
        Some(settings_item()),
    );
    match cold_start(&sdk_config(&aws.endpoint()), &function()).await {
        Ok(app) => assert_eq!(app.settings.site_origin, "https://mopm.test"),
        Err(err) => assert!(
            err.to_string().starts_with(
                "building the HTTPS client: infrastructure fault: no root certificates to trust"
            ),
            "{err}"
        ),
    }
}

#[test]
fn a_run_that_stops_says_why_in_debug_as_in_display() {
    let stopped = RunError::Runtime("the runtime API closed".to_string());
    assert_eq!(
        stopped.to_string(),
        "the Lambda runtime stopped: the runtime API closed"
    );
    assert_eq!(
        format!("{stopped:?}"),
        "the Lambda runtime stopped: the runtime API closed"
    );
    let startup = RunError::from(StartupError::from(SetupError::FunctionNameMissing));
    assert_eq!(
        format!("{startup:?}"),
        "the function cannot start: AWS_LAMBDA_FUNCTION_NAME is not set"
    );
}
