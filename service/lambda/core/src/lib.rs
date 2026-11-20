//! mopm_core: the registry's rules that need no storage, no network and no clock, ported from the
//! TypeScript registry (`service/api/src`) with its outputs held byte for byte:
//!
//! * [`version`]: the version grammar and order;
//! * [`types`], [`state`]: the stored records and the state machine of a version;
//! * [`canonical_json`], [`zstd`], [`repodata`]: the channel index, as the same bytes;
//! * [`error`]: the error codes, the message and hint templates, the views of an error;
//! * [`limits`], [`display`]: the validator's caps and the display metadata rules;
//! * [`token`], [`csrf`], [`return_to`]: token secrets, their hash and prefix, the web session's row fields, its CSRF
//!   value, and where a web login may return to.

pub mod canonical_json;
pub mod csrf;
pub mod display;
pub mod error;
pub mod limits;
pub mod rejection;
pub mod repodata;
pub mod return_to;
pub mod state;
pub mod token;
pub mod types;
pub mod version;
pub mod zstd;

#[cfg(test)]
mod error_tests;
#[cfg(test)]
mod fixtures;

/// A clippy warning (`needless_return`) that only `-D warnings` turns into a failure. Reverted by the next commit.
pub fn lint_fixture() -> u32 {
    return 1;
}
