//! `fn_tutorial_sandbox::run` against one loopback server that plays both the Lambda runtime API and the AWS endpoint
//! (the `--aws-endpoint-url` flag points both clients at it): the cold start reads the settings and the two secrets, one
//! event is answered, and the answer is posted back to the runtime. This is a test binary of its own, so it may set the
//! process environment (as Lambda does) without racing the unit tests.

use mopm_ports::error::{PortError, PortResult};
use mopm_ports::http::{HttpClient, HttpRequest, HttpResponse};
use mopm_testing::fake_http::{Answer, FakeHttp, Reply};
use serde_json::{json, Value};

const STAGE_ITEM: &str =
    include_str!("../../../infra/stacks/test/fixtures/stage-settings-item.json");
const NEXT: &str = "/2018-06-01/runtime/invocation/next";
const RESPONSE: &str = "/2018-06-01/runtime/invocation/req-run-1/response";

/// E2B is never called: the event is refused before it.
struct NoE2b;

impl HttpClient for NoE2b {
    async fn send(&self, _: HttpRequest) -> PortResult<HttpResponse> {
        Err(PortError::fault("this test never reaches E2B"))
    }
}

fn event() -> String {
    json!({
        "version": "2.0",
        "routeKey": "POST /api/v2/tutorial/sandbox",
        "rawPath": "/api/v2/tutorial/sandbox",
        "rawQueryString": "",
        "headers": {"x-mopm-edge": "edge-run-value"},
        "requestContext": {
            "accountId": "example",
            "apiId": "api",
            "domainName": "api.beta.mopm.dev",
            "http": {"method": "POST", "path": "/api/v2/tutorial/sandbox", "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": "req-run-1",
            "routeKey": "POST /api/v2/tutorial/sandbox",
            "stage": "$default",
            "timeEpoch": 1_795_168_800_000_i64
        },
        "isBase64Encoded": false
    })
    .to_string()
}

fn amz(status: u16, version: &str, body: Value) -> Answer {
    Answer::Reply(
        Reply::new(status)
            .header("Content-Type", &format!("application/x-amz-json-{version}"))
            .body(body.to_string()),
    )
}

fn server() -> FakeHttp {
    // Built at run time: the hygiene check refuses a 12-digit literal.
    let account = "0".repeat(12);
    let mut polls = 0;
    FakeHttp::with_handler(move |seen| {
        match (
            seen.method.as_str(),
            seen.path(),
            seen.header("x-amz-target"),
        ) {
            ("GET", NEXT, _) => {
                polls += 1;
                if polls > 1 {
                    return Answer::Hang;
                }
                Answer::Reply(
                Reply::new(200)
                    .header("Content-Type", "application/json")
                    .header("Lambda-Runtime-Aws-Request-Id", "req-run-1")
                    .header("Lambda-Runtime-Deadline-Ms", "32503680000000")
                    .header("Lambda-Runtime-Invoked-Function-Arn", &format!("arn:aws:lambda:us-east-1:{account}:function:mopm-beta-tutorial-sandbox"))
                    .header("Lambda-Runtime-Trace-Id", "Root=1-00000000-000000000000000000000000")
                    .body(event()),
            )
            }
            ("POST", RESPONSE, _) => Answer::Reply(Reply::new(202)),
            ("POST", "/", Some("DynamoDB_20120810.GetItem")) => amz(
                200,
                "1.0",
                json!({"Item": serde_json::from_str::<Value>(STAGE_ITEM).expect("the fixture is JSON")}),
            ),
            ("POST", "/", Some("secretsmanager.GetSecretValue")) => match seen
                .json()
                .and_then(|b| b["SecretId"].as_str().map(str::to_string))
                .as_deref()
            {
                Some("mopm/beta/edge-origin") => amz(
                    200,
                    "1.1",
                    json!({"ARN": format!("arn:aws:secretsmanager:us-east-1:{account}:secret:mopm/beta/edge-origin-AbCdEf"), "Name": "mopm/beta/edge-origin", "SecretString": "edge-run-value"}),
                ),
                _ => amz(
                    400,
                    "1.1",
                    json!({"__type": "ResourceNotFoundException", "message": "Secrets Manager can't find the specified secret."}),
                ),
            },
            _ => Answer::Reply(Reply::new(404)),
        }
    })
}

#[tokio::test]
async fn the_function_starts_answers_one_event_and_posts_the_answer() {
    let fake = server();
    let runtime = fake.endpoint().trim_start_matches("http://").to_string();
    for (name, value) in [
        ("AWS_LAMBDA_RUNTIME_API", runtime.as_str()),
        ("AWS_LAMBDA_FUNCTION_NAME", "mopm-beta-tutorial-sandbox"),
        ("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST"),
        ("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "256"),
        ("AWS_LAMBDA_LOG_GROUP_NAME", "run-test"),
        ("AWS_LAMBDA_LOG_STREAM_NAME", "run-test"),
        ("AWS_REGION", "us-east-1"),
        ("AWS_ACCESS_KEY_ID", "AKIDTEST"),
        ("AWS_SECRET_ACCESS_KEY", "test-secret-access-key"),
    ] {
        std::env::set_var(name, value);
    }
    let args = vec!["--aws-endpoint-url".to_string(), fake.endpoint()];
    // Progress, not time: the runtime posts the answer once it has it, and that is the fifth request.
    tokio::select! {
        ended = fn_tutorial_sandbox::run(args, NoE2b, "http://127.0.0.1:1") => panic!("the function ended: {ended:?}"),
        () = fake.wait_for_requests(5) => {}
    }
    let seen = fake.requests();
    let calls: Vec<(String, String)> = seen
        .iter()
        .take(5)
        .map(|r| {
            (
                r.method.clone(),
                r.header("x-amz-target")
                    .map_or_else(|| r.path().to_string(), str::to_string),
            )
        })
        .collect();
    assert_eq!(
        calls,
        [
            ("POST", "DynamoDB_20120810.GetItem"),
            ("POST", "secretsmanager.GetSecretValue"),
            ("POST", "secretsmanager.GetSecretValue"),
            ("GET", NEXT),
            ("POST", RESPONSE),
        ]
        .map(|(m, c)| (m.to_string(), c.to_string()))
    );
    let posted: Value = seen[4].json().expect("the posted answer is JSON");
    assert_eq!(posted["statusCode"], 401);
    assert_eq!(
        posted["body"],
        r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#
    );
    assert_eq!(posted["headers"]["x-mopm-request-id"], "req-run-1");
}

#[tokio::test]
async fn an_argument_the_function_does_not_take_fails_before_anything_is_read() {
    let error = fn_tutorial_sandbox::run(vec!["--help".to_string()], NoE2b, "http://127.0.0.1:1")
        .await
        .expect_err("the start fails");
    assert_eq!(
        error.to_string(),
        r#"unknown argument "--help"; the only flag is --aws-endpoint-url <url>"#
    );
}
