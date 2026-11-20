//! A request as the website's functions see it, without the transport: the method, the path, the query, the
//! headers (names compared without case), the cookies and the body. [`crate::apigw`] makes one from API
//! Gateway's event; a test makes one with the builder methods.

/// The request's method. The website's routes are `GET` and `POST`; any other is kept by name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Other(String),
}

impl Method {
    /// The method named `s` on the request line (`GET`, `POST`; any other spelling is [`Method::Other`]).
    pub fn parse(s: &str) -> Method {
        match s {
            "GET" => Method::Get,
            "POST" => Method::Post,
            other => Method::Other(other.to_string()),
        }
    }
}

/// Header fields, in the order received. Names are stored in lower case and looked up without case.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Headers(Vec<(String, String)>);

impl Headers {
    /// Adds a field; `name` is stored in lower case.
    pub fn push(&mut self, name: &str, value: &str) {
        self.0.push((name.to_ascii_lowercase(), value.to_string()));
    }

    /// The value of `name` when the request carries exactly one field of that name. Two fields of one name
    /// answer `None`, so a check never picks one of them.
    pub fn get(&self, name: &str) -> Option<&str> {
        let mut values = self.0.iter().filter(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str());
        let first = values.next()?;
        values.next().is_none().then_some(first)
    }

    /// Every value of `name`, in the order received.
    pub fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.0.iter().filter(move |(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }

    /// Whether the request carries any field named `name`.
    pub fn contains(&self, name: &str) -> bool {
        self.0.iter().any(|(n, _)| n.eq_ignore_ascii_case(name))
    }

    /// Every field, as (lower-case name, value).
    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.0.iter().map(|(n, v)| (n.as_str(), v.as_str()))
    }
}

/// One cookie of the request, as `name=value`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cookie {
    pub name: String,
    pub value: String,
}

/// The cookie pairs of one `Cookie` header value (`a=1; b=2`), in order. Whitespace around a pair, its name
/// and its value is dropped; a piece without `=` or with an empty name is no cookie. Values are kept as
/// sent: a quoted value keeps its quotes.
pub fn parse_cookie_header(header: &str) -> Vec<Cookie> {
    header
        .split(';')
        .filter_map(|piece| {
            let (name, value) = piece.split_once('=')?;
            let name = name.trim();
            (!name.is_empty()).then(|| Cookie { name: name.to_string(), value: value.trim().to_string() })
        })
        .collect()
}

/// A request to one of the website's routes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebRequest {
    pub method: Method,
    /// The path as received, without the query.
    pub path: String,
    /// The query's pairs, decoded, in order.
    pub query: Vec<(String, String)>,
    pub headers: Headers,
    /// Every cookie of the request, in order: those of each `Cookie` header and of API Gateway's `cookies`.
    pub cookies: Vec<Cookie>,
    /// The body's bytes; empty when there is none.
    pub body: Vec<u8>,
    /// API Gateway's id of the request, answered as `x-mopm-request-id`.
    pub request_id: String,
}

impl WebRequest {
    /// A request with no query, headers, cookies or body.
    pub fn new(method: Method, path: &str, request_id: &str) -> WebRequest {
        WebRequest { method, path: path.to_string(), query: Vec::new(), headers: Headers::default(), cookies: Vec::new(), body: Vec::new(), request_id: request_id.to_string() }
    }

    /// Adds a header field.
    pub fn with_header(mut self, name: &str, value: &str) -> WebRequest {
        self.headers.push(name, value);
        self
    }

    /// Adds the cookies of one `Cookie` header value.
    pub fn with_cookies(mut self, header: &str) -> WebRequest {
        self.cookies.extend(parse_cookie_header(header));
        self
    }

    /// Adds a query pair.
    pub fn with_query(mut self, name: &str, value: &str) -> WebRequest {
        self.query.push((name.to_string(), value.to_string()));
        self
    }

    /// Sets the body.
    pub fn with_body(mut self, body: &[u8]) -> WebRequest {
        self.body = body.to_vec();
        self
    }

    /// The value of the query parameter `name` when the query has it exactly once; two answer `None`.
    pub fn query_param(&self, name: &str) -> Option<&str> {
        let mut values = self.query.iter().filter(|(n, _)| n == name).map(|(_, v)| v.as_str());
        let first = values.next()?;
        values.next().is_none().then_some(first)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn methods_are_read_by_their_exact_name() {
        assert_eq!(Method::parse("GET"), Method::Get);
        assert_eq!(Method::parse("POST"), Method::Post);
        assert_eq!(Method::parse("post"), Method::Other("post".to_string()));
        assert_eq!(Method::parse("DELETE"), Method::Other("DELETE".to_string()));
    }

    #[test]
    fn header_names_are_looked_up_without_case() {
        let mut h = Headers::default();
        h.push("X-Mopm-CSRF", "v");
        assert_eq!(h.get("x-mopm-csrf"), Some("v"));
        assert_eq!(h.get("X-MOPM-CSRF"), Some("v"));
        assert!(h.contains("x-MOPM-csrf"));
        assert_eq!(h.iter().collect::<Vec<_>>(), vec![("x-mopm-csrf", "v")]);
    }

    #[test]
    fn a_header_sent_twice_has_no_single_value_but_both_are_listed() {
        let mut h = Headers::default();
        h.push("Origin", "https://a.example");
        h.push("origin", "https://b.example");
        assert_eq!(h.get("origin"), None);
        assert_eq!(h.all("ORIGIN").collect::<Vec<_>>(), vec!["https://a.example", "https://b.example"]);
    }

    #[test]
    fn an_absent_header_is_none_and_not_contained() {
        let h = Headers::default();
        assert_eq!(h.get("origin"), None);
        assert!(!h.contains("origin"));
    }

    #[test]
    fn a_cookie_header_is_split_into_pairs_in_order() {
        let c = parse_cookie_header(" a=1 ;b = 2;  c=x=y ; d=\"q\"");
        let pairs: Vec<(&str, &str)> = c.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect();
        assert_eq!(pairs, vec![("a", "1"), ("b", "2"), ("c", "x=y"), ("d", "\"q\"")]);
    }

    #[test]
    fn pieces_without_a_name_or_an_equals_sign_are_no_cookie() {
        let c = parse_cookie_header("novalue; =orphan; ;  ; e=");
        let pairs: Vec<(&str, &str)> = c.iter().map(|c| (c.name.as_str(), c.value.as_str())).collect();
        assert_eq!(pairs, vec![("e", "")]);
        assert!(parse_cookie_header("").is_empty());
    }

    #[test]
    fn the_builder_sets_every_part() {
        let r = WebRequest::new(Method::Post, "/api/v2/auth/web/logout", "req-1")
            .with_header("Content-Type", "application/json")
            .with_cookies("a=1; b=2")
            .with_query("q", "v")
            .with_body(b"{}");
        assert_eq!(r.method, Method::Post);
        assert_eq!(r.path, "/api/v2/auth/web/logout");
        assert_eq!(r.request_id, "req-1");
        assert_eq!(r.headers.get("content-type"), Some("application/json"));
        assert_eq!(r.cookies.len(), 2);
        assert_eq!(r.query, vec![("q".to_string(), "v".to_string())]);
        assert_eq!(r.body, b"{}");
    }

    #[test]
    fn a_query_parameter_is_read_only_when_it_is_there_once() {
        let r = WebRequest::new(Method::Get, "/", "r").with_query("state", "a").with_query("code", "1").with_query("code", "2");
        assert_eq!(r.query_param("state"), Some("a"));
        assert_eq!(r.query_param("code"), None);
        assert_eq!(r.query_param("missing"), None);
    }
}
