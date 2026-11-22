//! `SessionAuth` against the memory auth store, recorded (`test_support::Recording`), and a fixed clock.

use jiff::Timestamp;
use mopm_core::csrf::csrf_value;
use mopm_core::error::ErrorCode;
use mopm_core::token::{web_session_fields, TokenSecret, SECRET_BYTES};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::iso_millis;
use mopm_ports::types::{TokenKind, TokenRecord};
use mopm_testing::env::FixedClock;
use mopm_testing::memory_auth::MemoryAuthStore;
use mopm_testing::memory_publish::MemorySecrets;

use super::*;
use crate::request::Method;
use crate::settings::parse_function_name;
use crate::test_support::{Calls, Recording};

const SITE: &str = "https://mopm.dev";
const EDGE: &str = "edge-value-of-beta";
/// When the session was created (in November of the year this crate was written).
const CREATED_MS: i64 = 1_795_000_000_000;
/// An hour later: the session is live.
const NOW_MS: i64 = CREATED_MS + 3_600_000;
const SEVEN_DAYS_MS: i64 = 7 * 24 * 3_600_000;
const GITHUB_ID: u64 = 42;

fn secret(fill: u8) -> TokenSecret {
    TokenSecret::mint(&[fill; SECRET_BYTES])
}

fn at(ms: i64) -> Timestamp {
    Timestamp::from_millisecond(ms).unwrap()
}

/// The row a web login writes for `secret` at `CREATED_MS` (mopm_core's fields, mopm_ports' record).
fn session_row(secret: &TokenSecret) -> TokenRecord {
    let f = web_session_fields(secret, at(CREATED_MS)).unwrap();
    TokenRecord {
        id: "tok-1".to_string(),
        kind: TokenKind::Session,
        github_id: Some(GITHUB_ID),
        name: f.name.to_string(),
        hash: f.hash,
        prefix: f.prefix,
        scopes: Vec::new(),
        packages: Vec::new(),
        all_current: false,
        version: None,
        fresh_until: Some(f.fresh_until),
        created_at: f.created_at,
        expires_at: f.expires_at,
        revoked_at: None,
        last_used_at: None,
        issued_to: None,
    }
}

struct Rig {
    auth: SessionAuth<Recording, FixedClock>,
    calls: Calls,
}

impl Rig {
    fn calls(&self) -> Vec<&'static str> {
        self.calls.lock().unwrap().clone()
    }
}

/// A store holding `alice` and `row` (none when `row` is `None`), the clock at `now_ms`, `fail` failing.
async fn rig(row: Option<TokenRecord>, now_ms: i64, fail: Option<&'static str>) -> Rig {
    let store = MemoryAuthStore::new();
    store
        .upsert_user(GITHUB_ID, "alice", &iso_millis(at(CREATED_MS)), Some(true))
        .await
        .unwrap();
    if let Some(row) = row {
        store.put_token(&row).await.unwrap();
    }
    let (store, calls) = Recording::new(store, fail);
    let secrets = MemorySecrets::new();
    secrets.set("mopm/beta/edge-origin", EDGE);
    let stage = parse_function_name(Some(std::ffi::OsStr::new("mopm-beta-web-session")))
        .unwrap()
        .stage;
    let edge = EdgeCheck::load(&secrets, &stage).await.unwrap();
    Rig {
        auth: SessionAuth::new(
            edge,
            CsrfCheck::new(SITE),
            store,
            FixedClock::at_millis(now_ms),
        ),
        calls,
    }
}

async fn live() -> Rig {
    rig(Some(session_row(&secret(1))), NOW_MS, None).await
}

fn get(cookies: &str) -> WebRequest {
    WebRequest::new(Method::Get, "/api/v2/auth/web/session", "req-1")
        .with_header("x-mopm-edge", EDGE)
        .with_cookies(cookies)
}

fn cookie(s: &TokenSecret) -> String {
    format!("__Host-mopm_session={}", s.expose())
}

/// A `POST` from the site with `s`'s cookie and CSRF value.
fn post(s: &TokenSecret) -> WebRequest {
    WebRequest::new(Method::Post, "/api/v2/auth/web/logout", "req-2")
        .with_header("x-mopm-edge", EDGE)
        .with_header("Origin", SITE)
        .with_header("Sec-Fetch-Site", "same-origin")
        .with_header("X-Mopm-CSRF", &csrf_value(s))
        .with_cookies(&cookie(s))
}

/// The request with every field named `name` removed.
fn without(req: WebRequest, name: &str) -> WebRequest {
    let mut out = WebRequest {
        headers: Default::default(),
        ..req.clone()
    };
    for (n, v) in req
        .headers
        .iter()
        .filter(|(n, _)| !n.eq_ignore_ascii_case(name))
    {
        out.headers.push(n, v);
    }
    out
}

fn refused(r: Result<WebSession, RegistryError>, code: ErrorCode) -> String {
    let err = r.unwrap_err();
    assert_eq!(err.code, code, "{}", err.message);
    err.message
}

// ---- a valid session ---------------------------------------------------------------------------

#[tokio::test]
async fn a_valid_cookie_answers_the_session_and_its_account() {
    let rig = live().await;
    let s = rig.auth.session(&get(&cookie(&secret(1)))).await.unwrap();
    assert_eq!(s.secret, secret(1));
    assert_eq!(s.token.id, "tok-1");
    assert_eq!(s.user.github_id, GITHUB_ID);
    assert_eq!(s.user.handle, "alice");
    assert_eq!(
        rig.calls(),
        vec!["get_token_by_hash", "get_user", "touch_token"]
    );
}

#[tokio::test]
async fn a_used_session_is_marked_used_now() {
    let rig = live().await;
    rig.auth.session(&get(&cookie(&secret(1)))).await.unwrap();
    let after = rig.auth.session(&get(&cookie(&secret(1)))).await.unwrap();
    assert_eq!(
        after.token.last_used_at.as_deref(),
        Some(iso_millis(at(NOW_MS)).as_str())
    );
}

#[tokio::test]
async fn a_valid_post_with_its_csrf_value_answers_the_session() {
    let rig = live().await;
    let s = rig.auth.session_for_post(&post(&secret(1))).await.unwrap();
    assert_eq!(s.user.handle, "alice");
    assert_eq!(
        rig.calls(),
        vec!["get_token_by_hash", "get_user", "touch_token"]
    );
}

#[tokio::test]
async fn the_session_cookie_is_found_among_others() {
    let rig = live().await;
    let req = get(&format!(
        "theme=dark; {}; __Host-mopm_login=txn",
        cookie(&secret(1))
    ));
    assert!(rig.auth.session(&req).await.is_ok());
}

// ---- refusals of the session itself ------------------------------------------------------------

#[tokio::test]
async fn a_session_is_live_until_the_millisecond_before_it_expires() {
    let last = rig(
        Some(session_row(&secret(1))),
        CREATED_MS + SEVEN_DAYS_MS - 1,
        None,
    )
    .await;
    assert!(last.auth.session(&get(&cookie(&secret(1)))).await.is_ok());
    let expired = rig(
        Some(session_row(&secret(1))),
        CREATED_MS + SEVEN_DAYS_MS,
        None,
    )
    .await;
    assert_eq!(
        refused(
            expired.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session expired"
    );
    assert_eq!(expired.calls(), vec!["get_token_by_hash"]);
}

#[tokio::test]
async fn an_expiry_that_cannot_be_read_counts_as_expired() {
    let mut row = session_row(&secret(1));
    row.expires_at = "never".to_string();
    let rig = rig(Some(row), NOW_MS, None).await;
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session expired"
    );
}

#[tokio::test]
async fn a_revoked_session_is_session_required() {
    let mut row = session_row(&secret(1));
    row.revoked_at = Some(iso_millis(at(CREATED_MS + 1)));
    let rig = rig(Some(row), NOW_MS, None).await;
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session was revoked"
    );
    assert_eq!(rig.calls(), vec!["get_token_by_hash"]);
}

#[tokio::test]
async fn an_unknown_token_is_session_required() {
    let rig = live().await;
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(2)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: no such session"
    );
    assert_eq!(rig.calls(), vec!["get_token_by_hash"]);
}

/// An authenticator over a store that answers `row` to every token lookup, whatever the hash.
async fn answering(row: TokenRecord) -> (SessionAuth<Recording, FixedClock>, Calls) {
    let memory = MemoryAuthStore::new();
    memory
        .upsert_user(GITHUB_ID, "alice", &iso_millis(at(CREATED_MS)), Some(true))
        .await
        .unwrap();
    let (store, calls) = Recording::new(memory, None);
    let secrets = MemorySecrets::new();
    secrets.set("mopm/beta/edge-origin", EDGE);
    let stage = parse_function_name(Some(std::ffi::OsStr::new("mopm-beta-web-session")))
        .unwrap()
        .stage;
    let edge = EdgeCheck::load(&secrets, &stage).await.unwrap();
    (
        SessionAuth::new(
            edge,
            CsrfCheck::new(SITE),
            store.answering_tokens_with(row),
            FixedClock::at_millis(NOW_MS),
        ),
        calls,
    )
}

#[tokio::test]
async fn a_row_whose_hash_is_not_the_cookies_is_no_session() {
    // A store that matched on something other than the hash answers secret(2)'s row for secret(1)'s cookie.
    let (auth, calls) = answering(session_row(&secret(2))).await;
    assert_eq!(
        refused(
            auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: no such session"
    );
    assert_eq!(*calls.lock().unwrap(), vec!["get_token_by_hash"]);
    // The same kind of store answering the cookie's own row admits it, so the hash comparison alone refused above.
    let (auth, _) = answering(session_row(&secret(1))).await;
    assert_eq!(
        auth.session(&get(&cookie(&secret(1))))
            .await
            .unwrap()
            .token
            .hash,
        secret(1).hash()
    );
}

#[tokio::test]
async fn an_api_or_oidc_token_in_the_cookie_is_session_required() {
    for kind in [TokenKind::Api, TokenKind::Oidc] {
        let mut row = session_row(&secret(1));
        row.kind = kind;
        let rig = rig(Some(row), NOW_MS, None).await;
        assert_eq!(
            refused(
                rig.auth.session(&get(&cookie(&secret(1)))).await,
                ErrorCode::SessionRequired
            ),
            "not signed in: the token is not a session"
        );
        assert_eq!(rig.calls(), vec!["get_token_by_hash"]);
    }
}

#[tokio::test]
async fn a_session_without_an_account_is_session_required() {
    let mut row = session_row(&secret(1));
    row.github_id = None;
    let rig = rig(Some(row), NOW_MS, None).await;
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session names no account"
    );
}

#[tokio::test]
async fn a_session_whose_account_is_gone_is_session_required_and_not_touched() {
    let mut row = session_row(&secret(1));
    row.github_id = Some(7);
    let rig = rig(Some(row), NOW_MS, None).await;
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session's account does not exist"
    );
    assert_eq!(rig.calls(), vec!["get_token_by_hash", "get_user"]);
}

// ---- refusals before any store call ------------------------------------------------------------

#[tokio::test]
async fn no_cookie_is_session_required_without_a_store_call() {
    let rig = live().await;
    assert_eq!(
        refused(
            rig.auth.session(&get("theme=dark")).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: no session cookie"
    );
    let mut no_cookie = post(&secret(1));
    no_cookie.cookies.clear();
    assert_eq!(
        refused(
            rig.auth.session_for_post(&no_cookie).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: no session cookie"
    );
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn two_session_cookies_are_session_required_without_a_store_call() {
    let rig = live().await;
    let both = format!("{}; {}", cookie(&secret(1)), cookie(&secret(1)));
    assert_eq!(
        refused(
            rig.auth.session(&get(&both)).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: two session cookies"
    );
    let mut two = post(&secret(1));
    two.cookies
        .extend(crate::request::parse_cookie_header(&cookie(&secret(2))));
    assert_eq!(
        refused(
            rig.auth.session_for_post(&two).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: two session cookies"
    );
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn a_cookie_that_is_not_a_token_is_session_required_without_a_store_call() {
    let rig = live().await;
    // The failure message names the case, never the cookie: the last one holds a token.
    for (case, bad) in [
        ("empty", "__Host-mopm_session=".to_owned()),
        ("short", "__Host-mopm_session=mopm_short".to_owned()),
        ("Bearer", "__Host-mopm_session=Bearer".to_owned()),
        (
            "quoted token",
            format!("__Host-mopm_session=\"{}\"", secret(1).expose()),
        ),
    ] {
        assert_eq!(
            refused(
                rig.auth.session(&get(&bad)).await,
                ErrorCode::SessionRequired
            ),
            "not signed in: the session cookie is not a token",
            "{case}"
        );
    }
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn a_missing_or_wrong_edge_header_is_refused_before_any_store_call() {
    let rig = live().await;
    let valid_get = get(&cookie(&secret(1)));
    let missing = without(valid_get.clone(), "x-mopm-edge");
    let wrong = without(valid_get, "x-mopm-edge").with_header("x-mopm-edge", "edge-value-of-prod");
    assert_eq!(
        refused(rig.auth.session(&missing).await, ErrorCode::SessionRequired),
        "not signed in: no single x-mopm-edge header"
    );
    assert_eq!(
        refused(rig.auth.session(&wrong).await, ErrorCode::SessionRequired),
        "not signed in: the x-mopm-edge header is not the stage's value"
    );
    let post_missing = without(post(&secret(1)), "x-mopm-edge");
    assert_eq!(
        refused(
            rig.auth.session_for_post(&post_missing).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: no single x-mopm-edge header"
    );
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn an_authorization_header_is_invalid_request_even_with_a_valid_cookie() {
    let rig = live().await;
    let bearer = format!("Bearer {}", secret(1).expose());
    assert_eq!(
        refused(
            rig.auth
                .session(&get(&cookie(&secret(1))).with_header("Authorization", &bearer))
                .await,
            ErrorCode::InvalidRequest
        ),
        "The request is not valid: the website's routes take no Authorization header."
    );
    assert_eq!(
        refused(
            rig.auth
                .session(&get("").with_header("authorization", ""))
                .await,
            ErrorCode::InvalidRequest
        ),
        "The request is not valid: the website's routes take no Authorization header."
    );
    assert_eq!(
        refused(
            rig.auth
                .session_for_post(&post(&secret(1)).with_header("Authorization", &bearer))
                .await,
            ErrorCode::InvalidRequest
        ),
        "The request is not valid: the website's routes take no Authorization header."
    );
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn the_edge_check_comes_before_the_authorization_check() {
    let rig = live().await;
    let req = without(get(""), "x-mopm-edge").with_header("Authorization", "Bearer x");
    assert_eq!(
        refused(rig.auth.session(&req).await, ErrorCode::SessionRequired),
        "not signed in: no single x-mopm-edge header"
    );
}

#[tokio::test]
async fn each_failed_csrf_check_is_csrf_failed_without_a_store_call() {
    let rig = live().await;
    let s = secret(1);
    let cases = [
        (
            without(post(&s), "origin").with_header("Origin", "https://evil.example"),
            "CSRF check failed: Origin is not the site's",
        ),
        (
            without(post(&s), "sec-fetch-site").with_header("Sec-Fetch-Site", "cross-site"),
            "CSRF check failed: Sec-Fetch-Site is not same-origin",
        ),
        (
            post(&s)
                .with_body(b"{}")
                .with_header("Content-Type", "text/plain"),
            "CSRF check failed: a body that is not application/json",
        ),
        (
            without(post(&s), "x-mopm-csrf"),
            "CSRF check failed: no single X-Mopm-CSRF header",
        ),
        (
            without(post(&s), "x-mopm-csrf").with_header("X-Mopm-CSRF", &csrf_value(&secret(2))),
            "CSRF check failed: X-Mopm-CSRF is not the session's value",
        ),
    ];
    for (req, why) in cases {
        assert_eq!(
            refused(rig.auth.session_for_post(&req).await, ErrorCode::CsrfFailed),
            why
        );
    }
    assert!(rig.calls().is_empty());
}

#[tokio::test]
async fn a_get_needs_no_csrf_value() {
    let rig = live().await;
    assert!(rig.auth.session(&get(&cookie(&secret(1)))).await.is_ok());
}

#[tokio::test]
async fn a_post_with_a_json_body_and_its_csrf_value_passes() {
    let rig = live().await;
    let req = post(&secret(1))
        .with_body(b"{}")
        .with_header("Content-Type", "application/json");
    assert!(rig.auth.session_for_post(&req).await.is_ok());
}

#[tokio::test]
async fn a_good_csrf_value_does_not_save_a_revoked_session() {
    let mut row = session_row(&secret(1));
    row.revoked_at = Some(iso_millis(at(CREATED_MS)));
    let rig = rig(Some(row), NOW_MS, None).await;
    assert_eq!(
        refused(
            rig.auth.session_for_post(&post(&secret(1))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session was revoked"
    );
}

// ---- last_used_at ------------------------------------------------------------------------------

async fn calls_with_last_used(last_used_at: Option<String>) -> Vec<&'static str> {
    let mut row = session_row(&secret(1));
    row.last_used_at = last_used_at;
    let rig = rig(Some(row), NOW_MS, None).await;
    rig.auth.session(&get(&cookie(&secret(1)))).await.unwrap();
    rig.calls()
}

#[tokio::test]
async fn a_session_used_less_than_a_minute_ago_is_not_written_again() {
    assert_eq!(
        calls_with_last_used(Some(iso_millis(at(NOW_MS - 59_999)))).await,
        vec!["get_token_by_hash", "get_user"]
    );
    assert_eq!(
        calls_with_last_used(Some(iso_millis(at(NOW_MS)))).await,
        vec!["get_token_by_hash", "get_user"]
    );
}

#[tokio::test]
async fn a_session_used_a_minute_ago_or_never_or_at_an_unreadable_time_is_written() {
    let touched = vec!["get_token_by_hash", "get_user", "touch_token"];
    assert_eq!(
        calls_with_last_used(Some(iso_millis(at(NOW_MS - 60_000)))).await,
        touched
    );
    assert_eq!(calls_with_last_used(None).await, touched);
    assert_eq!(
        calls_with_last_used(Some("yesterday".to_string())).await,
        touched
    );
}

// ---- a store that fails ------------------------------------------------------------------------

#[tokio::test]
async fn a_store_fault_at_any_step_is_internal_error() {
    for (call, before) in [
        ("get_token_by_hash", vec![]),
        ("get_user", vec!["get_token_by_hash"]),
        ("touch_token", vec!["get_token_by_hash", "get_user"]),
    ] {
        let rig = rig(Some(session_row(&secret(1))), NOW_MS, Some(call)).await;
        let message = refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::InternalError,
        );
        assert_eq!(
            message, "internal: infrastructure fault: the store is unreachable",
            "{call}"
        );
        let mut expected = before;
        expected.push(call);
        assert_eq!(rig.calls(), expected, "{call}");
    }
}

#[tokio::test]
async fn debug_of_a_session_hides_the_token() {
    let rig = live().await;
    let s = rig.auth.session(&get(&cookie(&secret(1)))).await.unwrap();
    let shown = format!("{s:?}");
    assert!(!shown.contains(secret(1).expose()), "{shown}");
}

#[tokio::test]
async fn the_authenticator_hands_out_its_store_and_clock() {
    let rig = live().await;
    assert_eq!(rig.auth.clock().now(), at(NOW_MS));
    rig.auth
        .store()
        .revoke_token(&session_row(&secret(1)).hash, "2026-11-19T12:00:00.000Z")
        .await
        .unwrap();
    assert_eq!(
        refused(
            rig.auth.session(&get(&cookie(&secret(1)))).await,
            ErrorCode::SessionRequired
        ),
        "not signed in: the session was revoked"
    );
}
