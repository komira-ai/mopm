//! mopm_ports: the traits the registry's logic is written against, and the records they carry. Nothing
//! here does I/O. `mopm_testing` has the in-memory implementations, `mopm_aws` the ones on the AWS SDK.

pub mod auth;
pub mod env;
pub mod error;
pub mod publish;
pub mod store;
pub mod types;
