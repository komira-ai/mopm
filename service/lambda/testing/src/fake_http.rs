//! A scripted HTTP server on loopback for the adapters of services that are not DynamoDB (S3, SQS,
//! CloudFront, Secrets Manager): it records every request the SDK made, exactly as sent, and answers from
//! a list of replies in order (the last one repeats). The SDK talks to it over real HTTP, so what is held is
//! the adapter AND the SDK's serialisation and signing.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// A request as received.
#[derive(Clone, Debug)]
pub struct Seen {
    pub method: String,
    /// Path and query, as sent (percent-encoded).
    pub target: String,
    /// Header names lower-cased, in the order sent.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Seen {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or("")
    }

    pub fn query(&self) -> &str {
        self.target.split_once('?').map_or("", |(_, q)| q)
    }

    /// The names in the `SignedHeaders=` list of a SigV4 `Authorization` header.
    pub fn signed_headers(&self) -> Vec<String> {
        self.header("authorization")
            .and_then(|a| a.split("SignedHeaders=").nth(1))
            .and_then(|r| r.split(',').next())
            .map(|l| l.split(';').map(str::to_string).collect())
            .unwrap_or_default()
    }
}

/// What the server answers.
#[derive(Clone, Debug)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn new(status: u16) -> Reply {
        Reply { status, headers: vec![], body: vec![] }
    }

    pub fn header(mut self, k: &str, v: &str) -> Reply {
        self.headers.push((k.to_string(), v.to_string()));
        self
    }

    pub fn body(mut self, b: impl Into<Vec<u8>>) -> Reply {
        self.body = b.into();
        self
    }
}

struct State {
    seen: Vec<Seen>,
    replies: VecDeque<Reply>,
    last: Reply,
}

pub struct FakeHttp {
    addr: SocketAddr,
    state: Arc<Mutex<State>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for FakeHttp {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl FakeHttp {
    /// Serves `replies` in order on the current tokio runtime (so it must be called inside one).
    pub fn start(replies: Vec<Reply>) -> FakeHttp {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        std_listener.set_nonblocking(true).expect("a non-blocking listener");
        let addr = std_listener.local_addr().expect("a local address");
        let listener = TcpListener::from_std(std_listener).expect("a tokio listener");
        let last = replies.last().cloned().unwrap_or_else(|| Reply::new(200));
        let state = Arc::new(Mutex::new(State { seen: vec![], replies: replies.into(), last }));
        let shared = state.clone();
        let task = tokio::spawn(async move {
            // The first accept error ends the server, as before.
            let _ = accept_all(listener, shared).await;
        });
        FakeHttp { addr, state, task }
    }

    pub fn endpoint(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().expect("a lock is never held across a panic")
    }

    /// Every request, oldest first.
    pub fn requests(&self) -> Vec<Seen> {
        self.lock().seen.clone()
    }
}

async fn accept_all(listener: TcpListener, state: Arc<Mutex<State>>) -> Option<()> {
    loop {
        let (stream, _) = listener.accept().await.ok()?;
        tokio::spawn(serve(state.clone(), stream));
    }
}

async fn serve(state: Arc<Mutex<State>>, mut stream: TcpStream) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let (head, body_start) = loop {
        // A read error ends the connection exactly as a close does.
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break (String::from_utf8_lossy(&buf[..i]).to_string(), i + 4);
        }
    };
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let headers: Vec<(String, String)> = lines.filter_map(|l| l.split_once(':').map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))).collect();
    let len: usize = headers.iter().find(|(k, _)| k == "content-length").and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
    while buf.len() < body_start + len {
        // A read error ends the connection exactly as a close does.
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body = buf[body_start..body_start + len].to_vec();
    let reply = {
        let mut st = state.lock().expect("a lock is never held across a panic");
        st.seen.push(Seen { method: method.clone(), target, headers, body });
        st.replies.pop_front().unwrap_or_else(|| st.last.clone())
    };
    let reason = if reply.status < 300 { "OK" } else { "Error" };
    let mut out = format!("HTTP/1.1 {} {reason}\r\n", reply.status);
    let mut has_length = false;
    for (k, v) in &reply.headers {
        has_length |= k.eq_ignore_ascii_case("content-length");
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    if !has_length {
        out.push_str(&format!("Content-Length: {}\r\n", reply.body.len()));
    }
    out.push_str("Connection: close\r\n\r\n");
    let _ = stream.write_all(out.as_bytes()).await;
    if method != "HEAD" {
        let _ = stream.write_all(&reply.body).await;
    }
    let _ = stream.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn connect(fake: &FakeHttp) -> TcpStream {
        TcpStream::connect(fake.addr).await.unwrap()
    }

    async fn read_to_end(stream: &mut TcpStream) -> Vec<u8> {
        let mut out = Vec::new();
        stream.read_to_end(&mut out).await.unwrap();
        out
    }

    async fn exchange(fake: &FakeHttp, raw: &[u8]) -> String {
        let mut s = connect(fake).await;
        s.write_all(raw).await.unwrap();
        String::from_utf8(read_to_end(&mut s).await).unwrap()
    }

    #[tokio::test]
    async fn a_request_with_a_query_records_path_and_query_separately() {
        let fake = FakeHttp::start(vec![]);
        let reply = exchange(&fake, b"GET /bucket/key?list-type=2&prefix=a%2Fb HTTP/1.1\r\nHost: x\r\n\r\n").await;
        assert!(reply.starts_with("HTTP/1.1 200 OK\r\n"));
        let seen = fake.requests();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].method, "GET");
        assert_eq!(seen[0].path(), "/bucket/key");
        assert_eq!(seen[0].query(), "list-type=2&prefix=a%2Fb");
        assert_eq!(seen[0].target, "/bucket/key?list-type=2&prefix=a%2Fb");
    }

    #[tokio::test]
    async fn a_request_without_a_query_has_an_empty_query() {
        let fake = FakeHttp::start(vec![]);
        exchange(&fake, b"GET /only/path HTTP/1.1\r\nHost: x\r\n\r\n").await;
        let seen = fake.requests();
        assert_eq!(seen[0].path(), "/only/path");
        assert_eq!(seen[0].query(), "");
    }

    #[tokio::test]
    async fn headers_are_lower_cased_and_signed_headers_are_listed() {
        let fake = FakeHttp::start(vec![]);
        let auth = "AWS4-HMAC-SHA256 Credential=AK/20261119/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=abc";
        exchange(&fake, format!("PUT /k HTTP/1.1\r\nHost: h\r\nAuthorization: {auth}\r\nContent-Length: 2\r\n\r\nhi").as_bytes()).await;
        let seen = fake.requests();
        assert_eq!(seen[0].header("host"), Some("h"));
        assert_eq!(seen[0].header("missing"), None);
        assert_eq!(seen[0].signed_headers(), vec!["host".to_string(), "x-amz-date".to_string()]);
        assert_eq!(seen[0].body, b"hi");
    }

    #[tokio::test]
    async fn a_request_without_authorization_has_no_signed_headers() {
        let fake = FakeHttp::start(vec![]);
        exchange(&fake, b"GET /k HTTP/1.1\r\nHost: h\r\n\r\n").await;
        assert!(fake.requests()[0].signed_headers().is_empty());
    }

    #[tokio::test]
    async fn a_client_that_closes_mid_header_is_not_recorded_and_the_next_request_is_served() {
        let fake = FakeHttp::start(vec![Reply::new(204)]);
        let mut s = connect(&fake).await;
        s.write_all(b"GET /half HTTP/1.1\r\nHost: x\r\n").await.unwrap();
        s.shutdown().await.unwrap();
        assert!(read_to_end(&mut s).await.is_empty());
        assert!(fake.requests().is_empty());
        let reply = exchange(&fake, b"GET /whole HTTP/1.1\r\nHost: x\r\n\r\n").await;
        assert!(reply.starts_with("HTTP/1.1 204 OK\r\n"));
        assert_eq!(fake.requests().len(), 1);
        assert_eq!(fake.requests()[0].path(), "/whole");
    }

    #[tokio::test]
    async fn a_client_that_closes_mid_body_is_not_recorded() {
        let fake = FakeHttp::start(vec![]);
        let mut s = connect(&fake).await;
        s.write_all(b"PUT /k HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc").await.unwrap();
        s.shutdown().await.unwrap();
        assert!(read_to_end(&mut s).await.is_empty());
        assert!(fake.requests().is_empty());
    }

    #[tokio::test]
    async fn a_body_larger_than_one_read_is_recorded_whole() {
        let fake = FakeHttp::start(vec![]);
        let body: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let mut raw = format!("PUT /big HTTP/1.1\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        raw.extend_from_slice(&body);
        let mut s = connect(&fake).await;
        s.write_all(&raw).await.unwrap();
        let reply = String::from_utf8(read_to_end(&mut s).await).unwrap();
        assert!(reply.starts_with("HTTP/1.1 200 OK\r\n"));
        assert_eq!(fake.requests()[0].body, body);
    }

    #[tokio::test]
    async fn an_error_status_is_answered_with_its_headers_and_body() {
        let fake = FakeHttp::start(vec![Reply::new(404).header("x-amz-request-id", "r1").body("nope")]);
        let reply = exchange(&fake, b"GET /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(reply, "HTTP/1.1 404 Error\r\nx-amz-request-id: r1\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope");
    }

    #[tokio::test]
    async fn a_reply_that_sets_content_length_is_not_given_a_second_one() {
        let fake = FakeHttp::start(vec![Reply::new(200).header("Content-Length", "4").body("data")]);
        let reply = exchange(&fake, b"GET /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(reply, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata");
    }

    #[tokio::test]
    async fn a_head_reply_carries_the_length_but_no_body() {
        let fake = FakeHttp::start(vec![Reply::new(200).body("data")]);
        let reply = exchange(&fake, b"HEAD /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(reply, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n");
    }

    #[tokio::test]
    async fn replies_are_served_in_order_and_the_last_repeats() {
        let fake = FakeHttp::start(vec![Reply::new(201), Reply::new(202)]);
        let mut statuses = Vec::new();
        for _ in 0..3 {
            let reply = exchange(&fake, b"GET /k HTTP/1.1\r\n\r\n").await;
            statuses.push(reply[9..12].to_string());
        }
        assert_eq!(statuses, ["201", "202", "202"]);
        assert!(fake.endpoint().starts_with("http://127.0.0.1:"));
    }
}
