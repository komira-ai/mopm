//! Outbound HTTPS (`HttpClient`): one request, one response, bytes and headers. The web login calls GitHub
//! with it and the tutorial sandbox route calls E2B. Any status is an answer (`Ok`), a 4xx or 5xx included;
//! only a request that got no answer is an error, an [`HttpError`].

use std::fmt;
use std::future::Future;
use std::time::Duration;

use thiserror::Error;

use crate::error::PortResult;

/// The methods the callers send.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

impl Method {
    /// The method as it goes on the request line.
    pub fn as_str(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: Method,
    /// An absolute `https://` URL, query included.
    pub url: String,
    /// Sent in this order, names as given.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// The longest the whole exchange may take, connecting included; past it the answer is
    /// [`HttpFailure::Timeout`]. A field of the request, so a test reads the value and never waits for it.
    pub timeout: Duration,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    /// As received, in order; names lower-cased.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Why a request got no answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpFailure {
    /// No connection: the name did not resolve, the connection was refused, or it broke before the
    /// whole answer arrived.
    Connect,
    /// No whole answer within the request's `timeout`.
    Timeout,
    /// The TLS handshake failed: the certificate was refused, or the server's TLS is not one we speak.
    Tls,
}

impl fmt::Display for HttpFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            HttpFailure::Connect => "no connection",
            HttpFailure::Timeout => "timed out",
            HttpFailure::Tls => "TLS failed",
        })
    }
}

/// A request that got no answer. `detail` is the adapter's account of it, for the log; it never holds a
/// header or body of the request.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[error("HTTP request got no answer: {failure}: {detail}")]
pub struct HttpError {
    pub failure: HttpFailure,
    pub detail: String,
}

pub trait HttpClient: Send + Sync {
    /// Send one request and read the whole answer. A non-2xx status is `Ok`; no answer is
    /// `Err(PortError::Http(_))`.
    fn send(&self, req: HttpRequest) -> impl Future<Output = PortResult<HttpResponse>> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn methods_are_spelled_as_on_the_request_line() {
        assert_eq!(Method::Get.as_str(), "GET");
        assert_eq!(Method::Post.as_str(), "POST");
    }

    #[test]
    fn an_error_says_which_failure_and_the_detail() {
        let e = |failure| HttpError { failure, detail: "api.example.test:443".to_string() }.to_string();
        assert_eq!(e(HttpFailure::Connect), "HTTP request got no answer: no connection: api.example.test:443");
        assert_eq!(e(HttpFailure::Timeout), "HTTP request got no answer: timed out: api.example.test:443");
        assert_eq!(e(HttpFailure::Tls), "HTTP request got no answer: TLS failed: api.example.test:443");
    }
}
