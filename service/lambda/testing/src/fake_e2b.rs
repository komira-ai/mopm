//! A fake of E2B's platform API, as far as the tutorial uses it: the create call `POST /v2/sandboxes`
//! (`docs/design/tutorial-sign-in.md` section 4), on a [`FakeHttp`] on loopback.
//!
//! - A request without the configured key in `X-API-Key` is 401, whatever its route after that.
//! - Any other route (method and path) is 404.
//! - Each create carrying the key takes the next answer of the script, in order; once the script is used up its last
//!   answer repeats, and an empty script answers [`Sandbox::example`]. A refused or unrouted request does not take one.
//! - Every request is recorded in full ([`FakeE2b::requests`]), so a test asserts the create body byte for byte or as
//!   JSON ([`Seen::json`]).
//!
//! Error bodies have the shape of E2B's `Error` schema, `{"code": <status>, "message": <text>}`; the texts are the
//! fake's own.

use std::collections::VecDeque;

use serde_json::{json, Map, Value};

use crate::fake_http::{Answer, FakeHttp, Reply, Seen};

/// The create call's path.
pub const CREATE_PATH: &str = "/v2/sandboxes";

/// A created sandbox, as E2B's create call answers it (201).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sandbox {
    pub template_id: String,
    pub sandbox_id: String,
    pub envd_version: String,
    /// `None`: the answer has no `envdAccessToken` member at all.
    pub envd_access_token: Option<String>,
    /// `None`: the answer has `"domain": null`.
    pub domain: Option<String>,
}

impl Sandbox {
    /// A complete answer: every member present, `domain` `e2b.app`.
    pub fn example() -> Sandbox {
        Sandbox {
            template_id: "mopm-tutorial-test".into(),
            sandbox_id: "itest0sandbox0000001".into(),
            envd_version: "0.2.4".into(),
            envd_access_token: Some("envd-token-0123456789abcdef".into()),
            domain: Some("e2b.app".into()),
        }
    }

    /// The same sandbox with `"domain": null`.
    pub fn null_domain(self) -> Sandbox {
        Sandbox {
            domain: None,
            ..self
        }
    }

    /// The same sandbox without an `envdAccessToken` member.
    pub fn without_access_token(self) -> Sandbox {
        Sandbox {
            envd_access_token: None,
            ..self
        }
    }

    /// The answer's body: `templateID`, `sandboxID`, `envdVersion`, `envdAccessToken` (when present) and `domain`, the
    /// members of E2B's `Sandbox` schema the tutorial reads (it ignores any other).
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("templateID".into(), json!(self.template_id));
        m.insert("sandboxID".into(), json!(self.sandbox_id));
        m.insert("envdVersion".into(), json!(self.envd_version));
        if let Some(token) = &self.envd_access_token {
            m.insert("envdAccessToken".into(), json!(token));
        }
        m.insert("domain".into(), json!(self.domain));
        Value::Object(m)
    }
}

/// One scripted answer to a create.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CreateAnswer {
    /// 201 and [`Sandbox::to_json`].
    Created(Sandbox),
    /// E2B refuses: `status` and `{"code": status, "message": message}`.
    Refused { status: u16, message: String },
    /// Nothing, ever: the connection stays open until the fake is dropped, so only the caller's timeout ends it.
    Hang,
}

impl CreateAnswer {
    /// The team is at its plan's concurrency limit: 429.
    pub fn concurrency_limit() -> CreateAnswer {
        CreateAnswer::Refused {
            status: 429,
            message: "You have reached the maximum number of concurrent E2B sandboxes".into(),
        }
    }

    /// An outage: `status` (a 5xx).
    pub fn server_error(status: u16) -> CreateAnswer {
        CreateAnswer::Refused {
            status,
            message: "Internal server error".into(),
        }
    }

    fn answer(&self) -> Answer {
        match self {
            CreateAnswer::Created(sandbox) => Answer::Reply(Reply::json(201, &sandbox.to_json())),
            CreateAnswer::Refused { status, message } => Answer::Reply(error(*status, message)),
            CreateAnswer::Hang => Answer::Hang,
        }
    }
}

fn error(status: u16, message: &str) -> Reply {
    Reply::json(status, &json!({"code": status, "message": message}))
}

/// The fake E2B API. Dropping it closes every connection, a hanging one included.
pub struct FakeE2b {
    http: FakeHttp,
}

impl FakeE2b {
    /// Serves on the current tokio runtime; `api_key` is the team key it accepts.
    pub fn start(api_key: &str, script: Vec<CreateAnswer>) -> FakeE2b {
        let api_key = api_key.to_string();
        let last = script
            .last()
            .cloned()
            .unwrap_or_else(|| CreateAnswer::Created(Sandbox::example()));
        let mut script: VecDeque<CreateAnswer> = script.into();
        let http = FakeHttp::with_handler(move |seen| {
            if seen.header("x-api-key") != Some(api_key.as_str()) {
                return Answer::Reply(error(401, "Invalid API key"));
            }
            if (seen.method.as_str(), seen.path()) != ("POST", CREATE_PATH) {
                return Answer::Reply(error(404, "Not found"));
            }
            script.pop_front().unwrap_or_else(|| last.clone()).answer()
        });
        FakeE2b { http }
    }

    /// `http://127.0.0.1:<port>`, in place of `https://api.e2b.app`.
    pub fn endpoint(&self) -> String {
        self.http.endpoint()
    }

    /// Every request, oldest first, whatever its route and key.
    pub fn requests(&self) -> Vec<Seen> {
        self.http.requests()
    }

    /// The requests to the create route (`POST /v2/sandboxes`), with or without the key, oldest first.
    pub fn create_requests(&self) -> Vec<Seen> {
        self.requests()
            .into_iter()
            .filter(|r| r.method == "POST" && r.path() == CREATE_PATH)
            .collect()
    }

    /// Returns once at least `n` requests are recorded (see [`FakeHttp::wait_for_requests`]).
    pub async fn wait_for_requests(&self, n: usize) {
        self.http.wait_for_requests(n).await
    }
}

#[cfg(test)]
#[path = "fake_e2b_tests.rs"]
mod tests;
