//! What the web-login tests rely on from the fake GitHub: the authorization step, a token only for the configured app
//! and the code's verifier, GitHub's error for anything else, `GET /user` per token, unknown routes, and the outage modes.

use serde_json::json;

use super::*;
use crate::fake_http::client::{exchange as send, exchange_raw, request, Answered};

const VERIFIER: &str = "verifier-0123456789-0123456789-0123456789-abc";

fn app() -> OAuthApp {
    OAuthApp::example()
}

fn octo() -> GitHubUser {
    GitHubUser::new(4242, "octo")
}

/// The authorization URL the registry's start route builds, with `over` replacing (or, with an empty value, removing)
/// a parameter.
fn authorize_url(over: &[(&str, &str)]) -> String {
    let a = app();
    let challenge = s256(VERIFIER);
    let base = [
        ("client_id", a.client_id.as_str()),
        ("redirect_uri", a.redirect_uri.as_str()),
        ("scope", "read:user"),
        ("state", "st/ate+1"),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
        ("prompt", "select_account"),
    ];
    let pairs: Vec<(&str, &str)> = base
        .iter()
        .map(|(k, v)| {
            over.iter()
                .find(|(o, _)| o == k)
                .map_or((*k, *v), |(_, nv)| (*k, *nv))
        })
        .filter(|(_, v)| !v.is_empty())
        .collect();
    format!("https://github.com{AUTHORIZE_PATH}?{}", encode_form(&pairs))
}

/// The exchange's form, the app's credentials and `over` (replacing; an empty value removes the field).
fn exchange_form(code: &str, over: &[(&str, &str)]) -> Vec<u8> {
    let a = app();
    let base = [
        ("client_id", a.client_id.as_str()),
        ("client_secret", a.client_secret.as_str()),
        ("code", code),
        ("redirect_uri", a.redirect_uri.as_str()),
        ("code_verifier", VERIFIER),
    ];
    let pairs: Vec<(&str, &str)> = base
        .iter()
        .map(|(k, v)| {
            over.iter()
                .find(|(o, _)| o == k)
                .map_or((*k, *v), |(_, nv)| (*k, *nv))
        })
        .filter(|(_, v)| !v.is_empty())
        .collect();
    encode_form(&pairs).into_bytes()
}

async fn exchange_json(fake: &FakeGitHub, body: &[u8]) -> Answered {
    let headers = [
        ("Accept", "application/json"),
        ("Content-Type", "application/x-www-form-urlencoded"),
    ];
    send(
        &fake.endpoint(),
        &request("POST", TOKEN_PATH, &headers, body),
    )
    .await
    .expect("an answer")
}

async fn user(fake: &FakeGitHub, authorization: Option<&str>) -> Answered {
    let headers: Vec<(&str, &str)> = authorization
        .map(|a| ("Authorization", a))
        .into_iter()
        .collect();
    send(&fake.endpoint(), &request("GET", USER_PATH, &headers, b""))
        .await
        .expect("an answer")
}

fn error_json(e: TokenError) -> serde_json::Value {
    let p = e.pairs();
    json!({p[0].0: p[0].1, p[1].0: p[1].1, p[2].0: p[2].1})
}

fn query_of(url: &str) -> Vec<(String, String)> {
    decode_form(url.split_once('?').expect("a query").1)
}

#[test]
fn the_token_errors_are_github_s() {
    assert_eq!(
        error_json(TokenError::BadVerificationCode),
        json!({
            "error": "bad_verification_code",
            "error_description": "The code passed is incorrect or expired.",
            "error_uri": "https://docs.github.com/apps/managing-oauth-apps/troubleshooting-oauth-app-access-token-request-errors/#bad-verification-code"
        })
    );
    let codes = [
        TokenError::IncorrectClientCredentials,
        TokenError::RedirectUriMismatch,
        TokenError::AccessDenied,
    ]
    .map(TokenError::code);
    assert_eq!(
        codes,
        [
            "incorrect_client_credentials",
            "redirect_uri_mismatch",
            "access_denied"
        ]
    );
    assert_eq!(
        TokenError::AccessDenied.description(),
        "The user has denied your application access."
    );
    assert!(TokenError::IncorrectClientCredentials.pairs()[2]
        .1
        .ends_with("#incorrect-client-credentials"));
    assert_eq!(
        TokenError::RedirectUriMismatch.description(),
        "The redirect_uri MUST match the registered callback URL for this application."
    );
    assert_eq!(
        TokenError::IncorrectClientCredentials.description(),
        "The client_id and/or client_secret passed are incorrect."
    );
}

#[test]
fn s256_is_rfc_7636_s_example() {
    // RFC 7636 appendix B.
    assert_eq!(
        s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
}

#[test]
fn a_user_s_json_has_two_factor_only_when_known() {
    assert_eq!(
        octo().to_json(),
        json!({"login": "octo", "id": 4242, "two_factor_authentication": true})
    );
    assert_eq!(
        octo().two_factor(Some(false)).to_json(),
        json!({"login": "octo", "id": 4242, "two_factor_authentication": false})
    );
    assert_eq!(
        octo().two_factor(None).to_json(),
        json!({"login": "octo", "id": 4242})
    );
}

#[tokio::test]
async fn authorize_then_exchange_then_user_is_the_whole_sign_in() {
    let fake = FakeGitHub::start(app());
    let callback = fake
        .authorize(&authorize_url(&[]), octo())
        .expect("GitHub calls back");
    assert_eq!(
        callback,
        format!("{}?code=fake_code_1&state=st%2Fate%2B1", app().redirect_uri)
    );
    let got = exchange_json(&fake, &exchange_form("fake_code_1", &[])).await;
    assert_eq!(
        (got.status, got.header("content-type")),
        (200, Some("application/json"))
    );
    assert_eq!(
        got.json(),
        json!({"access_token": "gho_fake_fake_code_1", "token_type": "bearer", "scope": "read:user"})
    );
    let me = user(&fake, Some("Bearer gho_fake_fake_code_1")).await;
    assert_eq!(
        (me.status, me.json()),
        (
            200,
            json!({"login": "octo", "id": 4242, "two_factor_authentication": true})
        )
    );
    assert_eq!(fake.token_uses("gho_fake_fake_code_1"), 1);
    // A second sign-in gets the next code.
    let callback = fake
        .authorize(&authorize_url(&[("state", "")]), octo())
        .expect("GitHub calls back");
    assert_eq!(
        callback,
        format!("{}?code=fake_code_2", app().redirect_uri),
        "no state, none sent back"
    );
}

#[tokio::test]
async fn the_exchange_is_recorded_so_a_test_sees_the_verifier_and_secret_sent() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    exchange_json(&fake, &exchange_form("c1", &[])).await;
    let seen = fake.token_requests();
    assert_eq!(seen.len(), 1);
    let form = seen[0].form();
    assert_eq!(form_value(&form, "code_verifier"), Some(VERIFIER));
    assert_eq!(
        form_value(&form, "client_secret"),
        Some(app().client_secret.as_str())
    );
    assert_eq!(seen[0].header("accept"), Some("application/json"));
    assert_eq!(fake.requests().len(), 1);
}

#[tokio::test]
async fn without_an_accept_of_json_the_exchange_answers_a_form() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    let got = send(
        &fake.endpoint(),
        &request("POST", TOKEN_PATH, &[], &exchange_form("c1", &[])),
    )
    .await
    .expect("an answer");
    assert_eq!(
        (got.status, got.header("content-type")),
        (
            200,
            Some("application/x-www-form-urlencoded; charset=utf-8")
        )
    );
    assert_eq!(
        got.text(),
        "access_token=gho_fake_c1&token_type=bearer&scope=read%3Auser"
    );
    let got = send(
        &fake.endpoint(),
        &request(
            "POST",
            TOKEN_PATH,
            &[("Accept", "text/html")],
            &exchange_form("c1", &[]),
        ),
    )
    .await
    .expect("an answer");
    assert_eq!(
        decode_form(&got.text()),
        TokenError::BadVerificationCode
            .pairs()
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn a_code_is_used_once() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json()["access_token"],
        "gho_fake_c1"
    );
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json(),
        error_json(TokenError::BadVerificationCode)
    );
}

#[tokio::test]
async fn only_the_configured_client_and_secret_get_a_token() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    for over in [
        [("client_secret", "wrong")],
        [("client_secret", "")],
        [("client_id", "other")],
        [("client_id", "")],
    ] {
        let got = exchange_json(&fake, &exchange_form("c1", &over)).await;
        assert_eq!(
            (got.status, got.json()),
            (200, error_json(TokenError::IncorrectClientCredentials)),
            "{over:?}"
        );
    }
    // None of them used the code up.
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json()["access_token"],
        "gho_fake_c1"
    );
}

#[tokio::test]
async fn only_the_code_s_verifier_gets_a_token() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    let challenge = s256(VERIFIER);
    for over in [
        [("code_verifier", "another-verifier")],
        [("code_verifier", "")],
        [("code_verifier", challenge.as_str())],
    ] {
        assert_eq!(
            exchange_json(&fake, &exchange_form("c1", &over))
                .await
                .json(),
            error_json(TokenError::BadVerificationCode),
            "{over:?}"
        );
    }
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json()["access_token"],
        "gho_fake_c1"
    );
}

#[tokio::test]
async fn an_unknown_or_missing_code_is_bad_verification_code() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    for over in [[("code", "c2")], [("code", "")]] {
        assert_eq!(
            exchange_json(&fake, &exchange_form("c1", &over))
                .await
                .json(),
            error_json(TokenError::BadVerificationCode)
        );
    }
}

#[tokio::test]
async fn a_redirect_uri_when_sent_must_be_the_app_s() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    let wrong = format!("{}/below", app().redirect_uri);
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[("redirect_uri", &wrong)]))
            .await
            .json(),
        error_json(TokenError::RedirectUriMismatch)
    );
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[("redirect_uri", "")]))
            .await
            .json()["access_token"],
        "gho_fake_c1"
    );
}

#[tokio::test]
async fn a_grant_scripted_to_refuse_answers_its_error_once() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::refused("c1", VERIFIER, TokenError::AccessDenied));
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json(),
        error_json(TokenError::AccessDenied)
    );
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json(),
        error_json(TokenError::BadVerificationCode)
    );
}

#[tokio::test]
async fn deny_calls_back_with_access_denied_and_the_state() {
    let fake = FakeGitHub::start(app());
    let callback = fake.deny(&authorize_url(&[])).expect("GitHub calls back");
    assert!(callback.starts_with(&format!("{}?error=access_denied&", app().redirect_uri)));
    let mut expected: Vec<(String, String)> = TokenError::AccessDenied
        .pairs()
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect();
    expected.push(("state".into(), "st/ate+1".into()));
    assert_eq!(query_of(&callback), expected);
    assert_eq!(
        fake.deny(&authorize_url(&[("client_id", "x")])),
        Err(AuthorizeRefusal::UnknownClient)
    );
    assert!(
        fake.requests().is_empty(),
        "the browser's step is not a request to the fake"
    );
}

#[tokio::test]
async fn authorize_refuses_what_github_would_not_call_back_for() {
    let fake = FakeGitHub::start(app());
    let wrong_redirect = format!("{}/below", app().redirect_uri);
    let cases = [
        (
            authorize_url(&[]).replace(AUTHORIZE_PATH, "/login/device"),
            AuthorizeRefusal::NotAuthorize,
        ),
        (
            authorize_url(&[("client_id", "other")]),
            AuthorizeRefusal::UnknownClient,
        ),
        (
            authorize_url(&[("client_id", "")]),
            AuthorizeRefusal::UnknownClient,
        ),
        (
            authorize_url(&[("redirect_uri", &wrong_redirect)]),
            AuthorizeRefusal::RedirectUriMismatch,
        ),
        (
            authorize_url(&[("redirect_uri", "")]),
            AuthorizeRefusal::RedirectUriMismatch,
        ),
        (
            authorize_url(&[("code_challenge_method", "plain")]),
            AuthorizeRefusal::NoS256Challenge,
        ),
        (
            authorize_url(&[("code_challenge_method", "")]),
            AuthorizeRefusal::NoS256Challenge,
        ),
        (
            authorize_url(&[("code_challenge", "")]),
            AuthorizeRefusal::NoS256Challenge,
        ),
        (
            format!(
                "{}&code_challenge=",
                authorize_url(&[("code_challenge", "")])
            ),
            AuthorizeRefusal::NoS256Challenge,
        ),
        (
            format!("https://github.com{AUTHORIZE_PATH}"),
            AuthorizeRefusal::UnknownClient,
        ),
    ];
    for (url, refusal) in cases {
        assert_eq!(fake.authorize(&url, octo()), Err(refusal.clone()), "{url}");
    }
    // None of them issued a code: the next approval is the first.
    assert_eq!(
        query_of(
            &fake
                .authorize(&authorize_url(&[]), octo())
                .expect("GitHub calls back")
        )[0],
        ("code".to_string(), "fake_code_1".to_string())
    );
}

#[tokio::test]
async fn an_authorized_code_is_bound_to_the_url_s_challenge() {
    let fake = FakeGitHub::start(app());
    let other = s256("another-verifier");
    fake.authorize(&authorize_url(&[("code_challenge", &other)]), octo())
        .expect("GitHub calls back");
    assert_eq!(
        exchange_json(&fake, &exchange_form("fake_code_1", &[]))
            .await
            .json(),
        error_json(TokenError::BadVerificationCode)
    );
    let got = exchange_json(
        &fake,
        &exchange_form("fake_code_1", &[("code_verifier", "another-verifier")]),
    )
    .await;
    assert_eq!(got.json()["access_token"], "gho_fake_fake_code_1");
}

#[tokio::test]
async fn user_answers_the_token_s_account_and_401_otherwise() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("a", VERIFIER, octo().two_factor(None)));
    fake.add_grant(Grant::new(
        "b",
        VERIFIER,
        GitHubUser::new(7, "hubot").two_factor(Some(false)),
    ));
    exchange_json(&fake, &exchange_form("a", &[])).await;
    exchange_json(&fake, &exchange_form("b", &[])).await;
    assert_eq!(
        user(&fake, Some("token gho_fake_a")).await.json(),
        json!({"login": "octo", "id": 4242})
    );
    assert_eq!(
        user(&fake, Some("Bearer gho_fake_b")).await.json(),
        json!({"login": "hubot", "id": 7, "two_factor_authentication": false})
    );
    assert_eq!(user(&fake, Some("Bearer gho_fake_b")).await.status, 200);
    let bad = json!({"message": "Bad credentials", "documentation_url": "https://docs.github.com/rest", "status": "401"});
    for authorization in [
        None,
        Some("Bearer gho_fake_c"),
        Some("Basic gho_fake_a"),
        Some("gho_fake_a"),
    ] {
        let got = user(&fake, authorization).await;
        assert_eq!(
            (got.status, got.json()),
            (401, bad.clone()),
            "{authorization:?}"
        );
    }
    // The token on another route is not a use of it for `GET /user`.
    let elsewhere = request(
        "GET",
        "/user/emails",
        &[("Authorization", "Bearer gho_fake_a")],
        b"",
    );
    assert_eq!(
        send(&fake.endpoint(), &elsewhere)
            .await
            .expect("an answer")
            .status,
        404
    );
    assert_eq!(
        (
            fake.token_uses("gho_fake_a"),
            fake.token_uses("gho_fake_b"),
            fake.token_uses("gho_fake_c")
        ),
        (1, 2, 1)
    );
}

#[tokio::test]
async fn unknown_routes_are_404() {
    let fake = FakeGitHub::start(app());
    let not_found = json!({"message": "Not Found", "documentation_url": "https://docs.github.com/rest", "status": "404"});
    for (method, target) in [
        ("GET", TOKEN_PATH),
        ("POST", USER_PATH),
        ("GET", "/user/emails"),
        ("POST", "/login/device/code"),
        ("GET", AUTHORIZE_PATH),
    ] {
        let got = send(&fake.endpoint(), &request(method, target, &[], b""))
            .await
            .expect("an answer");
        assert_eq!(
            (got.status, got.json()),
            (404, not_found.clone()),
            "{method} {target}"
        );
    }
    assert_eq!(fake.requests().len(), 5);
    assert!(fake.token_requests().is_empty());
}

#[tokio::test]
async fn an_outage_answers_every_route_its_way_and_ends_when_cleared() {
    let fake = FakeGitHub::start(app());
    fake.add_grant(Grant::new("c1", VERIFIER, octo()));
    fake.set_outage(Some(Outage::Status(502)));
    let got = exchange_json(&fake, &exchange_form("c1", &[])).await;
    assert_eq!(
        (got.status, got.json()),
        (502, json!({"message": "Server Error"}))
    );
    assert_eq!(user(&fake, None).await.status, 502);
    fake.set_outage(Some(Outage::Drop));
    assert_eq!(
        exchange_raw(
            &fake.endpoint(),
            &request("POST", TOKEN_PATH, &[], &exchange_form("c1", &[]))
        )
        .await,
        Vec::<u8>::new()
    );
    fake.set_outage(None);
    // The outage used nothing up.
    assert_eq!(
        exchange_json(&fake, &exchange_form("c1", &[])).await.json()["access_token"],
        "gho_fake_c1"
    );
    assert_eq!(
        fake.token_requests().len(),
        3,
        "requests in an outage are recorded"
    );
}

#[tokio::test]
async fn a_hanging_outage_answers_nothing_until_the_fake_is_dropped() {
    let fake = FakeGitHub::start(app());
    fake.set_outage(Some(Outage::Hang));
    let endpoint = fake.endpoint();
    let hanging =
        tokio::spawn(
            async move { exchange_raw(&endpoint, &request("GET", USER_PATH, &[], b"")).await },
        );
    fake.wait_for_requests(1).await;
    assert_eq!(fake.requests()[0].path(), USER_PATH);
    drop(fake);
    assert_eq!(hanging.await.expect("the client task"), Vec::<u8>::new());
}
