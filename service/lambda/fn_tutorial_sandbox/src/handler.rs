//! `POST /api/v2/tutorial/sandbox`: a signed-in browser's sandbox on E2B (docs/design/tutorial-sign-in.md, section 4).
//!
//! The checks run in this order, and the first refusal answers. All of them run before any call to E2B, so a request
//! that is not allowed costs E2B nothing:
//!
//! 1. the route: any other path or method is `invalid_request` (the function is routed for one route; this is a
//!    guard against a mis-routing);
//! 2. [`SessionAuth::session_for_post`]: the edge header, no `Authorization`, one session cookie, the CSRF checks, the
//!    session row and its account (and the touch of the row);
//! 3. no body: `invalid_request`;
//! 4. the stage names a template, else `tutorial_unavailable` (`template_missing`);
//! 5. the E2B key ([`KeyCache`]), else `tutorial_unavailable`.
//!
//! Then [`create_sandbox`]. There is no limit, counter or per-user cap of any kind: a user who is still working gets a
//! new sandbox as often as they like, and E2B's own plan limits are `tutorial_unavailable`.

use aws_lambda_events::apigw::{ApiGatewayV2httpRequest, ApiGatewayV2httpResponse};
use mopm_core::error::{invalid_request, ErrorCode, RegistryError};
use mopm_e2b::{create_sandbox, E2bError, Grant, Settings, Unavailable};
use mopm_ports::auth::AuthStore;
use mopm_ports::http::{HttpClient, HttpFailure};
use mopm_ports::secrets::SecretReader;
use mopm_web::apigw::{fallback_internal_error, from_apigw, to_apigw};
use mopm_web::envelope::{error_response, tutorial_unavailable};
use mopm_web::request::Method;
use mopm_web::{SessionAuth, WebRequest, WebResponse};
use serde_json::json;

use crate::clock::SharedClock;
use crate::key::KeyCache;
use crate::log::{self, Sink};

/// The one route this function answers.
pub const ROUTE: &str = "/api/v2/tutorial/sandbox";

/// The seconds `Retry-After` names when the sandbox service is unavailable.
pub const RETRY_AFTER_S: u64 = 30;

/// The function, over its ports: the session store, the HTTP client and the secrets.
pub struct Function<S, H, R> {
    pub(crate) auth: SessionAuth<S, SharedClock>,
    pub(crate) http: H,
    pub(crate) secrets: R,
    pub(crate) key: KeyCache,
    /// `None` when the stage's settings name no template.
    pub(crate) e2b: Option<Settings>,
    pub(crate) clock: SharedClock,
    pub(crate) sink: Sink,
}

/// Why a request got no sandbox.
enum Failure {
    /// Refused by a check, or failed on our side (`internal_error`).
    Error(RegistryError),
    /// No sandbox from the service, for a reason class.
    Unavailable(String),
}

impl Failure {
    fn unavailable(reason: &str) -> Failure {
        Failure::Unavailable(reason.to_string())
    }
}

impl From<E2bError> for Failure {
    fn from(e: E2bError) -> Failure {
        let E2bError::Unavailable(why) = e;
        Failure::Unavailable(reason(&why))
    }
}

/// The class of what E2B did, for the log.
fn reason(why: &Unavailable) -> String {
    match why {
        Unavailable::Status(code) => format!("e2b_status_{code}"),
        Unavailable::NoAnswer {
            failure: HttpFailure::Timeout,
            ..
        } => "e2b_timeout".to_string(),
        Unavailable::NoAnswer {
            failure: HttpFailure::Connect,
            ..
        } => "e2b_no_connection".to_string(),
        Unavailable::NoAnswer {
            failure: HttpFailure::Tls,
            ..
        } => "e2b_tls".to_string(),
        Unavailable::Client(_) => "e2b_client".to_string(),
        Unavailable::Malformed { .. } => "e2b_malformed".to_string(),
        Unavailable::Missing(_) => "e2b_missing_field".to_string(),
        Unavailable::NoAccessToken => "e2b_no_access_token".to_string(),
        Unavailable::ExpiryOutOfRange => "clock_out_of_range".to_string(),
    }
}

fn check_route(req: &WebRequest) -> Result<(), Failure> {
    if req.path == ROUTE && req.method == Method::Post {
        Ok(())
    } else {
        Err(Failure::Error(invalid_request("no such route")))
    }
}

fn check_no_body(req: &WebRequest) -> Result<(), Failure> {
    if req.body.is_empty() {
        Ok(())
    } else {
        Err(Failure::Error(invalid_request("the request takes no body")))
    }
}

/// The answer and the log line of a request's outcome.
fn conclude(outcome: Result<(u64, Grant), Failure>, request_id: &str) -> (WebResponse, String) {
    match outcome {
        Ok((github_id, grant)) => {
            // What the browser gets: the sandbox agent's address and the token to it (keys in this order).
            let body = json!({
                "access_token": grant.access_token.expose(),
                "domain": grant.domain,
                "envd_version": grant.envd_version,
                "expires_at": grant.expires_at,
                "sandbox_id": grant.sandbox_id,
            });
            (
                WebResponse::json(201, &body, request_id),
                log::created(github_id, request_id, &grant.sandbox_id),
            )
        }
        Err(Failure::Unavailable(why)) => (
            error_response(&tutorial_unavailable(RETRY_AFTER_S, &why), request_id),
            log::unavailable(request_id, &why),
        ),
        Err(Failure::Error(err)) => {
            let line = if err.code == ErrorCode::InternalError {
                log::internal(request_id)
            } else {
                log::refused(request_id, err.code.as_str())
            };
            (error_response(&err, request_id), line)
        }
    }
}

impl<S: AuthStore, H: HttpClient, R: SecretReader> Function<S, H, R> {
    /// Answers `req`, and gives the one log line of the request beside the answer.
    pub async fn process(&self, req: &WebRequest) -> (WebResponse, String) {
        conclude(self.serve(req).await, &req.request_id)
    }

    /// Answers one API Gateway event and writes the request's one log line. An event that does not make a request is
    /// `invalid_request`, and an answer API Gateway cannot carry is a plain `internal_error` (and logged as one).
    pub async fn invoke(&self, event: ApiGatewayV2httpRequest) -> ApiGatewayV2httpResponse {
        let request_id = event.request_context.request_id.clone().unwrap_or_default();
        let (response, line) = match from_apigw(event) {
            Ok(req) => self.process(&req).await,
            Err(err) => conclude(Err(Failure::Error(err)), &request_id),
        };
        let (out, line) = match to_apigw(&response) {
            Ok(out) => (out, line),
            Err(_) => (
                fallback_internal_error(&request_id),
                log::internal(&request_id),
            ),
        };
        (self.sink)(&line);
        out
    }

    async fn serve(&self, req: &WebRequest) -> Result<(u64, Grant), Failure> {
        check_route(req)?;
        let session = self
            .auth
            .session_for_post(req)
            .await
            .map_err(Failure::Error)?;
        check_no_body(req)?;
        let settings = self
            .e2b
            .as_ref()
            .ok_or_else(|| Failure::unavailable("template_missing"))?;
        let key = self
            .key
            .get(&self.secrets)
            .await
            .map_err(Failure::unavailable)?;
        let grant = create_sandbox(&self.http, key, settings, &req.request_id, &self.clock).await?;
        Ok((session.user.github_id, grant))
    }
}
