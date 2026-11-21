//! A stage whose `config` table has no `stage_settings` item fails the cold start by name: the process entry exits with a
//! failure and never polls the runtime API. The only test of this file: it sets the process's environment.

use std::net::TcpListener;
use std::process::ExitCode;

use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo};

#[tokio::test(flavor = "current_thread")]
async fn a_stage_without_its_settings_item_fails_the_entry_before_any_poll_of_the_runtime_api() {
    let dynamo = FakeDynamo::start(FakeConfig::web_session("t"));
    let runtime_api = TcpListener::bind("127.0.0.1:0").unwrap();
    let scratch =
        std::env::temp_dir().join(format!("fn_web_session_cold_start_{}", std::process::id()));
    let vars = [
        ("AWS_LAMBDA_FUNCTION_NAME", "mopm-t-web-session".to_string()),
        (
            "AWS_LAMBDA_RUNTIME_API",
            runtime_api.local_addr().unwrap().to_string(),
        ),
        ("AWS_REGION", "us-east-1".to_string()),
        ("AWS_ACCESS_KEY_ID", "AKIDFAKE".to_string()),
        ("AWS_SECRET_ACCESS_KEY", "fakesecret".to_string()),
        ("AWS_ENDPOINT_URL_DYNAMODB", dynamo.endpoint()),
        (
            "AWS_CONFIG_FILE",
            scratch.join("config").display().to_string(),
        ),
        (
            "AWS_SHARED_CREDENTIALS_FILE",
            scratch.join("credentials").display().to_string(),
        ),
        ("AWS_EC2_METADATA_DISABLED", "true".to_string()),
    ];
    for (k, v) in &vars {
        std::env::set_var(k, v);
    }

    // The entry builds its own runtime, so it runs on a thread of its own while this one serves the fake DynamoDB.
    let exit = tokio::task::spawn_blocking(fn_web_session::runtime::main)
        .await
        .unwrap();

    assert!(exit == ExitCode::FAILURE);
    assert_eq!(dynamo.operations(), vec!["GetItem"]);
    runtime_api.set_nonblocking(true).unwrap();
    assert_eq!(
        runtime_api.accept().err().map(|e| e.kind()),
        Some(std::io::ErrorKind::WouldBlock)
    );
}
