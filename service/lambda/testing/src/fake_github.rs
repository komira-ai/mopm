//! A fake of GitHub, as far as the web sign-in uses it (`docs/design/tutorial-sign-in.md` section 1): the OAuth web
//! flow's authorization step and code exchange, and `GET /user`, on a [`FakeHttp`] on loopback. One endpoint serves both
//! of GitHub's hosts (`github.com` and `api.github.com`).
//!
//! - **Authorization** is the browser's step, so it is a method, not a route: [`FakeGitHub::authorize`] takes the URL
//!   the registry redirected to and answers the callback URL GitHub would send the browser to, with a fresh code bound
//!   to the URL's `code_challenge`; [`FakeGitHub::deny`] answers the callback of a user who refused. A test that knows
//!   the verifier can add a code directly ([`FakeGitHub::add_grant`]).
//! - **`POST /login/oauth/access_token`** (a form body) answers a token only for the configured client id and secret,
//!   the configured `redirect_uri` when one is sent, a known unused code, and the `code_verifier` whose S256 is the code's
//!   challenge. Otherwise it answers GitHub's error (HTTP 200 with an `error` member, as GitHub does). The first exchange
//!   that passes those checks uses the code up. The answer is JSON when `Accept` names `application/json`, a form
//!   otherwise, as GitHub's.
//!   A wrong `code_verifier` answering `bad_verification_code` is the fake's choice: GitHub does not document which
//!   error it gives.
//! - **`GET /user`** answers the user of a token it issued (`Authorization: Bearer` or `token`), 401 otherwise. As on
//!   GitHub, `two_factor_authentication` is in the account's private view only, which a token gets with the `read:user`
//!   or `user` scope; the scope is the authorization URL's ([`Grant::new`] grants `read:user`).
//! - Any other route (method and path) is 404.
//! - **Outage mode** ([`FakeGitHub::set_outage`]) answers every request with a status, a dropped connection or nothing.
//!
//! Every request is recorded in full, so a test asserts the verifier and secret that were sent, and how many times a
//! token was used ([`FakeGitHub::token_uses`]).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::fake_http::{decode_form, encode_form, form_value, Answer, FakeHttp, Reply, Seen};

/// Where the registry sends the browser (on `github.com`).
pub const AUTHORIZE_PATH: &str = "/login/oauth/authorize";
/// The code exchange (on `github.com`).
pub const TOKEN_PATH: &str = "/login/oauth/access_token";
/// The signed-in user (on `api.github.com`).
pub const USER_PATH: &str = "/user";

/// The OAuth app the fake is: what the token exchange requires.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OAuthApp {
    pub client_id: String,
    pub client_secret: String,
    /// The callback URL; a `redirect_uri` must equal it exactly.
    pub redirect_uri: String,
}

impl OAuthApp {
    pub fn example() -> OAuthApp {
        OAuthApp {
            client_id: "Ov23liFakeClientId00".into(),
            client_secret: "fake-client-secret-0123456789".into(),
            redirect_uri: "https://mopm.test/api/v2/auth/web/callback".into(),
        }
    }
}

/// A GitHub account, as `GET /user` shows it to the account itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitHubUser {
    pub id: u64,
    pub login: String,
    /// `two_factor_authentication`; `None`: the member is absent (the registry's two-factor rule reads absent as not
    /// satisfied).
    pub two_factor: Option<bool>,
}

impl GitHubUser {
    /// An account with two-factor authentication on.
    pub fn new(id: u64, login: &str) -> GitHubUser {
        GitHubUser {
            id,
            login: login.into(),
            two_factor: Some(true),
        }
    }

    pub fn two_factor(self, two_factor: Option<bool>) -> GitHubUser {
        GitHubUser { two_factor, ..self }
    }

    /// The body of `GET /user`: `login`, `id` and `two_factor_authentication` when it is known.
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("login".into(), json!(self.login));
        m.insert("id".into(), json!(self.id));
        if let Some(on) = self.two_factor {
            m.insert("two_factor_authentication".into(), json!(on));
        }
        Value::Object(m)
    }
}

/// An error of the token endpoint, as GitHub names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenError {
    /// The code is unknown or used (and, in the fake, its verifier is wrong).
    BadVerificationCode,
    IncorrectClientCredentials,
    RedirectUriMismatch,
    /// The user refused; GitHub sends it on the callback ([`FakeGitHub::deny`]), and a grant can be scripted to answer
    /// it from the token endpoint too.
    AccessDenied,
}

impl TokenError {
    pub fn code(self) -> &'static str {
        match self {
            TokenError::BadVerificationCode => "bad_verification_code",
            TokenError::IncorrectClientCredentials => "incorrect_client_credentials",
            TokenError::RedirectUriMismatch => "redirect_uri_mismatch",
            TokenError::AccessDenied => "access_denied",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            TokenError::BadVerificationCode => "The code passed is incorrect or expired.",
            TokenError::IncorrectClientCredentials => {
                "The client_id and/or client_secret passed are incorrect."
            }
            TokenError::RedirectUriMismatch => {
                "The redirect_uri MUST match the registered callback URL for this application."
            }
            TokenError::AccessDenied => "The user has denied your application access.",
        }
    }

    /// `error`, `error_description` and `error_uri`, in GitHub's order. The `error_uri` is the troubleshooting page that
    /// documents the error: the token request's for a bad code or bad credentials, the authorization request's for the
    /// other two.
    pub fn pairs(self) -> [(&'static str, String); 3] {
        let page = match self {
            TokenError::BadVerificationCode | TokenError::IncorrectClientCredentials => {
                "troubleshooting-oauth-app-access-token-request-errors"
            }
            TokenError::RedirectUriMismatch | TokenError::AccessDenied => {
                "troubleshooting-authorization-request-errors"
            }
        };
        let anchor = self.code().replace('_', "-");
        [
            ("error", self.code().to_string()),
            ("error_description", self.description().to_string()),
            (
                "error_uri",
                format!("https://docs.github.com/apps/managing-oauth-apps/{page}/#{anchor}"),
            ),
        ]
    }
}

/// A code GitHub issued, and what exchanging it gives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grant {
    pub code: String,
    /// The S256 challenge the code is bound to ([`s256`] of the verifier).
    pub code_challenge: String,
    /// The scopes granted, comma-separated as GitHub answers them.
    pub scope: String,
    /// The user whose token the exchange answers, or the error it answers.
    pub outcome: Result<GitHubUser, TokenError>,
}

impl Grant {
    /// `code`, exchanged with `code_verifier`, answers a token for `user` with the scope `read:user`.
    pub fn new(code: &str, code_verifier: &str, user: GitHubUser) -> Grant {
        Grant {
            code: code.into(),
            code_challenge: s256(code_verifier),
            scope: "read:user".into(),
            outcome: Ok(user),
        }
    }

    /// `code`, exchanged with `code_verifier`, answers `error`.
    pub fn refused(code: &str, code_verifier: &str, error: TokenError) -> Grant {
        Grant {
            code: code.into(),
            code_challenge: s256(code_verifier),
            scope: "read:user".into(),
            outcome: Err(error),
        }
    }
}

/// PKCE's S256: base64url, without padding, of the SHA-256 of the verifier.
pub fn s256(code_verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(code_verifier.as_bytes()))
}

/// How every request is answered while GitHub is down.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outage {
    /// This status (a 5xx) and a short JSON body.
    Status(u16),
    /// The connection closes without an answer.
    Drop,
    /// No answer until the fake is dropped.
    Hang,
}

/// Why [`FakeGitHub::authorize`] or [`FakeGitHub::deny`] refused an authorization URL: GitHub would show an error page
/// and never call back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthorizeRefusal {
    /// The URL's path is not [`AUTHORIZE_PATH`].
    NotAuthorize,
    /// `client_id` is not the app's.
    UnknownClient,
    /// `redirect_uri` is missing or not exactly the app's.
    RedirectUriMismatch,
    /// `code_challenge` is missing, or `code_challenge_method` is not `S256`.
    NoS256Challenge,
}

struct State {
    app: OAuthApp,
    grants: Vec<Grant>,
    /// Issued tokens, oldest first.
    tokens: Vec<Issued>,
    outage: Option<Outage>,
    /// Codes issued by `authorize`.
    issued: u64,
}

/// The fake GitHub. Dropping it closes every connection, a hanging one included.
pub struct FakeGitHub {
    http: FakeHttp,
    state: Arc<Mutex<State>>,
}

/// A token the exchange gave, its user and its scope.
struct Issued {
    token: String,
    user: GitHubUser,
    scope: String,
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

impl FakeGitHub {
    /// Serves on the current tokio runtime, as `app`, with no grants.
    pub fn start(app: OAuthApp) -> FakeGitHub {
        let state = Arc::new(Mutex::new(State {
            app,
            grants: vec![],
            tokens: vec![],
            outage: None,
            issued: 0,
        }));
        let shared = state.clone();
        let http = FakeHttp::with_handler(move |seen| handle(&mut lock(&shared), seen));
        FakeGitHub { http, state }
    }

    /// `http://127.0.0.1:<port>`, in place of both `https://github.com` and `https://api.github.com`.
    pub fn endpoint(&self) -> String {
        self.http.endpoint()
    }

    /// The token an exchange of `code` answers.
    pub fn token_for(code: &str) -> String {
        format!("gho_fake_{code}")
    }

    /// Adds a code the token exchange accepts once.
    pub fn add_grant(&self, grant: Grant) {
        lock(&self.state).grants.push(grant);
    }

    /// The user signs in as `user` on the page of `authorize_url` and approves: the callback URL,
    /// `<redirect_uri>?code=<fresh code>&state=<the URL's state>` (`state` only when the URL has one). The code is bound
    /// to the URL's `code_challenge` and grants the URL's `scope`.
    pub fn authorize(
        &self,
        authorize_url: &str,
        user: GitHubUser,
    ) -> Result<String, AuthorizeRefusal> {
        let mut st = lock(&self.state);
        let (redirect_uri, query) = checked(&st.app, authorize_url)?;
        st.issued += 1;
        let code = format!("fake_code_{}", st.issued);
        let challenge = form_value(&query, "code_challenge")
            .unwrap_or_default()
            .to_string();
        let scope = form_value(&query, "scope").unwrap_or_default();
        let scope = scope
            .split([' ', ','])
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(",");
        st.grants.push(Grant {
            code: code.clone(),
            code_challenge: challenge,
            scope,
            outcome: Ok(user),
        });
        Ok(callback(&redirect_uri, &[("code", &code)], &query))
    }

    /// The user refuses on the page of `authorize_url`: the callback URL with GitHub's `access_denied`, and the URL's
    /// `state`.
    pub fn deny(&self, authorize_url: &str) -> Result<String, AuthorizeRefusal> {
        let (redirect_uri, query) = checked(&lock(&self.state).app, authorize_url)?;
        let pairs = TokenError::AccessDenied.pairs();
        let pairs: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (*k, v.as_str())).collect();
        Ok(callback(&redirect_uri, &pairs, &query))
    }

    /// From now on, every request is answered as `outage` says; `None` ends the outage.
    pub fn set_outage(&self, outage: Option<Outage>) {
        lock(&self.state).outage = outage;
    }

    /// Every request, oldest first, whatever its route.
    pub fn requests(&self) -> Vec<Seen> {
        self.http.requests()
    }

    /// The code exchanges (`POST /login/oauth/access_token`), oldest first; [`Seen::form`] reads their fields.
    pub fn token_requests(&self) -> Vec<Seen> {
        self.requests()
            .into_iter()
            .filter(|r| r.method == "POST" && r.path() == TOKEN_PATH)
            .collect()
    }

    /// How many `GET /user` requests carried `token`.
    pub fn token_uses(&self, token: &str) -> usize {
        self.requests()
            .iter()
            .filter(|r| r.method == "GET" && r.path() == USER_PATH && bearer(r) == Some(token))
            .count()
    }

    /// Returns once at least `n` requests are recorded (see [`FakeHttp::wait_for_requests`]).
    pub async fn wait_for_requests(&self, n: usize) {
        self.http.wait_for_requests(n).await
    }
}

/// The app's redirect URI and the URL's query, if GitHub would show the app's sign-in page for `url`.
fn checked(app: &OAuthApp, url: &str) -> Result<(String, Vec<(String, String)>), AuthorizeRefusal> {
    let (path, query) = url.split_once('?').unwrap_or((url, ""));
    if !path.ends_with(AUTHORIZE_PATH) {
        return Err(AuthorizeRefusal::NotAuthorize);
    }
    let query = decode_form(query);
    if form_value(&query, "client_id") != Some(app.client_id.as_str()) {
        return Err(AuthorizeRefusal::UnknownClient);
    }
    if form_value(&query, "redirect_uri") != Some(app.redirect_uri.as_str()) {
        return Err(AuthorizeRefusal::RedirectUriMismatch);
    }
    if form_value(&query, "code_challenge_method") != Some("S256")
        || form_value(&query, "code_challenge").is_none_or(str::is_empty)
    {
        return Err(AuthorizeRefusal::NoS256Challenge);
    }
    Ok((app.redirect_uri.clone(), query))
}

/// `redirect_uri?<pairs>&state=<state>`, `state` only when the authorization URL had one.
fn callback(redirect_uri: &str, pairs: &[(&str, &str)], query: &[(String, String)]) -> String {
    let mut pairs = pairs.to_vec();
    pairs.extend(form_value(query, "state").map(|s| ("state", s)));
    format!("{redirect_uri}?{}", encode_form(&pairs))
}

/// The token of an `Authorization: Bearer <token>` or `token <token>` header.
fn bearer(seen: &Seen) -> Option<&str> {
    let value = seen.header("authorization")?;
    value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("token "))
}

fn api_error(status: u16, message: &str) -> Reply {
    Reply::json(
        status,
        &json!({"message": message, "documentation_url": "https://docs.github.com/rest", "status": status.to_string()}),
    )
}

fn handle(st: &mut State, seen: &Seen) -> Answer {
    match st.outage {
        Some(Outage::Status(status)) => {
            return Answer::Reply(Reply::json(status, &json!({"message": "Server Error"})))
        }
        Some(Outage::Drop) => return Answer::Drop,
        Some(Outage::Hang) => return Answer::Hang,
        None => {}
    }
    Answer::Reply(match (seen.method.as_str(), seen.path()) {
        ("POST", TOKEN_PATH) => exchange(st, seen),
        ("GET", USER_PATH) => {
            match bearer(seen).and_then(|t| st.tokens.iter().find(|i| i.token == t)) {
                Some(issued) => Reply::json(200, &view(issued)),
                None => api_error(401, "Bad credentials"),
            }
        }
        _ => api_error(404, "Not Found"),
    })
}

/// The token exchange: a token, or GitHub's error, as JSON or a form after `Accept`.
fn exchange(st: &mut State, seen: &Seen) -> Reply {
    let json = seen
        .header("accept")
        .is_some_and(|a| a.contains("application/json"));
    let pairs: Vec<(&'static str, String)> = match redeem(st, &seen.form()) {
        Ok((token, scope)) => vec![
            ("access_token", token),
            ("token_type", "bearer".into()),
            ("scope", scope),
        ],
        Err(e) => e.pairs().to_vec(),
    };
    if json {
        Reply::json(
            200,
            &Value::Object(
                pairs
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), json!(v)))
                    .collect(),
            ),
        )
    } else {
        let pairs: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (*k, v.as_str())).collect();
        Reply::new(200)
            .header(
                "Content-Type",
                "application/x-www-form-urlencoded; charset=utf-8",
            )
            .body(encode_form(&pairs))
    }
}

/// Checks the exchange's fields in GitHub's order (client, redirect URI, code, verifier) and uses the code up.
fn redeem(st: &mut State, form: &[(String, String)]) -> Result<(String, String), TokenError> {
    let field = |name| form_value(form, name);
    if field("client_id") != Some(st.app.client_id.as_str())
        || field("client_secret") != Some(st.app.client_secret.as_str())
    {
        return Err(TokenError::IncorrectClientCredentials);
    }
    if field("redirect_uri").is_some_and(|r| r != st.app.redirect_uri) {
        return Err(TokenError::RedirectUriMismatch);
    }
    let code = field("code").unwrap_or_default();
    let verifier = field("code_verifier");
    let i = st
        .grants
        .iter()
        .position(|g| g.code == code && verifier.is_some_and(|v| s256(v) == g.code_challenge))
        .ok_or(TokenError::BadVerificationCode)?;
    let grant = st.grants.remove(i);
    let user = grant.outcome?;
    let token = FakeGitHub::token_for(&grant.code);
    st.tokens.push(Issued {
        token: token.clone(),
        user,
        scope: grant.scope.clone(),
    });
    Ok((token, grant.scope))
}

/// The user as the token sees it: `two_factor_authentication` is in the private view, which needs `read:user` or `user`.
fn view(issued: &Issued) -> Value {
    let private = issued
        .scope
        .split(',')
        .any(|s| s == "read:user" || s == "user");
    if private {
        issued.user.to_json()
    } else {
        GitHubUser {
            two_factor: None,
            ..issued.user.clone()
        }
        .to_json()
    }
}

#[cfg(test)]
#[path = "fake_github_tests.rs"]
mod tests;
