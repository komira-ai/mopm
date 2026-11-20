//! What a sign-in that does not finish is answered with: `303` to `/tutorial?error=<code>`, the code from a fixed list
//! (`docs/design/tutorial-sign-in.md`, section 1; `completeWebLogin` of `spec/api/openapi-v2.yaml`).

use std::fmt;

/// The error codes the tutorial page explains.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureCode {
    /// GitHub, or the person at GitHub, refused the sign-in.
    AccessDenied,
    /// The GitHub account has no two-factor authentication and the stage requires it.
    TwoFactorRequired,
    /// The login transaction is unknown, used before, expired, or not this browser's.
    LoginExpired,
    /// GitHub or one of our stores did not answer.
    Unavailable,
}

impl FailureCode {
    /// The code as it appears in `?error=` and in the log.
    pub const fn as_str(self) -> &'static str {
        match self {
            FailureCode::AccessDenied => "access_denied",
            FailureCode::TwoFactorRequired => "two_factor_required",
            FailureCode::LoginExpired => "login_expired",
            FailureCode::Unavailable => "unavailable",
        }
    }
}

impl fmt::Display for FailureCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A sign-in that stops: the code the browser gets and `reason`, the check that refused, a fixed text for the log
/// (never a value of the request, of GitHub's answer or of a secret).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: FailureCode,
    pub reason: &'static str,
    /// The GitHub account, once GitHub has said who it is.
    pub github_id: Option<u64>,
}

impl Refusal {
    pub const fn new(code: FailureCode, reason: &'static str) -> Refusal {
        Refusal {
            code,
            reason,
            github_id: None,
        }
    }

    /// The same refusal for the account `id`.
    pub const fn for_account(mut self, id: u64) -> Refusal {
        self.github_id = Some(id);
        self
    }
}
