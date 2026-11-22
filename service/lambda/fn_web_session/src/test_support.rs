//! What the unit tests share: the rows of a signed-in browser, an auth store that fails one named call, and the
//! requests the website's pages send.

use std::sync::Arc;

use jiff::Timestamp;
use mopm_core::csrf::csrf_value;
use mopm_core::token::{web_session_fields, TokenSecret, SECRET_BYTES};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::iso_millis;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::types::{DeviceLoginRecord, TokenKind, TokenRecord, TrustedPublisher, UserRecord};
use mopm_testing::env::FixedClock;
use mopm_testing::memory_auth::MemoryAuthStore;
use mopm_testing::memory_publish::MemorySecrets;
use mopm_web::csrf::CsrfCheck;
use mopm_web::edge::EdgeCheck;
use mopm_web::request::Method;
use mopm_web::settings::parse_function_name;
use mopm_web::{SessionAuth, WebRequest};

use crate::handler::{WebSessionHandler, LOGOUT_PATH, SESSION_PATH};

pub const SITE: &str = "https://mopm.dev";
pub const EDGE: &str = "edge-value-of-beta";
/// When the sessions were created: 2026-11-18T11:06:40.000Z.
pub const CREATED_MS: i64 = 1_795_000_000_000;
/// An hour later: the sessions are live.
pub const NOW_MS: i64 = CREATED_MS + 3_600_000;
pub const SEVEN_DAYS_MS: i64 = 7 * 24 * 3_600_000;
pub const GITHUB_ID: u64 = 42;
/// The sessions' `expires_at`: 2026-11-25T11:06:40.000Z.
pub const EXPIRES_AT: &str = "2026-11-25T11:06:40.000Z";

pub fn secret(fill: u8) -> TokenSecret {
    TokenSecret::mint(&[fill; SECRET_BYTES])
}

pub fn at(ms: i64) -> Timestamp {
    Timestamp::from_millisecond(ms).unwrap()
}

/// The row a web login writes for `secret` at `CREATED_MS`, with id `id`, for account `github_id`.
pub fn session_row(secret: &TokenSecret, id: &str, github_id: u64) -> TokenRecord {
    let f = web_session_fields(secret, at(CREATED_MS)).unwrap();
    TokenRecord {
        id: id.to_string(),
        kind: TokenKind::Session,
        github_id: Some(github_id),
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

/// The memory store, except that the call named `fail` answers a fault. `store` is shared so a test can look at
/// the rows afterwards.
pub struct Faulty {
    pub store: Arc<MemoryAuthStore>,
    pub fail: Option<&'static str>,
}

impl Faulty {
    fn check(&self, call: &'static str) -> PortResult<()> {
        match self.fail {
            Some(f) if f == call => Err(PortError::fault("the store is unreachable")),
            _ => Ok(()),
        }
    }
}

impl AuthStore for Faulty {
    async fn upsert_user(
        &self,
        github_id: u64,
        handle: &str,
        now: &str,
        two_factor: Option<bool>,
    ) -> PortResult<UserRecord> {
        self.check("upsert_user")?;
        self.store
            .upsert_user(github_id, handle, now, two_factor)
            .await
    }
    async fn get_user(&self, github_id: u64) -> PortResult<Option<UserRecord>> {
        self.check("get_user")?;
        self.store.get_user(github_id).await
    }
    async fn put_token(&self, rec: &TokenRecord) -> PortResult<()> {
        self.check("put_token")?;
        self.store.put_token(rec).await
    }
    async fn get_token_by_hash(&self, hash: &str) -> PortResult<Option<TokenRecord>> {
        self.check("get_token_by_hash")?;
        self.store.get_token_by_hash(hash).await
    }
    async fn get_user_token(&self, github_id: u64, id: &str) -> PortResult<Option<TokenRecord>> {
        self.check("get_user_token")?;
        self.store.get_user_token(github_id, id).await
    }
    async fn list_tokens(&self, github_id: u64) -> PortResult<Vec<TokenRecord>> {
        self.check("list_tokens")?;
        self.store.list_tokens(github_id).await
    }
    async fn revoke_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.check("revoke_token")?;
        self.store.revoke_token(hash, at).await
    }
    async fn touch_token(&self, hash: &str, at: &str) -> PortResult<()> {
        self.check("touch_token")?;
        self.store.touch_token(hash, at).await
    }
    async fn put_device_login(&self, rec: &DeviceLoginRecord) -> PortResult<()> {
        self.check("put_device_login")?;
        self.store.put_device_login(rec).await
    }
    async fn get_device_login(&self, id: &str) -> PortResult<Option<DeviceLoginRecord>> {
        self.check("get_device_login")?;
        self.store.get_device_login(id).await
    }
    async fn set_device_polled(&self, id: &str, at: &str, interval: u64) -> PortResult<()> {
        self.check("set_device_polled")?;
        self.store.set_device_polled(id, at, interval).await
    }
    async fn delete_device_login(&self, id: &str) -> PortResult<()> {
        self.check("delete_device_login")?;
        self.store.delete_device_login(id).await
    }
    async fn add_trusted_publisher(&self, tp: &TrustedPublisher) -> PortResult<()> {
        self.check("add_trusted_publisher")?;
        self.store.add_trusted_publisher(tp).await
    }
    async fn list_trusted_publishers(&self, name: &str) -> PortResult<Vec<TrustedPublisher>> {
        self.check("list_trusted_publishers")?;
        self.store.list_trusted_publishers(name).await
    }
    async fn remove_trusted_publisher(&self, name: &str, id: &str) -> PortResult<()> {
        self.check("remove_trusted_publisher")?;
        self.store.remove_trusted_publisher(name, id).await
    }
}

/// A handler over a store, with the rows to look at.
pub struct Rig {
    pub handler: WebSessionHandler<Faulty, FixedClock>,
    pub store: Arc<MemoryAuthStore>,
}

impl Rig {
    /// The stored row with id `id`.
    pub fn row(&self, id: &str) -> TokenRecord {
        self.store
            .dump_tokens()
            .into_iter()
            .find(|t| t.id == id)
            .unwrap()
    }
}

/// A handler whose store holds alice and `rows`, at `now_ms`, with the call `fail` failing.
pub async fn rig(rows: Vec<TokenRecord>, now_ms: i64, fail: Option<&'static str>) -> Rig {
    let store = Arc::new(MemoryAuthStore::new());
    store
        .upsert_user(GITHUB_ID, "alice", &iso_millis(at(CREATED_MS)), Some(true))
        .await
        .unwrap();
    for row in &rows {
        store.put_token(row).await.unwrap();
    }
    let secrets = MemorySecrets::new();
    secrets.set("mopm/beta/edge-origin", EDGE);
    let stage = parse_function_name(Some(std::ffi::OsStr::new("mopm-beta-web-session")))
        .unwrap()
        .stage;
    let edge = EdgeCheck::load(&secrets, &stage).await.unwrap();
    let auth = SessionAuth::new(
        edge,
        CsrfCheck::new(SITE),
        Faulty {
            store: store.clone(),
            fail,
        },
        FixedClock::at_millis(now_ms),
    );
    Rig {
        handler: WebSessionHandler::new(auth),
        store,
    }
}

/// One live session of alice's (`tok-1`, `secret(1)`).
pub async fn live() -> Rig {
    rig(
        vec![session_row(&secret(1), "tok-1", GITHUB_ID)],
        NOW_MS,
        None,
    )
    .await
}

pub fn cookie(s: &TokenSecret) -> String {
    format!("__Host-mopm_session={}", s.expose())
}

/// A `GET` of the session route through the site, with the cookie header `cookies`.
pub fn get(cookies: &str) -> WebRequest {
    WebRequest::new(Method::Get, SESSION_PATH, "req-1")
        .with_header("x-mopm-edge", EDGE)
        .with_cookies(cookies)
}

/// A `POST` of the logout route from the site with `s`'s cookie and CSRF value.
pub fn post(s: &TokenSecret) -> WebRequest {
    WebRequest::new(Method::Post, LOGOUT_PATH, "req-2")
        .with_header("x-mopm-edge", EDGE)
        .with_header("Origin", SITE)
        .with_header("Sec-Fetch-Site", "same-origin")
        .with_header("X-Mopm-CSRF", &csrf_value(s))
        .with_cookies(&cookie(s))
}

/// The request with every field named `name` removed.
pub fn without(req: WebRequest, name: &str) -> WebRequest {
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

/// The SDK's DynamoDB client for the fake at `endpoint`.
pub fn dynamo_client(endpoint: &str) -> aws_sdk_dynamodb::Client {
    let config = aws_sdk_dynamodb::Config::builder()
        .behavior_version(aws_sdk_dynamodb::config::BehaviorVersion::latest())
        .region(aws_sdk_dynamodb::config::Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(aws_sdk_dynamodb::config::Credentials::new(
            "AKIDFAKE",
            "fakesecret",
            None,
            None,
            "static",
        ))
        .build();
    aws_sdk_dynamodb::Client::from_conf(config)
}

/// The SDK's Secrets Manager client for the fake at `endpoint`.
pub fn secrets_client(endpoint: &str) -> aws_sdk_secretsmanager::Client {
    let config = aws_sdk_secretsmanager::Config::builder()
        .behavior_version(aws_sdk_secretsmanager::config::BehaviorVersion::latest())
        .region(aws_sdk_secretsmanager::config::Region::new("us-east-1"))
        .endpoint_url(endpoint)
        .credentials_provider(aws_sdk_secretsmanager::config::Credentials::new(
            "AKIDFAKE",
            "fakesecret",
            None,
            None,
            "static",
        ))
        .build();
    aws_sdk_secretsmanager::Client::from_conf(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [&str; 15] = [
        "upsert_user",
        "get_user",
        "put_token",
        "get_token_by_hash",
        "get_user_token",
        "list_tokens",
        "revoke_token",
        "touch_token",
        "put_device_login",
        "get_device_login",
        "set_device_polled",
        "delete_device_login",
        "add_trusted_publisher",
        "list_trusted_publishers",
        "remove_trusted_publisher",
    ];

    /// Calls every method once, in `ALL`'s order, and answers which failed.
    async fn call_all(s: &Faulty) -> Vec<bool> {
        let tok = session_row(&secret(1), "t", 1);
        let dl = DeviceLoginRecord {
            id: "d".into(),
            github_device_code: "g".into(),
            client: "c".into(),
            created_at: "c".into(),
            expires_at: "e".into(),
            interval: 5,
            last_polled_at: None,
        };
        let tp: TrustedPublisher = serde_json::from_value(serde_json::json!({
            "id": "1", "name": "pkg", "repository_id": "r", "repository_owner_id": "o", "workflow": "w", "added_by": 1, "added_at": "a"
        }))
        .unwrap();
        vec![
            s.upsert_user(1, "a", "n", None).await.is_err(),
            s.get_user(1).await.is_err(),
            s.put_token(&tok).await.is_err(),
            s.get_token_by_hash("h").await.is_err(),
            s.get_user_token(1, "t").await.is_err(),
            s.list_tokens(1).await.is_err(),
            s.revoke_token("h", "n").await.is_err(),
            s.touch_token("h", "n").await.is_err(),
            s.put_device_login(&dl).await.is_err(),
            s.get_device_login("d").await.is_err(),
            s.set_device_polled("d", "n", 5).await.is_err(),
            s.delete_device_login("d").await.is_err(),
            s.add_trusted_publisher(&tp).await.is_err(),
            s.list_trusted_publishers("pkg").await.is_err(),
            s.remove_trusted_publisher("pkg", "1").await.is_err(),
        ]
    }

    #[tokio::test]
    async fn every_call_passes_to_the_store_when_none_fails() {
        let s = Faulty {
            store: Arc::new(MemoryAuthStore::new()),
            fail: None,
        };
        assert_eq!(call_all(&s).await, vec![false; 15]);
        assert_eq!(s.store.dump_tokens().len(), 1);
    }

    #[tokio::test]
    async fn the_named_call_and_only_it_fails() {
        for (i, name) in ALL.iter().enumerate() {
            let s = Faulty {
                store: Arc::new(MemoryAuthStore::new()),
                fail: Some(name),
            };
            let expected: Vec<bool> = (0..15).map(|j| j == i).collect();
            assert_eq!(call_all(&s).await, expected, "{name}");
        }
    }

    #[test]
    fn a_request_without_a_header_has_none_of_that_name() {
        assert!(without(post(&secret(1)), "origin")
            .headers
            .get("origin")
            .is_none());
        assert_eq!(
            without(post(&secret(1)), "origin")
                .headers
                .get("x-mopm-edge"),
            Some(EDGE)
        );
    }
}
