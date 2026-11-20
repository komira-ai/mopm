//! The adapter between API Gateway's HTTP API (payload format 2.0, `aws_lambda_events::apigw`) and
//! [`WebRequest`] / [`WebResponse`].
//!
//! In: the method of `requestContext.http`, `rawPath`, `rawQueryString` (decoded into pairs), the headers,
//! the cookies (API Gateway moves the `Cookie` header into the event's `cookies` array, one pair per entry;
//! a `cookie` header that is still there is read as well), the body (decoded when `isBase64Encoded`), and
//! `requestContext.requestId`.
//!
//! Out: the status, the headers, `cookies` (API Gateway sends each as its own `Set-Cookie`) and the body as
//! text.

use aws_lambda_events::apigw::{ApiGatewayV2httpRequest, ApiGatewayV2httpResponse};
use aws_lambda_events::encodings::Body;
use aws_lambda_events::http::{HeaderName, HeaderValue};
use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use mopm_core::error::{invalid_request, Detail, ErrorCode, RegistryError};
use thiserror::Error;

use crate::envelope::error_response;
use crate::request::{parse_cookie_header, Method, WebRequest};
use crate::response::{WebResponse, CACHE_CONTROL, CONTENT_TYPE, JSON, NO_STORE, REQUEST_ID};

/// The request of `event`. A body flagged as base64 that does not decode is `invalid_request`.
pub fn from_apigw(event: ApiGatewayV2httpRequest) -> Result<WebRequest, RegistryError> {
    let mut req = WebRequest::new(
        Method::parse(event.request_context.http.method.as_str()),
        event.raw_path.as_deref().unwrap_or_default(),
        event.request_context.request_id.as_deref().unwrap_or_default(),
    );
    req.query = form_urlencoded::parse(event.raw_query_string.as_deref().unwrap_or_default().as_bytes()).into_owned().collect();
    for (name, value) in &event.headers {
        let value = String::from_utf8_lossy(value.as_bytes());
        if name.as_str() == "cookie" {
            req.cookies.extend(parse_cookie_header(&value));
        }
        req.headers.push(name.as_str(), &value);
    }
    for pair in event.cookies.iter().flatten() {
        req.cookies.extend(parse_cookie_header(pair));
    }
    req.body = match event.body {
        None => Vec::new(),
        Some(b) if event.is_base64_encoded => STANDARD.decode(b).map_err(|_| invalid_request("the body is not valid base64"))?,
        Some(b) => b.into_bytes(),
    };
    Ok(req)
}

/// A response header that HTTP cannot carry (a name or value with a character a header cannot hold).
#[derive(Debug, Error, PartialEq, Eq)]
#[error("the response header {name:?} is not valid HTTP")]
pub struct InvalidHeader {
    pub name: String,
}

/// The event response of `resp`.
pub fn to_apigw(resp: &WebResponse) -> Result<ApiGatewayV2httpResponse, InvalidHeader> {
    let mut out = ApiGatewayV2httpResponse::default();
    out.status_code = i64::from(resp.status);
    for (name, value) in &resp.headers {
        let invalid = || InvalidHeader { name: name.clone() };
        let header = HeaderName::from_bytes(name.as_bytes()).map_err(|_| invalid())?;
        out.headers.append(header, HeaderValue::from_str(value).map_err(|_| invalid())?);
    }
    out.cookies = resp.set_cookies.iter().map(|c| c.as_str().to_string()).collect();
    out.body = (!resp.body.is_empty()).then(|| Body::Text(resp.body.clone()));
    Ok(out)
}

/// What a function answers when [`to_apigw`] refuses its response: `internal_error` (500) from fixed values,
/// with `x-mopm-request-id` when `request_id` is a valid header value.
pub fn fallback_internal_error(request_id: &str) -> ApiGatewayV2httpResponse {
    let body = error_response(&RegistryError::new(ErrorCode::InternalError, "", Detail::new()), request_id).body;
    let mut out = ApiGatewayV2httpResponse::default();
    out.status_code = 500;
    if let Ok(id) = HeaderValue::from_str(request_id) {
        out.headers.insert(REQUEST_ID, id);
    }
    out.headers.insert(CACHE_CONTROL, HeaderValue::from_static(NO_STORE));
    out.headers.insert(CONTENT_TYPE, HeaderValue::from_static(JSON));
    out.body = Some(Body::Text(body));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cookie::{clear_session_cookie, session_cookie};
    use crate::request::Cookie;
    use crate::response::Redirect;
    use mopm_core::token::{TokenSecret, SECRET_BYTES};
    use serde_json::json;

    /// An HTTP API event as API Gateway delivers it, with `extra` merged over the defaults.
    fn event(extra: serde_json::Value) -> ApiGatewayV2httpRequest {
        let mut e = json!({
            "version": "2.0",
            "routeKey": "GET /api/v2/auth/web/session",
            "rawPath": "/api/v2/auth/web/session",
            "rawQueryString": "",
            "headers": {"host": "api.mopm.dev", "x-mopm-edge": "edge-value"},
            "requestContext": {
                "accountId": "example",
                "apiId": "api",
                "domainName": "api.mopm.dev",
                "http": {"method": "GET", "path": "/api/v2/auth/web/session", "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "test"},
                "requestId": "req-7f3a2c19d0e4",
                "routeKey": "GET /api/v2/auth/web/session",
                "stage": "$default",
                "timeEpoch": 1_795_000_000_000_i64
            },
            "isBase64Encoded": false
        });
        for (k, v) in extra.as_object().unwrap() {
            e[k] = v.clone();
        }
        serde_json::from_value(e).unwrap()
    }

    fn cookie(name: &str, value: &str) -> Cookie {
        Cookie { name: name.to_string(), value: value.to_string() }
    }

    #[test]
    fn a_get_with_two_cookies_and_a_query_becomes_the_request() {
        let req = from_apigw(event(json!({
            "rawQueryString": "return_to=%2Ftutorial%2Fhello&x=a+b",
            "cookies": ["__Host-mopm_session=mopm_abc", "theme=dark"]
        })))
        .unwrap();
        assert_eq!(req.method, Method::Get);
        assert_eq!(req.path, "/api/v2/auth/web/session");
        assert_eq!(req.query, vec![("return_to".to_string(), "/tutorial/hello".to_string()), ("x".to_string(), "a b".to_string())]);
        assert_eq!(req.cookies, vec![cookie("__Host-mopm_session", "mopm_abc"), cookie("theme", "dark")]);
        assert_eq!(req.headers.get("X-Mopm-Edge"), Some("edge-value"));
        assert_eq!(req.headers.get("host"), Some("api.mopm.dev"));
        assert_eq!(req.request_id, "req-7f3a2c19d0e4");
        assert!(req.body.is_empty());
    }

    #[test]
    fn a_post_with_a_body_becomes_the_request() {
        let req = from_apigw(event(json!({
            "routeKey": "POST /api/v2/auth/web/logout",
            "rawPath": "/api/v2/auth/web/logout",
            "headers": {"origin": "https://mopm.dev", "content-type": "application/json"},
            "requestContext": {"http": {"method": "POST"}, "requestId": "req-2"},
            "body": "{\"a\":1}"
        })))
        .unwrap();
        assert_eq!(req.method, Method::Post);
        assert_eq!(req.path, "/api/v2/auth/web/logout");
        assert_eq!(req.headers.get("Origin"), Some("https://mopm.dev"));
        assert_eq!(req.body, b"{\"a\":1}");
        assert_eq!(req.request_id, "req-2");
        assert!(req.query.is_empty());
        assert!(req.cookies.is_empty());
    }

    #[test]
    fn a_base64_body_is_decoded_and_a_bad_one_is_invalid_request() {
        let req = from_apigw(event(json!({"body": "eyJhIjoxfQ==", "isBase64Encoded": true}))).unwrap();
        assert_eq!(req.body, b"{\"a\":1}");
        let err = from_apigw(event(json!({"body": "not base64!", "isBase64Encoded": true}))).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidRequest);
        assert_eq!(err.message, "The request is not valid: the body is not valid base64.");
    }

    #[test]
    fn a_cookie_header_left_in_the_event_is_read_before_the_cookies_array() {
        let req = from_apigw(event(json!({
            "headers": {"cookie": "a=1; b=2"},
            "cookies": ["c=3"]
        })))
        .unwrap();
        assert_eq!(req.cookies, vec![cookie("a", "1"), cookie("b", "2"), cookie("c", "3")]);
        assert_eq!(req.headers.get("cookie"), Some("a=1; b=2"));
    }

    #[test]
    fn an_event_without_path_query_or_request_id_reads_as_empty() {
        let mut e = event(json!({}));
        e.raw_path = None;
        e.raw_query_string = None;
        e.request_context.request_id = None;
        let req = from_apigw(e).unwrap();
        assert_eq!((req.path.as_str(), req.query.len(), req.request_id.as_str()), ("", 0, ""));
    }

    #[test]
    fn a_header_value_that_is_not_utf8_is_kept_with_replacement_characters() {
        let mut e = event(json!({}));
        e.headers.insert("x-mopm-csrf", HeaderValue::from_bytes(b"a\xffb").unwrap());
        assert_eq!(from_apigw(e).unwrap().headers.get("x-mopm-csrf"), Some("a\u{fffd}b"));
    }

    fn secret() -> TokenSecret {
        TokenSecret::mint(&[0; SECRET_BYTES])
    }

    #[test]
    fn a_json_answer_with_a_cookie_becomes_the_event_response() {
        let resp = WebResponse::json(200, &json!({"login": "alice"}), "req-1").with_cookie(session_cookie(&secret()));
        let out = serde_json::to_value(to_apigw(&resp).unwrap()).unwrap();
        assert_eq!(
            out,
            json!({
                "statusCode": 200,
                "headers": {"x-mopm-request-id": "req-1", "cache-control": "no-store", "content-type": "application/json"},
                "multiValueHeaders": {},
                "body": "{\"login\":\"alice\"}",
                "isBase64Encoded": false,
                "cookies": ["__Host-mopm_session=mopm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=604800"]
            })
        );
    }

    #[test]
    fn an_answer_without_a_body_has_none() {
        let resp = WebResponse::empty(204, "req-1").with_cookie(clear_session_cookie());
        let out = to_apigw(&resp).unwrap();
        assert_eq!(out.status_code, 204);
        assert_eq!(out.body, None);
        assert_eq!(out.cookies, vec!["__Host-mopm_session=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0".to_string()]);
        let redirect = to_apigw(&WebResponse::redirect(Redirect::SeeOther, "https://mopm.dev/tutorial", "r")).unwrap();
        assert_eq!(redirect.headers.get("location").unwrap(), "https://mopm.dev/tutorial");
    }

    #[test]
    fn a_header_http_cannot_carry_is_refused_by_name() {
        let bad_value = WebResponse::redirect(Redirect::Found, "https://x/\r\nset-cookie: a=b", "r");
        assert_eq!(to_apigw(&bad_value).unwrap_err(), InvalidHeader { name: "location".to_string() });
        let bad_name = WebResponse::empty(200, "r").with_header("bad name", "v");
        let err = to_apigw(&bad_name).unwrap_err();
        assert_eq!(err.to_string(), "the response header \"bad name\" is not valid HTTP");
    }

    #[test]
    fn the_fallback_is_internal_error_with_the_request_id() {
        let out = serde_json::to_value(fallback_internal_error("req-9")).unwrap();
        assert_eq!(
            out,
            json!({
                "statusCode": 500,
                "headers": {"x-mopm-request-id": "req-9", "cache-control": "no-store", "content-type": "application/json"},
                "multiValueHeaders": {},
                "body": "{\"error\":{\"code\":\"internal_error\",\"message\":\"Something went wrong on our side.\",\"hint\":\"Try again; report the request id if it persists.\"}}",
                "isBase64Encoded": false,
                "cookies": []
            })
        );
    }

    #[test]
    fn the_fallback_leaves_out_a_request_id_http_cannot_carry() {
        let out = fallback_internal_error("bad\nid");
        assert_eq!(out.status_code, 500);
        assert!(out.headers.get(REQUEST_ID).is_none());
        assert_eq!(out.headers.len(), 2);
    }
}
