//! The one log line of each request, a JSON object on stdout with its keys in a fixed order. Nothing else is printed:
//! no tracing subscriber is installed. A line never holds the E2B key, the sandbox's access token, the session token,
//! the CSRF value or a cookie: it names the outcome, a reason class and the ids that are ours.

use std::io::Write;
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::Value;

/// Where a line goes: stdout in the function, a recorder in a test.
pub type Sink = Arc<dyn Fn(&str) + Send + Sync>;

/// Writes each line to `out`, followed by a newline, and flushes it, so a line is out before the answer is posted. A
/// write that fails is dropped: the answer does not depend on the log.
pub fn writer_sink(out: Box<dyn Write + Send>) -> Sink {
    let out = Mutex::new(out);
    Arc::new(move |line| {
        let mut out = out.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = writeln!(out, "{line}").and_then(|()| out.flush());
    })
}

/// Writes each line to stdout ([`writer_sink`]).
pub fn stdout_sink() -> Sink {
    writer_sink(Box::new(std::io::stdout()))
}

fn text(s: &str) -> String {
    Value::String(s.to_string()).to_string()
}

/// A sandbox was created for the account `github_id`.
pub fn created(github_id: u64, request_id: &str, sandbox_id: &str) -> String {
    format!(
        r#"{{"event":"tutorial_sandbox","github_id":{github_id},"outcome":"created","request_id":{},"sandbox_id":{}}}"#,
        text(request_id),
        text(sandbox_id)
    )
}

/// The sandbox service could not give a sandbox; `reason` is a class (`e2b_status_429`, `secret_missing`, ...).
pub fn unavailable(request_id: &str, reason: &str) -> String {
    format!(
        r#"{{"event":"tutorial_sandbox","outcome":"unavailable","reason":{},"request_id":{}}}"#,
        text(reason),
        text(request_id)
    )
}

/// The request was refused (400, 401, 403); `code` is the error code of the answer.
pub fn refused(request_id: &str, code: &str) -> String {
    format!(
        r#"{{"event":"tutorial_sandbox","outcome":"refused","reason":{},"request_id":{}}}"#,
        text(code),
        text(request_id)
    )
}

/// The function failed on its own side (500).
pub fn internal(request_id: &str) -> String {
    format!(
        r#"{{"event":"tutorial_sandbox","outcome":"error","reason":"internal_error","request_id":{}}}"#,
        text(request_id)
    )
}
