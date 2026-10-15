//! The registry's error codes, their statuses, the message and hint templates the three
//! families of routes answer with, and the one error type the core raises.
//!
//! The TypeScript registry has three error classes (`RegistryError`, `AuthError`,
//! `PublishError`) and three template tables (`CATALOGUE`, `AUTH_CATALOGUE`,
//! `PUBLISH_CATALOGUE`); the codes are one namespace, the texts are the contract's
//! (`x-mopm-errors` in spec/api/openapi.yaml), and a code's status is the same in every
//! table. Here: one [`ErrorCode`], one [`RegistryError`], and the same three tables
//! because the routes differ in which codes they can answer with (an unknown code is
//! `internal_error`, and which codes are unknown depends on the table).

use std::collections::BTreeMap;

use thiserror::Error;

/// The values a message template names: `{name}`, `{version}`, `{detail}`, ...
pub type Detail = BTreeMap<String, String>;

macro_rules! error_codes {
    ($($variant:ident => ($text:literal, $status:literal)),+ $(,)?) => {
        /// A stable error code of the API.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum ErrorCode { $($variant),+ }

        impl ErrorCode {
            /// Every code, in declaration order.
            pub const ALL: &'static [ErrorCode] = &[$(ErrorCode::$variant),+];

            /// The code as it appears in a response body.
            pub const fn as_str(self) -> &'static str {
                match self { $(ErrorCode::$variant => $text),+ }
            }

            /// The HTTP status the code is answered with.
            pub const fn status(self) -> u16 {
                match self { $(ErrorCode::$variant => $status),+ }
            }

            /// The code named `s`, if there is one.
            pub fn parse(s: &str) -> Option<ErrorCode> {
                match s { $($text => Some(ErrorCode::$variant),)+ _ => None }
            }
        }
    };
}

error_codes! {
    InvalidRequest => ("invalid_request", 400),
    InvalidName => ("invalid_name", 400),
    InvalidVersion => ("invalid_version", 400),
    UploadInvalid => ("upload_invalid", 400),
    TokenMissing => ("token_missing", 401),
    TokenUnknown => ("token_unknown", 401),
    TokenExpired => ("token_expired", 401),
    TokenRevoked => ("token_revoked", 401),
    StaleSession => ("stale_session", 401),
    OidcTokenInvalid => ("oidc_token_invalid", 401),
    ScopeMissing => ("scope_missing", 403),
    NotOwner => ("not_owner", 403),
    OidcNotTrusted => ("oidc_not_trusted", 403),
    LimitExceeded => ("limit_exceeded", 403),
    PackageNotFound => ("package_not_found", 404),
    VersionNotFound => ("version_not_found", 404),
    OwnerNotFound => ("owner_not_found", 404),
    PublishNotFound => ("publish_not_found", 404),
    DeviceCodeUnknown => ("device_code_unknown", 404),
    TokenNotFound => ("token_not_found", 404),
    RouteNotFound => ("route_not_found", 404),
    VersionExists => ("version_exists", 409),
    InvalidTransition => ("invalid_transition", 409),
    NameTaken => ("name_taken", 409),
    AlreadyOwner => ("already_owner", 409),
    UploadUsed => ("upload_used", 409),
    PayloadTooLarge => ("payload_too_large", 413),
    RateLimited => ("rate_limited", 429),
    InternalError => ("internal_error", 500),
    ReadOnlyMode => ("read_only_mode", 503),
    Unavailable => ("unavailable", 503),
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An error with a stable code, the message the code was raised with, and the values
/// of its template. The text a client sees comes from the template tables, not from
/// `message` (which is for logs and tests).
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[error("{code}: {message}")]
pub struct RegistryError {
    pub code: ErrorCode,
    pub message: String,
    pub detail: Detail,
    /// Seconds, for `rate_limited` (the `Retry-After` header).
    pub retry_after: Option<u64>,
}

impl RegistryError {
    pub fn new(code: ErrorCode, message: impl Into<String>, detail: Detail) -> Self {
        RegistryError { code, message: message.into(), detail, retry_after: None }
    }

    /// The HTTP status of the code.
    pub fn status(&self) -> u16 {
        self.code.status()
    }
}

fn detail<const N: usize>(pairs: [(&str, &str); N]) -> Detail {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

pub fn invalid_request(why: &str) -> RegistryError {
    RegistryError::new(ErrorCode::InvalidRequest, format!("The request is not valid: {why}."), detail([("detail", why)]))
}

pub fn upload_invalid(why: &str) -> RegistryError {
    RegistryError::new(ErrorCode::UploadInvalid, format!("The upload does not match what was declared: {why}."), detail([("detail", why)]))
}

pub fn oidc_invalid(why: &str) -> RegistryError {
    RegistryError::new(ErrorCode::OidcTokenInvalid, format!("The CI identity token was rejected: {why}."), detail([("detail", why)]))
}

pub fn version_exists(name: &str, version: &str, sha256: &str) -> RegistryError {
    RegistryError::new(
        ErrorCode::VersionExists,
        format!("'{name}' {version} already exists (sha256 {sha256}); versions are immutable."),
        detail([("name", name), ("version", version), ("sha256", sha256)]),
    )
}

pub(crate) fn invalid_version(input: &str) -> RegistryError {
    RegistryError::new(ErrorCode::InvalidVersion, format!("'{input}' is not a valid version."), detail([("version", input)]))
}

// ---- the template tables ------------------------------------------------------------

/// A message and a hint, with `{name}` placeholders.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Template {
    pub message: &'static str,
    pub hint: &'static str,
}

const INVALID_VERSION: Template = Template {
    message: "'{version}' is not a valid version.",
    hint: "A version is MAJOR.MINOR.PATCH: three numbers separated by dots, such as 1.2.3. Suffixes such as rc1 are not supported.",
};

/// The templates of the codes the read API answers with (`CATALOGUE`).
pub const READ_CATALOGUE: &[(ErrorCode, Template)] = &[
    (ErrorCode::InvalidRequest, Template { message: "The request is not valid: {detail}.", hint: "Check the request against the API documentation; update mopm if it is old." }),
    (ErrorCode::InvalidName, Template { message: "'{name}' is not a valid package name.", hint: "Names are lowercase letters, digits and underscores, 2 to 64 characters, starting with a letter." }),
    (ErrorCode::InvalidVersion, INVALID_VERSION),
    (ErrorCode::PackageNotFound, Template { message: "There is no package '{name}'.", hint: "Check the spelling, or claim the name." }),
    (ErrorCode::VersionNotFound, Template { message: "'{name}' has no version '{version}'.", hint: "List the versions with 'mopm info {name}'." }),
    (ErrorCode::InternalError, Template { message: "Something went wrong on our side.", hint: "Try again; report the request id if it persists." }),
    (ErrorCode::Unavailable, Template { message: "The registry is temporarily unavailable.", hint: "Try again shortly." }),
    (ErrorCode::RouteNotFound, Template { message: "There is no such operation.", hint: "Check the request against the API documentation; update mopm if it is old." }),
];

/// The templates of the codes only the auth routes answer with (`AUTH_CATALOGUE`; its
/// `invalid_version` is the read one's).
pub const AUTH_CATALOGUE: &[(ErrorCode, Template)] = &[
    (ErrorCode::InvalidVersion, INVALID_VERSION),
    (ErrorCode::TokenMissing, Template { message: "This request needs a token.", hint: "Run 'mopm login' or pass a token." }),
    (ErrorCode::TokenUnknown, Template { message: "The token is not recognised.", hint: "Create a new token with 'mopm token create', or run 'mopm login'." }),
    (ErrorCode::TokenExpired, Template { message: "The token expired at {expires_at}.", hint: "Create a new token." }),
    (ErrorCode::TokenRevoked, Template { message: "The token was revoked.", hint: "Create a new token." }),
    (ErrorCode::StaleSession, Template { message: "This action needs a login from the last 15 minutes.", hint: "Run 'mopm login' again." }),
    (ErrorCode::OidcTokenInvalid, Template { message: "The CI identity token was rejected: {detail}.", hint: "Check the audience and that the job has permission to request an identity token." }),
    (ErrorCode::ScopeMissing, Template { message: "The token does not have the '{scope}' scope for '{name}'.", hint: "Create a token with that scope and that package." }),
    (ErrorCode::NotOwner, Template { message: "You are not an owner of '{name}'.", hint: "Ask an owner to invite you." }),
    (ErrorCode::OidcNotTrusted, Template { message: "No trusted publisher of '{name}' matches this CI identity.", hint: "Register the repository, workflow and environment as a trusted publisher of the package." }),
    (ErrorCode::DeviceCodeUnknown, Template { message: "The device code is not recognised.", hint: "Start the login again." }),
    (ErrorCode::TokenNotFound, Template { message: "There is no such token.", hint: "List yours with 'mopm token list'." }),
];

/// The templates of every code the publish routes can answer with (`PUBLISH_CATALOGUE`).
/// A code not in this table is answered as `internal_error`, whatever raised it.
pub const PUBLISH_CATALOGUE: &[(ErrorCode, Template)] = &[
    (ErrorCode::InvalidRequest, Template { message: "The request is not valid: {detail}.", hint: "Check the request against the API documentation; update mopm if it is old." }),
    (ErrorCode::InvalidName, Template { message: "'{name}' is not a valid package name.", hint: "Names are lowercase letters, digits and underscores, 2 to 64 characters, starting with a letter." }),
    (ErrorCode::InvalidVersion, INVALID_VERSION),
    (ErrorCode::UploadInvalid, Template { message: "The upload does not match what was declared: {detail}.", hint: "Begin a new upload with the real file name, sha256 and size." }),
    (ErrorCode::TokenMissing, Template { message: "This request needs a token.", hint: "Run 'mopm login' or pass a token." }),
    (ErrorCode::TokenUnknown, Template { message: "The token is not recognised.", hint: "Create a new token with 'mopm token create', or run 'mopm login'." }),
    (ErrorCode::TokenExpired, Template { message: "The token expired at {expires_at}.", hint: "Create a new token." }),
    (ErrorCode::TokenRevoked, Template { message: "The token was revoked.", hint: "Create a new token." }),
    (ErrorCode::ScopeMissing, Template { message: "The token does not have the '{scope}' scope for '{name}'.", hint: "Create a token with that scope and that package." }),
    (ErrorCode::NotOwner, Template { message: "You are not an owner of '{name}'.", hint: "Ask an owner to invite you." }),
    (ErrorCode::LimitExceeded, Template { message: "Adding this file would put '{name}' over its storage limit of {limit} bytes; {remaining} bytes are left.", hint: "Yanked versions still count toward the limit; only a takedown frees space. Reduce the package size." }),
    (ErrorCode::PackageNotFound, Template { message: "There is no package '{name}'.", hint: "Check the spelling, or claim the name." }),
    (ErrorCode::VersionNotFound, Template { message: "'{name}' has no version '{version}'.", hint: "List the versions with 'mopm info {name}'." }),
    (ErrorCode::PublishNotFound, Template { message: "There is no such publish.", hint: "Publish ids are only valid for the caller who made them." }),
    (ErrorCode::VersionExists, Template { message: "'{name}' {version} already exists (sha256 {sha256}); versions are immutable.", hint: "Publish a new version." }),
    (ErrorCode::InvalidTransition, Template { message: "Cannot {action} '{name}' {version}: it is {state}.", hint: "Only a published version can be yanked, only a yanked version can be unyanked, and a tombstoned version never changes." }),
    (ErrorCode::UploadUsed, Template { message: "The upload '{upload_id}' was already used.", hint: "Begin a new upload." }),
    (ErrorCode::PayloadTooLarge, Template { message: "The file is larger than the limit of {limit} bytes.", hint: "Reduce the package size." }),
    (ErrorCode::RateLimited, Template { message: "Too many requests.", hint: "Wait {retry_after} seconds; the Retry-After header says how long." }),
    (ErrorCode::InternalError, Template { message: "Something went wrong on our side.", hint: "Try again; report the request id if it persists." }),
    (ErrorCode::ReadOnlyMode, Template { message: "The registry is read-only right now; new uploads are refused.", hint: "Installs still work. Try again later." }),
    (ErrorCode::Unavailable, Template { message: "The registry is temporarily unavailable.", hint: "Try again shortly." }),
];

fn lookup(table: &'static [(ErrorCode, Template)], code: ErrorCode) -> Option<Template> {
    table.iter().find(|(c, _)| *c == code).map(|(_, t)| *t)
}

/// The template of `code` for the read and auth routes (`templateFor`: the read table, then the auth one).
pub fn read_auth_template(code: ErrorCode) -> Option<Template> {
    lookup(READ_CATALOGUE, code).or_else(|| lookup(AUTH_CATALOGUE, code))
}

/// The template of `code` for the publish routes.
pub fn publish_template(code: ErrorCode) -> Option<Template> {
    lookup(PUBLISH_CATALOGUE, code)
}

/// Replaces `{word}` (one or more of `[A-Za-z0-9_]`) by its value in `detail`, or by nothing
/// when `detail` lacks it. Text that is not a complete placeholder is left as it is, and a
/// substituted value is not scanned again.
pub fn render(template: &str, detail: &Detail) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let word_len = after.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
        if word_len > 0 && after.as_bytes().get(word_len) == Some(&b'}') {
            if let Some(v) = detail.get(&after[..word_len]) {
                out.push_str(v);
            }
            rest = &after[word_len + 1..];
        } else {
            out.push('{');
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// The `error` object of a response body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ErrorBody {
    pub code: &'static str,
    pub message: String,
    pub hint: String,
}

/// What a route answers for an error: the status, the body, and `Retry-After` when there is one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ErrorView {
    pub status: u16,
    pub body: ErrorBody,
    pub retry_after: Option<u64>,
}

fn view(code: ErrorCode, t: Template, status: u16, detail: &Detail, retry_after: Option<u64>) -> ErrorView {
    ErrorView {
        status,
        body: ErrorBody { code: code.as_str(), message: render(t.message, detail), hint: render(t.hint, detail) },
        retry_after,
    }
}

/// `internal_error` as the publish routes answer it (an error nobody classified).
pub fn internal_error_view() -> ErrorView {
    let t = publish_template(ErrorCode::InternalError).expect("the publish table holds internal_error");
    view(ErrorCode::InternalError, t, 500, &Detail::new(), None)
}

/// The answer of the publish routes (`errorView`): the status and texts come from the publish table; a
/// code it lacks is `internal_error`, with no detail.
pub fn publish_error_view(err: &RegistryError) -> ErrorView {
    match publish_template(err.code) {
        Some(t) => view(err.code, t, err.status(), &err.detail, err.retry_after),
        None => internal_error_view(),
    }
}

/// The answer of the read and auth routes: the status of the error's own code (its `status`), the texts from
/// `templateFor`; a code without a template is `internal_error` (500).
pub fn read_auth_error_view(err: &RegistryError) -> ErrorView {
    match read_auth_template(err.code) {
        Some(t) => view(err.code, t, err.status(), &err.detail, None),
        None => view(
            ErrorCode::InternalError,
            read_auth_template(ErrorCode::InternalError).expect("the read table holds internal_error"),
            ErrorCode::InternalError.status(),
            &Detail::new(),
            None,
        ),
    }
}
