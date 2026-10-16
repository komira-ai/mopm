//! The one outbound HTTP client of the registry's Lambda: GitHub's OAuth and API hosts. `hyper` on `rustls` (AWS-LC, the same library as the AWS SDK's), system root
//! certificates. No redirects are followed, the whole exchange has a deadline, and a response body has a cap.
//!
//! [`HttpClient::new`] speaks `https` only. [`HttpClient::with_plain_http`] also accepts `http`, for a test that
//! talks to a server on loopback; nothing in production builds one.

use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper::{Method, Request};
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use rustls::{ClientConfig, RootCertStore};
use thiserror::Error;

/// Longest the whole exchange (connect, request, response) may take.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);
/// Largest response body read. GitHub's answers here are a few hundred bytes; its key set a few kilobytes.
pub const DEFAULT_MAX_BODY: usize = 256 * 1024;

#[derive(Clone, Debug)]
pub struct HttpRequest {
    method: Method,
    url: String,
    headers: Vec<(&'static str, String)>,
    body: Vec<u8>,
}

impl HttpRequest {
    pub fn get(url: impl Into<String>) -> Self {
        HttpRequest { method: Method::GET, url: url.into(), headers: Vec::new(), body: Vec::new() }
    }

    /// A POST of `application/x-www-form-urlencoded` parameters (the encoding of `URLSearchParams`).
    pub fn post_form(url: impl Into<String>, params: &[(&str, &str)]) -> Self {
        let body = form_urlencoded::Serializer::new(String::new()).extend_pairs(params).finish();
        HttpRequest { method: Method::POST, url: url.into(), headers: vec![("content-type", "application/x-www-form-urlencoded".to_string())], body: body.into_bytes() }
    }

    pub fn header(mut self, name: &'static str, value: impl Into<String>) -> Self {
        self.headers.push((name, value.into()));
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

#[derive(Debug, Error)]
pub enum HttpError {
    #[error("not a request this client sends: {0}")]
    Request(String),
    #[error("the exchange failed: {0}")]
    Transport(String),
    #[error("no answer within {0:?}")]
    Timeout(Duration),
    #[error("the answer is longer than {0} bytes")]
    TooLarge(usize),
}

#[derive(Clone)]
pub struct HttpClient {
    client: Client<HttpsConnector<HttpConnector>, Full<Bytes>>,
    timeout: Duration,
    max_body: usize,
}

impl HttpClient {
    /// `https` only, with the system's root certificates. An error when the system has none: a client that
    /// trusts nothing would fail every call, so the process should not start.
    pub fn new() -> Result<Self, HttpError> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let builder = HttpsConnectorBuilder::new().with_provider_and_native_roots(provider).map_err(|e| HttpError::Request(format!("no root certificates: {e}")))?;
        Ok(Self::from_connector(builder.https_only().enable_http1().build()))
    }

    /// `https` and `http`, trusting no certificate: for tests against a server on loopback.
    pub fn with_plain_http() -> Self {
        Self::from_connector(Self::connector(RootCertStore::empty(), true))
    }

    /// `https` only, trusting the given roots (the tests of the refusal of `http`).
    #[cfg(test)]
    fn https_only_with(roots: RootCertStore) -> Self {
        Self::from_connector(Self::connector(roots, false))
    }

    fn connector(roots: RootCertStore, plain: bool) -> HttpsConnector<HttpConnector> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("the provider supports the safe default protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        let builder = HttpsConnectorBuilder::new().with_tls_config(config);
        if plain {
            builder.https_or_http().enable_http1().build()
        } else {
            builder.https_only().enable_http1().build()
        }
    }

    fn from_connector(connector: HttpsConnector<HttpConnector>) -> Self {
        HttpClient { client: Client::builder(TokioExecutor::new()).build(connector), timeout: DEFAULT_TIMEOUT, max_body: DEFAULT_MAX_BODY }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_max_body(mut self, bytes: usize) -> Self {
        self.max_body = bytes;
        self
    }

    pub async fn send(&self, req: HttpRequest) -> Result<HttpResponse, HttpError> {
        let mut builder = Request::builder().method(req.method).uri(req.url.as_str());
        for (k, v) in &req.headers {
            builder = builder.header(*k, v.as_str());
        }
        let request = builder.body(Full::new(Bytes::from(req.body))).map_err(|e| HttpError::Request(e.to_string()))?;
        let exchange = async {
            let response = self.client.request(request).await.map_err(|e| HttpError::Transport(e.to_string()))?;
            let status = response.status().as_u16();
            let body = Limited::new(response.into_body(), self.max_body).collect().await.map_err(|e| {
                if e.downcast_ref::<http_body_util::LengthLimitError>().is_some() {
                    HttpError::TooLarge(self.max_body)
                } else {
                    HttpError::Transport(e.to_string())
                }
            })?;
            Ok(HttpResponse { status, body: body.to_bytes().to_vec() })
        };
        tokio::time::timeout(self.timeout, exchange).await.map_err(|_| HttpError::Timeout(self.timeout))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mopm_testing::fake_http::{FakeHttp, Reply};

    #[tokio::test]
    async fn a_get_and_a_form_post_arrive_as_sent() {
        let server = FakeHttp::start(vec![Reply::new(200).body("one"), Reply::new(201).body("two")]);
        let c = HttpClient::with_plain_http();
        let a = c.send(HttpRequest::get(format!("{}/user?x=1", server.endpoint())).header("accept", "application/json")).await.unwrap();
        assert_eq!(a, HttpResponse { status: 200, body: b"one".to_vec() });
        let b = c.send(HttpRequest::post_form(format!("{}/login/device/code", server.endpoint()), &[("client_id", "Iv1.abc"), ("scope", "read:user x")])).await.unwrap();
        assert_eq!((b.status, b.body.as_slice()), (201, &b"two"[..]));
        let seen = server.requests();
        assert_eq!((seen[0].method.as_str(), seen[0].target.as_str(), seen[0].header("accept")), ("GET", "/user?x=1", Some("application/json")));
        assert_eq!((seen[1].method.as_str(), seen[1].header("content-type")), ("POST", Some("application/x-www-form-urlencoded")));
        assert_eq!(String::from_utf8(seen[1].body.clone()).unwrap(), "client_id=Iv1.abc&scope=read%3Auser+x", "encoded as URLSearchParams does");
    }

    #[tokio::test]
    async fn a_failure_status_is_an_answer_not_an_error() {
        let server = FakeHttp::start(vec![Reply::new(503).body("busy")]);
        let r = HttpClient::with_plain_http().send(HttpRequest::get(format!("{}/", server.endpoint()))).await.unwrap();
        assert!(!r.is_success());
        assert_eq!(r.status, 503);
    }

    #[tokio::test]
    async fn the_https_client_refuses_plain_http() {
        let server = FakeHttp::start(vec![Reply::new(200)]);
        let e = HttpClient::https_only_with(RootCertStore::empty()).send(HttpRequest::get(format!("{}/", server.endpoint()))).await.unwrap_err();
        assert!(matches!(e, HttpError::Transport(_)), "{e}");
        assert!(server.requests().is_empty(), "nothing was sent");
    }

    #[tokio::test]
    async fn a_body_past_the_cap_is_refused() {
        let server = FakeHttp::start(vec![Reply::new(200).body(vec![b'x'; 100])]);
        let c = HttpClient::with_plain_http().with_max_body(99);
        assert!(matches!(c.send(HttpRequest::get(format!("{}/", server.endpoint()))).await, Err(HttpError::TooLarge(99))));
        let c = HttpClient::with_plain_http().with_max_body(100);
        assert_eq!(c.send(HttpRequest::get(format!("{}/", server.endpoint()))).await.unwrap().body.len(), 100);
    }

    #[tokio::test]
    async fn a_server_that_never_answers_times_out() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let _accept = tokio::spawn(async move {
            let _held = listener.accept().await;
            std::future::pending::<()>().await;
        });
        let c = HttpClient::with_plain_http().with_timeout(Duration::from_millis(150));
        assert!(matches!(c.send(HttpRequest::get(url)).await, Err(HttpError::Timeout(_))));
    }

    #[tokio::test]
    async fn an_unreachable_server_and_a_bad_url_are_errors() {
        let c = HttpClient::with_plain_http();
        // A port nothing listens on: bind, note the port, drop.
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        assert!(matches!(c.send(HttpRequest::get(format!("http://127.0.0.1:{port}/"))).await, Err(HttpError::Transport(_))));
        assert!(matches!(c.send(HttpRequest::get("not a url")).await, Err(HttpError::Request(_))));
    }
}
