//! Deterministic JSON, byte for byte what `canonicalJson` of the TypeScript registry writes: object
//! keys sorted at every depth, compact separators, and numbers that are safe integers (the
//! index never carries a float, and refusing one is what makes number formatting stable).
//!
//! Two things are JavaScript's and are reproduced on purpose:
//!
//! * `Object.keys(o).sort()` orders keys by UTF-16 code unit, not by byte or code point: a
//!   character outside the Basic Multilingual Plane (a surrogate pair, `D800..DFFF`) sorts BEFORE
//!   `U+E000..U+FFFF`, where UTF-8 order puts it after;
//! * a JavaScript object enumerates its array-index keys (`"0"`, `"7"`, `"10"`: canonical
//!   decimal integers below 2^32 - 1) first, in numeric order, whatever order they were
//!   inserted in, so `{"10":..,"9":..,"a":..}` is written `9`, `10`, `a`.

use std::cmp::Ordering;

use serde_json::{Map, Number, Value};
use thiserror::Error;

/// The largest integer JavaScript represents exactly, 2^53 - 1.
const MAX_SAFE: u64 = 9_007_199_254_740_991;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum CanonicalJsonError {
    #[error("canonicalJson: {0} is not a safe integer")]
    NotSafeInteger(String),
}

/// Orders strings by UTF-16 code unit (JavaScript's default `sort`).
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// The array index a key denotes in JavaScript, if it denotes one.
fn array_index(k: &str) -> Option<u32> {
    let canonical = !k.is_empty() && k.bytes().all(|b| b.is_ascii_digit()) && (k == "0" || !k.starts_with('0'));
    if !canonical || k.len() > 10 {
        return None;
    }
    k.parse::<u32>().ok().filter(|n| *n != u32::MAX)
}

fn safe_integer(n: &Number) -> Result<i64, CanonicalJsonError> {
    if let Some(i) = n.as_i64() {
        if i.unsigned_abs() <= MAX_SAFE {
            return Ok(i);
        }
    } else if let Some(u) = n.as_u64() {
        if u <= MAX_SAFE {
            return Ok(u as i64);
        }
    } else if let Some(f) = n.as_f64() {
        // `1.0` is the number 1 in JavaScript.
        if f.is_finite() && f.fract() == 0.0 && f.abs() <= MAX_SAFE as f64 {
            return Ok(f as i64);
        }
    }
    Err(CanonicalJsonError::NotSafeInteger(n.to_string()))
}

fn ordered_keys(o: &Map<String, Value>) -> Vec<&String> {
    let mut indices: Vec<(u32, &String)> = Vec::new();
    let mut others: Vec<&String> = Vec::new();
    for k in o.keys() {
        match array_index(k) {
            Some(i) => indices.push((i, k)),
            None => others.push(k),
        }
    }
    indices.sort_by_key(|(i, _)| *i);
    others.sort_by(|a, b| cmp_utf16(a, b));
    indices.into_iter().map(|(_, k)| k).chain(others).collect()
}

fn write(v: &Value, out: &mut String) -> Result<(), CanonicalJsonError> {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&safe_integer(n)?.to_string()),
        Value::String(s) => out.push_str(&serde_json::to_string(s).expect("a string serialises")),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write(item, out)?;
            }
            out.push(']');
        }
        Value::Object(o) => {
            out.push('{');
            for (i, k) in ordered_keys(o).into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(k).expect("a string serialises"));
                out.push(':');
                write(&o[k], out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

/// The canonical text of `value`.
pub fn canonical_json(value: &Value) -> Result<String, CanonicalJsonError> {
    let mut out = String::new();
    write(value, &mut out)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sorts_keys_at_every_depth() {
        // service/api/test/repodata.test.ts: { b: 1, a: { d: [{ z: 1, y: 2 }], c: undefined } } (undefined is
        // dropped before the value reaches here).
        let v = json!({"b": 1, "a": {"d": [{"z": 1, "y": 2}]}});
        assert_eq!(canonical_json(&v).unwrap(), r#"{"a":{"d":[{"y":2,"z":1}]},"b":1}"#);
    }

    #[test]
    fn writes_scalars_and_empty_containers() {
        assert_eq!(canonical_json(&json!({})).unwrap(), "{}");
        assert_eq!(canonical_json(&json!([])).unwrap(), "[]");
        assert_eq!(canonical_json(&json!([null, true, false, 0, -7, "x"])).unwrap(), r#"[null,true,false,0,-7,"x"]"#);
    }

    #[test]
    fn refuses_what_is_not_a_safe_integer() {
        for text in ["1.5", "9007199254740992", "-9007199254740992", "1152921504606846976"] {
            let v: Value = serde_json::from_str(&format!("{{\"n\":{text}}}")).unwrap();
            assert_eq!(canonical_json(&v).unwrap_err(), CanonicalJsonError::NotSafeInteger(text.to_string()), "{text}");
        }
        assert_eq!(canonical_json(&json!({"n": 1.5})).unwrap_err().to_string(), "canonicalJson: 1.5 is not a safe integer");
    }

    #[test]
    fn the_safe_range_ends_at_two_to_the_53_minus_one() {
        assert_eq!(
            canonical_json(&json!([9007199254740991u64, -9007199254740991i64])).unwrap(),
            "[9007199254740991,-9007199254740991]"
        );
    }

    #[test]
    fn a_float_with_an_integer_value_is_that_integer_as_in_javascript() {
        let v: Value = serde_json::from_str(r#"[1.0, -0.0, 2e3, 5.50e1]"#).unwrap();
        assert_eq!(canonical_json(&v).unwrap(), "[1,0,2000,55]");
    }

    #[test]
    fn keys_sort_by_utf16_code_unit_not_by_code_point() {
        // U+1F600 is the surrogate pair D83D DE00; U+FF5E is the single unit FF5E. UTF-16 order puts the
        // emoji FIRST; UTF-8 and code point order put it last.
        let v = json!({"\u{ff5e}": 1, "\u{1f600}": 2, "a": 3, "\u{e9}": 4});
        assert_eq!(canonical_json(&v).unwrap(), "{\"a\":3,\"\u{e9}\":4,\"\u{1f600}\":2,\"\u{ff5e}\":1}");
        assert!("\u{1f600}".as_bytes() > "\u{ff5e}".as_bytes(), "the premise: UTF-8 order is the other way");
    }

    #[test]
    fn array_index_keys_come_first_in_numeric_order_as_a_javascript_object_enumerates_them() {
        let v = json!({"b": 1, "10": 2, "9": 3, "a": 4, "007": 5, "0": 6, "4294967295": 7, "4294967294": 8});
        // Indices (0, 9, 10, 4294967294), then the rest sorted: "007" has a leading zero, 4294967295 is not an index.
        assert_eq!(
            canonical_json(&v).unwrap(),
            r#"{"0":6,"9":3,"10":2,"4294967294":8,"007":5,"4294967295":7,"a":4,"b":1}"#
        );
    }

    #[test]
    fn escapes_strings_as_json_stringify_does() {
        let v = json!({"k": "q\"b\\n\n\t\u{1}\u{1f}\u{7f}\u{2028}\u{e9}\u{1f600}"});
        assert_eq!(
            canonical_json(&v).unwrap(),
            "{\"k\":\"q\\\"b\\\\n\\n\\t\\u0001\\u001f\u{7f}\u{2028}\u{e9}\u{1f600}\"}"
        );
    }

    #[test]
    fn is_idempotent_through_a_parse() {
        let v = json!({"z": [1, {"y": null, "x": "s"}], "a": {"c": 3, "b": 2}});
        let once = canonical_json(&v).unwrap();
        let again = canonical_json(&serde_json::from_str(&once).unwrap()).unwrap();
        assert_eq!(once, again);
    }
}
