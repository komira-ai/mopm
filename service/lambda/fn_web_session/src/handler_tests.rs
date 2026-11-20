//! The two routes and the event entry against the memory auth store and a fixed clock.

use aws_lambda_events::apigw::ApiGatewayV2httpRequest;
use mopm_core::csrf::csrf_value;
use mopm_core::error::ErrorCode;
use mopm_ports::env::iso_millis;
use mopm_ports::types::TokenKind;
use mopm_web::request::Method;
use mopm_web::WebRequest;
use serde_json::json;

use crate::handler::{Answer, LOGOUT_PATH, SESSION_PATH};
use crate::test_support::*;

const CLEARED: &str = "__Host-mopm_session=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0";
const SESSION_REQUIRED: &str = r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#;
const CSRF_FAILED: &str = r#"{"error":{"code":"csrf_failed","message":"The request did not come from a page of the website.","hint":"Reload the page and try again."}}"#;
const AUTHORIZATION: &str = r#"{"error":{"code":"invalid_request","message":"The request is not valid: the website's routes take no Authorization header.","hint":"Check the request against the API documentation; update mopm if it is old."}}"#;
const NOT_FOUND: &str =
    r#"{"error":{"code":"route_not_found","message":"There is no such operation.","hint":"Check the request against the API documentation; update mopm if it is old."}}"#;
const INTERNAL: &str = r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#;

fn headers(a: &Answer) -> Vec<(&str, &str)> {
    a.response.headers.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect()
}

fn error_headers(a: &Answer, request_id: &str) -> bool {
    headers(a) == vec![("x-mopm-request-id", request_id), ("cache-control", "no-store"), ("content-type", "application/json")]
}

/// Asserts `a` is the error `code` with status `status` and the body `body`; returns the log message.
fn refused(a: &Answer, status: u16, code: ErrorCode, body: &str) -> String {
    let error = a.error.as_ref().expect("an error");
    assert_eq!(error.code, code, "{}", error.message);
    assert_eq!(a.response.status, status);
    assert_eq!(a.response.body, body);
    assert!(a.response.set_cookies.is_empty());
    assert!(error_headers(a, &a.response.headers[0].1));
    error.message.clone()
}

// ---- GET session -------------------------------------------------------------------------------

#[tokio::test]
async fn a_valid_cookie_answers_200_with_the_login_the_csrf_value_and_the_expiry() {
    let rig = live().await;
    let a = rig.handler.answer(&get(&cookie(&secret(1)))).await;
    assert!(a.error.is_none());
    assert_eq!(a.response.status, 200);
    assert_eq!(a.response.body, format!(r#"{{"csrf":"{}","expires_at":"{EXPIRES_AT}","login":"alice"}}"#, csrf_value(&secret(1))));
    assert_eq!(headers(&a), vec![("x-mopm-request-id", "req-1"), ("cache-control", "no-store"), ("content-type", "application/json")]);
    assert!(a.response.set_cookies.is_empty());
}

#[tokio::test]
async fn the_csrf_value_answered_is_the_one_a_logout_then_accepts() {
    let rig = live().await;
    let a = rig.handler.answer(&get(&cookie(&secret(1)))).await;
    let body: serde_json::Value = serde_json::from_str(&a.response.body).unwrap();
    let logout = without(post(&secret(1)), "x-mopm-csrf").with_header("X-Mopm-CSRF", body["csrf"].as_str().unwrap());
    assert_eq!(rig.handler.answer(&logout).await.response.status, 204);
}

#[tokio::test]
async fn a_session_that_is_not_usable_is_401_session_required() {
    let mut revoked = session_row(&secret(1), "tok-1", GITHUB_ID);
    revoked.revoked_at = Some(iso_millis(at(CREATED_MS + 1)));
    let live_row = session_row(&secret(1), "tok-1", GITHUB_ID);
    let cases = [
        ("expired at its expiry", rig(vec![live_row.clone()], CREATED_MS + SEVEN_DAYS_MS, None).await, get(&cookie(&secret(1))), "the session expired"),
        ("expired after its expiry", rig(vec![live_row.clone()], CREATED_MS + SEVEN_DAYS_MS + 1, None).await, get(&cookie(&secret(1))), "the session expired"),
        ("revoked", rig(vec![revoked], NOW_MS, None).await, get(&cookie(&secret(1))), "the session was revoked"),
        ("unknown token", rig(vec![live_row.clone()], NOW_MS, None).await, get(&cookie(&secret(2))), "no such session"),
        ("two cookies", rig(vec![live_row.clone()], NOW_MS, None).await, get(&format!("{0}; {0}", cookie(&secret(1)))), "two session cookies"),
        ("no cookie", rig(vec![live_row.clone()], NOW_MS, None).await, get("theme=dark"), "no session cookie"),
        ("not a token", rig(vec![live_row.clone()], NOW_MS, None).await, get("__Host-mopm_session=hello"), "the session cookie is not a token"),
        ("no edge header", rig(vec![live_row.clone()], NOW_MS, None).await, without(get(&cookie(&secret(1))), "x-mopm-edge"), "no single x-mopm-edge header"),
    ];
    for (what, rig, req, why) in cases {
        let a = rig.handler.answer(&req).await;
        assert_eq!(refused(&a, 401, ErrorCode::SessionRequired, SESSION_REQUIRED), format!("not signed in: {why}"), "{what}");
    }
}

#[tokio::test]
async fn a_wrong_edge_value_is_401_session_required() {
    let rig = live().await;
    let req = without(get(&cookie(&secret(1))), "x-mopm-edge").with_header("x-mopm-edge", "other");
    let a = rig.handler.answer(&req).await;
    assert_eq!(refused(&a, 401, ErrorCode::SessionRequired, SESSION_REQUIRED), "not signed in: the x-mopm-edge header is not the stage's value");
}

#[tokio::test]
async fn an_authorization_header_is_400_invalid_request_even_with_a_valid_cookie() {
    let rig = live().await;
    let a = rig.handler.answer(&get(&cookie(&secret(1))).with_header("Authorization", "Bearer x")).await;
    refused(&a, 400, ErrorCode::InvalidRequest, AUTHORIZATION);
    let a = rig.handler.answer(&post(&secret(1)).with_header("Authorization", "Bearer x")).await;
    refused(&a, 400, ErrorCode::InvalidRequest, AUTHORIZATION);
    assert!(rig.row("tok-1").revoked_at.is_none());
}

// ---- POST logout -------------------------------------------------------------------------------

#[tokio::test]
async fn a_logout_that_fails_a_csrf_check_is_403_csrf_failed_and_revokes_nothing() {
    let with_body = post(&secret(1)).with_body(b"{}");
    let cases = [
        ("a foreign Origin", post(&secret(1)).with_header("Origin", "https://evil.example")),
        ("no Origin", without(post(&secret(1)), "origin")),
        ("a cross-site fetch", post(&secret(1)).with_header("Sec-Fetch-Site", "cross-site")),
        ("a body that is not JSON", with_body.with_header("Content-Type", "text/plain")),
        ("no CSRF header", without(post(&secret(1)), "x-mopm-csrf")),
        ("a wrong CSRF value", without(post(&secret(1)), "x-mopm-csrf").with_header("X-Mopm-CSRF", &csrf_value(&secret(2)))),
    ];
    for (what, req) in cases {
        let rig = live().await;
        let a = rig.handler.answer(&req).await;
        refused(&a, 403, ErrorCode::CsrfFailed, CSRF_FAILED);
        assert!(rig.row("tok-1").revoked_at.is_none(), "{what}");
    }
}

#[tokio::test]
async fn a_logout_revokes_this_session_only_and_clears_the_cookie() {
    let mut api = session_row(&secret(3), "tok-api", GITHUB_ID);
    api.kind = TokenKind::Api;
    let mut cli = session_row(&secret(4), "tok-cli", GITHUB_ID);
    cli.kind = TokenKind::Api;
    cli.name = "cli".to_string();
    let rig = rig(vec![session_row(&secret(1), "tok-1", GITHUB_ID), session_row(&secret(2), "tok-2", GITHUB_ID), api.clone(), cli.clone()], NOW_MS, None).await;
    let others_before: Vec<_> = ["tok-2", "tok-api", "tok-cli"].iter().map(|id| rig.row(id)).collect();

    let a = rig.handler.answer(&post(&secret(1))).await;

    assert!(a.error.is_none());
    assert_eq!(a.response.status, 204);
    assert_eq!(a.response.body, "");
    assert_eq!(headers(&a), vec![("x-mopm-request-id", "req-2"), ("cache-control", "no-store")]);
    assert_eq!(a.response.set_cookies.iter().map(|c| c.as_str()).collect::<Vec<_>>(), vec![CLEARED]);
    assert_eq!(rig.row("tok-1").revoked_at.as_deref(), Some(iso_millis(at(NOW_MS)).as_str()));
    let others_after: Vec<_> = ["tok-2", "tok-api", "tok-cli"].iter().map(|id| rig.row(id)).collect();
    assert_eq!(others_before, others_after);
    // The other session of the same account still answers.
    let other = rig.handler.answer(&get(&cookie(&secret(2)))).await;
    assert_eq!(other.response.status, 200);
}

#[tokio::test]
async fn a_second_logout_with_the_revoked_cookie_is_401_and_keeps_the_first_revocation_time() {
    let rig = live().await;
    assert_eq!(rig.handler.answer(&post(&secret(1))).await.response.status, 204);
    let again = rig.handler.answer(&post(&secret(1))).await;
    assert_eq!(refused(&again, 401, ErrorCode::SessionRequired, SESSION_REQUIRED), "not signed in: the session was revoked");
    assert_eq!(rig.row("tok-1").revoked_at.as_deref(), Some(iso_millis(at(NOW_MS)).as_str()));
    let get_after = rig.handler.answer(&get(&cookie(&secret(1)))).await;
    assert_eq!(get_after.response.status, 401);
}

#[tokio::test]
async fn a_logout_without_the_edge_header_is_401_and_revokes_nothing() {
    let rig = live().await;
    let a = rig.handler.answer(&without(post(&secret(1)), "x-mopm-edge")).await;
    assert_eq!(refused(&a, 401, ErrorCode::SessionRequired, SESSION_REQUIRED), "not signed in: no single x-mopm-edge header");
    assert!(rig.row("tok-1").revoked_at.is_none());
}

// ---- routes ------------------------------------------------------------------------------------

#[tokio::test]
async fn any_other_path_or_method_is_404_route_not_found() {
    let rig = live().await;
    let cases = [
        (Method::Get, "/api/v2/auth/web/other"),
        (Method::Get, "/"),
        (Method::Get, LOGOUT_PATH),
        (Method::Post, SESSION_PATH),
        (Method::Other("PUT".to_string()), SESSION_PATH),
        (Method::Other("DELETE".to_string()), LOGOUT_PATH),
        (Method::Other("OPTIONS".to_string()), SESSION_PATH),
        (Method::Get, "/api/v2/auth/web/session/"),
    ];
    for (method, path) in cases {
        let name = match &method {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Other(n) => n.as_str(),
        };
        let req = WebRequest::new(method.clone(), path, "req-9");
        let a = rig.handler.answer(&req).await;
        assert_eq!(a.response.status, 404, "{name} {path}");
        assert_eq!(a.response.body, NOT_FOUND, "{name} {path}");
        assert_eq!(a.error.as_ref().unwrap().message, format!("no such operation: {name} {path}"));
        assert!(error_headers(&a, "req-9"));
    }
}

#[tokio::test]
async fn a_route_is_matched_before_any_check_and_a_valid_session_does_not_make_another_path_answer() {
    let rig = live().await;
    // The session's own request, sent to another path and then with another method.
    let req = WebRequest::new(Method::Get, "/api/v2/auth/web/whoami", "req-9").with_header("x-mopm-edge", EDGE).with_cookies(&cookie(&secret(1)));
    assert_eq!(rig.handler.answer(&req).await.response.status, 404);
    let req = WebRequest::new(Method::Post, SESSION_PATH, "req-9").with_header("x-mopm-edge", EDGE).with_cookies(&cookie(&secret(1)));
    assert_eq!(rig.handler.answer(&req).await.response.status, 404);
    assert!(rig.row("tok-1").last_used_at.is_none());
}

// ---- store faults ------------------------------------------------------------------------------

#[tokio::test]
async fn a_store_fault_at_any_step_is_500_internal_error_with_the_fault_in_the_log_only() {
    for call in ["get_token_by_hash", "get_user", "touch_token"] {
        let rig = rig(vec![session_row(&secret(1), "tok-1", GITHUB_ID)], NOW_MS, Some(call)).await;
        let a = rig.handler.answer(&get(&cookie(&secret(1)))).await;
        assert_eq!(refused(&a, 500, ErrorCode::InternalError, INTERNAL), "internal: infrastructure fault: the store is unreachable", "{call}");
    }
    let rig = rig(vec![session_row(&secret(1), "tok-1", GITHUB_ID)], NOW_MS, Some("revoke_token")).await;
    let a = rig.handler.answer(&post(&secret(1))).await;
    assert_eq!(refused(&a, 500, ErrorCode::InternalError, INTERNAL), "internal: infrastructure fault: the store is unreachable");
    assert!(rig.row("tok-1").revoked_at.is_none());
}

// ---- the event entry ---------------------------------------------------------------------------

fn event(extra: serde_json::Value) -> ApiGatewayV2httpRequest {
    let mut e = json!({
        "version": "2.0",
        "routeKey": "GET /api/v2/auth/web/session",
        "rawPath": SESSION_PATH,
        "rawQueryString": "",
        "headers": {"host": "api.mopm.dev", "x-mopm-edge": EDGE},
        "requestContext": {
            "accountId": "example",
            "apiId": "api",
            "domainName": "api.mopm.dev",
            "http": {"method": "GET", "path": SESSION_PATH, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": "req-7f3a2c19d0e4",
            "routeKey": "GET /api/v2/auth/web/session",
            "stage": "$default",
            "timeEpoch": 1_795_000_000_000_i64
        },
        "isBase64Encoded": false
    });
    for (k, v) in extra.as_object().unwrap() {
        e[k] = v.clone();
    }
    serde_json::from_value(e).unwrap()
}

#[tokio::test]
async fn a_session_event_is_answered_with_the_exact_event_response() {
    let rig = live().await;
    let out = rig.handler.handle_event(event(json!({"cookies": [cookie(&secret(1))]}))).await;
    let expected = format!(
        r#"{{"statusCode":200,"headers":{{"x-mopm-request-id":"req-7f3a2c19d0e4","cache-control":"no-store","content-type":"application/json"}},"multiValueHeaders":{{}},"body":"{{\"csrf\":\"{}\",\"expires_at\":\"{EXPIRES_AT}\",\"login\":\"alice\"}}","isBase64Encoded":false,"cookies":[]}}"#,
        csrf_value(&secret(1))
    );
    assert_eq!(serde_json::to_string(&out).unwrap(), expected);
}

#[tokio::test]
async fn a_logout_event_is_answered_204_with_the_cleared_cookie_in_the_cookies_array() {
    let rig = live().await;
    let e = event(json!({
        "routeKey": "POST /api/v2/auth/web/logout",
        "rawPath": LOGOUT_PATH,
        "headers": {"host": "api.mopm.dev", "x-mopm-edge": EDGE, "origin": SITE, "sec-fetch-site": "same-origin", "x-mopm-csrf": csrf_value(&secret(1))},
        "cookies": [cookie(&secret(1))],
        "requestContext": {
            "accountId": "example", "apiId": "api", "domainName": "api.mopm.dev",
            "http": {"method": "POST", "path": LOGOUT_PATH, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
            "requestId": "req-8", "routeKey": "POST /api/v2/auth/web/logout", "stage": "$default", "timeEpoch": 1_795_000_000_000_i64
        }
    }));
    let out = rig.handler.handle_event(e).await;
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            r#"{{"statusCode":204,"headers":{{"x-mopm-request-id":"req-8","cache-control":"no-store"}},"multiValueHeaders":{{}},"isBase64Encoded":false,"cookies":["{CLEARED}"]}}"#
        )
    );
    assert!(rig.row("tok-1").revoked_at.is_some());
}

#[tokio::test]
async fn an_event_with_a_body_that_is_not_base64_is_400_invalid_request() {
    let rig = live().await;
    let out = rig.handler.handle_event(event(json!({"body": "***", "isBase64Encoded": true}))).await;
    assert_eq!(out.status_code, 400);
    let text = serde_json::to_string(&out).unwrap();
    assert!(text.contains(r#"\"code\":\"invalid_request\""#), "{text}");
    assert!(text.contains(r#""x-mopm-request-id":"req-7f3a2c19d0e4""#), "{text}");
}

#[tokio::test]
async fn a_response_that_cannot_be_http_is_the_fixed_500_without_the_request_id_header() {
    let rig = live().await;
    let mut e = event(json!({"cookies": [cookie(&secret(1))]}));
    e.request_context.request_id = Some("bad\u{1}id".to_string());
    let out = rig.handler.handle_event(e).await;
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            r#"{{"statusCode":500,"headers":{{"cache-control":"no-store","content-type":"application/json"}},"multiValueHeaders":{{}},"body":{},"isBase64Encoded":false,"cookies":[]}}"#,
            serde_json::Value::String(INTERNAL.to_string())
        )
    );
}

#[tokio::test]
async fn an_event_for_another_route_is_404() {
    let rig = live().await;
    let out = rig.handler.handle_event(event(json!({"rawPath": "/api/v2/auth/web/other"}))).await;
    assert_eq!(out.status_code, 404);
}
