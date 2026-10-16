//! GitHub, as far as login needs it (`auth/github.ts`): the OAuth device flow and the authenticated-user lookup.
//!
//! What GitHub exposes (documented here because the two-factor rule depends on it):
//!
//! * `GET /user` returns the numeric `id` and `login` for any token.
//! * `two_factor_authentication` (boolean) is part of the authenticated user's own, private view. Whether a given
//!   OAuth scope is enough to see it must be confirmed against live GitHub before the requirement is switched on
//!   in production. When the field is absent we cannot know, and the login layer treats absent as "not satisfied"
//!   while the requirement is on (fail closed).
//! * The device flow needs the OAuth app's client id only; the client secret is not used and not read.

use std::future::Future;

use serde_json::{Map, Value};
use thiserror::Error;

use crate::http::{HttpClient, HttpRequest};
use crate::js;

const USER_AGENT: &str = "mopm-registry";

/// GitHub could not be reached or answered something unusable. The device-login layer answers `unavailable`.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[error("{0}")]
pub struct GitHubUnavailable(pub String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitHubDeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GitHubPoll {
    Pending,
    SlowDown { interval: Option<u64> },
    Denied,
    Expired,
    Ok { access_token: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitHubUser {
    pub id: u64,
    pub login: String,
    /// `None` when GitHub did not include the field.
    pub two_factor: Option<bool>,
}

pub trait GitHubApi: Send + Sync {
    fn start_device_flow(&self, scope: &str) -> impl Future<Output = Result<GitHubDeviceStart, GitHubUnavailable>> + Send;
    fn poll_device_flow(&self, device_code: &str) -> impl Future<Output = Result<GitHubPoll, GitHubUnavailable>> + Send;
    fn get_user(&self, access_token: &str) -> impl Future<Output = Result<GitHubUser, GitHubUnavailable>> + Send;
}

/// Where GitHub's two hosts are. Production: [`GitHubHosts::github`]; a test points both at a loopback server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitHubHosts {
    pub oauth: String,
    pub api: String,
}

impl GitHubHosts {
    pub fn github() -> Self {
        GitHubHosts { oauth: "https://github.com".into(), api: "https://api.github.com".into() }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
#[error("GitHub client id is required")]
pub struct EmptyClientId;

pub struct HttpGitHub {
    client: HttpClient,
    client_id: String,
    hosts: GitHubHosts,
}

impl HttpGitHub {
    pub fn new(client_id: impl Into<String>, client: HttpClient, hosts: GitHubHosts) -> Result<Self, EmptyClientId> {
        let client_id = client_id.into();
        if client_id.is_empty() {
            return Err(EmptyClientId);
        }
        Ok(HttpGitHub { client, client_id, hosts })
    }

    async fn post(&self, path: &str, params: &[(&str, &str)]) -> Result<Map<String, Value>, GitHubUnavailable> {
        let req = HttpRequest::post_form(format!("{}{path}", self.hosts.oauth), params).header("accept", "application/json").header("user-agent", USER_AGENT);
        let res = self.client.send(req).await.map_err(|e| GitHubUnavailable(format!("GitHub could not be reached: {e}")))?;
        if !res.is_success() {
            return Err(GitHubUnavailable(format!("GitHub answered {}", res.status)));
        }
        match serde_json::from_slice::<Value>(&res.body) {
            Ok(Value::Object(m)) => Ok(m),
            Ok(_) => Err(GitHubUnavailable("GitHub answered a non-object".into())),
            Err(_) => Err(GitHubUnavailable("GitHub answered something that is not JSON".into())),
        }
    }
}

fn text(m: &Map<String, Value>, key: &str) -> Option<String> {
    m.get(key).and_then(Value::as_str).map(str::to_string)
}

impl GitHubApi for HttpGitHub {
    async fn start_device_flow(&self, scope: &str) -> Result<GitHubDeviceStart, GitHubUnavailable> {
        let b = self.post("/login/device/code", &[("client_id", &self.client_id), ("scope", scope)]).await?;
        let unusable = || GitHubUnavailable("GitHub answered an unusable device code response".into());
        let number = |k: &str| b.get(k).and_then(js::integer);
        Ok(GitHubDeviceStart {
            device_code: text(&b, "device_code").ok_or_else(unusable)?,
            user_code: text(&b, "user_code").ok_or_else(unusable)?,
            verification_uri: text(&b, "verification_uri").ok_or_else(unusable)?,
            expires_in: number("expires_in").ok_or_else(unusable)?,
            interval: number("interval").ok_or_else(unusable)?,
        })
    }

    async fn poll_device_flow(&self, device_code: &str) -> Result<GitHubPoll, GitHubUnavailable> {
        let b = self
            .post(
                "/login/oauth/access_token",
                &[("client_id", &self.client_id), ("device_code", device_code), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")],
            )
            .await?;
        if let Some(access_token) = text(&b, "access_token").filter(|t| !t.is_empty()) {
            return Ok(GitHubPoll::Ok { access_token });
        }
        match b.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => Ok(GitHubPoll::Pending),
            Some("slow_down") => Ok(GitHubPoll::SlowDown { interval: b.get("interval").and_then(js::integer) }),
            Some("access_denied") => Ok(GitHubPoll::Denied),
            Some("expired_token") => Ok(GitHubPoll::Expired),
            // incorrect_device_code, unsupported_grant_type, incorrect_client_credentials, device_flow_disabled...
            other => Err(GitHubUnavailable(format!("GitHub refused the device flow: {}", other.unwrap_or("undefined")))),
        }
    }

    async fn get_user(&self, access_token: &str) -> Result<GitHubUser, GitHubUnavailable> {
        let req = HttpRequest::get(format!("{}/user", self.hosts.api))
            .header("accept", "application/vnd.github+json")
            .header("authorization", format!("Bearer {access_token}"))
            .header("user-agent", USER_AGENT)
            .header("x-github-api-version", "2022-11-28");
        let res = self.client.send(req).await.map_err(|e| GitHubUnavailable(format!("GitHub could not be reached: {e}")))?;
        if !res.is_success() {
            return Err(GitHubUnavailable(format!("GitHub answered {} for the user lookup", res.status)));
        }
        let unusable = || GitHubUnavailable("GitHub answered an unusable user".into());
        let Ok(Value::Object(b)) = serde_json::from_slice::<Value>(&res.body) else { return Err(unusable()) };
        let id = b.get("id").and_then(js::integer).filter(|id| *id >= 1).ok_or_else(unusable)?;
        let login = text(&b, "login").filter(|l| !l.is_empty()).ok_or_else(unusable)?;
        Ok(GitHubUser { id, login, two_factor: b.get("two_factor_authentication").and_then(Value::as_bool) })
    }
}

#[cfg(test)]
mod tests {
    use mopm_testing::fake_http::{FakeHttp, Reply};
    use serde_json::json;

    use super::*;

    fn json_reply(status: u16, v: Value) -> Reply {
        Reply::new(status).header("content-type", "application/json").body(v.to_string())
    }

    fn github(server: &FakeHttp) -> HttpGitHub {
        let hosts = GitHubHosts { oauth: server.endpoint(), api: server.endpoint() };
        HttpGitHub::new("Iv1.client", HttpClient::with_plain_http(), hosts).unwrap()
    }

    #[test]
    fn an_empty_client_id_is_refused() {
        assert_eq!(HttpGitHub::new("", HttpClient::with_plain_http(), GitHubHosts::github()).err(), Some(EmptyClientId));
    }

    #[tokio::test]
    async fn the_device_code_request_is_a_form_post_with_the_client_id_and_scope() {
        let server = FakeHttp::start(vec![json_reply(200, json!({"device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}))]);
        let start = github(&server).start_device_flow("read:user").await.unwrap();
        assert_eq!(
            start,
            GitHubDeviceStart { device_code: "dc".into(), user_code: "WDJB-MJHT".into(), verification_uri: "https://github.com/login/device".into(), expires_in: 900, interval: 5 }
        );
        let seen = &server.requests()[0];
        assert_eq!((seen.method.as_str(), seen.path()), ("POST", "/login/device/code"));
        assert_eq!(seen.header("accept"), Some("application/json"));
        assert_eq!(seen.header("content-type"), Some("application/x-www-form-urlencoded"));
        assert_eq!(seen.header("user-agent"), Some("mopm-registry"));
        assert_eq!(String::from_utf8_lossy(&seen.body), "client_id=Iv1.client&scope=read%3Auser");
    }

    #[tokio::test]
    async fn an_unusable_device_code_response_is_unavailable() {
        for body in [json!({}), json!({"device_code": "d", "user_code": "u", "verification_uri": "v", "expires_in": "900", "interval": 5}), json!({"device_code": 1, "user_code": "u", "verification_uri": "v", "expires_in": 9, "interval": 5}), json!({"device_code": "d", "user_code": "u", "verification_uri": "v", "expires_in": 9, "interval": 5.5}), json!([1])] {
            let server = FakeHttp::start(vec![json_reply(200, body.clone())]);
            let e = github(&server).start_device_flow("s").await.unwrap_err();
            assert!(e.0.starts_with("GitHub answered"), "{body}: {e}");
        }
        let server = FakeHttp::start(vec![Reply::new(502).body("bad gateway")]);
        assert_eq!(github(&server).start_device_flow("s").await.unwrap_err().0, "GitHub answered 502");
        let server = FakeHttp::start(vec![Reply::new(200).body("<html>")]);
        assert!(github(&server).start_device_flow("s").await.is_err());
    }

    #[tokio::test]
    async fn polling_sends_the_device_grant_and_reads_every_answer() {
        let cases = [
            (json!({"access_token": "gho_x", "token_type": "bearer"}), Ok(GitHubPoll::Ok { access_token: "gho_x".into() })),
            (json!({"error": "authorization_pending"}), Ok(GitHubPoll::Pending)),
            (json!({"error": "slow_down", "interval": 10}), Ok(GitHubPoll::SlowDown { interval: Some(10) })),
            (json!({"error": "slow_down"}), Ok(GitHubPoll::SlowDown { interval: None })),
            (json!({"error": "slow_down", "interval": "10"}), Ok(GitHubPoll::SlowDown { interval: None })),
            (json!({"error": "access_denied"}), Ok(GitHubPoll::Denied)),
            (json!({"error": "expired_token"}), Ok(GitHubPoll::Expired)),
            (json!({"error": "device_flow_disabled"}), Err("GitHub refused the device flow: device_flow_disabled")),
            (json!({"access_token": ""}), Err("GitHub refused the device flow: undefined")),
            (json!({}), Err("GitHub refused the device flow: undefined")),
        ];
        for (body, want) in cases {
            let server = FakeHttp::start(vec![json_reply(200, body.clone())]);
            let got = github(&server).poll_device_flow("dc").await;
            assert_eq!(got.map_err(|e| e.0), want.map_err(str::to_string), "{body}");
            let seen = &server.requests()[0];
            assert_eq!(seen.path(), "/login/oauth/access_token");
            assert_eq!(
                String::from_utf8_lossy(&seen.body),
                "client_id=Iv1.client&device_code=dc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            );
        }
        let server = FakeHttp::start(vec![Reply::new(500)]);
        assert_eq!(github(&server).poll_device_flow("dc").await.unwrap_err().0, "GitHub answered 500");
    }

    #[tokio::test]
    async fn the_user_lookup_sends_the_token_and_reads_id_login_and_two_factor() {
        let server = FakeHttp::start(vec![json_reply(200, json!({"id": 4242, "login": "octo", "two_factor_authentication": true}))]);
        let u = github(&server).get_user("gho_secret").await.unwrap();
        assert_eq!(u, GitHubUser { id: 4242, login: "octo".into(), two_factor: Some(true) });
        let seen = &server.requests()[0];
        assert_eq!((seen.method.as_str(), seen.path()), ("GET", "/user"));
        assert_eq!(seen.header("authorization"), Some("Bearer gho_secret"));
        assert_eq!(seen.header("accept"), Some("application/vnd.github+json"));
        assert_eq!(seen.header("x-github-api-version"), Some("2022-11-28"));
        assert_eq!(seen.header("user-agent"), Some("mopm-registry"));

        let server = FakeHttp::start(vec![json_reply(200, json!({"id": 7, "login": "o"}))]);
        assert_eq!(github(&server).get_user("t").await.unwrap().two_factor, None, "absent stays absent");
        let server = FakeHttp::start(vec![json_reply(200, json!({"id": 7, "login": "o", "two_factor_authentication": "yes"}))]);
        assert_eq!(github(&server).get_user("t").await.unwrap().two_factor, None, "only a boolean counts");
    }

    #[tokio::test]
    async fn an_unusable_user_is_unavailable() {
        for body in [json!({"id": 0, "login": "o"}), json!({"id": -1, "login": "o"}), json!({"id": 1.5, "login": "o"}), json!({"id": "7", "login": "o"}), json!({"id": 7, "login": ""}), json!({"id": 7}), json!(null), json!([])] {
            let server = FakeHttp::start(vec![json_reply(200, body.clone())]);
            assert_eq!(github(&server).get_user("t").await.unwrap_err().0, "GitHub answered an unusable user", "{body}");
        }
        let server = FakeHttp::start(vec![json_reply(401, json!({"message": "Bad credentials"}))]);
        assert_eq!(github(&server).get_user("t").await.unwrap_err().0, "GitHub answered 401 for the user lookup");
    }

    #[tokio::test]
    async fn an_unreachable_github_is_unavailable() {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");
        let g = HttpGitHub::new("c", HttpClient::with_plain_http(), GitHubHosts { oauth: base.clone(), api: base }).unwrap();
        assert!(g.start_device_flow("s").await.unwrap_err().0.starts_with("GitHub could not be reached"));
        assert!(g.get_user("t").await.is_err());
    }
}
