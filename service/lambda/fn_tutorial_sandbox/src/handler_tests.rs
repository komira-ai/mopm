//! The function's answers to a request: what it refuses before E2B is asked, what it sends E2B, what it answers and logs
//! when E2B gives a sandbox, and the contract's error examples.

use mopm_testing::fake_e2b::{CreateAnswer, Sandbox};
use mopm_testing::fake_http::Seen;
use serde_json::{json, Value};

use crate::test_support::*;

const NO_STORE: &str = "no-store";
const INVALID_HINT: &str =
    "Check the request against the API documentation; update mopm if it is old.";

fn headers(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(n, v)| (n.to_string(), v.to_string()))
        .collect()
}

/// A refusal: its answer, its one log line, and no request to E2B.
async fn assert_refused(req: Req, status: i64, code: &str, message: &str, hint: &str) -> Rig {
    let rig = rig(Spec::default()).await;
    let got = rig.send(&req).await;
    assert_eq!(got.status, status, "{got:?}");
    assert_eq!(got.body, error_body(code, message, hint));
    assert_eq!(
        got.headers,
        headers(&[
            ("cache-control", NO_STORE),
            ("content-type", "application/json"),
            ("x-mopm-request-id", REQUEST_ID)
        ])
    );
    assert!(got.cookies.is_empty());
    assert_eq!(
        rig.last_line(),
        format!(
            r#"{{"event":"tutorial_sandbox","outcome":"refused","reason":"{code}","request_id":"{REQUEST_ID}"}}"#
        )
    );
    assert_eq!(rig.e2b.requests().len(), 0, "E2B was asked");
    assert_eq!(
        rig.secrets.reads("mopm/beta/e2b"),
        1,
        "the key is read at the cold start only"
    );
    rig
}

const NOT_SIGNED_IN: (&str, &str, &str) = (
    "session_required",
    "You are not signed in to the website.",
    "Sign in with GitHub, then try again.",
);
const NOT_FROM_THE_SITE: (&str, &str, &str) = (
    "csrf_failed",
    "The request did not come from a page of the website.",
    "Reload the page and try again.",
);

#[tokio::test]
async fn a_request_without_a_session_cookie_is_401_session_required() {
    let (code, message, hint) = NOT_SIGNED_IN;
    let rig = assert_refused(Req::signed_in().without_cookie(), 401, code, message, hint).await;
    assert_eq!(rig.operations(), ["GetItem"], "only the settings were read");
}

#[tokio::test]
async fn a_request_without_the_edge_header_or_with_another_value_is_401_session_required() {
    let (code, message, hint) = NOT_SIGNED_IN;
    assert_refused(
        Req::signed_in().without_header("x-mopm-edge"),
        401,
        code,
        message,
        hint,
    )
    .await;
    let rig = assert_refused(
        Req::signed_in().header("x-mopm-edge", "not-the-stage's-value"),
        401,
        code,
        message,
        hint,
    )
    .await;
    assert_eq!(rig.operations(), ["GetItem"]);
}

#[tokio::test]
async fn a_wrong_csrf_value_origin_or_fetch_site_is_403_csrf_failed() {
    let (code, message, hint) = NOT_FROM_THE_SITE;
    let rig = assert_refused(
        Req::signed_in().header("x-mopm-csrf", "another-sessions-value"),
        403,
        code,
        message,
        hint,
    )
    .await;
    assert_eq!(
        rig.operations(),
        ["GetItem"],
        "a forged POST reads no session row"
    );
    assert_refused(
        Req::signed_in().without_header("x-mopm-csrf"),
        403,
        code,
        message,
        hint,
    )
    .await;
    assert_refused(
        Req::signed_in().header("origin", "https://evil.example"),
        403,
        code,
        message,
        hint,
    )
    .await;
    assert_refused(
        Req::signed_in().without_header("origin"),
        403,
        code,
        message,
        hint,
    )
    .await;
    assert_refused(
        Req::signed_in().header("sec-fetch-site", "cross-site"),
        403,
        code,
        message,
        hint,
    )
    .await;
    assert_refused(
        Req::signed_in().header("sec-fetch-site", "same-site"),
        403,
        code,
        message,
        hint,
    )
    .await;
}

#[tokio::test]
async fn an_authorization_header_is_400_invalid_request() {
    let message = "The request is not valid: the website's routes take no Authorization header.";
    let rig = assert_refused(
        Req::signed_in().header("authorization", "Bearer mopm_token"),
        400,
        "invalid_request",
        message,
        INVALID_HINT,
    )
    .await;
    assert_eq!(rig.operations(), ["GetItem"]);
}

#[tokio::test]
async fn a_request_with_a_body_is_400_invalid_request_after_the_session_is_checked() {
    let message = "The request is not valid: the request takes no body.";
    assert_refused(
        Req::signed_in().with_body(r#"{"template":"base"}"#),
        400,
        "invalid_request",
        message,
        INVALID_HINT,
    )
    .await;
    // The checks come first: the same body without a session is the session's refusal.
    let (code, message, hint) = NOT_SIGNED_IN;
    assert_refused(
        Req::signed_in().without_cookie().with_body("{}"),
        401,
        code,
        message,
        hint,
    )
    .await;
}

#[tokio::test]
async fn another_path_or_method_is_400_invalid_request() {
    let message = "The request is not valid: no such route.";
    for (method, path) in [
        ("GET", "/api/v2/tutorial/sandbox"),
        ("POST", "/api/v2/tutorial/sandboxes"),
        ("POST", "/"),
        ("DELETE", "/api/v2/tutorial/sandbox"),
    ] {
        let mut req = Req::signed_in();
        req.method = method.to_string();
        req.path = path.to_string();
        let rig = assert_refused(req, 400, "invalid_request", message, INVALID_HINT).await;
        assert_eq!(rig.operations(), ["GetItem"], "{method} {path}");
    }
}

// ---- a sandbox --------------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_signed_in_post_gets_a_sandbox_with_the_exact_answer_and_log_line() {
    let rig = rig(Spec::default()).await;
    let got = rig.send(&Req::signed_in()).await;
    assert_eq!(got.status, 201);
    assert_eq!(
        got.headers,
        headers(&[
            ("cache-control", NO_STORE),
            ("content-type", "application/json"),
            ("x-mopm-request-id", REQUEST_ID)
        ])
    );
    assert_eq!(
        got.body,
        r#"{"access_token":"envd-token-0123456789abcdef","domain":"e2b.app","envd_version":"0.2.4","expires_at":"2026-11-20T10:30:00Z","sandbox_id":"itest0sandbox0000001"}"#
    );
    assert!(got.cookies.is_empty());
    assert_eq!(
        rig.lines(),
        [format!(
            r#"{{"event":"tutorial_sandbox","github_id":42,"outcome":"created","request_id":"{REQUEST_ID}","sandbox_id":"itest0sandbox0000001"}}"#
        )]
    );
    assert_eq!(
        rig.operations(),
        ["GetItem", "GetItem", "GetItem", "UpdateItem"],
        "the settings, the session row, its account, and the touch"
    );
}

fn create_of(rig: &Rig) -> Seen {
    let mut creates = rig.e2b.create_requests();
    assert_eq!(creates.len(), 1);
    creates.remove(0)
}

#[tokio::test]
async fn the_create_request_is_the_design_notes_body_and_the_key_is_only_in_x_api_key() {
    let rig = rig(Spec::default()).await;
    rig.send(&Req::signed_in()).await;
    let create = create_of(&rig);
    assert_eq!(
        create.json(),
        Some(json!({
            "templateID": "mopm-tutorial-beta",
            "timeout": 1800,
            "allow_internet_access": false,
            "autoPause": false,
            "network": {"allowPublicTraffic": false},
            "metadata": {"mopm_stage": "beta", "mopm_request": REQUEST_ID},
        }))
    );
    assert_eq!(
        create.json().expect("JSON")["allow_internet_access"],
        Value::Bool(false)
    );
    assert_eq!(create.header("x-api-key"), Some(E2B_KEY));
    let mut names: Vec<&str> = create.headers.iter().map(|(n, _)| n.as_str()).collect();
    names.sort_unstable();
    assert_eq!(
        names,
        ["content-length", "content-type", "host", "x-api-key"],
        "the request carries these headers and no others"
    );
    assert_eq!(create.header("content-type"), Some("application/json"));
    for (name, value) in &create.headers {
        assert!(
            name == "x-api-key" || !value.contains(E2B_KEY),
            "the key is in {name}"
        );
    }
    assert!(!create.target.contains(E2B_KEY));
    assert!(!String::from_utf8_lossy(&create.body).contains(E2B_KEY));
    // Nothing of the browser's request goes to E2B.
    let secret = session_secret();
    let sent = format!(
        "{:?}{}",
        create.headers,
        String::from_utf8_lossy(&create.body)
    );
    for private in [secret.expose(), EDGE, "alice"] {
        assert!(!sent.contains(private), "{private} was sent to E2B");
    }
    assert_eq!(
        (create.method.as_str(), create.path()),
        ("POST", "/v2/sandboxes")
    );
}

#[tokio::test]
async fn a_null_domain_is_the_settings_and_the_end_is_the_clock_plus_the_settings_timeout() {
    let config = item_with(|item| {
        item["e2b_domain"] = json!({"S": "sandboxes.example.test"});
        item["sandbox_timeout_s"] = json!({"N": "90"});
    });
    let spec = Spec {
        config: Some(config),
        script: vec![CreateAnswer::Created(Sandbox::example().null_domain())],
        ..Spec::default()
    };
    let rig = rig(spec).await;
    let got = rig.send(&Req::signed_in()).await;
    assert_eq!(got.status, 201);
    let body = got.json();
    assert_eq!(body["domain"], "sandboxes.example.test");
    assert_eq!(body["expires_at"], "2026-11-20T10:01:30Z");
    assert_eq!(create_of(&rig).json().expect("JSON")["timeout"], 90);
}

#[tokio::test]
async fn two_requests_by_the_same_user_both_get_a_sandbox() {
    let rig = rig(Spec::default()).await;
    assert_eq!(rig.send(&Req::signed_in()).await.status, 201);
    let mut again = Req::signed_in();
    again.id = "req-second".to_string();
    assert_eq!(rig.send(&again).await.status, 201);
    assert_eq!(rig.e2b.create_requests().len(), 2);
    let second = rig.e2b.create_requests().remove(1).json().expect("JSON");
    assert_eq!(second["metadata"]["mopm_request"], "req-second");
    assert_eq!(rig.lines().len(), 2);
    assert!(rig
        .lines()
        .iter()
        .all(|l| l.contains(r#""outcome":"created""#)));
}

// ---- the contract's error examples ------------------------------------------------------------------------------

const CONTRACT: &str = include_str!("../../../../tests/contract/api-v2/tutorial-sandbox.json");

/// The spec and request that make the contract case `name`.
fn scenario(name: &str) -> (Spec, Req) {
    let reply = |status: u16| TestHttp::answering(status, "{}");
    match name {
        "a sandbox request from a signed-out browser is refused as session_required" => (Spec::default(), Req::signed_in().without_cookie()),
        "a sandbox request with a wrong CSRF value is refused as csrf_failed" => (Spec::default(), Req::signed_in().header("x-mopm-csrf", "wrong")),
        "a sandbox request with a body is refused as invalid_request" => (Spec::default(), Req::signed_in().with_body(r#"{"template":"base"}"#)),
        "a sandbox request with an Authorization header is refused as invalid_request" => (Spec::default(), Req::signed_in().header("authorization", "Bearer mopm_token")),
        "a sandbox request while E2B does not answer is refused as tutorial_unavailable with Retry-After" => (Spec { http: Some(reply(503)), ..Spec::default() }, Req::signed_in()),
        other => panic!("the contract has a case this test does not make: {other}"),
    }
}

#[tokio::test]
async fn every_error_case_of_the_contract_is_answered_with_its_status_headers_and_body() {
    let contract: Value = serde_json::from_str(CONTRACT).expect("the contract is JSON");
    let mut answered = 0;
    for case in contract["cases"].as_array().expect("cases") {
        let response = &case["response"];
        if case.get("expect").is_some() || response["status"].as_i64().expect("a status") < 400 {
            continue;
        }
        let name = case["name"].as_str().expect("a name");
        let (spec, req) = scenario(name);
        let rig = rig(spec).await;
        let got = rig.send(&req).await;
        assert_eq!(
            got.status,
            response["status"].as_i64().expect("a status"),
            "{name}"
        );
        assert_eq!(got.json(), response["body"], "{name}");
        for (header, value) in response["headers"].as_object().expect("headers") {
            assert_eq!(got.header(header), value.as_str(), "{name}: {header}");
        }
        answered += 1;
    }
    assert_eq!(answered, 5);
}
