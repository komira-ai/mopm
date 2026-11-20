//! The errors of the website's routes and how they are answered: `{"error": {"code", "message", "hint"}}`
//! with `x-mopm-request-id`, the status of the code, and `Retry-After` when the error has one. The texts come
//! from `mopm_core`'s [`WEB_CATALOGUE`] (`x-mopm-errors` of spec/api/openapi-v2.yaml); a code that table lacks is
//! answered as `internal_error`. An error's `message` is for logs: it says which check refused, which the
//! client is not told.

use mopm_core::error::{invalid_request, Detail, ErrorCode, RegistryError, Template, WEB_CATALOGUE};
use mopm_ports::error::PortError;

use crate::response::{WebResponse, CONTENT_TYPE, JSON};

/// `session_required` (401): no usable session cookie, or the request did not come through the site's
/// distribution. `why` names the check, for the log.
pub fn session_required(why: &str) -> RegistryError {
    RegistryError::new(ErrorCode::SessionRequired, format!("not signed in: {why}"), Detail::new())
}

/// `csrf_failed` (403): a cookie-authenticated `POST` failed a CSRF check. `why` names the check, for the log.
pub fn csrf_failed(why: &str) -> RegistryError {
    RegistryError::new(ErrorCode::CsrfFailed, format!("CSRF check failed: {why}"), Detail::new())
}

/// `invalid_request` for an `Authorization` header: the website's routes take the cookie only and never
/// combine it with a bearer token. The detail is the contract's (tests/contract/api-v2).
pub fn authorization_refused() -> RegistryError {
    invalid_request("the website's routes take no Authorization header")
}

/// `tutorial_unavailable` (503) with `Retry-After: retry_after` seconds. `why` says what E2B did, for the log.
pub fn tutorial_unavailable(retry_after: u64, why: &str) -> RegistryError {
    let seconds = retry_after.to_string();
    let mut e = RegistryError::new(ErrorCode::TutorialUnavailable, format!("sandbox service unavailable: {why}"), Detail::from([("retry_after".to_string(), seconds)]));
    e.retry_after = Some(retry_after);
    e
}

/// `internal_error` (500) for a port that failed: the fault goes to the log, the client gets the template.
pub fn internal(fault: &PortError) -> RegistryError {
    RegistryError::new(ErrorCode::InternalError, format!("internal: {fault}"), Detail::new())
}

fn template(code: ErrorCode) -> Option<Template> {
    WEB_CATALOGUE.iter().find(|(c, _)| *c == code).map(|(_, t)| *t)
}

/// A JSON string literal of `s`.
fn json_string(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

/// The answer to `err` for the request `request_id`. A code outside [`WEB_CATALOGUE`] is `internal_error`
/// (500) with no detail; `Retry-After` is sent only for a code that keeps its own template.
pub fn error_response(err: &RegistryError, request_id: &str) -> WebResponse {
    let (code, t, detail, retry_after) = match template(err.code) {
        Some(t) => (err.code, t, &err.detail, err.retry_after),
        None => (ErrorCode::InternalError, INTERNAL, &Detail::new(), None),
    };
    let body = format!(
        r#"{{"error":{{"code":{},"message":{},"hint":{}}}}}"#,
        json_string(code.as_str()),
        json_string(&mopm_core::error::render(t.message, detail)),
        json_string(&mopm_core::error::render(t.hint, detail)),
    );
    let response = WebResponse::empty(code.status(), request_id).with_header(CONTENT_TYPE, JSON).with_body(body);
    match retry_after {
        Some(s) => response.with_header("retry-after", &s.to_string()),
        None => response,
    }
}

/// `internal_error`'s template: [`WEB_CATALOGUE`]'s (a test holds the two equal), written here so the fallback
/// needs no lookup.
const INTERNAL: Template = Template { message: "Something went wrong on our side.", hint: "Try again; report the request id if it persists." };

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(r: &WebResponse) -> Vec<(&str, &str)> {
        r.headers.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect()
    }

    #[test]
    fn session_required_is_401_with_the_contracts_texts() {
        let r = error_response(&session_required("no session cookie"), "req-1");
        assert_eq!(r.status, 401);
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "req-1"), ("cache-control", "no-store"), ("content-type", "application/json")]);
        assert_eq!(r.body, r#"{"error":{"code":"session_required","message":"You are not signed in to the website.","hint":"Sign in with GitHub, then try again."}}"#);
        assert!(r.set_cookies.is_empty());
    }

    #[test]
    fn csrf_failed_is_403_with_the_contracts_texts() {
        let r = error_response(&csrf_failed("Origin"), "req-1");
        assert_eq!(r.status, 403);
        assert_eq!(r.body, r#"{"error":{"code":"csrf_failed","message":"The request did not come from a page of the website.","hint":"Reload the page and try again."}}"#);
    }

    #[test]
    fn an_authorization_header_is_invalid_request_400() {
        let r = error_response(&authorization_refused(), "req-1");
        assert_eq!(r.status, 400);
        assert_eq!(
            r.body,
            r#"{"error":{"code":"invalid_request","message":"The request is not valid: the website's routes take no Authorization header.","hint":"Check the request against the API documentation; update mopm if it is old."}}"#
        );
    }

    #[test]
    fn tutorial_unavailable_is_503_with_retry_after_in_the_header_and_the_hint() {
        let e = tutorial_unavailable(30, "E2B answered 429");
        assert_eq!(e.message, "sandbox service unavailable: E2B answered 429");
        let r = error_response(&e, "req-1");
        assert_eq!(r.status, 503);
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "req-1"), ("cache-control", "no-store"), ("content-type", "application/json"), ("retry-after", "30")]);
        assert_eq!(
            r.body,
            r#"{"error":{"code":"tutorial_unavailable","message":"The sandbox service did not answer.","hint":"Wait 30 seconds and try again; the Retry-After header says how long."}}"#
        );
    }

    #[test]
    fn a_port_fault_is_internal_error_500_and_its_text_stays_in_the_log() {
        let e = internal(&PortError::fault("connection reset"));
        assert_eq!(e.code, ErrorCode::InternalError);
        assert_eq!(e.message, "internal: infrastructure fault: connection reset");
        let r = error_response(&e, "req-9");
        assert_eq!(r.status, 500);
        assert_eq!(r.body, r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#);
        assert!(!r.body.contains("connection reset"));
    }

    #[test]
    fn a_code_outside_the_web_table_is_internal_error_without_its_detail_or_retry_after() {
        let mut e = RegistryError::new(ErrorCode::RateLimited, "slow down", Detail::from([("retry_after".to_string(), "9".to_string())]));
        e.retry_after = Some(9);
        let r = error_response(&e, "req-2");
        assert_eq!(r.status, 500);
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "req-2"), ("cache-control", "no-store"), ("content-type", "application/json")]);
        assert_eq!(r.body, r#"{"error":{"code":"internal_error","message":"Something went wrong on our side.","hint":"Try again; report the request id if it persists."}}"#);
    }

    #[test]
    fn the_fallback_template_is_the_web_tables_internal_error() {
        assert_eq!(template(ErrorCode::InternalError), Some(INTERNAL));
    }

    #[test]
    fn a_message_is_escaped_as_json() {
        let r = error_response(&invalid_request("a \"quoted\" \\ value\n"), "r");
        let v: serde_json::Value = serde_json::from_str(&r.body).unwrap();
        assert_eq!(v["error"]["message"], "The request is not valid: a \"quoted\" \\ value\n.");
    }

    #[test]
    fn the_log_messages_name_the_check() {
        assert_eq!(session_required("two session cookies").message, "not signed in: two session cookies");
        assert_eq!(csrf_failed("Sec-Fetch-Site").message, "CSRF check failed: Sec-Fetch-Site");
    }

    /// The error this crate makes for a contract example's `code` and `message`; `None` for a code it never makes.
    fn ours(code: &str, message: &str) -> Option<RegistryError> {
        match code {
            "session_required" => Some(session_required("x")),
            "csrf_failed" => Some(csrf_failed("x")),
            "tutorial_unavailable" => Some(tutorial_unavailable(30, "x")),
            "invalid_request" if message.contains("Authorization") => Some(authorization_refused()),
            "invalid_request" => Some(invalid_request("the request takes no body")),
            _ => None,
        }
    }

    /// Every error the website's contract examples show (tests/contract/api-v2/web-auth.json and
    /// tutorial-sandbox.json, the valid cases) is what this module answers for its code: status, texts and
    /// `retry-after`.
    #[test]
    fn every_error_of_the_contract_examples_is_answered_byte_for_byte() {
        let files = [include_str!("../../../../tests/contract/api-v2/web-auth.json"), include_str!("../../../../tests/contract/api-v2/tutorial-sandbox.json")];
        let mut seen = 0;
        for file in files {
            let doc: serde_json::Value = serde_json::from_str(file).unwrap();
            for case in doc["cases"].as_array().unwrap() {
                let resp = &case["response"];
                if case.get("expect").is_some() || resp["body"].get("error").is_none() {
                    continue;
                }
                let err = &resp["body"]["error"];
                let ours = ours(err["code"].as_str().unwrap(), err["message"].as_str().unwrap());
                assert!(ours.is_some(), "an error code this crate does not make: {}", err["code"]);
                let r = error_response(&ours.unwrap(), resp["headers"]["x-mopm-request-id"].as_str().unwrap());
                assert_eq!(u64::from(r.status), resp["status"].as_u64().unwrap(), "{}", case["name"]);
                let body: serde_json::Value = serde_json::from_str(&r.body).unwrap();
                assert_eq!(body, resp["body"], "{}", case["name"]);
                for (name, value) in resp["headers"].as_object().unwrap() {
                    assert_eq!(r.header(name), value.as_str(), "{}: {name}", case["name"]);
                }
                seen += 1;
            }
        }
        assert!(ours("rate_limited", "").is_none());
        assert_eq!(seen, 9);
    }
}
