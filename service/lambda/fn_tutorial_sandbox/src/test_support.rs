//! What the tests share: the function over a fake DynamoDB restricted to this package's grants (`tests/fixtures/grants.json`),
//! a fake Secrets Manager, a fake E2B API and a fixed clock, all on loopback; a way to make a request of the website
//! and read the answer; and the record of what was logged.
//!
//! The function is always `Function<DynamoAuthStore, TestHttp, SecretsManagerReader>`, so each of its generic functions
//! has the one instantiation the tests run.

use std::sync::{Arc, Mutex};

use aws_lambda_events::apigw::ApiGatewayV2httpRequest;
use aws_lambda_events::encodings::Body;
use aws_sdk_dynamodb::config::{BehaviorVersion, Credentials, Region};
use mopm_aws::dynamo::{AuthTables, DynamoAuthStore};
use mopm_aws::services::SecretsManagerReader;
use mopm_core::csrf::csrf_value;
use mopm_core::token::{web_session_fields, TokenSecret, SECRET_BYTES};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::iso_millis;
use mopm_ports::error::PortResult;
use mopm_ports::http::{HttpClient, HttpError, HttpFailure, HttpRequest, HttpResponse};
use mopm_ports::types::{TokenKind, TokenRecord};
use mopm_testing::env::FixedClock;
use mopm_testing::fake_dynamo::{FakeConfig, FakeDynamo, Grants};
use mopm_testing::fake_e2b::{CreateAnswer, FakeE2b};
use mopm_testing::fake_http::{Answer, FakeHttp, Reply};
use mopm_testing::scripted_http::ScriptedHttp;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::handler::Function;
use crate::log::Sink;
use crate::start::{start, Endpoints, Env, Parts, StartError};

pub const SITE: &str = "https://beta.mopm.dev";
pub const EDGE: &str = "edge-test-value-of-beta";
pub const E2B_KEY: &str = "e2b_test_key_0123456789";
pub const GITHUB_ID: u64 = 42;
/// 2026-11-20T10:00:00.000Z
pub const NOW_MS: i64 = 1_795_168_800_000;
pub const REQUEST_ID: &str = "req-7f3a2c19d0e4";
pub const GRANTS: &str = include_str!("../tests/fixtures/grants.json");
/// The `stage_settings` item the stack writes for beta (template `mopm-tutorial-beta`, two-factor on), as DynamoDB JSON.
pub const STAGE_ITEM: &str =
    include_str!("../../../infra/stacks/test/fixtures/stage-settings-item.json");
pub const CONFIG_TABLE: &str = "mopm-beta-config";

/// The session's secret: the one cookie the signed-in browser holds.
pub fn session_secret() -> TokenSecret {
    TokenSecret::mint(&[7; SECRET_BYTES])
}

/// The stage item with `change` applied to its JSON.
pub fn item_with(change: impl FnOnce(&mut Value)) -> String {
    let mut item: Value = serde_json::from_str(STAGE_ITEM).expect("the stack's fixture is JSON");
    change(&mut item);
    item.to_string()
}

pub fn dynamo_client(endpoint: &str) -> aws_sdk_dynamodb::Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new(
            "AKIDTEST",
            "test-secret",
            None,
            None,
            "static",
        ))
        .build();
    aws_sdk_dynamodb::Client::from_conf(config)
}

// ---- the HTTP client of the tests -------------------------------------------------------------------------------

/// An `HttpClient` over plain HTTP/1.1 on loopback, for `FakeE2b` (the production client refuses `http://`). The
/// request goes out exactly as built: its headers, `Host` and `Content-Length`, nothing else.
async fn plain_send(req: HttpRequest) -> PortResult<HttpResponse> {
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
    let end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("an answer head");
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

/// Plain HTTP to a fake, or a script of answers.
pub enum TestHttp {
    Plain,
    Scripted(Arc<ScriptedHttp>),
}

impl TestHttp {
    pub fn scripted(script: Vec<Result<HttpResponse, HttpError>>) -> TestHttp {
        TestHttp::Scripted(Arc::new(ScriptedHttp::new(script)))
    }

    /// A client whose one answer is the failure, and the script to read what it was sent.
    pub fn failing(failure: HttpFailure) -> (TestHttp, Arc<ScriptedHttp>) {
        let script = Arc::new(ScriptedHttp::new(vec![Err(HttpError {
            failure,
            detail: "e2b.test:443".to_string(),
        })]));
        (TestHttp::Scripted(script.clone()), script)
    }

    pub fn answering(status: u16, body: &str) -> TestHttp {
        TestHttp::scripted(vec![Ok(HttpResponse {
            status,
            headers: vec![],
            body: body.as_bytes().to_vec(),
        })])
    }
}

impl HttpClient for TestHttp {
    async fn send(&self, req: HttpRequest) -> PortResult<HttpResponse> {
        match self {
            TestHttp::Plain => plain_send(req).await,
            TestHttp::Scripted(script) => script.send(req).await,
        }
    }
}

// ---- Secrets Manager --------------------------------------------------------------------------------------------

/// What the fake Secrets Manager holds under a name.
#[derive(Clone, Debug)]
pub enum Stored {
    /// A string value.
    Value(String),
    /// No such secret, or no value yet (`ResourceNotFoundException`).
    NotFound,
    /// A secret that holds binary only.
    NoString,
    /// The service fails with this status.
    Fail(u16),
}

/// A secret's ARN; the account is built at run time, as the hygiene check refuses a 12-digit literal.
fn arn(id: &str) -> String {
    format!(
        "arn:aws:secretsmanager:us-east-1:{}:secret:{id}-AbCdEf",
        "0".repeat(12)
    )
}

impl Stored {
    pub fn key(api_key: &str) -> Stored {
        Stored::Value(json!({"api_key": api_key}).to_string())
    }

    fn reply(&self, id: &str) -> Reply {
        let amz = |status| Reply::new(status).header("Content-Type", "application/x-amz-json-1.1");
        match self {
            Stored::Value(v) => amz(200).body(json!({"ARN": arn(id), "Name": id, "SecretString": v}).to_string()),
            Stored::NotFound => amz(400).body(json!({"__type": "ResourceNotFoundException", "message": "Secrets Manager can't find the specified secret."}).to_string()),
            Stored::NoString => amz(200).body(json!({"ARN": arn("x"), "Name": id, "SecretBinary": "c2VjcmV0"}).to_string()),
            Stored::Fail(status) => amz(*status).body(json!({"__type": "InternalServiceError", "message": "the service failed"}).to_string()),
        }
    }
}

/// A fake Secrets Manager with the edge secret and the E2B key; the key can change while the test runs.
pub struct Secrets {
    http: FakeHttp,
    e2b: Arc<Mutex<Stored>>,
}

impl Secrets {
    pub fn start(edge: Stored, e2b: Stored) -> Secrets {
        let e2b = Arc::new(Mutex::new(e2b));
        let current = e2b.clone();
        let http = FakeHttp::with_handler(move |seen| {
            let id = seen
                .json()
                .and_then(|b| b["SecretId"].as_str().map(str::to_string))
                .unwrap_or_default();
            let stored = if id == "mopm/beta/e2b" {
                current.lock().expect("a lock").clone()
            } else {
                edge.clone()
            };
            Answer::Reply(stored.reply(&id))
        });
        Secrets { http, e2b }
    }

    pub fn endpoint(&self) -> String {
        self.http.endpoint()
    }

    /// The operator writes (or changes) the key.
    pub fn set_e2b(&self, stored: Stored) {
        *self.e2b.lock().expect("a lock") = stored;
    }

    /// How many times the secret `id` was read.
    pub fn reads(&self, id: &str) -> usize {
        self.http
            .requests()
            .iter()
            .filter(|r| r.json().is_some_and(|b| b["SecretId"] == id))
            .count()
    }
}

// ---- the rig ----------------------------------------------------------------------------------------------------

/// What a test varies.
pub struct Spec {
    /// The `stage_settings` item, as DynamoDB JSON; `None`: the table has none.
    pub config: Option<String>,
    pub grants: String,
    pub edge: Stored,
    pub e2b_secret: Stored,
    pub script: Vec<CreateAnswer>,
    pub http: Option<TestHttp>,
    pub env: Env,
    pub clock_ms: i64,
    /// The session row's `expires_at`, when it is not a week after it was made.
    pub session_expires: Option<String>,
}

impl Default for Spec {
    fn default() -> Spec {
        Spec {
            config: Some(STAGE_ITEM.to_string()),
            grants: GRANTS.to_string(),
            edge: Stored::Value(EDGE.to_string()),
            e2b_secret: Stored::key(E2B_KEY),
            script: vec![],
            http: None,
            env: env(),
            clock_ms: NOW_MS,
            session_expires: None,
        }
    }
}

/// The environment of a Lambda in beta.
pub fn env() -> Env {
    Env {
        function_name: Some("mopm-beta-tutorial-sandbox".into()),
        region: Some("us-east-1".to_string()),
        access_key_id: Some("AKIDTEST".to_string()),
        secret_access_key: Some("test-secret-access-key".to_string()),
        session_token: Some("test-session-token".to_string()),
    }
}

/// The function and everything it talks to.
pub struct Rig {
    pub db: FakeDynamo,
    pub secrets: Secrets,
    pub e2b: FakeE2b,
    pub lines: Arc<Mutex<Vec<String>>>,
    pub function: Function<DynamoAuthStore, TestHttp, SecretsManagerReader>,
}

/// The table of the fake DynamoDB with a session row and its account, written through the adapter, then moved into a
/// fake that holds the grants.
async fn database(spec: &Spec) -> FakeDynamo {
    let clock = || Arc::new(FixedClock::at_millis(spec.clock_ms));
    let admin = FakeDynamo::start(FakeConfig::registry("beta"));
    let store = DynamoAuthStore::new(
        dynamo_client(&admin.endpoint()),
        AuthTables::for_stage("beta"),
        clock(),
    );
    // The session was made an hour before the clock, unless its end is given (the clock is then at the edge of time).
    let made = if spec.session_expires.is_some() {
        NOW_MS
    } else {
        spec.clock_ms
    };
    let created =
        jiff::Timestamp::from_millisecond(made - 3_600_000).expect("a representable time");
    let secret = session_secret();
    let f = web_session_fields(&secret, created).expect("session fields");
    let row = TokenRecord {
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
        expires_at: spec.session_expires.clone().unwrap_or(f.expires_at),
        revoked_at: None,
        last_used_at: None,
        issued_to: None,
    };
    store
        .upsert_user(GITHUB_ID, "alice", &iso_millis(created), Some(true))
        .await
        .expect("the account is written");
    store.put_token(&row).await.expect("the session is written");
    let grants = Grants::parse(&spec.grants).expect("grants are JSON");
    let db = FakeDynamo::start(FakeConfig::registry("beta").with_grants("mopm-beta-", grants));
    for table in ["mopm-beta-users", "mopm-beta-tokens"] {
        for item in admin.dump(table) {
            db.seed(table, item);
        }
    }
    if let Some(item) = &spec.config {
        db.seed(
            CONFIG_TABLE,
            serde_json::from_str(item).expect("an item is JSON"),
        );
    }
    db
}

/// Starts the function over `spec`: the cold start's error, or the rig.
pub async fn try_rig(spec: Spec) -> Result<Rig, StartError> {
    let db = database(&spec).await;
    let secrets = Secrets::start(spec.edge.clone(), spec.e2b_secret.clone());
    let e2b = FakeE2b::start(E2B_KEY, spec.script.clone());
    let lines = Arc::new(Mutex::new(Vec::new()));
    let record = lines.clone();
    let sink: Sink = Arc::new(move |line| record.lock().expect("a lock").push(line.to_string()));
    let endpoints = Endpoints {
        dynamodb: Some(db.endpoint()),
        secrets: Some(secrets.endpoint()),
    };
    let parts = Parts {
        http: spec.http.unwrap_or(TestHttp::Plain),
        e2b_api: e2b.endpoint(),
        clock: Arc::new(FixedClock::at_millis(spec.clock_ms)),
        sink,
    };
    let function = start(&spec.env, &endpoints, parts).await?;
    Ok(Rig {
        db,
        secrets,
        e2b,
        lines,
        function,
    })
}

/// Starts the function; the cold start must succeed.
pub async fn rig(spec: Spec) -> Rig {
    try_rig(spec).await.expect("the function starts")
}

impl Rig {
    pub fn lines(&self) -> Vec<String> {
        self.lines.lock().expect("a lock").clone()
    }

    /// The operations asked of DynamoDB, in order.
    pub fn operations(&self) -> Vec<String> {
        self.db.operations()
    }

    /// Sends `req` and answers; every answer and log line is checked for what must never be in them.
    pub async fn send(&self, req: &Req) -> Got {
        let before = self.lines().len();
        let out = self.function.invoke(req.event()).await;
        let mut headers: Vec<(String, String)> = out
            .headers
            .iter()
            .map(|(n, v)| {
                (
                    n.as_str().to_string(),
                    String::from_utf8_lossy(v.as_bytes()).into_owned(),
                )
            })
            .collect();
        headers.sort();
        let body =
            String::from_utf8_lossy(out.body.as_ref().map_or(&[][..], Body::as_ref)).into_owned();
        let lines = self.lines();
        assert_eq!(
            lines.len(),
            before + 1,
            "exactly one log line per request: {lines:?}"
        );
        let answer = Got {
            status: out.status_code,
            headers,
            body,
            cookies: out.cookies,
        };
        let secret = session_secret();
        let hidden = [
            E2B_KEY,
            secret.expose(),
            csrf_value(&secret).as_str(),
            EDGE,
            "envd-token-0123456789abcdef",
        ]
        .map(str::to_string);
        for line in &lines[before..] {
            for h in &hidden {
                assert!(!line.contains(h.as_str()), "{h} is in the log line {line}");
            }
        }
        let shown = format!("{}{:?}", answer.body, answer.headers);
        for h in &hidden[..4] {
            assert!(!shown.contains(h.as_str()), "{h} is in the answer {shown}");
        }
        if answer.status != 201 {
            assert!(
                !shown.contains(hidden[4].as_str()),
                "the access token is in the answer {shown}"
            );
        }
        answer
    }

    /// The last log line.
    pub fn last_line(&self) -> String {
        self.lines().pop().expect("a log line")
    }
}

/// An answer.
#[derive(Debug)]
pub struct Got {
    pub status: i64,
    /// Sorted by name.
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub cookies: Vec<String>,
}

impl Got {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn json(&self) -> Value {
        serde_json::from_str(&self.body).expect("a JSON body")
    }
}

// ---- a request --------------------------------------------------------------------------------------------------

/// A request of the website, as API Gateway's event.
#[derive(Clone)]
pub struct Req {
    pub method: String,
    pub path: String,
    pub id: String,
    pub headers: Vec<(String, String)>,
    pub cookies: Vec<String>,
    pub body: Option<String>,
    pub base64: bool,
}

impl Req {
    /// What the site's page sends once signed in: the edge header, the site's origin, `same-origin`, the CSRF value and
    /// the session cookie.
    pub fn signed_in() -> Req {
        let secret = session_secret();
        Req {
            method: "POST".to_string(),
            path: "/api/v2/tutorial/sandbox".to_string(),
            id: REQUEST_ID.to_string(),
            headers: vec![
                ("x-mopm-edge".to_string(), EDGE.to_string()),
                ("origin".to_string(), SITE.to_string()),
                ("sec-fetch-site".to_string(), "same-origin".to_string()),
                ("x-mopm-csrf".to_string(), csrf_value(&secret)),
            ],
            cookies: vec![format!("__Host-mopm_session={}", secret.expose())],
            body: None,
            base64: false,
        }
    }

    pub fn header(mut self, name: &str, value: &str) -> Req {
        self.headers.retain(|(n, _)| n != name);
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    pub fn without_header(mut self, name: &str) -> Req {
        self.headers.retain(|(n, _)| n != name);
        self
    }

    pub fn without_cookie(mut self) -> Req {
        self.cookies.clear();
        self
    }

    pub fn with_body(mut self, body: &str) -> Req {
        self.body = Some(body.to_string());
        self.header("content-type", "application/json")
    }

    pub fn event(&self) -> ApiGatewayV2httpRequest {
        let headers: serde_json::Map<String, Value> = self
            .headers
            .iter()
            .map(|(n, v)| (n.clone(), json!(v)))
            .collect();
        let mut event = json!({
            "version": "2.0",
            "routeKey": format!("{} {}", self.method, self.path),
            "rawPath": self.path,
            "rawQueryString": "",
            "headers": headers,
            "cookies": self.cookies,
            "requestContext": {
                "accountId": "example",
                "apiId": "api",
                "domainName": "api.beta.mopm.dev",
                "http": {"method": self.method, "path": self.path, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
                "requestId": self.id,
                "routeKey": format!("{} {}", self.method, self.path),
                "stage": "$default",
                "timeEpoch": NOW_MS
            },
            "isBase64Encoded": self.base64
        });
        if let Some(body) = &self.body {
            event["body"] = json!(body);
        }
        serde_json::from_value(event).expect("an API Gateway event")
    }
}

/// The error body of the website's routes.
pub fn error_body(code: &str, message: &str, hint: &str) -> String {
    format!(r#"{{"error":{{"code":"{code}","message":"{message}","hint":"{hint}"}}}}"#)
}

/// The 503 body and its `Retry-After`.
pub const UNAVAILABLE_BODY: &str = r#"{"error":{"code":"tutorial_unavailable","message":"The sandbox service did not answer.","hint":"Wait 30 seconds and try again; the Retry-After header says how long."}}"#;

/// The line of an unavailable request.
pub fn unavailable_line(reason: &str) -> String {
    format!(
        r#"{{"event":"tutorial_sandbox","outcome":"unavailable","reason":"{reason}","request_id":"{REQUEST_ID}"}}"#
    )
}
