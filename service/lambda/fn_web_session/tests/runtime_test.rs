//! The process entry (`fn_web_session::runtime::main`) end to end: it reads its name from the environment, builds the
//! AWS clients from the SDK's own configuration (the endpoints below), starts, polls a fake Lambda runtime API for three
//! events (a session, a logout and a session again), posts each answer, and exits with a failure when the runtime API
//! answers its next poll with an error. Fake DynamoDB (with the role's grants), a fake Secrets Manager and the fake
//! runtime API are all on loopback, ports from the system. The only test of this file: it sets the process's environment.

use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;

use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, WEB_SESSION_GRANTS};
use mopm_testing::fake_http::{FakeHttp, Reply};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const STAGE_SETTINGS_ITEM: &str = include_str!("../../web/tests/fixtures/stage_settings_item.json");
const TOKENS: &str = include_str!("fixtures/web_session_tokens.json");
/// The entry reads the system clock, so the sessions it is given expire on 2100-01-01 (as the runtime API's deadline
/// below), not on the shared fixture's date, which the flow tests' injected clock is set before.
const EXPIRES_AT: (&str, &str) = ("4102444800", "2100-01-01T00:00:00.000Z");

/// The shared token fixture with every `expires_at` (number and ISO string) set to [`EXPIRES_AT`].
fn tokens() -> Vec<Value> {
    let mut items: Vec<Value> = serde_json::from_str(TOKENS).unwrap();
    for item in &mut items {
        item["expires_at"] = json!({"N": EXPIRES_AT.0});
        item["expires_at_iso"] = json!({"S": EXPIRES_AT.1});
    }
    items
}
const USERS: &str = include_str!("fixtures/web_session_users.json");

/// `TokenSecret::mint(&[1; SECRET_BYTES])`, the cookie of the session `tok-1`.
const SESSION_TOKEN: &str = "mopm_aeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaib";
/// The `edge-origin` secret of stage `t`.
const EDGE: &str = "edge-value-of-t";
/// `csrf_value` of `SESSION_TOKEN`.
const CSRF: &str = "xuAO3YCRSWXChUFi-Ro24qR01ucbsCFFPVBoM1_kkYs";
const CLEARED: &str = "__Host-mopm_session=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0";

fn event(method: &str, path: &str, request_id: &str, headers: Value) -> String {
    json!({
        "version": "2.0",
        "routeKey": format!("{method} {path}"),
        "rawPath": path,
        "rawQueryString": "",
        "cookies": [format!("__Host-mopm_session={SESSION_TOKEN}")],
        "headers": headers,
        "requestContext": {
            "accountId": "fake",
            "apiId": "api",
            "domainName": "api.beta.mopm.dev",
            "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": request_id,
            "routeKey": format!("{method} {path}"),
            "stage": "$default",
            "timeEpoch": 1_795_003_600_000_i64
        },
        "isBase64Encoded": false
    })
    .to_string()
}

/// The three events, in the order the fake runtime API sends them, with the id each is invoked under.
fn events() -> Vec<(&'static str, String)> {
    let session = |id| {
        event(
            "GET",
            "/api/v2/auth/web/session",
            id,
            json!({"host": "api.beta.mopm.dev", "x-mopm-edge": EDGE}),
        )
    };
    let logout = event(
        "POST",
        "/api/v2/auth/web/logout",
        "gw-2",
        json!({"host": "api.beta.mopm.dev", "x-mopm-edge": EDGE, "origin": "https://beta.mopm.dev", "sec-fetch-site": "same-origin", "x-mopm-csrf": CSRF}),
    );
    vec![
        ("inv-1", session("gw-1")),
        ("inv-2", logout),
        ("inv-3", session("gw-3")),
    ]
}

/// What the function must post for each event, byte for byte.
fn expected() -> Vec<String> {
    vec![
        format!(
            r#"{{"statusCode":200,"headers":{{"x-mopm-request-id":"gw-1","cache-control":"no-store","content-type":"application/json"}},"multiValueHeaders":{{}},"body":"{{\"csrf\":\"{CSRF}\",\"expires_at\":\"2100-01-01T00:00:00.000Z\",\"login\":\"alice\"}}","isBase64Encoded":false,"cookies":[]}}"#
        ),
        format!(r#"{{"statusCode":204,"headers":{{"x-mopm-request-id":"gw-2","cache-control":"no-store"}},"multiValueHeaders":{{}},"isBase64Encoded":false,"cookies":["{CLEARED}"]}}"#),
        r#"{"statusCode":401,"headers":{"x-mopm-request-id":"gw-3","cache-control":"no-store","content-type":"application/json"},"multiValueHeaders":{},"body":"{\"error\":{\"code\":\"session_required\",\"message\":\"You are not signed in to the website.\",\"hint\":\"Sign in with GitHub, then try again.\"}}","isBase64Encoded":false,"cookies":[]}"#.to_string(),
    ]
}

/// Reads one HTTP/1.1 request: the request line, and the body by its content length.
async fn read_request(stream: &mut TcpStream) -> (String, Vec<u8>) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        let n = stream.read(&mut chunk).await.unwrap();
        assert!(n > 0, "the runtime closed the connection inside a request");
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let len: usize = head
        .lines()
        .find_map(|l| {
            l.to_ascii_lowercase()
                .strip_prefix("content-length:")
                .map(|v| v.trim().parse().unwrap())
        })
        .unwrap_or(0);
    while buf.len() < head_end + len {
        let n = stream.read(&mut chunk).await.unwrap();
        assert!(n > 0, "the runtime closed the connection inside a body");
        buf.extend_from_slice(&chunk[..n]);
    }
    (
        head.lines().next().unwrap().to_string(),
        buf[head_end..head_end + len].to_vec(),
    )
}

async fn reply(stream: &mut TcpStream, status: &str, headers: &[(&str, String)], body: &str) {
    let mut out = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (k, v) in headers {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("\r\n");
    out.push_str(body);
    stream.write_all(out.as_bytes()).await.unwrap();
    stream.shutdown().await.unwrap();
}

/// The fake runtime API: the three events one poll each; when the third answer is posted and accepted it stops
/// listening, so the function's next poll fails. `posted` gets each (path, body) the function posts, before the post
/// is answered.
async fn runtime_api(listener: TcpListener, posted: mpsc::Sender<(String, Vec<u8>)>) {
    let polls = AtomicUsize::new(0);
    let mut answered = 0;
    let events = events();
    loop {
        let (mut stream, _) = listener.accept().await.unwrap();
        let (line, body) = read_request(&mut stream).await;
        if line.starts_with("GET /2018-06-01/runtime/invocation/next ") {
            let n = polls.fetch_add(1, Ordering::SeqCst);
            match events.get(n) {
                Some((id, payload)) => {
                    let headers = [
                        ("Content-Type", "application/json".to_string()),
                        ("Lambda-Runtime-Aws-Request-Id", id.to_string()),
                        ("Lambda-Runtime-Deadline-Ms", "4102444800000".to_string()),
                        (
                            "Lambda-Runtime-Invoked-Function-Arn",
                            "arn:aws:lambda:us-east-1:fake:function:mopm-t-web-session".to_string(),
                        ),
                    ];
                    reply(&mut stream, "200 OK", &headers, payload).await;
                }
                None => unreachable!("the function polls again only after the third answer"),
            }
        } else {
            posted.send((line, body)).unwrap();
            reply(&mut stream, "202 Accepted", &[], "").await;
            answered += 1;
            if answered == events.len() {
                return;
            }
        }
    }
}

struct Fakes {
    dynamo: FakeDynamo,
    secrets: FakeHttp,
    runtime_addr: std::net::SocketAddr,
    posted: mpsc::Receiver<(String, Vec<u8>)>,
}

/// Starts the three fakes on a runtime of their own thread (the entry under test makes its own runtime).
fn start_fakes() -> Fakes {
    let (ready_tx, ready_rx) = mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let dynamo = FakeDynamo::start(FakeConfig::web_session("t"));
            dynamo.seed(
                "mopm-t-config",
                serde_json::from_str(STAGE_SETTINGS_ITEM).unwrap(),
            );
            for item in serde_json::from_str::<Vec<Value>>(USERS).unwrap() {
                dynamo.seed("mopm-t-users", item);
            }
            for item in tokens() {
                dynamo.seed("mopm-t-tokens", item);
            }
            let secrets = FakeHttp::start(vec![Reply::new(200)
                .header("content-type", "application/x-amz-json-1.1")
                .body(json!({"Name": "mopm/t/edge-origin", "SecretString": EDGE}).to_string())]);
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let runtime_addr = listener.local_addr().unwrap();
            let (posted_tx, posted) = mpsc::channel();
            ready_tx
                .send(Fakes {
                    dynamo,
                    secrets,
                    runtime_addr,
                    posted,
                })
                .unwrap();
            runtime_api(listener, posted_tx).await;
            // The fakes outlive the entry: the test reads them after it returns.
            std::future::pending::<()>().await;
        });
    });
    ready_rx.recv().unwrap()
}

#[test]
fn the_entry_serves_a_session_a_logout_and_a_session_again_and_fails_when_the_runtime_api_does() {
    let fakes = start_fakes();
    let scratch =
        std::env::temp_dir().join(format!("fn_web_session_runtime_{}", std::process::id()));
    let vars = [
        ("AWS_LAMBDA_FUNCTION_NAME", "mopm-t-web-session".to_string()),
        ("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST".to_string()),
        ("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128".to_string()),
        (
            "AWS_LAMBDA_LOG_GROUP_NAME",
            "/aws/lambda/mopm-t-web-session".to_string(),
        ),
        ("AWS_LAMBDA_LOG_STREAM_NAME", "stream".to_string()),
        ("AWS_LAMBDA_RUNTIME_API", fakes.runtime_addr.to_string()),
        ("AWS_REGION", "us-east-1".to_string()),
        ("AWS_ACCESS_KEY_ID", "AKIDFAKE".to_string()),
        ("AWS_SECRET_ACCESS_KEY", "fakesecret".to_string()),
        ("AWS_ENDPOINT_URL_DYNAMODB", fakes.dynamo.endpoint()),
        ("AWS_ENDPOINT_URL_SECRETS_MANAGER", fakes.secrets.endpoint()),
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

    let exit = fn_web_session::runtime::main();

    assert!(
        exit == ExitCode::FAILURE,
        "the entry exits non-zero when the runtime API ends"
    );
    let posted: Vec<(String, Vec<u8>)> = fakes.posted.try_iter().collect();
    let expected = expected();
    assert_eq!(posted.len(), expected.len(), "{posted:?}");
    for (i, (line, body)) in posted.iter().enumerate() {
        assert_eq!(
            line,
            &format!(
                "POST /2018-06-01/runtime/invocation/inv-{}/response HTTP/1.1",
                i + 1
            )
        );
        assert_eq!(
            String::from_utf8(body.clone()).unwrap(),
            expected[i],
            "answer {}",
            i + 1
        );
    }

    // The logout revoked the session's row and no other; every call was one the role's grants allow.
    let tokens = fakes.dynamo.dump("mopm-t-tokens");
    let revoked: Vec<&str> = tokens
        .iter()
        .filter(|t| t.get("revoked_at").is_some())
        .map(|t| t["id"]["S"].as_str().unwrap())
        .collect();
    assert_eq!(revoked, vec!["tok-1"]);
    let grants: Value = serde_json::from_str(WEB_SESSION_GRANTS).unwrap();
    for r in fakes.dynamo.requests() {
        let table = r.body["TableName"]
            .as_str()
            .unwrap()
            .strip_prefix("mopm-t-")
            .unwrap()
            .to_string();
        let allowed = grants[&table]["actions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == &Value::String(format!("dynamodb:{}", r.operation)));
        assert!(allowed, "{} on {table}", r.operation);
        assert!(r.signed);
    }
    assert_eq!(fakes.secrets.requests().len(), 1);
}
