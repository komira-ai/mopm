//! The function's front: routing, the edge check before everything, the API Gateway event in and out, and the log (one
//! line per request, asserted by exact equality, and never a secret).

use aws_lambda_events::apigw::ApiGatewayV2httpRequest;
use mopm_testing::fake_github::{FakeGitHub, GitHubUser, Outage};
use mopm_web::request::{Method, WebRequest};
use serde_json::{json, Value};

use crate::login::{CALLBACK_PATH, START_PATH};
use crate::test_support::*;

const ERROR_401: &str = r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#;
const ERROR_400_NO_ROUTE: &str = r#"{"error":{"code":"invalid_request","message":"The request is not valid: no such route.","hint":"Check the request against the API documentation; update mopm if it is old."}}"#;

/// The log line of an INFO event: `fields` are the JSON members after `message`, as the subscriber writes them.
fn line(message: &str, fields: &str) -> String {
    format!(r#"{{"level":"INFO","fields":{{"message":"{message}",{fields}}}}}"#)
}

fn start_line(outcome: &str, reason: Option<&str>) -> String {
    match reason {
        Some(reason) => line(
            "web login start",
            &format!(r#""request_id":"{REQUEST_ID}","outcome":"{outcome}","reason":"{reason}""#),
        ),
        None => line(
            "web login start",
            &format!(r#""request_id":"{REQUEST_ID}","outcome":"{outcome}""#),
        ),
    }
}

fn callback_line(outcome: &str, reason: Option<&str>, github_id: Option<u64>) -> String {
    let mut fields = format!(r#""request_id":"{REQUEST_ID}","outcome":"{outcome}""#);
    if let Some(reason) = reason {
        fields.push_str(&format!(r#","reason":"{reason}""#));
    }
    if let Some(id) = github_id {
        fields.push_str(&format!(r#","github_id":{id}"#));
    }
    line("web login callback", &fields)
}

#[test]
fn the_log_buffer_keeps_what_is_written_to_it_line_by_line() {
    use std::io::Write;
    let mut buf = LogBuf;
    let _capture = buf.capture();
    buf.write_all(b"one\ntwo\n").unwrap();
    buf.flush().unwrap();
    assert_eq!(buf.lines(), vec!["one", "two"]);
    assert_eq!(buf.text(), "one\ntwo");
}

#[tokio::test]
async fn a_start_logs_one_line_with_its_outcome() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    rig.start(Some("/tutorial/hello")).await;
    assert_eq!(log.lines(), vec![r#"{"level":"INFO","fields":{"message":"web login start","request_id":"req-7f3a2c19d0e4","outcome":"redirected"}}"#.to_string()]);
}

#[tokio::test]
async fn a_signed_in_callback_logs_one_line_with_the_github_id() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let log = LogBuf;
    let _guard = log.capture();
    rig.callback(&begun.callback_url, &begun.started, "").await;
    assert_eq!(log.lines(), vec![r#"{"level":"INFO","fields":{"message":"web login callback","request_id":"req-7f3a2c19d0e4","outcome":"signed_in","github_id":4242}}"#.to_string()]);
}

#[tokio::test]
async fn every_start_refusal_logs_its_code_and_the_check_that_refused() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    let no_edge = WebRequest::new(Method::Get, START_PATH, REQUEST_ID);
    let wrong_edge =
        WebRequest::new(Method::Get, START_PATH, REQUEST_ID).with_header("x-mopm-edge", "wrong");
    let cross_site = start_request(None).with_header("sec-fetch-site", "cross-site");
    for req in [no_edge, wrong_edge, cross_site] {
        rig.login.handle(&req).await;
    }
    let broken = Rig::with(
        &grants_without("web_logins", "dynamodb:PutItem"),
        true,
        Loopback,
    )
    .await;
    broken.start(None).await;
    assert_eq!(
        log.lines(),
        vec![
            start_line(
                "session_required",
                Some("not signed in: no single x-mopm-edge header")
            ),
            start_line(
                "session_required",
                Some("not signed in: the x-mopm-edge header is not the stage's value")
            ),
            // Two `Sec-Fetch-Site` headers: the one sent and the one the request already had.
            start_line("invalid_request", Some("not a top-level navigation")),
            start_line("unavailable", Some("the login transaction was not stored")),
        ]
    );
}

#[tokio::test]
async fn every_callback_failure_logs_its_code_the_check_that_refused_and_the_account_once_known() {
    let log = LogBuf;
    let _guard = log.capture();
    let mut expected = Vec::new();

    // The edge header, then no login cookie, then an error from GitHub.
    let rig = Rig::new().await;
    rig.login
        .handle(&WebRequest::new(Method::Get, CALLBACK_PATH, REQUEST_ID))
        .await;
    expected.push(callback_line(
        "session_required",
        Some("not signed in: no single x-mopm-edge header"),
        None,
    ));
    rig.login
        .handle(&callback_request(&callback_url("c", "s"), ""))
        .await;
    expected.push(callback_line(
        "login_expired",
        Some("no login cookie"),
        None,
    ));
    rig.login
        .handle(&callback_request(
            "https://mopm.test/cb?error=access_denied&state=s",
            "",
        ))
        .await;
    expected.push(callback_line(
        "access_denied",
        Some("GitHub reported access_denied"),
        None,
    ));
    rig.login
        .handle(&callback_request(
            "https://mopm.test/cb?error=server_error&state=s",
            "",
        ))
        .await;
    expected.push(callback_line(
        "unavailable",
        Some("GitHub reported an error"),
        None,
    ));

    // The rows: no code, an unknown transaction, a wrong state.
    let begun = rig.begin(alice(), None).await;
    expected.push(start_line("redirected", None));
    rig.login
        .handle(&callback_request(
            "https://mopm.test/cb?state=s",
            &login_cookie(&begun),
        ))
        .await;
    expected.push(callback_line(
        "login_expired",
        Some("code or state is missing or repeated"),
        None,
    ));
    rig.login
        .handle(&callback_request(
            &callback_url("c", "s"),
            &format!("{LOGIN}=nope"),
        ))
        .await;
    expected.push(callback_line(
        "login_expired",
        Some("no live login transaction"),
        None,
    ));
    rig.login
        .handle(&callback_request(
            &callback_url(&begun.code(), "wrong"),
            &login_cookie(&begun),
        ))
        .await;
    expected.push(callback_line(
        "login_expired",
        Some("state does not match the login transaction"),
        None,
    ));
    rig.login
        .handle(&callback_request(
            &callback_url("c", "s"),
            &format!("{LOGIN}=a; {LOGIN}=b"),
        ))
        .await;
    expected.push(callback_line(
        "login_expired",
        Some("more than one login cookie"),
        None,
    ));

    // GitHub down for the token exchange.
    let begun = rig.begin(alice(), None).await;
    expected.push(start_line("redirected", None));
    rig.github.set_outage(Some(Outage::Status(503)));
    rig.callback(&begun.callback_url, &begun.started, "").await;
    expected.push(callback_line(
        "unavailable",
        Some("GitHub's token endpoint answered with an error status"),
        None,
    ));
    rig.github.set_outage(Some(Outage::Drop));
    let begun2 = rig.begin(alice(), None).await;
    expected.push(start_line("redirected", None));
    rig.callback(&begun2.callback_url, &begun2.started, "")
        .await;
    expected.push(callback_line(
        "unavailable",
        Some("GitHub's token endpoint did not answer"),
        None,
    ));
    rig.github.set_outage(None);

    // Two-factor off: GitHub has said whose account it is.
    let off = rig
        .begin(
            GitHubUser::new(4242, "Alice-Dev").two_factor(Some(false)),
            None,
        )
        .await;
    expected.push(start_line("redirected", None));
    rig.callback(&off.callback_url, &off.started, "").await;
    expected.push(callback_line(
        "two_factor_required",
        Some("two-factor authentication is off on the account"),
        Some(4242),
    ));

    // A store that fails after GitHub answered.
    let broken = Rig::with(
        &grants_without("tokens", "dynamodb:PutItem"),
        true,
        Loopback,
    )
    .await;
    let begun = broken.begin(alice(), None).await;
    expected.push(start_line("redirected", None));
    broken
        .callback(&begun.callback_url, &begun.started, "")
        .await;
    expected.push(callback_line(
        "unavailable",
        Some("the session could not be stored"),
        Some(4242),
    ));

    assert_eq!(log.lines(), expected);
}

fn login_cookie(begun: &Begun) -> String {
    format!("{LOGIN}={}", begun.txn())
}

#[tokio::test]
async fn any_other_route_is_invalid_request_and_is_logged() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    let requests = [
        ("GET", "/api/v2/auth/web/session"),
        ("POST", START_PATH),
        ("POST", CALLBACK_PATH),
        ("GET", "/api/v2/auth/web/start/"),
        ("GET", "/API/V2/AUTH/WEB/START"),
        ("HEAD", START_PATH),
        ("GET", ""),
    ];
    for (method, path) in requests {
        let req = WebRequest::new(Method::parse(method), path, REQUEST_ID)
            .with_header("x-mopm-edge", EDGE);
        let resp = rig.login.handle(&req).await;
        assert_eq!(
            (resp.status, resp.body.as_str()),
            (400, ERROR_400_NO_ROUTE),
            "{method} {path}"
        );
        assert!(resp.set_cookies.is_empty());
    }
    let unknown = line(
        "web login request",
        &format!(
            r#""request_id":"{REQUEST_ID}","outcome":"invalid_request","reason":"no such route""#
        ),
    );
    assert_eq!(log.lines(), vec![unknown; 7]);
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
}

#[tokio::test]
async fn the_edge_check_comes_first_on_every_route() {
    let rig = Rig::new().await;
    for (method, path) in [
        ("GET", START_PATH),
        ("GET", CALLBACK_PATH),
        ("GET", "/elsewhere"),
        ("POST", START_PATH),
    ] {
        let resp = rig
            .login
            .handle(&WebRequest::new(Method::parse(method), path, REQUEST_ID))
            .await;
        assert_eq!(
            (resp.status, resp.body.as_str()),
            (401, ERROR_401),
            "{method} {path}"
        );
        assert!(resp.set_cookies.is_empty());
    }
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
}

#[tokio::test]
async fn no_secret_a_code_a_state_a_verifier_a_transaction_or_a_token_reaches_the_log() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), Some("/tutorial/hello"), "").await;
    let verifier = rig.dynamo.dump(WEB_LOGINS)[0]["code_verifier"]["S"]
        .as_str()
        .unwrap()
        .to_string();
    // The failures too: a wrong state, a replay, GitHub down, two-factor off.
    let replay = rig.callback(&done.callback_url, &done.started, "").await;
    let second = rig.begin(alice(), None).await;
    rig.login
        .handle(&callback_request(
            &callback_url(&second.code(), "wrong-state-value"),
            &login_cookie(&second),
        ))
        .await;
    let third = rig
        .begin(GitHubUser::new(4242, "Alice-Dev").two_factor(None), None)
        .await;
    rig.callback(&third.callback_url, &third.started, "").await;
    let fourth = rig.begin(alice(), None).await;
    rig.github.set_outage(Some(Outage::Status(500)));
    rig.callback(&fourth.callback_url, &fourth.started, "")
        .await;
    assert_eq!(replay.status, 303);

    let text = log.text();
    assert!(!text.is_empty());
    let mut secrets = vec![
        "fake-client-secret-0123456789".to_string(),
        EDGE.to_string(),
        verifier,
        done.session().unwrap(),
        FakeGitHub::token_for(&done.code()),
        "wrong-state-value".to_string(),
        "gho_".to_string(),
    ];
    for begun in [&done.begun, &second, &third, &fourth] {
        secrets.extend([begun.txn(), begun.state(), begun.code()]);
    }
    for secret in secrets {
        assert!(!text.contains(&secret), "{secret} is in the log:\n{text}");
    }
}

/// An HTTP API event of API Gateway for `path`, with `extra` merged over the defaults.
fn event(path: &str, extra: Value) -> ApiGatewayV2httpRequest {
    let mut e = json!({
        "version": "2.0",
        "routeKey": format!("GET {path}"),
        "rawPath": path,
        "rawQueryString": "",
        "headers": {
            "host": "api.mopm.test", "x-mopm-edge": EDGE,
            "sec-fetch-mode": "navigate", "sec-fetch-dest": "document", "sec-fetch-site": "none",
        },
        "requestContext": {
            "accountId": "example", "apiId": "api", "domainName": "api.mopm.test",
            "http": {"method": "GET", "path": path, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": REQUEST_ID, "routeKey": format!("GET {path}"), "stage": "$default", "timeEpoch": 1_795_000_000_000_i64
        },
        "isBase64Encoded": false
    });
    for (k, v) in extra.as_object().unwrap() {
        e[k] = v.clone();
    }
    serde_json::from_value(e).unwrap()
}

#[tokio::test]
async fn an_api_gateway_start_event_is_answered_as_an_api_gateway_response_with_the_cookie_in_cookies(
) {
    let rig = Rig::new().await;
    let resp = serde_json::to_value(
        rig.login
            .handle_event(event(
                START_PATH,
                json!({"rawQueryString": "return_to=%2Ftutorial%2Fhello"}),
            ))
            .await,
    )
    .unwrap();
    assert_eq!(resp["statusCode"], 302);
    let location = resp["headers"]["location"].as_str().unwrap().to_string();
    assert!(
        location.starts_with(&format!("{}/login/oauth/authorize?", rig.github.endpoint())),
        "{location}"
    );
    assert_eq!(resp["headers"]["x-mopm-request-id"], REQUEST_ID);
    assert_eq!(resp["headers"]["cache-control"], "no-store");
    let cookies = resp["cookies"].as_array().unwrap();
    assert_eq!(cookies.len(), 1);
    assert!(cookies[0]
        .as_str()
        .unwrap()
        .starts_with("__Host-mopm_login="));
    assert!(cookies[0]
        .as_str()
        .unwrap()
        .ends_with("; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600"));
    assert_eq!(
        rig.dynamo.dump(WEB_LOGINS)[0]["return_to"]["S"],
        "/tutorial/hello"
    );
}

#[tokio::test]
async fn an_api_gateway_callback_event_reads_the_login_cookie_from_the_cookies_array() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), Some("/search")).await;
    let query = begun.callback_url.split_once('?').unwrap().1.to_string();
    let cookies = json!([format!("{LOGIN}={}", begun.txn()), "theme=dark"]);
    let resp = serde_json::to_value(
        rig.login
            .handle_event(event(
                CALLBACK_PATH,
                json!({"rawQueryString": query, "cookies": cookies}),
            ))
            .await,
    )
    .unwrap();
    assert_eq!(resp["statusCode"], 303);
    assert_eq!(resp["headers"]["location"], "https://mopm.test/search");
    assert_eq!(resp["headers"]["referrer-policy"], "no-referrer");
    let set = resp["cookies"].as_array().unwrap();
    assert_eq!(set[0], CLEAR_LOGIN);
    assert!(set[1]
        .as_str()
        .unwrap()
        .starts_with("__Host-mopm_session=mopm_"));
}

#[tokio::test]
async fn an_event_whose_body_is_not_valid_base64_is_invalid_request_and_logged() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    let resp = serde_json::to_value(
        rig.login
            .handle_event(event(
                START_PATH,
                json!({"isBase64Encoded": true, "body": "***"}),
            ))
            .await,
    )
    .unwrap();
    assert_eq!(resp["statusCode"], 400);
    assert_eq!(resp["headers"]["x-mopm-request-id"], REQUEST_ID);
    assert!(resp["body"]
        .as_str()
        .unwrap()
        .contains(r#""code":"invalid_request""#));
    assert_eq!(
        log.lines(),
        vec![line(
            "web login request",
            &format!(
                r#""request_id":"{REQUEST_ID}","outcome":"invalid_request","reason":"the event is not a valid request""#
            )
        )]
    );
}

#[tokio::test]
async fn a_response_http_cannot_carry_is_the_fixed_internal_error_without_the_bad_request_id() {
    let log = LogBuf;
    let _guard = log.capture();
    let rig = Rig::new().await;
    let mut bad = event(START_PATH, json!({}));
    bad.request_context.request_id = Some("bad\nid".to_string());
    let resp = serde_json::to_value(rig.login.handle_event(bad).await).unwrap();
    assert_eq!(resp["statusCode"], 500);
    assert!(resp["headers"].get("x-mopm-request-id").is_none());
    assert_eq!(resp["headers"]["cache-control"], "no-store");
    assert_eq!(resp["headers"]["content-type"], "application/json");
    assert_eq!(
        resp["body"],
        r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#
    );
    assert_eq!(
        log.lines(),
        vec![
            r#"{"level":"INFO","fields":{"message":"web login start","request_id":"bad\nid","outcome":"redirected"}}"#.to_string(),
            r#"{"level":"ERROR","fields":{"message":"the response is not valid HTTP","request_id":"bad\nid","outcome":"internal_error"}}"#.to_string(),
        ]
    );
}

#[tokio::test]
async fn an_event_without_a_request_id_is_answered_with_an_empty_one() {
    let rig = Rig::new().await;
    let mut anonymous = event("/elsewhere", json!({}));
    anonymous.request_context.request_id = None;
    let resp = serde_json::to_value(rig.login.handle_event(anonymous).await).unwrap();
    assert_eq!(resp["statusCode"], 400);
    assert_eq!(resp["headers"]["x-mopm-request-id"], "");
}
