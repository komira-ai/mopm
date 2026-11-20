//! mopm_e2b: E2B's create call for the tutorial sandbox (`docs/design/tutorial-sign-in.md` section 4), over
//! [`HttpClient`]. One function, [`create_sandbox`], and its types: the request it sends, and the [`Grant`] it reads
//! from E2B's answer. Every way E2B can fail to give a usable sandbox is [`E2bError::Unavailable`], which the
//! `tutorial-sandbox` function answers as 503 `tutorial_unavailable`.
//!
//! The team key ([`ApiKey`]) and the sandbox's access token ([`AccessToken`]) print as `<redacted>` in `Debug`, and no
//! type or error of this crate shows either of them in its `Debug` or `Display`.

use std::fmt;
use std::time::Duration;

use jiff::{SignedDuration, Timestamp};
use mopm_ports::env::Clock;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::http::{HttpClient, HttpFailure, HttpRequest, HttpResponse, Method};
use serde::Deserialize;
use serde_json::json;
use thiserror::Error;

/// E2B's platform API, the base of [`Settings::api_base`].
pub const E2B_API: &str = "https://api.e2b.app";

/// The create call's path ("Create sandbox (v2)").
pub const CREATE_PATH: &str = "/v2/sandboxes";

/// The longest the create call may take, connecting included. The function's own timeout is 10 s, so an E2B that does
/// not answer is still answered with `tutorial_unavailable` and not cut off by Lambda.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);

/// The sandbox's lifetime in seconds unless the stage sets another: E2B ends it this long after creation.
pub const DEFAULT_TIMEOUT_S: u32 = 1800;

/// The domain of a sandbox E2B answers without one.
pub const DEFAULT_DOMAIN: &str = "e2b.app";

/// What redacted text reads as in `Debug`.
const REDACTED: &str = "<redacted>";

/// E2B's team API key. It is sent in `X-API-Key` and nowhere else; `Debug` prints `ApiKey(<redacted>)` and it has no
/// `Display`.
#[derive(Clone)]
pub struct ApiKey(String);

impl ApiKey {
    pub fn new(key: impl Into<String>) -> ApiKey {
        ApiKey(key.into())
    }
}

impl fmt::Debug for ApiKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("ApiKey")
            .field(&format_args!("{REDACTED}"))
            .finish()
    }
}

/// The sandbox's access token (`envdAccessToken`): it opens this one sandbox. The function hands it to the signed-in
/// browser with [`AccessToken::expose`]; `Debug` prints `AccessToken(<redacted>)` and it has no `Display`.
#[derive(Clone, PartialEq, Eq)]
pub struct AccessToken(String);

impl AccessToken {
    /// The token itself, for the response body. Never for a log.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("AccessToken")
            .field(&format_args!("{REDACTED}"))
            .finish()
    }
}

/// The stage's E2B settings, and where E2B is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    /// Where the create call goes, without a trailing `/`: [`E2B_API`]. A test points it at its fake.
    pub api_base: String,
    /// The stage's name, sent as `metadata.mopm_stage`.
    pub stage: String,
    /// The stage's tutorial template (`templateID`).
    pub template_id: String,
    /// The sandbox's lifetime (`timeout`), in seconds.
    pub timeout_s: u32,
    /// The domain of a sandbox whose answer has none.
    pub e2b_domain: String,
}

impl Settings {
    /// `stage` and `template_id` on E2B's API, with the default timeout and domain.
    pub fn new(stage: impl Into<String>, template_id: impl Into<String>) -> Settings {
        Settings {
            api_base: E2B_API.to_string(),
            stage: stage.into(),
            template_id: template_id.into(),
            timeout_s: DEFAULT_TIMEOUT_S,
            e2b_domain: DEFAULT_DOMAIN.to_string(),
        }
    }
}

/// A created sandbox, as the tutorial route answers it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grant {
    /// E2B's id of the sandbox (`sandboxID`).
    pub sandbox_id: String,
    /// The sandbox's access token (`envdAccessToken`).
    pub access_token: AccessToken,
    /// The version of the sandbox's agent (`envdVersion`).
    pub envd_version: String,
    /// The base domain of the sandbox's address: E2B's `domain`, or [`Settings::e2b_domain`] when E2B gave none.
    pub domain: String,
    /// When E2B ends the sandbox, as we count it: the time the request was sent plus [`Settings::timeout_s`], RFC 3339
    /// in UTC to the second (`2026-11-20T10:30:00Z`). The fraction of the send time is dropped, so it is never later
    /// than E2B's own end.
    pub expires_at: String,
}

/// Why no grant came back.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum E2bError {
    /// E2B did not give a usable sandbox (the route's 503 `tutorial_unavailable`).
    #[error("E2B is unavailable: {0}")]
    Unavailable(Unavailable),
}

/// The reason behind [`E2bError::Unavailable`], for the log. None of them carries a header or a body of the exchange.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum Unavailable {
    /// E2B answered with a status outside 2xx: it refused (its concurrency limit, a bad key) or failed.
    #[error("E2B answered {0}")]
    Status(u16),
    /// The request got no answer.
    #[error("no answer: {failure}: {detail}")]
    NoAnswer {
        failure: HttpFailure,
        detail: String,
    },
    /// The HTTP client failed for a reason of its own.
    #[error("the HTTP client failed: {0}")]
    Client(String),
    /// A 2xx answer that is not the JSON of a sandbox. Only the place is kept: a decode error's own text can quote
    /// the answer.
    #[error("the answer is not a sandbox (JSON line {line}, column {column})")]
    Malformed { line: usize, column: usize },
    /// A 2xx answer without `sandboxID` or `envdVersion`, or with one of them empty.
    #[error("the answer has no {0}")]
    Missing(&'static str),
    /// A sandbox without `envdAccessToken`: its agent would take commands from anyone who knew its id.
    #[error("the sandbox has no access token")]
    NoAccessToken,
    /// The clock is so late that the sandbox's end is past the last representable time. Nothing was sent.
    #[error("the sandbox's end is past the last representable time")]
    ExpiryOutOfRange,
}

impl From<Unavailable> for E2bError {
    fn from(why: Unavailable) -> E2bError {
        E2bError::Unavailable(why)
    }
}

/// The members of E2B's create answer the grant is made of; any other is ignored.
#[derive(Deserialize)]
struct Created {
    #[serde(rename = "sandboxID")]
    sandbox_id: Option<String>,
    #[serde(rename = "envdVersion")]
    envd_version: Option<String>,
    #[serde(rename = "envdAccessToken")]
    envd_access_token: Option<String>,
    domain: Option<String>,
}

/// Creates the tutorial sandbox: `POST {api_base}/v2/sandboxes` with the team key in `X-API-Key` and section 4's
/// body, which turns the sandbox's internet and public traffic off and tags it with the stage and `request_id`. The
/// clock is read once, just before the request is sent; the grant expires that long after it.
pub async fn create_sandbox<H: HttpClient>(
    http: &H,
    api_key: &ApiKey,
    settings: &Settings,
    request_id: &str,
    clock: &dyn Clock,
) -> Result<Grant, E2bError> {
    let (request, expires_at) = prepare(api_key, settings, request_id, clock.now())?;
    read_answer(http.send(request).await, settings, expires_at)
}

/// The request, and the grant's `expires_at` for a request sent at `sent_at`.
fn prepare(
    api_key: &ApiKey,
    settings: &Settings,
    request_id: &str,
    sent_at: Timestamp,
) -> Result<(HttpRequest, String), E2bError> {
    let expires_at = sent_at
        .checked_add(SignedDuration::from_secs(i64::from(settings.timeout_s)))
        .map_err(|_| Unavailable::ExpiryOutOfRange)?;
    // Section 4's body. `allow_internet_access` and `network.allowPublicTraffic` are what keep the sandbox off the
    // internet and its URLs private; `metadata` names no user.
    let body = json!({
        "templateID": settings.template_id,
        "timeout": settings.timeout_s,
        "allow_internet_access": false,
        "autoPause": false,
        "network": {"allowPublicTraffic": false},
        "metadata": {"mopm_stage": settings.stage, "mopm_request": request_id},
    });
    let request = HttpRequest {
        method: Method::Post,
        url: format!("{}{CREATE_PATH}", settings.api_base),
        headers: vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("X-API-Key".to_string(), api_key.0.clone()),
        ],
        body: body.to_string().into_bytes(),
        timeout: REQUEST_TIMEOUT,
    };
    Ok((
        request,
        expires_at.strftime("%Y-%m-%dT%H:%M:%SZ").to_string(),
    ))
}

/// E2B's answer as a grant, or why there is none.
fn read_answer(
    answer: PortResult<HttpResponse>,
    settings: &Settings,
    expires_at: String,
) -> Result<Grant, E2bError> {
    let response = answer.map_err(|e| match e {
        PortError::Http(e) => Unavailable::NoAnswer {
            failure: e.failure,
            detail: e.detail,
        },
        other => Unavailable::Client(other.to_string()),
    })?;
    if !(200..300).contains(&response.status) {
        return Err(Unavailable::Status(response.status).into());
    }
    let created: Created =
        serde_json::from_slice(&response.body).map_err(|e| Unavailable::Malformed {
            line: e.line(),
            column: e.column(),
        })?;
    let present = |v: Option<String>| v.filter(|s| !s.is_empty());
    let sandbox_id = present(created.sandbox_id).ok_or(Unavailable::Missing("sandboxID"))?;
    let envd_version = present(created.envd_version).ok_or(Unavailable::Missing("envdVersion"))?;
    let access_token = present(created.envd_access_token).ok_or(Unavailable::NoAccessToken)?;
    Ok(Grant {
        sandbox_id,
        access_token: AccessToken(access_token),
        envd_version,
        domain: present(created.domain).unwrap_or_else(|| settings.e2b_domain.clone()),
        expires_at,
    })
}

#[cfg(test)]
#[path = "lib_tests.rs"]
mod tests;
