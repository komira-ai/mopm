//! A scripted HTTP server on loopback (127.0.0.1, port 0) for the adapters of services that are not DynamoDB (S3, SQS,
//! CloudFront, Secrets Manager) and for the typed fakes built on it (`fake_github`, `fake_e2b`). It records every
//! request exactly as sent, and answers it with what its handler decides: a reply, a dropped connection, or nothing at
//! all. [`FakeHttp::start`] answers from a list of replies in order (the last one repeats). The client talks to it
//! over real HTTP/1.1, one request per connection (every reply says `Connection: close`), so what is held is the client
//! AND its serialisation.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;

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
    /// The first header of that name; `name` is lower-case.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
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

    /// The body as JSON; `None` when it is not JSON.
    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice(&self.body).ok()
    }

    /// The body as `application/x-www-form-urlencoded` pairs, decoded, in the order sent.
    pub fn form(&self) -> Vec<(String, String)> {
        decode_form(&String::from_utf8_lossy(&self.body))
    }
}

/// The value of the first pair named `name`.
pub(crate) fn form_value<'a>(pairs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    pairs
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.as_str())
}

/// `a=1&b=x+y%21` as `[("a", "1"), ("b", "x y!")]`. A pair without `=` has an empty value; a `%` not followed by two
/// hex digits stays a `%`.
pub fn decode_form(s: &str) -> Vec<(String, String)> {
    s.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (decode_component(k), decode_component(v))
        })
        .collect()
}

fn decode_component(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = (bytes[i] == b'%')
            .then(|| bytes.get(i + 1..i + 3))
            .flatten()
            .and_then(|h| hex::decode(h).ok());
        match (bytes[i], escaped) {
            (_, Some(b)) => {
                out.extend(b);
                i += 3;
            }
            (b'+', None) => {
                out.push(b' ');
                i += 1;
            }
            (b, None) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `pairs` as `application/x-www-form-urlencoded`: unreserved characters as they are, every other byte `%XX`.
pub(crate) fn encode_form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn encode_component(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
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
        Reply {
            status,
            headers: vec![],
            body: vec![],
        }
    }

    /// A reply with `Content-Type: application/json` and `body` serialised.
    pub fn json(status: u16, body: &serde_json::Value) -> Reply {
        Reply::new(status)
            .header("Content-Type", "application/json")
            .body(body.to_string())
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

/// What the server does with one request, after recording it.
#[derive(Clone, Debug)]
pub enum Answer {
    Reply(Reply),
    /// Close the connection without sending a byte: the client sees the connection end before any answer.
    Drop,
    /// Send nothing and keep the connection open until the server is dropped: only the client's own timeout ends the
    /// wait. Other connections are served meanwhile.
    Hang,
}

type Handler = Box<dyn FnMut(&Seen) -> Answer + Send>;

struct State {
    seen: Vec<Seen>,
    handler: Handler,
}

pub struct FakeHttp {
    addr: SocketAddr,
    state: Arc<Mutex<State>>,
    /// The number of requests recorded so far, for [`FakeHttp::wait_for_requests`].
    count: watch::Receiver<usize>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for FakeHttp {
    /// Stops accepting, and closes every connection still open (a hanging one included): the accept task owns them.
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl FakeHttp {
    /// Serves `replies` in order on the current tokio runtime (so it must be called inside one); once they are used
    /// up the last repeats, and with none every request gets an empty 200.
    pub fn start(replies: Vec<Reply>) -> FakeHttp {
        let last = replies.last().cloned().unwrap_or_else(|| Reply::new(200));
        let mut queue: VecDeque<Reply> = replies.into();
        FakeHttp::with_handler(move |_| {
            Answer::Reply(queue.pop_front().unwrap_or_else(|| last.clone()))
        })
    }

    /// Serves every request with what `handler` answers for it, on the current tokio runtime. The handler sees each
    /// request once, in the order they are recorded, after it is recorded. It runs under the server's lock, so it must
    /// not call back into this `FakeHttp`; if it panics, that request's connection closes unanswered and the server
    /// keeps serving the next ones.
    pub fn with_handler(handler: impl FnMut(&Seen) -> Answer + Send + 'static) -> FakeHttp {
        FakeHttp::serve_with(Box::new(handler))
    }

    /// One server for every handler type: what is not generic is instantiated once.
    fn serve_with(handler: Handler) -> FakeHttp {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        std_listener
            .set_nonblocking(true)
            .expect("a non-blocking listener");
        let addr = std_listener.local_addr().expect("a local address");
        let listener = TcpListener::from_std(std_listener).expect("a tokio listener");
        let state = Arc::new(Mutex::new(State {
            seen: vec![],
            handler,
        }));
        let (counter, count) = watch::channel(0);
        let shared = state.clone();
        let task = tokio::spawn(async move {
            // The first accept error ends the server, as before.
            let _ = accept_all(listener, shared, counter).await;
        });
        FakeHttp {
            addr,
            state,
            count,
            task,
        }
    }

    pub fn endpoint(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        // A handler that panicked left the state whole: it runs after the request is recorded.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Every request, oldest first.
    pub fn requests(&self) -> Vec<Seen> {
        self.lock().seen.clone()
    }

    /// Returns once at least `n` requests are recorded: a progress event, so a test can wait for a request that will
    /// never be answered without a timer.
    pub async fn wait_for_requests(&self, n: usize) {
        let mut count = self.count.clone();
        count.wait_for(|c| *c >= n).await.expect(
            "the server stopped accepting (an accept error) before that many requests came",
        );
    }
}

/// Serves every connection until `accept` fails. The connections' tasks belong to a set this function owns, so they all
/// end when it returns or when the task running it is aborted (the server dropped): a hanging connection closes then.
async fn accept_all(
    listener: TcpListener,
    state: Arc<Mutex<State>>,
    counter: watch::Sender<usize>,
) -> Option<()> {
    let mut connections = JoinSet::new();
    loop {
        let (stream, _) = listener.accept().await.ok()?;
        while connections.try_join_next().is_some() {}
        connections.spawn(serve(state.clone(), counter.clone(), stream));
    }
}

/// The method, the target and the headers (names lower-cased) of a request head.
fn parse_head(head: &str) -> (String, String, Vec<(String, String)>) {
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let headers = lines
        .filter_map(|l| {
            l.split_once(':')
                .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        })
        .collect();
    (method, target, headers)
}

async fn serve(state: Arc<Mutex<State>>, counter: watch::Sender<usize>, mut stream: TcpStream) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    // Read until the head and a body of its `Content-Length` are in; however the bytes arrive, one path.
    let (method, target, headers, body) = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let (method, target, headers) = parse_head(&String::from_utf8_lossy(&buf[..i]));
            let len: usize = headers
                .iter()
                .find(|(k, _)| k == "content-length")
                .and_then(|(_, v)| v.parse().ok())
                .unwrap_or(0);
            if buf.len() >= i + 4 + len {
                break (method, target, headers, buf[i + 4..i + 4 + len].to_vec());
            }
        }
        // A read error is a connection that ended: nothing to record.
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let seen = Seen {
        method,
        target,
        headers,
        body,
    };
    let head_only = seen.method == "HEAD";
    let answer = {
        let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
        let State { seen: all, handler } = &mut *st;
        all.push(seen);
        counter.send_replace(all.len());
        handler(&all[all.len() - 1])
    };
    let reply = match answer {
        Answer::Reply(reply) => reply,
        Answer::Drop => return,
        Answer::Hang => return std::future::pending().await,
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
    if !head_only {
        let _ = stream.write_all(&reply.body).await;
    }
    let _ = stream.shutdown().await;
}

/// A raw HTTP/1.1 client for the tests of the fakes: no client crate, so what is sent is exactly what the test wrote.
#[cfg(test)]
pub(crate) mod client {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    /// A parsed answer.
    #[derive(Debug)]
    pub(crate) struct Answered {
        pub status: u16,
        /// Names lower-cased.
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
    }

    impl Answered {
        pub fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.as_str())
        }

        pub fn json(&self) -> serde_json::Value {
            serde_json::from_slice(&self.body).expect("a JSON body")
        }

        pub fn text(&self) -> String {
            String::from_utf8(self.body.clone()).expect("a UTF-8 body")
        }
    }

    /// `method target` with `headers`, and `body` with its `Content-Length`.
    pub(crate) fn request(
        method: &str,
        target: &str,
        headers: &[(&str, &str)],
        body: &[u8],
    ) -> Vec<u8> {
        let mut out = format!("{method} {target} HTTP/1.1\r\nHost: fake\r\n");
        for (k, v) in headers {
            out.push_str(&format!("{k}: {v}\r\n"));
        }
        out.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
        let mut out = out.into_bytes();
        out.extend_from_slice(body);
        out
    }

    /// Sends `raw` on a new connection and returns every byte the server sent before it closed the connection.
    pub(crate) async fn exchange_raw(endpoint: &str, raw: &[u8]) -> Vec<u8> {
        let mut stream = TcpStream::connect(endpoint.trim_start_matches("http://"))
            .await
            .expect("a connection to the fake");
        stream.write_all(raw).await.expect("the request is written");
        let mut out = Vec::new();
        // A reset after a dropped connection is an end like any other: what was read so far is the answer.
        let _ = stream.read_to_end(&mut out).await;
        out
    }

    /// The answer to `raw`; `None` when the server closed the connection without one.
    pub(crate) async fn exchange(endpoint: &str, raw: &[u8]) -> Option<Answered> {
        parse(&exchange_raw(endpoint, raw).await)
    }

    pub(crate) fn parse(raw: &[u8]) -> Option<Answered> {
        let i = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
        let head = String::from_utf8_lossy(&raw[..i]).to_string();
        let mut lines = head.lines();
        let status = lines.next()?.split(' ').nth(1)?.parse().ok()?;
        let headers = lines
            .filter_map(|l| {
                l.split_once(':')
                    .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
            })
            .collect();
        Some(Answered {
            status,
            headers,
            body: raw[i + 4..].to_vec(),
        })
    }
}

#[cfg(test)]
#[path = "fake_http_tests.rs"]
mod tests;

/// `FakeHttp::start` as the S3, SQS, CloudFront and Secrets Manager adapters' tests use it.
#[cfg(test)]
mod start_tests {
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
        let reply = exchange(
            &fake,
            b"GET /bucket/key?list-type=2&prefix=a%2Fb HTTP/1.1\r\nHost: x\r\n\r\n",
        )
        .await;
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
        assert_eq!(
            seen[0].signed_headers(),
            vec!["host".to_string(), "x-amz-date".to_string()]
        );
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
        s.write_all(b"GET /half HTTP/1.1\r\nHost: x\r\n")
            .await
            .unwrap();
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
        s.write_all(b"PUT /k HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
            .await
            .unwrap();
        s.shutdown().await.unwrap();
        assert!(read_to_end(&mut s).await.is_empty());
        assert!(fake.requests().is_empty());
    }

    #[tokio::test]
    async fn a_body_larger_than_one_read_is_recorded_whole() {
        let fake = FakeHttp::start(vec![]);
        let body: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let mut raw = format!(
            "PUT /big HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        raw.extend_from_slice(&body);
        let mut s = connect(&fake).await;
        s.write_all(&raw).await.unwrap();
        let reply = String::from_utf8(read_to_end(&mut s).await).unwrap();
        assert!(reply.starts_with("HTTP/1.1 200 OK\r\n"));
        assert_eq!(fake.requests()[0].body, body);
    }

    #[tokio::test]
    async fn an_error_status_is_answered_with_its_headers_and_body() {
        let fake = FakeHttp::start(vec![Reply::new(404)
            .header("x-amz-request-id", "r1")
            .body("nope")]);
        let reply = exchange(&fake, b"GET /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(reply, "HTTP/1.1 404 Error\r\nx-amz-request-id: r1\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope");
    }

    #[tokio::test]
    async fn a_reply_that_sets_content_length_is_not_given_a_second_one() {
        let fake = FakeHttp::start(vec![Reply::new(200)
            .header("Content-Length", "4")
            .body("data")]);
        let reply = exchange(&fake, b"GET /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(
            reply,
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata"
        );
    }

    #[tokio::test]
    async fn a_head_reply_carries_the_length_but_no_body() {
        let fake = FakeHttp::start(vec![Reply::new(200).body("data")]);
        let reply = exchange(&fake, b"HEAD /k HTTP/1.1\r\n\r\n").await;
        assert_eq!(
            reply,
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
        );
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
