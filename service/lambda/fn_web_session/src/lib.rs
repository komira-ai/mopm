//! fn_web_session: the website's `web-session` function (docs/design/tutorial-sign-in.md, sections 2, 2.1 and 5). It
//! answers two routes of API Gateway's HTTP API and nothing else:
//!
//! * `GET /api/v2/auth/web/session`: who the browser is signed in as;
//! * `POST /api/v2/auth/web/logout`: revokes the session the cookie names and clears the cookie.
//!
//! The pieces:
//!
//! * [`handler`]: [`WebSessionHandler`], the two routes over `mopm_web`'s [`mopm_web::SessionAuth`], and the event
//!   entry that puts every answer through `mopm_web::apigw`;
//! * [`startup`]: the cold start, from the function's name to a handler, generic over the config table, the secret
//!   reader, the auth store and the clock;
//! * [`clock`]: the system clock;
//! * [`runtime`]: the wiring to the AWS SDK and `lambda_runtime`; the executable (`src/main.rs`) only calls
//!   [`runtime::main`].

pub mod clock;
pub mod handler;
pub mod runtime;
pub mod startup;

pub use clock::SystemClock;
pub use handler::{Answer, WebSessionHandler, LOGOUT_PATH, SESSION_PATH};
pub use startup::cold_start;

#[cfg(test)]
mod flow_tests;
#[cfg(test)]
mod handler_tests;
#[cfg(test)]
mod startup_tests;
#[cfg(test)]
mod test_support;
