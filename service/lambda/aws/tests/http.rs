//! `HyperHttpClient` over real TLS on loopback (see `common`): what is sent arrives as sent, every answer comes back
//! whole, and each way of getting no answer is the failure the port names. Nothing here leaves the machine.

mod common;

use std::net::SocketAddr;
use std::time::Duration;

use common::{https, read_head, tcp_server, tls_front, tls_server, trusted_cert, trusted_roots, untrusted_cert};
use mopm_aws::http::HyperHttpClient;
use mopm_ports::error::PortError;
use mopm_ports::http::{HttpClient, HttpError, HttpFailure, HttpRequest, HttpResponse, Method};
use mopm_testing::fake_http::{FakeHttp, Reply};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// The body cap of the clients built here.
const CAP: usize = 64;

/// Long enough never to be reached by an exchange that gets its answer: nothing waits for it.
const PATIENT: Duration = Duration::from_secs(30);

fn client() -> HyperHttpClient {
    HyperHttpClient::with_roots(trusted_roots(), CAP).unwrap()
}

fn get(url: String) -> HttpRequest {
    HttpRequest { method: Method::Get, url, headers: vec![], body: vec![], timeout: PATIENT }
}

fn pairs(list: &[(&str, &str)]) -> Vec<(String, String)> {
    list.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// The `HttpError` of a request that got no answer.
fn no_answer(r: Result<HttpResponse, PortError>) -> HttpError {
    match r {
        Err(PortError::Http(e)) => e,
        other => panic!("expected no answer, got {other:?}"),
    }
}

/// The message of a request the client refused or an answer it would not take.
fn fault(r: Result<HttpResponse, PortError>) -> String {
    match r {
        Err(e @ PortError::Fault(_)) => e.to_string(),
        other => panic!("expected a fault, got {other:?}"),
    }
}

// ---- What is sent arrives, and the answer comes back -------------------------------------------------------

#[tokio::test]
async fn a_post_arrives_with_its_method_target_headers_and_body_and_the_whole_answer_comes_back() {
    let fake = FakeHttp::start(vec![Reply::new(201).header("X-Request-Id", "r1").header("Content-Type", "application/json").body(r#"{"sandboxID":"s1"}"#)]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let req = HttpRequest {
        method: Method::Post,
        url: https(addr, "/sandboxes?team=t1&x=%2F"),
        headers: pairs(&[("Accept", "application/json"), ("X-API-Key", "k-123"), ("x-trace", "a"), ("x-trace", "b")]),
        body: br#"{"templateID":"tpl"}"#.to_vec(),
        timeout: PATIENT,
    };
    let answer = client().send(req).await.unwrap();

    assert_eq!(
        answer,
        HttpResponse {
            status: 201,
            headers: pairs(&[("x-request-id", "r1"), ("content-type", "application/json"), ("content-length", "18"), ("connection", "close")]),
            body: br#"{"sandboxID":"s1"}"#.to_vec(),
        }
    );
    let seen = fake.requests();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].target, "/sandboxes?team=t1&x=%2F");
    assert_eq!(
        seen[0].headers,
        pairs(&[
            ("accept", "application/json"),
            ("x-api-key", "k-123"),
            ("x-trace", "a"),
            ("x-trace", "b"),
            ("host", &addr.to_string()),
            ("content-length", "20"),
        ])
    );
    assert_eq!(seen[0].body, br#"{"templateID":"tpl"}"#);
}

#[tokio::test]
async fn a_get_arrives_without_a_body_and_an_empty_answer_comes_back_empty() {
    let fake = FakeHttp::start(vec![Reply::new(204)]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let answer = client().send(get(https(addr, "/user"))).await.unwrap();

    assert_eq!(answer, HttpResponse { status: 204, headers: pairs(&[("content-length", "0"), ("connection", "close")]), body: vec![] });
    let seen = fake.requests();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].target, "/user");
    assert_eq!(seen[0].headers, pairs(&[("host", &addr.to_string())]));
    assert!(seen[0].body.is_empty());
}

#[tokio::test]
async fn an_error_status_is_an_answer() {
    let fake = FakeHttp::start(vec![Reply::new(503).body("busy")]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let answer = client().send(get(https(addr, "/"))).await.unwrap();
    assert_eq!((answer.status, answer.body), (503, b"busy".to_vec()));
}

#[tokio::test]
async fn a_redirect_comes_back_as_it_is_and_is_not_followed() {
    let fake = FakeHttp::start(vec![Reply::new(302).header("Location", "/elsewhere"), Reply::new(200).body("followed")]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let answer = client().send(get(https(addr, "/login"))).await.unwrap();

    assert_eq!(answer.status, 302);
    assert_eq!(answer.headers[0], ("location".to_string(), "/elsewhere".to_string()));
    assert_eq!(fake.requests().len(), 1);
}

#[tokio::test]
async fn one_client_sends_one_request_after_another() {
    let fake = FakeHttp::start(vec![Reply::new(200).body("one"), Reply::new(200).body("two")]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let client = client();
    assert_eq!(client.send(get(https(addr, "/1"))).await.unwrap().body, b"one");
    assert_eq!(client.send(get(https(addr, "/2"))).await.unwrap().body, b"two");
    let targets: Vec<String> = fake.requests().into_iter().map(|s| s.target).collect();
    assert_eq!(targets, ["/1", "/2"]);
}

#[tokio::test]
async fn a_header_value_that_is_not_utf8_is_read_lossily() {
    let addr = tls_server(trusted_cert(), |mut tls| async move {
        read_head(&mut tls).await;
        tls.write_all(b"HTTP/1.1 200 OK\r\nx-raw: caf\xe9\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").await.unwrap();
        tls.shutdown().await.unwrap();
    })
    .await;
    let answer = client().send(get(https(addr, "/"))).await.unwrap();
    assert_eq!(answer.headers[0], ("x-raw".to_string(), "caf\u{fffd}".to_string()));
}

// ---- The body cap --------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_body_exactly_at_the_cap_comes_back() {
    let fake = FakeHttp::start(vec![Reply::new(200).body(vec![b'a'; CAP])]);
    let addr = tls_front(&fake, trusted_cert()).await;
    assert_eq!(client().send(get(https(addr, "/"))).await.unwrap().body, vec![b'a'; CAP]);
}

#[tokio::test]
async fn a_body_over_the_cap_is_refused_and_none_of_it_comes_back() {
    let fake = FakeHttp::start(vec![Reply::new(200).body(vec![b'a'; CAP + 1])]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let r = client().send(get(https(addr, "/"))).await;
    assert_eq!(fault(r), format!("infrastructure fault: {addr}: the response body is longer than 64 bytes"));
}

// ---- Refused before anything is sent ----------------------------------------------------------------------

#[tokio::test]
async fn an_http_url_is_refused_and_nothing_reaches_the_server() {
    let fake = FakeHttp::start(vec![]);
    let r = client().send(get(format!("{}/user", fake.endpoint()))).await;
    assert_eq!(fault(r), "infrastructure fault: HTTP request refused: http:// is not https://");
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn a_url_that_is_not_an_absolute_https_url_is_refused() {
    let cases = [
        ("ftp://127.0.0.1/file", "HTTP request refused: ftp:// is not https://"),
        ("/user?token=s3cret", "HTTP request refused: the URL is not absolute"),
        ("https://exa mple.test/?token=s3cret", "HTTP request refused: the URL does not parse"),
        ("", "HTTP request refused: the URL does not parse"),
    ];
    for (url, want) in cases {
        let r = client().send(get(url.to_string())).await;
        assert_eq!(fault(r), format!("infrastructure fault: {want}"), "{url}");
    }
}

#[tokio::test]
async fn a_header_http_cannot_carry_is_refused_without_repeating_its_value() {
    let fake = FakeHttp::start(vec![]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let cases = [
        (("bad name", "v"), r#"HTTP request refused: "bad name" is not a header name"#),
        (("Authorization", "Bearer s3cret\r\nx-injected: 1"), "HTTP request refused: the value of header authorization is not valid"),
    ];
    for ((name, value), want) in cases {
        let mut req = get(https(addr, "/"));
        req.headers = pairs(&[(name, value)]);
        assert_eq!(fault(client().send(req).await), format!("infrastructure fault: {want}"));
    }
    assert!(fake.requests().is_empty());
}

// ---- TLS refused -------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_certificate_from_an_issuer_the_client_does_not_trust_is_refused() {
    let fake = FakeHttp::start(vec![]);
    let addr = tls_front(&fake, untrusted_cert()).await;
    let e = no_answer(client().send(get(https(addr, "/user"))).await);
    assert_eq!(e, HttpError { failure: HttpFailure::Tls, detail: format!("{addr}: client error (Connect): invalid peer certificate: UnknownIssuer") });
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn a_server_that_does_not_speak_tls_is_a_tls_failure() {
    let addr = tcp_server(|mut tcp| async move {
        // Read the ClientHello before answering, and keep the connection open after: closing over unread bytes would
        // reset it, and the client could see the reset before the answer.
        let mut hello = [0u8; 5];
        tcp.read_exact(&mut hello).await.unwrap();
        tcp.write_all(b"HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n").await.unwrap();
        std::future::pending::<()>().await;
    })
    .await;
    let e = no_answer(client().send(get(https(addr, "/"))).await);
    assert_eq!(e.failure, HttpFailure::Tls);
    assert!(e.detail.starts_with(&format!("{addr}: client error (Connect): ")), "{}", e.detail);
}

// ---- No connection, or one that broke ------------------------------------------------------------------------

#[tokio::test]
async fn a_connection_reset_before_the_handshake_is_a_connect_failure() {
    let addr = tcp_server(|tcp| async move {
        tcp.set_zero_linger().unwrap();
        drop(tcp);
    })
    .await;
    let e = no_answer(client().send(get(https(addr, "/"))).await);
    assert_eq!(e.failure, HttpFailure::Connect);
    assert!(e.detail.starts_with(&format!("{addr}: client error (Connect): ")), "{}", e.detail);
}

#[tokio::test]
async fn a_connection_reset_after_the_request_is_a_connect_failure() {
    let addr = tls_server(trusted_cert(), |mut tls| async move {
        read_head(&mut tls).await;
        tls.get_ref().0.set_zero_linger().unwrap();
        drop(tls);
    })
    .await;
    let e = no_answer(client().send(get(https(addr, "/"))).await);
    assert_eq!(e.failure, HttpFailure::Connect);
    assert!(e.detail.starts_with(&format!("{addr}: client error (SendRequest): ")), "{}", e.detail);
}

#[tokio::test]
async fn an_answer_cut_off_inside_its_body_is_a_connect_failure() {
    let addr = tls_server(trusted_cert(), |mut tls| async move {
        read_head(&mut tls).await;
        tls.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 40\r\n\r\nonly ten b").await.unwrap();
        tls.shutdown().await.unwrap();
    })
    .await;
    let e = no_answer(client().send(get(https(addr, "/"))).await);
    assert_eq!(e.failure, HttpFailure::Connect);
    assert!(e.detail.starts_with(&format!("{addr}: error reading a body from connection")), "{}", e.detail);
}

// ---- Timeouts: servers that never answer, and the timeout each request carries -------------------------------

/// A short timeout for servers that never answer: the outcome is the same for any value.
const SHORT: Duration = Duration::from_millis(100);

/// Accepts connections and never sends a byte.
async fn silent_server() -> SocketAddr {
    tcp_server(|tcp| async move {
        let _held = tcp;
        std::future::pending::<()>().await;
    })
    .await
}

#[tokio::test]
async fn a_server_that_never_answers_is_a_timeout_and_the_detail_names_only_host_and_port() {
    let addr = silent_server().await;
    let url = format!("https://user:pass@{addr}/login/oauth/access_token?code=s3cret");
    let req = HttpRequest { method: Method::Post, url, headers: pairs(&[("Authorization", "Bearer s3cret")]), body: b"s3cret".to_vec(), timeout: SHORT };
    let e = no_answer(client().send(req).await);
    assert_eq!(e, HttpError { failure: HttpFailure::Timeout, detail: format!("{addr}: no whole answer within 100ms") });
}

#[tokio::test]
async fn a_body_that_stops_arriving_is_a_timeout() {
    let addr = tls_server(trusted_cert(), |mut tls| async move {
        read_head(&mut tls).await;
        tls.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 40\r\n\r\nonly ten b").await.unwrap();
        tls.flush().await.unwrap();
        std::future::pending::<()>().await;
    })
    .await;
    let mut req = get(https(addr, "/"));
    req.timeout = SHORT;
    let e = no_answer(client().send(req).await);
    assert_eq!(e, HttpError { failure: HttpFailure::Timeout, detail: format!("{addr}: no whole answer within 100ms") });
}
