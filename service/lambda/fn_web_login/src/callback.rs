//! `GET /api/v2/auth/web/callback?code&state` (or `?error&state`) (`docs/design/tutorial-sign-in.md`, sections 1, 2
//! and 6). The edge check has passed when this runs ([`crate::handler`]).
//!
//! The browser comes back from GitHub with the login cookie. The transaction row is taken once (a second callback
//! with the same cookie, an expired row and an unknown one are all `login_expired`, and a wrong `state` burns the row
//! it was compared against), the code is exchanged with the app's secret and the PKCE verifier, the account is read
//! once with the token and the token is dropped. The account and its user namespace are made as the device login makes
//! them, the browser's earlier session is revoked, and a new session is minted.
//!
//! Every answer but the edge refusal clears the login cookie. A refusal is `303` to `/tutorial?error=<code>` with
//! no session: the codes are those of [`FailureCode`]. Each refusal also says which check refused, for the log only.

use mopm_core::return_to::validate_return_to;
use mopm_core::token::{web_session_fields, TokenSecret, SECRET_BYTES};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{iso_millis, Clock, Rng};
use mopm_ports::http::HttpClient;
use mopm_ports::namespaces::NamespaceStore;
use mopm_ports::types::{TokenKind, TokenRecord};
use mopm_ports::web_login::WebLoginStore;
use mopm_web::cookie::{clear_login_cookie, session_cookie, single, LOGIN_COOKIE, SESSION_COOKIE};
use mopm_web::request::WebRequest;
use mopm_web::response::{Redirect, WebResponse};
use subtle::ConstantTimeEq;

use crate::github::{exchange_code, fetch_account};
use crate::login::{random_bytes, sha256_hex, WebLogin};
use crate::outcome::{FailureCode, Refusal};

/// What the log says of a callback.
pub(crate) struct Completed {
    pub response: WebResponse,
    /// `signed_in`, or the code of the refusal.
    pub outcome: &'static str,
    pub reason: Option<&'static str>,
    pub github_id: Option<u64>,
}

/// A sign-in that finished: whose it is, the session to hand the browser, and where to send it.
struct SignedIn {
    github_id: u64,
    session: TokenSecret,
    return_to: String,
}

fn expired(reason: &'static str) -> Refusal {
    Refusal::new(FailureCode::LoginExpired, reason)
}

fn unavailable(reason: &'static str) -> Refusal {
    Refusal::new(FailureCode::Unavailable, reason)
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
    pub(crate) async fn callback(&self, req: &WebRequest) -> Completed {
        let id = &req.request_id;
        let to = |location: String| {
            WebResponse::redirect(Redirect::SeeOther, &location, id)
                .with_header("referrer-policy", "no-referrer")
                .with_cookie(clear_login_cookie())
        };
        match self.complete(req).await {
            Ok(signed) => {
                let response = to(format!(
                    "{}{}",
                    self.settings.site_origin,
                    validate_return_to(&signed.return_to)
                ))
                .with_cookie(session_cookie(&signed.session));
                Completed {
                    response,
                    outcome: "signed_in",
                    reason: None,
                    github_id: Some(signed.github_id),
                }
            }
            Err(refusal) => {
                let response = to(format!(
                    "{}/tutorial?error={}",
                    self.settings.site_origin, refusal.code
                ));
                Completed {
                    response,
                    outcome: refusal.code.as_str(),
                    reason: Some(refusal.reason),
                    github_id: refusal.github_id,
                }
            }
        }
    }

    async fn complete(&self, req: &WebRequest) -> Result<SignedIn, Refusal> {
        if let Some((_, error)) = req.query.iter().find(|(name, _)| name == "error") {
            return Err(match error.as_str() {
                "access_denied" => {
                    Refusal::new(FailureCode::AccessDenied, "GitHub reported access_denied")
                }
                _ => unavailable("GitHub reported an error"),
            });
        }
        let txn = single(req, LOGIN_COOKIE)
            .map_err(|_| expired("more than one login cookie"))?
            .ok_or(expired("no login cookie"))?;
        let (Some(code), Some(state)) = (req.query_param("code"), req.query_param("state")) else {
            return Err(expired("code or state is missing or repeated"));
        };
        let now = self.clock.now();
        let row = self
            .logins
            .consume(&sha256_hex(txn), now)
            .await
            .map_err(|_| unavailable("the login transaction could not be taken"))?
            .ok_or(expired("no live login transaction"))?;
        if !bool::from(
            sha256_hex(state)
                .as_bytes()
                .ct_eq(row.state_hash.as_bytes()),
        ) {
            return Err(expired("state does not match the login transaction"));
        }
        let token = exchange_code(
            &self.http,
            &self.github,
            &self.app,
            &self.settings.redirect_uri,
            code,
            &row.code_verifier,
        )
        .await?;
        let account = fetch_account(&self.http, &self.github, &token).await?;
        // GitHub's token has done its one job.
        drop(token);
        let github_id = account.id;
        let fail = |refusal: Refusal| refusal.for_account(github_id);
        if self.settings.require_2fa && account.two_factor != Some(true) {
            return Err(fail(Refusal::new(
                FailureCode::TwoFactorRequired,
                "two-factor authentication is off on the account",
            )));
        }

        let iso = iso_millis(now);
        self.auth
            .upsert_user(github_id, &account.login, &iso, account.two_factor)
            .await
            .map_err(|_| fail(unavailable("the user could not be stored")))?;
        // None (the login is reserved, outside the grammar, or another account's) does not stop the login.
        self.namespaces
            .ensure_user_namespace(github_id, &account.login, &iso)
            .await
            .map_err(|_| fail(unavailable("the user namespace could not be stored")))?;

        let session = TokenSecret::mint(&random_bytes::<SECRET_BYTES>(&self.rng));
        let fields = web_session_fields(&session, now)
            .map_err(|_| fail(unavailable("the session's expiry is out of range")))?;
        if let Some(previous) = single(req, SESSION_COOKIE)
            .ok()
            .flatten()
            .and_then(TokenSecret::parse)
        {
            self.auth
                .revoke_token(&previous.hash(), &iso)
                .await
                .map_err(|_| {
                    fail(unavailable(
                        "the browser's earlier session could not be revoked",
                    ))
                })?;
        }
        let record = TokenRecord {
            id: format!("tok_{}", hex::encode(random_bytes::<12>(&self.rng))),
            kind: TokenKind::Session,
            github_id: Some(github_id),
            name: fields.name.to_string(),
            hash: fields.hash,
            prefix: fields.prefix,
            scopes: Vec::new(),
            packages: Vec::new(),
            all_current: false,
            version: None,
            fresh_until: Some(fields.fresh_until),
            created_at: fields.created_at,
            expires_at: fields.expires_at,
            revoked_at: None,
            last_used_at: None,
            issued_to: None,
        };
        self.auth
            .put_token(&record)
            .await
            .map_err(|_| fail(unavailable("the session could not be stored")))?;
        Ok(SignedIn {
            github_id,
            session,
            return_to: row.return_to,
        })
    }
}

#[cfg(test)]
#[path = "callback_tests.rs"]
mod tests;
