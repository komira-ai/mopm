//! The two routes of the `web-session` function and the event entry.
//!
//! Routing is on the path and the method of the [`WebRequest`], before any check: API Gateway sends this function the
//! two route keys only, and an unknown path or another method on those paths is `route_not_found` (404), the v2 API's
//! answer for both (it has no `method_not_allowed`). Then:
//!
//! * `GET /api/v2/auth/web/session`: [`SessionAuth::session`]; 200 with `{"csrf", "expires_at", "login"}`;
//! * `POST /api/v2/auth/web/logout`: [`SessionAuth::session_for_post`] (the CSRF checks included), then the revocation
//!   of that session's row alone (`revoke_token` by its hash, at the clock's time); 204 with the cookie cleared.
//!
//! [`WebSessionHandler::handle_event`] is what the runtime calls: the event to a request ([`from_apigw`]), the answer,
//! the response to an event ([`to_apigw`]; a response HTTP cannot carry is [`fallback_internal_error`]). Each answer is
//! logged with its method, path, status and, for an error, its code and message; a cookie, a header or a body is never
//! logged, and an error's message never holds the token.

use aws_lambda_events::apigw::{ApiGatewayV2httpRequest, ApiGatewayV2httpResponse};
use mopm_core::csrf::csrf_value;
use mopm_core::error::RegistryError;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{iso_millis, Clock};
use mopm_web::apigw::{fallback_internal_error, from_apigw, to_apigw};
use mopm_web::cookie::clear_session_cookie;
use mopm_web::envelope::{error_response, internal, route_not_found};
use mopm_web::request::Method;
use mopm_web::{SessionAuth, WebRequest, WebResponse};

/// The session route's path.
pub const SESSION_PATH: &str = "/api/v2/auth/web/session";
/// The logout route's path.
pub const LOGOUT_PATH: &str = "/api/v2/auth/web/logout";

/// What the function answers to one request: the response, and the error behind it when it is one (for the log).
#[derive(Debug)]
pub struct Answer {
    pub response: WebResponse,
    pub error: Option<RegistryError>,
}

/// The `web-session` function's routes over the stage's session authenticator.
pub struct WebSessionHandler<S, C> {
    auth: SessionAuth<S, C>,
}

fn method_name(method: &Method) -> &str {
    match method {
        Method::Get => "GET",
        Method::Post => "POST",
        Method::Other(name) => name,
    }
}

impl<S: AuthStore, C: Clock> WebSessionHandler<S, C> {
    pub fn new(auth: SessionAuth<S, C>) -> Self {
        WebSessionHandler { auth }
    }

    /// The answer to `req`.
    pub async fn answer(&self, req: &WebRequest) -> Answer {
        let routed = match (req.path.as_str(), &req.method) {
            (SESSION_PATH, Method::Get) => self.session(req).await,
            (LOGOUT_PATH, Method::Post) => self.logout(req).await,
            (path, method) => Err(route_not_found(method_name(method), path)),
        };
        match routed {
            Ok(response) => Answer {
                response,
                error: None,
            },
            Err(error) => Answer {
                response: error_response(&error, &req.request_id),
                error: Some(error),
            },
        }
    }

    async fn session(&self, req: &WebRequest) -> Result<WebResponse, RegistryError> {
        let session = self.auth.session(req).await?;
        let body = serde_json::json!({
            "login": session.user.handle,
            "csrf": csrf_value(&session.secret),
            "expires_at": session.token.expires_at,
        });
        Ok(WebResponse::json(200, &body, &req.request_id))
    }

    async fn logout(&self, req: &WebRequest) -> Result<WebResponse, RegistryError> {
        let session = self.auth.session_for_post(req).await?;
        let at = iso_millis(self.auth.clock().now());
        self.auth
            .store()
            .revoke_token(&session.token.hash, &at)
            .await
            .map_err(|fault| internal(&fault))?;
        Ok(WebResponse::empty(204, &req.request_id).with_cookie(clear_session_cookie()))
    }

    /// The runtime's entry: API Gateway's event in, the event response out. An event that is no request, or a
    /// response that is no HTTP, is answered as an error rather than left to the runtime.
    pub async fn handle_event(&self, event: ApiGatewayV2httpRequest) -> ApiGatewayV2httpResponse {
        let request_id = event.request_context.request_id.clone().unwrap_or_default();
        let method = event.request_context.http.method.to_string();
        let path = event.raw_path.clone().unwrap_or_default();
        let answer = match from_apigw(event) {
            Ok(req) => self.answer(&req).await,
            Err(error) => Answer {
                response: error_response(&error, &request_id),
                error: Some(error),
            },
        };
        log_answer(&method, &path, &answer);
        to_apigw(&answer.response).unwrap_or_else(|_| fallback_internal_error(&request_id))
    }
}

/// One log line per answer: what was asked and what was answered, never a cookie, a header or a body.
fn log_answer(method: &str, path: &str, answer: &Answer) {
    let status = answer.response.status;
    match &answer.error {
        None => tracing::info!(method, path, status, "answered"),
        Some(error) => tracing::warn!(
            method,
            path,
            status,
            error_code = error.code.as_str(),
            error_message = error.message.as_str(),
            "refused"
        ),
    }
}
