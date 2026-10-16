//! Versions: `MAJOR.MINOR.PATCH`, exactly three numbers separated by dots, no leading zeros,
//! nothing else. There is one spelling of a version, so equality is string equality; the
//! grammar is `Version` in spec/api/openapi.yaml.

use std::cmp::Ordering;

use crate::error::{invalid_version, RegistryError};

/// The sort key of a version is stored in DynamoDB (1024 byte limit); the spec sets no length, so this is ours.
pub const MAX_VERSION_LENGTH: usize = 128;

/// A decimal number of any length without leading zeros, ordered numerically.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Number(String);

impl Number {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Ord for Number {
    fn cmp(&self, other: &Self) -> Ordering {
        // No leading zeros, so a longer number is a larger one.
        self.0.len().cmp(&other.0.len()).then_with(|| self.0.cmp(&other.0))
    }
}

impl PartialOrd for Number {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// A version that passed the grammar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedVersion {
    /// major, minor, patch
    pub release: [Number; 3],
    /// The version itself: one version has one spelling.
    pub canonical: String,
}

impl Ord for ParsedVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        self.release.cmp(&other.release)
    }
}

impl PartialOrd for ParsedVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn component(s: &str) -> Option<Number> {
    let ok = !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && (s == "0" || !s.starts_with('0'));
    ok.then(|| Number(s.to_string()))
}

/// Parses `input`; anything but the grammar is `invalid_version`.
pub fn parse_version(input: &str) -> Result<ParsedVersion, RegistryError> {
    let parts: Vec<&str> = input.split('.').collect();
    if input.len() <= MAX_VERSION_LENGTH && parts.len() == 3 {
        if let (Some(a), Some(b), Some(c)) = (component(parts[0]), component(parts[1]), component(parts[2])) {
            return Ok(ParsedVersion { release: [a, b, c], canonical: input.to_string() });
        }
    }
    Err(invalid_version(input))
}

pub fn is_valid_version(s: &str) -> bool {
    parse_version(s).is_ok()
}

/// The key a version is stored under (its only spelling). `invalid_version` when `s` is not one.
pub fn canonical_version(s: &str) -> Result<String, RegistryError> {
    parse_version(s).map(|v| v.canonical)
}

/// Numeric order of major, then minor, then patch.
pub fn compare_versions(a: &str, b: &str) -> Result<Ordering, RegistryError> {
    Ok(parse_version(a)?.cmp(&parse_version(b)?))
}

pub fn versions_equivalent(a: &str, b: &str) -> Result<bool, RegistryError> {
    Ok(compare_versions(a, b)? == Ordering::Equal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    // The accepted and refused spellings, as in service/api/test/version.test.ts.
    const ACCEPTED: &[&str] = &["0.0.0", "1.0.0", "0.4.0", "10.20.30", "1.10.100", "99999999999999999999.0.1"];
    const REFUSED: &[&str] = &[
        "", "0", "1", "1.0", "1.2.3.4", "1.0.0.0", "1.", ".1", "1..0", "1.0.",
        "1.0rc1", "1.0.0rc1", "1.0.0-rc.1", "1.0.0-rc1", "1.0a1", "1.0.0a1", "1.0.0b2", "1.0.0dev", "1.0.0.dev1",
        "1.0.0.post1", "1.0.0+local", "1!2.0.0", "dev", "v1.0.0", "1.0.x", "1.0.0A1",
        "01.0.0", "1.00.0", "1.0.00", " 1.0.0", "1.0.0 ", "1.0.0\n",
        "1.0.\u{663}", // an Arabic-Indic digit is not an ASCII digit
    ];

    #[test]
    fn accepts_exactly_three_plain_numbers() {
        for v in ACCEPTED {
            assert!(is_valid_version(v), "{v}");
        }
    }

    #[test]
    fn refuses_every_other_spelling_with_invalid_version() {
        for v in REFUSED {
            assert!(!is_valid_version(v), "{v:?}");
            let err = parse_version(v).unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidVersion, "{v:?}");
            assert_eq!(err.status(), 400);
            assert_eq!(err.message, format!("'{v}' is not a valid version."));
            assert_eq!(err.detail.get("version").map(String::as_str), Some(*v));
        }
    }

    #[test]
    fn refuses_a_version_over_the_length_limit() {
        assert!(!is_valid_version(&format!("1.0.{}", "9".repeat(200))));
        // The limit itself: 128 bytes pass, 129 do not.
        let at = format!("1.0.{}", "9".repeat(MAX_VERSION_LENGTH - 4));
        assert_eq!(at.len(), MAX_VERSION_LENGTH);
        assert!(is_valid_version(&at));
        assert!(!is_valid_version(&format!("{at}9")));
    }

    #[test]
    fn a_version_has_one_spelling() {
        assert_eq!(canonical_version("1.2.3").unwrap(), "1.2.3");
        assert_eq!(canonical_version("1.2").unwrap_err().code, ErrorCode::InvalidVersion);
    }

    #[test]
    fn orders_numerically_by_major_minor_patch() {
        let table: &[(&str, &str, Ordering)] = &[
            ("1.0.0", "1.0.0", Ordering::Equal),
            ("1.0.0", "1.0.1", Ordering::Less),
            ("1.9.0", "1.10.0", Ordering::Less),
            ("1.0.9", "1.0.10", Ordering::Less),
            ("2.0.0", "1.99.99", Ordering::Greater),
            ("99999999999999999999.0.0", "99999999999999999998.0.0", Ordering::Greater),
        ];
        for (a, b, want) in table {
            assert_eq!(compare_versions(a, b).unwrap(), *want, "{a} {b}");
            assert_eq!(compare_versions(b, a).unwrap(), want.reverse(), "{b} {a}");
            assert_eq!(versions_equivalent(a, b).unwrap(), *want == Ordering::Equal);
        }
    }

    #[test]
    fn comparing_an_invalid_version_is_an_error() {
        assert_eq!(compare_versions("1.0", "1.0.0").unwrap_err().code, ErrorCode::InvalidVersion);
        assert_eq!(compare_versions("1.0.0", "x").unwrap_err().code, ErrorCode::InvalidVersion);
    }

    #[test]
    fn the_order_agrees_with_comparing_the_three_integers() {
        // Every pair of a grid that crosses digit counts (9 and 10, 99 and 100).
        let mut all = Vec::new();
        for a in 0..4u32 {
            for b in 0..12u32 {
                for c in [0u32, 1, 9, 10, 11, 100] {
                    all.push((a, b, c));
                }
            }
        }
        for x in &all {
            for y in &all {
                let want = x.cmp(y);
                let got = compare_versions(&format!("{}.{}.{}", x.0, x.1, x.2), &format!("{}.{}.{}", y.0, y.1, y.2)).unwrap();
                assert_eq!(got, want, "{x:?} {y:?}");
            }
        }
    }
}
