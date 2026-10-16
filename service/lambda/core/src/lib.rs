//! mopm_core: the registry's rules that need no storage, no network and no clock, ported from the
//! TypeScript registry (`service/api/src`) with its outputs held byte for byte:
//!
//! * [`version`]: the version grammar and order;
//! * [`types`], [`state`]: the stored records and the state machine of a version;
//! * [`canonical_json`], [`zstd`], [`repodata`]: the channel index, as the same bytes;
//! * [`error`]: the error codes, the message and hint templates, the views of an error;
//! * [`limits`], [`display`]: the validator's caps and the display metadata rules.

pub mod canonical_json;
pub mod display;
pub mod error;
pub mod limits;
pub mod repodata;
pub mod state;
pub mod types;
pub mod version;
pub mod zstd;

#[cfg(test)]
mod error_tests;
#[cfg(test)]
mod fixtures;
