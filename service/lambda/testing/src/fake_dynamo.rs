//! A DynamoDB on loopback, strict enough to catch what a real table would refuse, for the adapters'
//! tests. The SDK talks to it over HTTP exactly as to the real service (JSON 1.0, signed requests), so
//! what is held is the adapter AND the SDK's serialisation.
//!
//! Operations: GetItem, PutItem, DeleteItem, UpdateItem, Query (a table or an index, paged), Scan (paged),
//! TransactWriteItems (Puts only: all conditions checked, then all writes, atomically). Expressions: the
//! forms the adapters use (`attribute_exists`, `attribute_not_exists`, `#x = :v` joined by AND; `SET a = :v,
//! ...` with an optional `REMOVE`; key conditions `#p = :p`, with `AND begins_with(#s, :v)` or `AND #s = :v`).
//! Anything else is a `ValidationException` naming it, so a new expression in an adapter fails here instead
//! of being accepted. As DynamoDB does, it also refuses: a raw attribute name in an expression (reserved
//! words), an `ExpressionAttributeNames`/`Values` entry no expression uses, an empty `begins_with` operand,
//! a key or index key attribute that is not a string, a TTL attribute that is not a number, two writes to
//! one item in a transaction, a transaction without a `ClientRequestToken`, and an `ExclusiveStartKey`
//! outside the query.
//!
//! Requests are handled one at a time under one lock, but arrive over separate connections, so two
//! callers' read and write do interleave as against a real table.

use std::collections::{BTreeMap, BTreeSet};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Map, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

type Item = Map<String, Value>;

#[derive(Clone, Debug)]
pub struct IndexDef {
    pub name: String,
    pub pk: String,
    pub sk: String,
    /// The non-key attributes the index carries; `None`: all of them.
    pub projected: Option<Vec<String>>,
}

#[derive(Clone, Debug)]
pub struct TableDef {
    pub name: String,
    pub pk: String,
    pub sk: Option<String>,
    pub indexes: Vec<IndexDef>,
    /// The time-to-live attribute: a number when present.
    pub ttl: Option<String>,
}

fn table(stage_prefix: &str, name: &str, pk: &str, sk: Option<&str>, ttl: Option<&str>, indexes: Vec<IndexDef>) -> TableDef {
    TableDef { name: format!("{stage_prefix}{name}"), pk: pk.into(), sk: sk.map(Into::into), indexes, ttl: ttl.map(Into::into) }
}

/// The tables of the data stack (service/infra/stacks/lib/data-stack.ts) for `mopm-<stage>-`.
pub fn registry_tables(stage: &str) -> Vec<TableDef> {
    let p = format!("mopm-{stage}-");
    let search = IndexDef { name: "by_search_bucket".into(), pk: "search_bucket".into(), sk: "name".into(), projected: Some(vec!["description".into(), "state".into(), "created_at".into()]) };
    let by_account = IndexDef { name: "by_github_id".into(), pk: "github_id".into(), sk: "id".into(), projected: None };
    let owned = IndexDef { name: "by_github_id".into(), pk: "github_id".into(), sk: "name".into(), projected: None };
    vec![
        table(&p, "packages", "name", None, None, vec![search]),
        table(&p, "versions", "name", Some("version"), None, vec![]),
        table(&p, "owners", "name", Some("github_id"), None, vec![owned]),
        table(&p, "audit", "name", Some("ts_seq"), None, vec![]),
        table(&p, "users", "github_id", None, None, vec![]),
        table(&p, "tokens", "token_hash", None, Some("expires_at"), vec![by_account]),
        table(&p, "device_logins", "id", None, Some("expires_at"), vec![]),
        table(&p, "trusted_publishers", "name", Some("publisher"), None, vec![]),
        table(&p, "uploads", "upload_id", None, Some("expires_at"), vec![]),
        table(&p, "publishes", "publish_id", None, Some("expires_at"), vec![]),
        table(&p, "config", "key", None, None, vec![]),
    ]
}

/// What a role may call, per table (`service/api/test/fixtures/lambda-auth-grants.json`):
/// `{ "<table>": { "actions": ["dynamodb:GetItem", ...], "indexes": ["by_github_id"] } }`. A table the grants do
/// not list is denied entirely.
#[derive(Clone, Debug, Default)]
pub struct Grants(BTreeMap<String, (BTreeSet<String>, BTreeSet<String>)>);

impl Grants {
    pub fn parse(text: &str) -> Result<Grants, serde_json::Error> {
        let v: Value = serde_json::from_str(text)?;
        let mut m = BTreeMap::new();
        for (table, g) in v.as_object().cloned().unwrap_or_default() {
            let list = |k: &str| g.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
            m.insert(table, (list("actions"), list("indexes")));
        }
        Ok(Grants(m))
    }
}

#[derive(Clone, Debug)]
pub struct FakeConfig {
    pub tables: Vec<TableDef>,
    /// At most this many items a Query or Scan page returns, as DynamoDB pages by size.
    pub page_size: usize,
    pub grants: Option<(String, Grants)>,
}

impl FakeConfig {
    /// All tables of the data stack for `stage`, pages of two, no grants.
    pub fn registry(stage: &str) -> FakeConfig {
        FakeConfig { tables: registry_tables(stage), page_size: 2, grants: None }
    }

    /// Restrict the role to `grants`; table names are `<prefix><table>`.
    pub fn with_grants(mut self, prefix: &str, grants: Grants) -> FakeConfig {
        self.grants = Some((prefix.to_string(), grants));
        self
    }
}

/// A request the fake saw.
#[derive(Clone, Debug)]
pub struct Recorded {
    pub operation: String,
    pub body: Value,
    pub signed: bool,
}

#[derive(Default)]
struct State {
    /// table name -> ((partition, sort), item)
    tables: BTreeMap<String, BTreeMap<(String, String), Item>>,
    requests: Vec<Recorded>,
}

struct Shared {
    cfg: FakeConfig,
    state: Mutex<State>,
}

pub struct FakeDynamo {
    addr: SocketAddr,
    shared: Arc<Shared>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for FakeDynamo {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl FakeDynamo {
    /// Binds a loopback port and serves on the current tokio runtime (so it must be called inside one).
    pub fn start(cfg: FakeConfig) -> FakeDynamo {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        std_listener.set_nonblocking(true).expect("a non-blocking listener");
        let addr = std_listener.local_addr().expect("a local address");
        let listener = TcpListener::from_std(std_listener).expect("a tokio listener");
        let mut state = State::default();
        for t in &cfg.tables {
            state.tables.insert(t.name.clone(), BTreeMap::new());
        }
        let shared = Arc::new(Shared { cfg, state: Mutex::new(state) });
        let accept = shared.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { return };
                tokio::spawn(serve(accept.clone(), stream));
            }
        });
        FakeDynamo { addr, shared, task }
    }

    pub fn endpoint(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.shared.state.lock().expect("a lock is never held across a panic")
    }

    /// Every request, oldest first.
    pub fn requests(&self) -> Vec<Recorded> {
        self.lock().requests.clone()
    }

    /// The operations asked of the service, in order (`GetItem`, `TransactWriteItems`, ...).
    pub fn operations(&self) -> Vec<String> {
        self.lock().requests.iter().map(|r| r.operation.clone()).collect()
    }

    pub fn clear_requests(&self) {
        self.lock().requests.clear();
    }

    /// The items of a table in key order, as DynamoDB JSON.
    pub fn dump(&self, table: &str) -> Vec<Value> {
        self.lock().tables.get(table).map(|t| t.values().map(|i| Value::Object(i.clone())).collect()).unwrap_or_default()
    }

    /// Put an item (DynamoDB JSON) without any check, as data that was there before.
    pub fn seed(&self, table: &str, item: Value) {
        let def = self.shared.cfg.tables.iter().find(|t| t.name == table).expect("a table of the fake");
        let item = item.as_object().cloned().expect("an item is an object");
        let key = key_of(def, &item).expect("a seeded item has its key");
        self.lock().tables.get_mut(table).expect("a table of the fake").insert(key, item);
    }
}

// ---- HTTP ------------------------------------------------------------------------------------------

async fn serve(shared: Arc<Shared>, mut stream: TcpStream) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let (head, body_start) = loop {
        let Ok(n) = stream.read(&mut chunk).await else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break (String::from_utf8_lossy(&buf[..i]).to_string(), i + 4);
        }
    };
    let header = |name: &str| -> Option<String> {
        head.lines().skip(1).find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
        })
    };
    let len: usize = header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    while buf.len() < body_start + len {
        let Ok(n) = stream.read(&mut chunk).await else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body: Value = serde_json::from_slice(&buf[body_start..body_start + len]).unwrap_or(Value::Null);
    let operation = header("x-amz-target").and_then(|t| t.rsplit('.').next().map(str::to_string)).unwrap_or_default();
    let signed = header("authorization").is_some_and(|a| a.starts_with("AWS4-HMAC-SHA256 ") && a.contains("SignedHeaders="));
    let (status, reply) = {
        let mut st = shared.state.lock().expect("a lock is never held across a panic");
        st.requests.push(Recorded { operation: operation.clone(), body: body.clone(), signed });
        match handle(&shared.cfg, &mut st, &operation, &body) {
            Ok(v) => (200, v),
            Err(f) => (400, f.json()),
        }
    };
    let text = reply.to_string();
    let response = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/x-amz-json-1.0\r\nx-amzn-RequestId: fake-request\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
        if status == 200 { "OK" } else { "Bad Request" },
        text.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ---- failures --------------------------------------------------------------------------------------

#[derive(Debug)]
enum Fail {
    Validation(String),
    ConditionFailed,
    AccessDenied(String),
    Cancelled(Vec<bool>),
}

impl Fail {
    fn validation(msg: impl Into<String>) -> Fail {
        Fail::Validation(msg.into())
    }

    fn json(&self) -> Value {
        match self {
            Fail::Validation(m) => json!({"__type": "com.amazon.coral.validate#ValidationException", "message": m}),
            Fail::ConditionFailed => json!({"__type": "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException", "message": "The conditional request failed"}),
            Fail::AccessDenied(m) => json!({"__type": "com.amazon.coral.service#AccessDeniedException", "Message": m}),
            Fail::Cancelled(failed) => {
                let reasons: Vec<Value> = failed
                    .iter()
                    .map(|f| if *f { json!({"Code": "ConditionalCheckFailed", "Message": "The conditional request failed"}) } else { json!({"Code": "None"}) })
                    .collect();
                let codes: Vec<&str> = failed.iter().map(|f| if *f { "ConditionalCheckFailed" } else { "None" }).collect();
                json!({
                    "__type": "com.amazonaws.dynamodb.v20120810#TransactionCanceledException",
                    "message": format!("Transaction cancelled, please refer cancellation reasons for specific reasons [{}]", codes.join(", ")),
                    "CancellationReasons": reasons
                })
            }
        }
    }
}

// ---- operations ------------------------------------------------------------------------------------

fn str_of<'a>(v: &'a Value, key: &str) -> Result<&'a str, Fail> {
    v.get(key).and_then(Value::as_str).ok_or_else(|| Fail::validation(format!("{key} is required")))
}

fn table_def<'a>(cfg: &'a FakeConfig, name: &str) -> Result<&'a TableDef, Fail> {
    cfg.tables.iter().find(|t| t.name == name).ok_or_else(|| Fail::validation(format!("Requested resource not found: table {name}")))
}

fn attr_s(item: &Item, name: &str) -> Option<String> {
    item.get(name).and_then(|v| v.get("S")).and_then(Value::as_str).map(str::to_string)
}

fn key_of(def: &TableDef, item: &Item) -> Result<(String, String), Fail> {
    let part = attr_s(item, &def.pk).ok_or_else(|| Fail::validation(format!("One or more parameter values were invalid: Type mismatch for key {} expected: S", def.pk)))?;
    let sort = match &def.sk {
        Some(sk) => attr_s(item, sk).ok_or_else(|| Fail::validation(format!("One or more parameter values were invalid: Type mismatch for key {sk} expected: S")))?,
        None => String::new(),
    };
    Ok((part, sort))
}

fn item_of(v: &Value, key: &str) -> Result<Item, Fail> {
    v.get(key).and_then(Value::as_object).cloned().ok_or_else(|| Fail::validation(format!("{key} is required")))
}

/// Checks a written item against the table: its key, its index keys and its TTL attribute.
fn check_item(def: &TableDef, item: &Item) -> Result<(), Fail> {
    key_of(def, item)?;
    for ix in &def.indexes {
        for a in [&ix.pk, &ix.sk] {
            if let Some(v) = item.get(a) {
                if v.get("S").is_none() {
                    return Err(Fail::validation(format!("One or more parameter values were invalid: Type mismatch for Index Key {a} Expected: S")));
                }
            }
        }
    }
    if let Some(ttl) = &def.ttl {
        if let Some(v) = item.get(ttl) {
            if v.get("N").is_none() {
                return Err(Fail::validation(format!("TimeToLive attribute {ttl} must be a number")));
            }
        }
    }
    Ok(())
}

/// The `#name` and `:value` tokens of expression texts.
fn tokens(exprs: &[&str]) -> (BTreeSet<String>, BTreeSet<String>) {
    let (mut n, mut v) = (BTreeSet::new(), BTreeSet::new());
    for e in exprs {
        let b = e.as_bytes();
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'#' || b[i] == b':' {
                let start = i;
                i += 1;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                let t = e[start..i].to_string();
                if b[start] == b'#' { n.insert(t); } else { v.insert(t); }
            } else {
                i += 1;
            }
        }
    }
    (n, v)
}

struct Exprs<'a> {
    names: Map<String, Value>,
    values: Map<String, Value>,
    texts: Vec<&'a str>,
}

impl<'a> Exprs<'a> {
    fn new(req: &'a Value, keys: &[&str]) -> Result<Exprs<'a>, Fail> {
        let texts: Vec<&str> = keys.iter().filter_map(|k| req.get(*k).and_then(Value::as_str)).collect();
        let e = Exprs {
            names: req.get("ExpressionAttributeNames").and_then(Value::as_object).cloned().unwrap_or_default(),
            values: req.get("ExpressionAttributeValues").and_then(Value::as_object).cloned().unwrap_or_default(),
            texts,
        };
        let (used_n, used_v) = tokens(&e.texts);
        for n in e.names.keys() {
            if !used_n.contains(n) {
                return Err(Fail::validation(format!("Value provided in ExpressionAttributeNames unused in expressions: keys: {{{n}}}")));
            }
        }
        for v in e.values.keys() {
            if !used_v.contains(v) {
                return Err(Fail::validation(format!("Value provided in ExpressionAttributeValues unused in expressions: keys: {{{v}}}")));
            }
        }
        for n in used_n {
            if !e.names.contains_key(&n) {
                return Err(Fail::validation(format!("An expression attribute name used in the document path is not defined; attribute name: {n}")));
            }
        }
        for v in used_v {
            if !e.values.contains_key(&v) {
                return Err(Fail::validation(format!("An expression attribute value used in expression is not defined; attribute value: {v}")));
            }
        }
        Ok(e)
    }

    fn name(&self, t: &str) -> Result<String, Fail> {
        if !t.starts_with('#') {
            return Err(Fail::validation(format!("Attribute name is a reserved keyword or not a placeholder: {t}")));
        }
        self.names.get(t).and_then(Value::as_str).map(str::to_string).ok_or_else(|| Fail::validation(format!("undefined name {t}")))
    }

    fn value(&self, t: &str) -> Result<&Value, Fail> {
        self.values.get(t).ok_or_else(|| Fail::validation(format!("undefined value {t}")))
    }

    /// `attribute_not_exists(#x)`, `attribute_exists(#x)` and `#x = :v`, joined by AND.
    fn holds(&self, cond: Option<&str>, existing: Option<&Item>) -> Result<bool, Fail> {
        let Some(cond) = cond else { return Ok(true) };
        let mut all = true;
        for clause in cond.split(" AND ") {
            let c = clause.trim();
            let ok = if let Some(x) = c.strip_prefix("attribute_not_exists(").and_then(|r| r.strip_suffix(')')) {
                let a = self.name(x)?;
                !existing.is_some_and(|i| i.contains_key(&a))
            } else if let Some(x) = c.strip_prefix("attribute_exists(").and_then(|r| r.strip_suffix(')')) {
                let a = self.name(x)?;
                existing.is_some_and(|i| i.contains_key(&a))
            } else if let Some((l, r)) = c.split_once(" = ") {
                let a = self.name(l.trim())?;
                let want = self.value(r.trim())?;
                existing.is_some_and(|i| i.get(&a) == Some(want))
            } else {
                return Err(Fail::validation(format!("fake: unsupported condition {c}")));
            };
            all &= ok;
        }
        Ok(all)
    }
}

fn check_grant(cfg: &FakeConfig, table: &str, action: &str, index: Option<&str>) -> Result<(), Fail> {
    let Some((prefix, grants)) = &cfg.grants else { return Ok(()) };
    let logical = table.strip_prefix(prefix.as_str()).unwrap_or(table);
    let denied = |what: &str| Fail::AccessDenied(format!("User is not authorized to perform: {what} on resource: {table}"));
    let Some((actions, indexes)) = grants.0.get(logical) else { return Err(denied(action)) };
    if !actions.contains(action) {
        return Err(denied(action));
    }
    if let Some(ix) = index {
        if !indexes.contains(ix) {
            return Err(denied(&format!("{action} on index {ix}")));
        }
    }
    Ok(())
}

fn handle(cfg: &FakeConfig, st: &mut State, op: &str, req: &Value) -> Result<Value, Fail> {
    match op {
        "GetItem" => {
            let t = str_of(req, "TableName")?;
            let def = table_def(cfg, t)?;
            check_grant(cfg, t, "dynamodb:GetItem", None)?;
            let key = item_of(req, "Key")?;
            let k = key_of(def, &key)?;
            Ok(match st.tables[t].get(&k) {
                Some(i) => json!({"Item": i}),
                None => json!({}),
            })
        }
        "PutItem" => {
            let t = str_of(req, "TableName")?;
            let def = table_def(cfg, t)?;
            check_grant(cfg, t, "dynamodb:PutItem", None)?;
            let item = item_of(req, "Item")?;
            check_item(def, &item)?;
            let e = Exprs::new(req, &["ConditionExpression"])?;
            let k = key_of(def, &item)?;
            if !e.holds(req.get("ConditionExpression").and_then(Value::as_str), st.tables[t].get(&k))? {
                return Err(Fail::ConditionFailed);
            }
            st.tables.get_mut(t).expect("checked").insert(k, item);
            Ok(json!({}))
        }
        "DeleteItem" => {
            let t = str_of(req, "TableName")?;
            let def = table_def(cfg, t)?;
            check_grant(cfg, t, "dynamodb:DeleteItem", None)?;
            let key = item_of(req, "Key")?;
            let k = key_of(def, &key)?;
            let e = Exprs::new(req, &["ConditionExpression"])?;
            if !e.holds(req.get("ConditionExpression").and_then(Value::as_str), st.tables[t].get(&k))? {
                return Err(Fail::ConditionFailed);
            }
            st.tables.get_mut(t).expect("checked").remove(&k);
            Ok(json!({}))
        }
        "UpdateItem" => update_item(cfg, st, req),
        "Query" => query(cfg, st, req),
        "Scan" => scan(cfg, st, req),
        "TransactWriteItems" => transact(cfg, st, req),
        other => Err(Fail::validation(format!("fake: unsupported operation {other}"))),
    }
}

fn update_item(cfg: &FakeConfig, st: &mut State, req: &Value) -> Result<Value, Fail> {
    let t = str_of(req, "TableName")?;
    let def = table_def(cfg, t)?;
    check_grant(cfg, t, "dynamodb:UpdateItem", None)?;
    let key = item_of(req, "Key")?;
    let k = key_of(def, &key)?;
    let e = Exprs::new(req, &["ConditionExpression", "UpdateExpression"])?;
    let current = st.tables[t].get(&k).cloned();
    if !e.holds(req.get("ConditionExpression").and_then(Value::as_str), current.as_ref())? {
        return Err(Fail::ConditionFailed);
    }
    let upd = str_of(req, "UpdateExpression")?;
    let (set_part, remove_part) = match upd.split_once(" REMOVE ") {
        Some((a, b)) => (a, Some(b)),
        None => (upd, None),
    };
    let assignments = set_part.strip_prefix("SET ").ok_or_else(|| Fail::validation(format!("fake: unsupported update {upd}")))?;
    // An update creates the item when there is none, from its key.
    let mut item = current.unwrap_or(key);
    for a in assignments.split(", ") {
        let (l, r) = a.split_once(" = ").ok_or_else(|| Fail::validation(format!("fake: unsupported update {a}")))?;
        item.insert(e.name(l.trim())?, e.value(r.trim())?.clone());
    }
    if let Some(r) = remove_part {
        for a in r.split(", ") {
            item.remove(&e.name(a.trim())?);
        }
    }
    check_item(def, &item)?;
    st.tables.get_mut(t).expect("checked").insert(k, item);
    Ok(json!({}))
}

fn page(items: Vec<Item>, key_attrs: &[String], start: Option<&Item>, limit: usize, page_size: usize) -> Value {
    let from = match start {
        Some(s) => {
            let same = |i: &Item| key_attrs.iter().all(|a| i.get(a) == s.get(a));
            items.iter().position(same).map_or(0, |p| p + 1)
        }
        None => 0,
    };
    let rest = &items[from.min(items.len())..];
    let take = limit.min(page_size);
    let slice = &rest[..take.min(rest.len())];
    let mut out = json!({"Items": slice, "Count": slice.len(), "ScannedCount": slice.len()});
    if rest.len() > take {
        if let Some(last) = slice.last() {
            let lek: Item = key_attrs.iter().filter_map(|a| last.get(a).map(|v| (a.clone(), v.clone()))).collect();
            out["LastEvaluatedKey"] = Value::Object(lek);
        }
    }
    out
}

fn query(cfg: &FakeConfig, st: &State, req: &Value) -> Result<Value, Fail> {
    let t = str_of(req, "TableName")?;
    let def = table_def(cfg, t)?;
    let index = req.get("IndexName").and_then(Value::as_str);
    check_grant(cfg, t, "dynamodb:Query", index)?;
    let e = Exprs::new(req, &["KeyConditionExpression"])?;
    let kc = str_of(req, "KeyConditionExpression")?;
    let limit = match req.get("Limit") {
        None => usize::MAX,
        Some(l) => match l.as_u64() {
            Some(n) if n >= 1 => usize::try_from(n).unwrap_or(usize::MAX),
            _ => return Err(Fail::validation("Limit must be a positive integer")),
        },
    };
    if index.is_some() && req.get("ConsistentRead").and_then(Value::as_bool) == Some(true) {
        return Err(Fail::validation("Consistent reads are not supported on global secondary indexes"));
    }
    let (pk_attr, sk_attr, projected): (String, Option<String>, Option<Vec<String>>) = match index {
        Some(name) => {
            let ix = def.indexes.iter().find(|i| i.name == name).ok_or_else(|| Fail::validation(format!("The table does not have the specified index: {name}")))?;
            (ix.pk.clone(), Some(ix.sk.clone()), ix.projected.clone())
        }
        None => (def.pk.clone(), def.sk.clone(), None),
    };
    // `#p = :p` [AND begins_with(#s, :v) | AND #s = :v]
    let (first, second) = match kc.split_once(" AND ") {
        Some((a, b)) => (a, Some(b)),
        None => (kc, None),
    };
    let (l, r) = first.split_once(" = ").ok_or_else(|| Fail::validation(format!("fake: unsupported key condition {kc}")))?;
    if e.name(l.trim())? != pk_attr {
        return Err(Fail::validation(format!("Query condition missed key schema element: {pk_attr}")));
    }
    let pk_value = e.value(r.trim())?.clone();
    enum Sort {
        None,
        Prefix(String),
        Equals(Value),
    }
    let sort = match second {
        None => Sort::None,
        Some(c) => {
            let c = c.trim();
            if let Some(args) = c.strip_prefix("begins_with(").and_then(|x| x.strip_suffix(')')) {
                let (a, v) = args.split_once(", ").ok_or_else(|| Fail::validation(format!("fake: unsupported key condition {c}")))?;
                if Some(e.name(a.trim())?) != sk_attr {
                    return Err(Fail::validation(format!("begins_with must be on the sort key {sk_attr:?}")));
                }
                match e.value(v.trim())?.get("S").and_then(Value::as_str) {
                    Some(p) if !p.is_empty() => Sort::Prefix(p.to_string()),
                    _ => return Err(Fail::validation("One or more parameter values are not valid: an empty or non-string begins_with operand")),
                }
            } else if let Some((a, v)) = c.split_once(" = ") {
                if Some(e.name(a.trim())?) != sk_attr {
                    return Err(Fail::validation(format!("Query condition missed key schema element: {sk_attr:?}")));
                }
                Sort::Equals(e.value(v.trim())?.clone())
            } else {
                return Err(Fail::validation(format!("fake: unsupported key condition {c}")));
            }
        }
    };
    let start = req.get("ExclusiveStartKey").and_then(Value::as_object).cloned();
    if let Some(s) = &start {
        let outside = s.get(&pk_attr) != Some(&pk_value)
            || match (&sort, &sk_attr) {
                (Sort::Prefix(p), Some(sk)) => !attr_s(s, sk).is_some_and(|v| v.starts_with(p.as_str())),
                _ => false,
            };
        if outside {
            return Err(Fail::validation("The provided starting key is outside query boundaries based on provided conditions"));
        }
    }
    let mut rows: Vec<Item> = st.tables[t]
        .values()
        .filter(|i| i.get(&pk_attr) == Some(&pk_value))
        .filter(|i| match (&sort, &sk_attr) {
            (Sort::Prefix(p), Some(sk)) => attr_s(i, sk).is_some_and(|v| v.starts_with(p.as_str())),
            (Sort::Equals(v), Some(sk)) => i.get(sk) == Some(v),
            _ => true,
        })
        .cloned()
        .collect();
    // Table rows come out in key order already (a BTreeMap); an index orders by its sort key, then the table key.
    if let (Some(_), Some(sk)) = (index, &sk_attr) {
        rows.sort_by(|a, b| {
            let ka = (attr_s(a, sk), attr_s(a, &def.pk), def.sk.as_ref().and_then(|s| attr_s(a, s)));
            let kb = (attr_s(b, sk), attr_s(b, &def.pk), def.sk.as_ref().and_then(|s| attr_s(b, s)));
            ka.cmp(&kb)
        });
    }
    if let Some(keep) = &projected {
        let table_keys = [Some(def.pk.clone()), def.sk.clone()];
        let allowed: BTreeSet<&String> = keep.iter().chain([&pk_attr]).chain(sk_attr.iter()).chain(table_keys.iter().flatten()).collect();
        for r in &mut rows {
            r.retain(|k, _| allowed.contains(k));
        }
    }
    let mut key_attrs = vec![pk_attr.clone()];
    key_attrs.extend(sk_attr.clone());
    if index.is_some() {
        key_attrs.push(def.pk.clone());
        key_attrs.extend(def.sk.clone());
    }
    Ok(page(rows, &key_attrs, start.as_ref(), limit, cfg.page_size))
}

fn scan(cfg: &FakeConfig, st: &State, req: &Value) -> Result<Value, Fail> {
    let t = str_of(req, "TableName")?;
    let def = table_def(cfg, t)?;
    check_grant(cfg, t, "dynamodb:Scan", None)?;
    let e = Exprs::new(req, &["ProjectionExpression"])?;
    let mut rows: Vec<Item> = st.tables[t].values().cloned().collect();
    if let Some(p) = req.get("ProjectionExpression").and_then(Value::as_str) {
        let keep: Vec<String> = p.split(',').map(|x| e.name(x.trim())).collect::<Result<_, _>>()?;
        for r in &mut rows {
            r.retain(|k, _| keep.contains(k));
        }
    }
    // Paging needs the table keys; a projection that drops them would lose the position, as in DynamoDB's
    // own LastEvaluatedKey, which is built from the stored item.
    let full: Vec<Item> = st.tables[t].values().cloned().collect();
    let mut key_attrs = vec![def.pk.clone()];
    key_attrs.extend(def.sk.clone());
    let start = req.get("ExclusiveStartKey").and_then(Value::as_object).cloned();
    let from = match &start {
        Some(s) => full.iter().position(|i| key_attrs.iter().all(|a| i.get(a) == s.get(a))).map_or(0, |p| p + 1),
        None => 0,
    };
    let take = cfg.page_size;
    let slice = &rows[from.min(rows.len())..(from + take).min(rows.len())];
    let mut out = json!({"Items": slice, "Count": slice.len(), "ScannedCount": slice.len()});
    if from + take < rows.len() {
        if let Some(last) = full.get(from + take - 1) {
            let lek: Item = key_attrs.iter().filter_map(|a| last.get(a).map(|v| (a.clone(), v.clone()))).collect();
            out["LastEvaluatedKey"] = Value::Object(lek);
        }
    }
    Ok(out)
}

fn transact(cfg: &FakeConfig, st: &mut State, req: &Value) -> Result<Value, Fail> {
    let items = req.get("TransactItems").and_then(Value::as_array).ok_or_else(|| Fail::validation("TransactItems is required"))?;
    if items.is_empty() || items.len() > 100 {
        return Err(Fail::validation("TransactItems must hold 1 to 100 items"));
    }
    if req.get("ClientRequestToken").and_then(Value::as_str).is_none_or(str::is_empty) {
        return Err(Fail::validation("ClientRequestToken is required: a retry of the transaction must not apply it twice"));
    }
    struct W<'a> {
        table: &'a str,
        item: Item,
        key: (String, String),
        put: &'a Value,
    }
    let mut writes: Vec<W<'_>> = Vec::new();
    let mut seen = BTreeSet::new();
    for it in items {
        let put = it.get("Put").ok_or_else(|| Fail::validation("fake: a transaction item other than Put"))?;
        let t = str_of(put, "TableName")?;
        let def = table_def(cfg, t)?;
        check_grant(cfg, t, "dynamodb:PutItem", None)?;
        let item = item_of(put, "Item")?;
        check_item(def, &item)?;
        let key = key_of(def, &item)?;
        if !seen.insert((t.to_string(), key.clone())) {
            return Err(Fail::validation("Transaction request cannot include multiple operations on one item"));
        }
        writes.push(W { table: t, item, key, put });
    }
    let mut failed = Vec::new();
    for w in &writes {
        let e = Exprs::new(w.put, &["ConditionExpression"])?;
        let ok = e.holds(w.put.get("ConditionExpression").and_then(Value::as_str), st.tables[w.table].get(&w.key))?;
        failed.push(!ok);
    }
    if failed.iter().any(|f| *f) {
        return Err(Fail::Cancelled(failed));
    }
    for w in writes {
        st.tables.get_mut(w.table).expect("checked").insert(w.key, w.item);
    }
    Ok(json!({}))
}

