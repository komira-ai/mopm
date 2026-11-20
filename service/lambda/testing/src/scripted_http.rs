//! An `HttpClient` that answers from a script, in memory: each `send` records the request exactly as given
//! and takes the next scripted answer, a response or an [`HttpError`] (a timeout, say, returned at once:
//! nothing waits). A `send` past the end of the script is a fault naming the request, so a test that sends
//! more than it scripted fails loudly.

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard};

use mopm_ports::error::{PortError, PortResult};
use mopm_ports::http::{HttpClient, HttpError, HttpRequest, HttpResponse};

#[derive(Default)]
struct State {
    script: VecDeque<Result<HttpResponse, HttpError>>,
    sent: Vec<HttpRequest>,
}

pub struct ScriptedHttp(Mutex<State>);

impl ScriptedHttp {
    /// Answers `script` in order, one entry per `send`.
    pub fn new(script: Vec<Result<HttpResponse, HttpError>>) -> Self {
        ScriptedHttp(Mutex::new(State { script: script.into(), sent: vec![] }))
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.0.lock().expect("the script's lock is never held across a panic")
    }

    /// Every request sent, oldest first.
    pub fn requests(&self) -> Vec<HttpRequest> {
        self.lock().sent.clone()
    }
}

impl HttpClient for ScriptedHttp {
    async fn send(&self, req: HttpRequest) -> PortResult<HttpResponse> {
        let mut st = self.lock();
        let next = st.script.pop_front();
        let what = format!("{} {}", req.method.as_str(), req.url);
        st.sent.push(req);
        match next {
            Some(answer) => answer.map_err(PortError::from),
            None => Err(PortError::fault(format!("no scripted answer left for {what}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use mopm_ports::http::{HttpFailure, Method};

    use super::*;

    fn get(url: &str) -> HttpRequest {
        HttpRequest { method: Method::Get, url: url.to_string(), headers: vec![], body: vec![], timeout: Duration::from_secs(5) }
    }

    fn reply(status: u16, body: &str) -> HttpResponse {
        HttpResponse { status, headers: vec![("content-type".into(), "application/json".into())], body: body.as_bytes().to_vec() }
    }

    #[tokio::test]
    async fn answers_in_the_order_scripted_a_non_2xx_status_included() {
        let http = ScriptedHttp::new(vec![Ok(reply(200, "{\"a\":1}")), Ok(reply(502, "bad gateway")), Ok(reply(201, ""))]);
        assert_eq!(http.send(get("https://a.test/1")).await.unwrap(), reply(200, "{\"a\":1}"));
        assert_eq!(http.send(get("https://a.test/2")).await.unwrap(), reply(502, "bad gateway"));
        assert_eq!(http.send(get("https://a.test/3")).await.unwrap(), reply(201, ""));
    }

    #[tokio::test]
    async fn records_method_url_headers_body_and_timeout_exactly_as_sent() {
        let http = ScriptedHttp::new(vec![Ok(reply(200, "")), Ok(reply(200, ""))]);
        let post = HttpRequest {
            method: Method::Post,
            url: "https://github.test/login/oauth/access_token?x=1".to_string(),
            headers: vec![("Accept".into(), "application/json".into()), ("accept".into(), "text/plain".into())],
            body: b"code=abc&code_verifier=xyz".to_vec(),
            timeout: Duration::from_millis(8_000),
        };
        http.send(post.clone()).await.unwrap();
        let user = get("https://api.github.test/user");
        http.send(user.clone()).await.unwrap();
        assert_eq!(http.requests(), vec![post, user]);
        assert_eq!(http.requests()[0].timeout, Duration::from_secs(8));
    }

    #[tokio::test]
    async fn a_scripted_timeout_is_an_http_error_returned_at_once_and_the_request_is_still_recorded() {
        let timeout = HttpError { failure: HttpFailure::Timeout, detail: "no answer in 8s".into() };
        let http = ScriptedHttp::new(vec![Err(timeout), Ok(reply(200, "after"))]);
        let create = get("https://e2b.test/v2/sandboxes");
        let err = http.send(create).await.unwrap_err();
        assert_eq!(format!("{err:?}"), r#"Http(HttpError { failure: Timeout, detail: "no answer in 8s" })"#);
        assert_eq!(http.send(get("https://e2b.test/again")).await.unwrap(), reply(200, "after"));
        assert_eq!(http.requests().iter().map(|r| r.url.as_str()).collect::<Vec<_>>(), ["https://e2b.test/v2/sandboxes", "https://e2b.test/again"]);
    }

    #[tokio::test]
    async fn a_send_past_the_end_of_the_script_is_a_fault_naming_the_request() {
        let http = ScriptedHttp::new(vec![]);
        let err = http.send(get("https://a.test/extra")).await.unwrap_err();
        assert_eq!(err.to_string(), "infrastructure fault: no scripted answer left for GET https://a.test/extra");
        assert_eq!(http.requests(), vec![get("https://a.test/extra")]);
    }
}
