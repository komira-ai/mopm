//! The CSRF checks of a cookie-authenticated `POST` (docs/design/tutorial-sign-in.md, section 2). The request
//! must carry:
//!
//! * `Origin` equal to the site's origin (the stage settings' `site_origin`), exactly;
//! * `Sec-Fetch-Site: same-origin`;
//! * `Content-Type: application/json` when it has a body (parameters such as `; charset=utf-8` allowed);
//! * `X-Mopm-CSRF` equal to the session's CSRF value ([`mopm_core::csrf`]), compared in constant time.
//!
//! The checks run in that order, and the first that fails is `csrf_failed` (403). Each needs one field of its
//! name: two fields of one name fail the check. Nothing here reads a store, so [`crate::SessionAuth`] runs these
//! before it looks the session up.

use mopm_core::csrf::csrf_matches;
use mopm_core::error::RegistryError;
use mopm_core::token::TokenSecret;

use crate::envelope::csrf_failed;
use crate::request::WebRequest;

pub const CSRF_HEADER: &str = "x-mopm-csrf";

/// The site's origin, for the `Origin` check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CsrfCheck {
    site_origin: String,
}

/// Whether a `Content-Type` value is `application/json`: its media type, without case, before any parameter.
fn is_json(content_type: &str) -> bool {
    let essence = content_type.split(';').next().unwrap_or_default();
    essence.trim().eq_ignore_ascii_case("application/json")
}

impl CsrfCheck {
    /// The check for the site at `site_origin` (`https://<site>`, as [`crate::settings::StageSettings`] holds it).
    pub fn new(site_origin: &str) -> CsrfCheck {
        CsrfCheck {
            site_origin: site_origin.to_string(),
        }
    }

    /// Admits `req`, a `POST` with the session `session`'s cookie, or names the first check it fails.
    pub fn check(&self, req: &WebRequest, session: &TokenSecret) -> Result<(), RegistryError> {
        if req.headers.get("origin") != Some(self.site_origin.as_str()) {
            return Err(csrf_failed("Origin is not the site's"));
        }
        if req.headers.get("sec-fetch-site") != Some("same-origin") {
            return Err(csrf_failed("Sec-Fetch-Site is not same-origin"));
        }
        if !req.body.is_empty() && !req.headers.get("content-type").is_some_and(is_json) {
            return Err(csrf_failed("a body that is not application/json"));
        }
        match req.headers.get(CSRF_HEADER) {
            Some(v) if csrf_matches(session, v) => Ok(()),
            Some(_) => Err(csrf_failed("X-Mopm-CSRF is not the session's value")),
            None => Err(csrf_failed("no single X-Mopm-CSRF header")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Method;
    use mopm_core::csrf::csrf_value;
    use mopm_core::error::ErrorCode;

    const SITE: &str = "https://mopm.dev";

    fn secret(fill: u8) -> TokenSecret {
        TokenSecret::mint(&[fill; mopm_core::token::SECRET_BYTES])
    }

    /// A `POST` that passes every check, before the edit a test makes.
    fn good() -> WebRequest {
        WebRequest::new(Method::Post, "/api/v2/auth/web/logout", "r")
            .with_header("Origin", SITE)
            .with_header("Sec-Fetch-Site", "same-origin")
            .with_header("X-Mopm-CSRF", &csrf_value(&secret(1)))
    }

    fn without(req: WebRequest, name: &str) -> WebRequest {
        let mut out = WebRequest {
            headers: Default::default(),
            ..req.clone()
        };
        for (n, v) in req
            .headers
            .iter()
            .filter(|(n, _)| !n.eq_ignore_ascii_case(name))
        {
            out.headers.push(n, v);
        }
        out
    }

    fn refusal(req: &WebRequest) -> String {
        let err = CsrfCheck::new(SITE).check(req, &secret(1)).unwrap_err();
        assert_eq!(err.code, ErrorCode::CsrfFailed);
        err.message
    }

    #[test]
    fn a_post_from_the_site_with_the_sessions_value_passes() {
        assert_eq!(CsrfCheck::new(SITE).check(&good(), &secret(1)), Ok(()));
    }

    #[test]
    fn a_bad_origin_is_csrf_failed() {
        for bad in [
            "https://evil.example",
            "https://mopm.dev/",
            "http://mopm.dev",
            "https://MOPM.dev",
            "https://beta.mopm.dev",
            "null",
            "",
        ] {
            let req = without(good(), "origin").with_header("Origin", bad);
            assert_eq!(
                refusal(&req),
                "CSRF check failed: Origin is not the site's",
                "{bad:?}"
            );
        }
        assert_eq!(
            refusal(&without(good(), "origin")),
            "CSRF check failed: Origin is not the site's"
        );
        assert_eq!(
            refusal(&good().with_header("origin", SITE)),
            "CSRF check failed: Origin is not the site's"
        );
    }

    #[test]
    fn a_bad_sec_fetch_site_is_csrf_failed() {
        for bad in ["same-site", "cross-site", "none", "Same-Origin", ""] {
            let req = without(good(), "sec-fetch-site").with_header("Sec-Fetch-Site", bad);
            assert_eq!(
                refusal(&req),
                "CSRF check failed: Sec-Fetch-Site is not same-origin",
                "{bad:?}"
            );
        }
        assert_eq!(
            refusal(&without(good(), "sec-fetch-site")),
            "CSRF check failed: Sec-Fetch-Site is not same-origin"
        );
    }

    #[test]
    fn a_body_that_is_not_json_is_csrf_failed() {
        for bad in [
            "text/plain",
            "application/x-www-form-urlencoded",
            "multipart/form-data; boundary=x",
            "application/jsonx",
            "application/json-seq",
            "",
        ] {
            let req = good().with_body(b"{}").with_header("Content-Type", bad);
            assert_eq!(
                refusal(&req),
                "CSRF check failed: a body that is not application/json",
                "{bad:?}"
            );
        }
        assert_eq!(
            refusal(&good().with_body(b"{}")),
            "CSRF check failed: a body that is not application/json"
        );
    }

    #[test]
    fn a_json_body_passes_with_any_case_and_parameters() {
        for ok in [
            "application/json",
            "Application/JSON",
            "application/json; charset=utf-8",
            " application/json ;x=y",
        ] {
            let req = good().with_body(b"{}").with_header("Content-Type", ok);
            assert_eq!(
                CsrfCheck::new(SITE).check(&req, &secret(1)),
                Ok(()),
                "{ok:?}"
            );
        }
    }

    #[test]
    fn no_body_needs_no_content_type() {
        assert_eq!(
            CsrfCheck::new(SITE).check(
                &good().with_header("Content-Type", "text/plain"),
                &secret(1)
            ),
            Ok(())
        );
    }

    #[test]
    fn a_missing_or_wrong_csrf_value_is_csrf_failed() {
        assert_eq!(
            refusal(&without(good(), "x-mopm-csrf")),
            "CSRF check failed: no single X-Mopm-CSRF header"
        );
        let other =
            without(good(), "x-mopm-csrf").with_header("X-Mopm-CSRF", &csrf_value(&secret(2)));
        assert_eq!(
            refusal(&other),
            "CSRF check failed: X-Mopm-CSRF is not the session's value"
        );
        let empty = without(good(), "x-mopm-csrf").with_header("X-Mopm-CSRF", "");
        assert_eq!(
            refusal(&empty),
            "CSRF check failed: X-Mopm-CSRF is not the session's value"
        );
        let twice = good().with_header("x-mopm-csrf", &csrf_value(&secret(1)));
        assert_eq!(
            refusal(&twice),
            "CSRF check failed: no single X-Mopm-CSRF header"
        );
    }

    #[test]
    fn the_first_failing_check_is_named() {
        let all_bad = WebRequest::new(Method::Post, "/", "r").with_body(b"x");
        assert_eq!(
            refusal(&all_bad),
            "CSRF check failed: Origin is not the site's"
        );
        let origin_ok = all_bad.with_header("Origin", SITE);
        assert_eq!(
            refusal(&origin_ok),
            "CSRF check failed: Sec-Fetch-Site is not same-origin"
        );
        let fetch_ok = origin_ok.with_header("Sec-Fetch-Site", "same-origin");
        assert_eq!(
            refusal(&fetch_ok),
            "CSRF check failed: a body that is not application/json"
        );
        let type_ok = fetch_ok.with_header("Content-Type", "application/json");
        assert_eq!(
            refusal(&type_ok),
            "CSRF check failed: no single X-Mopm-CSRF header"
        );
    }
}
