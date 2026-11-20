//! GitHub, over [`HttpClient`]: the authorize URL, the exchange of a code for an access token, and `GET /user`
//! (<https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps>). The access token is read
//! once, used once for `/user` and dropped: nothing stores or logs it.

use std::fmt;
use std::time::Duration;

use mopm_ports::http::{HttpClient, HttpRequest, HttpResponse, Method};
use serde::Deserialize;

use crate::oauth::OAuthApp;
use crate::outcome::{FailureCode, Refusal};

/// The `User-Agent` of every request to GitHub (GitHub's API refuses a request without one).
pub const USER_AGENT: &str = "mopm-registry";
/// The scope asked for: the account and its two-factor flag.
pub const SCOPE: &str = "read:user";
/// The longest the whole exchange with GitHub may take, connecting included. A field of the request.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);

/// Where GitHub's two hosts are: the browser's (`https://github.com`) and the API's (`https://api.github.com`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitHubEndpoints {
    web: String,
    api: String,
}

impl GitHubEndpoints {
    /// GitHub itself.
    pub fn production() -> GitHubEndpoints {
        GitHubEndpoints::new("https://github.com", "https://api.github.com")
    }

    /// `web` and `api` as base URLs without a trailing slash (a test points both at a fake).
    pub fn new(web: &str, api: &str) -> GitHubEndpoints {
        GitHubEndpoints {
            web: web.to_string(),
            api: api.to_string(),
        }
    }
}

/// GitHub's access token for one sign-in. `Debug` never shows it.
pub struct AccessToken(String);

impl fmt::Debug for AccessToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AccessToken(..)")
    }
}

/// The GitHub account a token belongs to: what `GET /user` says of it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Account {
    pub id: u64,
    pub login: String,
    /// Absent when GitHub does not show the field (the token is not the account's own).
    #[serde(default, rename = "two_factor_authentication")]
    pub two_factor: Option<bool>,
}

/// The URL the browser is sent to: GitHub's authorization page, asking for `read:user` with `state`, an S256
/// `challenge`, and the stage's exact `redirect_uri`.
pub fn authorize_url(
    endpoints: &GitHubEndpoints,
    app: &OAuthApp,
    redirect_uri: &str,
    state: &str,
    challenge: &str,
) -> String {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("client_id", app.client_id())
        .append_pair("redirect_uri", redirect_uri)
        .append_pair("scope", SCOPE)
        .append_pair("state", state)
        .append_pair("code_challenge", challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("prompt", "select_account")
        .finish();
    format!("{}/login/oauth/authorize?{query}", endpoints.web)
}

fn unavailable(reason: &'static str) -> Refusal {
    Refusal::new(FailureCode::Unavailable, reason)
}

async fn send(
    http: &impl HttpClient,
    req: HttpRequest,
    no_answer: &'static str,
) -> Result<HttpResponse, Refusal> {
    http.send(req).await.map_err(|_| unavailable(no_answer))
}

/// GitHub's answer to the token request: a token, or an error code.
#[derive(Deserialize)]
struct TokenAnswer {
    access_token: Option<String>,
    error: Option<String>,
}

/// Exchanges `code` for an access token (`POST /login/oauth/access_token`), with the app's secret and the PKCE
/// `verifier`. A refusal says what the sign-in becomes: `access_denied` is `access_denied`, `bad_verification_code`
/// is `login_expired`, and everything else (an HTTP status, an answer that is not JSON, any other error, no token,
/// no answer at all) is `unavailable`.
pub async fn exchange_code(
    http: &impl HttpClient,
    endpoints: &GitHubEndpoints,
    app: &OAuthApp,
    redirect_uri: &str,
    code: &str,
    verifier: &str,
) -> Result<AccessToken, Refusal> {
    let body = form_urlencoded::Serializer::new(String::new())
        .append_pair("client_id", app.client_id())
        .append_pair("client_secret", app.client_secret())
        .append_pair("code", code)
        .append_pair("redirect_uri", redirect_uri)
        .append_pair("code_verifier", verifier)
        .finish();
    let req = HttpRequest {
        method: Method::Post,
        url: format!("{}/login/oauth/access_token", endpoints.web),
        headers: vec![
            ("Accept".to_string(), "application/json".to_string()),
            (
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            ),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
        ],
        body: body.into_bytes(),
        timeout: REQUEST_TIMEOUT,
    };
    let answer = send(http, req, "GitHub's token endpoint did not answer").await?;
    if !(200..300).contains(&answer.status) {
        return Err(unavailable(
            "GitHub's token endpoint answered with an error status",
        ));
    }
    let TokenAnswer {
        access_token,
        error,
    } = serde_json::from_slice(&answer.body).map_err(|_| {
        unavailable("GitHub's token endpoint did not answer with the expected JSON")
    })?;
    match (access_token, error.as_deref()) {
        (Some(token), _) if !token.is_empty() => Ok(AccessToken(token)),
        (_, Some("access_denied")) => Err(Refusal::new(
            FailureCode::AccessDenied,
            "GitHub's token endpoint refused: access_denied",
        )),
        (_, Some("bad_verification_code")) => Err(Refusal::new(
            FailureCode::LoginExpired,
            "GitHub's token endpoint refused: bad_verification_code",
        )),
        (_, Some(_)) => Err(unavailable("GitHub's token endpoint refused the exchange")),
        (_, None) => Err(unavailable("GitHub's token endpoint gave no access token")),
    }
}

/// Reads the account `token` belongs to (`GET /user`). Anything but a 200 with the account is `unavailable`.
pub async fn fetch_account(
    http: &impl HttpClient,
    endpoints: &GitHubEndpoints,
    token: &AccessToken,
) -> Result<Account, Refusal> {
    let req = HttpRequest {
        method: Method::Get,
        url: format!("{}/user", endpoints.api),
        headers: vec![
            ("Authorization".to_string(), format!("Bearer {}", token.0)),
            (
                "Accept".to_string(),
                "application/vnd.github+json".to_string(),
            ),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
        ],
        body: Vec::new(),
        timeout: REQUEST_TIMEOUT,
    };
    let answer = send(http, req, "GitHub's user endpoint did not answer").await?;
    if answer.status != 200 {
        return Err(unavailable("GitHub's user endpoint did not answer 200"));
    }
    serde_json::from_slice(&answer.body)
        .map_err(|_| unavailable("GitHub's user endpoint did not answer with the expected JSON"))
}

#[cfg(test)]
#[path = "github_tests.rs"]
mod tests;
