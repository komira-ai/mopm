//! `create_sandbox` against the fake E2B API (real HTTP on loopback) and against a scripted `HttpClient`, with a fixed
//! clock: the request it sends, the grant it reads, and every way of failing being `Unavailable`.

use std::sync::Mutex;

use mopm_ports::http::HttpError;
use mopm_testing::env::FixedClock;
use mopm_testing::fake_e2b::{CreateAnswer, FakeE2b, Sandbox};
use mopm_testing::fake_http::{FakeHttp, Reply};
use mopm_testing::scripted_http::ScriptedHttp;
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::*;

const KEY: &str = "e2b_test_key_0123456789";
const TOKEN: &str = "envd-token-0123456789abcdef";
/// 2026-11-20T10:00:00.750Z: a send time with a fraction of a second.
const SENT_MS: i64 = 1_795_168_800_750;

/// An `HttpClient` over plain HTTP/1.1 on loopback, for the fakes of `mopm_testing` (which close every connection after
/// one answer). The request goes out exactly as built; the timeout is not waited on by any test.
struct Loopback;

impl HttpClient for Loopback {
    async fn send(&self, req: HttpRequest) -> PortResult<HttpResponse> {
        let rest = req
            .url
            .strip_prefix("http://")
            .expect("a fake's http:// URL");
        let (addr, target) = rest.split_at(rest.find('/').expect("a path"));
        let mut head = format!(
            "{} {target} HTTP/1.1\r\nHost: {addr}\r\n",
            req.method.as_str()
        );
        for (k, v) in &req.headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str(&format!("Content-Length: {}\r\n\r\n", req.body.len()));
        let mut stream = TcpStream::connect(addr)
            .await
            .expect("a connection to the fake");
        stream
            .write_all(head.as_bytes())
            .await
            .expect("the head is written");
        stream
            .write_all(&req.body)
            .await
            .expect("the body is written");
        let mut raw = Vec::new();
        stream
            .read_to_end(&mut raw)
            .await
            .expect("the answer is read");
        let end = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("an answer head");
        let text = String::from_utf8(raw[..end].to_vec()).expect("a UTF-8 head");
        let mut lines = text.lines();
        let status = lines
            .next()
            .and_then(|l| l.split(' ').nth(1))
            .and_then(|s| s.parse().ok())
            .expect("a status");
        let headers = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
            .collect();
        Ok(HttpResponse {
            status,
            headers,
            body: raw[end + 4..].to_vec(),
        })
    }
}

fn settings(api_base: &str) -> Settings {
    Settings {
        api_base: api_base.to_string(),
        ..Settings::new("beta", "mopm-tutorial-test")
    }
}

fn clock() -> FixedClock {
    FixedClock::at_millis(SENT_MS)
}

async fn create<H: HttpClient>(http: &H, settings: &Settings) -> Result<Grant, E2bError> {
    create_sandbox(http, &ApiKey::new(KEY), settings, "req-1", &clock()).await
}

/// The section 4 body for `settings` and request `req-1`.
fn section_4_body(timeout: u32) -> Value {
    json!({
        "templateID": "mopm-tutorial-test",
        "timeout": timeout,
        "allow_internet_access": false,
        "autoPause": false,
        "network": {"allowPublicTraffic": false},
        "metadata": {"mopm_stage": "beta", "mopm_request": "req-1"}
    })
}

fn example_grant() -> Grant {
    Grant {
        sandbox_id: "itest0sandbox0000001".into(),
        access_token: AccessToken(TOKEN.into()),
        envd_version: "0.2.4".into(),
        domain: "e2b.app".into(),
        expires_at: "2026-11-20T10:30:00Z".into(),
    }
}

fn reply(status: u16, body: &str) -> Result<HttpResponse, HttpError> {
    Ok(HttpResponse {
        status,
        headers: vec![],
        body: body.as_bytes().to_vec(),
    })
}

fn created_json(sandbox: Value) -> String {
    sandbox.to_string()
}

async fn scripted(answer: Result<HttpResponse, HttpError>) -> Result<Grant, E2bError> {
    create(&ScriptedHttp::new(vec![answer]), &settings(E2B_API)).await
}

fn unavailable(why: Unavailable) -> Result<Grant, E2bError> {
    Err(E2bError::Unavailable(why))
}

#[tokio::test]
async fn the_fake_sees_section_4_s_body_and_the_key_only_in_x_api_key() {
    let fake = FakeE2b::start(KEY, vec![]);
    create(&Loopback, &settings(&fake.endpoint()))
        .await
        .expect("a grant");
    let seen = fake.create_requests();
    assert_eq!(seen.len(), 1);
    let seen = &seen[0];
    assert_eq!(
        (seen.method.as_str(), seen.target.as_str()),
        ("POST", "/v2/sandboxes")
    );
    assert_eq!(seen.json(), Some(section_4_body(1800)));
    assert_eq!(
        seen.json().expect("JSON")["allow_internet_access"],
        Value::Bool(false)
    );
    assert_eq!(seen.header("x-api-key"), Some(KEY));
    assert_eq!(seen.header("content-type"), Some("application/json"));
    let with_key: Vec<&str> = seen
        .headers
        .iter()
        .filter(|(_, v)| v.contains(KEY))
        .map(|(k, _)| k.as_str())
        .collect();
    assert_eq!(with_key, ["x-api-key"]);
    assert!(!String::from_utf8_lossy(&seen.body).contains(KEY));
    assert!(!seen.target.contains(KEY));
}

#[tokio::test]
async fn the_request_is_a_post_to_e2b_s_create_path_with_the_8_second_timeout() {
    let http = ScriptedHttp::new(vec![reply(
        201,
        &created_json(Sandbox::example().to_json()),
    )]);
    create(&http, &Settings::new("beta", "mopm-tutorial-test"))
        .await
        .expect("a grant");
    let sent = http.requests();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].timeout, Duration::from_secs(8));
    assert_eq!(sent[0].method, Method::Post);
    assert_eq!(sent[0].url, "https://api.e2b.app/v2/sandboxes");
    assert_eq!(
        sent[0].headers,
        [
            ("Content-Type".to_string(), "application/json".to_string()),
            ("X-API-Key".to_string(), KEY.to_string())
        ]
    );
    let body: Value = serde_json::from_slice(&sent[0].body).expect("a JSON body");
    assert_eq!(body, section_4_body(1800));
}

#[tokio::test]
async fn a_created_sandbox_maps_to_the_grant() {
    let fake = FakeE2b::start(KEY, vec![CreateAnswer::Created(Sandbox::example())]);
    assert_eq!(
        create(&Loopback, &settings(&fake.endpoint())).await,
        Ok(example_grant())
    );
}

#[tokio::test]
async fn a_null_absent_or_empty_domain_is_the_stage_s_domain() {
    let fake = FakeE2b::start(
        KEY,
        vec![CreateAnswer::Created(Sandbox::example().null_domain())],
    );
    let mut stage = settings(&fake.endpoint());
    stage.e2b_domain = "sandbox.example.test".into();
    let filled = Grant {
        domain: "sandbox.example.test".into(),
        ..example_grant()
    };
    assert_eq!(create(&Loopback, &stage).await, Ok(filled.clone()));

    let mut absent = Sandbox::example().to_json();
    absent.as_object_mut().expect("an object").remove("domain");
    let mut empty = Sandbox::example().to_json();
    empty["domain"] = json!("");
    for answer in [absent, empty] {
        let http = ScriptedHttp::new(vec![reply(201, &created_json(answer.clone()))]);
        assert_eq!(
            create(
                &http,
                &Settings {
                    api_base: E2B_API.into(),
                    ..stage.clone()
                }
            )
            .await,
            Ok(filled.clone()),
            "{answer}"
        );
    }
}

#[tokio::test]
async fn expires_at_is_the_send_time_plus_the_stage_s_timeout_to_the_second() {
    let fake = FakeE2b::start(KEY, vec![]);
    let mut stage = settings(&fake.endpoint());
    stage.timeout_s = 600;
    let grant = create(&Loopback, &stage).await.expect("a grant");
    // 10:00:00.750 + 600 s, the fraction dropped.
    assert_eq!(grant.expires_at, "2026-11-20T10:10:00Z");
    assert_eq!(fake.create_requests()[0].json(), Some(section_4_body(600)));

    stage.timeout_s = 0;
    let grant = create(&Loopback, &stage).await.expect("a grant");
    assert_eq!(grant.expires_at, "2026-11-20T10:00:00Z");
}

/// A clock that moves an hour on each read and records how many requests the client had sent when it was read.
struct SteppingClock<'a> {
    http: &'a ScriptedHttp,
    reads: Mutex<Vec<(Timestamp, usize)>>,
}

impl Clock for SteppingClock<'_> {
    fn now(&self) -> Timestamp {
        let mut reads = self.reads.lock().expect("an unpoisoned lock");
        let hours = i64::try_from(reads.len()).expect("a few reads");
        let now =
            Timestamp::from_millisecond(SENT_MS + hours * 3_600_000).expect("a representable time");
        reads.push((now, self.http.requests().len()));
        now
    }
}

#[tokio::test]
async fn the_clock_is_read_once_before_the_request_is_sent() {
    let http = ScriptedHttp::new(vec![reply(
        201,
        &created_json(Sandbox::example().to_json()),
    )]);
    let clock = SteppingClock {
        http: &http,
        reads: Mutex::new(vec![]),
    };
    let grant = create_sandbox(
        &http,
        &ApiKey::new(KEY),
        &settings(E2B_API),
        "req-1",
        &clock,
    )
    .await;
    assert_eq!(grant, Ok(example_grant()));
    let reads = clock.reads.lock().expect("an unpoisoned lock").clone();
    assert_eq!(
        reads,
        [(Timestamp::from_millisecond(SENT_MS).expect("a time"), 0)]
    );
}

#[tokio::test]
async fn a_sandbox_without_an_access_token_is_unavailable() {
    let fake = FakeE2b::start(
        KEY,
        vec![CreateAnswer::Created(
            Sandbox::example().without_access_token(),
        )],
    );
    assert_eq!(
        create(&Loopback, &settings(&fake.endpoint())).await,
        unavailable(Unavailable::NoAccessToken)
    );

    let mut null = Sandbox::example().to_json();
    null["envdAccessToken"] = Value::Null;
    let mut empty = Sandbox::example().to_json();
    empty["envdAccessToken"] = json!("");
    for answer in [null, empty] {
        assert_eq!(
            scripted(reply(201, &created_json(answer.clone()))).await,
            unavailable(Unavailable::NoAccessToken),
            "{answer}"
        );
    }
}

#[tokio::test]
async fn e2b_s_refusals_and_failures_are_unavailable_with_their_status() {
    let fake = FakeE2b::start(
        KEY,
        vec![
            CreateAnswer::concurrency_limit(),
            CreateAnswer::Refused {
                status: 400,
                message: "bad template".into(),
            },
            CreateAnswer::server_error(500),
            CreateAnswer::server_error(503),
        ],
    );
    let stage = settings(&fake.endpoint());
    for status in [429, 400, 500, 503] {
        assert_eq!(
            create(&Loopback, &stage).await,
            unavailable(Unavailable::Status(status))
        );
    }
    // A key E2B does not know: 401.
    let refused = create_sandbox(
        &Loopback,
        &ApiKey::new("another_key"),
        &stage,
        "req-1",
        &clock(),
    )
    .await;
    assert_eq!(refused, unavailable(Unavailable::Status(401)));
}

#[tokio::test]
async fn only_a_2xx_answer_is_read_as_a_sandbox() {
    let body = created_json(Sandbox::example().to_json());
    for status in [200, 201, 299] {
        assert_eq!(
            scripted(reply(status, &body)).await,
            Ok(example_grant()),
            "{status}"
        );
    }
    for status in [199, 300, 302, 404] {
        assert_eq!(
            scripted(reply(status, &body)).await,
            unavailable(Unavailable::Status(status)),
            "{status}"
        );
    }
}

#[tokio::test]
async fn an_answer_that_is_not_a_sandbox_s_json_is_unavailable() {
    let fake = FakeHttp::start(vec![Reply::new(201)
        .header("Content-Type", "text/html")
        .body("<html>busy</html>")]);
    let got = create(&Loopback, &settings(&fake.endpoint())).await;
    assert_eq!(
        got,
        unavailable(Unavailable::Malformed { line: 1, column: 1 })
    );

    let cases = [
        ("", Unavailable::Malformed { line: 1, column: 0 }),
        (
            "{\"sandboxID\": \"a\"",
            Unavailable::Malformed {
                line: 1,
                column: 17,
            },
        ),
        // A JSON string holding the key: the error keeps only the place, not the text.
        (
            &format!("\"{KEY}\"") as &str,
            Unavailable::Malformed {
                line: 1,
                column: 25,
            },
        ),
        (
            "{\"sandboxID\": 7, \"envdVersion\": \"0.2.4\"}",
            Unavailable::Malformed {
                line: 1,
                column: 15,
            },
        ),
        ("[]", Unavailable::Malformed { line: 1, column: 2 }),
    ];
    for (body, why) in cases {
        assert_eq!(scripted(reply(201, body)).await, unavailable(why), "{body}");
    }
}

#[tokio::test]
async fn an_answer_without_a_sandbox_id_or_agent_version_is_unavailable() {
    for (member, value) in [
        ("sandboxID", None),
        ("sandboxID", Some("")),
        ("envdVersion", None),
        ("envdVersion", Some("")),
    ] {
        let mut answer = Sandbox::example().to_json();
        match value {
            None => {
                answer.as_object_mut().expect("an object").remove(member);
            }
            Some(v) => answer[member] = json!(v),
        }
        assert_eq!(
            scripted(reply(201, &created_json(answer.clone()))).await,
            unavailable(Unavailable::Missing(member)),
            "{answer}"
        );
    }
}

#[tokio::test]
async fn no_answer_and_a_client_failure_are_unavailable() {
    for failure in [HttpFailure::Timeout, HttpFailure::Connect, HttpFailure::Tls] {
        let detail = "api.e2b.app:443 after 8s".to_string();
        let got = scripted(Err(HttpError {
            failure,
            detail: detail.clone(),
        }))
        .await;
        assert_eq!(got, unavailable(Unavailable::NoAnswer { failure, detail }));
    }
    // A client that fails for a reason of its own (here, the script has no answer left).
    let got = create(&ScriptedHttp::new(vec![]), &settings(E2B_API)).await;
    let why =
        "infrastructure fault: no scripted answer left for POST https://api.e2b.app/v2/sandboxes";
    assert_eq!(got, unavailable(Unavailable::Client(why.into())));
}

#[tokio::test]
async fn a_clock_past_the_last_representable_end_sends_nothing() {
    let late = FixedClock::at_millis(Timestamp::MAX.as_second() * 1000);
    let http = ScriptedHttp::new(vec![]);
    let got = create_sandbox(&http, &ApiKey::new(KEY), &settings(E2B_API), "req-1", &late).await;
    assert_eq!(got, unavailable(Unavailable::ExpiryOutOfRange));
    assert_eq!(http.requests(), []);
    // The same through the loopback client: nothing reaches the fake.
    let fake = FakeE2b::start(KEY, vec![]);
    let got = create_sandbox(
        &Loopback,
        &ApiKey::new(KEY),
        &settings(&fake.endpoint()),
        "req-1",
        &late,
    )
    .await;
    assert_eq!(got, unavailable(Unavailable::ExpiryOutOfRange));
    assert!(fake.requests().is_empty());
}

#[test]
fn settings_new_is_e2b_s_api_with_the_default_timeout_and_domain() {
    assert_eq!(
        Settings::new("prod", "tmpl-1"),
        Settings {
            api_base: "https://api.e2b.app".into(),
            stage: "prod".into(),
            template_id: "tmpl-1".into(),
            timeout_s: 1800,
            e2b_domain: "e2b.app".into(),
        }
    );
}

#[test]
fn the_token_is_exposed_only_by_name() {
    assert_eq!(example_grant().access_token.expose(), TOKEN);
}

#[test]
fn no_debug_or_message_shows_the_key_or_the_token() {
    assert_eq!(format!("{:?}", ApiKey::new(KEY)), "ApiKey(<redacted>)");
    assert_eq!(
        format!("{:#?}", ApiKey::new(KEY)),
        "ApiKey(\n    <redacted>,\n)"
    );
    assert_eq!(
        format!("{:?}", AccessToken(TOKEN.into())),
        "AccessToken(<redacted>)"
    );
    assert_eq!(
        format!("{:?}", example_grant()),
        "Grant { sandbox_id: \"itest0sandbox0000001\", access_token: AccessToken(<redacted>), envd_version: \"0.2.4\", \
         domain: \"e2b.app\", expires_at: \"2026-11-20T10:30:00Z\" }"
    );
    let errors = [
        (
            Unavailable::Status(429),
            "E2B is unavailable: E2B answered 429",
            "Unavailable(Status(429))",
        ),
        (
            Unavailable::NoAnswer {
                failure: HttpFailure::Timeout,
                detail: "api.e2b.app:443".into(),
            },
            "E2B is unavailable: no answer: timed out: api.e2b.app:443",
            "Unavailable(NoAnswer { failure: Timeout, detail: \"api.e2b.app:443\" })",
        ),
        (
            Unavailable::Client("infrastructure fault: x".into()),
            "E2B is unavailable: the HTTP client failed: infrastructure fault: x",
            "Unavailable(Client(\"infrastructure fault: x\"))",
        ),
        (
            Unavailable::Malformed {
                line: 1,
                column: 25,
            },
            "E2B is unavailable: the answer is not a sandbox (JSON line 1, column 25)",
            "Unavailable(Malformed { line: 1, column: 25 })",
        ),
        (
            Unavailable::Missing("sandboxID"),
            "E2B is unavailable: the answer has no sandboxID",
            "Unavailable(Missing(\"sandboxID\"))",
        ),
        (
            Unavailable::NoAccessToken,
            "E2B is unavailable: the sandbox has no access token",
            "Unavailable(NoAccessToken)",
        ),
        (
            Unavailable::ExpiryOutOfRange,
            "E2B is unavailable: the sandbox's end is past the last representable time",
            "Unavailable(ExpiryOutOfRange)",
        ),
    ];
    for (why, display, debug) in errors {
        let e = E2bError::from(why);
        assert_eq!(
            (e.to_string(), format!("{e:?}")),
            (display.to_string(), debug.to_string())
        );
    }
}

#[tokio::test]
async fn the_errors_of_real_failures_show_neither_the_key_nor_the_token() {
    // Each failure as the function returns it, the key in the request and the token in the answer where there is one.
    let mut no_version = Sandbox::example().to_json();
    no_version
        .as_object_mut()
        .expect("an object")
        .remove("envdVersion");
    let failures = [
        reply(
            401,
            &format!("{{\"code\":401,\"message\":\"Invalid API key {KEY}\"}}"),
        ),
        reply(201, &format!("\"{KEY} {TOKEN}\"")),
        reply(
            201,
            &format!("{{\"sandboxID\": 7, \"envdAccessToken\": \"{TOKEN}\"}}"),
        ),
        reply(201, &created_json(no_version)),
        Err(HttpError {
            failure: HttpFailure::Timeout,
            detail: "no answer in 8s".into(),
        }),
    ];
    let expected = [
        (
            "E2B is unavailable: E2B answered 401",
            "Unavailable(Status(401))",
        ),
        (
            "E2B is unavailable: the answer is not a sandbox (JSON line 1, column 53)",
            "Unavailable(Malformed { line: 1, column: 53 })",
        ),
        (
            "E2B is unavailable: the answer is not a sandbox (JSON line 1, column 15)",
            "Unavailable(Malformed { line: 1, column: 15 })",
        ),
        (
            "E2B is unavailable: the answer has no envdVersion",
            "Unavailable(Missing(\"envdVersion\"))",
        ),
        (
            "E2B is unavailable: no answer: timed out: no answer in 8s",
            "Unavailable(NoAnswer { failure: Timeout, detail: \"no answer in 8s\" })",
        ),
    ];
    for (answer, (display, debug)) in failures.into_iter().zip(expected) {
        let e = scripted(answer).await.expect_err("a failure");
        assert_eq!(
            (e.to_string(), format!("{e:?}")),
            (display.to_string(), debug.to_string())
        );
    }
}
