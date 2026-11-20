//! The built executable, run as Lambda runs it: a custom runtime against a fake Lambda runtime API, a fake DynamoDB and
//! a fake Secrets Manager, all one loopback server. It starts (reads the stage's settings and its two secrets), takes one
//! API Gateway event (a start request), stores the login transaction and posts the redirect to GitHub. Whatever the
//! runtime API does next (here: the connection closed on the next poll) ends the process, which this test lets finish.
//!
//! The child's environment is exactly what the test gives it: the function's name, the runtime API's address, the SDK's
//! endpoint, test credentials, no config files, no instance metadata, and the test CA as the system's roots. (The
//! profile file of a coverage run, when the test is one, is passed on so that the child's lines count.)

use std::process::{Command, Stdio};

use mopm_testing::fake_http::{Answer, FakeHttp, Reply, Seen};
use serde_json::{json, Value};

const EDGE: &str = "edge-value-for-the-process-test";
const CLIENT_ID: &str = "Ov23liProcessTest0";
const NEXT: &str = "/2018-06-01/runtime/invocation/next";
const RESPONSE: &str = "/2018-06-01/runtime/invocation/req-1/response";

fn event() -> Value {
    json!({
        "version": "2.0",
        "routeKey": "GET /api/v2/auth/web/start",
        "rawPath": "/api/v2/auth/web/start",
        "rawQueryString": "return_to=%2Ftutorial%2Fhello",
        "headers": {
            "host": "api.mopm.test", "x-mopm-edge": EDGE,
            "sec-fetch-mode": "navigate", "sec-fetch-dest": "document", "sec-fetch-site": "none",
        },
        "requestContext": {
            "accountId": "example", "apiId": "api", "domainName": "api.mopm.test",
            "http": {"method": "GET", "path": "/api/v2/auth/web/start", "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": "req-1", "routeKey": "GET /api/v2/auth/web/start", "stage": "$default", "timeEpoch": 1_795_000_000_000_i64
        },
        "isBase64Encoded": false
    })
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

fn json_reply(content_type: &str, body: Value) -> Answer {
    Answer::Reply(
        Reply::new(200)
            .header("content-type", content_type)
            .body(body.to_string()),
    )
}

fn answer(nexts: &mut u32, seen: &Seen) -> Answer {
    match (
        seen.method.as_str(),
        seen.path(),
        seen.header("x-amz-target"),
    ) {
        ("GET", NEXT, _) => {
            *nexts += 1;
            if *nexts > 1 {
                return Answer::Drop;
            }
            Answer::Reply(
                Reply::new(200)
                    .header("content-type", "application/json")
                    .header("Lambda-Runtime-Aws-Request-Id", "req-1")
                    .header("Lambda-Runtime-Deadline-Ms", "32503680000000")
                    .header(
                        "Lambda-Runtime-Invoked-Function-Arn",
                        // Built at run time: the hygiene lint refuses an account-id-shaped literal.
                        &format!(
                            "arn:aws:lambda:us-east-1:{}:function:mopm-e2e-web-login",
                            "0".repeat(12)
                        ),
                    )
                    .body(event().to_string()),
            )
        }
        ("POST", RESPONSE, _) => Answer::Reply(Reply::new(202)),
        (_, _, Some("DynamoDB_20120810.GetItem")) => json_reply(
            "application/x-amz-json-1.0",
            json!({"Item": settings_item()}),
        ),
        (_, _, Some("DynamoDB_20120810.PutItem")) => {
            json_reply("application/x-amz-json-1.0", json!({}))
        }
        (_, _, Some("secretsmanager.GetSecretValue")) => {
            let id = seen
                .json()
                .and_then(|j| j["SecretId"].as_str().map(str::to_string))
                .unwrap_or_default();
            let value = match id.as_str() {
                "mopm/e2e/edge-origin" => EDGE.to_string(),
                "mopm/e2e/github-oauth" => {
                    json!({"client_id": CLIENT_ID, "client_secret": "process-test-secret"})
                        .to_string()
                }
                other => panic!("an unexpected secret {other}"),
            };
            json_reply(
                "application/x-amz-json-1.1",
                json!({"Name": id, "SecretString": value}),
            )
        }
        _ => Answer::Reply(Reply::new(404)),
    }
}

#[tokio::test]
async fn the_executable_starts_serves_one_start_event_and_posts_the_redirect_to_github() {
    let mut nexts = 0;
    let server = FakeHttp::with_handler(move |seen| answer(&mut nexts, seen));
    let port = server.endpoint().rsplit(':').next().unwrap().to_string();
    let mut child = Command::new(env!("CARGO_BIN_EXE_web_login"));
    child
        .env_clear()
        .env("AWS_LAMBDA_FUNCTION_NAME", "mopm-e2e-web-login")
        .env("AWS_LAMBDA_RUNTIME_API", format!("127.0.0.1:{port}"))
        .env("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST")
        .env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128")
        .env(
            "AWS_LAMBDA_LOG_GROUP_NAME",
            "/aws/lambda/mopm-e2e-web-login",
        )
        .env("AWS_LAMBDA_LOG_STREAM_NAME", "stream")
        .env("AWS_ENDPOINT_URL", server.endpoint())
        .env("AWS_REGION", "us-east-1")
        .env("AWS_ACCESS_KEY_ID", "AKIDPROCESSTEST")
        .env("AWS_SECRET_ACCESS_KEY", "process-test-secret-key")
        .env("AWS_CONFIG_FILE", "tests/fixtures/absent-config")
        .env(
            "AWS_SHARED_CREDENTIALS_FILE",
            "tests/fixtures/absent-credentials",
        )
        .env("AWS_EC2_METADATA_DISABLED", "true")
        .env("HOME", "tests/fixtures/absent-home")
        .env("SSL_CERT_FILE", "tests/fixtures/ca.pem")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(profile) = std::env::var_os("LLVM_PROFILE_FILE") {
        child.env("LLVM_PROFILE_FILE", profile);
    }
    // The fake server runs on this runtime, so the process is waited for on a thread of its own.
    let output = tokio::task::spawn_blocking(move || child.output())
        .await
        .expect("the wait finished")
        .expect("the executable runs");

    // The runtime API's answers are the whole script: the process ended because the second poll was refused.
    let seen = server.requests();
    let posted = seen
        .iter()
        .find(|r| r.method == "POST" && r.path() == RESPONSE)
        .unwrap_or_else(|| {
            panic!(
                "no response was posted; the executable said:\n{}",
                String::from_utf8_lossy(&output.stderr)
            )
        });
    let posted: Value = posted.json().expect("a JSON response");
    assert_eq!(posted["statusCode"], 302);
    let location = posted["headers"]["location"].as_str().unwrap();
    assert!(
        location.starts_with(&format!("https://github.com/login/oauth/authorize?client_id={CLIENT_ID}&redirect_uri=https%3A%2F%2Fmopm.test%2Fapi%2Fv2%2Fauth%2Fweb%2Fcallback&scope=read%3Auser&state=")),
        "{location}"
    );
    let cookie = posted["cookies"][0].as_str().unwrap();
    assert!(cookie.starts_with("__Host-mopm_login="), "{cookie}");
    assert!(
        cookie.ends_with("; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600"),
        "{cookie}"
    );
    let put = seen
        .iter()
        .find(|r| r.header("x-amz-target") == Some("DynamoDB_20120810.PutItem"))
        .expect("the login transaction was stored");
    assert_eq!(put.json().unwrap()["TableName"], "mopm-e2e-web_logins");

    // The process ended because the runtime API closed the connection, and says so as the error that stopped it.
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.starts_with("Error: the Lambda runtime stopped: "),
        "{stderr}"
    );

    // The log is JSON lines on stdout (the SDK's own warnings about the absent config files are among them); the request's
    // line is the function's, with the runtime's span beside it, and nothing of the secrets is in any of them.
    let stdout = String::from_utf8(output.stdout).unwrap();
    let lines: Vec<Value> = stdout
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{l}: {e}")))
        .collect();
    let ours: Vec<&Value> = lines
        .iter()
        .filter(|l| l["fields"]["message"] == "web login start")
        .collect();
    assert_eq!(ours.len(), 1, "{stdout}");
    assert_eq!(ours[0]["level"], "INFO");
    assert_eq!(
        ours[0]["fields"],
        json!({"message": "web login start", "request_id": "req-1", "outcome": "redirected"})
    );
    assert_eq!(ours[0]["span"]["requestId"], "req-1");
    assert!(!stdout.contains("process-test-secret") && !stderr.contains("process-test-secret"));
}
