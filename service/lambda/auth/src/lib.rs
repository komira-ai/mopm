//! mopm_auth: who a request is and how a caller becomes someone. Tokens (minting, the API-token routes, the
//! bearer middleware and the four security schemes), device login over GitHub's OAuth device flow, and the
//! exchange of a CI identity token for a publish token. It is the logic of `service/api/src/auth`, written
//! against the ports of `mopm_ports`; the one outbound seam is [`http::HttpClient`].

pub mod device_login;
pub mod github;
pub mod http;
pub mod js;
pub mod oidc;
pub mod system;
pub mod tokens;

#[cfg(test)]
mod device_login_tests;
#[cfg(test)]
mod oidc_tests;
#[cfg(test)]
mod test_keys;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tokens_tests;
