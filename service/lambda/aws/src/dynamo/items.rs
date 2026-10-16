//! Items: the DynamoDB rows of the records, and back. Rows are built as JSON and marshalled by
//! `serde_dynamo` (numbers are `N`, strings `S`, absent members absent), so a row has exactly the
//! attributes written here.

use std::collections::HashMap;

use aws_sdk_dynamodb::types::AttributeValue;
use mopm_ports::error::{PortError, PortResult};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{Map, Value};

pub(crate) type Item = HashMap<String, AttributeValue>;

pub(crate) fn s(v: impl Into<String>) -> AttributeValue {
    AttributeValue::S(v.into())
}

pub(crate) fn n(v: impl ToString) -> AttributeValue {
    AttributeValue::N(v.to_string())
}

pub(crate) fn names<const N: usize>(pairs: [(&str, &str); N]) -> HashMap<String, String> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

pub(crate) fn values<const N: usize>(pairs: [(&str, AttributeValue); N]) -> Item {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

/// The JSON object of a record.
pub(crate) fn object<T: Serialize>(rec: &T) -> PortResult<Map<String, Value>> {
    match serde_json::to_value(rec).map_err(PortError::fault)? {
        Value::Object(m) => Ok(m),
        other => Err(PortError::fault(format!("a record is a JSON object, not {other}"))),
    }
}

pub(crate) fn to_item(m: Map<String, Value>) -> PortResult<Item> {
    serde_dynamo::to_item(Value::Object(m)).map_err(PortError::fault)
}

pub(crate) fn from_item(i: Item) -> PortResult<Map<String, Value>> {
    match serde_dynamo::from_item::<_, Value>(i).map_err(PortError::fault)? {
        Value::Object(m) => Ok(m),
        other => Err(PortError::fault(format!("an item is a JSON object, not {other}"))),
    }
}

/// A record out of a JSON object.
pub(crate) fn record<T: DeserializeOwned>(m: Map<String, Value>) -> PortResult<T> {
    serde_json::from_value(Value::Object(m)).map_err(PortError::fault)
}

/// Epoch seconds of an ISO-8601 time with milliseconds, as `Math.floor(Date.parse(iso) / 1000)`.
pub(crate) fn epoch_seconds(iso: &str) -> PortResult<i64> {
    let ts: jiff::Timestamp = iso.parse().map_err(|e| PortError::fault(format!("not a time: {iso}: {e}")))?;
    Ok(ts.as_millisecond().div_euclid(1000))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_json_object_becomes_an_item_with_strings_and_numbers() {
        let i = to_item(json!({"a": "x", "b": 3, "c": true, "d": ["p", 1], "e": {"f": null}}).as_object().unwrap().clone()).unwrap();
        assert_eq!(i["a"], AttributeValue::S("x".into()));
        assert_eq!(i["b"], AttributeValue::N("3".into()));
        assert_eq!(i["c"], AttributeValue::Bool(true));
        assert_eq!(i["d"], AttributeValue::L(vec![AttributeValue::S("p".into()), AttributeValue::N("1".into())]));
        assert_eq!(i["e"], AttributeValue::M(HashMap::from([("f".to_string(), AttributeValue::Null(true))])));
    }

    #[test]
    fn an_item_reads_back_to_the_same_json() {
        let m = json!({"name": "p", "rev": 7, "files": [{"size": 1000}], "state": "published"}).as_object().unwrap().clone();
        assert_eq!(from_item(to_item(m.clone()).unwrap()).unwrap(), m);
    }

    #[test]
    fn epoch_seconds_floors_like_javascript() {
        assert_eq!(epoch_seconds("2026-11-13T12:00:00.123Z").unwrap(), 1_794_571_200);
        assert_eq!(epoch_seconds("2026-11-13T12:00:00.999Z").unwrap(), 1_794_571_200);
        assert_eq!(epoch_seconds("1969-12-31T23:59:59.500Z").unwrap(), -1, "floor, not truncate");
        assert!(epoch_seconds("tomorrow").is_err());
    }
}
