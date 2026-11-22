//! The edge-header check (docs/design/tutorial-sign-in.md, section 2.1). The site's CloudFront distribution sends
//! every `/api/*` request to API Gateway with the origin header `x-mopm-edge` set to the stage's secret
//! `mopm/<stage>/edge-origin`, replacing any header of that name the viewer sent. The website's functions refuse
//! every request without the right value, so none of their routes answers a request sent straight to
//! `api.<site>`. It is defence in depth, not the boundary: the `__Host-` cookie never reaches `api.<site>` anyway.
//!
//! A refused request is `session_required` (401). The check runs before anything else, on every route: no
//! request that fails it reads a store. The code is the one the design's tests name for a missing edge header
//! (tu-A1: "a missing edge header [is] 401"), and `session_required` is the website's one 401: a request that did
//! not come through the site cannot be signed in to it, since the cookie is never sent to `api.<site>`. It tells
//! the caller nothing about the header.

use std::fmt;

use mopm_core::error::RegistryError;
use mopm_ports::error::PortResult;
use mopm_ports::secrets::SecretReader;
use subtle::ConstantTimeEq;

use crate::envelope::session_required;
use crate::request::WebRequest;
use crate::settings::{SetupError, Stage};

/// The header CloudFront sets.
pub const EDGE_HEADER: &str = "x-mopm-edge";
/// The name of the stage's secret that holds its value (`mopm/<stage>/edge-origin`).
pub const EDGE_SECRET: &str = "edge-origin";

/// The stage's edge value, read once at cold start.
pub struct EdgeCheck {
    expected: Vec<u8>,
}

impl fmt::Debug for EdgeCheck {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("EdgeCheck(..)")
    }
}

impl EdgeCheck {
    /// Reads `mopm/<stage>/edge-origin` through `secrets`, once. The whole secret string is the value; a missing
    /// or empty secret fails the start.
    pub async fn load(secrets: &impl SecretReader, stage: &Stage) -> Result<EdgeCheck, SetupError> {
        let id = stage.secret_id(EDGE_SECRET);
        let found = secrets.read(&id).await;
        EdgeCheck::from_secret(id, found)
    }

    /// What [`EdgeCheck::load`] makes of the secret `id`'s answer (not generic, so one instantiation covers it).
    fn from_secret(id: String, found: PortResult<Option<String>>) -> Result<EdgeCheck, SetupError> {
        let value = found.map_err(|source| SetupError::Port {
            what: format!("the secret {id}"),
            source,
        })?;
        match value {
            None => Err(SetupError::SecretMissing(id)),
            Some(v) if v.is_empty() => Err(SetupError::SecretEmpty(id)),
            Some(v) => Ok(EdgeCheck {
                expected: v.into_bytes(),
            }),
        }
    }

    /// Admits `req` when it carries exactly one `x-mopm-edge` equal to the stage's value, compared in constant
    /// time. Anything else is `session_required`.
    pub fn check(&self, req: &WebRequest) -> Result<(), RegistryError> {
        let presented = req
            .headers
            .get(EDGE_HEADER)
            .ok_or_else(|| session_required("no single x-mopm-edge header"))?;
        if bool::from(self.expected.ct_eq(presented.as_bytes())) {
            Ok(())
        } else {
            Err(session_required(
                "the x-mopm-edge header is not the stage's value",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Method;
    use crate::settings::parse_function_name;
    use mopm_core::error::ErrorCode;
    use mopm_ports::error::PortError;
    use mopm_testing::memory_publish::MemorySecrets;
    use std::ffi::OsStr;

    fn beta() -> Stage {
        parse_function_name(Some(OsStr::new("mopm-beta-web-session")))
            .unwrap()
            .stage
    }

    async fn loaded(value: &str) -> EdgeCheck {
        let secrets = MemorySecrets::new();
        secrets.set("mopm/beta/edge-origin", value);
        EdgeCheck::load(&secrets, &beta()).await.unwrap()
    }

    fn req() -> WebRequest {
        WebRequest::new(Method::Get, "/api/v2/auth/web/session", "r")
    }

    #[tokio::test]
    async fn the_right_value_is_admitted_under_any_header_case() {
        let edge = loaded("edge-secret-value").await;
        assert_eq!(
            edge.check(&req().with_header("x-mopm-edge", "edge-secret-value")),
            Ok(())
        );
        assert_eq!(
            edge.check(&req().with_header("X-Mopm-Edge", "edge-secret-value")),
            Ok(())
        );
    }

    #[tokio::test]
    async fn a_missing_header_is_session_required() {
        let err = loaded("edge-secret-value").await.check(&req()).unwrap_err();
        assert_eq!(err.code, ErrorCode::SessionRequired);
        assert_eq!(err.message, "not signed in: no single x-mopm-edge header");
    }

    #[tokio::test]
    async fn a_wrong_value_is_session_required() {
        let edge = loaded("edge-secret-value").await;
        for wrong in [
            "",
            "edge-secret-valuE",
            "edge-secret-valu",
            "edge-secret-value ",
            "EDGE-SECRET-VALUE",
        ] {
            let err = edge
                .check(&req().with_header("x-mopm-edge", wrong))
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::SessionRequired, "{wrong:?}");
            assert_eq!(
                err.message, "not signed in: the x-mopm-edge header is not the stage's value",
                "{wrong:?}"
            );
        }
    }

    #[tokio::test]
    async fn two_edge_headers_are_refused_even_if_one_is_right() {
        let edge = loaded("v").await;
        let err = edge
            .check(
                &req()
                    .with_header("x-mopm-edge", "v")
                    .with_header("x-mopm-edge", "v"),
            )
            .unwrap_err();
        assert_eq!(err.message, "not signed in: no single x-mopm-edge header");
    }

    #[tokio::test]
    async fn the_value_is_read_once_and_kept() {
        let secrets = MemorySecrets::new();
        secrets.set("mopm/beta/edge-origin", "first");
        let edge = EdgeCheck::load(&secrets, &beta()).await.unwrap();
        secrets.set("mopm/beta/edge-origin", "second");
        assert_eq!(
            edge.check(&req().with_header("x-mopm-edge", "first")),
            Ok(())
        );
        assert!(edge
            .check(&req().with_header("x-mopm-edge", "second"))
            .is_err());
    }

    #[tokio::test]
    async fn another_stages_secret_is_not_read() {
        let secrets = MemorySecrets::new();
        secrets.set("mopm/prod/edge-origin", "prod-value");
        let err = EdgeCheck::load(&secrets, &beta()).await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "the secret mopm/beta/edge-origin does not exist"
        );
    }

    #[tokio::test]
    async fn an_empty_secret_fails_the_start() {
        let secrets = MemorySecrets::new();
        secrets.set("mopm/beta/edge-origin", "");
        assert_eq!(
            EdgeCheck::load(&secrets, &beta())
                .await
                .unwrap_err()
                .to_string(),
            "the secret mopm/beta/edge-origin is empty"
        );
    }

    struct Failing;

    impl SecretReader for Failing {
        async fn read(&self, _: &str) -> PortResult<Option<String>> {
            Err(PortError::fault("access denied"))
        }
    }

    #[tokio::test]
    async fn a_failing_reader_fails_the_start_naming_the_secret() {
        let err = EdgeCheck::load(&Failing, &beta()).await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "reading the secret mopm/beta/edge-origin: infrastructure fault: access denied"
        );
    }

    #[tokio::test]
    async fn debug_never_shows_the_value() {
        assert_eq!(
            format!("{:?}", loaded("edge-secret-value").await),
            "EdgeCheck(..)"
        );
    }
}
