//! Where a web login sends the browser back to (`return_to` of `GET /api/v2/auth/web/start`; appendix C.1 of
//! docs/design/mopm-dev-appendix.md, with docs/design/tutorial-sign-in.md section 1's fallback).
//!
//! The value is the query parameter as the HTTP layer decoded it, once. It is kept only when it is a path of a page
//! of the site: it starts with `/` but not `//` or `/\`, holds no control character and no backslash, is at most
//! [`RETURN_TO_MAX`] characters, and is one of these routes:
//!
//! * `/` and `/search` (no query string, no fragment);
//! * `/packages/<namespace>/<name>`, `/packages/<namespace>/<name>/versions` and
//!   `/packages/<namespace>/<name>/<version>`, the app routes of `site/src/routes.ts` (`parseRoute`): a namespace, a
//!   canonical name and a version as that file spells them;
//! * `/docs`, `/docs/`, `/docs/<slug>` and `/docs/<slug>/`, the pages the site's edge router serves;
//! * `/tutorial` and `/tutorial/<lesson>`, the lesson `^[a-z0-9]+(-[a-z0-9]+)*$`.
//!
//! The site's edge router serves `/tutorial` and `/tutorial/<lesson>` from the tutorial's pages, on a stage that
//! serves the tutorial, and answers `/tutorial/` and `/tutorial/<lesson>/` with the 404 page, as this module refuses
//! them; `site/test/fixtures/routes.json` carries both (tests/return_to_routes.rs). A stage without the tutorial
//! answers every tutorial path with the 404 page, the fallback included.
//!
//! Anything else becomes [`RETURN_TO_FALLBACK`]. A `%` is in no route (a valid segment needs no encoding), so a
//! value that is still encoded (`/%2F%2Fx`) falls back too and is never decoded a second time.

use crate::version::is_valid_version;

/// What any value outside the grammar becomes.
pub const RETURN_TO_FALLBACK: &str = "/tutorial";
/// The most characters a kept value has.
pub const RETURN_TO_MAX: usize = 256;

/// `routes.ts` VERSIONS_SEGMENT: the last segment of a package's full version list.
const VERSIONS_SEGMENT: &str = "versions";
/// `routes.ts` NAMESPACE_MAX.
const NAMESPACE_MAX: usize = 39;
/// `routes.ts` DOC_SLUG's bound.
const DOC_SLUG_MAX: usize = 64;

/// `value` when it is a path the login may return to, otherwise [`RETURN_TO_FALLBACK`].
pub fn validate_return_to(value: &str) -> String {
    if is_return_path(value) {
        value.to_owned()
    } else {
        RETURN_TO_FALLBACK.to_owned()
    }
}

fn is_return_path(v: &str) -> bool {
    v.starts_with('/')
        && !v.starts_with("//")
        && !v.starts_with("/\\")
        && !v.chars().any(|c| c.is_control() || c == '\\')
        && v.chars().count() <= RETURN_TO_MAX
        && is_site_route(v)
}

fn is_site_route(v: &str) -> bool {
    let parts: Vec<&str> = v.split('/').collect();
    // parts[0] is the empty string before the leading '/'.
    match parts[1..] {
        [""] | ["search"] | ["tutorial"] | ["docs"] | ["docs", ""] => true,
        ["tutorial", lesson] => is_hyphenated(lesson),
        ["docs", slug] | ["docs", slug, ""] => is_doc_slug(slug),
        ["packages", ns, name] => is_namespace(ns) && is_canonical_name(name),
        ["packages", ns, name, last] => {
            is_namespace(ns)
                && is_canonical_name(name)
                && (last == VERSIONS_SEGMENT || is_valid_version(last))
        }
        _ => false,
    }
}

/// `^[a-z0-9]+(-[a-z0-9]+)*$`: runs of lowercase letters and digits joined by single hyphens.
fn is_hyphenated(s: &str) -> bool {
    !s.is_empty()
        && s.split('-').all(|run| {
            !run.is_empty()
                && run
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// `routes.ts` isNamespace.
fn is_namespace(s: &str) -> bool {
    s.len() <= NAMESPACE_MAX && is_hyphenated(s)
}

/// `routes.ts` isCanonicalName: NAME (`^[a-z][a-z0-9_]{1,63}$`) and already normalised, which for a string NAME
/// accepts means no run of two `_`.
fn is_canonical_name(s: &str) -> bool {
    let b = s.as_bytes();
    (2..=64).contains(&b.len())
        && b[0].is_ascii_lowercase()
        && b.iter()
            .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        && !s.contains("__")
}

/// `routes.ts` DOC_SLUG: `^[a-z0-9-]{1,64}$`.
fn is_doc_slug(s: &str) -> bool {
    (1..=DOC_SLUG_MAX).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(v: &str) {
        assert_eq!(validate_return_to(v), v, "{v:?} should be kept");
    }

    fn refused(v: &str) {
        assert_eq!(
            validate_return_to(v),
            RETURN_TO_FALLBACK,
            "{v:?} should fall back"
        );
    }

    #[test]
    fn the_pages_of_the_site_are_kept() {
        for v in [
            "/",
            "/search",
            "/tutorial",
            "/tutorial/hello",
            "/tutorial/hello-world-2",
            "/tutorial/2",
            "/docs",
            "/docs/",
            "/docs/why",
            "/docs/getting-started/",
            "/packages/komira-ai/http_client",
            "/packages/komira-ai/http2_client",
            "/packages/9lives/a1",
            "/docs/step-2/",
            "/docs/2",
            "/packages/a/ab",
            "/packages/komira-ai/http_client/1.0.0",
            "/packages/komira-ai/http_client/10.20.300",
            "/packages/komira-ai/http_client/versions",
            "/packages/a/versions/versions",
        ] {
            kept(v);
        }
    }

    #[test]
    fn what_is_not_a_path_on_this_site_falls_back() {
        for v in [
            "",
            "x",
            "tutorial",
            "https://evil.example/",
            "%2F%2Fx",
            "javascript:alert(1)",
        ] {
            refused(v);
        }
    }

    #[test]
    fn a_protocol_relative_or_backslash_start_falls_back() {
        for v in [
            "//x",
            "//evil.example/tutorial",
            "/\\x",
            "/\\evil.example",
            "///tutorial",
        ] {
            refused(v);
        }
    }

    #[test]
    fn a_backslash_anywhere_falls_back() {
        refused("/tutorial\\hello");
        refused("/tutorial/hello\\");
    }

    #[test]
    fn a_control_character_falls_back() {
        for v in [
            "/tutorial\n",
            "/tutorial/hel\rlo",
            "/\t/x",
            "/tutorial\0",
            "/tutorial\u{7f}",
            "/tutorial\u{85}",
        ] {
            refused(v);
        }
    }

    #[test]
    fn an_encoded_value_is_not_decoded_again() {
        for v in [
            "/%2F%2Fx",
            "/%2f%2fx",
            "/tutorial/%68ello",
            "/%5Cx",
            "/packages/komira-ai/http%5Fclient",
        ] {
            refused(v);
        }
    }

    #[test]
    fn at_most_256_characters_are_kept() {
        let at_limit = format!(
            "/tutorial/{}",
            "a".repeat(RETURN_TO_MAX - "/tutorial/".len())
        );
        assert_eq!(at_limit.len(), 256);
        kept(&at_limit);
        let over = format!("{at_limit}a");
        assert_eq!(over.len(), 257);
        refused(&over);
    }

    #[test]
    fn a_route_outside_the_grammar_falls_back() {
        for v in [
            "/account",
            "/search/",
            "/search?q=x",
            "/tutorial/",
            "/tutorial/hello/",
            "/tutorial/hello/extra",
            "/tutorial/Hello",
            "/tutorial/-hello",
            "/tutorial/hello-",
            "/tutorial/hello--world",
            "/tutorial/hello_world",
            "/tutorial/hello#x",
            "/tutorial/../x",
            "/docs/a/b",
            "/docs/Bad_Slug",
            "/docs/../x",
            "/docs//",
            "/packages",
            "/packages/",
            "/packages/http_client",
            "/packages/komira-ai",
            "/packages/komira-ai/",
            "/packages/komira-ai/http_client/",
            "/packages/komira-ai/http_client/1.0",
            "/packages/komira-ai/http_client/01.0.0",
            "/packages/komira-ai/http_client/1.0.0/x",
            "/packages/komira-ai/http_client/Versions",
            "/packages/komira-ai/http_client/version",
            "/packages/komira-ai/http_client/versions/",
            "/packages/komira-ai/http_client/versions/1.0.0",
            "/packages/komira-ai/Http_client/versions",
            "/packages/Komira-AI/http_client/versions",
            "/packages/Komira-AI/http_client",
            "/packages/komira--ai/http_client",
            "/packages/komira-ai/Http_client",
            "/packages/komira-ai/http__client",
            "/packages/komira-ai/http-client",
            "/packages/komira-ai/1abc",
            "/packages/komira-ai/a",
        ] {
            refused(v);
        }
    }

    #[test]
    fn the_namespace_slug_and_name_bounds() {
        let ns39 = "a".repeat(39);
        kept(&format!("/packages/{ns39}/ab"));
        refused(&format!("/packages/{ns39}a/ab"));
        let name64 = format!("a{}", "b".repeat(63));
        kept(&format!("/packages/a/{name64}"));
        refused(&format!("/packages/a/{name64}b"));
        let slug64 = "a".repeat(64);
        kept(&format!("/docs/{slug64}/"));
        refused(&format!("/docs/{slug64}a/"));
        refused("/docs//x");
    }

    #[test]
    fn the_version_bound_is_the_registrys() {
        let long = format!("1.0.{}", "1".repeat(124));
        assert_eq!(long.len(), 128);
        kept(&format!("/packages/a/ab/{long}"));
        refused(&format!("/packages/a/ab/{long}1"));
    }
}
