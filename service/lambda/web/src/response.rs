//! A response as the website's functions make it, without the transport. Every response carries
//! `x-mopm-request-id` and `Cache-Control: no-store`: each answer of the website's routes is about one
//! browser (its cookie, its session, its sandbox), so no cache may keep one.

use crate::cookie::SetCookie;

/// `x-mopm-request-id`: the request's id, on every answer.
pub const REQUEST_ID: &str = "x-mopm-request-id";
/// `cache-control`, and the one value this crate sends.
pub const CACHE_CONTROL: &str = "cache-control";
pub const NO_STORE: &str = "no-store";
pub const CONTENT_TYPE: &str = "content-type";
pub const JSON: &str = "application/json";

/// The two redirects of the sign-in: 302 from `start` to GitHub, 303 from `callback` to the site.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Redirect {
    Found,
    SeeOther,
}

impl Redirect {
    pub const fn status(self) -> u16 {
        match self {
            Redirect::Found => 302,
            Redirect::SeeOther => 303,
        }
    }
}

/// An answer: the status, the header fields (lower-case names, at most one field per name), the
/// `Set-Cookie` values, and the body (empty for none).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub set_cookies: Vec<SetCookie>,
    pub body: String,
}

impl WebResponse {
    /// `status` with no body: the request id and `no-store` only.
    pub fn empty(status: u16, request_id: &str) -> WebResponse {
        WebResponse {
            status,
            headers: vec![(REQUEST_ID.to_string(), request_id.to_string()), (CACHE_CONTROL.to_string(), NO_STORE.to_string())],
            set_cookies: Vec::new(),
            body: String::new(),
        }
    }

    /// `status` with `body` as JSON (`content-type: application/json`). Object keys come out in sorted order.
    pub fn json(status: u16, body: &serde_json::Value, request_id: &str) -> WebResponse {
        WebResponse::empty(status, request_id).with_header(CONTENT_TYPE, JSON).with_body(body.to_string())
    }

    /// A redirect to `location`, with no body.
    pub fn redirect(kind: Redirect, location: &str, request_id: &str) -> WebResponse {
        WebResponse::empty(kind.status(), request_id).with_header("location", location)
    }

    /// Sets the field `name` (stored in lower case) to `value`, replacing a field of that name.
    pub fn with_header(mut self, name: &str, value: &str) -> WebResponse {
        let name = name.to_ascii_lowercase();
        self.headers.retain(|(n, _)| *n != name);
        self.headers.push((name, value.to_string()));
        self
    }

    /// Adds a `Set-Cookie`.
    pub fn with_cookie(mut self, cookie: SetCookie) -> WebResponse {
        self.set_cookies.push(cookie);
        self
    }

    /// Sets the body; the caller sets its `content-type`.
    pub fn with_body(mut self, body: String) -> WebResponse {
        self.body = body;
        self
    }

    /// The value of the field `name`, looked up without case.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cookie;

    fn headers(r: &WebResponse) -> Vec<(&str, &str)> {
        r.headers.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect()
    }

    #[test]
    fn an_empty_answer_carries_the_request_id_and_no_store_only() {
        let r = WebResponse::empty(204, "req-1");
        assert_eq!(r.status, 204);
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "req-1"), ("cache-control", "no-store")]);
        assert!(r.set_cookies.is_empty());
        assert_eq!(r.body, "");
    }

    #[test]
    fn a_json_answer_has_its_content_type_and_the_compact_body() {
        let r = WebResponse::json(200, &serde_json::json!({"login": "alice", "csrf": "c"}), "req-2");
        assert_eq!(r.status, 200);
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "req-2"), ("cache-control", "no-store"), ("content-type", "application/json")]);
        assert_eq!(r.body, r#"{"csrf":"c","login":"alice"}"#);
    }

    #[test]
    fn redirects_are_302_and_303_with_a_location_and_no_body() {
        let found = WebResponse::redirect(Redirect::Found, "https://github.com/login/oauth/authorize?x=1", "r");
        assert_eq!(found.status, 302);
        assert_eq!(found.header("Location"), Some("https://github.com/login/oauth/authorize?x=1"));
        assert_eq!(found.body, "");
        let see_other = WebResponse::redirect(Redirect::SeeOther, "https://mopm.dev/tutorial", "r");
        assert_eq!(see_other.status, 303);
        assert_eq!(see_other.header("location"), Some("https://mopm.dev/tutorial"));
    }

    #[test]
    fn a_header_set_twice_keeps_the_last_value_once() {
        let r = WebResponse::empty(200, "r").with_header("Referrer-Policy", "origin").with_header("referrer-policy", "no-referrer");
        assert_eq!(headers(&r), vec![("x-mopm-request-id", "r"), ("cache-control", "no-store"), ("referrer-policy", "no-referrer")]);
        assert_eq!(r.header("absent"), None);
    }

    #[test]
    fn cookies_are_kept_in_the_order_added() {
        let r = WebResponse::empty(303, "r").with_cookie(cookie::clear_login_cookie()).with_cookie(cookie::clear_session_cookie());
        let values: Vec<&str> = r.set_cookies.iter().map(|c| c.as_str()).collect();
        assert_eq!(
            values,
            vec!["__Host-mopm_login=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0", "__Host-mopm_session=; Secure; HttpOnly; Path=/; SameSite=Lax; Max-Age=0"]
        );
    }
}
