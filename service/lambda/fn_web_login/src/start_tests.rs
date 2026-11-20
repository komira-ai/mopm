//! `GET /api/v2/auth/web/start` against a fake DynamoDB under the function role's grants: what a navigation gets, what
//! every other request gets, and what is stored.

use mopm_testing::fake_github::s256;
use serde_json::{json, Value};

use crate::test_support::*;

const ERROR_400: &str = r#"{"error":{"code":"invalid_request","message":"The request is not valid: a sign-in starts from a link of the site.","hint":"Check the request against the API documentation; update mopm if it is old."}}"#;
const ERROR_401: &str = r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#;

/// The one `web_logins` row of the table, as DynamoDB JSON.
fn only_row(rig: &Rig<Loopback>) -> Value {
    let rows = rig.dynamo.dump(WEB_LOGINS);
    assert_eq!(rows.len(), 1, "{rows:?}");
    rows[0].clone()
}

fn stored_return_to(rig: &Rig<Loopback>) -> String {
    only_row(rig)["return_to"]["S"]
        .as_str()
        .expect("a return_to")
        .to_string()
}

fn assert_nothing_called(rig: &Rig<Loopback>) {
    assert_eq!(rig.dynamo.operations(), Vec::<String>::new());
    assert!(rig.github.requests().is_empty());
}

#[tokio::test]
async fn a_navigation_is_sent_to_github_with_the_login_cookie_set() {
    let rig = Rig::new().await;
    let resp = rig.start(Some("/tutorial/hello")).await;
    assert_eq!(resp.status, 302);
    let txn = cookie_value(&resp, LOGIN).unwrap();
    assert_eq!(
        set_cookies(&resp),
        vec![format!(
            "__Host-mopm_login={txn}; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=600"
        )]
    );
    let location = resp.header("location").unwrap().to_string();
    assert!(
        location.starts_with(&format!("{}/login/oauth/authorize?", rig.github.endpoint())),
        "{location}"
    );
    assert_eq!(
        headers(&resp),
        vec![
            ("x-mopm-request-id", REQUEST_ID),
            ("cache-control", "no-store"),
            ("location", location.as_str())
        ]
    );
    assert_eq!(resp.body, "");
}

#[tokio::test]
async fn the_authorize_url_asks_for_read_user_with_an_s256_challenge_of_the_stored_verifier() {
    let rig = Rig::new().await;
    let resp = rig.start(None).await;
    let location = resp.header("location").unwrap();
    let query: Vec<(String, String)> =
        form_urlencoded::parse(location.split_once('?').unwrap().1.as_bytes())
            .into_owned()
            .collect();
    let names: Vec<&str> = query.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        names,
        [
            "client_id",
            "redirect_uri",
            "scope",
            "state",
            "code_challenge",
            "code_challenge_method",
            "prompt"
        ]
    );
    let get = |name: &str| query_value(location, name).unwrap();
    assert_eq!(get("client_id"), "Ov23liFakeClientId00");
    assert_eq!(
        get("redirect_uri"),
        "https://mopm.test/api/v2/auth/web/callback"
    );
    assert_eq!(get("scope"), "read:user");
    assert_eq!(get("code_challenge_method"), "S256");
    assert_eq!(get("prompt"), "select_account");
    let row = only_row(&rig);
    let verifier = row["code_verifier"]["S"].as_str().unwrap();
    assert_eq!(get("code_challenge"), s256(verifier));
    assert_eq!(verifier.len(), 43);
    // The state is 256 random bits, base64url: 43 characters, and only its hash is stored.
    assert_eq!(get("state").len(), 43);
    assert_eq!(row["state_hash"]["S"], sha256_of(&get("state")));
    assert!(get("state")
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
}

fn sha256_of(s: &str) -> String {
    crate::login::sha256_hex(s)
}

#[tokio::test]
async fn the_login_row_is_the_transaction_state_and_verifier_hashed_with_a_ten_minute_expiry() {
    let rig = Rig::new().await;
    let resp = rig.start(Some("/tutorial/hello")).await;
    let txn = cookie_value(&resp, LOGIN).unwrap();
    assert_eq!(txn.len(), 43);
    let row = only_row(&rig);
    let state = query_value(resp.header("location").unwrap(), "state").unwrap();
    assert_eq!(
        row,
        json!({
            "id": {"S": sha256_of(&txn)},
            "state_hash": {"S": sha256_of(&state)},
            "code_verifier": row["code_verifier"],
            "return_to": {"S": "/tutorial/hello"},
            "expires_at": {"N": "1795090200"},
        })
    );
}

#[tokio::test]
async fn each_start_makes_its_own_transaction_state_and_verifier() {
    let rig = Rig::new().await;
    let first = rig.start(None).await;
    let second = rig.start(None).await;
    assert_ne!(cookie_value(&first, LOGIN), cookie_value(&second, LOGIN));
    assert_ne!(
        query_value(first.header("location").unwrap(), "state"),
        query_value(second.header("location").unwrap(), "state")
    );
    let rows = rig.dynamo.dump(WEB_LOGINS);
    assert_eq!(rows.len(), 2);
    assert_ne!(rows[0]["code_verifier"], rows[1]["code_verifier"]);
}

#[tokio::test]
async fn the_redirect_uri_is_the_stage_settings_whatever_host_the_request_names() {
    let rig = Rig::new().await;
    let forged = start_request(None)
        .with_header("host", "evil.example")
        .with_header("x-forwarded-host", "evil.example")
        .with_header("x-forwarded-proto", "http")
        .with_header("forwarded", "host=evil.example");
    let resp = rig.login.handle(&forged).await;
    assert_eq!(resp.status, 302);
    assert_eq!(
        query_value(resp.header("location").unwrap(), "redirect_uri").as_deref(),
        Some("https://mopm.test/api/v2/auth/web/callback")
    );
}

#[tokio::test]
async fn good_return_to_values_are_kept_and_every_bad_one_falls_back_to_the_tutorial() {
    let long = format!("/packages/acme/{}", "a".repeat(250));
    let cases: Vec<(Option<&str>, &str)> = vec![
        (None, "/tutorial"),
        (Some(""), "/tutorial"),
        (Some("/"), "/"),
        (Some("/search"), "/search"),
        (Some("/tutorial"), "/tutorial"),
        (Some("/tutorial/hello-world"), "/tutorial/hello-world"),
        (Some("/docs/"), "/docs/"),
        (Some("/packages/acme/widget"), "/packages/acme/widget"),
        (
            Some("/packages/acme/widget/1.2.3"),
            "/packages/acme/widget/1.2.3",
        ),
        (Some("//evil.example"), "/tutorial"),
        (Some("/\\evil.example"), "/tutorial"),
        (Some("https://evil.example/tutorial"), "/tutorial"),
        (Some("javascript:alert(1)"), "/tutorial"),
        (Some("tutorial"), "/tutorial"),
        (Some("/tutorial\r\nSet-Cookie: x=1"), "/tutorial"),
        (Some("/tutorial\u{0}"), "/tutorial"),
        (Some("/tutorial\u{7f}"), "/tutorial"),
        (Some("/tutorial\\x"), "/tutorial"),
        (Some(long.as_str()), "/tutorial"),
        (Some("/no-such-page"), "/tutorial"),
        (Some("/account"), "/tutorial"),
        (Some("/%2F%2Fevil.example"), "/tutorial"),
        (Some("/tutorial/%2e%2e"), "/tutorial"),
        (Some("/tutorial/Hello"), "/tutorial"),
        (Some("/search?q=x"), "/tutorial"),
        (Some("/tutorial#x"), "/tutorial"),
    ];
    for (return_to, kept) in cases {
        let rig = Rig::new().await;
        let resp = rig.start(return_to).await;
        assert_eq!(resp.status, 302, "{return_to:?}");
        assert_eq!(stored_return_to(&rig), kept, "{return_to:?}");
    }
}

#[tokio::test]
async fn a_return_to_sent_twice_falls_back_to_the_tutorial() {
    let rig = Rig::new().await;
    let req = start_request(Some("/search")).with_query("return_to", "/");
    assert_eq!(rig.login.handle(&req).await.status, 302);
    assert_eq!(stored_return_to(&rig), "/tutorial");
}

#[tokio::test]
async fn a_return_to_that_is_still_percent_encoded_is_not_decoded_again() {
    let rig = Rig::new().await;
    // The HTTP layer decoded the query once: `%252F` arrived as `%2F`, which is in no route.
    rig.start(Some("/%2Ftutorial")).await;
    assert_eq!(stored_return_to(&rig), "/tutorial");
}

#[tokio::test]
async fn both_values_of_sec_fetch_site_that_come_from_the_site_itself_are_accepted() {
    for site in ["none", "same-origin"] {
        let rig = Rig::new().await;
        let req = WebRequest::new(Method::Get, START_PATH, REQUEST_ID)
            .with_header("x-mopm-edge", EDGE)
            .with_header("sec-fetch-mode", "navigate")
            .with_header("sec-fetch-dest", "document")
            .with_header("sec-fetch-site", site);
        assert_eq!(rig.login.handle(&req).await.status, 302, "{site}");
    }
}

use mopm_web::request::{Method, WebRequest};

use crate::login::START_PATH;

/// A request through the distribution with the given values of the three `Sec-Fetch-*` headers (each name sent once per
/// value, so an empty slice omits the header and two values duplicate it).
fn navigation(mode: &[&str], dest: &[&str], site: &[&str]) -> WebRequest {
    let mut req =
        WebRequest::new(Method::Get, START_PATH, REQUEST_ID).with_header("x-mopm-edge", EDGE);
    for (name, values) in [
        ("sec-fetch-mode", mode),
        ("sec-fetch-dest", dest),
        ("sec-fetch-site", site),
    ] {
        for value in values {
            req = req.with_header(name, value);
        }
    }
    req
}

#[tokio::test]
async fn a_request_that_is_not_a_top_level_navigation_is_refused_and_stores_nothing() {
    const M: &[&str] = &["navigate"];
    const D: &[&str] = &["document"];
    const S: &[&str] = &["none"];
    let cases: Vec<(&str, WebRequest)> = vec![
        ("mode missing", navigation(&[], D, S)),
        ("dest missing", navigation(M, &[], S)),
        ("site missing", navigation(M, D, &[])),
        (
            "mode duplicated",
            navigation(&["navigate", "navigate"], D, S),
        ),
        (
            "dest duplicated",
            navigation(M, &["document", "document"], S),
        ),
        ("site duplicated", navigation(M, D, &["none", "none"])),
        (
            "site duplicated with both accepted values",
            navigation(M, D, &["none", "same-origin"]),
        ),
        ("mode empty", navigation(&[""], D, S)),
        ("dest empty", navigation(M, &[""], S)),
        ("site empty", navigation(M, D, &[""])),
        ("mode cors", navigation(&["cors"], D, S)),
        ("mode no-cors", navigation(&["no-cors"], D, S)),
        ("mode same-origin", navigation(&["same-origin"], D, S)),
        ("mode websocket", navigation(&["websocket"], D, S)),
        ("mode in capitals", navigation(&["NAVIGATE"], D, S)),
        ("mode with a space", navigation(&["navigate "], D, S)),
        ("dest the value empty", navigation(M, &["empty"], S)),
        ("dest iframe", navigation(M, &["iframe"], S)),
        ("dest image", navigation(M, &["image"], S)),
        ("dest script", navigation(M, &["script"], S)),
        ("dest in capitals", navigation(M, &["Document"], S)),
        ("dest with a space", navigation(M, &["document "], S)),
        ("site cross-site", navigation(M, D, &["cross-site"])),
        ("site same-site", navigation(M, D, &["same-site"])),
        ("site in capitals", navigation(M, D, &["NONE"])),
        (
            "site same-origin in capitals",
            navigation(M, D, &["Same-Origin"]),
        ),
        ("site with a space", navigation(M, D, &["none "])),
        ("site as a list", navigation(M, D, &["same-origin,none"])),
    ];
    for (name, req) in cases {
        let rig = Rig::new().await;
        let resp = rig.login.handle(&req).await;
        assert_eq!(resp.status, 400, "{name}");
        assert_eq!(resp.body, ERROR_400, "{name}");
        assert!(resp.set_cookies.is_empty(), "{name}");
        assert_eq!(resp.header("location"), None, "{name}");
        assert_nothing_called(&rig);
    }
}

#[tokio::test]
async fn a_request_with_no_sec_fetch_headers_at_all_is_refused() {
    let rig = Rig::new().await;
    let req = WebRequest::new(Method::Get, START_PATH, REQUEST_ID).with_header("x-mopm-edge", EDGE);
    let resp = rig.login.handle(&req).await;
    assert_eq!((resp.status, resp.body.as_str()), (400, ERROR_400));
    assert_nothing_called(&rig);
}

#[tokio::test]
async fn a_request_without_the_edge_header_or_with_a_wrong_one_is_session_required_and_stores_nothing(
) {
    let navigation = |req: WebRequest| {
        req.with_header("sec-fetch-mode", "navigate")
            .with_header("sec-fetch-dest", "document")
            .with_header("sec-fetch-site", "none")
    };
    let bare = || WebRequest::new(Method::Get, START_PATH, REQUEST_ID);
    let cases = [
        navigation(bare()),
        navigation(bare().with_header("x-mopm-edge", "")),
        navigation(bare().with_header("x-mopm-edge", "wrong")),
        navigation(bare().with_header("x-mopm-edge", &format!("{EDGE} "))),
        navigation(
            bare()
                .with_header("x-mopm-edge", EDGE)
                .with_header("x-mopm-edge", EDGE),
        ),
    ];
    for req in cases {
        let rig = Rig::new().await;
        let resp = rig.login.handle(&req).await;
        assert_eq!(resp.status, 401);
        assert_eq!(resp.body, ERROR_401);
        assert!(resp.set_cookies.is_empty());
        assert_nothing_called(&rig);
    }
}

#[tokio::test]
async fn the_edge_check_comes_before_the_navigation_check() {
    let rig = Rig::new().await;
    let resp = rig
        .login
        .handle(&WebRequest::new(Method::Get, START_PATH, REQUEST_ID))
        .await;
    assert_eq!((resp.status, resp.body.as_str()), (401, ERROR_401));
}

#[tokio::test]
async fn a_failing_store_sends_the_browser_to_the_tutorial_as_unavailable_and_sets_no_cookie() {
    let rig = Rig::with(
        &grants_without("web_logins", "dynamodb:PutItem"),
        true,
        Loopback,
    )
    .await;
    let resp = rig.start(Some("/search")).await;
    assert_eq!(resp.status, 303);
    assert_eq!(
        resp.header("location"),
        Some("https://mopm.test/tutorial?error=unavailable")
    );
    assert_eq!(
        headers(&resp),
        vec![
            ("x-mopm-request-id", REQUEST_ID),
            ("cache-control", "no-store"),
            ("location", "https://mopm.test/tutorial?error=unavailable")
        ]
    );
    assert!(resp.set_cookies.is_empty());
    assert_eq!(resp.body, "");
    assert!(rig.dynamo.dump(WEB_LOGINS).is_empty());
}
