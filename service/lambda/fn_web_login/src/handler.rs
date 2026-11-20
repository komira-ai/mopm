//! The function's front: an API Gateway event in, an API Gateway response out, and one log line per request.
//!
//! Every request meets the edge check first ([`mopm_web::edge::EdgeCheck`]): a refusal is the `session_required` envelope
//! (401), whatever the route, and no store is called. Then the route: `GET /api/v2/auth/web/start` and
//! `GET /api/v2/auth/web/callback`. Any other path or method is `invalid_request` (400): `route_not_found` is in no
//! table of the website's routes (`WEB_CATALOGUE`), and a code outside that table would be answered as `internal_error`.
//!
//! The log line says `message` (which route), `request_id`, `outcome` (`redirected`, `signed_in`, or the code of the
//! refusal) and, for a refusal, `reason`, a fixed text naming the check; a callback adds `github_id` once GitHub has said
//! whose account it is. No line holds a secret, a code, a state, a transaction id, a verifier or a token.

use aws_lambda_events::apigw::{ApiGatewayV2httpRequest, ApiGatewayV2httpResponse};
use mopm_core::error::{invalid_request, ErrorCode, RegistryError};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{Clock, Rng};
use mopm_ports::http::HttpClient;
use mopm_ports::namespaces::NamespaceStore;
use mopm_ports::web_login::WebLoginStore;
use mopm_web::apigw::{fallback_internal_error, from_apigw, to_apigw};
use mopm_web::envelope::error_response;
use mopm_web::request::{Method, WebRequest};
use mopm_web::response::WebResponse;

use crate::login::{WebLogin, CALLBACK_PATH, START_PATH};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    Start,
    Callback,
    Unknown,
}

impl Route {
    fn of(req: &WebRequest) -> Route {
        match (&req.method, req.path.as_str()) {
            (Method::Get, START_PATH) => Route::Start,
            (Method::Get, CALLBACK_PATH) => Route::Callback,
            _ => Route::Unknown,
        }
    }

    /// The log line's `message`.
    const fn message(self) -> &'static str {
        match self {
            Route::Start => "web login start",
            Route::Callback => "web login callback",
            Route::Unknown => "web login request",
        }
    }
}

/// The one line of a request.
fn log_outcome(
    route: Route,
    request_id: &str,
    outcome: &str,
    reason: Option<&str>,
    github_id: Option<u64>,
) {
    tracing::info!(request_id = %request_id, outcome, reason, github_id, "{}", route.message());
}

fn refuse(route: Route, request_id: &str, err: &RegistryError, reason: &str) -> WebResponse {
    log_outcome(route, request_id, err.code.as_str(), Some(reason), None);
    error_response(err, request_id)
}

impl<A, N, W, H, C, R> WebLogin<A, N, W, H, C, R>
where
    A: AuthStore,
    N: NamespaceStore,
    W: WebLoginStore,
    H: HttpClient,
    C: Clock,
    R: Rng,
{
    /// The answer to `req`, with its log line written.
    pub async fn handle(&self, req: &WebRequest) -> WebResponse {
        let route = Route::of(req);
        if let Err(err) = self.edge.check(req) {
            return refuse(route, &req.request_id, &err, &err.message);
        }
        match route {
            Route::Start => {
                let done = self.start(req).await;
                log_outcome(route, &req.request_id, done.outcome, done.reason, None);
                done.response
            }
            Route::Callback => {
                let done = self.callback(req).await;
                log_outcome(
                    route,
                    &req.request_id,
                    done.outcome,
                    done.reason,
                    done.github_id,
                );
                done.response
            }
            Route::Unknown => refuse(
                route,
                &req.request_id,
                &invalid_request("no such route"),
                "no such route",
            ),
        }
    }

    /// The API Gateway response to `event`. A body that is not valid base64 is `invalid_request`; a response HTTP cannot
    /// carry (a request id that is not a header value) is the fixed `internal_error`.
    pub async fn handle_event(&self, event: ApiGatewayV2httpRequest) -> ApiGatewayV2httpResponse {
        let request_id = event.request_context.request_id.clone().unwrap_or_default();
        let response = match from_apigw(event) {
            Ok(req) => self.handle(&req).await,
            Err(err) => refuse(
                Route::Unknown,
                &request_id,
                &err,
                "the event is not a valid request",
            ),
        };
        to_apigw(&response).unwrap_or_else(|_| {
            tracing::error!(request_id = %request_id, outcome = ErrorCode::InternalError.as_str(), "the response is not valid HTTP");
            fallback_internal_error(&request_id)
        })
    }
}

#[cfg(test)]
#[path = "handler_tests.rs"]
mod tests;
