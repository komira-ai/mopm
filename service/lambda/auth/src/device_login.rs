//! Device login (`auth/device-login.ts`): the CLI starts a login, the person approves it on GitHub, the CLI
//! polls until it has a session token.
//!
//! GitHub's own device code stays on the server: the CLI gets a code of ours, and only its hash is stored, so a
//! leaked CLI log cannot be polled at GitHub. The GitHub access token is used once, to learn who the person is,
//! and never stored.

use std::sync::Arc;

use mopm_core::error::{invalid_request, ErrorCode, RegistryError};
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{Clock, Rng};
use mopm_ports::error::PortResult;
use mopm_ports::types::{DeviceLoginRecord, TokenKind};
use serde::Serialize;

use crate::github::{GitHubApi, GitHubPoll, GitHubUnavailable};
use crate::js;
use crate::tokens::{error, hash_token, iso_at, is_past, mint_token, new_id, now_ms, unavailable, TokenFields, SESSION_FRESH_MS};

/// The approval page expires in ten minutes (spec), whatever GitHub allows.
pub const DEVICE_LOGIN_TTL_S: u64 = 600;
pub const MIN_POLL_INTERVAL_S: u64 = 5;
const SLOW_DOWN_STEP_S: u64 = 5;

pub struct DeviceLoginConfig {
    /// Refuse a login whose GitHub account does not have two-factor authentication on. Pending the CEO: the
    /// default is ON. It fails closed: if GitHub does not show the field, the login is denied.
    pub require_2fa: bool,
    /// OAuth scope to request. `read:user`; see `github.rs` for what that shows.
    pub github_scope: String,
    pub session_ttl_days: u64,
}

impl Default for DeviceLoginConfig {
    fn default() -> Self {
        DeviceLoginConfig { require_2fa: true, github_scope: "read:user".into(), session_ttl_days: 30 }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct DeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DenyReason {
    GithubDenied,
    TwoFactorRequired,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "lowercase")]
pub enum DevicePoll {
    Pending { interval: u64 },
    Expired,
    Denied { reason: DenyReason },
    Approved { token: String, token_kind: &'static str, expires_at: String, fresh_until: String, handle: String },
}

pub struct DeviceLogin<A, G> {
    store: Arc<A>,
    github: G,
    config: DeviceLoginConfig,
    clock: Arc<dyn Clock>,
    rng: Arc<dyn Rng>,
}

fn device_code_unknown() -> RegistryError {
    error(ErrorCode::DeviceCodeUnknown, "The device code is not recognised.", [])
}

fn github_down(_: GitHubUnavailable) -> RegistryError {
    unavailable()
}

impl<A: AuthStore, G: GitHubApi> DeviceLogin<A, G> {
    pub fn new(store: Arc<A>, github: G, config: DeviceLoginConfig, clock: Arc<dyn Clock>, rng: Arc<dyn Rng>) -> Self {
        DeviceLogin { store, github, config, clock, rng }
    }

    pub async fn start(&self, client: &str) -> PortResult<DeviceStart> {
        if !(1..=80).contains(&js::length(client)) {
            return Err(invalid_request("client must be 1 to 80 characters").into());
        }
        let gh = self.github.start_device_flow(&self.config.github_scope).await.map_err(github_down)?;
        let now = now_ms(self.clock.as_ref());
        let expires_in = gh.expires_in.min(DEVICE_LOGIN_TTL_S);
        let interval = gh.interval.max(MIN_POLL_INTERVAL_S);
        // Our own code goes to the CLI; GitHub's stays here.
        let device_code = format!("{}{}", new_id(self.rng.as_ref(), "dev"), &new_id(self.rng.as_ref(), "x")[2..]);
        self.store
            .put_device_login(&DeviceLoginRecord {
                id: hash_token(&device_code),
                github_device_code: gh.device_code,
                client: client.to_string(),
                created_at: iso_at(now),
                expires_at: iso_at(now + expires_in as i64 * 1000),
                interval,
                last_polled_at: None,
            })
            .await?;
        Ok(DeviceStart { device_code, user_code: gh.user_code, verification_uri: gh.verification_uri, expires_in, interval })
    }

    pub async fn poll(&self, device_code: &str) -> PortResult<DevicePoll> {
        if !(16..=200).contains(&js::length(device_code)) {
            return Err(device_code_unknown().into());
        }
        let id = hash_token(device_code);
        let login = self.store.get_device_login(&id).await?.ok_or_else(device_code_unknown)?;
        let now = now_ms(self.clock.as_ref());
        if is_past(&login.expires_at, now) {
            self.store.delete_device_login(&id).await?;
            return Ok(DevicePoll::Expired);
        }
        // Polling faster than the interval is answered without bothering GitHub, and slows the client down.
        let too_soon = login.last_polled_at.as_deref().and_then(js::parse_ms).is_some_and(|t| now - t < login.interval as i64 * 1000);
        if too_soon {
            let interval = login.interval + SLOW_DOWN_STEP_S;
            self.store.set_device_polled(&id, &iso_at(now), interval).await?;
            return Ok(DevicePoll::Pending { interval });
        }
        self.store.set_device_polled(&id, &iso_at(now), login.interval).await?;

        let access_token = match self.github.poll_device_flow(&login.github_device_code).await.map_err(github_down)? {
            GitHubPoll::Pending => return Ok(DevicePoll::Pending { interval: login.interval }),
            GitHubPoll::SlowDown { interval } => {
                let interval = interval.unwrap_or(0).max(login.interval + SLOW_DOWN_STEP_S);
                self.store.set_device_polled(&id, &iso_at(now), interval).await?;
                return Ok(DevicePoll::Pending { interval });
            }
            GitHubPoll::Denied => {
                self.store.delete_device_login(&id).await?;
                return Ok(DevicePoll::Denied { reason: DenyReason::GithubDenied });
            }
            GitHubPoll::Expired => {
                self.store.delete_device_login(&id).await?;
                return Ok(DevicePoll::Expired);
            }
            GitHubPoll::Ok { access_token } => access_token,
        };

        let gh = self.github.get_user(&access_token).await.map_err(github_down)?;
        // The GitHub token has done its job; it is never stored.
        self.store.delete_device_login(&id).await?;
        if self.config.require_2fa && gh.two_factor != Some(true) {
            return Ok(DevicePoll::Denied { reason: DenyReason::TwoFactorRequired });
        }
        let iso = iso_at(now);
        let user = self.store.upsert_user(gh.id, &gh.login, &iso, gh.two_factor).await?;
        let m = mint_token(
            self.store.as_ref(),
            self.rng.as_ref(),
            TokenFields {
                kind: TokenKind::Session,
                github_id: Some(user.github_id),
                name: format!("login ({})", login.client),
                scopes: vec![],
                packages: vec![],
                all_current: false,
                version: None,
                fresh_until: Some(iso_at(now + SESSION_FRESH_MS)),
                created_at: iso,
                expires_at: iso_at(now + self.config.session_ttl_days as i64 * 86_400_000),
                issued_to: None,
            },
        )
        .await?;
        Ok(DevicePoll::Approved {
            token: m.secret,
            token_kind: "session",
            expires_at: m.record.expires_at,
            fresh_until: m.record.fresh_until.expect("a session token has a fresh_until"),
            handle: user.handle,
        })
    }
}
