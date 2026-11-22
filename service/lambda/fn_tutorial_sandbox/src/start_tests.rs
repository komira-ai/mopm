//! The cold start, the command line, the environment, the API Gateway adapter's paths, and the failures of the stores.

use mopm_ports::env::Clock;

use crate::args::{ArgsError, Options};
use crate::clock::SystemClock;
use crate::log::{self, writer_sink};
use crate::start::{Endpoints, Env, StartError};
use crate::test_support::*;

fn args(list: &[&str]) -> Result<Options, ArgsError> {
    Options::parse(list.iter().map(|a| a.to_string()))
}

async fn start_error(spec: Spec) -> String {
    match try_rig(spec).await {
        Ok(_) => panic!("the function started"),
        Err(e) => e.to_string(),
    }
}

// ---- the command line -------------------------------------------------------------------------------------------

#[test]
fn no_arguments_set_nothing() {
    assert_eq!(
        args(&[]),
        Ok(Options {
            aws_endpoint_url: None
        })
    );
}

#[test]
fn the_endpoint_flag_takes_a_url_and_points_both_clients_at_it() {
    let options = args(&["--aws-endpoint-url", "http://127.0.0.1:4566"]).expect("the flag parses");
    assert_eq!(
        options.aws_endpoint_url.as_deref(),
        Some("http://127.0.0.1:4566")
    );
    let endpoints = Endpoints::from(&options);
    assert_eq!(
        endpoints,
        Endpoints {
            dynamodb: Some("http://127.0.0.1:4566".to_string()),
            secrets: Some("http://127.0.0.1:4566".to_string())
        }
    );
    assert_eq!(Endpoints::from(&Options::default()), Endpoints::default());
}

#[test]
fn any_other_argument_and_a_flag_without_its_value_fail_the_start() {
    assert_eq!(
        args(&["--verbose"]),
        Err(ArgsError::Unknown("--verbose".to_string()))
    );
    assert_eq!(
        args(&["http://127.0.0.1:1"]),
        Err(ArgsError::Unknown("http://127.0.0.1:1".to_string()))
    );
    assert_eq!(
        args(&["--aws-endpoint-url", "http://127.0.0.1:1", "--extra"]),
        Err(ArgsError::Unknown("--extra".to_string()))
    );
    assert_eq!(args(&["--aws-endpoint-url"]), Err(ArgsError::MissingValue));
    assert_eq!(
        args(&["--aws-endpoint-url", "a", "--aws-endpoint-url", "b"]),
        Err(ArgsError::Repeated)
    );
    assert_eq!(
        ArgsError::Unknown("-x".to_string()).to_string(),
        r#"unknown argument "-x"; the only flag is --aws-endpoint-url <url>"#
    );
    assert_eq!(
        ArgsError::MissingValue.to_string(),
        "--aws-endpoint-url needs a value"
    );
    assert_eq!(
        ArgsError::Repeated.to_string(),
        "--aws-endpoint-url is given twice"
    );
    assert_eq!(
        StartError::from(ArgsError::MissingValue).to_string(),
        "--aws-endpoint-url needs a value"
    );
}

#[test]
fn the_process_arguments_are_those_after_the_program_name() {
    let all: Vec<String> = std::env::args().collect();
    assert_eq!(crate::process_args(), all[1..]);
}

// ---- the environment, the clock, the sink -----------------------------------------------------------------------

#[test]
fn the_environment_read_is_the_process_environment_and_nothing_else() {
    let var = |name: &str| std::env::var(name).ok();
    let expected = Env {
        function_name: std::env::var_os("AWS_LAMBDA_FUNCTION_NAME"),
        region: var("AWS_REGION"),
        access_key_id: var("AWS_ACCESS_KEY_ID"),
        secret_access_key: var("AWS_SECRET_ACCESS_KEY"),
        session_token: var("AWS_SESSION_TOKEN"),
    };
    assert_eq!(Env::from_process(), expected);
}

#[test]
fn the_system_clock_is_after_the_start_of_this_work() {
    let floor = "2026-09-01T00:00:00Z"
        .parse::<jiff::Timestamp>()
        .expect("a time");
    assert!(SystemClock.now() > floor);
}

/// A writer whose bytes a test reads back.
#[derive(Clone, Default)]
struct Captured(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().expect("the buffer").extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn the_writer_sink_writes_each_line_exactly_with_a_newline() {
    let out = Captured::default();
    let sink = writer_sink(Box::new(out.clone()));
    sink(&log::unavailable("req-sink", "secret_missing"));
    sink(&log::refused("req-sink-2", "csrf_failed"));
    assert_eq!(
        String::from_utf8(out.0.lock().expect("the buffer").clone()).expect("utf-8"),
        concat!(
            r#"{"event":"tutorial_sandbox","outcome":"unavailable","reason":"secret_missing","request_id":"req-sink"}"#,
            "\n",
            r#"{"event":"tutorial_sandbox","outcome":"refused","reason":"csrf_failed","request_id":"req-sink-2"}"#,
            "\n"
        )
    );
}

/// A writer that refuses every write, and counts the tries.
#[derive(Clone, Default)]
struct Refusing(std::sync::Arc<std::sync::atomic::AtomicUsize>);

impl std::io::Write for Refusing {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Err(std::io::Error::other("closed"))
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_line_the_writer_refuses_is_tried_once_and_dropped_without_failing_the_request() {
    let out = Refusing::default();
    let sink = writer_sink(Box::new(out.clone()));
    sink(&log::internal("req-sink"));
    sink(&log::internal("req-sink-2"));
    assert_eq!(out.0.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[test]
fn a_log_line_escapes_what_a_client_could_send() {
    assert_eq!(
        log::internal("a\"b\nc"),
        r#"{"event":"tutorial_sandbox","outcome":"error","reason":"internal_error","request_id":"a\"b\nc"}"#
    );
}

// ---- the cold start ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_function_name_that_is_not_the_stages_fails_the_start_by_name() {
    for (name, text) in [
        (
            Some("other-beta-tutorial-sandbox"),
            r#"AWS_LAMBDA_FUNCTION_NAME is "other-beta-tutorial-sandbox", not mopm-<stage>-<function>"#,
        ),
        (None, "AWS_LAMBDA_FUNCTION_NAME is not set"),
    ] {
        let env = Env {
            function_name: name.map(Into::into),
            ..env()
        };
        assert_eq!(
            start_error(Spec {
                env,
                ..Spec::default()
            })
            .await,
            text
        );
    }
}

#[tokio::test]
async fn a_missing_settings_item_fails_the_start_by_name() {
    assert_eq!(
        start_error(Spec {
            config: None,
            ..Spec::default()
        })
        .await,
        "the config table has no stage_settings item"
    );
}

#[tokio::test]
async fn an_item_that_is_not_valid_fails_the_start_by_name() {
    let config = item_with(|item| {
        item.as_object_mut().expect("an item").remove("site_origin");
    });
    assert_eq!(
        start_error(Spec {
            config: Some(config),
            ..Spec::default()
        })
        .await,
        "the stage_settings item is not valid: missing field `site_origin`"
    );
    let binary = item_with(|item| item["blob"] = serde_json::json!({"B": "AAE="}));
    let error = start_error(Spec {
        config: Some(binary),
        ..Spec::default()
    })
    .await;
    assert_eq!(
        error,
        "reading the stage_settings item: infrastructure fault: invalid type: byte array, expected any valid JSON value"
    );
}

#[tokio::test]
async fn the_item_the_stack_writes_gives_the_e2b_settings() {
    let rig = try_rig(Spec {
        config: Some(STACK_ITEM.to_string()),
        ..Spec::default()
    })
    .await
    .expect("the function starts");
    let e2b = rig.function.e2b.clone().expect("the item names a template");
    assert_eq!(
        (
            e2b.stage.as_str(),
            e2b.template_id.as_str(),
            e2b.timeout_s,
            e2b.e2b_domain.as_str()
        ),
        ("beta", "tpl-abc_1", 600, "e2b.example")
    );
}

#[tokio::test]
async fn a_timeout_longer_than_e2b_takes_fails_the_start_by_name() {
    let longest =
        item_with(|item| item["sandbox_timeout_s"] = serde_json::json!({"N": "4294967295"}));
    let rig = try_rig(Spec {
        config: Some(longest),
        ..Spec::default()
    })
    .await
    .expect("u32::MAX seconds is taken");
    assert_eq!(rig.function.e2b.expect("a template").timeout_s, u32::MAX);
    let longer =
        item_with(|item| item["sandbox_timeout_s"] = serde_json::json!({"N": "4294967296"}));
    assert_eq!(
        start_error(Spec {
            config: Some(longer),
            ..Spec::default()
        })
        .await,
        "the stage_settings item is not valid: sandbox_timeout_s 4294967296 is more than 4294967295 seconds"
    );
}

#[tokio::test]
async fn a_config_table_the_role_cannot_read_fails_the_start() {
    let grants = r#"{"tokens": {"actions": ["dynamodb:GetItem", "dynamodb:UpdateItem"]}, "users": {"actions": ["dynamodb:GetItem"]}}"#;
    let error = start_error(Spec {
        grants: grants.to_string(),
        ..Spec::default()
    })
    .await;
    assert!(
        error.starts_with("reading the stage_settings item: infrastructure fault: get config item: service error: unhandled error (AccessDeniedException)"),
        "{error}"
    );
}

#[tokio::test]
async fn a_missing_or_empty_edge_secret_fails_the_start_by_name() {
    assert_eq!(
        start_error(Spec {
            edge: Stored::NotFound,
            ..Spec::default()
        })
        .await,
        "the secret mopm/beta/edge-origin does not exist"
    );
    assert_eq!(
        start_error(Spec {
            edge: Stored::Value(String::new()),
            ..Spec::default()
        })
        .await,
        "the secret mopm/beta/edge-origin is empty"
    );
    let error = start_error(Spec {
        edge: Stored::Fail(500),
        ..Spec::default()
    })
    .await;
    assert!(error.starts_with("reading the secret mopm/beta/edge-origin: infrastructure fault: secretsmanager GetSecretValue"), "{error}");
}

#[tokio::test]
async fn a_missing_region_or_credential_fails_the_start_by_name() {
    let cases = [
        (
            Env {
                region: None,
                ..env()
            },
            "AWS_REGION is not set",
        ),
        (
            Env {
                access_key_id: None,
                ..env()
            },
            "AWS_ACCESS_KEY_ID is not set",
        ),
        (
            Env {
                secret_access_key: None,
                ..env()
            },
            "AWS_SECRET_ACCESS_KEY is not set",
        ),
    ];
    for (env, text) in cases {
        assert_eq!(
            start_error(Spec {
                env,
                ..Spec::default()
            })
            .await,
            text
        );
    }
}

#[tokio::test]
async fn a_session_token_is_optional() {
    let rig = rig(Spec {
        env: Env {
            session_token: None,
            ..env()
        },
        ..Spec::default()
    })
    .await;
    assert_eq!(rig.send(&Req::signed_in()).await.status, 201);
}

// ---- the stores ---------------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_session_store_the_role_cannot_use_is_500_internal_error() {
    // The role without `users`: the session row is found, its account is not readable.
    let grants = r#"{"tokens": {"actions": ["dynamodb:GetItem", "dynamodb:UpdateItem"]}, "config": {"actions": ["dynamodb:GetItem"]}}"#;
    let rig = rig(Spec {
        grants: grants.to_string(),
        ..Spec::default()
    })
    .await;
    let got = rig.send(&Req::signed_in()).await;
    assert_eq!(got.status, 500);
    assert_eq!(
        got.body,
        r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#
    );
    assert_eq!(
        rig.last_line(),
        format!(
            r#"{{"event":"tutorial_sandbox","outcome":"error","reason":"internal_error","request_id":"{REQUEST_ID}"}}"#
        )
    );
    assert_eq!(rig.e2b.requests().len(), 0);
}

#[tokio::test]
async fn a_session_the_store_does_not_know_is_401_and_an_expired_one_too() {
    let rig = rig(Spec::default()).await;
    let other = mopm_core::token::TokenSecret::mint(&[9; mopm_core::token::SECRET_BYTES]);
    let mut unknown = Req::signed_in().header("x-mopm-csrf", &mopm_core::csrf::csrf_value(&other));
    unknown.cookies = vec![format!("__Host-mopm_session={}", other.expose())];
    let got = rig.send(&unknown).await;
    assert_eq!(got.status, 401);
    assert_eq!(rig.e2b.requests().len(), 0);
    let expired = rig_expired().await;
    assert_eq!(expired.send(&Req::signed_in()).await.status, 401);
    assert_eq!(
        expired.last_line(),
        format!(
            r#"{{"event":"tutorial_sandbox","outcome":"refused","reason":"session_required","request_id":"{REQUEST_ID}"}}"#
        )
    );
    assert_eq!(expired.e2b.requests().len(), 0);
}

async fn rig_expired() -> Rig {
    rig(Spec {
        session_expires: Some("2026-11-20T09:59:00.000Z".to_string()),
        ..Spec::default()
    })
    .await
}

// ---- the API Gateway adapter ------------------------------------------------------------------------------------

#[tokio::test]
async fn a_body_that_is_not_base64_is_400_invalid_request() {
    let rig = rig(Spec::default()).await;
    let mut req = Req::signed_in().with_body("***not base64***");
    req.base64 = true;
    let got = rig.send(&req).await;
    assert_eq!(got.status, 400);
    assert_eq!(
        got.body,
        error_body(
            "invalid_request",
            "The request is not valid: the body is not valid base64.",
            "Check the request against the API documentation; update mopm if it is old."
        )
    );
    assert_eq!(
        rig.last_line(),
        format!(
            r#"{{"event":"tutorial_sandbox","outcome":"refused","reason":"invalid_request","request_id":"{REQUEST_ID}"}}"#
        )
    );
    assert_eq!(rig.e2b.requests().len(), 0);
}

#[tokio::test]
async fn a_base64_body_is_decoded_before_the_no_body_check() {
    let rig = rig(Spec::default()).await;
    let mut req = Req::signed_in().with_body("e30=");
    req.base64 = true;
    let got = rig.send(&req).await;
    assert_eq!(got.status, 400);
    assert_eq!(
        got.json()["error"]["message"],
        "The request is not valid: the request takes no body."
    );
}

#[tokio::test]
async fn an_answer_api_gateway_cannot_carry_is_a_plain_500_and_logged_as_one() {
    let rig = rig(Spec::default()).await;
    let mut req = Req::signed_in();
    req.id = "bad\nid".to_string();
    let got = rig.send(&req).await;
    assert_eq!(got.status, 500);
    assert_eq!(
        got.headers,
        vec![
            ("cache-control".to_string(), "no-store".to_string()),
            ("content-type".to_string(), "application/json".to_string())
        ]
    );
    assert_eq!(
        got.body,
        r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#
    );
    assert_eq!(
        rig.last_line(),
        r#"{"event":"tutorial_sandbox","outcome":"error","reason":"internal_error","request_id":"bad\nid"}"#
    );
    assert_eq!(
        rig.e2b.create_requests().len(),
        1,
        "the sandbox was made; its answer could not be carried"
    );
}
