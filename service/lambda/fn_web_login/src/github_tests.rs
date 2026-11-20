//! GitHub's three calls against a scripted `HttpClient`: the requests as sent, exactly, and what every answer becomes.

use mopm_ports::http::{HttpError, HttpFailure};
use mopm_testing::scripted_http::ScriptedHttp;

use super::*;
use crate::test_support::oauth_app;

fn endpoints() -> GitHubEndpoints {
    GitHubEndpoints::new("https://github.test", "https://api.github.test")
}

fn reply(status: u16, body: &str) -> Result<HttpResponse, HttpError> {
    Ok(HttpResponse {
        status,
        headers: vec![],
        body: body.as_bytes().to_vec(),
    })
}

fn no_answer(failure: HttpFailure) -> Result<HttpResponse, HttpError> {
    Err(HttpError {
        failure,
        detail: "github.test:443".to_string(),
    })
}

async fn exchange(answer: Result<HttpResponse, HttpError>) -> Result<AccessToken, Refusal> {
    let http = ScriptedHttp::new(vec![answer]);
    exchange_code(
        &http,
        &endpoints(),
        &oauth_app().await,
        "https://mopm.test/api/v2/auth/web/callback",
        "the-code",
        "the-verifier",
    )
    .await
}

async fn account(answer: Result<HttpResponse, HttpError>) -> Result<Account, Refusal> {
    let http = ScriptedHttp::new(vec![answer]);
    fetch_account(&http, &endpoints(), &AccessToken("gho_example".to_string())).await
}

fn refusal(code: FailureCode, reason: &'static str) -> Result<(), Refusal> {
    Err(Refusal::new(code, reason))
}

#[test]
fn the_production_endpoints_are_githubs_two_hosts() {
    let production = GitHubEndpoints::production();
    assert_eq!(
        production,
        GitHubEndpoints::new("https://github.com", "https://api.github.com")
    );
}

#[tokio::test]
async fn the_authorize_url_asks_for_read_user_with_the_s256_challenge_and_the_exact_redirect_uri() {
    let url = authorize_url(
        &GitHubEndpoints::production(),
        &oauth_app().await,
        "https://mopm.test/api/v2/auth/web/callback",
        "state-1",
        "challenge-1",
    );
    assert_eq!(
        url,
        "https://github.com/login/oauth/authorize?client_id=Ov23liFakeClientId00&redirect_uri=https%3A%2F%2Fmopm.test%2Fapi%2Fv2%2Fauth%2Fweb%2Fcallback\
         &scope=read%3Auser&state=state-1&code_challenge=challenge-1&code_challenge_method=S256&prompt=select_account"
    );
}

#[tokio::test]
async fn the_token_request_is_the_form_github_documents_with_the_secret_and_the_verifier() {
    let http = ScriptedHttp::new(vec![reply(
        200,
        r#"{"access_token":"gho_example","token_type":"bearer","scope":"read:user"}"#,
    )]);
    let app = oauth_app().await;
    let token = exchange_code(
        &http,
        &endpoints(),
        &app,
        "https://mopm.test/api/v2/auth/web/callback",
        "the code&",
        "the-verifier",
    )
    .await
    .unwrap();
    assert_eq!(token.0, "gho_example");
    let expected = HttpRequest {
        method: Method::Post,
        url: "https://github.test/login/oauth/access_token".to_string(),
        headers: vec![
            ("Accept".to_string(), "application/json".to_string()),
            ("Content-Type".to_string(), "application/x-www-form-urlencoded".to_string()),
            ("User-Agent".to_string(), "mopm-registry".to_string()),
        ],
        body: "client_id=Ov23liFakeClientId00&client_secret=fake-client-secret-0123456789&code=the+code%26&redirect_uri=https%3A%2F%2Fmopm.test%2Fapi%2Fv2%2Fauth%2Fweb%2Fcallback&code_verifier=the-verifier"
            .as_bytes()
            .to_vec(),
        timeout: Duration::from_secs(8),
    };
    assert_eq!(http.requests(), vec![expected]);
}

#[tokio::test]
async fn an_answer_with_a_token_is_the_token_whatever_else_it_says() {
    assert_eq!(
        exchange(reply(200, r#"{"access_token":"gho_a","error":"ignored"}"#))
            .await
            .unwrap()
            .0,
        "gho_a"
    );
    assert_eq!(
        exchange(reply(201, r#"{"access_token":"gho_b"}"#))
            .await
            .unwrap()
            .0,
        "gho_b"
    );
}

#[tokio::test]
async fn the_two_errors_the_flow_knows_are_their_own_codes() {
    let denied = exchange(reply(200, r#"{"error":"access_denied","error_description":"The user has denied your application access."}"#)).await;
    assert_eq!(
        denied.map(|_| ()),
        refusal(
            FailureCode::AccessDenied,
            "GitHub's token endpoint refused: access_denied"
        )
    );
    let bad_code = exchange(reply(200, r#"{"error":"bad_verification_code"}"#)).await;
    assert_eq!(
        bad_code.map(|_| ()),
        refusal(
            FailureCode::LoginExpired,
            "GitHub's token endpoint refused: bad_verification_code"
        )
    );
}

#[tokio::test]
async fn every_other_token_answer_is_unavailable() {
    let unavailable = |reason| refusal(FailureCode::Unavailable, reason);
    let cases = [
        (
            reply(200, r#"{"error":"incorrect_client_credentials"}"#),
            "GitHub's token endpoint refused the exchange",
        ),
        (
            reply(200, r#"{"error":"redirect_uri_mismatch"}"#),
            "GitHub's token endpoint refused the exchange",
        ),
        (
            reply(200, r#"{"error":""}"#),
            "GitHub's token endpoint refused the exchange",
        ),
        (
            reply(200, r#"{"access_token":"","error":"server_error"}"#),
            "GitHub's token endpoint refused the exchange",
        ),
        (
            reply(200, "{}"),
            "GitHub's token endpoint gave no access token",
        ),
        (
            reply(200, r#"{"access_token":""}"#),
            "GitHub's token endpoint gave no access token",
        ),
        (
            reply(200, r#"{"access_token":null}"#),
            "GitHub's token endpoint gave no access token",
        ),
        (
            reply(200, r#"{"access_token":5}"#),
            "GitHub's token endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, "access_token=gho_a&token_type=bearer"),
            "GitHub's token endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, ""),
            "GitHub's token endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, "[]"),
            "GitHub's token endpoint did not answer with the expected JSON",
        ),
        (
            reply(500, r#"{"access_token":"gho_a"}"#),
            "GitHub's token endpoint answered with an error status",
        ),
        (
            reply(302, ""),
            "GitHub's token endpoint answered with an error status",
        ),
        (
            reply(199, ""),
            "GitHub's token endpoint answered with an error status",
        ),
        (
            reply(403, r#"{"error":"access_denied"}"#),
            "GitHub's token endpoint answered with an error status",
        ),
        (
            no_answer(HttpFailure::Timeout),
            "GitHub's token endpoint did not answer",
        ),
        (
            no_answer(HttpFailure::Connect),
            "GitHub's token endpoint did not answer",
        ),
        (
            no_answer(HttpFailure::Tls),
            "GitHub's token endpoint did not answer",
        ),
    ];
    for (answer, reason) in cases {
        let shown = format!("{answer:?}");
        assert_eq!(
            exchange(answer).await.map(|_| ()),
            unavailable(reason),
            "{shown}"
        );
    }
}

#[tokio::test]
async fn a_scripted_http_with_no_answer_left_is_a_failure_to_reach_github() {
    let http = ScriptedHttp::new(vec![]);
    let result = fetch_account(&http, &endpoints(), &AccessToken("gho_example".to_string())).await;
    assert_eq!(
        result,
        Err(Refusal::new(
            FailureCode::Unavailable,
            "GitHub's user endpoint did not answer"
        ))
    );
}

#[tokio::test]
async fn the_user_request_carries_the_token_as_a_bearer_and_nowhere_else() {
    let http = ScriptedHttp::new(vec![reply(
        200,
        r#"{"id":4242,"login":"Alice-Dev","two_factor_authentication":true}"#,
    )]);
    let got = fetch_account(&http, &endpoints(), &AccessToken("gho_example".to_string()))
        .await
        .unwrap();
    assert_eq!(
        got,
        Account {
            id: 4242,
            login: "Alice-Dev".to_string(),
            two_factor: Some(true)
        }
    );
    let expected = HttpRequest {
        method: Method::Get,
        url: "https://api.github.test/user".to_string(),
        headers: vec![
            (
                "Authorization".to_string(),
                "Bearer gho_example".to_string(),
            ),
            (
                "Accept".to_string(),
                "application/vnd.github+json".to_string(),
            ),
            ("User-Agent".to_string(), "mopm-registry".to_string()),
        ],
        body: vec![],
        timeout: Duration::from_secs(8),
    };
    assert_eq!(http.requests(), vec![expected]);
}

#[tokio::test]
async fn the_two_factor_flag_is_what_github_shows_and_absent_when_it_does_not() {
    let some = |two_factor| {
        Ok(Account {
            id: 7,
            login: "bob".to_string(),
            two_factor,
        })
    };
    assert_eq!(
        account(reply(
            200,
            r#"{"id":7,"login":"bob","two_factor_authentication":false,"email":"x@example.test"}"#
        ))
        .await,
        some(Some(false))
    );
    assert_eq!(
        account(reply(200, r#"{"id":7,"login":"bob"}"#)).await,
        some(None)
    );
    assert_eq!(
        account(reply(
            200,
            r#"{"id":7,"login":"bob","two_factor_authentication":null}"#
        ))
        .await,
        some(None)
    );
}

#[tokio::test]
async fn every_user_answer_that_is_not_the_account_is_unavailable() {
    let cases = [
        (
            reply(401, r#"{"message":"Bad credentials"}"#),
            "GitHub's user endpoint did not answer 200",
        ),
        (reply(500, ""), "GitHub's user endpoint did not answer 200"),
        (
            reply(201, r#"{"id":7,"login":"bob"}"#),
            "GitHub's user endpoint did not answer 200",
        ),
        (
            reply(200, ""),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, r#"{"login":"bob"}"#),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, r#"{"id":"7","login":"bob"}"#),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, r#"{"id":-7,"login":"bob"}"#),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            reply(200, r#"{"id":7}"#),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            reply(
                200,
                r#"{"id":7,"login":"bob","two_factor_authentication":"yes"}"#,
            ),
            "GitHub's user endpoint did not answer with the expected JSON",
        ),
        (
            no_answer(HttpFailure::Timeout),
            "GitHub's user endpoint did not answer",
        ),
        (
            no_answer(HttpFailure::Connect),
            "GitHub's user endpoint did not answer",
        ),
    ];
    for (answer, reason) in cases {
        let shown = format!("{answer:?}");
        assert_eq!(
            account(answer).await,
            Err(Refusal::new(FailureCode::Unavailable, reason)),
            "{shown}"
        );
    }
}

#[test]
fn the_access_token_never_shows_in_debug() {
    assert_eq!(
        format!("{:?}", AccessToken("gho_secret".to_string())),
        "AccessToken(..)"
    );
}

#[test]
fn failure_codes_are_the_fixed_list() {
    let all = [
        FailureCode::AccessDenied,
        FailureCode::TwoFactorRequired,
        FailureCode::LoginExpired,
        FailureCode::Unavailable,
    ];
    assert_eq!(
        all.map(|c| c.to_string()),
        [
            "access_denied",
            "two_factor_required",
            "login_expired",
            "unavailable"
        ]
    );
    let refused = Refusal::new(FailureCode::TwoFactorRequired, "why").for_account(9);
    assert_eq!(
        refused,
        Refusal {
            code: FailureCode::TwoFactorRequired,
            reason: "why",
            github_id: Some(9)
        }
    );
}
