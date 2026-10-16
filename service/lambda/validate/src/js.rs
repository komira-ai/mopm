//! The few JavaScript behaviours the TypeScript validator's verdicts depend on: its lenient `parseInt`, its
//! `\s`, its `trim`, `TextDecoder`'s byte order mark, `path.posix.normalize`. Each is the behaviour of the
//! language, reproduced so that the same bytes give the same verdict.

/// JavaScript's `\s` (and the set `trim` removes, except the line terminators it also removes).
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}

/// `parseInt(s, radix)`: leading white space, an optional sign, then as many digits of the radix as there
/// are; `None` is `NaN`.
pub fn parse_int(s: &str, radix: u32) -> Option<i128> {
    let s = s.trim_start_matches(is_space);
    let (neg, rest) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let digits: String = rest.chars().take_while(|c| c.is_digit(radix)).collect();
    if digits.is_empty() {
        return None;
    }
    // More digits than an i128 holds are far past every use here (a safe-integer check follows).
    let v = i128::from_str_radix(&digits, radix).unwrap_or(i128::MAX / 4);
    Some(if neg { -v } else { v })
}

/// `new TextDecoder('utf-8', { fatal: true }).decode(bytes)`: strict UTF-8, and a leading byte order mark is dropped.
pub fn decode_utf8(bytes: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(bytes).ok()?;
    Some(s.strip_prefix('\u{feff}').unwrap_or(s).to_string())
}

/// `buf.toString('latin1')`.
pub fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|b| char::from(*b)).collect()
}

/// `path.posix.normalize`.
pub fn posix_normalize(path: &str) -> String {
    if path.is_empty() {
        return ".".to_string();
    }
    let absolute = path.starts_with('/');
    let trailing = path.ends_with('/');
    let mut out: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                if out.last().is_some_and(|l| *l != "..") {
                    out.pop();
                } else if !absolute {
                    out.push("..");
                }
            }
            s => out.push(s),
        }
    }
    let joined = out.join("/");
    if joined.is_empty() {
        return if absolute { "/".to_string() } else if trailing { "./".to_string() } else { ".".to_string() };
    }
    let joined = if trailing { format!("{joined}/") } else { joined };
    if absolute {
        format!("/{joined}")
    } else {
        joined
    }
}

/// `path.posix.join(a, b)`.
pub fn posix_join(a: &str, b: &str) -> String {
    match (a.is_empty(), b.is_empty()) {
        (true, true) => ".".to_string(),
        (_, true) => posix_normalize(a),
        (true, _) => posix_normalize(b),
        _ => posix_normalize(&format!("{a}/{b}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_int_is_lenient_like_javascript() {
        assert_eq!(parse_int("12", 10), Some(12));
        assert_eq!(parse_int("  12abc", 10), Some(12));
        assert_eq!(parse_int("-3", 10), Some(-3));
        assert_eq!(parse_int("+7", 10), Some(7));
        assert_eq!(parse_int("abc", 10), None);
        assert_eq!(parse_int("", 10), None);
        assert_eq!(parse_int("0x10", 10), Some(0));
        assert_eq!(parse_int("777", 8), Some(511));
        assert_eq!(parse_int("789", 8), Some(7));
        assert_eq!(parse_int("1.9", 10), Some(1));
    }

    #[test]
    fn strict_utf8_drops_a_byte_order_mark_and_refuses_invalid_bytes() {
        assert_eq!(decode_utf8(b"abc").as_deref(), Some("abc"));
        assert_eq!(decode_utf8(b"\xef\xbb\xbfabc").as_deref(), Some("abc"));
        assert_eq!(decode_utf8(b"ab\xffc"), None);
        assert_eq!(decode_utf8(b"\xef\xbb\xbf\xef\xbb\xbfx").as_deref(), Some("\u{feff}x"), "only the first mark");
    }

    #[test]
    fn latin1_maps_each_byte_to_the_code_point() {
        assert_eq!(latin1(&[0x41, 0xe9, 0xff]), "A\u{e9}\u{ff}");
    }

    #[test]
    fn posix_normalize_and_join_as_node_does() {
        let table = [
            ("lib/mojo/../libfoo.so", "lib/libfoo.so"),
            ("lib/mojo/libfoo.so", "lib/mojo/libfoo.so"),
            ("lib/mojo/./x", "lib/mojo/x"),
            ("lib/mojo//x", "lib/mojo/x"),
            ("lib/mojo/../../x", "x"),
            ("lib/mojo/../../../x", "../x"),
            ("lib/mojo/sub/../", "lib/mojo/"),
            ("a/..", "."),
            ("a/../", "./"),
            ("/a/../..", "/"),
        ];
        for (input, want) in table {
            assert_eq!(posix_normalize(input), want, "{input}");
        }
        assert_eq!(posix_join("lib/mojo", "../libfoo.so"), "lib/libfoo.so");
        assert_eq!(posix_join("lib/mojo", ""), "lib/mojo");
        assert_eq!(posix_join("lib/mojo", "/abs"), "lib/mojo/abs");
        assert_eq!(posix_join("lib/mojo", "a/b"), "lib/mojo/a/b");
    }

    #[test]
    fn is_space_is_the_ecmascript_set() {
        for c in ['\t', '\n', '\u{b}', '\u{c}', '\r', ' ', '\u{a0}', '\u{feff}', '\u{2028}', '\u{3000}'] {
            assert!(is_space(c), "{c:?}");
        }
        assert!(!is_space('\u{85}'), "NEL is not JavaScript white space");
        assert!(!is_space('a'));
    }
}
