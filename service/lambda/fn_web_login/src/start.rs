//! `GET /api/v2/auth/web/start?return_to=` (`docs/design/tutorial-sign-in.md`, section 1). The edge check has passed
//! when this runs ([`crate::handler`]).
//!
//! Only a top-level navigation is taken: exactly one `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` and
//! `Sec-Fetch-Site` of `none` or `same-origin`, each spelled so. Anything else is `invalid_request` (400, the
//! envelope), and nothing is stored. A navigation stores the login transaction and is sent to GitHub, with the login
//! cookie. When the store fails, the browser is sent to `/tutorial?error=unavailable`: it navigated, so it never gets
//! JSON for a fault.

use mopm_core::error::{invalid_request, RegistryError};
use mopm_core::return_to::validate_return_to;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{Clock, Rng};
use mopm_ports::http::HttpClient;
use mopm_ports::namespaces::NamespaceStore;
use mopm_ports::web_login::{WebLoginRecord, WebLoginStore};
use mopm_web::cookie::login_cookie;
use mopm_web::envelope::error_response;
use mopm_web::request::WebRequest;
use mopm_web::response::{Redirect, WebResponse};

use crate::github::authorize_url;
use crate::login::{random_token, s256_challenge, sha256_hex, WebLogin, LOGIN_SECONDS};
use crate::outcome::FailureCode;

/// What the log says of a start: the outcome and, for a refusal, the check that refused.
pub(crate) struct Started {
    pub response: WebResponse,
    pub outcome: &'static str,
    pub reason: Option<&'static str>,
}

/// Whether `req` is a top-level navigation of a browser to this site's own link.
fn is_navigation(req: &WebRequest) -> bool {
    let h = &req.headers;
    h.get("sec-fetch-mode") == Some("navigate")
        && h.get("sec-fetch-dest") == Some("document")
        && matches!(h.get("sec-fetch-site"), Some("none" | "same-origin"))
}

fn refused(req: &WebRequest, err: &RegistryError, reason: &'static str) -> Started {
    Started {
        response: error_response(err, &req.request_id),
        outcome: err.code.as_str(),
        reason: Some(reason),
    }
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
    pub(crate) async fn start(&self, req: &WebRequest) -> Started {
        if !is_navigation(req) {
            return refused(
                req,
                &invalid_request("a sign-in starts from a link of the site"),
                "not a top-level navigation",
            );
        }
        let return_to = validate_return_to(req.query_param("return_to").unwrap_or_default());
        let txn = random_token::<32>(&self.rng);
        let state = random_token::<32>(&self.rng);
        let verifier = random_token::<32>(&self.rng);
        let row = WebLoginRecord {
            id: sha256_hex(&txn),
            state_hash: sha256_hex(&state),
            code_verifier: verifier.clone(),
            return_to,
            expires_at: self.clock.now().as_second() + LOGIN_SECONDS,
            consumed_at: None,
        };
        let id = &req.request_id;
        // A transaction id is base64url, so its cookie is always valid; a store that fails is the one way to no cookie.
        let cookie = self
            .logins
            .put(&row)
            .await
            .ok()
            .and_then(|()| login_cookie(&txn).ok());
        match cookie {
            Some(cookie) => {
                let location = authorize_url(
                    &self.github,
                    &self.app,
                    &self.settings.redirect_uri,
                    &state,
                    &s256_challenge(&verifier),
                );
                Started {
                    response: WebResponse::redirect(Redirect::Found, &location, id)
                        .with_cookie(cookie),
                    outcome: "redirected",
                    reason: None,
                }
            }
            None => {
                let location = format!(
                    "{}/tutorial?error={}",
                    self.settings.site_origin,
                    FailureCode::Unavailable
                );
                Started {
                    response: WebResponse::redirect(Redirect::SeeOther, &location, id),
                    outcome: FailureCode::Unavailable.as_str(),
                    reason: Some("the login transaction was not stored"),
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "start_tests.rs"]
mod tests;
