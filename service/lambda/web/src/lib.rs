//! mopm_web: what the website's three functions (`web-login`, `web-session`, `tutorial-sandbox`;
//! docs/design/tutorial-sign-in.md, sections 2, 2.1 and 5) share. Nothing here routes a request or
//! runs on its own; each function's binary wires these to `lambda_runtime`.
//!
//! * [`request`], [`response`]: a request and a response without the transport ([`WebRequest`],
//!   [`WebResponse`]);
//! * [`apigw`]: the adapter from and to API Gateway's HTTP API event (payload format 2.0);
//! * [`cookie`]: reading `__Host-mopm_session` and `__Host-mopm_login`, and their `Set-Cookie` forms;
//! * [`edge`]: the `x-mopm-edge` check every request passes first;
//! * [`csrf`]: the checks of a cookie-authenticated `POST`;
//! * [`session`]: [`SessionAuth`], the session a cookie names;
//! * [`envelope`]: the website routes' errors and their `{"error": {...}}` answer;
//! * [`settings`]: the stage, from `AWS_LAMBDA_FUNCTION_NAME`, and the `stage_settings` item.

pub mod apigw;
pub mod cookie;
pub mod csrf;
pub mod edge;
pub mod envelope;
pub mod request;
pub mod response;
pub mod session;
pub mod settings;

pub use request::WebRequest;
pub use response::WebResponse;
pub use session::{SessionAuth, WebSession};

#[cfg(test)]
mod test_support;
