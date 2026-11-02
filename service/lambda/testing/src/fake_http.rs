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
            loop {
                let Ok((stream, _)) = listener.accept().await else { return };
                tokio::spawn(serve(shared.clone(), stream));
            }
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

async fn serve(state: Arc<Mutex<State>>, mut stream: TcpStream) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let (head, body_start) = loop {
        let Ok(n) = stream.read(&mut chunk).await else { return };
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
        let Ok(n) = stream.read(&mut chunk).await else { return };
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
