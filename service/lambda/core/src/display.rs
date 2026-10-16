//! The optional display metadata a commit request carries (spec/api/openapi.yaml
//! `CommitPublishRequest`; rules in spec/mopm-toml.md, `[package]` display fields). The registry
//! stores it on the version and serves it back. Every rule is the one the spec states for the field;
//! a value that breaks it is `invalid_request`, never silently trimmed.
//!
//! Lengths are JavaScript's: a string's `length` counts UTF-16 code units, and `\s` is JavaScript's
//! whitespace set, so the rules accept and refuse the same text as `parseDisplay` of the
//! TypeScript registry. A URL is judged by the WHATWG parser (the `url` crate here, `new URL` there).

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{invalid_request, RegistryError};
use crate::types::README_MAX_BYTES;

/// The display fields of a commit body. Stored with a publish record: an absent field is absent, never `null`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplayMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    /// Markdown, at most [`README_MAX_BYTES`] of UTF-8.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readme: Option<String>,
}

pub const DISPLAY_FIELDS: [&str; 6] = ["description", "license", "repository", "homepage", "keywords", "readme"];

/// JavaScript's `\s`: the ECMAScript WhiteSpace and LineTerminator code points.
fn js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

fn is_keyword(k: &str) -> bool {
    (1..=32).contains(&k.len()) && k.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'+' | b'-'))
}

/// A `https` URL of at most 2048 characters without whitespace.
fn url(field: &str, v: &str) -> Result<String, RegistryError> {
    let ok = utf16_len(v) <= 2048 && !v.chars().any(js_space) && url::Url::parse(v).is_ok_and(|u| u.scheme() == "https");
    if ok {
        Ok(v.to_string())
    } else {
        Err(invalid_request(&format!("'{field}' is a https URL of at most 2048 characters")))
    }
}

/// Validates the display fields of a commit body. Absent stays absent; `null` is not a value.
pub fn parse_display(body: &Map<String, Value>) -> Result<DisplayMeta, RegistryError> {
    let mut out = DisplayMeta::default();
    if let Some(v) = body.get("description") {
        match v.as_str() {
            Some(s) if (1..=512).contains(&utf16_len(s)) && !s.contains(['\r', '\n']) => out.description = Some(s.to_string()),
            _ => return Err(invalid_request("'description' is one line of 1 to 512 characters")),
        }
    }
    if let Some(v) = body.get("license") {
        match v.as_str() {
            Some(s) if (1..=128).contains(&utf16_len(s)) => out.license = Some(s.to_string()),
            _ => return Err(invalid_request("'license' is a string of 1 to 128 characters")),
        }
    }
    if let Some(v) = body.get("repository") {
        let s = v.as_str().ok_or_else(|| invalid_request("'repository' must be a string"))?;
        out.repository = Some(url("repository", s)?);
    }
    if let Some(v) = body.get("homepage") {
        let s = v.as_str().ok_or_else(|| invalid_request("'homepage' must be a string"))?;
        out.homepage = Some(url("homepage", s)?);
    }
    if let Some(v) = body.get("keywords") {
        let items = match v.as_array() {
            Some(a) if a.len() <= 10 => a,
            _ => return Err(invalid_request("'keywords' is an array of at most 10 strings")),
        };
        let mut keywords: Vec<String> = Vec::with_capacity(items.len());
        for k in items {
            match k.as_str() {
                Some(s) if is_keyword(s) => keywords.push(s.to_string()),
                _ => return Err(invalid_request("each keyword is 1 to 32 letters, digits, '-', '_', '.' or '+'")),
            }
        }
        let distinct: std::collections::BTreeSet<&String> = keywords.iter().collect();
        if distinct.len() != keywords.len() {
            return Err(invalid_request("'keywords' repeats a keyword"));
        }
        out.keywords = Some(keywords);
    }
    if let Some(v) = body.get("readme") {
        // Bytes of UTF-8, not characters: the read API serves at most README_MAX_BYTES, so a larger one
        // could never be shown.
        match v.as_str() {
            Some(s) if s.len() <= README_MAX_BYTES => out.readme = Some(s.to_string()),
            _ => return Err(invalid_request(&format!("'readme' is a string of at most {README_MAX_BYTES} bytes of UTF-8"))),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;
    use serde_json::json;

    fn body(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    fn refused(v: Value) -> String {
        let err = parse_display(&body(v)).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidRequest);
        assert_eq!(err.status(), 400);
        // The message is the template with the detail in it, and the detail is what the response renders.
        assert_eq!(err.message, format!("The request is not valid: {}.", err.detail["detail"]));
        err.detail["detail"].clone()
    }

    #[test]
    fn absent_fields_stay_absent() {
        assert_eq!(parse_display(&body(json!({"unrelated": 1}))).unwrap(), DisplayMeta::default());
    }

    #[test]
    fn a_full_valid_body_is_kept_as_it_is() {
        let m = parse_display(&body(json!({
            "description": "A client.",
            "license": "Apache-2.0",
            "repository": "https://github.com/example/http_client",
            "homepage": "https://example.org/http",
            "keywords": ["http", "client_2", "a.b", "c+d", "e-f"],
            "readme": "# Title\n\nbody"
        })))
        .unwrap();
        assert_eq!(m.description.as_deref(), Some("A client."));
        assert_eq!(m.license.as_deref(), Some("Apache-2.0"));
        assert_eq!(m.repository.as_deref(), Some("https://github.com/example/http_client"));
        assert_eq!(m.homepage.as_deref(), Some("https://example.org/http"));
        assert_eq!(m.keywords.as_ref().map(Vec::len), Some(5));
        assert_eq!(m.readme.as_deref(), Some("# Title\n\nbody"));
    }

    #[test]
    fn description_is_one_line_of_1_to_512_utf16_units() {
        let msg = "'description' is one line of 1 to 512 characters";
        assert_eq!(refused(json!({"description": ""})), msg);
        assert_eq!(refused(json!({"description": "a\nb"})), msg);
        assert_eq!(refused(json!({"description": "a\rb"})), msg);
        assert_eq!(refused(json!({"description": 5})), msg);
        assert_eq!(refused(json!({"description": null})), msg, "null is not a value");
        assert_eq!(refused(json!({"description": "x".repeat(513)})), msg);
        assert!(parse_display(&body(json!({"description": "x".repeat(512)}))).is_ok());
        // 256 astral characters are 512 UTF-16 units; 257 are 514 (JavaScript's length counts units).
        assert!(parse_display(&body(json!({"description": "\u{1f600}".repeat(256)}))).is_ok());
        assert_eq!(refused(json!({"description": "\u{1f600}".repeat(257)})), msg);
    }

    #[test]
    fn license_is_1_to_128_characters() {
        let msg = "'license' is a string of 1 to 128 characters";
        assert_eq!(refused(json!({"license": ""})), msg);
        assert_eq!(refused(json!({"license": "x".repeat(129)})), msg);
        assert_eq!(refused(json!({"license": ["MIT"]})), msg);
        assert!(parse_display(&body(json!({"license": "x".repeat(128)}))).is_ok());
    }

    #[test]
    fn repository_and_homepage_are_https_urls_without_whitespace_of_at_most_2048_characters() {
        for field in ["repository", "homepage"] {
            let msg = format!("'{field}' is a https URL of at most 2048 characters");
            for bad in [
                "http://example.org/x",
                "git@github.com:example/x.git",
                "example.org/x",
                "ftp://example.org",
                "https://exa mple.org",
                "https://example.org/a b",
                "https://example.org/\u{a0}",
                "https://example.org/\u{feff}",
                "https://example.org/\u{3000}",
                "https:// example.org",
                "",
                "javascript:alert(1)",
            ] {
                assert_eq!(refused(json!({ field: bad })), msg, "{bad:?}");
            }
            let long = format!("https://example.org/{}", "a".repeat(2048));
            assert_eq!(refused(json!({ field: long })), msg);
            let at = format!("https://example.org/{}", "a".repeat(2048 - "https://example.org/".len()));
            assert_eq!(at.len(), 2048);
            assert!(parse_display(&body(json!({ field: at }))).is_ok());
            assert_eq!(refused(json!({ field: 7 })), format!("'{field}' must be a string"));
            assert_eq!(refused(json!({ field: null })), format!("'{field}' must be a string"));
        }
        assert!(parse_display(&body(json!({"repository": "HTTPS://Example.org/x"}))).is_ok(), "the scheme is case-insensitive");
    }

    #[test]
    fn keywords_are_at_most_10_distinct_tokens_of_1_to_32_allowed_characters() {
        assert_eq!(refused(json!({"keywords": "http"})), "'keywords' is an array of at most 10 strings");
        let eleven: Vec<String> = (0..11).map(|i| format!("k{i}")).collect();
        assert_eq!(refused(json!({"keywords": eleven})), "'keywords' is an array of at most 10 strings");
        let ten: Vec<String> = (0..10).map(|i| format!("k{i}")).collect();
        assert!(parse_display(&body(json!({"keywords": ten}))).is_ok());
        let each = "each keyword is 1 to 32 letters, digits, '-', '_', '.' or '+'";
        for bad in [json!(""), json!("a b"), json!("a/b"), json!("x".repeat(33)), json!("k\n"), json!("\u{e9}"), json!(3), json!(null)] {
            assert_eq!(refused(json!({"keywords": [bad]})), each);
        }
        assert!(parse_display(&body(json!({"keywords": ["x".repeat(32)]}))).is_ok());
        assert_eq!(refused(json!({"keywords": ["a", "b", "a"]})), "'keywords' repeats a keyword");
    }

    #[test]
    fn readme_is_at_most_65536_bytes_of_utf8() {
        let msg = "'readme' is a string of at most 65536 bytes of UTF-8";
        assert!(parse_display(&body(json!({"readme": "x".repeat(65536)}))).is_ok());
        assert_eq!(refused(json!({"readme": "x".repeat(65537)})), msg);
        // Bytes, not characters: 21846 three-byte characters are 65538 bytes.
        assert_eq!(refused(json!({"readme": "\u{20ac}".repeat(21846)})), msg);
        assert!(parse_display(&body(json!({"readme": "\u{20ac}".repeat(21845)}))).is_ok());
        assert_eq!(refused(json!({"readme": 1})), msg);
    }

    #[test]
    fn the_first_broken_field_in_the_spec_order_is_reported() {
        // description, license, repository, homepage, keywords, readme.
        assert_eq!(refused(json!({"readme": 1, "keywords": 1, "license": ""})), "'license' is a string of 1 to 128 characters");
        assert_eq!(refused(json!({"readme": 1, "keywords": 1})), "'keywords' is an array of at most 10 strings");
        assert_eq!(DISPLAY_FIELDS, ["description", "license", "repository", "homepage", "keywords", "readme"]);
    }
}
