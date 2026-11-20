//! [`WebLogin`]: the function's state after cold start, and what its two routes share. The routes are `start.rs` and
//! `callback.rs` and, in front of both, [`crate::handler`].

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use mopm_ports::env::Rng;
use mopm_web::edge::EdgeCheck;
use mopm_web::settings::StageSettings;
use sha2::{Digest, Sha256};

use crate::github::GitHubEndpoints;
use crate::oauth::OAuthApp;

/// The path of the route that starts a sign-in.
pub const START_PATH: &str = "/api/v2/auth/web/start";
/// The path of the route GitHub sends the browser back to.
pub const CALLBACK_PATH: &str = "/api/v2/auth/web/callback";

/// How long a login transaction lives, in seconds: the login cookie's `Max-Age`, and the row's expiry.
pub const LOGIN_SECONDS: i64 = 600;

/// The web sign-in, over its ports: the stores of the account (`auth`, `namespaces`), of the login transaction
/// (`logins`), HTTPS to GitHub (`http`), time and randomness.
pub struct WebLogin<A, N, W, H, C, R> {
    pub settings: StageSettings,
    pub edge: EdgeCheck,
    pub app: OAuthApp,
    pub github: GitHubEndpoints,
    pub auth: A,
    pub namespaces: N,
    pub logins: W,
    pub http: H,
    pub clock: C,
    pub rng: R,
}

/// SHA-256 of `s`, lower-case hex: what the `web_logins` row keeps of the transaction id and of `state`.
pub(crate) fn sha256_hex(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

/// `N` random bytes from `rng`, base64url without padding (32 bytes are 43 characters).
pub(crate) fn random_token<const N: usize>(rng: &impl Rng) -> String {
    URL_SAFE_NO_PAD.encode(random_bytes::<N>(rng))
}

pub(crate) fn random_bytes<const N: usize>(rng: &impl Rng) -> [u8; N] {
    let mut bytes = [0u8; N];
    rng.fill(&mut bytes);
    bytes
}

/// The S256 challenge of a PKCE verifier: base64url without padding of its SHA-256.
pub(crate) fn s256_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}
