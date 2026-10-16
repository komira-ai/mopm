//! The few JavaScript behaviours the auth layer's answers depend on: what `trim()` and `\s` call whitespace, how
//! `String.prototype.length` counts, how `Array.prototype.sort()` orders strings, and what `Number.isInteger`
//! accepts. Each is used where the TypeScript used the JavaScript, so a client sees the same answer.

use std::cmp::Ordering;

use jiff::Timestamp;
use serde_json::Value;

/// The characters `\s` and `String.prototype.trim` treat as white space (ECMAScript WhiteSpace and LineTerminator).
/// Not `char::is_whitespace`: that one has U+0085 and lacks U+FEFF.
pub fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}

/// `s.trim()`.
pub fn trim(s: &str) -> &str {
    s.trim_matches(is_js_space)
}

/// `s.length`: UTF-16 code units, so a character outside the Basic Multilingual Plane counts twice.
pub fn length(s: &str) -> usize {
    s.encode_utf16().count()
}

/// The order of `[...].sort()` on strings: by UTF-16 code unit.
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// `Number.isInteger(v)` for a JSON value, as an unsigned integer: `4242` and `4242.0` both, `4242.5` and a string not.
pub fn integer(v: &Value) -> Option<u64> {
    if let Some(n) = v.as_u64() {
        return Some(n);
    }
    // Beyond 2^53 a double is no longer exact; no id or interval gets there.
    v.as_f64().filter(|f| f.fract() == 0.0 && (0.0..=9_007_199_254_740_992.0).contains(f)).map(|f| f as u64)
}

/// `Date.parse(iso)` in milliseconds since the epoch, or `None` where JavaScript gives `NaN`.
pub fn parse_ms(iso: &str) -> Option<i64> {
    iso.parse::<Timestamp>().ok().map(Timestamp::as_millisecond)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn white_space_is_the_ecmascript_set() {
        for c in ['\t', '\n', '\u{b}', '\u{c}', '\r', ' ', '\u{a0}', '\u{1680}', '\u{2003}', '\u{2028}', '\u{2029}', '\u{202f}', '\u{205f}', '\u{3000}', '\u{feff}'] {
            assert!(is_js_space(c), "{c:?}");
        }
        // U+0085 is white space to Rust and not to JavaScript; U+200B (zero width space) to neither.
        for c in ['\u{85}', '\u{200b}', 'a', '0', '\u{180e}'] {
            assert!(!is_js_space(c), "{c:?}");
        }
        assert_eq!(trim("\u{feff} \tBearer x\u{3000}\n"), "Bearer x");
        assert_eq!(trim("\u{85}x"), "\u{85}x");
    }

    #[test]
    fn length_counts_utf16_units() {
        assert_eq!(length("abc"), 3);
        assert_eq!(length("\u{e9}"), 1);
        assert_eq!(length("\u{1f600}"), 2);
        assert_eq!(length(&"\u{1f600}".repeat(40)), 80);
    }

    #[test]
    fn utf16_order_differs_from_utf8_order_above_the_plane() {
        // U+FF5E sorts before U+10000 in UTF-8 and after it in UTF-16 (the surrogate 0xD800 is below 0xFF5E).
        assert_eq!("\u{ff5e}".cmp("\u{10000}"), Ordering::Less);
        assert_eq!(cmp_utf16("\u{ff5e}", "\u{10000}"), Ordering::Greater);
        assert_eq!(cmp_utf16("a", "b"), Ordering::Less);
        assert_eq!(cmp_utf16("a", "ab"), Ordering::Less);
    }

    #[test]
    fn integers_as_number_is_integer_has_them() {
        assert_eq!(integer(&json!(5)), Some(5));
        assert_eq!(integer(&json!(5.0)), Some(5));
        assert_eq!(integer(&json!(5.5)), None);
        assert_eq!(integer(&json!(-1)), None);
        assert_eq!(integer(&json!("5")), None);
        assert_eq!(integer(&json!(null)), None);
        assert_eq!(integer(&json!(1e300)), None);
    }

    #[test]
    fn dates_parse_as_iso_and_garbage_does_not() {
        assert_eq!(parse_ms("1970-01-01T00:00:01.250Z"), Some(1250));
        assert_eq!(parse_ms("2026-10-14T12:00:00Z"), parse_ms("2026-10-14T12:00:00.000Z"));
        assert_eq!(parse_ms("not a date"), None);
        assert_eq!(parse_ms(""), None);
    }
}
