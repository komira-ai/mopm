//! `HyperHttpClient`: the `HttpClient` port on hyper's client over rustls, with rustls on the workspace's AWS-LC (the
//! aws-lc-rs provider, pinned in the root `Cargo.toml`), so every outbound TLS connection uses that stack. HTTP/1.1.
//!
//! - Only `https://` URLs are sent. Any other scheme, or a URL that does not parse, is refused before a connection is
//!   made, with a fault. A header name or value that HTTP cannot carry is refused the same way.
//! - The roots are the system's (`with_native_roots`, read once when the client is built, as the SDK's clients read
//!   them) or the ones given (`with_roots`).
//! - The request's `timeout` bounds the whole exchange: connecting, the TLS handshake, sending, and reading the whole
//!   body. Past it the answer is `HttpFailure::Timeout`.
//! - A response body longer than the client's cap is refused with a fault. No part of that answer is returned.
//! - A redirect is an answer like any other. Its status and `location` header come back, and nothing follows it.
//! - No proxy: the connector dials the URL's host itself and reads no environment variable.
//! - No answer is an `HttpError`: `Tls` when rustls refused the handshake (an untrusted certificate, a server that does
//!   not speak TLS), `Connect` for everything else (no connection, or one that broke before the whole answer). Its
//!   `detail` is the host and port, then the causes. It never holds the path, query, userinfo, headers or body of the
//!   request.
//!
//! Headers go through hyper's `HeaderMap` both ways: names are lower-cased, and the order is the first-seen order of the
//! names with the values of a repeated name together (so request headers are sent in the port's order except that a
//! repeated name's later values move up to its first). A response header value that is not UTF-8 is read lossily.

use std::error::Error as StdError;
use std::io;
use std::sync::Arc;

use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::Bytes;
use hyper::header::{HeaderName, HeaderValue};
use hyper::{Request, Uri};
use hyper_rustls::{ConfigBuilderExt, HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::{TokioExecutor, TokioTimer};
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::http::{HttpClient, HttpError, HttpFailure, HttpRequest, HttpResponse, Method};
use rustls::client::WantsClientCert;
use rustls::crypto::aws_lc_rs;
use rustls::{ClientConfig, ConfigBuilder, RootCertStore, WantsVerifier};

pub struct HyperHttpClient {
    client: Client<HttpsConnector<HttpConnector>, Full<Bytes>>,
    max_body_bytes: usize,
}

impl HyperHttpClient {
    /// A client that trusts the system's root certificates. A system with none is a fault.
    pub fn with_native_roots(max_body_bytes: usize) -> PortResult<Self> {
        let config = tls_builder()?.with_native_roots().map_err(|e| PortError::fault(format!("no root certificates to trust: {e}")))?;
        Ok(Self::from_config(config, max_body_bytes))
    }

    /// A client that trusts `roots` only.
    pub fn with_roots(roots: RootCertStore, max_body_bytes: usize) -> PortResult<Self> {
        Ok(Self::from_config(tls_builder()?.with_root_certificates(roots), max_body_bytes))
    }

    fn from_config(config: ConfigBuilder<ClientConfig, WantsClientCert>, max_body_bytes: usize) -> Self {
        let mut tcp = HttpConnector::new();
        // The TLS layer above it takes the https:// URLs; HttpConnector alone would refuse them.
        tcp.enforce_http(false);
        let https = HttpsConnectorBuilder::new().with_tls_config(config.with_no_client_auth()).https_only().enable_http1().wrap_connector(tcp);
        let client = Client::builder(TokioExecutor::new()).pool_timer(TokioTimer::new()).build(https);
        HyperHttpClient { client, max_body_bytes }
    }
}

/// rustls on the aws-lc-rs provider, named here rather than taken from the process default, with its default versions
/// (TLS 1.3 and 1.2). rustls refuses a provider with no cipher suite for those versions; aws-lc-rs's default provider has
/// suites for both, so that refusal is not expected here, and it would be a fault with rustls's message.
fn tls_builder() -> PortResult<ConfigBuilder<ClientConfig, WantsVerifier>> {
    ClientConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider())).with_safe_default_protocol_versions().map_err(PortError::fault)
}

/// Refused before anything is sent. The message never repeats the URL or a header value.
fn refused(why: impl std::fmt::Display) -> PortError {
    PortError::fault(format!("HTTP request refused: {why}"))
}

/// The request as hyper sends it, and the `host:port` it goes to (for the log).
fn build(req: HttpRequest) -> PortResult<(Request<Full<Bytes>>, String)> {
    let uri: Uri = req.url.parse().map_err(|_| refused("the URL does not parse"))?;
    match uri.scheme_str() {
        Some("https") => {}
        Some(other) => return Err(refused(format_args!("{other}:// is not https://"))),
        None => return Err(refused("the URL is not absolute")),
    }
    // An absolute URI with a scheme always has an authority, so a host.
    let host = uri.host().unwrap_or_default();
    let target = format!("{host}:{}", uri.port_u16().unwrap_or(443));
    let mut out = Request::new(Full::new(Bytes::from(req.body)));
    *out.method_mut() = match req.method {
        Method::Get => hyper::Method::GET,
        Method::Post => hyper::Method::POST,
    };
    *out.uri_mut() = uri;
    for (name, value) in req.headers {
        let header = HeaderName::from_bytes(name.as_bytes()).map_err(|_| refused(format_args!("{name:?} is not a header name")))?;
        let value = HeaderValue::from_bytes(value.as_bytes()).map_err(|_| refused(format_args!("the value of header {header} is not valid")))?;
        out.headers_mut().append(header, value);
    }
    Ok((out, target))
}

/// Whether rustls refused the handshake: a `rustls::Error` anywhere in the chain. An `io::Error` hides the error it
/// wraps from `source()`, so it is opened with `get_ref()`.
fn is_tls(e: &(dyn StdError + 'static)) -> bool {
    let mut cur = Some(e);
    while let Some(err) = cur {
        if err.is::<rustls::Error>() {
            return true;
        }
        cur = match err.downcast_ref::<io::Error>().and_then(io::Error::get_ref) {
            Some(inner) => Some(inner),
            None => err.source(),
        };
    }
    false
}

/// `e` and its causes, outermost first, joined by ": ".
fn causes(e: &(dyn StdError + 'static)) -> String {
    let mut out = e.to_string();
    let mut cur = e.source();
    while let Some(err) = cur {
        out.push_str(": ");
        out.push_str(&err.to_string());
        cur = err.source();
    }
    out
}

fn no_answer(target: &str, e: &(dyn StdError + 'static)) -> PortError {
    let failure = if is_tls(e) { HttpFailure::Tls } else { HttpFailure::Connect };
    HttpError { failure, detail: format!("{target}: {}", causes(e)) }.into()
}

impl HyperHttpClient {
    async fn exchange(&self, req: Request<Full<Bytes>>, target: &str) -> PortResult<HttpResponse> {
        let response = self.client.request(req).await.map_err(|e| no_answer(target, &e))?;
        let (parts, body) = response.into_parts();
        let body = match Limited::new(body, self.max_body_bytes).collect().await {
            Ok(collected) => collected.to_bytes().to_vec(),
            Err(e) if e.is::<LengthLimitError>() => {
                return Err(PortError::fault(format!("{target}: the response body is longer than {} bytes", self.max_body_bytes)));
            }
            Err(e) => return Err(no_answer(target, &*e)),
        };
        let headers = parts.headers.iter().map(|(k, v)| (k.as_str().to_string(), String::from_utf8_lossy(v.as_bytes()).into_owned())).collect();
        Ok(HttpResponse { status: parts.status.as_u16(), headers, body })
    }
}

impl HttpClient for HyperHttpClient {
    async fn send(&self, req: HttpRequest) -> PortResult<HttpResponse> {
        let timeout = req.timeout;
        let (request, target) = build(req)?;
        match tokio::time::timeout(timeout, self.exchange(request, &target)).await {
            Ok(answer) => answer,
            Err(_) => Err(HttpError { failure: HttpFailure::Timeout, detail: format!("{target}: no whole answer within {timeout:?}") }.into()),
        }
    }
}
