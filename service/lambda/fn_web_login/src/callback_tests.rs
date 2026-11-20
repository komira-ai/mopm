//! `GET /api/v2/auth/web/callback`: whole sign-ins against a fake GitHub and a fake DynamoDB held to the function
//! role's grants, and every way a sign-in stops.

use std::collections::BTreeSet;

use mopm_ports::http::{HttpError, HttpFailure, HttpResponse};
use mopm_testing::fake_github::{GitHubUser, Grant, Outage, TokenError};
use mopm_testing::scripted_http::ScriptedHttp;
use mopm_web::response::WebResponse;
use serde_json::{json, Value};

use crate::login::sha256_hex;
use crate::test_support::*;

const SESSION_COOKIE_ATTRIBUTES: &str = "; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800";

/// A callback request with `cookies`, for GitHub's `code` and `state`.
async fn call(
    rig: &Rig<impl mopm_ports::http::HttpClient>,
    code: &str,
    state: &str,
    cookies: &str,
) -> WebResponse {
    rig.login
        .handle(&callback_request(&callback_url(code, state), cookies))
        .await
}

fn login_cookie_of(begun: &Begun) -> String {
    format!("{LOGIN}={}", begun.txn())
}

fn is_session_token(token: &str) -> bool {
    token.strip_prefix("mopm_").is_some_and(|body| {
        body.len() == 40
            && body
                .bytes()
                .all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b))
    })
}

/// The tokens row of a session minted at `created` (ISO) that lives until `expires` (epoch seconds, ISO).
fn session_row(
    id: &str,
    token: &str,
    github_id: u64,
    created: &str,
    expires: (i64, &str),
    revoked_at: Option<&str>,
) -> Value {
    let mut row = json!({
        "token_hash": {"S": sha256_hex(token)},
        "id": {"S": id},
        "kind": {"S": "session"},
        "github_id": {"S": github_id.to_string()},
        "github_id_num": {"N": github_id.to_string()},
        "name": {"S": "web login"},
        "prefix": {"S": &token[..11]},
        "scopes": {"L": []},
        "packages": {"L": []},
        "all_current": {"BOOL": false},
        "fresh_until": {"S": created},
        "created_at": {"S": created},
        "expires_at": {"N": expires.0.to_string()},
        "expires_at_iso": {"S": expires.1},
    });
    if let Some(at) = revoked_at {
        row["revoked_at"] = json!({"S": at});
    }
    row
}

fn id_of(row: &Value) -> String {
    row["id"]["S"].as_str().expect("an id").to_string()
}

#[tokio::test]
async fn a_full_sign_in_sets_the_session_and_sends_the_browser_back_to_the_page_it_started_from() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), Some("/tutorial/hello"), "").await;
    let token = done.session().expect("a session cookie");
    assert!(is_session_token(&token), "{token}");
    let resp = &done.finished;
    assert_eq!(resp.status, 303);
    assert_eq!(
        resp.header("location"),
        Some("https://mopm.test/tutorial/hello")
    );
    assert_eq!(
        headers(resp),
        vec![
            ("x-mopm-request-id", REQUEST_ID),
            ("cache-control", "no-store"),
            ("location", "https://mopm.test/tutorial/hello"),
            ("referrer-policy", "no-referrer")
        ]
    );
    assert_eq!(
        set_cookies(resp),
        vec![
            CLEAR_LOGIN.to_string(),
            format!("__Host-mopm_session={token}{SESSION_COOKIE_ATTRIBUTES}")
        ]
    );
    assert_eq!(resp.body, "");
}

#[tokio::test]
async fn the_login_cookie_start_sets_and_the_session_cookie_callback_sets_carry_exactly_the_designs_attributes(
) {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    assert_eq!(
        set_cookies(&done.started),
        vec![format!(
            "__Host-mopm_login={}; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600",
            done.txn()
        )]
    );
    let token = done.session().unwrap();
    assert_eq!(set_cookies(&done.finished), vec!["__Host-mopm_login=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0".to_string(), format!("__Host-mopm_session={token}; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800")]);
}

#[tokio::test]
async fn the_return_to_start_stored_is_where_the_browser_goes_and_a_bad_one_went_to_the_tutorial() {
    for (asked, goes) in [
        (
            Some("/packages/acme/widget/1.0.0"),
            "/packages/acme/widget/1.0.0",
        ),
        (Some("//evil.example"), "/tutorial"),
        (None, "/tutorial"),
    ] {
        let rig = Rig::new().await;
        let done = rig.sign_in(alice(), asked, "").await;
        assert_eq!(
            done.finished.header("location"),
            Some(format!("https://mopm.test{goes}").as_str()),
            "{asked:?}"
        );
    }
}

#[tokio::test]
async fn the_session_row_is_a_web_login_session_that_is_never_fresh_and_lasts_seven_days() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    let token = done.session().unwrap();
    let rows = rig.dynamo.dump(TOKENS);
    assert_eq!(rows.len(), 1);
    let id = id_of(&rows[0]);
    assert!(
        id.strip_prefix("tok_").is_some_and(|h| h.len() == 24
            && h.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
        "{id}"
    );
    // fresh_until is created_at, so no token route of the TypeScript functions treats the session as fresh.
    assert_eq!(
        rows[0],
        session_row(
            &id,
            &token,
            4242,
            "2026-11-19T12:00:00.000Z",
            (1_795_694_400, "2026-11-26T12:00:00.000Z"),
            None
        )
    );
    assert_eq!(rows[0]["fresh_until"], rows[0]["created_at"]);
}

#[tokio::test]
async fn a_sign_in_stores_the_user_the_namespace_the_session_and_the_used_login_and_nothing_else() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), Some("/search"), "").await;
    let token = done.session().unwrap();
    let [users, namespaces, tokens, logins] = rig.tables();
    assert_eq!(
        users,
        vec![json!({
            "github_id": {"S": "4242"}, "github_id_num": {"N": "4242"}, "handle": {"S": "Alice-Dev"},
            "created_at": {"S": NOW_ISO}, "last_login_at": {"S": NOW_ISO}, "two_factor": {"BOOL": true},
        })]
    );
    assert_eq!(
        namespaces,
        vec![json!({
            "namespace": {"S": "alice-dev"}, "kind": {"S": "user"}, "github_id": {"S": "4242"}, "github_id_num": {"N": "4242"}, "created_at": {"S": NOW_ISO},
        })]
    );
    assert_eq!(
        tokens,
        vec![session_row(
            &id_of(&tokens[0]),
            &token,
            4242,
            NOW_ISO,
            (1_795_694_400, "2026-11-26T12:00:00.000Z"),
            None
        )]
    );
    let verifier = logins[0]["code_verifier"].clone();
    assert_eq!(
        logins,
        vec![json!({
            "id": {"S": sha256_hex(&done.txn())}, "state_hash": {"S": sha256_hex(&done.state())}, "code_verifier": verifier,
            "return_to": {"S": "/search"}, "expires_at": {"N": "1795090200"}, "consumed_at": {"S": NOW_ISO},
        })]
    );
}

#[tokio::test]
async fn the_github_token_is_stored_nowhere_and_used_only_for_the_one_user_request() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    let github_token = mopm_testing::fake_github::FakeGitHub::token_for(&done.code());
    assert_eq!(rig.github.token_uses(&github_token), 1);
    let stored = rig.all_tables();
    assert!(!stored.contains(&github_token), "{stored}");
    assert!(!stored.contains("gho_"), "{stored}");
    let requests = rig.dynamo.requests();
    assert!(requests
        .iter()
        .all(|r| !r.body.to_string().contains(&github_token)));
    assert!(done
        .finished
        .headers
        .iter()
        .all(|(_, v)| !v.contains(&github_token)));
    assert!(done
        .finished
        .set_cookies
        .iter()
        .all(|c| !c.as_str().contains(&github_token)));
    assert_eq!(rig.github.token_requests().len(), 1);
}

#[tokio::test]
async fn the_token_request_carries_the_apps_secret_the_codes_verifier_and_the_exact_redirect_uri() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    let seen = rig.github.token_requests();
    assert_eq!(seen.len(), 1);
    let verifier = rig.dynamo.dump(WEB_LOGINS)[0]["code_verifier"]["S"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        seen[0].form(),
        vec![
            ("client_id".to_string(), "Ov23liFakeClientId00".to_string()),
            (
                "client_secret".to_string(),
                "fake-client-secret-0123456789".to_string()
            ),
            ("code".to_string(), done.code()),
            (
                "redirect_uri".to_string(),
                "https://mopm.test/api/v2/auth/web/callback".to_string()
            ),
            ("code_verifier".to_string(), verifier),
        ]
    );
    assert_eq!(seen[0].header("accept"), Some("application/json"));
    assert_eq!(
        seen[0].header("content-type"),
        Some("application/x-www-form-urlencoded")
    );
    assert_eq!(seen[0].header("user-agent"), Some("mopm-registry"));
}

#[tokio::test]
async fn the_user_and_namespace_rows_are_the_ones_the_typescript_device_login_writes_for_the_same_account(
) {
    let fixture: Value = serde_json::from_str(DEVICE_LOGIN_ROWS).unwrap();
    assert_eq!(fixture["now"], NOW_ISO);
    let gh = &fixture["github_user"];
    let user = GitHubUser::new(gh["id"].as_u64().unwrap(), gh["login"].as_str().unwrap())
        .two_factor(gh["two_factor_authentication"].as_bool());
    let rig = Rig::new().await;
    let done = rig.sign_in(user, None, "").await;
    assert_eq!(done.finished.status, 303);
    assert!(done.session().is_some());
    assert_eq!(Value::Array(rig.dynamo.dump(USERS)), fixture["users"]);
    assert_eq!(
        Value::Array(rig.dynamo.dump(NAMESPACES)),
        fixture["namespaces"]
    );
}

#[tokio::test]
async fn a_whole_sign_in_needs_no_permission_beyond_the_roles_grants_and_never_deletes() {
    // The fake refuses any call the grants of tests/fixtures/role_grants.json do not allow, and a refused call is a
    // fault that stops the sign-in: this one finished, with the session stored.
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    assert!(done.session().is_some());
    let used: BTreeSet<String> = rig.dynamo.operations().into_iter().collect();
    assert!(
        used.is_subset(&BTreeSet::from(
            ["GetItem", "PutItem", "UpdateItem"].map(String::from)
        )),
        "{used:?}"
    );
    assert!(!used.contains("DeleteItem"));
    assert!(used.contains("UpdateItem"));
}

#[tokio::test]
async fn an_account_without_two_factor_is_refused_and_nothing_of_it_is_stored() {
    for two_factor in [Some(false), None] {
        let rig = Rig::new().await;
        let done = rig
            .sign_in(
                GitHubUser::new(4242, "Alice-Dev").two_factor(two_factor),
                None,
                "",
            )
            .await;
        assert_refused_with(&done.finished, "two_factor_required");
        let [users, namespaces, tokens, _] = rig.tables();
        assert_eq!(
            (users, namespaces, tokens),
            (vec![], vec![], vec![]),
            "{two_factor:?}"
        );
        assert!(done.session().is_none());
    }
}

#[tokio::test]
async fn a_stage_that_does_not_require_two_factor_admits_the_account_and_records_what_github_said()
{
    for (two_factor, stored) in [(Some(false), json!({"BOOL": false})), (None, Value::Null)] {
        let rig = Rig::with(ROLE_GRANTS, false, Loopback).await;
        let done = rig
            .sign_in(
                GitHubUser::new(4242, "Alice-Dev").two_factor(two_factor),
                None,
                "",
            )
            .await;
        assert_eq!(done.finished.status, 303);
        assert!(done.session().is_some());
        let users = rig.dynamo.dump(USERS);
        assert_eq!(users.len(), 1);
        assert_eq!(users[0]["two_factor"], stored, "{two_factor:?}");
    }
}

#[tokio::test]
async fn an_account_with_no_user_namespace_still_signs_in() {
    for login in ["Poll", "noarch", "linux-64", "-bad-"] {
        let rig = Rig::new().await;
        let done = rig.sign_in(GitHubUser::new(77, login), None, "").await;
        assert_eq!(done.finished.status, 303, "{login}");
        assert!(done.session().is_some(), "{login}");
        assert_eq!(rig.dynamo.dump(NAMESPACES), Vec::<Value>::new(), "{login}");
        assert_eq!(rig.dynamo.dump(USERS).len(), 1);
    }
}

#[tokio::test]
async fn signing_in_again_revokes_the_session_the_browser_held_and_keeps_the_user_namespace() {
    let rig = Rig::new().await;
    let first = rig.sign_in(alice(), None, "").await;
    let old = first.session().unwrap();
    rig.clock.advance_millis(60_000);
    let second = rig
        .sign_in(alice(), None, &format!("{SESSION}={old}"))
        .await;
    let new = second.session().unwrap();
    assert_ne!(old, new);
    let tokens = rig.dynamo.dump(TOKENS);
    assert_eq!(tokens.len(), 2);
    let row = |token: &str| {
        tokens
            .iter()
            .find(|r| r["token_hash"]["S"] == sha256_hex(token))
            .cloned()
            .unwrap()
    };
    let expect_old = session_row(
        &id_of(&row(&old)),
        &old,
        4242,
        NOW_ISO,
        (1_795_694_400, "2026-11-26T12:00:00.000Z"),
        Some("2026-11-19T12:01:00.000Z"),
    );
    let expect_new = session_row(
        &id_of(&row(&new)),
        &new,
        4242,
        "2026-11-19T12:01:00.000Z",
        (1_795_694_460, "2026-11-26T12:01:00.000Z"),
        None,
    );
    assert_eq!((row(&old), row(&new)), (expect_old, expect_new));
    assert_ne!(id_of(&row(&old)), id_of(&row(&new)));
    assert_eq!(rig.dynamo.dump(NAMESPACES).len(), 1);
    let users = rig.dynamo.dump(USERS);
    assert_eq!(
        (
            users[0]["created_at"]["S"].as_str(),
            users[0]["last_login_at"]["S"].as_str()
        ),
        (Some(NOW_ISO), Some("2026-11-19T12:01:00.000Z"))
    );
}

#[tokio::test]
async fn a_previous_session_cookie_that_is_no_session_token_or_is_sent_twice_revokes_nothing() {
    let rig = Rig::new().await;
    let held = rig.sign_in(alice(), None, "").await.session().unwrap();
    let cases = [
        format!("{SESSION}=not-a-token"),
        format!("{SESSION}="),
        format!("{SESSION}=mopm_{}", "A".repeat(40)),
        format!("{SESSION}={held}; {SESSION}={held}"),
        format!("__host-mopm_session={held}"),
    ];
    for cookies in cases {
        let done = rig.sign_in(alice(), None, &cookies).await;
        assert_eq!(done.finished.status, 303, "{cookies}");
        assert!(done.session().is_some(), "{cookies}");
    }
    assert!(rig
        .dynamo
        .dump(TOKENS)
        .iter()
        .all(|r| r.get("revoked_at").is_none()));
    assert_eq!(rig.dynamo.dump(TOKENS).len(), 6);
}

#[tokio::test]
async fn a_session_token_the_store_does_not_know_is_revoked_to_nothing_and_the_sign_in_goes_on() {
    let rig = Rig::new().await;
    let stranger = format!("mopm_{}", "a".repeat(40));
    let done = rig
        .sign_in(alice(), None, &format!("{SESSION}={stranger}"))
        .await;
    assert_eq!(done.finished.status, 303);
    assert_eq!(rig.dynamo.dump(TOKENS).len(), 1);
}

#[tokio::test]
async fn a_callback_without_the_edge_header_or_with_a_wrong_one_is_session_required_and_asks_no_store_and_no_github(
) {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    rig.dynamo.clear_requests();
    let cookie = login_cookie_of(&begun);
    let valid = callback_request(&begun.callback_url, &cookie).with_header("accept", "text/html");
    for edge in [
        None,
        Some(""),
        Some("wrong"),
        Some("edge-secret-value-for-tests "),
    ] {
        let resp = rig.login.handle(&with_edge(valid.clone(), edge)).await;
        assert_eq!(resp.status, 401, "{edge:?}");
        assert_eq!(
            resp.body,
            r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#
        );
        assert!(
            resp.set_cookies.is_empty(),
            "a request that did not come through the site does not clear the login cookie"
        );
    }
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
    assert!(rig.github.requests().is_empty());
    // The transaction was not used up: the right request still signs in.
    assert_eq!(rig.login.handle(&valid).await.status, 303);
}

#[tokio::test]
async fn a_replayed_callback_is_login_expired_and_makes_no_second_session() {
    let rig = Rig::new().await;
    let done = rig.sign_in(alice(), None, "").await;
    assert_eq!(done.finished.status, 303);
    let replay = rig.callback(&done.callback_url, &done.started, "").await;
    assert_refused_with(&replay, "login_expired");
    assert_eq!(rig.dynamo.dump(TOKENS).len(), 1);
    assert_eq!(rig.github.token_requests().len(), 1);
}

#[tokio::test]
async fn a_wrong_state_is_login_expired_and_burns_the_transaction() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let wrong = call(
        &rig,
        &begun.code(),
        "not-the-state",
        &login_cookie_of(&begun),
    )
    .await;
    assert_refused_with(&wrong, "login_expired");
    assert!(rig.github.requests().is_empty());
    // The row was consumed by the first attempt, so the right state no longer works either.
    let right = call(
        &rig,
        &begun.code(),
        &begun.state(),
        &login_cookie_of(&begun),
    )
    .await;
    assert_refused_with(&right, "login_expired");
    assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
    assert!(rig.github.requests().is_empty());
}

#[tokio::test]
async fn a_state_that_is_a_prefix_or_an_extension_of_the_right_one_is_wrong() {
    for tamper in [
        |s: &str| s[..s.len() - 1].to_string(),
        |s: &str| format!("{s}x"),
        |s: &str| s.to_uppercase(),
        |_: &str| String::new(),
    ] {
        let rig = Rig::new().await;
        let begun = rig.begin(alice(), None).await;
        let resp = call(
            &rig,
            &begun.code(),
            &tamper(&begun.state()),
            &login_cookie_of(&begun),
        )
        .await;
        assert_refused_with(&resp, "login_expired");
    }
}

#[tokio::test]
async fn a_login_is_good_until_the_second_it_expires_and_not_from_then_on() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    rig.clock.advance_millis(599_999);
    let in_time = rig.callback(&begun.callback_url, &begun.started, "").await;
    assert_eq!(in_time.status, 303);
    assert!(cookie_value(&in_time, SESSION).is_some());

    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    rig.clock.advance_millis(600_000);
    let at_expiry = rig.callback(&begun.callback_url, &begun.started, "").await;
    assert_refused_with(&at_expiry, "login_expired");
    assert!(rig.github.token_requests().is_empty());

    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    rig.clock.advance_millis(3_600_000);
    assert_refused_with(
        &rig.callback(&begun.callback_url, &begun.started, "").await,
        "login_expired",
    );
    assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
}

#[tokio::test]
async fn a_callback_without_a_usable_login_cookie_is_login_expired_before_any_store_is_asked() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let (code, state) = (begun.code(), begun.state());
    let txn = begun.txn();
    rig.dynamo.clear_requests();
    let cases = [
        ("no cookie at all", String::new()),
        ("another cookie only", "other=1".to_string()),
        (
            "the cookie in another case",
            format!("__host-mopm_login={txn}"),
        ),
        ("the cookie twice", format!("{LOGIN}={txn}; {LOGIN}={txn}")),
        (
            "the cookie twice with two values",
            format!("{LOGIN}={txn}; {LOGIN}=other"),
        ),
    ];
    for (name, cookies) in cases {
        let resp = call(&rig, &code, &state, &cookies).await;
        assert_refused_with(&resp, "login_expired");
        assert_eq!(rig.dynamo.operations(), Vec::<String>::new(), "{name}");
    }
    assert!(rig.github.requests().is_empty());
    // The transaction is still there for the right browser.
    assert_eq!(
        call(&rig, &code, &state, &login_cookie_of(&begun))
            .await
            .status,
        303
    );
}

#[tokio::test]
async fn a_callback_without_exactly_one_code_and_one_state_is_login_expired_before_any_store_is_asked(
) {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let cookie = login_cookie_of(&begun);
    rig.dynamo.clear_requests();
    let base = "https://mopm.test/api/v2/auth/web/callback";
    let urls = [
        base.to_string(),
        format!("{base}?code=c"),
        format!("{base}?state=s"),
        format!("{base}?code=c&code=d&state=s"),
        format!("{base}?code=c&state=s&state=t"),
        format!("{base}?other=1"),
    ];
    for url in urls {
        let resp = rig.login.handle(&callback_request(&url, &cookie)).await;
        assert_refused_with(&resp, "login_expired");
        assert_eq!(rig.dynamo.operations(), Vec::<String>::new(), "{url}");
    }
}

#[tokio::test]
async fn a_login_cookie_no_transaction_belongs_to_is_login_expired() {
    let rig = Rig::new().await;
    for txn in ["", "unknown-transaction", &"A".repeat(43)] {
        let resp = call(&rig, "c", "s", &format!("{LOGIN}={txn}")).await;
        assert_refused_with(&resp, "login_expired");
    }
    assert!(rig.github.requests().is_empty());
}

#[tokio::test]
async fn a_sign_in_github_refused_is_access_denied_and_asks_no_store_and_no_github() {
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let denied_url = rig
        .github
        .deny(&begun.authorize_url)
        .expect("GitHub's refusal");
    assert!(denied_url.contains("error=access_denied"), "{denied_url}");
    rig.dynamo.clear_requests();
    let resp = rig
        .login
        .handle(&callback_request(&denied_url, &login_cookie_of(&begun)))
        .await;
    assert_refused_with(&resp, "access_denied");
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
    assert!(rig.github.requests().is_empty());
    // With no login cookie at all the answer is the same: the error is read first.
    assert_refused_with(
        &rig.login.handle(&callback_request(&denied_url, "")).await,
        "access_denied",
    );
}

#[tokio::test]
async fn any_other_error_github_reports_is_unavailable() {
    let rig = Rig::new().await;
    for error in [
        "server_error",
        "temporarily_unavailable",
        "redirect_uri_mismatch",
        "unsupported_response_type",
        "",
        "ACCESS_DENIED",
    ] {
        let url = format!("https://mopm.test/api/v2/auth/web/callback?error={error}&state=s");
        assert_refused_with(
            &rig.login.handle(&callback_request(&url, "")).await,
            "unavailable",
        );
    }
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
}

/// Starts a sign-in and answers its callback with the code `code`, which the fake GitHub already holds as `grant`.
async fn refused_at_the_token_endpoint(error: TokenError) -> (Rig<Loopback>, WebResponse) {
    let rig = Rig::new().await;
    let started = rig.start(None).await;
    let state = query_value(started.header("location").unwrap(), "state").unwrap();
    let verifier = rig.dynamo.dump(WEB_LOGINS)[0]["code_verifier"]["S"]
        .as_str()
        .unwrap()
        .to_string();
    rig.github
        .add_grant(Grant::refused("granted-code", &verifier, error));
    let resp = rig
        .callback(&callback_url("granted-code", &state), &started, "")
        .await;
    (rig, resp)
}

#[tokio::test]
async fn a_token_endpoint_that_says_access_denied_is_access_denied() {
    let (rig, resp) = refused_at_the_token_endpoint(TokenError::AccessDenied).await;
    assert_refused_with(&resp, "access_denied");
    assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
}

#[tokio::test]
async fn a_code_github_does_not_know_or_that_does_not_fit_the_verifier_is_login_expired() {
    let (_, resp) = refused_at_the_token_endpoint(TokenError::BadVerificationCode).await;
    assert_refused_with(&resp, "login_expired");
    let rig = Rig::new().await;
    let begun = rig.begin(alice(), None).await;
    let resp = call(
        &rig,
        "a-code-github-never-issued",
        &begun.state(),
        &login_cookie_of(&begun),
    )
    .await;
    assert_refused_with(&resp, "login_expired");
    assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
}

#[tokio::test]
async fn any_other_token_endpoint_error_is_unavailable_and_stores_nothing() {
    for error in [
        TokenError::IncorrectClientCredentials,
        TokenError::RedirectUriMismatch,
    ] {
        let (rig, resp) = refused_at_the_token_endpoint(error).await;
        assert_refused_with(&resp, "unavailable");
        let [users, namespaces, tokens, _] = rig.tables();
        assert_eq!((users, namespaces, tokens), (vec![], vec![], vec![]));
    }
}

#[tokio::test]
async fn a_github_outage_on_the_token_exchange_is_unavailable_and_stores_nothing() {
    for outage in [
        Outage::Status(500),
        Outage::Status(503),
        Outage::Status(404),
        Outage::Drop,
    ] {
        let rig = Rig::new().await;
        let begun = rig.begin(alice(), None).await;
        rig.github.set_outage(Some(outage));
        let resp = rig.callback(&begun.callback_url, &begun.started, "").await;
        assert_refused_with(&resp, "unavailable");
        let [users, namespaces, tokens, _] = rig.tables();
        assert_eq!(
            (users, namespaces, tokens),
            (vec![], vec![], vec![]),
            "{outage:?}"
        );
    }
}

fn http_reply(status: u16, body: &str) -> Result<HttpResponse, HttpError> {
    Ok(HttpResponse {
        status,
        headers: vec![],
        body: body.as_bytes().to_vec(),
    })
}

const TOKEN_ANSWER: &str =
    r#"{"access_token":"gho_scripted","token_type":"bearer","scope":"read:user"}"#;
const USER_ANSWER: &str = r#"{"id":4242,"login":"Alice-Dev","two_factor_authentication":true}"#;

/// A sign-in whose GitHub answers are `script`, in order (the token exchange, then the user).
async fn scripted(
    script: Vec<Result<HttpResponse, HttpError>>,
) -> (Rig<ScriptedHttp>, WebResponse) {
    let rig = Rig::with(ROLE_GRANTS, true, ScriptedHttp::new(script)).await;
    let started = rig.start(None).await;
    let state = query_value(started.header("location").unwrap(), "state").unwrap();
    let resp = rig.callback(&callback_url("c", &state), &started, "").await;
    (rig, resp)
}

#[tokio::test]
async fn the_user_is_read_with_the_token_the_exchange_gave() {
    let (rig, resp) = scripted(vec![
        http_reply(200, TOKEN_ANSWER),
        http_reply(200, USER_ANSWER),
    ])
    .await;
    assert_eq!(resp.status, 303);
    assert_eq!(rig.dynamo.dump(TOKENS).len(), 1);
    let sent = rig.login.http.requests();
    let github = rig.github.endpoint();
    assert_eq!(
        (sent[0].url.as_str(), sent[1].url.as_str()),
        (
            format!("{github}/login/oauth/access_token").as_str(),
            format!("{github}/user").as_str()
        )
    );
    assert!(sent[1].headers.contains(&(
        "Authorization".to_string(),
        "Bearer gho_scripted".to_string()
    )));
}

#[tokio::test]
async fn a_github_that_does_not_answer_the_token_exchange_is_unavailable() {
    for failure in [HttpFailure::Timeout, HttpFailure::Connect, HttpFailure::Tls] {
        let no_answer = Err(HttpError {
            failure,
            detail: "github.com:443".to_string(),
        });
        let (rig, resp) = scripted(vec![no_answer]).await;
        assert_refused_with(&resp, "unavailable");
        assert_eq!(rig.login.http.requests().len(), 1);
        assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
    }
}

#[tokio::test]
async fn a_github_that_does_not_answer_the_user_request_is_unavailable_and_stores_nothing() {
    let timeout = || {
        Err(HttpError {
            failure: HttpFailure::Timeout,
            detail: "api.github.com:443".to_string(),
        })
    };
    let scripts = vec![
        vec![http_reply(200, TOKEN_ANSWER), timeout()],
        vec![http_reply(200, TOKEN_ANSWER), http_reply(500, "")],
        vec![
            http_reply(200, TOKEN_ANSWER),
            http_reply(502, "<html>Bad Gateway</html>"),
        ],
        vec![
            http_reply(200, TOKEN_ANSWER),
            http_reply(401, r#"{"message":"Bad credentials"}"#),
        ],
        vec![http_reply(200, TOKEN_ANSWER), http_reply(200, "not json")],
        vec![
            http_reply(200, TOKEN_ANSWER),
            http_reply(200, r#"{"login":"alice"}"#),
        ],
        vec![http_reply(200, TOKEN_ANSWER)],
    ];
    for script in scripts {
        let (rig, resp) = scripted(script).await;
        assert_refused_with(&resp, "unavailable");
        let [users, namespaces, tokens, _] = rig.tables();
        assert_eq!((users, namespaces, tokens), (vec![], vec![], vec![]));
    }
}

#[tokio::test]
async fn a_token_answer_that_is_not_a_token_is_unavailable() {
    for body in [
        "{}",
        "not json",
        r#"{"error":"server_error"}"#,
        r#"{"access_token":""}"#,
    ] {
        let (_, resp) = scripted(vec![http_reply(200, body)]).await;
        assert_refused_with(&resp, "unavailable");
    }
    let (_, resp) = scripted(vec![http_reply(500, TOKEN_ANSWER)]).await;
    assert_refused_with(&resp, "unavailable");
}

#[tokio::test]
async fn a_store_that_fails_stops_the_sign_in_as_unavailable() {
    // Each case withholds one grant, so that call is a fault: the login row cannot be taken, the user cannot be stored,
    // the namespace cannot be stored, the session cannot be stored.
    let cases = [
        ("web_logins", "dynamodb:UpdateItem", [0, 0, 0]),
        ("users", "dynamodb:PutItem", [0, 0, 0]),
        ("namespaces", "dynamodb:PutItem", [1, 0, 0]),
        ("tokens", "dynamodb:PutItem", [1, 1, 0]),
    ];
    for (table, action, [users, namespaces, tokens]) in cases {
        let rig = Rig::with(&grants_without(table, action), true, Loopback).await;
        let done = rig.sign_in(alice(), None, "").await;
        assert_refused_with(&done.finished, "unavailable");
        assert!(done.session().is_none(), "{table} {action}");
        let counts = [
            rig.dynamo.dump(USERS).len(),
            rig.dynamo.dump(NAMESPACES).len(),
            rig.dynamo.dump(TOKENS).len(),
        ];
        assert_eq!(counts, [users, namespaces, tokens], "{table} {action}");
    }
}

#[tokio::test]
async fn a_store_that_cannot_revoke_the_earlier_session_stops_the_sign_in_before_a_new_session_exists(
) {
    let rig = Rig::with(
        &grants_without("tokens", "dynamodb:UpdateItem"),
        true,
        Loopback,
    )
    .await;
    let first = rig.sign_in(alice(), None, "").await;
    let old = first.session().unwrap();
    let second = rig
        .sign_in(alice(), None, &format!("{SESSION}={old}"))
        .await;
    assert_refused_with(&second.finished, "unavailable");
    let tokens = rig.dynamo.dump(TOKENS);
    assert_eq!(tokens.len(), 1);
    assert_eq!(tokens[0]["token_hash"]["S"], sha256_hex(&old));
    assert!(tokens[0].get("revoked_at").is_none());
}

#[tokio::test]
async fn a_clock_too_late_for_a_seven_day_session_is_unavailable() {
    let rig = Rig::new().await;
    // 9999-12-30T22:00:00Z, the last second a time can be (jiff's Timestamp::MAX).
    rig.clock.advance_millis(253_402_207_200_000 - NOW_MS);
    let begun = rig.begin(alice(), None).await;
    let resp = rig.callback(&begun.callback_url, &begun.started, "").await;
    assert_refused_with(&resp, "unavailable");
    assert_eq!(rig.dynamo.dump(TOKENS), Vec::<Value>::new());
}
