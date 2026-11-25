//! What the tests of this crate share: a plain-HTTP `HttpClient` for the fakes, a rig of the function over a fake
//! DynamoDB (under the function role's grants) and a fake GitHub, request builders, and the log capture.

use std::cell::RefCell;
use std::io;
use std::sync::{Arc, Once};

use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use mopm_ports::env::Clock;
use mopm_ports::error::PortResult;
use mopm_ports::http::{HttpClient, HttpError, HttpFailure, HttpRequest, HttpResponse};
use mopm_testing::env::{FixedClock, SeededRng};
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, Grants};
use mopm_testing::fake_github::{FakeGitHub, GitHubUser, OAuthApp as FakeApp};
use mopm_testing::memory_publish::MemorySecrets;
use mopm_web::edge::EdgeCheck;
use mopm_web::request::{Method, WebRequest};
use mopm_web::response::WebResponse;
use mopm_web::settings::{parse_function_name, Stage, StageSettings};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::github::GitHubEndpoints;
use crate::login::{WebLogin, CALLBACK_PATH, START_PATH};
use crate::oauth::OAuthApp;

/// 2026-11-19T12:00:00.000Z: the moment `tests/fixtures/device_login_rows.json` is written for.
pub const NOW_MS: i64 = 1_795_089_600_000;
pub const NOW_ISO: &str = "2026-11-19T12:00:00.000Z";
/// The stage's edge value.
pub const EDGE: &str = "edge-secret-value-for-tests";
pub const SITE: &str = "https://mopm.test";
pub const REQUEST_ID: &str = "req-7f3a2c19d0e4";
/// The function role's grants (`tests/fixtures/role_grants.json`) and the rows the device login writes.
pub const ROLE_GRANTS: &str = include_str!("../tests/fixtures/role_grants.json");
pub const DEVICE_LOGIN_ROWS: &str = include_str!("../tests/fixtures/device_login_rows.json");

pub const USERS: &str = "mopm-t-users";
pub const NAMESPACES: &str = "mopm-t-namespaces";
pub const TOKENS: &str = "mopm-t-tokens";
pub const WEB_LOGINS: &str = "mopm-t-web_logins";

/// An `HttpClient` over plain HTTP/1.1 on loopback, for the fakes of `mopm_testing` (which close every connection after
/// one answer). The request goes out exactly as built; its timeout is never waited on.
pub struct Loopback;

impl HttpClient for Loopback {
    async fn send(&self, req: HttpRequest) -> PortResult<HttpResponse> {
        let rest = req
            .url
            .strip_prefix("http://")
            .expect("a fake's http:// URL");
        let (addr, target) = rest.split_at(rest.find('/').expect("a path"));
        let mut head = format!(
            "{} {target} HTTP/1.1\r\nHost: {addr}\r\n",
            req.method.as_str()
        );
        for (k, v) in &req.headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str(&format!("Content-Length: {}\r\n\r\n", req.body.len()));
        let mut stream = TcpStream::connect(addr)
            .await
            .expect("a connection to the fake");
        stream
            .write_all(head.as_bytes())
            .await
            .expect("the head is written");
        stream
            .write_all(&req.body)
            .await
            .expect("the body is written");
        let mut raw = Vec::new();
        stream
            .read_to_end(&mut raw)
            .await
            .expect("the answer is read");
        // A connection that closed with no answer is what a dropped one looks like to the real client too.
        let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
            return Err(HttpError {
                failure: HttpFailure::Connect,
                detail: "the connection closed before an answer".to_string(),
            }
            .into());
        };
        let text = String::from_utf8(raw[..end].to_vec()).expect("a UTF-8 head");
        let mut lines = text.lines();
        let status = lines
            .next()
            .and_then(|l| l.split(' ').nth(1))
            .and_then(|s| s.parse().ok())
            .expect("a status");
        let headers = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
            .collect();
        Ok(HttpResponse {
            status,
            headers,
            body: raw[end + 4..].to_vec(),
        })
    }
}

/// A clock a test moves, shared with the stores that take an `Arc<dyn Clock>`.
#[derive(Clone)]
pub struct SharedClock(pub Arc<FixedClock>);

impl Clock for SharedClock {
    fn now(&self) -> jiff::Timestamp {
        self.0.now()
    }
}

pub fn stage() -> Stage {
    parse_function_name(Some(std::ffi::OsStr::new("mopm-t-web-login")))
        .expect("a function name")
        .stage
}

pub fn settings(require_two_factor: bool) -> StageSettings {
    StageSettings::from_item(json!({
        "redirect_uri": format!("{SITE}/api/v2/auth/web/callback"),
        "site_origin": SITE,
        "require_2fa": require_two_factor,
        "e2b_template_id": "tpl-test",
        "e2b_domain": "e2b.test",
        "sandbox_timeout_s": 1800,
    }))
    .expect("valid settings")
}

/// The OAuth app of the fake GitHub, as the stage's secret holds it.
pub async fn oauth_app() -> OAuthApp {
    let fake = FakeApp::example();
    let secrets = MemorySecrets::new();
    secrets.set(
        "mopm/t/github-oauth",
        &json!({"client_id": fake.client_id, "client_secret": fake.client_secret}).to_string(),
    );
    OAuthApp::load(&secrets, &stage())
        .await
        .expect("a valid secret")
}

pub async fn edge_check() -> EdgeCheck {
    let secrets = MemorySecrets::new();
    secrets.set("mopm/t/edge-origin", EDGE);
    EdgeCheck::load(&secrets, &stage())
        .await
        .expect("a valid secret")
}

pub fn dynamo_client(endpoint: &str) -> aws_sdk_dynamodb::Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new(
            "AKIDFAKE",
            "fakesecret",
            None,
            None,
            "static",
        ))
        .build();
    aws_sdk_dynamodb::Client::from_conf(config)
}

/// `grants` (JSON as in `role_grants.json`) without `action` on `table`.
pub fn grants_without(table: &str, action: &str) -> String {
    let mut grants: Value = serde_json::from_str(ROLE_GRANTS).expect("grants are JSON");
    let actions = grants[table]["actions"]
        .as_array_mut()
        .expect("a table of the grants");
    let before = actions.len();
    actions.retain(|a| a != action);
    assert_eq!(
        actions.len() + 1,
        before,
        "{action} is one of {table}'s grants"
    );
    grants.to_string()
}

pub type TestLogin<H> = WebLogin<
    mopm_aws::dynamo::DynamoAuthStore,
    mopm_aws::dynamo::DynamoNamespaceStore,
    mopm_aws::dynamo::DynamoWebLoginStore,
    H,
    SharedClock,
    SeededRng,
>;

/// The function over a fake DynamoDB that holds the role to `grants`, a fake GitHub, and the clock at `NOW_MS`.
pub struct Rig<H> {
    pub login: TestLogin<H>,
    pub dynamo: FakeDynamo,
    pub github: FakeGitHub,
    pub clock: Arc<FixedClock>,
}

impl Rig<Loopback> {
    /// The role as `role_grants.json` has it, two-factor required.
    pub async fn new() -> Rig<Loopback> {
        Rig::with(ROLE_GRANTS, true, Loopback).await
    }
}

impl<H: HttpClient> Rig<H> {
    pub async fn with(grants: &str, require_two_factor: bool, http: H) -> Rig<H> {
        let config = FakeConfig::registry("t")
            .with_grants("mopm-t-", Grants::parse(grants).expect("grants are JSON"));
        let dynamo = FakeDynamo::start(config);
        let github = FakeGitHub::start(FakeApp::example());
        let clock = Arc::new(FixedClock::at_millis(NOW_MS));
        let client = dynamo_client(&dynamo.endpoint());
        let shared: Arc<dyn Clock> = clock.clone();
        let login = WebLogin {
            settings: settings(require_two_factor),
            edge: edge_check().await,
            app: oauth_app().await,
            github: GitHubEndpoints::new(&github.endpoint(), &github.endpoint()),
            auth: mopm_aws::dynamo::DynamoAuthStore::new(
                client.clone(),
                mopm_aws::dynamo::AuthTables::for_stage("t"),
                shared,
            ),
            namespaces: mopm_aws::dynamo::DynamoNamespaceStore::new(
                client.clone(),
                "mopm-t-namespaces".to_string(),
            ),
            logins: mopm_aws::dynamo::DynamoWebLoginStore::new(
                client,
                "mopm-t-web_logins".to_string(),
            ),
            http,
            clock: SharedClock(clock.clone()),
            rng: SeededRng::new(7),
        };
        Rig {
            login,
            dynamo,
            github,
            clock,
        }
    }

    /// Every table's items, as one string (to look for a value in any of them).
    pub fn all_tables(&self) -> String {
        [USERS, NAMESPACES, TOKENS, WEB_LOGINS]
            .iter()
            .map(|t| Value::Array(self.dynamo.dump(t)).to_string())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The tables a sign-in can write, as `(users, namespaces, tokens, web_logins)`.
    pub fn tables(&self) -> [Vec<Value>; 4] {
        [USERS, NAMESPACES, TOKENS, WEB_LOGINS].map(|t| self.dynamo.dump(t))
    }

    /// A browser's `GET start`, as the distribution forwards it.
    pub async fn start(&self, return_to: Option<&str>) -> WebResponse {
        self.login.handle(&start_request(return_to)).await
    }

    /// The callback of `callback_url` (the fake GitHub's `authorize` answer), with the login cookie of `start`'s answer
    /// and `extra_cookies` (a `Cookie` header value) if any.
    pub async fn callback(
        &self,
        callback_url: &str,
        started: &WebResponse,
        extra_cookies: &str,
    ) -> WebResponse {
        let cookie = format!(
            "{}={}",
            LOGIN,
            cookie_value(started, LOGIN).expect("a login cookie")
        );
        let cookies = if extra_cookies.is_empty() {
            cookie
        } else {
            format!("{cookie}; {extra_cookies}")
        };
        self.login
            .handle(&callback_request(callback_url, &cookies))
            .await
    }

    /// A sign-in up to the callback: start (to `return_to`), then GitHub's authorize of `user` at the Location.
    pub async fn begin(&self, user: GitHubUser, return_to: Option<&str>) -> Begun {
        let started = self.start(return_to).await;
        let authorize_url = started.header("location").expect("a Location").to_string();
        let callback_url = self
            .github
            .authorize(&authorize_url, user)
            .expect("GitHub accepts the authorize URL");
        Begun {
            started,
            authorize_url,
            callback_url,
        }
    }

    /// A whole sign-in of `user`: [`Rig::begin`], then the callback with `extra_cookies`.
    pub async fn sign_in(
        &self,
        user: GitHubUser,
        return_to: Option<&str>,
        extra_cookies: &str,
    ) -> SignIn {
        let begun = self.begin(user, return_to).await;
        let finished = self
            .callback(&begun.callback_url, &begun.started, extra_cookies)
            .await;
        SignIn { begun, finished }
    }
}

pub const LOGIN: &str = "__Host-mopm_login";
pub const SESSION: &str = "__Host-mopm_session";

/// A sign-in that has started and been authorized at GitHub, and not come back yet.
pub struct Begun {
    pub started: WebResponse,
    pub authorize_url: String,
    pub callback_url: String,
}

impl Begun {
    pub fn txn(&self) -> String {
        cookie_value(&self.started, LOGIN).expect("a login cookie")
    }

    pub fn code(&self) -> String {
        query_value(&self.callback_url, "code").expect("a code")
    }

    pub fn state(&self) -> String {
        query_value(&self.authorize_url, "state").expect("a state")
    }
}

/// A sign-in that came back.
pub struct SignIn {
    pub begun: Begun,
    pub finished: WebResponse,
}

impl std::ops::Deref for SignIn {
    type Target = Begun;

    fn deref(&self) -> &Begun {
        &self.begun
    }
}

impl SignIn {
    /// The session token the browser was given, if it was given one.
    pub fn session(&self) -> Option<String> {
        cookie_value(&self.finished, SESSION)
    }
}

/// The callback URL of GitHub's answer for `code` and `state`.
pub fn callback_url(code: &str, state: &str) -> String {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("code", code)
        .append_pair("state", state)
        .finish();
    format!("{SITE}/api/v2/auth/web/callback?{query}")
}

/// A request to `path` of the site, from a browser through the distribution: the edge header.
fn request(path: &str) -> WebRequest {
    WebRequest::new(Method::Get, path, REQUEST_ID).with_header("x-mopm-edge", EDGE)
}

/// A top-level navigation to `start`.
pub fn start_request(return_to: Option<&str>) -> WebRequest {
    let req = request(START_PATH)
        .with_header("sec-fetch-mode", "navigate")
        .with_header("sec-fetch-dest", "document")
        .with_header("sec-fetch-site", "none");
    match return_to {
        Some(r) => req.with_query("return_to", r),
        None => req,
    }
}

/// The callback GitHub sent the browser to (`url` holds the query), with `cookies` (a `Cookie` header value).
pub fn callback_request(url: &str, cookies: &str) -> WebRequest {
    let query = url.split_once('?').map_or("", |(_, q)| q);
    let mut req = request(CALLBACK_PATH).with_cookies(cookies);
    for (k, v) in form_urlencoded::parse(query.as_bytes()) {
        req = req.with_query(&k, &v);
    }
    req
}

/// `req` with its `x-mopm-edge` header replaced by `value` (no such header for `None`).
pub fn with_edge(mut req: WebRequest, value: Option<&str>) -> WebRequest {
    let kept: Vec<(String, String)> = req
        .headers
        .iter()
        .filter(|(name, _)| *name != "x-mopm-edge")
        .map(|(n, v)| (n.to_string(), v.to_string()))
        .collect();
    req.headers = Default::default();
    for (name, v) in kept {
        req.headers.push(&name, &v);
    }
    match value {
        Some(v) => req.with_header("x-mopm-edge", v),
        None => req,
    }
}

/// The value of the query parameter `name` of `url`.
pub fn query_value(url: &str, name: &str) -> Option<String> {
    let query = url.split_once('?').map_or("", |(_, q)| q);
    form_urlencoded::parse(query.as_bytes())
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

/// The value the response sets the cookie `name` to (empty for a clearing cookie); `None` when it sets no such cookie.
pub fn cookie_value(resp: &WebResponse, name: &str) -> Option<String> {
    resp.set_cookies.iter().find_map(|c| {
        c.as_str()
            .strip_prefix(&format!("{name}="))
            .map(|rest| rest.split(';').next().unwrap_or_default().to_string())
    })
}

/// Every `Set-Cookie` of the response, as sent.
pub fn set_cookies(resp: &WebResponse) -> Vec<&str> {
    resp.set_cookies.iter().map(|c| c.as_str()).collect()
}

/// The response's headers, as (name, value).
pub fn headers(resp: &WebResponse) -> Vec<(&str, &str)> {
    resp.headers
        .iter()
        .map(|(n, v)| (n.as_str(), v.as_str()))
        .collect()
}

pub const CLEAR_LOGIN: &str =
    "__Host-mopm_login=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0";

/// A redirect to the tutorial page with `error`, with the login cookie cleared and nothing else set.
pub fn assert_refused_with(resp: &WebResponse, error: &str) {
    assert_eq!(resp.status, 303, "{resp:?}");
    assert_eq!(
        resp.header("location"),
        Some(format!("{SITE}/tutorial?error={error}").as_str())
    );
    assert_eq!(resp.header("referrer-policy"), Some("no-referrer"));
    assert_eq!(resp.header("cache-control"), Some("no-store"));
    assert_eq!(set_cookies(resp), vec![CLEAR_LOGIN]);
    assert_eq!(resp.body, "");
}

/// A fake GitHub user (two-factor on) of the fixture: `Alice-Dev`, 4242.
pub fn alice() -> GitHubUser {
    GitHubUser::new(4242, "Alice-Dev")
}

thread_local! {
    /// What this thread has logged: each test runs on a thread of its own, so a test's log is its own.
    static LOG: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

static INSTALLED: Once = Once::new();

/// The log of the test's own thread. One subscriber, the function's own ([`crate::runtime::subscriber`]), is the process's
/// default for every test and writes to the thread-local buffer, so tests that log at the same time never meet, and
/// no callsite is cached against a subscriber a parallel test has just dropped.
#[derive(Clone, Copy)]
pub struct LogBuf;

impl LogBuf {
    /// Starts this thread's capture: the subscriber is installed (once) and the thread's log emptied.
    pub fn capture(&self) -> Capture {
        INSTALLED.call_once(|| {
            load_native_roots_before_the_log();
            tracing::subscriber::set_global_default(crate::runtime::subscriber(|| LogBuf))
                .expect("no other test installs a subscriber");
        });
        LOG.with(|log| log.borrow_mut().clear());
        Capture
    }

    /// Everything this thread logged since its capture started, one string per line.
    pub fn lines(&self) -> Vec<String> {
        LOG.with(|log| {
            String::from_utf8(log.borrow().clone())
                .expect("the log is UTF-8")
                .lines()
                .map(str::to_string)
                .collect()
        })
    }

    pub fn text(&self) -> String {
        self.lines().join("\n")
    }
}

/// The SDK's HTTPS client reads the system's root certificates once per process, on the first request any client
/// sends, and logs a warning when there are none (a build worker may have none). One request here, before the
/// subscriber is installed, makes that read happen with nobody listening, so no test's log holds the warning, whichever
/// test would otherwise send the process's first request. The request goes to a loopback port with no listener and is
/// refused; only the connector it builds matters, and it is not retried.
fn load_native_roots_before_the_log() {
    std::thread::spawn(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("a runtime for the warm-up request");
        runtime.block_on(async {
            let closed = std::net::TcpListener::bind("127.0.0.1:0").expect("a loopback port");
            let endpoint = format!("http://{}", closed.local_addr().expect("its address"));
            drop(closed);
            let config = aws_sdk_dynamodb::Config::builder()
                .behavior_version(BehaviorVersion::latest())
                .region(Region::new("us-east-1"))
                .endpoint_url(endpoint)
                .credentials_provider(Credentials::new(
                    "AKIDFAKE",
                    "fakesecret",
                    None,
                    None,
                    "static",
                ))
                .retry_config(aws_sdk_dynamodb::config::retry::RetryConfig::disabled())
                .build();
            let refused = aws_sdk_dynamodb::Client::from_conf(config)
                .list_tables()
                .send()
                .await;
            assert!(refused.is_err(), "nothing listens on the warm-up port");
        });
    })
    .join()
    .expect("the warm-up request");
}

/// Held by a test for as long as it captures; the capture itself is the thread's, so there is nothing to undo.
pub struct Capture;

impl io::Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        LOG.with(|log| log.borrow_mut().extend_from_slice(buf));
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
