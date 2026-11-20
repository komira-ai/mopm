//! fn_web_login: the website's sign-in function, `web-login` (`docs/design/tutorial-sign-in.md`, sections 1, 2, 2.1, 5
//! and 6). It serves two routes of the API on the site host: `GET /api/v2/auth/web/start` sends the browser to GitHub
//! (OAuth web flow, S256 PKCE) and `GET /api/v2/auth/web/callback` takes it back, makes the account as the device login
//! does, and sets the session cookie.
//!
//! * [`handler`]: an API Gateway event in and out, the edge check, the routes, the log line of each request;
//! * `start`, `callback`: the two routes, over the ports ([`login::WebLogin`] holds them);
//! * [`github`]: the authorize URL, the code exchange and `GET /user`, over `HttpClient`;
//! * [`oauth`]: the OAuth app's secret, read at cold start;
//! * [`outcome`]: the failure codes of the callback;
//! * [`runtime`]: the real clock and randomness, the stage's config table, the cold start, [`run`].
//!
//! `main.rs` forwards to [`run`]. See README.md for what the function decides and what it logs.

mod callback;
pub mod github;
pub mod handler;
pub mod login;
pub mod oauth;
pub mod outcome;
pub mod runtime;
mod start;

pub use login::WebLogin;
pub use runtime::{cold_start, run, App, RunError, StartupError};

#[cfg(test)]
mod test_support;
