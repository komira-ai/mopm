//! What a port can fail with: a domain error the registry answers with (`version_exists`, `name_taken`,
//! ...), an infrastructure fault (the store was unreachable, a conditional write was refused for a
//! reason the port does not model), or an outbound HTTP request that got no answer. Callers pass the
//! first on to the client and log the others; a fault becomes `internal_error` at the edge, and the
//! caller of an `HttpClient` decides what no answer means for its route.

use mopm_core::error::RegistryError;
use thiserror::Error;

use crate::http::HttpError;

#[derive(Debug, Error)]
pub enum PortError {
    #[error(transparent)]
    Registry(#[from] RegistryError),
    #[error("infrastructure fault: {0}")]
    Fault(String),
    /// An `HttpClient` request got no answer (no connection, timed out, TLS failed). A non-2xx status is
    /// an answer, never this.
    #[error(transparent)]
    Http(#[from] HttpError),
}

impl PortError {
    pub fn fault(why: impl std::fmt::Display) -> Self {
        PortError::Fault(why.to_string())
    }

    /// The domain error, when it is one.
    pub fn registry(&self) -> Option<&RegistryError> {
        match self {
            PortError::Registry(e) => Some(e),
            PortError::Fault(_) | PortError::Http(_) => None,
        }
    }
}

pub type PortResult<T> = Result<T, PortError>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::HttpFailure;
    use mopm_core::error::{invalid_request, ErrorCode};

    #[test]
    fn a_domain_error_converts_and_is_found_again() {
        let e: PortError = invalid_request("x").into();
        assert_eq!(e.registry().map(|r| r.code), Some(ErrorCode::InvalidRequest));
        assert_eq!(e.to_string(), "invalid_request: The request is not valid: x.");
    }

    #[test]
    fn a_fault_is_not_a_domain_error() {
        let e = PortError::fault("connection reset");
        assert!(e.registry().is_none());
        assert_eq!(e.to_string(), "infrastructure fault: connection reset");
    }

    #[test]
    fn no_http_answer_is_its_own_error_and_not_a_domain_error() {
        let e: PortError = HttpError { failure: HttpFailure::Timeout, detail: "after 8s".to_string() }.into();
        assert!(e.registry().is_none());
        assert_eq!(format!("{e:?}"), r#"Http(HttpError { failure: Timeout, detail: "after 8s" })"#);
        assert_eq!(e.to_string(), "HTTP request got no answer: timed out: after 8s");
    }
}
